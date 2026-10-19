# setup-kokoro.ps1 - one-time setup of the free, open-source Kokoro voice on this PC.
# choose-voice.bat runs this for you when you pick Kokoro. Safe to run again.
#
# What it does:
#   1. Finds Python 3.10-3.13 (or offers to install Python 3.12 for you).
#   2. Makes a private Python environment in  %USERPROFILE%\.claude\kokoro\venv
#   3. Installs the kokoro-onnx package into it.
#   4. Downloads the Kokoro model and voices (about 350 MB) from the official project page.
#   5. Tests that it can speak.

# Native programs (python, pip, winget) write progress to stderr; don't treat that as a failure.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'   # much faster downloads in Windows PowerShell

$KokoroDir = Join-Path (Join-Path $env:USERPROFILE '.claude') 'kokoro'
$VenvDir   = Join-Path $KokoroDir 'venv'
$VenvPy    = Join-Path $VenvDir 'Scripts\python.exe'
$Script    = Join-Path $KokoroDir 'kokoro-speak.py'
$ModelUrl  = 'https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx'
$VoicesUrl = 'https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin'
$Model     = Join-Path $KokoroDir 'kokoro-v1.0.onnx'
$Voices    = Join-Path $KokoroDir 'voices-v1.0.bin'

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Fail([string]$text) { Say ''; Say $text 'Red'; exit 1 }

function Test-PythonOk([string]$exe) {
    if (-not $exe -or -not (Test-Path $exe)) { return $false }
    $out = & $exe -c "import sys, venv; print((3,10) <= sys.version_info[:2] < (3,14))" 2>$null
    return ($LASTEXITCODE -eq 0 -and "$out".Trim() -eq 'True')
}

function Find-Python {
    # 1. The Python launcher ("py"), asking for a suitable version
    $py = $null
    $cmd = Get-Command py -ErrorAction SilentlyContinue
    if ($cmd) { $py = $cmd.Source }
    else {
        $p = Join-Path $env:LOCALAPPDATA 'Programs\Python\Launcher\py.exe'
        if (Test-Path $p) { $py = $p }
    }
    if ($py) {
        foreach ($v in '3.12', '3.11', '3.13', '3.10') {
            $exe = & $py "-$v" -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $exe -and (Test-PythonOk "$exe".Trim())) { return "$exe".Trim() }
        }
    }
    # 2. Usual install folders
    foreach ($v in '312', '311', '313', '310') {
        foreach ($root in @((Join-Path $env:LOCALAPPDATA 'Programs\Python'), $env:ProgramFiles)) {
            if (-not $root) { continue }
            $exe = Join-Path $root "Python$v\python.exe"
            if (Test-PythonOk $exe) { return $exe }
        }
    }
    # 3. "python" on the PATH
    $cmd = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        $exe = & $cmd.Source -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe -and (Test-PythonOk "$exe".Trim())) { return "$exe".Trim() }
    }
    return $null
}

Write-Host ''
Say 'Setting up the Kokoro voice (one time only)...' 'Cyan'
New-Item -ItemType Directory -Force -Path $KokoroDir | Out-Null

# 1. Python
Say '1/5  Looking for Python...'
$python = Find-Python
if (-not $python) {
    Say '     Kokoro needs Python (a free programming tool), version 3.10 to 3.13. It is not on this PC yet.' 'Yellow'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        $ok = Read-Host '     Install Python 3.12 now, just for your user account? (Y/N)'
        if ($ok -notmatch '^[Yy]') { Fail 'Stopped. Nothing else was changed.' }
        & $winget.Source install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
        $python = Find-Python
    }
    if (-not $python) {
        Fail ("Please install Python 3.12 from https://www.python.org/downloads/ " +
              "(tick 'Add python.exe to PATH' during install), then run choose-voice.bat again.")
    }
}
Say "     Using $python" 'DarkGray'

# 2. Private environment
if (-not (Test-Path $VenvPy)) {
    Say '2/5  Creating a private Python environment...'
    & $python -m venv $VenvDir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $VenvPy)) { Fail 'Could not create the Python environment.' }
} else {
    Say '2/5  Private Python environment already exists.'
}

# 3. Kokoro package
Say '3/5  Installing Kokoro (a few minutes)...'
& $VenvPy -m pip install --disable-pip-version-check --quiet --upgrade 'kokoro-onnx>=0.5,<0.7'
if ($LASTEXITCODE -ne 0) { Fail 'Installing the kokoro-onnx package failed. Check your internet connection and try again.' }

# 4. Model files
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
function Get-BigFile([string]$url, [string]$dest, [long]$minBytes, [string]$label) {
    if ((Test-Path $dest) -and (Get-Item $dest).Length -ge $minBytes) { Say "     $label already downloaded."; return }
    Say "     Downloading $label... (please wait, no progress bar)"
    $part = "$dest.part"
    try { Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing -ErrorAction Stop }
    catch { Fail ("Download failed: " + $_.Exception.Message) }
    if ((Get-Item $part).Length -lt $minBytes) { Remove-Item $part -Force; Fail "The $label download was incomplete. Please try again." }
    Move-Item $part $dest -Force
}
Say '4/5  Getting the voice model (about 350 MB)...'
Get-BigFile $ModelUrl  $Model  300MB 'the voice model (325 MB)'
Get-BigFile $VoicesUrl $Voices 25MB  'the voices (28 MB)'
Copy-Item (Join-Path $PSScriptRoot 'kokoro-speak.py') $Script -Force

# 5. Test
Say '5/5  Testing...'
$testWav = Join-Path $KokoroDir 'setup-test.wav'
'Kokoro is ready.' | & $VenvPy $Script --model $Model --voices $Voices --voice af_heart --out $testWav
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $testWav)) { Fail 'Kokoro was installed but the test failed. The message above says why.' }
Remove-Item $testWav -Force -ErrorAction SilentlyContinue

Say ''
Say 'Kokoro is set up.' 'Green'
exit 0
