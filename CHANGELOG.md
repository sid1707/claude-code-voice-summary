# Changelog

## 1.1.0 - 2026-10-20

- **Permission alerts**: you now hear "Claude is waiting for your permission to continue" when Claude stops part-way to ask your permission or for input. Before, these pauses were silent because they aren't a finished reply.
- **Clearer log**: every summary and alert is now written to the log, with where the text came from and which voice spoke it, so it's easy to see what happened.
- **`check-voice.bat`**: checks the set-up, plays a test summary and saves a report to your Desktop.
- **Clearer installer**: it says which voice it is testing (Kokoro can take a few seconds) and warns if it was opened from inside the zip without unzipping.

## 1.0.0 - 2026-10-19

First public release.

- **Plain Words** output style: every Claude Code reply ends with a short "In plain words" recap for non-programmers.
- **Spoken summaries**: a Stop hook reads that recap aloud after each reply (falls back to a quick Claude Haiku summary, then to the first sentences).
- **Voices**: Kokoro (free, open-source, runs on your PC), OpenAI, Microsoft Azure, or the built-in Windows voice. The Windows voice fills in automatically if another voice fails.
- `choose-voice.bat` to pick and preview voices; `/voice-off` and `/voice-on` to mute.
- One-click `install.bat` / `uninstall.bat` that back up and merge your Claude Code settings.
