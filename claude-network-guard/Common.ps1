$ErrorActionPreference='Stop'
$script:AppRoot=$PSScriptRoot
$script:StateRoot=Join-Path $AppRoot 'state'
$script:Config=Get-Content (Join-Path $AppRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
function Read-Json([string]$Path){
 # Replacement can briefly hide or lock the destination even with delete sharing.
 for($attempt=0;;$attempt++){
  $stream=$null
  $reader=$null
  try{
   $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
   $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
   return ($reader.ReadToEnd() | ConvertFrom-Json)
  }catch{
   $cause=$_.Exception
   while($cause.InnerException){$cause=$cause.InnerException}
   $code=$cause.HResult -band 65535
   if($cause -isnot [IO.IOException] -or $code -notin @(2,32,33) -or $attempt -ge 20){throw}
  }finally{
   if($reader){$reader.Dispose()}
   if($stream){$stream.Dispose()}
  }
  Start-Sleep -Milliseconds 50
 }
}
function Write-Json([string]$Path,$Value){
 $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 [IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 try{
  for($attempt=0;$attempt -lt 21;$attempt++){
   try{
    if(Test-Path -LiteralPath $Path){
     $backup=$Path+'.replace-'+[guid]::NewGuid().ToString('N')
     [IO.File]::Replace($temp,$Path,$backup)
     Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }else{[IO.File]::Move($temp,$Path)}
    return
   }catch{
    $cause=$_.Exception;while($cause.InnerException){$cause=$cause.InnerException}
    $native=$cause.HResult -band 65535
    if($native -notin @(32,33) -or $attempt -eq 20){throw}
    # Retry only transient sharing violations for at most 1 second. Permanent failures still lock.
    Start-Sleep -Milliseconds 50
   }
  }
 }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}}
}
function Write-Event([string]$Kind,[string]$Message){
 $path=Join-Path $StateRoot 'events.jsonl'
 # Each process has its own log, avoiding concurrent append/truncation races.
 $path=Join-Path $StateRoot ('events-'+$PID+'.jsonl')
 if((Test-Path $path) -and (Get-Item $path).Length -gt 2097152){Move-Item -LiteralPath $path -Destination ($path+'.previous') -Force}
 [IO.File]::AppendAllText($path,((@{At=[datetime]::UtcNow.ToString('o');Kind=$Kind;Message=$Message} | ConvertTo-Json -Compress)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}
function Is-Protected([string]$Name,[string]$Path){
 if(-not $Path){return $false}
 if($Path -match '^C:\\Program Files\\WindowsApps\\Claude_[^\\]+\\app\\(?:[^\\]+\\)*[^\\]+\.exe$'){return $true}
 if($Name -ieq 'node' -or $Name -ieq 'node.exe'){return $Path -ieq $Config.DedicatedNode}
 if($Name -ine 'claude' -and $Name -ine 'claude.exe'){return $false}
 return ($Path -match '^C:\\Program Files\\WindowsApps\\Claude_[^\\]+\\app\\claude\.exe$' -or $Path.StartsWith($Config.CodeRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))
}
function Get-ProtectedProcesses {
 foreach($p in @(Get-Process -ErrorAction SilentlyContinue)){
  try{$path=$p.MainModule.FileName;if(Is-Protected $p.ProcessName $path){[pscustomobject]@{Id=$p.Id;Name=$p.ProcessName;Path=$path}}}catch{
   # Do not guess a node PID: shared Node must never be killed.
   if($p.ProcessName -match '^(claude|cowork-svc|claude-ssh-.+|github-mcp-server|chrome-native-host)$'){throw ('Cannot inspect protected candidate PID '+$p.Id)}
  }
 }
}
function Stop-Protected([bool]$AllowRouter=$false){
 foreach($p in @(Get-ProtectedProcesses)){
  if($AllowRouter -and $p.Path -ieq $Config.DedicatedNode){continue}
  try{
   $actual=Get-Process -Id $p.Id -ErrorAction Stop
   if($actual.MainModule.FileName -ine $p.Path){continue}
   $actual.Kill();Write-Event 'terminated' ($p.Name+' PID '+$p.Id)
  }catch{Write-Event 'termination-error' ($p.Name+' PID '+$p.Id+': '+$_.Exception.Message)}
 }
}
function Set-Lock([string]$Reason){
 $path=Join-Path $StateRoot 'lock.json'
 if(Test-Path -LiteralPath $path){return}
 $stream=$null
 try{
  $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  $bytes=[Text.Encoding]::UTF8.GetBytes((@{At=[datetime]::UtcNow.ToString('o');Reason=$Reason} | ConvertTo-Json))
  $stream.Write($bytes,0,$bytes.Length)
 }catch [IO.IOException]{if(-not (Test-Path $path)){throw}}finally{if($stream){$stream.Dispose()}}
 Write-Event 'locked' $Reason
}
function Get-Lock {if(Test-Path (Join-Path $StateRoot 'lock.json')){try{return (Read-Json (Join-Path $StateRoot 'lock.json'))}catch{return [pscustomobject]@{Reason='Lock record pending or unreadable';At=[datetime]::UtcNow.ToString('o')}}};return $null}
function Is-Fresh($Report,[int]$MaxSeconds){
 if(-not $Report -or -not $Report.At){return $false}
 try{$age=([datetime]::UtcNow-([datetime]$Report.At).ToUniversalTime()).TotalSeconds;return $age -ge -5 -and $age -le $MaxSeconds}catch{return $false}
}
function Can-Unlock($Report){return ($Report -and (Is-Fresh $Report 45) -and $Report.Healthy -eq $true)}
function Check-Fast([bool]$Locked){
 $fail=[Collections.Generic.List[string]]::new()
 try{
  $inet=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $conn=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
  if($inet.ProxyEnable -ne 1 -or $inet.ProxyServer -ne '127.0.0.1:12460' -or $conn.DefaultConnectionSettings[8] -ne 3){$fail.Add('Windows proxy changed')}
  $ports=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object {$_.Address.ToString() -in @('127.0.0.1','::1')} | ForEach-Object {$_.Port})
  foreach($port in @(12460,53)){if($ports -notcontains $port){$fail.Add('Missing local listener '+$port)}}
  if(-not $Locked -and $ports -notcontains 18791){$fail.Add('Router listener missing')}
  $targets=Read-Json (Join-Path $Config.RuntimeRoot 'EgressGuard\targets.json')
  foreach($t in $targets.Targets){if(-not (Test-Path -LiteralPath $t.Path)){$fail.Add('Protected executable removed: '+$t.Label)}}
  foreach($p in @(Get-ProtectedProcesses)){if(@($targets.Targets | Where-Object {$_.Path -ieq $p.Path}).Count -eq 0){$fail.Add('New Claude executable not covered: '+$p.Path)}}
  $fw=New-Object -ComObject HNetCfg.FwPolicy2
  foreach($profile in @(1,2,4)){if(-not $fw.FirewallEnabled($profile)){$fail.Add('Windows firewall disabled')}}
 }catch{$fail.Add('Fast check failed: '+$_.Exception.Message)}
 return $fail.ToArray()
}
