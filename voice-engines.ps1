# voice-engines.ps1 - shared voice code for the Claude Code voice summaries.
# Voice services ("engines"): "kokoro" (free, on this PC), "openai", "azure", "windows".
# Settings are saved in voice-config.json by choose-voice.bat. API keys are stored
# encrypted with Windows' own per-user protection (only your Windows account can read them).
# If a voice service fails (no internet, no credit, bad key), the Windows voice is used instead.

$script:VoiceHookDir    = Join-Path (Join-Path $env:USERPROFILE '.claude') 'hooks'
$script:VoiceConfigPath = Join-Path $script:VoiceHookDir 'voice-config.json'
$script:VoiceLogPath    = Join-Path $script:VoiceHookDir 'voice-summary.log'
$script:VoiceUtf8       = New-Object System.Text.UTF8Encoding $false

$script:OpenAITones = [ordered]@{
    warm   = 'Voice: warm, friendly and natural, like a helpful colleague giving a quick spoken update. Tone: positive and clear. Pace: relaxed but not slow.'
    upbeat = 'Voice: bright, energetic and upbeat, like an enthusiastic podcast host sharing good news. Keep it natural, not over the top. Pace: lively.'
    calm   = 'Voice: calm, clear and reassuring, like a friendly teacher. Pace: steady, with short pauses between sentences.'
}

function Write-VoiceLog([string]$msg) {
    try { Add-Content -Path $script:VoiceLogPath -Value ("{0}  {1}" -f (Get-Date -Format 's'), $msg) -Encoding UTF8 } catch {}
}

function Get-VoiceConfig {
    if (Test-Path $script:VoiceConfigPath) {
        try { return ([System.IO.File]::ReadAllText($script:VoiceConfigPath) | ConvertFrom-Json) }
        catch { Write-VoiceLog ("voice-config.json could not be read: " + $_.Exception.Message) }
    }
    return [pscustomobject]@{ engine = 'windows' }
}

function Save-VoiceConfig($cfg) {
    New-Item -ItemType Directory -Force -Path $script:VoiceHookDir | Out-Null
    [System.IO.File]::WriteAllText($script:VoiceConfigPath, ($cfg | ConvertTo-Json -Depth 5), $script:VoiceUtf8)
}

function Get-CfgValue($cfg, [string]$name, $default) {
    if ($cfg -and $cfg.PSObject.Properties[$name] -and $null -ne $cfg.$name -and "$($cfg.$name)" -ne '') { return $cfg.$name }
    return $default
}

function Set-CfgValue($cfg, [string]$name, $value) {
    $cfg | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
}

function Protect-VoiceSecret([string]$plain) {
    ConvertTo-SecureString $plain -AsPlainText -Force | ConvertFrom-SecureString
}

function Unprotect-VoiceSecret([string]$enc) {
    if (-not $enc) { throw 'No API key is saved. Run choose-voice.bat.' }
    $secure = ConvertTo-SecureString $enc
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Sends a request and returns the audio bytes. On failure, throws with the service's own error text.
function Invoke-AudioRequest([string]$url, [hashtable]$headers, [string]$contentType, [string]$body) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method           = 'POST'
    $req.ContentType      = $contentType
    $req.UserAgent        = 'claude-voice-summary'
    $req.Timeout          = 30000
    $req.ReadWriteTimeout = 30000
    foreach ($k in $headers.Keys) { $req.Headers.Add($k, [string]$headers[$k]) }
    $bytes = $script:VoiceUtf8.GetBytes($body)
    $req.ContentLength = $bytes.Length
    $resp = $null
    try {
        $rs = $req.GetRequestStream()
        $rs.Write($bytes, 0, $bytes.Length)
        $rs.Close()
        $resp = $req.GetResponse()
    } catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
        $detail = $_.Exception.Message
        if ($ex) {
            $detail = $ex.Message
            if ($ex.Response) {
                try {
                    $sr = New-Object System.IO.StreamReader($ex.Response.GetResponseStream())
                    $detail = $detail + ' ' + $sr.ReadToEnd()
                } catch {}
            }
        }
        throw ('Voice service error: ' + $detail)
    }
    try {
        $ms = New-Object System.IO.MemoryStream
        $resp.GetResponseStream().CopyTo($ms)
        $audio = $ms.ToArray()
        if ($audio.Length -lt 100) { throw 'Voice service returned no audio.' }
        return ,$audio
    } finally {
        $resp.Close()
    }
}

# Wraps raw 16-bit mono PCM samples in a WAV header so Windows can play them.
function New-WavFromPcm([byte[]]$pcm, [int]$sampleRate = 24000) {
    $ms = New-Object System.IO.MemoryStream
    $w  = New-Object System.IO.BinaryWriter($ms)
    $a  = [System.Text.Encoding]::ASCII
    $w.Write($a.GetBytes('RIFF')); $w.Write([int](36 + $pcm.Length)); $w.Write($a.GetBytes('WAVE'))
    $w.Write($a.GetBytes('fmt ')); $w.Write([int]16); $w.Write([int16]1); $w.Write([int16]1)
    $w.Write([int]$sampleRate); $w.Write([int]($sampleRate * 2)); $w.Write([int16]2); $w.Write([int16]16)
    $w.Write($a.GetBytes('data')); $w.Write([int]$pcm.Length); $w.Write($pcm)
    $w.Flush()
    return ,$ms.ToArray()
}

function Invoke-WavPlayback([byte[]]$wav) {
    $ms = New-Object System.IO.MemoryStream(,$wav)
    $player = New-Object System.Media.SoundPlayer($ms)
    try { $player.PlaySync() } finally { $player.Dispose(); $ms.Dispose() }
}

function Get-OpenAIPcm([string]$text, $cfg) {
    $key   = Unprotect-VoiceSecret (Get-CfgValue $cfg 'openai_key' '')
    $tone  = Get-CfgValue $cfg 'openai_tone' 'warm'
    $instr = Get-CfgValue $cfg 'openai_instructions' ''
    if (-not $instr) { $instr = $script:OpenAITones[$tone]; if (-not $instr) { $instr = $script:OpenAITones['warm'] } }
    $body = [ordered]@{
        model           = (Get-CfgValue $cfg 'openai_model' 'gpt-4o-mini-tts')
        voice           = (Get-CfgValue $cfg 'openai_voice' 'coral')
        input           = $text
        instructions    = $instr
        response_format = 'pcm'
    } | ConvertTo-Json -Compress
    $url = Get-CfgValue $cfg 'openai_url' 'https://api.openai.com/v1/audio/speech'
    return ,(Invoke-AudioRequest $url @{ Authorization = "Bearer $key" } 'application/json' $body)
}

function Get-AzurePcm([string]$text, $cfg) {
    $key    = Unprotect-VoiceSecret (Get-CfgValue $cfg 'azure_key' '')
    $region = ((Get-CfgValue $cfg 'azure_region' '') -replace '\s', '').ToLower()
    if (-not $region) { throw 'No Azure region is saved. Run choose-voice.bat.' }
    $voice  = Get-CfgValue $cfg 'azure_voice' 'en-IN-NeerjaNeural'
    $rate   = Get-CfgValue $cfg 'azure_rate' '+0%'
    $lang   = (($voice -split '-')[0..1]) -join '-'
    $safe   = [System.Security.SecurityElement]::Escape($text)
    $ssml   = "<speak version='1.0' xml:lang='$lang' xmlns='http://www.w3.org/2001/10/synthesis'>" +
              "<voice name='$voice'><prosody rate='$rate'>$safe</prosody></voice></speak>"
    $url = Get-CfgValue $cfg 'azure_url' "https://$region.tts.speech.microsoft.com/cognitiveservices/v1"
    $headers = @{
        'Ocp-Apim-Subscription-Key' = $key
        'X-Microsoft-OutputFormat'  = 'raw-24khz-16bit-mono-pcm'
    }
    return ,(Invoke-AudioRequest $url $headers 'application/ssml+xml' $ssml)
}

# ---------- Kokoro (free, open-source, runs on this PC) ----------
$script:KokoroDir = Join-Path (Join-Path $env:USERPROFILE '.claude') 'kokoro'

function Get-KokoroPaths {
    $py = Join-Path (Join-Path (Join-Path $script:KokoroDir 'venv') 'Scripts') 'python.exe'
    if (-not (Test-Path $py)) { $py = Join-Path (Join-Path (Join-Path $script:KokoroDir 'venv') 'bin') 'python' }
    return @{
        Python = $py
        Script = Join-Path $script:KokoroDir 'kokoro-speak.py'
        Model  = Join-Path $script:KokoroDir 'kokoro-v1.0.onnx'
        Voices = Join-Path $script:KokoroDir 'voices-v1.0.bin'
    }
}

function Test-KokoroReady {
    $p = Get-KokoroPaths
    foreach ($f in $p.Values) { if (-not (Test-Path $f)) { return $false } }
    return $true
}

# Runs a program, feeds it text on standard input, waits (up to a limit) and returns its results.
function Invoke-ProgramWithInput([string]$exe, [string]$arguments, [string]$inputText, [int]$timeoutSeconds) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $exe
    $psi.Arguments              = $arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = $script:VoiceUtf8
    $psi.StandardErrorEncoding  = $script:VoiceUtf8
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $bytes = $script:VoiceUtf8.GetBytes($inputText)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()
    if (-not $proc.WaitForExit($timeoutSeconds * 1000)) {
        try { $proc.Kill() } catch {}
        throw "timed out after $timeoutSeconds seconds"
    }
    return @{ ExitCode = $proc.ExitCode; StdOut = $outTask.Result; StdErr = $errTask.Result }
}

function Invoke-KokoroSpeech([string]$text, $cfg) {
    if (-not (Test-KokoroReady)) { throw 'Kokoro is not set up yet. Run choose-voice.bat and pick Kokoro.' }
    $p     = Get-KokoroPaths
    $voice = Get-CfgValue $cfg 'kokoro_voice' 'af_heart'
    $speed = Get-CfgValue $cfg 'kokoro_speed' '1.0'
    if ($voice -notmatch '^[a-z]{2}_[a-z]+$') { $voice = 'af_heart' }
    if ($speed -notmatch '^\d(\.\d+)?$') { $speed = '1.0' }
    $arguments = '"{0}" --model "{1}" --voices "{2}" --voice {3} --speed {4} --play' -f $p.Script, $p.Model, $p.Voices, $voice, $speed
    $r = Invoke-ProgramWithInput $p.Python $arguments $text 300
    if ($r.ExitCode -ne 0) { throw ('Kokoro failed: ' + ($r.StdErr.Trim() -split "`n")[-1]) }
}

function Invoke-WindowsSpeech([string]$text, $cfg) {
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        $v = Get-CfgValue $cfg 'windows_voice' ''
        if ($v) { try { $synth.SelectVoice($v) } catch { Write-VoiceLog "Windows voice not found: $v" } }
        $synth.Rate = [Math]::Max(-10, [Math]::Min(10, [int](Get-CfgValue $cfg 'windows_rate' 0)))
        $synth.SetOutputToDefaultAudioDevice()
        $synth.Speak($text)
    } finally { $synth.Dispose() }
}

# Speaks text with the chosen voice service. Falls back to the Windows voice unless -NoFallback.
function Invoke-VoiceSpeak([string]$text, $Config = $null, [switch]$NoFallback) {
    $cfg = $Config
    if (-not $cfg) { $cfg = Get-VoiceConfig }
    $engine = Get-CfgValue $cfg 'engine' 'windows'
    if ($engine -ne 'windows') {
        try {
            if ($engine -eq 'kokoro') { Invoke-KokoroSpeech $text $cfg; return }
            if ($engine -eq 'openai')    { $pcm = Get-OpenAIPcm $text $cfg }
            elseif ($engine -eq 'azure') { $pcm = Get-AzurePcm $text $cfg }
            else { throw "Unknown voice service '$engine'" }
            Invoke-WavPlayback (New-WavFromPcm $pcm)
            return
        } catch {
            if ($NoFallback) { throw }
            Write-VoiceLog ("$engine voice failed, used the Windows voice instead: " + $_.Exception.Message)
        }
    }
    Invoke-WindowsSpeech $text $cfg
}
