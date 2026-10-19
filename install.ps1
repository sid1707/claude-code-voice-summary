# install.ps1 - sets up "Plain Words" + spoken summaries for Claude Code on Windows.
# Run it by double-clicking install.bat (or uninstall.bat to remove everything).
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 can wrap arrays as {value, Count} in JSON; this keeps settings.json clean.
Remove-TypeData System.Array -ErrorAction SilentlyContinue
$Here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Utf8       = New-Object System.Text.UTF8Encoding $false
$ClaudeDir  = Join-Path $env:USERPROFILE '.claude'
$HookDir    = Join-Path $ClaudeDir 'hooks'
$StyleDir   = Join-Path $ClaudeDir 'output-styles'
$SkillsDir  = Join-Path $ClaudeDir 'skills'
$Settings   = Join-Path $ClaudeDir 'settings.json'
$HookScript = Join-Path $HookDir 'speak-summary.ps1'
$StyleName  = 'Plain Words'

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }

function Read-Settings {
    if (Test-Path $Settings) {
        $text = [System.IO.File]::ReadAllText($Settings)
        if ($text.Trim()) {
            try { return ($text | ConvertFrom-Json) }
            catch { throw "Your Claude Code settings file isn't valid JSON, so I left it untouched: $Settings" }
        }
    }
    return New-Object PSObject
}

function Save-Settings($obj) {
    if (Test-Path $Settings) {
        $backup = "$Settings.backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $Settings $backup
        Say "  Backed up your old settings to $backup"
    }
    $json = $obj | ConvertTo-Json -Depth 50
    [System.IO.File]::WriteAllText($Settings, $json, $Utf8)
}

function Remove-OurHook($obj) {
    if ($obj.PSObject.Properties['hooks'] -and $obj.hooks -and $obj.hooks.PSObject.Properties['Stop']) {
        $kept = @($obj.hooks.Stop | Where-Object {
            -not (($_ | ConvertTo-Json -Depth 20 -Compress) -match 'speak-summary\.ps1')
        })
        if ($kept.Count -gt 0) {
            $obj.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue $kept -Force
        } else {
            $obj.hooks.PSObject.Properties.Remove('Stop')
        }
        if (@($obj.hooks.PSObject.Properties).Count -eq 0) { $obj.PSObject.Properties.Remove('hooks') }
    }
}

try {
    Write-Host ''
    if ($Uninstall) {
        Say 'Removing Plain Words + voice summaries...' 'Cyan'
        $cfg = Read-Settings
        Remove-OurHook $cfg
        if ($cfg.PSObject.Properties['outputStyle'] -and $cfg.outputStyle -eq $StyleName) {
            $cfg.PSObject.Properties.Remove('outputStyle')
        }
        Save-Settings $cfg
        foreach ($f in @(
            $HookScript,
            (Join-Path $HookDir 'voice-engines.ps1'),
            (Join-Path $HookDir 'choose-voice.ps1'),
            (Join-Path $HookDir 'setup-kokoro.ps1'),
            (Join-Path $HookDir 'kokoro-speak.py'),
            (Join-Path $HookDir 'voice-config.json'),
            (Join-Path $HookDir 'no-hooks.json'),
            (Join-Path $StyleDir 'plain-words.md'),
            (Join-Path $ClaudeDir 'voice-summary-off'),
            (Join-Path $ClaudeDir 'last-summary.txt'))) {
            if (Test-Path $f) { Remove-Item $f -Force }
        }
        foreach ($s in 'voice-on', 'voice-off') {
            $d = Join-Path $SkillsDir $s
            if (Test-Path $d) { Remove-Item $d -Recurse -Force }
        }
        $kokoroDir = Join-Path $ClaudeDir 'kokoro'
        if (Test-Path $kokoroDir) {
            Remove-Item $kokoroDir -Recurse -Force
            Say '  Removed the Kokoro voice files.'
        }
        Say 'Done. Close and reopen Claude Code to finish.' 'Green'
        exit 0
    }

    Say 'Installing Plain Words + voice summaries for Claude Code...' 'Cyan'

    # 1. Copy the files into your .claude folder
    New-Item -ItemType Directory -Force -Path $HookDir, $StyleDir | Out-Null
    Copy-Item (Join-Path $Here 'speak-summary.ps1') $HookScript -Force
    Copy-Item (Join-Path $Here 'voice-engines.ps1') (Join-Path $HookDir 'voice-engines.ps1') -Force
    Copy-Item (Join-Path $Here 'choose-voice.ps1') (Join-Path $HookDir 'choose-voice.ps1') -Force
    Copy-Item (Join-Path $Here 'setup-kokoro.ps1') (Join-Path $HookDir 'setup-kokoro.ps1') -Force
    Copy-Item (Join-Path $Here 'kokoro-speak.py') (Join-Path $HookDir 'kokoro-speak.py') -Force
    $kokoroScript = Join-Path (Join-Path $ClaudeDir 'kokoro') 'kokoro-speak.py'
    if (Test-Path $kokoroScript) { Copy-Item (Join-Path $Here 'kokoro-speak.py') $kokoroScript -Force }
    [System.IO.File]::WriteAllText((Join-Path $HookDir 'no-hooks.json'), '{ "disableAllHooks": true }', $Utf8)
    Copy-Item (Join-Path $Here 'plain-words.md') (Join-Path $StyleDir 'plain-words.md') -Force
    foreach ($s in 'voice-on', 'voice-off') {
        $d = Join-Path $SkillsDir $s
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Copy-Item (Join-Path $Here "skills\$s\SKILL.md") (Join-Path $d 'SKILL.md') -Force
    }
    try { Get-ChildItem $HookDir, $StyleDir -File | Unblock-File } catch {}
    Say '  Copied the files.'

    # 2. Turn on the style and the voice hook in settings.json (keeping everything else)
    $cfg = Read-Settings
    Remove-OurHook $cfg
    $entry = New-Object PSObject -Property @{
        hooks = @(
            (New-Object PSObject -Property ([ordered]@{
                type    = 'command'
                command = 'powershell.exe'
                args    = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $HookScript)
                async   = $true
            }))
        )
    }
    if (-not $cfg.PSObject.Properties['hooks'] -or -not $cfg.hooks) {
        $cfg | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject) -Force
    }
    $existing = @()
    if ($cfg.hooks.PSObject.Properties['Stop']) { $existing = @($cfg.hooks.Stop) }
    $cfg.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue (@($existing) + $entry) -Force

    if ($cfg.PSObject.Properties['outputStyle'] -and $cfg.outputStyle -and $cfg.outputStyle -ne $StyleName) {
        Say ("  Note: your previous output style was '" + $cfg.outputStyle + "'. Switching to Plain Words.") 'Yellow'
    }
    $cfg | Add-Member -NotePropertyName outputStyle -NotePropertyValue $StyleName -Force
    Save-Settings $cfg
    Say '  Updated Claude Code settings.'

    # 3. Check for the claude command (used only when a reply has no "In plain words" section)
    $cli = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue
    if (-not $cli) {
        foreach ($p in @((Join-Path $env:USERPROFILE '.local\bin\claude.exe'), (Join-Path $env:APPDATA 'npm\claude.cmd'))) {
            if (Test-Path $p) { $cli = $p }
        }
    }
    if ($cli) {
        Say '  Found the claude command, so long replies can be summarised too.'
    } else {
        Say '  Could not find the "claude" command on this PC.' 'Yellow'
        Say '  Voice still works: it reads the "In plain words" part of each reply.' 'Yellow'
        Say '  For summaries of replies without that part, install it by pasting this into PowerShell:' 'Yellow'
        Say '      irm https://claude.ai/install.ps1 | iex' 'White'
    }

    # 4. Test the voice
    Say '  Testing the voice now - you should hear it in your headphones.'
    try {
        . (Join-Path $HookDir 'voice-engines.ps1')
        Invoke-VoiceSpeak 'Voice summaries are ready.'
    } catch {
        Say ('  Could not play the test sound: ' + $_.Exception.Message) 'Yellow'
        Say '  Everything else is installed. Check your speakers or headphones.' 'Yellow'
    }

    Write-Host ''
    Say 'All set! Close Claude Code completely and open it again.' 'Green'
    Say 'Type /voice-off or /voice-on in Claude Code to mute or unmute.' 'Green'
    Say ('The last summary is always saved in ' + (Join-Path $ClaudeDir 'last-summary.txt')) 'Green'
    Write-Host ''
    $choose = Read-Host 'Would you like to choose a more natural voice now? (Y/N)'
    if ($choose -match '^[Yy]') { & (Join-Path $Here 'choose-voice.ps1') }
    else { Say 'You can do it later by double-clicking choose-voice.bat.' 'Gray' }
} catch {
    Write-Host ''
    Say ('Something went wrong: ' + $_.Exception.Message) 'Red'
    exit 1
}
