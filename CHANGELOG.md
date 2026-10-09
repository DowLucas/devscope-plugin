# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.35.1] - 2026-10-09

### Changed
- **Long speech runs up to about 5 minutes.** Explanations and reply summaries
  were cut after 3000 characters (about 3 minutes at 1.2x), which could end
  them mid-thought; the limit is now 5000 characters (`DS_VOICE_LONG_MAX`).

## [0.35.0] - 2026-10-08

### Added
- **First use of a model.** The first time a model shows up on this machine (at
  session start or after `/model`), Claude is asked to offer, in one question,
  to check your CLAUDE.md and memory files for instructions about model
  selection and usage and update them for the new model; it does nothing
  unless you agree. You see `DevScope: first time on <model>.` and a
  `model.first_use` event (`model`, `trigger`, `previousModel`) is sent, which
  the dashboard shows in the live feed. Seen models are kept in
  `~/.cache/devscope/models-seen`; the context-window suffix (`[1m]`) does not
  make a model new, and the model in use when the plugin first runs is the
  silent baseline. New synchronous hook `scripts/model-first-use.sh` on
  `SessionStart` and `PostModelSwitch`: local only, the event is sent in the
  background. `DEVSCOPE_HINTS=off` turns the message off; the event is still
  sent. Older servers reject the new event type with a 400 and the plugin
  drops it, so nothing else is affected.

## [0.34.0] - 2026-10-08

### Added
- **The voice bar shows in the session that is speaking.** `progress.json`
  carries `sessionId` (the Claude Code session the speech is about) and, for
  replies, the session's spoken name as `project`. Explanations are started by
  a command that is not told the session, so the prompt hook records each
  window's session in `~/.cache/devscope/voice/sessions/<claude-pid>` (only
  when voice is set up or Claude Code passes its PID) and `/devscope:voice
  explain` looks it up. Needs devscope-live 0.4.0 to take effect.

## [0.33.0] - 2026-10-08

### Fixed
- **Sessions finishing together are all heard, in order.** Speakers now take a
  ticket and the oldest live one speaks next (first come, first served). Before,
  a waiter gave up after 120 s, so with three or four sessions finishing at once
  the later replies were silently dropped, and `flock` woke waiters in no
  particular order. A turn is now skipped only after 15 minutes
  (`DS_VOICE_QUEUE_MAX_WAIT`, stale) or when its process died.
- **No more voices talking over a long explanation on macOS.** The `mkdir`
  lock was taken over once it was two minutes old, which a three-minute
  explanation reaches; it is now taken over only when its holder has exited.
- **Reply summaries are fetched before waiting for a turn**, so sessions do
  not wait on each other's summary requests as well as their speech. (The voice
  bar therefore no longer shows a "summarizing" phase.)
- **Endings cut off.** A clip whose download was cut short (curl timed out
  after the `200` headers) was played with its end missing; it now counts as
  failed and is fetched again. With a server that supports it, every voiced
  text ends with trailing silence so outputs that close the stream early
  (Bluetooth headphones) keep the last word; in long speech only the final
  piece is padded, so pieces still run straight on (`pad_ms: 0`).
- `/devscope:voice stop` removes the macOS lock directory, which now holds the
  holder's pid.

## [0.32.0] - 2026-10-08

### Added
- **Voice says which session it is talking about.** Announcements and auto
  voice summaries start with the session's name, the project plus what it is
  working on ("api-service, rate limiter fix"), so several sessions can be
  told apart by ear. The plugin sends `session_id` to `/api/ai/voice-summary`;
  the server names the session from its title, else its branch, and returns
  the name as `label`. The first label is kept per session
  (`~/.cache/devscope/voice/labels/`) and sent back, so a session keeps one
  name even when its title changes. When the server is unreachable the local
  sentence starts with the kept label; `private` sessions are named from the
  local git branch, which is never sent. The "N sessions need you" sentence
  names each as "rate limiter fix in api-service".
- The voice hook now runs after `send-event.sh` resolves the DevScope session
  id, so the id voice sends (and keys its labels by) is the one the session's
  events are recorded under.
- Needs a DevScope server with session labels for the server-built names;
  older servers ignore the new fields and answer as before.

## [0.31.0] - 2026-10-07

### Added
- **Subagents report what they were asked to do.** `agent.start` now carries
  the subagent's `description` and `model` from the Agent tool call, so the
  DevScope topology can label each subagent. SubagentStart itself has neither,
  so the Agent tool's PreToolUse queues them per session
  (`~/.cache/devscope/intents/`) and `agent-start.sh` takes the oldest one of
  its type from the last 10 minutes. In `private` mode only the model is kept;
  the description is never written or sent.

## [0.30.0] - 2026-10-07

### Added
- **`playback_volume` in `voice.json`** (0.5-3, default 1) sets how loud this
  computer plays DevScope's speech, so it can be louder without turning up
  every other sound. It is passed to `pw-play`, `paplay` and `afplay`; `aplay`
  plays as received. `volume` still sets how loud the server makes the speech.

## [0.29.0] - 2026-10-07

### Added
- **Local mode: `/devscope:voice model local`** speaks with this computer's own
  voice (`say` on macOS) instead of the server's. It uses the System voice, so
  choosing a Siri voice in System Settings > Accessibility > Spoken Content
  makes DevScope speak with Siri. Summaries for auto voice still come from the
  server; only the voice is local. `model <server voice>` or `model default`
  switches back. `model` lists `local` with the server's voices.

## [0.28.0] - 2026-10-07

### Changed
- **Auto voice is per session.** `/devscope:voice auto` (or `auto on|off`)
  now turns it on or off only for the session you type it in, for as long as
  that Claude Code window is open (`/clear` included). The new
  **`/devscope:voice auto-default on|off`** is the setting for every session
  where `auto` was not used; it is what `auto` used to change. `status` shows
  both. Your current setting carries over as the default.

## [0.27.0] - 2026-10-07

### Added
- **`/devscope:voice model [name|default]`** chooses which of the server's
  voices speaks. Without a name it lists them (`/api/ai/voice-models`, the
  first is the server's default); the choice is sent with every request as
  `model`, and `model default` goes back to the server's choice. The homelab
  now offers Chatterbox Turbo (the new default, on its Arc B580) and Kokoro
  (the previous voice, on its CPU, also the server's fallback when the GPU is
  busy). Needs a DevScope server with named voices (DowLucas/devscope); an
  older one ignores the choice.

## [0.26.0] - 2026-10-07

### Added
- **Quiet while the screen is locked.** Announcements are held and said soon
  after you unlock (if the session still waits, no reminder used up), auto voice
  is skipped, and an explanation stops after the current piece. Detected
  locally: macOS `ioreg` (`CGSSessionScreenIsLocked`) and the screensaver, Linux
  logind `LockedHint`; where it cannot tell (SSH, servers, lockers without
  LockedHint) speech plays as before. `/devscope:voice when-locked play|quiet`
  (default quiet); `status` shows the screen state.

### Fixed
- **Pauses and split phrases in spoken summaries.** Every summary over 200
  characters was voiced as two or three separate recordings, with a pause and
  restarted intonation between them, and a phrase was cut where no sentence
  ended in time. Text that fits one request (440 characters, so every normal
  summary) is now one recording, and longer text is split only between
  sentences.

## [0.25.1] - 2026-10-07

### Changed
- **Clearer pronunciation of technical terms.** Explanations are written for
  the voice: acronyms said letter by letter stay in capitals (API, CLI, PR),
  the rest are spelled as said ("jay-son", "the readme", "five seconds",
  "version two point one"), and identifiers, file names and flags are
  described rather than read out. The DevScope server now also rewrites every
  text it voices the same way (DowLucas/devscope).

## [0.25.0] - 2026-10-07

### Added
- **`/devscope:voice verbosity [explain|auto] short|normal|long`**: how detailed
  spoken responses are. Auto voice: one sentence, two or three (default), or
  four to six. Explain: about 40 seconds, a minute and a half (default), or three
  minutes, with a written card to match. Without a mode it sets both; plain
  `verbosity` shows them. `explain --short <topic>` / `--long` overrides it for
  one explanation. Auto voice's `long` needs a DevScope server with reply
  lengths (DowLucas/devscope); older servers give the normal length.

## [0.24.2] - 2026-10-07

### Fixed
- **The voice switched between a male and a female voice.** When a server-voice
  request failed, speech fell back at once to the local system voice (on macOS
  `say`, a female voice by default), sometimes partway through an explanation.
  The failures were passing: the DevScope API key rate limit (fixed on the
  server, DowLucas/devscope#81) and backend restarts. A request that fails with
  429, 401, 502, 503, 504 or no response is now tried again after 1.5 s before
  the local voice speaks, and the next piece of a long explanation, fetched
  while the current one plays, is tried up to four times.

## [0.24.1] - 2026-10-07

### Added
- `/devscope:voice speed <number>` sets any rate from 0.5 to 2 (`speed 1.35`;
  `1,35`, `1.35x` and `.8` work too), next to the `slow`/`normal`/`fast`
  presets. A number outside the range is refused rather than clamped, and
  `speed` shows a custom rate as itself (`1.35x`).

### Changed
- `/devscope:voice replies` is now **`/devscope:voice auto`** (auto voice: a spoken
  summary whenever Claude finishes a reply). `replies` still works.
- `/devscope:voice explain` speaks once, when you run it. Follow-up answers are
  text; turn on auto voice to hear them.

## [0.24.0] - 2026-10-07

### Added
- **`/devscope:voice explain [topic]`** talks a topic through out loud, simply, like a
  colleague at the whiteboard: the question, a concrete scenario, the options
  weighed with their catch, where it leans, and a question back to you. A short
  written card stays in the chat, and answering the question keeps the
  discussion going by voice. Long speech is voiced in pieces of at most 400
  characters, the next one fetched while the current one plays, so there are
  no gaps; if the server voice fails partway, the rest uses a local voice.
- **Spoken reply summaries**: `/devscope:voice replies` (toggle, or `on`/`off`)
  reads a two-to-three sentence summary of every reply Claude finishes,
  independent of the announcer. The reply is sent to your DevScope server to
  summarize and is not stored; in `private` mode you hear only which project
  finished, voiced locally. A turn that used `/devscope:voice explain` is not
  summarized on top. Needs a DevScope server with the `reply` voice-summary
  trigger; older servers fall back to "<project> is done".
- **`/devscope:voice speed slow|normal|fast`** (1.0x, 1.2x, 1.5x) for every
  engine: the server voice, Piper (length scale) and the system voices.
- **`/devscope:voice stop`** ends speech in progress.
- The speaker writes `~/.cache/devscope/voice/progress.json` (phase, piece, the
  piece's length from its WAV header, process group) while it speaks, for the
  devscope-live mod's progress bar (0.2.0).

### Changed
- The default speech rate is 1.2x (was 1.5x). A `speed` set in `voice.json`
  still wins.

## [0.23.0] - 2026-10-06

### Added
- **Model switches are recorded.** `PostModelSwitch` is registered again and
  sends `model.switch` (from/to model, requested model, source, context tokens,
  whether the prompt cache was warm). 0.15.1 unregistered it because Claude Code
  2.1.251 rejected the key; 2.1.291 accepts it and fires the hook, checked with
  a test plugin.

### Changed
- **Requires a Claude Code that accepts `PostModelSwitch` in `hooks.json`**
  (2.1.291 does; 2.1.251 does not). On an older Claude Code the whole
  `hooks.json` fails to load and no DevScope hook runs; update Claude Code.

## [0.21.1] - 2026-09-28

### Fixed
- AI summaries were often replaced by the plain template: the summary call gave
  up after 4 s, and Gemini takes about 3 s even when warm. It now waits up to
  10 s (in the background timer, so nothing waits on it).

### Added
- `volume` in `voice.json` (0.5-3) for the server voice. Unset, the server's
  default applies, now twice as loud as before.

## [0.21.0] - 2026-09-28

### Added
- **Server voice.** Voice announcements are now spoken by the DevScope server
  (`/api/ai/voice-audio`, a Kokoro model on the homelab) by default: a natural
  voice with nothing to install. Default voice `am_michael` at 1.5×; set
  `voice` and `speed` in `~/.config/devscope/voice.json`. New engine value
  `server` (`auto` prefers it). `private` sessions never use it, and when the
  server has no voice or can't be reached the announcer falls back to Piper or
  the system voice.

### Changed
- The test stub server can answer with a chosen status and content type.
- The "answered in time" test allows 3 s, so a slow runner can't beat it.

## [0.20.0] - 2026-09-25

### Added
- **Voice announcements when a session needs you.** `/devscope:voice on` makes
  DevScope speak when a session has waited on you past a grace delay: 30 s for
  a permission prompt or question, 10 s for a failed turn, optionally 2 min for
  a finished turn. Answer in time and it stays silent; otherwise it reminds you
  every 5 min, up to 3 times. Works across all your sessions: announcements
  never overlap, and three or more falling due within 15 s become one
  sentence. The sentence
  comes from the server's `/api/ai/voice-summary` and follows your privacy
  mode (standard sends no more than its events do; `private` never leaves the
  machine and uses a local template, as does any server failure). Speaks with
  Piper if installed (`/devscope:voice setup`), otherwise `say`/`spd-say`/
  `espeak`. Also `off`, `mute 1h`, `unmute`, `test`, `status`, `finished on`.
  Settings in `~/.config/devscope/voice.json`. `tests/voice/run.sh` (35 checks)
  in CI.
  An approved Bash command that runs past the delay is not announced: Claude
  Code has no approval hook, so the announcer checks for the command running
  under the session's `claude` process.

### Changed
- The test stub server also records every request path (`paths` in
  `tests/lib/stub.sh`).

## [0.19.0] - 2026-09-24

### Added
- **"You've hit this error before."** `scripts/error-recall.sh`, a synchronous
  PostToolUseFailure hook, sends the failed tool's error to the server's
  `/api/similar/error`. On a close match from the user's own earlier sessions,
  Claude gets whether it was resolved and how that turn ended, as
  `additionalContext`; the user sees a one-line notice. Once per distinct
  error per session, 20+ char errors only, interrupts skipped, 2 s cap, silent
  on any error, off with `DEVSCOPE_ERROR_RECALL=off`, never in private mode.
  `tests/errors/run.sh` (19 checks) in CI.
- **Next-skill hints.** `skill-hint.sh` now also runs after Skill tool calls
  and hints the skill the user most often runs next, from per-user chains
  `session-start.sh` caches from `/api/similar/skill-chains` (at most every
  6 hours, not in private mode or with hints off). Server-supplied names are
  validated before use. Honours `DEVSCOPE_HINTS` like the PR hint.

### Changed
- Synchronous hooks share `_ds_api` in `_helpers.sh` (API key via curl config,
  CSRF header, short timeout); the recall and error tests share a stub server
  in `tests/lib/`.

## [0.18.1] - 2026-09-24

### Fixed
- **Prompt recall never fired against a real server.** `prompt-recall.sh` did
  not send the `x-requested-with` header the backend's CSRF middleware requires
  on POSTs, so every call was rejected (and, by design, stayed silent). The test
  stub now enforces the same rule.

## [0.18.0] - 2026-09-24

### Added
- **"You've asked this before."** `scripts/prompt-recall.sh`, a synchronous
  UserPromptSubmit hook, asks the server's `/api/similar/preflight` whether the
  prompt nearly repeats one from the user's own earlier sessions. On a strong
  match, Claude gets a note with how it went (tool calls, failures, how it ended)
  as `additionalContext`, and the user sees a one-line notice. 4+ word prompts
  only (checked locally, so "yes" costs no round trip), 2 s cap, silent on any
  error, off with `DEVSCOPE_PREFLIGHT=off` (now also read from the config file),
  never in private mode. `tests/recall/run.sh` (15 checks, stub server) in CI.

### Fixed
- **The similar-prompts pre-flight never reached Claude.** It lived in
  `prompt-submit.sh`, which is registered async, and Claude Code ignores async
  hook output. Removed from there; replaced by the recall hook above.

## [0.17.0] - 2026-09-23

### Added
- **`DEVSCOPE_HINTS=claude`**: the PR hint is also passed to Claude as
  `additionalContext`, asking it to offer the next step in one sentence and not
  to run it unless the user agrees. Verified live: Claude ended its reply with
  "Want me to run `/code-review` on it?" and made no further tool calls. The
  default (`on`, alias `user`) is unchanged and user-only; unknown values fall
  back to it. `tests/hints/run.sh` grows to 24 checks.

## [0.16.0] - 2026-09-23

### Added
- **Next-step hint after opening a PR.** When a Bash call runs `gh pr create` and
  prints the new PR's URL, `scripts/skill-hint.sh` shows the user one line:
  "DevScope: PR opened. Review it next with /code-review?". DevScope data showed
  that opening a PR is the strongest precursor of a code review (about 1 in 6
  PRs, 16x the base rate) but too weak to invoke anything automatically, so this
  is a suggestion to the user only; Claude is not told and nothing runs. Shown
  once per PR per session, no network, silent on any error. It is the plugin's
  only synchronous hook (Claude Code ignores async hook output) and is matched
  to Bash alone; the non-PR path averages under 10 ms.
- `DEVSCOPE_HINTS` (`on`/`off`, default `on`) and `DEVSCOPE_HINT_AFTER_PR`
  (default `/code-review`; must look like `/name`, anything else falls back),
  read from the environment or `~/.config/devscope/config`.
- `tests/hints/run.sh`: 17 checks, including dedupe, config precedence, unsafe
  command values and the latency of the common path.

## [0.15.2] - 2026-09-22

### Fixed
- **Rate-limited events were dropped instead of retried.** `send-event.sh` and
  `drain-queue.sh` treated every 4xx as a permanently bad event and discarded it,
  including HTTP 429. The backend returns 429 from its per-IP ingest limit and
  (since devscope `f797aa2`) from the per-API-key limit, which previously surfaced
  as a 401. Replaying the outage queue after a backend restart is exactly what
  trips those limits, so the events buffered during the outage were the ones lost.
  A 429 is now buffered like a 5xx, and a drain that hits one keeps the file,
  backs off and stops the batch. Other 4xx are still dropped. Covered by phases 6
  and 7 of `tests/queue/run.sh`.

## [0.15.1] - 2026-08-29

### Fixed
- **`hooks.json` failed to load in its entirety on 0.15.0, disabling every hook in
  the plugin.** 0.15.0 registered `PostModelSwitch`, which Claude Code's
  hooks-config schema rejects:

      Failed to load hooks from .../0.15.0/hooks/hooks.json:
      "path": ["hooks", "PostModelSwitch"], "message": "Invalid key in record"

  Claude Code's *internal* runtime event list (33 entries) is not the same as the
  set of events registrable from `hooks.json`/`settings.json` (31). `PreModelSwitch`
  and `PostModelSwitch` fire internally but cannot be configured. 0.15.0 was built
  from the runtime list, so it registered one key the schema does not accept — and
  because the schema validates the whole record, a single bad key rejects the file
  and no hook loads at all. Upgrading from 0.15.0 restores all hooks.

  `scripts/model-switch.sh`, its smoke fixture, and the backend's `model.switch`
  payload schema are kept on disk so the event can be wired the day config
  registration is allowed; it is simply not registered. No `model.switch` events
  were ever emitted, since 0.15.0's hooks never loaded.

### Added
- `tests/check-hooks-consistency.sh` now validates every event key in `hooks.json`
  against the set the hooks-config schema accepts, and fails with an explicit note
  that an unsupported key disables the entire plugin. `claude plugin validate` does
  not catch this — in a repo that is also a marketplace it validates the
  marketplace manifest, not `hooks.json`.

## [0.15.0] - 2026-08-29

### Fixed
- **`WorktreeCreate`/`WorktreeRemove` are no longer registered.** These are not
  observation events: Claude Code branches on whether *any* `WorktreeCreate` hook
  is configured (`hasWorktreeCreateHook()`), and when one is, it stops running
  `git worktree add` itself and requires the hook to create the directory and echo
  its absolute path. DevScope's hook only POSTed telemetry, so `EnterWorktree` and
  `claude --worktree` failed in **every repository** with the plugin enabled, not
  just this one. `async: true` made it unrecoverable: an async hook is backgrounded
  and its late response is validated against a reduced schema (only
  `systemMessage`, `metrics`, `hookSpecificOutput.additionalContext`), so a printed
  path is discarded. `WorktreeRemove` had the same shape, silently suppressing
  worktree cleanup. The `worktree.create` / `worktree.remove` event types are gone.
- **`PreToolUse` can return a decision again.** It was registered `async: true`,
  which meant the `permissionDecision: "deny"` that `tool-use.sh` emits for
  hard-block nudge mode was discarded before it could take effect — an async
  hook's late response is validated against a reduced schema that has no
  permission fields. `PreToolUse` is now registered without `async`, and
  `tool-use.sh` announces `{"async": true}` on its first stdout line unless
  `DEVSCOPE_NUDGE_MODE=hard`. Claude Code backgrounds the process on seeing that
  line, so the default path costs the session nothing, while hard mode stays
  synchronous and its deny is honored.
- **Config file no longer overrides the environment.** `scripts/_helpers.sh`
  documented "env var > config file > default" but did the opposite: it assigned
  config values unconditionally, so `DEVSCOPE_PRIVACY=private` in the environment
  was discarded whenever `~/.config/devscope/config` named a mode — a silent
  privacy downgrade. The block was also skipped entirely when `DEVSCOPE_URL` was
  set, so exporting a URL discarded the configured API key and privacy mode. The
  config file is now always read and only fills in values the environment has not
  set.

### Added
- Nine hook events introduced in Claude Code since this plugin was last updated:
  | Event | Script | Event type |
  |---|---|---|
  | `PostToolBatch` | `tool-batch.sh` | `tool.batch` |
  | `UserPromptExpansion` | `prompt-expansion.sh` | `prompt.expansion` |
  | `StopFailure` | `response-failed.sh` | `response.failed` |
  | `PostModelSwitch` | `model-switch.sh` | `model.switch` |
  | `PermissionDenied` | `permission-denied.sh` | `permission.denied` |
  | `TaskCreated` | `task-created.sh` | `task.created` |
  | `CwdChanged` | `cwd-changed.sh` | `cwd.change` |
  | `DirectoryAdded` | `directory-added.sh` | `directory.added` |
  | `Setup` | `setup-hook.sh` | `plugin.setup` |
- Every event payload now carries the base hook-input fields Claude Code stamps on
  all events: `promptId` (correlates every event back to the user prompt that
  caused it, and joins to the `prompt.id` OpenTelemetry attribute), `permissionMode`,
  and `effortLevel`. Added to `payload`, not the envelope, so older backends keep
  accepting events unchanged.
- Smoke fixtures for all nine new hooks.
- A "Hook Selection Rule" section in `CLAUDE.md` recording which events delegate a
  job rather than report one, so this class of outage is not reintroduced.

### Deliberately not registered
- `PreModelSwitch` — gates the model switch and waits for an answer; a hook that
  fails or never answers can block or abort a model change.
- `MessageDisplay` — rewrites displayed assistant text and fires on every flush of
  every message.
- `FileChanged` — inert unless the plugin imposes absolute watch paths on the user,
  and high-volume once it is not.

### Notes for operators
- **Deploy the backend before releasing this plugin version.** The matching
  server-side change is in the `devscope` repo: the nine new types were added to
  the `eventType` enum in `packages/backend/src/routes/events.ts` and to the
  `EventType` union in `packages/shared/src/events.ts`, with dashboard rendering in
  `packages/dashboard/src/lib/eventDisplay.ts`. Until that is live, `zValidator`
  rejects the new types with 400, and `send-event.sh` treats 4xx as "reject and
  drop" (deliberately — retrying a malformed event would just fill the retry
  buffer), so each new event would be lost *and* write a
  `[devscope] Event delivery failed (HTTP 400)` line to stderr.
- `worktree.create` / `worktree.remove` were deliberately kept in the backend enum.
  Plugin versions before 0.15.0 stay installed in the wild and keep sending them;
  removing the enum members would turn their events into 400s. This plugin simply
  stops producing them, so those rows go dormant. Historical rows are untouched.
- No backend change is needed for `promptId` / `permissionMode` / `effortLevel`:
  `payload` is validated as `z.record(z.unknown())`.
- Verified against Claude Code 2.1.251.

## [0.11.1] - 2026-05-07

### Fixed
- Developer ID now lowercases + trims `git config user.email` before SHA256, matching the
  backend's `computeDeveloperId` (`devscope/packages/backend/src/services/developerLink.ts`).
  Previously, a mixed-case git email (e.g. `Test.User@Example.COM`) would hash differently on
  the plugin side than on the backend and fork the same human into two `developers` rows.
  Session/project hashes that mix the email into their input (`send-event.sh`,
  `session-start.sh`, `_ds_project_hash`) are also normalized so case-different emails resolve
  to the same on-disk session-state file.

### Added
- `_ds_normalize_email` helper in `scripts/_helpers.sh` so the normalization is auditable in
  one place and `_ds_sha256` stays a pure hash primitive.

### Notes for operators
- A backend that received events from a pre-`0.11.1` plugin **and** a post-`0.11.1` plugin for
  the same human with a mixed-case git email will have two `developers` rows for that human.
  The fix only stops the bleeding; previously-split rows need a one-time backend merge. That
  backfill is tracked as a separate follow-up issue and is not in scope here.

## [0.9.3] - 2026-05-05

### Added
- GitHub Actions CI on every PR (`.github/workflows/ci.yml`):
  - `shellcheck` over all hook scripts, the installer, and the new test
    helpers (severity = `warning`, with a documented `.shellcheckrc`).
  - `hooks.json` consistency check (`tests/check-hooks-consistency.sh`):
    every script referenced in `hooks/hooks.json` must exist on disk, every
    `scripts/*.sh` must be wired in `hooks.json` or on an explicit excluded
    allow-list (`_helpers.sh`, `send-event.sh`, `setup.sh`).
  - Smoke POST against a freshly-built DevScope backend container: replays
    recorded hook stdin fixtures (`tests/smoke/fixtures/`) through the real
    hook scripts and asserts the backend returns 2xx for every event.

## [0.3.1] - 2026-03-04

### Changed
- **Privacy mode rename**: `redacted` → `private`, `full` → `open`. Default changed from `redacted` to `standard`.
  - `private` — metadata only (tool names, file paths, durations)
  - `standard` — adds prompt text and full tool inputs **(new default)**
  - `open` — adds Claude's response content
- `setup.sh` expanded from 2 modes to 3, matching `install.sh`

### Backwards Compatible
- Old config values `DEVSCOPE_PRIVACY=redacted` and `DEVSCOPE_PRIVACY=full` are silently remapped to `private` and `open` respectively — no user action required

## [0.3.0] - 2026-03-03

### Added
- Full installer (`install.sh`) with gum UI and 3-step onboarding
- `jq` prerequisite check — fails early with install instructions
- `/devscope:setup` slash command for reconfiguration
- Additional hooks: `SubagentStart`, `SubagentStop`, `Notification`, `PreCompact`, `TaskCompleted`, `PermissionRequest`, `WorktreeCreate`, `WorktreeRemove`, `ConfigChange`

### Fixed
- `eval` + `jq` pattern in tool hooks corrupted JSON (quotes stripped). Replaced with safe per-field `jq -r` extraction.
- HTTP errors from `send-event.sh` now logged to stderr

## [0.2.0] - 2026-03-01

### Added
- `standard` privacy mode — sends prompt text and tool inputs in addition to metadata
- Session continuity: context clears and compactions preserve the DevScope session ID
- Git commit hash tracked in session start/end events

## [0.1.0] - 2026-02-27

### Added
- Initial plugin with `SessionStart`, `SessionEnd`, `PreToolUse`, `PostToolUse`, `Stop` hooks
- Privacy modes: `redacted` (default) and `full`
- Config file support (`~/.config/devscope/config`)
- Cross-platform SHA256, timestamps, and UUID helpers

[0.3.1]: https://github.com/DowLucas/devscope-plugin/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/DowLucas/devscope-plugin/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/DowLucas/devscope-plugin/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/DowLucas/devscope-plugin/releases/tag/v0.1.0
