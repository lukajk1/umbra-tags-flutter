param(
    [ValidateSet('App','Full','Runtime')][string]$Mode = 'App',
    [string]$BundleDirectory,
    [string]$OutputDirectory,
    [string]$IsccPath,
    [string]$FlutterCommand = 'flutter',
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$mlRoot = Join-Path (Split-Path -Parent $projectRoot) 'umbra-tags-ml'
if (-not $IsccPath) {
    $compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($compiler) { $IsccPath = $compiler.Source }
    else { $IsccPath = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe' }
}
if (-not (Test-Path -LiteralPath $IsccPath)) { throw 'Install Inno Setup 6 or supply -IsccPath.' }
$versionMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)')
if (-not $versionMatch.Success) { throw 'Could not read app version from pubspec.yaml.' }
$version = $versionMatch.Groups[1].Value
$runtimeId = (Get-Content -LiteralPath (Join-Path $mlRoot 'runtime-requirements.json') -Raw | ConvertFrom-Json).runtimeId
if ($runtimeId -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Invalid runtime ID.' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $BundleDirectory) {
    Push-Location $projectRoot
    try {
        if ($Mode -ne 'Runtime' -and -not $SkipBuild) {
            & $FlutterCommand build windows --release
            if ($LASTEXITCODE -ne 0) { throw 'Flutter release build failed.' }
        }
        $BundleDirectory = Join-Path $projectRoot "dist/UmbraTags-$Mode-$stamp"
        & (Join-Path $PSScriptRoot 'package_windows.ps1') -OutputDirectory $BundleDirectory -Mode $Mode
    } finally { Pop-Location }
}
$bundle = (Resolve-Path -LiteralPath $BundleDirectory).Path
$requiredFiles = @()
if ($Mode -ne 'Runtime') {
    $requiredFiles += @('flutter_gallery_test.exe','flutter_windows.dll','msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll','umbra-tags-ml/runner.py','umbra-tags-ml/runtime_paths.py','umbra-tags-ml/runtime-requirements.json')
}
if ($Mode -ne 'App') {
    $requiredFiles += @('umbra-tags-ml/python/python.exe','umbra-tags-ml/ml-runtime.json','umbra-tags-ml/best_model.pth','umbra-tags-ml/model.pth','umbra-tags-ml/models/siglip2-base-224/bundle.json','umbra-tags-ml/models/siglip2-text-224/bundle.json')
}
foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundle $file))) { throw "Incomplete $Mode bundle: missing $file" }
}
if ($Mode -ne 'Runtime') {
    $actual = Get-Content -LiteralPath (Join-Path $bundle 'umbra-tags-ml/runtime-requirements.json') -Raw | ConvertFrom-Json
    if ($actual.runtimeId -ne $runtimeId) { throw 'App bundle requires a different runtime version. Repackage it.' }
}
if ($Mode -ne 'App') {
    $actual = Get-Content -LiteralPath (Join-Path $bundle 'umbra-tags-ml/ml-runtime.json') -Raw | ConvertFrom-Json
    if ($actual.runtimeId -ne $runtimeId) { throw 'Runtime bundle version does not match the app.' }
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot "dist/installer-$Mode-$stamp" }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Installer output directory already exists. Choose a new folder.' }
New-Item -ItemType Directory -Path $output | Out-Null
$script = if ($Mode -eq 'Runtime') { 'runtime_installer.iss' } else { 'installer.iss' }
& $IsccPath /Q "/DBundleDir=$bundle" "/DOutputDir=$output" "/DAppVersion=$version" "/DMode=$Mode" "/DRuntimeId=$runtimeId" (Join-Path $PSScriptRoot $script)
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed.' }
Write-Output "$Mode installer built in $output. Keep any accompanying BIN files beside its EXE."
