---
allowed-tools: Read, Grep, Glob, Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(bash:*)
description: DevScope voice: explain a topic out loud, auto voice after every reply, announcements when a session waits on you (explain, auto, verbosity, speed, on, off, mute, stop, test, setup)
argument-hint: "[explain [--short|--long] <topic>|model [chatterbox|kokoro|default]|auto [on|off]|auto-default [on|off]|verbosity [explain|auto] [short|normal|long]|when-locked [quiet|play]|speed [slow|normal|fast|1.35]|status|on|off|mute 1h|unmute|stop|test|setup|finished on|off]"
---

## Your task

Arguments: `$ARGUMENTS`

**If the first argument is `explain`**, follow *Explain mode* below and do not run the command here.

Otherwise, run the DevScope voice command with the user's arguments and report the result.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/voice/cli.sh" $ARGUMENTS
```

Show the output to the user in a few short lines. Do not run anything else.

The default engine is `server`: the DevScope server voices speech. `model` lists the server's voices (on the homelab: chatterbox, the default, and kokoro), `model <name>` picks one, `model default` goes back to the server's choice; when the chosen voice is busy or down, the server uses its next one. If the engine is `system` or `none`, mention that it needs a DevScope API key (`/devscope:setup`), and that `/devscope:voice setup` installs Piper as an offline fallback (Linux; on macOS use `pipx install piper-tts`).

Three features:
- **Explain** (`explain [topic]`): see *Explain mode* below.
- **Announcer** (`on`/`off`): speaks only after a session has waited on the user past a grace delay (30 s for permission prompts and questions, 10 s for failures, 2 min for finished turns if `finished on`), then reminds every 5 min, up to 3 times. Answering in time keeps it silent.
- **Auto voice**, per session: `auto` / `auto on` / `auto off` sets it for **this session only** (plain `auto` toggles; `replies` is an old name for it), lasting as long as this Claude Code window. `auto-default on|off` is the setting for sessions where `auto` was not used. Whenever Claude finishes a reply, a two-to-three sentence spoken summary of what it said. The reply is sent to the DevScope server to summarize and is not stored; in `private` mode only "<project> is done" is spoken, locally. A turn that used `explain` is not summarized on top.

`speed slow|normal|fast` sets how fast every voice talks: 1.0x, 1.2x (default) or 1.5x; `speed <number>` sets any rate from 0.5 to 2 (e.g. `speed 1.35`); plain `speed` shows the current one. `stop` ends speech in progress (a long explanation or a summary). `when-locked quiet|play`: by default (`quiet`) nothing is spoken while the screen is locked (macOS `ioreg`/screensaver, Linux logind `LockedHint`): announcements wait until unlock, auto voice is skipped, an explanation stops; `play` ignores the lock. `verbosity [explain|auto] short|normal|long` sets how detailed explain and auto voice are (both when no mode is named); plain `verbosity` shows them. `auto off` turns off only auto voice; announcements and `explain` are unaffected. `mute` silences auto voice and announcements. Settings live in `~/.config/devscope/voice.json` (`delays`, `reminder_interval`, `max_reminders`, `speak_replies`, `speed` (a number, 0.5-2), `engine`: `auto`/`server`/`piper`/`system`/`off`, `voice`, `volume` (0.5-3, server default 2), `piper_model`).

## Explain mode (`explain [topic]`)

Explain a topic **simply**, as a short spoken discussion, through DevScope's voice. Then leave a short written card in the chat.

Explain verbosity setting: !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/voice/cli.sh" verbosity explain`

The level is that setting (`normal` if the line above shows nothing), unless the arguments start with `--short` or `--long`, which override it for this one explanation:

| Level | Spoken script | Options weighed | Written card |
|---|---|---|---|
| `short` | 60 to 100 words, about 40 seconds | at most one, in a sentence | **What it is**, **Scenario** (2-3 sentences), **Your call**; max ~6 lines |
| `normal` | 150 to 220 words, about a minute and a half | at most three | the full card below; max ~12 lines |
| `long` | 300 to 450 words, about three minutes | at most three, each with its catch and when it would win | the full card; may add one more option and an edge case to the scenario; max ~18 lines |

### What to explain

The topic is everything after `explain` (and after `--short` / `--long`). If it names a file, function, PR or topic, explain that. Read just enough code to be right.
If it is empty, explain whatever was just discussed or last changed in this session.

### Step 1: speak it

Write a spoken script and run exactly this, with the script between the markers:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/voice/cli.sh" say <<'DEVSCOPE_SPEECH'
<the spoken script>
DEVSCOPE_SPEECH
```

It returns at once and keeps speaking in the background. If it prints that no voice is available, pass that on in one line and carry on with step 2.

**The spoken script is a conversation, not a summary read aloud.** Talk like a senior colleague thinking it through with the user at a whiteboard:

1. **Open with the question** in one sentence: "So, the question is why reminders sometimes come twice."
2. **Say what it is** in plain words, one or two sentences.
3. **Tell the scenario** as a little story: a real name, a real value, a real click, and what actually happens at the end.
4. **Think out loud about the options** (at most three): "We could ..., which is quick, but ... Or we could ..., the catch being ..." Weigh them; don't list them.
5. **Say where you lean** and why, in a sentence.
6. **End with one real question** for the user, one whose answer would change the recommendation: "Does it matter to you that ..., or is ... fine?"

If there is no problem (pure explanation), skip 4 and 5, and end with a question that checks the understanding or opens the next step.

Spoken-script rules:
- **Length by level** (table above). Never more than the level's upper bound.
- **Written for the ear:** short sentences, contractions, "so", "now", "here's the thing". No markdown, bullets, code, file paths, URLs, symbols or emoji. Say names in words ("the reminder timer", not `timer.sh`). Spell out abbreviations a voice would stumble on, or avoid them.
- **Plain English.** Define any unavoidable jargon in the same sentence.
- **Say technical shorthand the way a person would.** The voice spells capitals letter by letter, so acronyms said that way stay in capitals (API, CLI, PR, SSH). Write the rest as spoken words: "jay-son" for JSON, "the readme", "yammel" for YAML, "version two point one", "five seconds", "one point two times", "for example", "versus". Never read out identifiers, file names, flags or paths (`useActivityStore`, `voice.json`, `--short`): say what they are ("the activity store", "the voice settings file", "the short option").
- No line in the script may be exactly `DEVSCOPE_SPEECH`.

### Step 2: the written card

After the command, reply with this card and nothing else (its length by level, table above):

```
**What it is**: <one sentence, plain English>

**The problem**: <1-2 sentences: what breaks or what's missing>

**Options**:
- <option 1, one line, the one you lean towards first>
- <option 2, one line>

**Scenario**:
> <3-5 sentences. A real person doing a real thing. Real names and values. End with what actually happens.>

**Your call**: <the question from the end of the script>
```

If there is no problem, drop **The problem** and **Options**.

### Speak once

`explain` speaks only this explanation. When the user answers the question, answer in text as usual and do not run the `say` command again; auto voice (`/devscope:voice auto`), if on, already reads replies aloud.

### Anti-patterns

- A wall of text, in the card or in the script
- Mechanics ("it iterates over the array and calls ...")
- Abstract scenarios ("if user A has X and user B has Y ...")
- Six options with a trade-off table
- Reading the card aloud: the script is the conversation, the card is the note left behind
- Ending the script on a summary instead of a question
