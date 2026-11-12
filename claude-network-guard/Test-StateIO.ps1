. "$PSScriptRoot\Common.ps1"
$dir=Join-Path $AppRoot ('test-io-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir | Out-Null
$file=Join-Path $dir 'state.json'
$results=@()
Write-Json $file @{Value=1}
$handle=[IO.File]::Open($file,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
try{Write-Json $file @{Value=2};if((Read-Json $file).Value -ne 2){throw 'Share-delete test failed'}}finally{$handle.Dispose()}
$results+='Concurrent shared-delete reader: PASS'
$script=@'
param($Folder)
$s=[IO.File]::Open((Join-Path $Folder 'state.json'),'Open','Read',[IO.FileShare]::ReadWrite)
try{[IO.File]::WriteAllText((Join-Path $Folder 'ready'),'1');Start-Sleep -Milliseconds 400}finally{$s.Dispose()}
'@
$path=Join-Path $dir 'reader.ps1';[IO.File]::WriteAllText($path,$script)
$p=Start-Process -FilePath $Config.PowerShell -ArgumentList @('-NoProfile','-File',('"'+$path+'"'),'-Folder',('"'+$dir+'"')) -WindowStyle Hidden -PassThru
try{
 $deadline=[datetime]::UtcNow.AddSeconds(10)
 while(-not (Test-Path (Join-Path $dir 'ready'))){if([datetime]::UtcNow -gt $deadline){throw 'Reader startup timeout'};Start-Sleep -Milliseconds 10}
 Write-Json $file @{Value=3}
 if((Read-Json $file).Value -ne 3){throw 'Transient sharing test failed'}
}finally{if(-not $p.HasExited){$p.WaitForExit(2000) | Out-Null}}
$results+='Transient non-delete-sharing reader: PASS'
$held=[IO.File]::Open($file,'Open','Read',[IO.FileShare]::ReadWrite);$threw=$false
try{try{Write-Json $file @{Value=4}}catch{$threw=$true}}finally{$held.Dispose()}
if(-not $threw -or (Read-Json $file).Value -ne 3){throw 'Persistent error must not be suppressed'}
$results+='Persistent sharing failure still reported, old state intact: PASS'
$results | ConvertTo-Json | Set-Content "$AppRoot\state-io-tests.json" -Encoding UTF8
$results
