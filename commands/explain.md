---
allowed-tools: Read, Grep, Glob, Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(bash:*)
description: Talk a topic through out loud, simply, like a colleague at the whiteboard, and leave a short written card
argument-hint: "[file, function, PR or topic; empty = what we just discussed]"
---

# Explain, out loud

Explain a topic **simply**, as a short spoken discussion, through DevScope's voice. Then leave a short written card in the chat.

$ARGUMENTS

## What to explain

If `$ARGUMENTS` names a file, function, PR or topic, explain that. Read just enough code to be right.
If it is empty, explain whatever was just discussed or last changed in this session.

## Step 1: speak it

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
- **150 to 220 words.** About a minute and a half. Never more than 300.
- **Written for the ear:** short sentences, contractions, "so", "now", "here's the thing". No markdown, bullets, code, file paths, URLs, symbols or emoji. Say names in words ("the reminder timer", not `timer.sh`). Spell out abbreviations a voice would stumble on, or avoid them.
- **Plain English.** Define any unavoidable jargon in the same sentence.
- No line in the script may be exactly `DEVSCOPE_SPEECH`.

## Step 2: the written card

After the command, reply with this card and nothing else (max ~12 lines):

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

## Keep the discussion going

When the user answers the question, keep talking it through the same way for the rest of this discussion: speak a short reply (40 to 120 words, same spoken rules, again ending with a question when there is still something to decide) with the same command, then answer in one to three written lines. Stop speaking once the user moves on to other work or says so.

## Anti-patterns

- A wall of text, in the card or in the script
- Mechanics ("it iterates over the array and calls ...")
- Abstract scenarios ("if user A has X and user B has Y ...")
- Six options with a trade-off table
- Reading the card aloud: the script is the conversation, the card is the note left behind
- Ending the script on a summary instead of a question
