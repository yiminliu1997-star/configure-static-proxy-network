# Generates local policy input only; does not install or remove WFP filters.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$config=Get-Content "$root\config.json" -Raw -Encoding UTF8|ConvertFrom-Json
$targets=(Get-Content (Join-Path $config.RuntimeRoot 'EgressGuard\targets.json') -Raw -Encoding UTF8|ConvertFrom-Json).Targets
$lines=@($targets | Where-Object {$_.Label -notmatch 'Microsoft Edge|Google Chrome'} | ForEach-Object {
 if(-not (Test-Path -LiteralPath $_.Path -PathType Leaf)){throw 'Protected executable missing'}
 $ports=if($_.Label -like '*Router*'){'12460'}elseif($_.Label -like 'Claude Code*'){'12460,18791'}else{'12460'}
 $_.Path+"`t"+$ports
})
if(-not $lines.Count){throw 'No protected targets'}
if(Test-Path "$PSScriptRoot\targets.tsv"){throw 'Existing manifest preserved; review before replacing'}
[IO.File]::WriteAllLines("$PSScriptRoot\targets.tsv",$lines,[Text.UTF8Encoding]::new($false))
Write-Output 'Manifest prepared. Review local application dependencies before installation.'
