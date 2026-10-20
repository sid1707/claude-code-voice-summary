"""
kokoro-speak.py - turns text into speech with the free, open-source Kokoro voice model.
Used by the Claude Code voice summaries (voice-engines.ps1). Runs fully on this PC.

Reads the text from standard input (UTF-8), then either:
  --stream     writes each sentence as a WAV to standard output as soon as it is
               ready (used by the voice summaries: PowerShell plays them),
  --play       speaks it through the speakers itself (Windows), or
  --out FILE   saves it all as one WAV file.

Example:
  python kokoro-speak.py --model kokoro-v1.0.onnx --voices voices-v1.0.bin --voice af_heart --play
"""
import argparse
import io
import queue
import re
import sys
import threading
import wave

PAUSE_SECONDS = 0.15  # short breath between sentences


def to_wav_bytes(samples, sample_rate, np):
    pcm = (np.clip(np.asarray(samples, dtype=np.float32), -1.0, 1.0) * 32767).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(sample_rate))
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


def split_sentences(text):
    """Split into sentences, joining very short ones so speech flows naturally."""
    parts = [p.strip() for p in re.split(r"(?<=[.!?;:])\s+", text) if p.strip()]
    chunks, current = [], ""
    for part in parts:
        current = f"{current} {part}".strip()
        if len(current) >= 40:
            chunks.append(current)
            current = ""
    if current:
        if chunks and len(current) < 20:
            chunks[-1] = f"{chunks[-1]} {current}"
        else:
            chunks.append(current)
    return chunks


def main() -> int:
    parser = argparse.ArgumentParser(description="Kokoro text to speech")
    parser.add_argument("--model", required=True)
    parser.add_argument("--voices", required=True)
    parser.add_argument("--voice", default="af_heart")
    parser.add_argument("--speed", type=float, default=1.0)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--play", action="store_true", help="speak through the speakers")
    group.add_argument("--out", help="save to this WAV file instead")
    group.add_argument("--stream", action="store_true",
                       help="write each sentence as a WAV to standard output, for another program to play")
    args = parser.parse_args()

    text = sys.stdin.buffer.read().decode("utf-8", errors="replace").strip()
    if not text:
        print("No text to speak.", file=sys.stderr)
        return 2

    import numpy as np
    from kokoro_onnx import Kokoro

    # Voices starting with "b" (bf_, bm_) are British English; the rest American.
    lang = "en-gb" if args.voice.startswith("b") else "en-us"
    speed = min(2.0, max(0.5, args.speed))
    kokoro = Kokoro(args.model, args.voices)

    def synth(chunk):
        return kokoro.create(chunk, voice=args.voice, speed=speed, lang=lang)

    if args.stream:
        # Each sentence goes out as soon as it is ready: a 4-byte length (little-endian), then a WAV.
        # The caller (voice-engines.ps1) plays them, so the sound comes from PowerShell, not Python.
        import struct
        out = sys.stdout.buffer
        for chunk in split_sentences(text):
            samples, rate = synth(chunk)
            silence = np.zeros(int(rate * PAUSE_SECONDS), dtype=np.float32)
            wav = to_wav_bytes(np.concatenate([samples, silence]), rate, np)
            out.write(struct.pack("<I", len(wav)))
            out.write(wav)
            out.flush()
        return 0

    if args.out:
        samples, rate = synth(text)
        with open(args.out, "wb") as f:
            f.write(to_wav_bytes(samples, rate, np))
        return 0

    import winsound  # Windows only

    # One thread prepares sentences; this thread plays each one as soon as it is ready.
    ready = queue.Queue(maxsize=3)
    failure = []

    def producer():
        try:
            for chunk in split_sentences(text):
                samples, rate = synth(chunk)
                silence = np.zeros(int(rate * PAUSE_SECONDS), dtype=np.float32)
                ready.put(to_wav_bytes(np.concatenate([samples, silence]), rate, np))
        except Exception as exc:
            failure.append(exc)
        finally:
            ready.put(None)

    threading.Thread(target=producer, daemon=True).start()
    played = 0
    while True:
        wav = ready.get()
        if wav is None:
            break
        winsound.PlaySound(wav, winsound.SND_MEMORY)
        played += 1
    if failure and played == 0:
        raise failure[0]
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # report the reason so the log shows what went wrong
        print(f"Kokoro error: {exc}", file=sys.stderr)
        sys.exit(1)
