# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
