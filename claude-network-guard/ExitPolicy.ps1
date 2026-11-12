function Get-ExitCheck($Name,$Observed,$Expected){
 $expectedAddress=$null
 if(-not [Net.IPAddress]::TryParse([string]$Expected,[ref]$expectedAddress)){throw 'Invalid expected exit IP'}
 $observedAddress=$null
 if(-not [Net.IPAddress]::TryParse([string]$Observed,[ref]$observedAddress)){
  return [pscustomobject]@{Name=$Name;Status='warning';Detail='Exit IP could not be confirmed'}
 }
 $status=if($observedAddress.Equals($expectedAddress)){'pass'}else{'fail'}
 return [pscustomobject]@{Name=$Name;Status=$status;Detail=('Observed '+$observedAddress+'; expected '+$expectedAddress)}
}
function Get-HealthSummary($Checks){
 $failures=@($Checks | Where-Object {$_.Status -notin @('pass','quarantined','warning')})
 $warnings=@($Checks | Where-Object {$_.Status -eq 'warning'})
 return [pscustomobject]@{
  Healthy=($failures.Count -eq 0)
  Failures=@($failures | ForEach-Object {$_.Name+': '+$_.Detail})
  Warnings=@($warnings | ForEach-Object {$_.Name+': '+$_.Detail})
 }
}
