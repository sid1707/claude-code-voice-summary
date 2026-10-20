# check-voice.ps1 - checks the voice summary set-up and writes a report to your Desktop.
# Run it by double-clicking check-voice.bat. It changes nothing, except playing one test summary.
# The report contains no API keys.

$ErrorActionPreference = 'Continue'
$Utf8 = New-Object System.Text.UTF8Encoding $false
$lines = New-Object System.Collections.Generic.List[string]
function Add([string]$text) { $lines.Add($text); Write-Host $text }

$ClaudeDir = Join-Path $env:USERPROFILE '.claude'
if ($env:CLAUDE_CONFIG_DIR) { $ClaudeDir = $env:CLAUDE_CONFIG_DIR }
$HookDir  = Join-Path $ClaudeDir 'hooks'
$Settings = Join-Path $ClaudeDir 'settings.json'
$LogFile  = Join-Path $HookDir 'voice-summary.log'

Add '=== Claude Code voice summary check ==='
Add ("Time:        " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add ("Windows:     " + [Environment]::OSVersion.VersionString)
Add ("PowerShell:  " + $PSVersionTable.PSVersion)
if ($env:CLAUDE_CONFIG_DIR) { Add ("CLAUDE_CONFIG_DIR is set to: " + $env:CLAUDE_CONFIG_DIR) }
Add ("Claude folder: " + $ClaudeDir + "   (exists: " + (Test-Path $ClaudeDir) + ")")
Add ''

Add '--- Installed files ---'
foreach ($f in @(
    'hooks\speak-summary.ps1', 'hooks\voice-engines.ps1', 'hooks\choose-voice.ps1',
    'hooks\setup-kokoro.ps1', 'hooks\kokoro-speak.py', 'hooks\voice-config.json',
    'output-styles\plain-words.md', 'skills\voice-on\SKILL.md', 'skills\voice-off\SKILL.md')) {
    $p = Join-Path $ClaudeDir $f
    $state = 'missing'
    if (Test-Path $p) { $state = 'ok, changed ' + (Get-Item $p).LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
    Add ("  {0,-32} {1}" -f $f, $state)
}
$version = 'unknown'
$hookScript = Join-Path $HookDir 'speak-summary.ps1'
if (Test-Path $hookScript) {
    if (Select-String -Path $hookScript -Pattern 'Get-NotificationSpeech' -Quiet) { $version = '1.1 or newer' } else { $version = '1.0' }
}
Add ("  Hook version: " + $version)
if (Test-Path (Join-Path $ClaudeDir 'voice-summary-off')) { Add '  !! MUTED: voice is turned off (/voice-off). Type /voice-on in Claude Code.' }
Add ''

Add '--- Claude Code settings ---'
if (Test-Path $Settings) {
    try {
        $cfg = [System.IO.File]::ReadAllText($Settings) | ConvertFrom-Json
        Add ("  outputStyle:     " + $cfg.outputStyle)
        if ($cfg.PSObject.Properties['disableAllHooks'] -and $cfg.disableAllHooks) { Add '  !! disableAllHooks is ON: no hooks run at all.' }
        foreach ($ev in 'Stop', 'Notification') {
            $found = $false
            if ($cfg.hooks -and $cfg.hooks.PSObject.Properties[$ev]) {
                foreach ($entry in @($cfg.hooks.$ev)) {
                    $json = $entry | ConvertTo-Json -Depth 10 -Compress
                    if ($json -match 'speak-summary') {
                        $found = $true
                        $m = ''
                        if ($entry.PSObject.Properties['matcher']) { $m = ' (matcher: ' + $entry.matcher + ')' }
                        Add ("  {0} hook:  found{1}" -f $ev, $m)
                    }
                }
            }
            if (-not $found) { Add ("  {0} hook:  not found" -f $ev) }
        }
    } catch { Add ('  Could not read settings.json: ' + $_.Exception.Message) }
} else {
    Add ('  settings.json not found at ' + $Settings)
}
Add ''

Add '--- Voice ---'
$vc = Join-Path $HookDir 'voice-config.json'
if (Test-Path $vc) {
    try {
        $v = [System.IO.File]::ReadAllText($vc) | ConvertFrom-Json
        Add ("  Voice service: " + $v.engine)
        foreach ($k in 'kokoro_voice', 'kokoro_speed', 'openai_voice', 'openai_tone', 'azure_voice', 'azure_region', 'windows_voice') {
            if ($v.PSObject.Properties[$k] -and $v.$k) { Add ("  {0}: {1}" -f $k, $v.$k) }
        }
    } catch { Add ('  Could not read voice-config.json: ' + $_.Exception.Message) }
} else { Add '  No voice chosen yet (using the Windows voice).' }
$kd = Join-Path $ClaudeDir 'kokoro'
if (Test-Path $kd) {
    foreach ($f in 'venv\Scripts\python.exe', 'kokoro-speak.py', 'kokoro-v1.0.onnx', 'voices-v1.0.bin') {
        Add ("  Kokoro {0,-24} {1}" -f $f, $(if (Test-Path (Join-Path $kd $f)) { 'ok' } else { 'missing' }))
    }
}
$cl = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
Add ("  claude command: " + $(if ($cl) { $cl.Source } else { 'not found (only needed for replies without a recap)' }))
Add ''

Add '--- Last summary spoken ---'
$last = Join-Path $ClaudeDir 'last-summary.txt'
if (Test-Path $last) {
    Add ('  At ' + (Get-Item $last).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + ':')
    Add ('  ' + [System.IO.File]::ReadAllText($last))
} else { Add '  None yet.' }
Add ''

# Play one test summary through the real hook, exactly as Claude Code would.
if (Test-Path $hookScript) {
    Write-Host ''
    Write-Host 'Playing a test summary now - you should hear it...' -ForegroundColor Cyan
    $test = '{"hook_event_name":"Stop","last_assistant_message":"Test.\n\n**In plain words:** This is a test of your voice summaries."}'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $hookScript + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Write($test)
        $proc.StandardInput.Close()
        $finished = $proc.WaitForExit(120000)
        Add ('--- Test summary --- finished: ' + $finished + ', exit code: ' + $(if ($finished) { $proc.ExitCode } else { 'still running' }))
    } catch { Add ('--- Test summary --- could not run: ' + $_.Exception.Message) }
    Add ''
}

Add '--- Log (last 40 lines) ---'
if (Test-Path $LogFile) {
    Get-Content $LogFile -Tail 40 | ForEach-Object { Add ('  ' + $_) }
} else {
    Add '  No log file yet. Version 1.0 only writes to it when something goes wrong; version 1.1 writes every summary.'
}

$desktop = [Environment]::GetFolderPath('Desktop')
$report = Join-Path $desktop 'voice-summary-report.txt'
[System.IO.File]::WriteAllLines($report, $lines, $Utf8)
Write-Host ''
Write-Host ('Report saved to: ' + $report) -ForegroundColor Green
Write-Host 'You can drag that file into your Claude chat.' -ForegroundColor Green
try { Start-Process notepad.exe -ArgumentList ('"' + $report + '"') } catch {}
