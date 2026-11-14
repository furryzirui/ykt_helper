[CmdletBinding()]
param(
    [string]$BuildDir,
    [string]$OutputDir,
    [string]$InnoSetupCompiler,
    [string]$VisualStudioRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $BuildDir) { $BuildDir = Join-Path $repoRoot 'build/windows/x64/runner/Release' }
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'dist' }
$BuildDir = [System.IO.Path]::GetFullPath($BuildDir)
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

$versionLine = Get-Content -LiteralPath (Join-Path $repoRoot 'pubspec.yaml') |
    Where-Object { $_ -match '^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$' } |
    Select-Object -First 1
if (-not $versionLine -or $versionLine -notmatch '^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$') {
    throw 'pubspec.yaml must contain a semantic version such as 1.0.0+5.'
}
$appVersion = $Matches[1]

foreach ($required in @('ykt_helper.exe', 'flutter_windows.dll', 'WebView2Loader.dll', 'data/icudtl.dat', 'data/flutter_assets')) {
    if (-not (Test-Path -LiteralPath (Join-Path $BuildDir $required))) {
        throw "Missing Windows release component: $required. Run flutter build windows --release first."
    }
}

# Flutter and native plugins link the Visual C++ runtime dynamically. Ship the
# redistributable CRT DLLs beside the application instead of requiring admin.
if (-not $VisualStudioRoot) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $VisualStudioRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($LASTEXITCODE -ne 0) { throw 'vswhere could not inspect the C++ toolchain.' }
        $VisualStudioRoot = [string]($VisualStudioRoot | Select-Object -First 1)
    }
}

$crtDirectory = $null
if ($VisualStudioRoot) {
    $redistRoot = Join-Path $VisualStudioRoot 'VC/Redist/MSVC'
    if (Test-Path -LiteralPath $redistRoot) {
        $versions = Get-ChildItem -LiteralPath $redistRoot -Directory |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_.Name } -Descending
        foreach ($redist in $versions) {
            $x64 = Join-Path $redist.FullName 'x64'
            if (-not (Test-Path -LiteralPath $x64)) { continue }
            $crtDirectory = Get-ChildItem -LiteralPath $x64 -Directory |
                Where-Object { $_.Name -like 'Microsoft.VC*.CRT' } |
                Select-Object -First 1
            if ($crtDirectory) { break }
        }
    }
}
if ($crtDirectory) {
    foreach ($dll in (Get-ChildItem -LiteralPath $crtDirectory.FullName -File -Filter '*.dll')) {
        Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $BuildDir $dll.Name) -Force
    }
}
foreach ($runtime in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $BuildDir $runtime))) {
        throw "Missing $runtime. Install the Visual Studio C++ tools or supply their redist DLLs in BuildDir."
    }
}

if (-not $InnoSetupCompiler) {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6/ISCC.exe')
    )
    $InnoSetupCompiler = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $InnoSetupCompiler) {
        $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
        if ($command) { $InnoSetupCompiler = $command.Source }
    }
}
if (-not $InnoSetupCompiler -or -not (Test-Path -LiteralPath $InnoSetupCompiler)) {
    throw 'Inno Setup 6 was not found. Install it or pass -InnoSetupCompiler <ISCC.exe>.'
}

foreach ($path in @($repoRoot, $BuildDir, $OutputDir)) {
    if ($path.Contains('"')) { throw 'Paths containing double quotes cannot be passed to Inno Setup.' }
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$compilerArguments = @(
    "/DAppVersion=$appVersion",
    "/DBuildDir=$BuildDir",
    "/DOutputDir=$OutputDir",
    "/DRepoRoot=$repoRoot",
    (Join-Path $PSScriptRoot 'installer.iss')
)
& $InnoSetupCompiler @compilerArguments
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE." }
$installer = Join-Path $OutputDir "ykt_helper-$appVersion-windows-setup.exe"
if (-not (Test-Path -LiteralPath $installer)) { throw 'Inno Setup did not create the expected installer.' }
Write-Output $installer
