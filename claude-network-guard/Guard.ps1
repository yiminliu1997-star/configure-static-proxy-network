. "$PSScriptRoot\Common.ps1"
$mutex=[Threading.Mutex]::new($false,'Global\ClaudeNetworkGuard-Worker-v1')
if(-not $mutex.WaitOne(0)){exit 0}
$child=$null;$childAt=[datetime]::MinValue;$nextProbe=[datetime]::MinValue;$nextFast=[datetime]::MinValue;$nextRouter=[datetime]::MinValue
$recovering=$false;$recoveryAt=[datetime]::MinValue;$notice='';$report=$null;$fast=@()
function Stop-Probe {
 if($script:child){try{if(-not $script:child.HasExited){Stop-Process -Id $script:child.Id -Force}}catch{};$script:child=$null}
}
function Router-Quarantine {
 $task=Get-ScheduledTask -TaskName $Config.RouterTask
 if(-not $task.Actions[0].Arguments.Contains($Config.RouterLauncher)){throw 'Router task action changed; refusing to modify foreign task'}
 if($task.Settings.Enabled){Disable-ScheduledTask -TaskName $Config.RouterTask | Out-Null}
 foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {$_.CommandLine -and $_.CommandLine.Contains('"'+$Config.RouterLauncher+'"')})){Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue}
}
try{
 Write-Event 'started' 'Guard worker started'
 while($true){
  $now=[datetime]::UtcNow;$armed=Test-Path (Join-Path $StateRoot 'armed')
  try{
   $lock=Get-Lock
   if(Test-Path (Join-Path $StateRoot 'health.json')){$report=Read-Json (Join-Path $StateRoot 'health.json')}
   $request=Join-Path $StateRoot 'command.json'
   if(Test-Path $request){
    $cmd=Read-Json $request;Remove-Item -LiteralPath $request -Force
    switch($cmd.Action){
     'lock' {if($armed){Set-Lock 'Manual emergency stop';$recovering=$false;$lock=Get-Lock;$notice='已手动锁定'}}
     'check' {$nextProbe=[datetime]::MinValue;$notice='已请求重新检查'}
     'unlock' {
      if($lock -and $armed -and (Can-Unlock $report) -and $report.Quarantined){
       $recovering=$true;$recoveryAt=$now;$nextProbe=$now.AddSeconds(6);Stop-Probe
       Enable-ScheduledTask -TaskName $Config.RouterTask | Out-Null
       Start-ScheduledTask -TaskName $Config.RouterTask
       $notice='正在验证解锁；Claude 仍被停止，仅启动路由器进行诊断'
      }else{$notice='暂不能解锁：请先修复异常，再等待一轮健康检查'}
     }
    }
   }
   if($now -ge $nextFast){$fast=@(Check-Fast ([bool]$lock));$nextFast=$now.AddSeconds(2)}
   if($armed){
    $supervisor=$null;try{$supervisor=Read-Json (Join-Path $StateRoot 'supervisor.json')}catch{}
    if(-not (Is-Fresh $supervisor 10)){Set-Lock 'Supervisor heartbeat missing/stale (10s)';$recovering=$false}
    if($fast.Count){Set-Lock ($fast -join '; ');$recovering=$false}
    if(-not (Is-Fresh $report 75)){Set-Lock 'Health report missing/stale (75s)';$recovering=$false}
    elseif(-not $report.Healthy){Set-Lock ($report.Failures -join '; ');$recovering=$false}
    elseif($report.Quarantined -and -not $lock){Set-Lock 'Full health report required before operation'}
   }
   $lock=Get-Lock
   if($armed -and $lock){
    Stop-Protected $recovering
    if(-not $recovering -and $now -ge $nextRouter){Router-Quarantine;$nextRouter=$now.AddSeconds(5)}
    if($recovering){
     if($now.Subtract($recoveryAt).TotalSeconds -gt 70){$recovering=$false;$notice='解锁超时，继续锁定';$nextRouter=[datetime]::MinValue}
     elseif($report -and -not $report.Quarantined -and ([datetime]$report.At).ToUniversalTime() -gt $recoveryAt -and (Can-Unlock $report) -and $fast.Count -eq 0){
      Remove-Item -LiteralPath (Join-Path $StateRoot 'lock.json') -Force
      $recovering=$false;$lock=$null;$notice='已手动解锁；可自行重新打开 Claude';Write-Event 'unlocked' 'Manual unlock after fresh full health check'
     }
    }
   }
   if($child){
    $child.Refresh()
    if($child.HasExited){$child=$null;$nextProbe=$now.AddSeconds(8)}
    elseif($now.Subtract($childAt).TotalSeconds -gt 60){Stop-Probe;if($armed){Set-Lock 'Health probe exceeded 60s'};$nextProbe=$now.AddSeconds(2)}
   }
   if(-not $child -and $now -ge $nextProbe){
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$AppRoot+'\Probe.ps1"'),'-OutputPath',('"'+$StateRoot+'\health.json"'))
    if($lock -and -not $recovering){$args+='-Quarantined'}
    $child=Start-Process -FilePath $Config.PowerShell -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $StateRoot 'probe-error.log')
    $childAt=$now
   }
   $mode=if(-not $armed){'OBSERVE'}elseif($lock){if($recovering){'VERIFYING_UNLOCK'}else{'LOCKED'}}elseif($report -and $report.Healthy){'HEALTHY'}else{'CHECKING'}
   Write-Json (Join-Path $StateRoot 'status.json') @{At=[datetime]::UtcNow.ToString('o');Mode=$mode;Pid=$PID;SessionId=(Get-Process -Id $PID).SessionId;Armed=$armed;Lock=$lock;Notice=$notice;FastFailures=@($fast);ProbeRunning=[bool]$child;ReportAt=$report.At;ExpectedExit=$report.ExpectedExit}
  }catch{
   $notice=$_.Exception.Message;Write-Event 'guard-error' $notice
   if($armed){Set-Lock ('Monitor error: '+$notice);Stop-Protected $false}
   try{Write-Json (Join-Path $StateRoot 'status.json') @{At=[datetime]::UtcNow.ToString('o');Mode='ERROR';Pid=$PID;Armed=$armed;Lock=(Get-Lock);Notice=$notice}}catch{}
  }
  Start-Sleep -Milliseconds 500
 }
}finally{Stop-Probe;$mutex.ReleaseMutex();$mutex.Dispose()}
