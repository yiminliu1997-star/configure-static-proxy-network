$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    throw 'The x64 .NET Framework C# compiler is required.'
}

$arguments = @(
    '/nologo'
    '/target:winexe'
    '/optimize+'
    '/platform:x64'
    '/codepage:65001'
    '/r:System.Windows.Forms.dll'
    '/r:System.Drawing.dll'
    '/r:System.Web.Extensions.dll'
    '/r:Microsoft.CSharp.dll'
    "/win32icon:$PSScriptRoot\guard-icon.ico"
    "/out:$PSScriptRoot\ClaudeNetworkGuard.exe"
    "$PSScriptRoot\LightGuard.cs"
)
& $compiler @arguments
if ($LASTEXITCODE -ne 0) {
    throw "C# compilation failed with exit code $LASTEXITCODE."
}
New-Item -ItemType Directory -Path "$PSScriptRoot\state" -Force | Out-Null
Copy-Item "$PSScriptRoot\ClaudeNetworkGuard.exe" "$PSScriptRoot\ClaudeNetworkGuard.UI.exe" -Force
