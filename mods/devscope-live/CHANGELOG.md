# Changelog: devscope-live

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.4.0] - 2026-10-08

### Changed
- **Voice bar per session.** The bar and its Stop button appear only in the
  window whose session is speaking; every other window shows one dimmed line,
  "🔊 api-service, rate limiter fix · reading the summary". Progress from a
  devscope plugin older than 0.34.0 names no session and still shows the bar
  everywhere.

## [0.3.0] - 2026-10-07

### Changed
- **Team prompt suggestions are few and short.** A suggestion is at most 5 words
  (60 characters) on one line; anything longer is dropped, whatever the server
  sends. It is offered only after a turn in which Claude used tools and did not
  end by asking a question (then your answer is the next prompt, and only you
  know it). After three suggestions in a row are typed over, suggestions pause
  for 30 minutes. The server side (DevScope backend) now also only proposes
  habits: a short prompt that came next and worked in at least two separate
  sessions (three for the opening prompt of a session), never a bare reply
  like "yes" or "a".

## [0.2.0] - 2026-10-07

### Added
- **Voice progress bar.** While DevScope voice makes or speaks audio
  (`/devscope:voice explain`, reply summaries), a gradient bar of 6-dot braille sits
  above the prompt: a comet sweeps while the reply is summarized and the audio is
  created, then it fills through the pieces as they play (24 cells, 144 steps),
  with what is happening and a *Stop* button. It reads the `devscope` plugin's
  `~/.cache/devscope/voice/progress.json` (0.24.0+): once a second while idle,
  every 120 ms while speech runs. A file left behind by a killed speaker is
  ignored. Interactive sessions only; turn off with the *Voice progress bar*
  option.

## [0.1.0] - 2026-10-06

### Added
- **Team prompts.** After a turn, and at session start, the next prompt that worked
  in similar sessions (yours and teammates who share theirs) is proposed as ghost
  text; it replaces the engine's own guess while fresh.
- **Team skills.** A prompt that matches an active team skill's trigger phrase asks
  "Use it?" once per skill per session; choosing it attaches the skill to that prompt.
- **Stuck band.** When a tool call fails and DevScope's friction rules tripped for the
  session, a band offers *Step back*, *Stop* and *Keep going*.
- **Outcome labels.** Replies that clearly praise or complain label the previous turn;
  a long or busy turn (2 min or 15 tool calls) asks "Did that work?", at most every
  30 minutes.
- **Commit and PR links.** Commits and PRs made through Bash are recorded against the
  session; open PRs are settled with the user's `gh` at session start (every 6 h per
  repository). Optional `DevScope-Session:` trailer, off by default.
- Every feature fails open, has a `userConfig` toggle, and `private` mode sends no
  content or repository data.
