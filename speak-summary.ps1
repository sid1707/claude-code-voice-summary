# speak-summary.ps1
# Runs automatically after every Claude Code reply (a "Stop" hook).
# It finds or makes a short plain-English summary of the reply and reads it aloud.
#
# Where the summary comes from, in order:
#   1. The "In plain words:" section at the end of the reply (added by the Plain Words style).
#   2. If the reply is short, the reply itself.
#   3. Otherwise, a quick summary written by Claude Haiku (needs the "claude" command).
#   4. If that fails, the first couple of sentences of the reply.

#
# The voice itself (OpenAI, Azure or Windows) is chosen with choose-voice.bat
# and handled in voice-engines.ps1.

$MaxSeconds = 90   # give up waiting for a summary after this many seconds

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'voice-engines.ps1')
$Utf8      = New-Object System.Text.UTF8Encoding $false
$ClaudeDir = Join-Path $env:USERPROFILE '.claude'
$HookDir   = Join-Path $ClaudeDir 'hooks'
$LogFile   = Join-Path $HookDir 'voice-summary.log'
$LastFile  = Join-Path $ClaudeDir 'last-summary.txt'
$OffFlag   = Join-Path $ClaudeDir 'voice-summary-off'
$NoHooks   = Join-Path $HookDir 'no-hooks.json'

$SummaryInstructions = @'
You are writing a short spoken update for someone who is building software with an AI coding assistant but has no programming background. Below is the assistant's latest message.

Rewrite it as 2 to 4 short sentences, under 70 words, that will be read aloud:
- what was done or found, in everyday words (what the person would see or notice in the app);
- whether the person needs to do or decide anything - if the assistant asked a question, state that question clearly;
- what happens next.

No jargon, file names, code, symbols, lists or markdown. If a technical idea is essential, explain it with a simple everyday comparison. Output only the spoken text, nothing else.

----- ASSISTANT MESSAGE START -----
'@

function Write-Log([string]$msg) {
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 200KB)) { Remove-Item $LogFile -Force }
        Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 's'), $msg) -Encoding UTF8
    } catch {}
}

function ConvertTo-SpeakableText([string]$t) {
    if (-not $t) { return '' }
    $t = [regex]::Replace($t, '(?s)```.*?```', ' ')                 # code blocks
    $t = [regex]::Replace($t, '\[([^\]]+)\]\([^)]+\)', '$1')         # [text](link) -> text
    $t = [regex]::Replace($t, 'https?://\S+', 'a link')               # bare links
    $t = [regex]::Replace($t, '(?m)^\s*#+\s*', '')                    # headings
    $t = [regex]::Replace($t, '(?m)^\s*([-*+]|\d+\.)\s+', '')         # bullets and numbers
    $t = $t -replace '[*_`>|#]', ''                                   # leftover markdown symbols
    $t = [regex]::Replace($t, '\s+', ' ')
    return $t.Trim()
}

function Get-FirstSentences([string]$t, [int]$maxChars) {
    if ($t.Length -le $maxChars) { return $t }
    $cut = $t.Substring(0, $maxChars)
    $end = $cut.LastIndexOfAny([char[]]'.!?')
    if ($end -gt 40) { return $cut.Substring(0, $end + 1) }
    return $cut + '...'
}

function Find-ClaudeCommand {
    $cmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path $env:APPDATA 'npm\claude.cmd'))) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-HaikuSummary([string]$message) {
    $claude = Find-ClaudeCommand
    if (-not $claude) { Write-Log 'claude command not found; using fallback'; return $null }

    if ($message.Length -gt 12000) { $message = $message.Substring(0, 12000) + "`n[message shortened]" }
    $prompt = $SummaryInstructions + "`n" + $message + "`n----- ASSISTANT MESSAGE END -----`n"

    $cliArgs = "-p --model haiku --settings `"$NoHooks`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($claude -match '\.(cmd|bat)$') {
        $psi.FileName  = $env:ComSpec
        $psi.Arguments = "/d /s /c `"`"$claude`" $cliArgs`""
    } else {
        $psi.FileName  = $claude
        $psi.Arguments = $cliArgs
    }
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding  = $Utf8
    $psi.WorkingDirectory       = $env:TEMP
    # Marks the helper run so this script stays silent for it (no endless loop).
    $psi.EnvironmentVariables['VOICE_SUMMARY_CHILD'] = '1'

    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $bytes = $Utf8.GetBytes($prompt)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()

    if (-not $proc.WaitForExit($MaxSeconds * 1000)) {
        try { $proc.Kill() } catch {}
        Write-Log "summary timed out after $MaxSeconds s"
        return $null
    }
    $out = $outTask.Result.Trim()
    if ($proc.ExitCode -ne 0 -or -not $out) {
        Write-Log ("claude exited {0}: {1}" -f $proc.ExitCode, $errTask.Result.Trim())
        return $null
    }
    return $out
}

function Invoke-Speak([string]$text) {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeVoiceSummary')
    $haveLock = $false
    try {
        # One summary at a time: wait for any summary that's still playing.
        try { $haveLock = $mutex.WaitOne(180000) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
        Invoke-VoiceSpeak $text
    } finally {
        if ($haveLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

try {
    if ($env:VOICE_SUMMARY_CHILD -eq '1') { exit 0 }   # the helper summary run itself
    if (Test-Path $OffFlag) { exit 0 }                 # turned off with /voice-off

    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $Utf8)
    $raw = $reader.ReadToEnd()
    if (-not $raw.Trim()) { exit 0 }
    $data = $raw | ConvertFrom-Json
    $message = [string]$data.last_assistant_message
    if ([string]::IsNullOrWhiteSpace($message)) { exit 0 }

    $spoken = $null
    # The last line that starts with "In plain words" (the heading), and everything after it.
    $plain = [regex]::Match($message, '^\W*in plain words\W*',
        [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Multiline, RightToLeft')
    if ($plain.Success) {
        $spoken = ConvertTo-SpeakableText $message.Substring($plain.Index + $plain.Length)
    }
    if (-not $spoken) {
        $clean = ConvertTo-SpeakableText $message
        if ($clean.Length -le 300) {
            $spoken = $clean
        } else {
            $summary = Get-HaikuSummary $message
            if ($summary) {
                $spoken = ConvertTo-SpeakableText $summary
            } else {
                $spoken = 'Claude has replied. It begins: ' + (Get-FirstSentences $clean 280)
            }
        }
    }
    if (-not $spoken) { exit 0 }

    try { [System.IO.File]::WriteAllText($LastFile, $spoken, $Utf8) } catch {}
    Invoke-Speak $spoken
} catch {
    Write-Log ("error: " + $_.Exception.Message)
}
exit 0
