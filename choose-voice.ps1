# choose-voice.ps1 - pick the voice that reads your Claude Code summaries.
# Run it by double-clicking choose-voice.bat. You can run it again any time to change voice.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'voice-engines.ps1')

$Sample = 'Hi! This is how your Claude Code updates will sound. The login page now works, and nothing is needed from you right now.'

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }

function Select-Option([string]$title, [object[]]$options) {
    Write-Host ''
    Say $title 'Cyan'
    for ($i = 0; $i -lt $options.Count; $i++) { Say ("  {0}) {1}" -f ($i + 1), $options[$i][0]) }
    while ($true) {
        $answer = Read-Host 'Type a number and press Enter'
        $n = 0
        if ([int]::TryParse($answer.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $options.Count) { return $options[$n - 1][1] }
        Say ("Please type a number from 1 to {0}." -f $options.Count) 'Yellow'
    }
}

function Read-Secret([string]$prompt) {
    $secure = Read-Host $prompt -AsSecureString
    if (-not $secure -or $secure.Length -eq 0) { return '' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-Key($cfg, [string]$field, [string]$serviceName, [bool]$forceNew) {
    $hasOld = [bool](Get-CfgValue $cfg $field '')
    while ($true) {
        Write-Host ''
        if ($hasOld -and -not $forceNew) {
            $k = Read-Secret "Paste your $serviceName key (it stays hidden), or just press Enter to keep the saved one"
            if (-not $k) { return }
        } else {
            $k = Read-Secret "Paste your $serviceName key (right-click or Ctrl+V; it stays hidden), then press Enter"
        }
        if ($k) { Set-CfgValue $cfg $field (Protect-VoiceSecret $k); return }
        Say 'Nothing was pasted. Try again.' 'Yellow'
    }
}

function Show-Problem([string]$message) {
    Say ''
    Say "That didn't work." 'Red'
    if ($message -match '401|403|Unauthorized|invalid_api_key|Incorrect API key|Forbidden|Access denied') {
        Say 'The key was not accepted. Check you copied the whole key, with nothing extra.' 'Yellow'
    } elseif ($message -match '429|insufficient_quota|quota|billing') {
        Say 'The account has no credit left or is being rate-limited. Add credit or try again shortly.' 'Yellow'
    } elseif ($message -match 'remote name could not be resolved|Unable to connect|timed out|No such host') {
        Say 'Could not reach the service. Check your internet connection (and the Azure region, if you used Azure).' 'Yellow'
    }
    Say ('Details: ' + $message) 'DarkGray'
}

try {
    $cfg = Get-VoiceConfig
    Say ''
    Say 'Choose the voice for your Claude Code summaries' 'Cyan'
    Say 'Your summaries are sent to the service you pick, which turns them into speech.' 'DarkGray'

    $engine = Select-Option 'Which voice service?' @(
        ,@('Kokoro - free and open-source, natural voice that runs on your own PC. One-time setup (about 450 MB download).', 'kokoro')
        ,@('OpenAI - very natural, and you can choose a warm or lively tone. Pay as you go (about half a US cent per summary).', 'openai')
        ,@('Microsoft Azure - natural voices, including Indian English. Free up to 500,000 characters a month.', 'azure')
        ,@('Windows built-in - free and offline, but robotic (what you have now).', 'windows')
    )
    Set-CfgValue $cfg 'engine' $engine

    $needKey = $true
    if ($engine -eq 'kokoro') {
        $needKey = $false
        if (-not (Test-KokoroReady)) {
            Say ''
            Say 'Kokoro needs a one-time setup: it downloads the free voice model (about 450 MB in total)' 'Yellow'
            Say 'and may install Python (a free programming tool). This takes about 5 to 15 minutes.' 'Yellow'
            $go = Read-Host 'Set it up now? (Y/N)'
            if ($go -notmatch '^[Yy]') { Say 'Nothing was changed.' 'Yellow'; exit 1 }
            & (Join-Path $PSScriptRoot 'setup-kokoro.ps1')
            if (-not (Test-KokoroReady)) { Say 'Kokoro setup did not finish, so nothing was changed. Run choose-voice.bat to try again.' 'Red'; exit 1 }
        }
        $voices = @(
            ,@('Heart - American, female, warm', 'af_heart')
            ,@('Bella - American, female, expressive', 'af_bella')
            ,@('Nicole - American, female, soft', 'af_nicole')
            ,@('Michael - American, male', 'am_michael')
            ,@('Puck - American, male, lively', 'am_puck')
            ,@('Fenrir - American, male, deep', 'am_fenrir')
            ,@('Emma - British, female', 'bf_emma')
            ,@('George - British, male', 'bm_george')
            ,@('Fable - British, male', 'bm_fable')
        )
        $speed = Select-Option 'How fast should it speak?' @(
            ,@('Normal', '1.0')
            ,@('A little faster', '1.15')
            ,@('A little slower', '0.9')
        )
        Set-CfgValue $cfg 'kokoro_speed' $speed
        Say ''
        Say 'Each sample takes a few seconds to start - Kokoro is working on your own PC.' 'DarkGray'
    } elseif ($engine -eq 'openai') {
        $tone = Select-Option 'Which tone of voice?' @(
            ,@('Warm and friendly', 'warm')
            ,@('Bright and upbeat', 'upbeat')
            ,@('Calm and clear', 'calm')
        )
        Set-CfgValue $cfg 'openai_tone' $tone
        $voices = @(
            ,@('Coral - female, warm', 'coral')
            ,@('Marin - female, very natural', 'marin')
            ,@('Cedar - male, very natural', 'cedar')
            ,@('Sage - female, gentle', 'sage')
            ,@('Ash - male, clear', 'ash')
            ,@('Nova - female, bright', 'nova')
            ,@('Ballad - male, soft', 'ballad')
            ,@('Verse - male, expressive', 'verse')
        )
    } elseif ($engine -eq 'azure') {
        $voices = @(
            ,@('Neerja - Indian English, female', 'en-IN-NeerjaNeural')
            ,@('Prabhat - Indian English, male', 'en-IN-PrabhatNeural')
            ,@('Ava - American English, female, very natural', 'en-US-AvaMultilingualNeural')
            ,@('Andrew - American English, male, very natural', 'en-US-AndrewMultilingualNeural')
            ,@('Sonia - British English, female', 'en-GB-SoniaNeural')
            ,@('Ryan - British English, male', 'en-GB-RyanNeural')
        )
        $rate = Select-Option 'How fast should it speak?' @(
            ,@('Normal', '+0%')
            ,@('A little faster', '+12%')
            ,@('A little slower', '-10%')
        )
        Set-CfgValue $cfg 'azure_rate' $rate
    } else {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $voices = @($synth.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object {
            ,@(($_.VoiceInfo.Name + ' - ' + $_.VoiceInfo.Culture.DisplayName), $_.VoiceInfo.Name)
        })
        $synth.Dispose()
        $needKey = $false
    }

    $forceNewKey = $false
    while ($true) {
        if ($engine -eq 'openai' -and $needKey) {
            Say ''
            Say 'You need an OpenAI API key: go to platform.openai.com > sign in > API keys > Create new secret key.' 'DarkGray'
            Read-Key $cfg 'openai_key' 'OpenAI API' $forceNewKey
            $needKey = $false
        } elseif ($engine -eq 'azure' -and $needKey) {
            Say ''
            Say 'You need an Azure Speech key and region: portal.azure.com > Create a resource > Speech > Free F0 tier,' 'DarkGray'
            Say 'then open it and go to "Keys and Endpoint". Copy KEY 1 and the Location/Region.' 'DarkGray'
            Read-Key $cfg 'azure_key' 'Azure Speech' $forceNewKey
            $oldRegion = Get-CfgValue $cfg 'azure_region' ''
            $prompt = 'Type the region shown under Location/Region (for example centralindia)'
            if ($oldRegion) { $prompt = "$prompt, or press Enter to keep '$oldRegion'" }
            $region = (Read-Host $prompt).Trim()
            if ($region) { Set-CfgValue $cfg 'azure_region' $region }
            $needKey = $false
        }

        $voice = Select-Option 'Pick a voice to hear a sample:' $voices
        Set-CfgValue $cfg ($engine + '_voice') $voice

        Say ''
        Say 'Playing a sample...' 'Gray'
        try {
            Invoke-VoiceSpeak $Sample -Config $cfg -NoFallback
        } catch {
            Show-Problem $_.Exception.Message
            if ($_.Exception.Message -match '401|403|Unauthorized|invalid_api_key|Incorrect API key|Forbidden|Access denied|resolved|No such host') {
                $needKey = $true; $forceNewKey = $true
            }
            $again = Read-Host 'Try again? (Y/N)'
            if ($again -notmatch '^[Yy]') { Say 'Nothing was changed.' 'Yellow'; exit 1 }
            continue
        }

        $keep = Read-Host 'Keep this voice? (Y = yes, N = hear another)'
        if ($keep -match '^[Yy]') { break }
    }

    Save-VoiceConfig $cfg
    Say ''
    Say 'Saved! Your next Claude Code summary will use this voice.' 'Green'
    Say 'If the service is ever unavailable, the Windows voice fills in automatically.' 'Green'
    Say 'Run choose-voice.bat again any time to change it.' 'Green'
} catch {
    Say ''
    Say ('Something went wrong: ' + $_.Exception.Message) 'Red'
    exit 1
}
