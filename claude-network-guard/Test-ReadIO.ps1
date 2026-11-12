param([string]$TestDirectory,[switch]$Writer)
. "$PSScriptRoot\Common.ps1"
if(-not $TestDirectory){$TestDirectory=Join-Path $env:TEMP ('GuardReadTest-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $TestDirectory | Out-Null}
$file=Join-Path $TestDirectory 'sample.json'
if($Writer){
 for($i=0;$i -lt 1500;$i++){Write-Json $file @{Value=$i}}
 exit 0
}
Add-Type -TypeDefinition @'
using System.IO;
using System.Threading;
public static class TemporaryReadLock {
 public static Thread Hold(string path){
  var file=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.None);
  var thread=new Thread(delegate(){Thread.Sleep(200);file.Dispose();});
  thread.Start();return thread;
 }
}
'@
Write-Json $file @{Value=1}
$release=[TemporaryReadLock]::Hold($file)
if((Read-Json $file).Value -ne 1){throw 'Transient read failed'}
$release.Join()
function Assert-ReadFailure($Path,$Code){
 $timer=[Diagnostics.Stopwatch]::StartNew();$failed=$false
 try{Read-Json $Path | Out-Null}catch{
  $cause=$_.Exception;while($cause.InnerException){$cause=$cause.InnerException}
  if(($cause.HResult -band 65535) -ne $Code){throw}
  $failed=$true
 }
 if(-not $failed -or $timer.Elapsed.TotalSeconds -gt 3){throw 'Permanent failure handling incorrect'}
}
$held=[IO.File]::Open($file,'Open','ReadWrite','None')
try{Assert-ReadFailure $file 32}finally{$held.Dispose()}
Assert-ReadFailure ($file+'.missing') 2
[IO.File]::WriteAllText($file,'{invalid')
$failed=$false
try{Read-Json $file | Out-Null}catch{$failed=$true}
if(-not $failed){throw 'Malformed JSON accepted'}
Write-Json $file @{Value=0}
$child=Start-Process $Config.PowerShell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-TestDirectory',('"'+$TestDirectory+'"'),'-Writer') -RedirectStandardError "$TestDirectory\writer-error.txt"
$reads=0
try{
 while(-not $child.HasExited){Read-Json $file | Out-Null;$reads++}
 $child.WaitForExit()
 if((Get-Item "$TestDirectory\writer-error.txt").Length -gt 0 -or $reads -eq 0){throw 'Concurrent writer failed'}
}finally{if(-not $child.HasExited){$child.Kill()}}
Write-Output "PASS: transient lock, persistent lock, missing file, malformed JSON, concurrent replacement ($reads reads)"
