---
allowed-tools: Bash(bash:*)
description: Voice announcements when a Claude Code session has been waiting on you (on, off, mute, test, setup)
argument-hint: "[status|on|off|mute 1h|unmute|test|setup|finished on|off]"
---

## Your task

Run the DevScope voice command with the user's arguments and report the result.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/voice/cli.sh" $ARGUMENTS
```

Show the output to the user in a few short lines. Do not run anything else.

If the engine is `system` or `none`, mention that `/devscope:voice setup` installs Piper, a natural offline voice (Linux; on macOS use `pipx install piper-tts`).

When the announcer is on, it speaks only after a session has waited on the user past a grace delay (30 s for permission prompts and questions, 10 s for failures, 2 min for finished turns if enabled), then reminds every 5 min, up to 3 times. Answering in time keeps it silent. Settings live in `~/.config/devscope/voice.json` (`delays`, `reminder_interval`, `max_reminders`, `engine`: `auto`/`piper`/`system`/`off`, `piper_model`).
