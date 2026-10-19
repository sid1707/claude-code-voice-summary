# Changelog

## 1.0.0 - 2026-10-19

First public release.

- **Plain Words** output style: every Claude Code reply ends with a short "In plain words" recap for non-programmers.
- **Spoken summaries**: a Stop hook reads that recap aloud after each reply (falls back to a quick Claude Haiku summary, then to the first sentences).
- **Voices**: Kokoro (free, open-source, runs on your PC), OpenAI, Microsoft Azure, or the built-in Windows voice. The Windows voice fills in automatically if another voice fails.
- `choose-voice.bat` to pick and preview voices; `/voice-off` and `/voice-on` to mute.
- One-click `install.bat` / `uninstall.bat` that back up and merge your Claude Code settings.
