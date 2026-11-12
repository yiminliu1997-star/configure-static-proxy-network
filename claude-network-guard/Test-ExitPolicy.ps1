$ErrorActionPreference='Stop'
. "$PSScriptRoot\ExitPolicy.ps1"
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\Probe.ps1",[ref]$tokens,[ref]$errors)
if($errors){throw ($errors | Out-String)}
$add=$ast.Find({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-Check'},$true)
. ([scriptblock]::Create($add.Extent.Text))
$source=[IO.File]::ReadAllText("$PSScriptRoot\Probe.ps1")
$start=$source.IndexOf(' try{$r=Fetch')
$end=$source.IndexOf(' foreach($entry', $start)
$exitChecks=[scriptblock]::Create($source.Substring($start,$end-$start))
$desired=[pscustomobject]@{exitIp='192.0.2.1';localProxy='http://127.0.0.1:12460'}
$Quarantined=$false
function Fetch($Url,$Proxy){
 if($script:scenario -eq 'timeout'){throw [TimeoutException]::new('Synthetic timeout')}
 if($script:scenario -eq 'http-error'){throw [Net.WebException]::new('Synthetic HTTP error')}
 $ip=switch($script:scenario){'mismatch'{'192.0.2.2'} 'missing'{$null} default{'192.0.2.1'}}
 $port=if($script:scenario -eq 'peer'){9999}else{12460}
 return [pscustomobject]@{ip=$ip;proxy=[pscustomobject]@{ip=$ip};exitIP=$ip;proxyPeer=[pscustomobject]@{port=$port}}
}
foreach($script:scenario in @('normal','timeout','http-error','missing','mismatch','peer','firewall')){
 $checks=[Collections.Generic.List[object]]::new()
 . $exitChecks
 if($script:scenario -eq 'firewall'){Add-Check 'Firewall:disabled' $false}
 $summary=Get-HealthSummary $checks
 $mustLock=$script:scenario -in @('mismatch','peer','firewall')
 if((-not $summary.Healthy) -ne $mustLock){throw "Wrong lock decision: $script:scenario"}
 if($script:scenario -in @('timeout','http-error','missing') -and $summary.Warnings.Count -ne 2){throw 'Both exit paths must show warnings'}
 Write-Output "PASS $script:scenario"
}
