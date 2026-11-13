function Test-WebRtcSnapshots($Browser,$Snapshots){
 $handlingOk=$true;$overridesOk=$true;$exceptionsOk=$true
 if(-not $Snapshots){$handlingOk=$false;$overridesOk=$false;$exceptionsOk=$false}
 foreach($snapshot in $Snapshots){
  if($snapshot.Error){$handlingOk=$false;$overridesOk=$false;$exceptionsOk=$false;continue}
  $effective=if($null -ne $snapshot.MachineHandling){$snapshot.MachineHandling}else{$snapshot.UserHandling}
  if($effective -cne 'disable_non_proxied_udp'){$handlingOk=$false}
  foreach($json in $snapshot.OverrideValues){
   try{
    if($json -isnot [string] -or -not $json.TrimStart().StartsWith('[')){throw 'Expected a JSON array'}
    $items=$json | ConvertFrom-Json -ErrorAction Stop
    foreach($item in $items){if($item.handling -cne 'disable_non_proxied_udp' -or -not ($item.url -is [string]) -or -not $item.url){$overridesOk=$false}}
   }catch{$overridesOk=$false}
  }
  if($snapshot.AllowedUrlCount -gt 0){$exceptionsOk=$false}
 }
 foreach($check in @(
  @{Label='non-proxied UDP disabled';Passed=$handlingOk},
  @{Label='URL overrides restricted';Passed=$overridesOk},
  @{Label='no local-IP exposure exceptions';Passed=$exceptionsOk}
 )){
  [pscustomobject]@{Name=('WebRTC:'+$Browser+' '+$check.Label);Status=$(if($check.Passed){'pass'}else{'fail'});Detail='Mandatory registry policies, 32/64-bit views; browser runtime requires separate verification'}
 }
}
function Get-WebRtcChecks {
 foreach($browser in @(
  @{Name='Edge';Path='Software\Policies\Microsoft\Edge';Handling='WebRtcLocalhostIpHandling'},
  @{Name='Chrome';Path='Software\Policies\Google\Chrome';Handling='WebRtcIPHandling'}
 )){
  $snapshots=@()
  foreach($view in @('Registry64','Registry32')){
   $snapshot=[pscustomobject]@{MachineHandling=$null;UserHandling=$null;OverrideValues=@();AllowedUrlCount=0;Error=$false}
   foreach($hive in @('LocalMachine','CurrentUser')){
    $base=$null;$key=$null;$allowed=$null
    try{
     $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::$hive,[Microsoft.Win32.RegistryView]::$view)
     $key=$base.OpenSubKey($browser.Path)
     if($key){
      $value=$key.GetValue($browser.Handling,$null)
      if($hive -eq 'LocalMachine'){$snapshot.MachineHandling=$value}else{$snapshot.UserHandling=$value}
      if($key.GetValueNames() -contains 'WebRtcIPHandlingUrl'){$snapshot.OverrideValues+=,$key.GetValue('WebRtcIPHandlingUrl')}
      $allowed=$key.OpenSubKey('WebRtcLocalIpsAllowedUrls')
      if($allowed){$snapshot.AllowedUrlCount+=@($allowed.GetValueNames()|Where-Object {$_ -match '^\d+$'}).Count}
     }
    }catch{$snapshot.Error=$true}finally{if($allowed){$allowed.Dispose()};if($key){$key.Dispose()};if($base){$base.Dispose()}}
   }
   $snapshots+=$snapshot
  }
  Test-WebRtcSnapshots $browser.Name $snapshots
 }
}
