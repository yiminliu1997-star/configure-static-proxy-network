param([string]$OutputPath,[switch]$Quarantined)
. "$PSScriptRoot\Common.ps1"
$checks=[Collections.Generic.List[object]]::new()
$diagnostic=@{User=[Security.Principal.WindowsIdentity]::GetCurrent().Name;Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;EdgeHKCU=(Test-Path 'HKCU:\Software\Policies\Microsoft\Edge');EdgeHKU=(Test-Path ('Registry::HKEY_USERS\'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value+'\Software\Policies\Microsoft\Edge'))}
$diagnostic.Is64Bit=[Environment]::Is64BitProcess
foreach($view in @('Registry32','Registry64')){$b=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::$view);try{$k=$b.OpenSubKey('Software\Policies\Microsoft\Edge');$diagnostic[$view]=($null -ne $k);if($k){$k.Dispose()}}finally{$b.Dispose()}}
Write-Json (Join-Path $StateRoot 'registry-diagnostic.json') $diagnostic
function Add-Check($Name,$Passed,$Detail=''){$checks.Add([pscustomobject]@{Name=$Name;Status=$(if($Passed){'pass'}else{'fail'});Detail=$Detail})}
try{
 $base=& $Config.AuditScript -Root $Config.RuntimeRoot | ConvertFrom-Json
 foreach($c in $base.Checks){
  if($Quarantined -and $c.Name -in @(("Task:"+$Config.RouterTask),("Task:noninteractive "+$Config.RouterTask),'Listener:TCP18791')){$c.Status='quarantined';$c.Detail='Stopped intentionally while locked'}
  $checks.Add($c)
 }
 $desired=Read-Json $Config.DesiredPath
 Add-Type -AssemblyName System.Net.Http
 function Fetch($Url,$Proxy,[int]$TimeoutSeconds=6){
  for($attempt=1;$attempt -le 2;$attempt++){
   $handler=New-Object Net.Http.HttpClientHandler
   $handler.UseProxy=[bool]$Proxy
   if($Proxy){$handler.Proxy=New-Object Net.WebProxy($Proxy)}
   $client=New-Object Net.Http.HttpClient($handler)
   $client.Timeout=[timespan]::FromSeconds($TimeoutSeconds)
   try{
    return ($client.GetStringAsync($Url).GetAwaiter().GetResult() | ConvertFrom-Json)
   }catch{
    $cause=$_.Exception
    while($cause.InnerException){$cause=$cause.InnerException}
    if($cause -isnot [OperationCanceledException]){throw}
    if($attempt -eq 2){throw "Health request timed out twice ($TimeoutSeconds seconds per attempt)"}
    Write-Event 'probe-retry' ('Health request timed out; verifying again: '+([uri]$Url).Host)
   }finally{$client.Dispose();$handler.Dispose()}
  }
 }
 try{$r=Fetch $desired.exitCheck.url $desired.localProxy;Add-Check 'Live:static exit' ($r.ip -eq $desired.exitIp) ('Observed '+$r.ip)}catch{Add-Check 'Live:static exit' $false $_.Exception.Message}
 if(-not $Quarantined){try{$r=Fetch 'http://127.0.0.1:18791/proxy-check' '';Add-Check 'Live:router exit' ($r.exitIP -eq $desired.exitIp -and $r.proxyPeer.port -eq 12460)}catch{Add-Check 'Live:router exit' $false $_.Exception.Message}}
 foreach($entry in @(@{Type='A';Server='127.0.0.1'},@{Type='AAAA';Server='::1'})){
  try{$r=@(Resolve-DnsName example.com -Type $entry.Type -Server $entry.Server -DnsOnly -QuickTimeout -ErrorAction Stop);Add-Check ('DNS query '+$entry.Type) (@($r | Where-Object IPAddress).Count -gt 0)}catch{Add-Check ('DNS query '+$entry.Type) $false $_.Exception.Message}
 }
 $targets=(Read-Json (Join-Path $Config.RuntimeRoot 'EgressGuard\targets.json')).Targets
 $packages=@(Get-AppxPackage 'Claude')
 Add-Check 'Desktop package discovery' ($packages.Count -gt 0)
 $installed=@($packages | ForEach-Object {Get-ChildItem -LiteralPath (Join-Path $_.InstallLocation 'app') -Recurse -Filter *.exe -File -ErrorAction Stop | ForEach-Object {$_.FullName}})
 $installed+=@(Get-ChildItem -LiteralPath $Config.CodeRoot -Filter claude.exe -Recurse -File | ForEach-Object {$_.FullName})
 foreach($path in $installed){Add-Check ('Version coverage: '+$path) (@($targets | Where-Object {$_.Path -ieq $path}).Count -gt 0)}
 foreach($p in @(Get-ProtectedProcesses)){Add-Check ('Running path: '+$p.Path) (@($targets | Where-Object {$_.Path -ieq $p.Path}).Count -gt 0)}
 $policy=(Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Claude' -ErrorAction SilentlyContinue).disableAutoUpdates
 Add-Check 'Desktop auto-update disabled' ($policy -eq 1)
 $code=Read-Json (Join-Path $env:USERPROFILE '.claude\settings.json')
 Add-Check 'Code auto-update disabled' ($code.env.DISABLE_AUTOUPDATER -eq '1')
}catch{Add-Check 'Probe exception' $false $_.Exception.Message}
$fail=@($checks | Where-Object {$_.Status -notin @('pass','quarantined')})
Write-Json $OutputPath @{At=[datetime]::UtcNow.ToString('o');Healthy=($fail.Count -eq 0);Quarantined=[bool]$Quarantined;ExpectedExit=$desired.exitIp;Checks=@($checks);Failures=@($fail | ForEach-Object {$_.Name+': '+$_.Detail});SessionId=(Get-Process -Id $PID).SessionId;Pid=$PID}
