param([ValidateSet('Install','Arm','Uninstall','Preflight')][string]$Action='Preflight')
. "$PSScriptRoot\Common.ps1"
$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $admin){throw 'Administrator rights required'}
try{
 switch($Action){
  'Preflight' {
   & "$AppRoot\Probe.ps1" -OutputPath "$StateRoot\preflight.json"
   $probe=Read-Json "$StateRoot\preflight.json"
   if(-not $probe.Healthy){throw ('Preflight failed: '+($probe.Failures -join '; '))}
  }
  'Install' {
   if(Test-Path "$StateRoot\armed"){throw 'Already armed; no reinstall while active'}
   foreach($name in @($Config.GuardTask,$Config.SupervisorTask)){if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw ('Task already exists: '+$name)}}
   & "$AppRoot\Probe.ps1" -OutputPath "$StateRoot\health.json"
   if(-not (Read-Json "$StateRoot\health.json").Healthy){throw 'Preflight failed; monitoring not installed'}
   $backup=Join-Path $AppRoot ('backup-'+(Get-Date -Format yyyyMMdd-HHmmss))
   New-Item -ItemType Directory $backup | Out-Null
   Export-ScheduledTask -TaskName $Config.RouterTask | Set-Content (Join-Path $backup 'router-task.xml') -Encoding UTF8
   Write-Json (Join-Path $backup 'install.json') @{User=$Config.User;At=[datetime]::UtcNow.ToString('o');RouterWasEnabled=(Get-ScheduledTask -TaskName $Config.RouterTask).Settings.Enabled}
   $registered=@()
   try{
    foreach($entry in @(@{Name=$Config.GuardTask;File='Guard.ps1'},@{Name=$Config.SupervisorTask;File='Supervisor.ps1'})){
     $taskAction=New-ScheduledTaskAction -Execute $Config.PowerShell -Argument ('-NoProfile -ExecutionPolicy Bypass -File "'+$AppRoot+'\'+$entry.File+'"') -WorkingDirectory $AppRoot
     if($entry.Name -eq $Config.SupervisorTask){$taskAction=New-ScheduledTaskAction -Execute "$AppRoot\ClaudeNetworkGuard.exe" -Argument '--supervisor' -WorkingDirectory $AppRoot}
     $trigger=New-ScheduledTaskTrigger -AtLogOn -User $Config.User
     $principal=New-ScheduledTaskPrincipal -UserId $Config.User -LogonType S4U -RunLevel Highest
     $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
     Register-ScheduledTask -TaskName $entry.Name -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Description 'Claude Network Guard: local monitoring and explicit lock; owned by ClaudeNetworkGuard' | Out-Null
     $registered+=$entry.Name
     Start-ScheduledTask -TaskName $entry.Name
    }
   }catch{foreach($name in $registered){Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $name -Confirm:$false};throw}
  }
  'Arm' {
   $health=Read-Json "$StateRoot\health.json";$status=Read-Json "$StateRoot\status.json";$sup=Read-Json "$StateRoot\supervisor.json"
   if(-not (Can-Unlock $health) -or $health.Quarantined -or -not (Is-Fresh $status 10) -or -not (Is-Fresh $sup 10) -or $status.SessionId -ne 0 -or $sup.SessionId -ne 0 -or $sup.GuardStale -or @($status.FastFailures).Count -gt 0 -or $status.Mode -notin @('OBSERVE','HEALTHY')){throw 'Healthy Session 0 monitoring required before arming'}
   if(Get-Lock){throw 'Existing lock must be reviewed before arming'}
   [IO.File]::WriteAllText("$StateRoot\armed",[datetime]::UtcNow.ToString('o'))
   Write-Event 'armed' 'Automatic stop and persistent lock enabled'
  }
  'Uninstall' {
   # Explicit user action only. Preserve a lock and disabled router rather than silently reconnecting.
   if(Test-Path "$StateRoot\armed"){Remove-Item -LiteralPath "$StateRoot\armed" -Force}
   foreach($entry in @(@{Name=$Config.SupervisorTask;File='Supervisor.ps1'},@{Name=$Config.GuardTask;File='Guard.ps1'})){
    $t=Get-ScheduledTask -TaskName $entry.Name -ErrorAction SilentlyContinue
    if($t){
     $owned=($t.Actions[0].Execute -ieq $Config.PowerShell -and $t.Actions[0].Arguments.Contains('"'+$AppRoot+'\'+$entry.File+'"'))
     if($entry.Name -eq $Config.SupervisorTask -and $t.Actions[0].Execute -ieq "$AppRoot\ClaudeNetworkGuard.exe" -and $t.Actions[0].Arguments -eq '--supervisor'){$owned=$true}
     if(-not $owned){throw 'Task ownership mismatch'}
     Stop-ScheduledTask -TaskName $entry.Name;Unregister-ScheduledTask -TaskName $entry.Name -Confirm:$false
    }
   }
  }
 }
 Write-Json "$StateRoot\management-result.json" @{Action=$Action;Success=$true;At=[datetime]::UtcNow.ToString('o')}
}catch{Write-Json "$StateRoot\management-result.json" @{Action=$Action;Success=$false;Error=$_.Exception.Message;At=[datetime]::UtcNow.ToString('o')};throw}
