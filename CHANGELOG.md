# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
