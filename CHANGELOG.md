# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.15.0] - 2026-05-09

### Added
- **DEV-94**: `tool_use_id` is now forwarded as `toolUseId` on `tool.start`,
  `tool.complete`, and `tool.fail` payloads. Lets the backend/dashboard pair
  start/complete events reliably even when the same tool runs concurrently in
  parallel sub-agent calls (closes [DowLucas/devscope#3](https://github.com/DowLucas/devscope/issues/3)).
  - `scripts/tool-use.sh` and `scripts/tool-complete.sh` use a `tool_use_id`-scoped
    timing-file path (`~/.cache/devscope/timings/<session>_<toolUseId>`) so concurrent
    same-tool starts each get their own file. Falls back to the legacy
    `<session>_<toolName>` path when the host hook input omits `tool_use_id`.
  - Smoke fixtures updated to include `tool_use_id`.

- **DEV-96**: `PermissionRequest` hook events now include `toolInput` in the payload
  (closes [DowLucas/devscope#6](https://github.com/DowLucas/devscope/issues/6)).
  - `scripts/permission-request.sh` extracts `tool_input` and applies the same
    privacy-mode redaction used by `tool-use.sh`: `standard`/`open` modes pass the
    full input; `private` mode hashes paths, drops command/content/old_string/new_string.
  - `permission_suggestions` is intentionally omitted (low signal vs. payload size).

### Notes for operators
- Both changes are backwards-compatible: older plugin versions continue to work;
  consumers fall back to previous behaviour when the new fields are absent.

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
