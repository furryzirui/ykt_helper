$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$installation) { throw 'MSVC C++ build tools are required' }
& (Join-Path $installation 'Common7/Tools/Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
$output = Join-Path ([IO.Path]::GetTempPath()) ('ykt-autostart-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $output | Out-Null
try {
  $source = Join-Path $repoRoot 'test/native/windows_autostart_test.cpp'
  $executable = Join-Path $output 'windows_autostart_test.exe'
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /utf-8 /DUNICODE /D_UNICODE $source "/Fo$output/" "/Fe$executable" /link advapi32.lib
  if ($LASTEXITCODE -ne 0) { throw 'Windows autostart test compilation failed' }
  & $executable
  if ($LASTEXITCODE -ne 0) { throw 'Windows autostart test failed' }
} finally {
  # Only remove the exact test-owned temporary directory.
  $resolvedOutput = [IO.Path]::GetFullPath($output)
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if (!$resolvedOutput.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
      !(Split-Path $resolvedOutput -Leaf).StartsWith('ykt-autostart-tests-')) {
    throw 'Unexpected test output path'
  }
  Remove-Item -LiteralPath $resolvedOutput -Recurse -Force
}
