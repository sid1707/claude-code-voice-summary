---
name: voice-off
description: Turn off the spoken summaries that play after each reply.
disable-model-invocation: true
---

Create an empty file named `voice-summary-off` inside the user's `.claude` folder (on Windows: `%USERPROFILE%\.claude\voice-summary-off`). If it already exists, leave it.

Then reply with exactly this and nothing else: Voice summaries are off. Type /voice-on to turn them back on.
