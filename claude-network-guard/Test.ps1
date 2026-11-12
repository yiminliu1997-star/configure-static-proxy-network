. "$PSScriptRoot\Common.ps1"
$script:StateRoot=Join-Path $AppRoot ('test-state-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $StateRoot | Out-Null
$tests=[Collections.Generic.List[object]]::new()
function Assert($Name,$Condition){$tests.Add(@{Name=$Name;Passed=[bool]$Condition});if(-not $Condition){throw ('Test failed: '+$Name)}}
Assert 'Desktop version discovery' (Is-Protected 'claude' 'C:\Program Files\WindowsApps\Claude_99.0.0.0_x64__pzs8sxrjxfjjc\app\Claude.exe')
Assert 'Cowork included' (Is-Protected 'cowork-svc' 'C:\Program Files\WindowsApps\Claude_99_x64\app\resources\cowork-svc.exe')
Assert 'Unknown packaged helper included' (Is-Protected 'new-helper' 'C:\Program Files\WindowsApps\Claude_99_x64\app\resources\new-helper.exe')
Assert 'Foreign cowork excluded' (-not (Is-Protected 'cowork-svc' 'C:\other\cowork-svc.exe'))
Assert 'Other package excluded' (-not (Is-Protected 'helper' 'C:\Program Files\WindowsApps\Other_99\app\helper.exe'))
Assert 'Code version discovery' (Is-Protected 'claude' ($Config.CodeRoot+'\99\hash\claude.exe'))
Assert 'Dedicated router matched' (Is-Protected 'node' $Config.DedicatedNode)
Assert 'Shared node excluded' (-not (Is-Protected 'node' 'C:\shared\node.exe'))
Assert 'Codex excluded' (-not (Is-Protected 'Codex' 'C:\Codex\Codex.exe'))
Assert 'ToDesk excluded' (-not (Is-Protected 'ToDesk' 'C:\ToDesk\ToDesk.exe'))
Assert 'Unknown Claude path excluded' (-not (Is-Protected 'claude' 'C:\other\claude.exe'))
Assert 'Healthy fresh unlock allowed' (Can-Unlock ([pscustomobject]@{At=[datetime]::UtcNow.ToString('o');Healthy=$true}))
Assert 'Stale health cannot unlock' (-not (Can-Unlock ([pscustomobject]@{At=[datetime]::UtcNow.AddMinutes(-3).ToString('o');Healthy=$true})))
Assert 'Failed health cannot unlock' (-not (Can-Unlock ([pscustomobject]@{At=[datetime]::UtcNow.ToString('o');Healthy=$false})))
Assert 'Missing health cannot unlock' (-not (Can-Unlock $null))
Set-Lock 'Synthetic fault A';Set-Lock 'Synthetic fault B'
Assert 'First fault remains latched' ((Get-Lock).Reason -eq 'Synthetic fault A')
Write-Json "$StateRoot\sample.json" @{Value=1};Write-Json "$StateRoot\sample.json" @{Value=2}
Assert 'Atomic state update readable' ((Read-Json "$StateRoot\sample.json").Value -eq 2)
# Exercise the exact termination function against a harmless process we create.
# No production processes are returned by this test's process-discovery stub.
$dummyFile=Join-Path $StateRoot 'sleep.ps1'
[IO.File]::WriteAllText($dummyFile,'Start-Sleep -Seconds 60')
$dummy=Start-Process -FilePath $Config.PowerShell -ArgumentList @('-NoProfile','-File',('"'+$dummyFile+'"')) -WindowStyle Hidden -PassThru
try{
 $script:dummyRecord=[pscustomobject]@{Id=$dummy.Id;Name='harmless-test';Path=$Config.PowerShell}
 function Get-ProtectedProcesses {return $script:dummyRecord}
 Stop-Protected $false
 Assert 'Stop action terminates owned test process' ($dummy.WaitForExit(5000))
 Assert 'Lock persists after termination' ([bool](Get-Lock))
}finally{if(-not $dummy.HasExited){Stop-Process -Id $dummy.Id -ErrorAction SilentlyContinue}}
Write-Json "$AppRoot\test-results.json" @{At=[datetime]::UtcNow.ToString('o');Tests=@($tests);ProductionFaultInjected=$false;AllPassed=$true}
$tests | ConvertTo-Json
