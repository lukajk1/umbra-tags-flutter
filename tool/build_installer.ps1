param(
    [string]$BundleDirectory,
    [string]$OutputDirectory,
    [string]$IsccPath,
    [string]$FlutterCommand = 'flutter'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $IsccPath) {
    $compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($compiler) { $IsccPath = $compiler.Source }
    else { $IsccPath = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe' }
}
if (-not (Test-Path -LiteralPath $IsccPath)) { throw 'Install Inno Setup 6 or supply -IsccPath.' }
$versionMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)')
if (-not $versionMatch.Success) { throw 'Could not read app version from pubspec.yaml.' }
$version = $versionMatch.Groups[1].Value
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $BundleDirectory) {
    Push-Location $projectRoot
    try {
        & $FlutterCommand build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Flutter release build failed.' }
        $BundleDirectory = Join-Path $projectRoot "dist/UmbraTags-windows-$stamp"
        & (Join-Path $PSScriptRoot 'package_windows.ps1') -OutputDirectory $BundleDirectory
    } finally { Pop-Location }
}
$bundle = (Resolve-Path -LiteralPath $BundleDirectory).Path
foreach ($file in @('flutter_gallery_test.exe', 'flutter_windows.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'umbra-tags-ml/python/python.exe', 'umbra-tags-ml/runner.py', 'umbra-tags-ml/models/siglip2-base-224/bundle.json', 'umbra-tags-ml/models/siglip2-text-224/bundle.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundle $file))) { throw "Incomplete offline bundle: missing $file" }
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot "dist/installer-$stamp" }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Installer output directory already exists. Choose a new folder.' }
New-Item -ItemType Directory -Path $output | Out-Null
& $IsccPath /Q "/DBundleDir=$bundle" "/DOutputDir=$output" "/DAppVersion=$version" (Join-Path $PSScriptRoot 'installer.iss')
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed.' }
Write-Output "Installer built in $output. Keep the setup EXE and all accompanying BIN files together."
