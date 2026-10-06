# Changelog: devscope-live

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
