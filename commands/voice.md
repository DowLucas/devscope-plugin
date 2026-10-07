---
allowed-tools: Bash(bash:*)
description: Voice announcements when a session waits on you, and spoken summaries of every reply (on, off, replies, speed, mute, stop, test, setup)
argument-hint: "[status|on|off|replies [on|off]|speed [slow|normal|fast]|mute 1h|unmute|stop|test|setup|finished on|off]"
---

## Your task

Run the DevScope voice command with the user's arguments and report the result.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/voice/cli.sh" $ARGUMENTS
```

Show the output to the user in a few short lines. Do not run anything else.

The default engine is `server`: the DevScope server voices speech (Kokoro, `voice` in voice.json, default `am_michael`). If the engine is `system` or `none`, mention that it needs a DevScope API key (`/devscope:setup`), and that `/devscope:voice setup` installs Piper as an offline fallback (Linux; on macOS use `pipx install piper-tts`).

Two independent features:
- **Announcer** (`on`/`off`): speaks only after a session has waited on the user past a grace delay (30 s for permission prompts and questions, 10 s for failures, 2 min for finished turns if `finished on`), then reminds every 5 min, up to 3 times. Answering in time keeps it silent.
- **Reply summaries** (`replies`, `replies on`, `replies off`; plain `replies` toggles): after every reply Claude finishes, a two-to-three sentence spoken summary of what it said. The reply is sent to the DevScope server to summarize and is not stored; in `private` mode only "<project> is done" is spoken, locally. A turn that used `/devscope:explain` is not summarized on top.

`speed slow|normal|fast` sets how fast every voice talks: 1.0x, 1.2x (default) or 1.5x; plain `speed` shows the current one. `stop` ends speech in progress (a long explanation or a summary). `mute` silences both features. Settings live in `~/.config/devscope/voice.json` (`delays`, `reminder_interval`, `max_reminders`, `speak_replies`, `speed` (a number, 0.5-2), `engine`: `auto`/`server`/`piper`/`system`/`off`, `voice`, `volume` (0.5-3, server default 2), `piper_model`).
