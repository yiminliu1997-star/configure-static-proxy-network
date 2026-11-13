$ErrorActionPreference='Stop'
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if(-not (Test-Path $vswhere)){throw 'Visual Studio Build Tools with C++ tools and Windows SDK are required'}
$vs=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'C++ build tools not found'}
$vc=Get-ChildItem (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$sdk=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=Get-ChildItem "$sdk\Include" -Directory | Where-Object {Test-Path (Join-Path $_.FullName 'um\fwpmu.h')} | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1 -ExpandProperty Name
if(-not $version){throw 'Windows SDK not found'}
Push-Location $PSScriptRoot
try {
 & "$($vc.FullName)\bin\Hostx64\x64\cl.exe" /nologo /EHsc /std:c++17 /W4 /DUNICODE /D_UNICODE /D_SILENCE_CXX17_CODECVT_HEADER_DEPRECATION_WARNING "/I$($vc.FullName)\include" "/I$sdk\Include\$version\ucrt" "/I$sdk\Include\$version\shared" "/I$sdk\Include\$version\um" LoopbackGuard.cpp /Fe:LoopbackGuard.exe /link "/LIBPATH:$($vc.FullName)\lib\x64" "/LIBPATH:$sdk\Lib\$version\ucrt\x64" "/LIBPATH:$sdk\Lib\$version\um\x64"
 if($LASTEXITCODE){throw 'Compilation failed'}
}finally{Pop-Location}
