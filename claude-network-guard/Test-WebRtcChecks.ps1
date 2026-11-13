$ErrorActionPreference='Stop'
. "$PSScriptRoot\WebRtcChecks.ps1"
foreach($scenario in @('secure-user','secure-machine','missing','permissive','unsafe-url','safe-url','malformed','exposure-exception','read-error','empty')){
 $snapshot=[pscustomobject]@{MachineHandling=$null;UserHandling='disable_non_proxied_udp';OverrideValues=@();AllowedUrlCount=0;Error=$false}
 switch($scenario){
  'secure-machine' {$snapshot.MachineHandling='disable_non_proxied_udp';$snapshot.UserHandling='default'}
  'missing' {$snapshot.UserHandling=$null}
  'permissive' {$snapshot.MachineHandling='default'}
  'unsafe-url' {$snapshot.OverrideValues=@('[{"url":"*","handling":"default"}]')}
  'safe-url' {$snapshot.OverrideValues=@('[{"url":"*","handling":"disable_non_proxied_udp"}]')}
  'malformed' {$snapshot.OverrideValues=@('{broken')}
  'exposure-exception' {$snapshot.AllowedUrlCount=1}
  'read-error' {$snapshot.Error=$true}
 }
 $inputSnapshots=if($scenario -eq 'empty'){@()}else{@($snapshot)}
 $result=@(Test-WebRtcSnapshots 'TestBrowser' $inputSnapshots)
 $expectedPass=$scenario -in @('secure-user','secure-machine','safe-url')
 $passed=(@($result|Where-Object Status -eq 'fail').Count -eq 0)
 if($passed -ne $expectedPass -or $result.Count -ne 3){throw "Unexpected result for $scenario"}
 Write-Output "PASS $scenario"
}
