$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$assembly=[Reflection.Assembly]::LoadFrom("$PSScriptRoot\ClaudeNetworkGuard.UI.exe")
$dashboard=$assembly.GetType('Dashboard')
$category=$dashboard.GetMethod('Category')
$h=Get-Content "$PSScriptRoot\state\health.json" -Raw|ConvertFrom-Json
$counts=@(0,0,0,0,0,0)
foreach($row in $h.Checks){$index=$category.Invoke($null,@([string]$row.Name));if($index -lt 0 -or $index -gt 5){throw 'Invalid category'};$counts[$index]++}
if(($counts|Measure-Object -Sum).Sum -ne $h.Checks.Count){throw 'Missing checks'}
$type=$assembly.GetType('CheckCard')
$card=[Activator]::CreateInstance($type,@([int]0))
try {
 $card.Size=New-Object Drawing.Size(1000,300)
 $rows=New-Object 'Collections.Generic.List[Collections.Generic.Dictionary[string,object]]'
 $row=New-Object 'Collections.Generic.Dictionary[string,object]'
 $row.Add('Name','Live:static exit');$row.Add('Status','warning');$row.Add('Detail','Isolated UI fixture: timeout reminder only')
 $rows.Add($row)
 $update=$type.GetMethod('UpdateRows')
 $null=$update.Invoke($card,@('代理与出口','出口检测超时只提醒，不代表已经锁定。',$rows.PSObject.BaseObject))
 if($card.Severity -ne 1 -or -not $card.Expanded){throw 'Warning rendering failed'}
 $row['Status']='fail';$null=$update.Invoke($card,@('代理与出口','独立界面测试，不改生产状态。',$rows.PSObject.BaseObject))
 if($card.Severity -ne 2 -or -not $card.Expanded){throw 'Failure rendering failed'}
 $row['Status']='quarantined';$null=$update.Invoke($card,@('代理与出口','锁定停用不是新的异常。',$rows.PSObject.BaseObject))
 if($card.Severity -ne 0){throw 'Quarantine incorrectly classified'}
 $row['Status']='pass';$null=$update.Invoke($card,@('代理与出口','主代理、专用路由器与出口 IP',$rows.PSObject.BaseObject))
 if($card.Severity -ne 0){throw 'Normal rendering failed'}
 $bitmap=New-Object Drawing.Bitmap(1000,300)
 try{$card.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,1000,300)));$bitmap.Save("$PSScriptRoot\ui-categories-expanded.png")}finally{$bitmap.Dispose()}
 [pscustomobject]@{Passed=$true;Total=$h.Checks.Count;Categories=$counts;WarningFailureQuarantine=$true;ProductionStateModified=$false}|ConvertTo-Json|Set-Content "$PSScriptRoot\ui-categories-tests.json" -Encoding UTF8
}finally{$card.Dispose()}
