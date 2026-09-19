param([string]$OutputDirectory, [string]$VcRuntimeDirectory)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$mlRoot = Join-Path (Split-Path -Parent $projectRoot) 'umbra-tags-ml'
$releaseRoot = Join-Path $projectRoot 'build/windows/x64/runner/Release'
$venvPython = Join-Path $mlRoot '.venv/Scripts/python.exe'
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $projectRoot ('dist/UmbraTags-windows-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$destination = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $destination) { throw "Output folder already exists: $destination. Choose a new folder." }
if (-not $VcRuntimeDirectory) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $vsRoot = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
        if ($vsRoot) {
            $redistRoot = Join-Path $vsRoot 'VC/Redist/MSVC'
            $VcRuntimeDirectory = Get-ChildItem -LiteralPath $redistRoot -Directory |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
                Sort-Object { [version]$_.Name } -Descending |
                ForEach-Object { Join-Path $_.FullName 'x64/Microsoft.VC143.CRT' } |
                Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        }
    }
}
foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not $VcRuntimeDirectory -or -not (Test-Path -LiteralPath (Join-Path $VcRuntimeDirectory $dll))) {
        throw "Missing Visual C++ redistributable DLL $dll. Supply -VcRuntimeDirectory pointing to the x64 Microsoft.VC143.CRT folder."
    }
}
foreach ($required in @((Join-Path $releaseRoot 'flutter_gallery_test.exe'), $venvPython, (Join-Path $mlRoot 'models/siglip2-base-224/bundle.json'), (Join-Path $mlRoot 'models/siglip2-text-224/bundle.json'))) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing $required. Build the release app and prepare the bundled model first." }
}
$pythonBase = (& $venvPython -c 'import sys; print(sys.base_prefix)').Trim()
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $pythonBase 'python.exe'))) { throw 'Could not locate the base Python runtime.' }
function Copy-Tree([string]$Source, [string]$Target, [string[]]$Exclusions = @()) {
    $options = @($Source, $Target, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1', '/XF', '*.pyc', '_virtualenv.pth', '_virtualenv.py')
    if ($Exclusions.Count) { $options += '/XD'; $options += $Exclusions }
    & robocopy @options | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copy failed: $Source" }
}
New-Item -ItemType Directory -Path $destination | Out-Null
Copy-Tree $releaseRoot $destination
Get-ChildItem -LiteralPath $VcRuntimeDirectory -Filter '*.dll' -File | Copy-Item -Destination $destination
$bundledMl = Join-Path $destination 'umbra-tags-ml'
$bundledPython = Join-Path $bundledMl 'python'
New-Item -ItemType Directory -Path $bundledPython -Force | Out-Null
foreach ($name in @('runner.py','embedding_worker.py','embedding.json','tag_worker.py','tagging.json','tag_vocabulary.json','models.json','requirements.txt','README.md','best_model.pth','model.pth')) {
    Copy-Item -LiteralPath (Join-Path $mlRoot $name) -Destination $bundledMl
}
Copy-Tree (Join-Path $mlRoot 'ml_adapters') (Join-Path $bundledMl 'ml_adapters')
Copy-Tree (Join-Path $mlRoot 'models') (Join-Path $bundledMl 'models')
Get-ChildItem -LiteralPath $pythonBase -File | Where-Object { $_.Extension -in '.exe','.dll' -or $_.Name -eq 'LICENSE.txt' } | Copy-Item -Destination $bundledPython
Copy-Tree (Join-Path $pythonBase 'DLLs') (Join-Path $bundledPython 'DLLs')
Copy-Tree (Join-Path $pythonBase 'Lib') (Join-Path $bundledPython 'Lib') @((Join-Path $pythonBase 'Lib/site-packages'))
Copy-Tree (Join-Path $mlRoot '.venv/Lib/site-packages') (Join-Path $bundledPython 'Lib/site-packages')
Get-ChildItem -LiteralPath $VcRuntimeDirectory -Filter '*.dll' -File | Copy-Item -Destination $bundledPython
$pythonVersion = (& $venvPython -c 'import sys; print(str(sys.version_info.major)+str(sys.version_info.minor))').Trim()
@('.', 'Lib', 'DLLs', 'Lib\site-packages', 'import site') | Set-Content -LiteralPath (Join-Path $bundledPython "python$pythonVersion._pth") -Encoding ascii
@'
Umbra Tags for Windows

Run flutter_gallery_test.exe. Keep this folder's files together.
Python, the classifiers, and SigLIP 2 vision and text weights are included.
No model download or Python installation is required. AI inference runs locally.
Model attribution and licenses: umbra-tags-ml/models/.
Dependencies retain their license files in umbra-tags-ml/python/Lib/site-packages.
'@ | Set-Content -LiteralPath (Join-Path $destination 'START-HERE.txt') -Encoding utf8
Write-Output "Packaged offline Windows app: $destination"
