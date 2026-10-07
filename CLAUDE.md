# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is This

The Claude Code plugin for [DevScope](https://github.com/DowLucas/devscope). It hooks into Claude Code lifecycle events and sends them to a DevScope server for real-time monitoring.

This is a **standalone plugin repo** (`DowLucas/devscope-plugin`) that acts as both the plugin source and its own marketplace. There is no copy in the main DevScope monorepo.

## Plugin Structure

```
.claude-plugin/
  plugin.json          # Plugin manifest (name, version, description)
  marketplace.json     # Marketplace manifest (makes this repo a marketplace)
hooks/
  hooks.json           # Hook event → script mappings
commands/
  setup.md             # /devscope:setup slash command definition
  voice.md             # /devscope:voice (on/off/replies/speed/mute/stop/test/setup)
  explain.md           # /devscope:explain (spoken, discussion-style explanation via voice/cli.sh say)
  backfill-usage.md    # /devscope:backfill-usage (exact usage for past sessions)
scripts/
  _helpers.sh          # Shared helpers (config loading, SHA256, timestamps)
  token_usage.py       # Exact per-model token totals from transcripts (Stop/SessionEnd, /devscope:backfill-usage)
  send-event.sh        # Core event sender (all hooks call this)
  session-start.sh     # SessionStart hook
  session-end.sh       # SessionEnd hook
  tool-use.sh          # PreToolUse hook
  tool-complete.sh     # PostToolUse / PostToolUseFailure hook
  prompt-submit.sh     # UserPromptSubmit hook
  response-stop.sh     # Stop hook
  agent-start.sh       # SubagentStart hook
  agent-stop.sh        # SubagentStop hook
  notification.sh      # Notification hook
  pre-compact.sh       # PreCompact hook
  task-completed.sh    # TaskCompleted hook
  permission-request.sh # PermissionRequest hook
  config-change.sh     # ConfigChange hook
  tool-batch.sh        # PostToolBatch hook
  prompt-expansion.sh  # UserPromptExpansion hook
  response-failed.sh   # StopFailure hook
  model-switch.sh      # PostModelSwitch hook
  permission-denied.sh # PermissionDenied hook
  task-created.sh      # TaskCreated hook
  cwd-changed.sh       # CwdChanged hook
  directory-added.sh   # DirectoryAdded hook
  setup-hook.sh        # Setup hook (plugin init/maintenance)
  setup.sh             # Interactive setup (used by install.sh) — NOT a hook
  voice/               # Voice: lib.sh (arm/clear/announce, replies, long speech), timer.sh, speak.sh, cli.sh
install.sh             # One-liner installer with gum UI
mods/devscope-live/    # Second plugin: a Claude Code mod (see below)
docs/specs/            # Design specs
```

## DevScope Live mod (`mods/devscope-live`)

A separate plugin in the same marketplace (`source: ./mods/devscope-live`), built on
Claude Code's function hooks ("mods", early access; verified on 2.1.291). Design and the
`/api/live` backend contract: `docs/specs/2026-10-06-devscope-live-design.md`. It adds
in-session features (team prompts, team skills, stuck band, outcome labels, commit/PR
links); the Bash plugin still ships all events. It has its own version in its
`plugin.json` and its `marketplace.json` entry (keep both in sync); changing it does not
require bumping the `devscope` plugin.

```bash
claude plugin validate mods/devscope-live   # what the engine would refuse
claude plugin test mods/devscope-live       # tests/*.test.ts(x) against the engine
# Loading the mod writes .claude-plugin/types/ (self-ignored) and tsconfig.json (ignored).
```

Rules the engine enforces (learned the hard way):
- `$` may only be passed to functions **declared at the top level of the same file**. All
  I/O (`$.http`, `$.store`, `$.process`, ...) lives in `hooks/register.tsx`; the other
  files in `hooks/` are pure logic, which is also what the logic tests import.
- `$.http.fetch` has no timeout: race it with `$.clock.sleep`. Network work never runs
  inside `session.start` (it would delay the first prompt): schedule it with
  `$.clock.after(0, ...)`.
- Gating hooks (`prompt.submit`, `tool.call`) carry `.catch(($, e, next) => next(e))` so a
  failure lets the call through without running it twice.
- In tests, every event the test raises needs a stand-in beneath the plugin
  (`on('prompt.submit', ...)`, `on('session.cwd', ...)`, ...), each event hooked once and
  before the test's first `$` call; events take their full input (`origin`, `wait`).
  `mock.clock` starts near 0, so "last time" defaults must be `-Infinity`, not 0.

## Hook Selection Rule

Only register hook events that Claude Code treats as **observations**. Some events
delegate a *job* to the hook, and registering one makes Claude Code stop doing that
job itself — merely being registered claims the role, whether or not the hook is
`async`:

- `WorktreeCreate` / `WorktreeRemove` — Claude Code branches on
  `hasWorktreeCreateHook()`; a registered hook must create the directory and echo
  its absolute path, or worktree isolation fails for every repo. **Never register.**
- `PreModelSwitch` — gates the model switch and waits for an answer. **Never
  register.**
- An event key the hooks-config schema does not accept fails validation for the
  **whole file**, so every hook in the plugin stops loading. 0.15.0 registered
  `PostModelSwitch`, which Claude Code 2.1.251 rejected, and disabled the plugin.
  2.1.291 accepts it, so 0.23.0 registers it again; on a Claude Code too old to
  accept the key, no DevScope hook loads. `tests/check-hooks-consistency.sh`
  enforces the accepted set; note that `claude plugin validate` does **not**
  check `hooks.json` in this repo, because it validates the marketplace manifest
  instead.
- `MessageDisplay` — rewrites displayed assistant text and fires on every flush of
  every message. **Never register.**

Events whose output is *optional* (`PreToolUse`, `PostToolUse`, `PostToolBatch`,
`Stop`, `TaskCompleted`, `PermissionRequest`, `PermissionDenied`, `Elicitation`,
`UserPromptExpansion`) are safe: staying silent means "no opinion".

Note that `async: true` makes a hook fire-and-forget. Its late response is
validated against a reduced schema that accepts only `systemMessage`, `metrics`,
and `hookSpecificOutput.additionalContext` — any permission decision, block, or
path it prints is discarded. A hook that must return a decision cannot be `async`.

## Claude Code Marketplace

### How It Works

This repo is both a **plugin** and a **marketplace**. The `.claude-plugin/marketplace.json` file makes it discoverable as a marketplace, and `.claude-plugin/plugin.json` defines the plugin itself.

Users install the plugin with two commands:
```bash
# 1. Add this repo as a marketplace source
claude plugin marketplace add DowLucas/devscope-plugin

# 2. Install the plugin from that marketplace
claude plugin install devscope
```

Or via the one-liner installer (`install.sh`) which does both steps automatically.

### Versioning

**Version bumps are required** for `claude plugin update` to fetch new code. Claude Code caches plugins by version at `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`.

The version is set in `.claude-plugin/plugin.json`. The `marketplace.json` also has a version field — keep them in sync (plugin.json takes priority if they differ).

To release a new version:
1. Bump `version` in `.claude-plugin/plugin.json`
2. Bump `version` in `.claude-plugin/marketplace.json` (keep in sync)
3. Commit and push to `main`
4. Users run `claude plugin update devscope` (restart required to apply)

**GitHub raw content has ~5 min cache**, so updates may not be immediately visible after push.

### Local Development / Testing

```bash
# Test plugin locally without installing from marketplace
claude --plugin-dir /path/to/devscope-plugin

# Force-update cache without waiting for GitHub cache expiry
cp -r . ~/.claude/plugins/cache/devscope/devscope/<version>/
```

### CLI Reference

```bash
claude plugin marketplace add DowLucas/devscope-plugin  # Add marketplace
claude plugin install devscope                           # Install
claude plugin update devscope                            # Update (bump version first!)
claude plugin uninstall devscope                         # Uninstall
claude plugin marketplace remove devscope                # Remove marketplace
claude plugin list                                       # List installed plugins
claude plugin marketplace list                           # List marketplaces
claude plugin validate .                                 # Validate plugin structure
claude plugin enable devscope@devscope                   # Enable
claude plugin disable devscope@devscope                  # Disable
```

### Installation Scopes

| Scope | Flag | Settings file | Use case |
|---|---|---|---|
| `user` (default) | `--scope user` | `~/.claude/settings.json` | Personal, across all projects |
| `project` | `--scope project` | `.claude/settings.json` | Shared with team via VCS |
| `local` | `--scope local` | `.claude/settings.local.json` | Project-specific, gitignored |

### Plugin Internals

- **`${CLAUDE_PLUGIN_ROOT}`**: Environment variable set by Claude Code, resolves to the plugin's cache directory. All `hooks.json` script paths use this.
- **Installed plugins path**: `~/.claude/plugins/cache/devscope/devscope/<version>/`
- **Marketplace source path**: `~/.claude/plugins/marketplaces/devscope/` (git clone of this repo)
- **Plugin config**: `~/.claude/plugins/installed_plugins.json` and `~/.claude/settings.json` (`enabledPlugins`)

## Key Patterns

- Hook scripts are **non-blocking** — they must exit quickly and suppress errors. All but
  one get this from `"async": true` in `hooks.json`. `PreToolUse` is the exception: it is
  registered *without* `async` so it can return a `permissionDecision`, and `tool-use.sh`
  instead announces `{"async": true}` on its first stdout line unless
  `DEVSCOPE_NUDGE_MODE=hard`. Claude Code backgrounds the process on seeing that line, so
  the common path costs the session nothing while hard mode stays synchronous and can deny.
- Cross-platform support: Linux + macOS (SHA256, timestamps, UUID all have OS-specific fallbacks in `_helpers.sh`)
- Config is read from `~/.config/devscope/config` (or `$XDG_CONFIG_HOME/devscope/config`)
- Developer identity: `SHA256(git config user.email)`
- Events POST to `$DEVSCOPE_URL/api/events` with optional `x-api-key` header
- **Voice announcer** (opt-in, `/devscope:voice on`, settings in `~/.config/devscope/voice.json`):
  `send-event.sh` calls `_ds_voice_on_event` for every event. Blocking events (permission
  prompt, `AskUserQuestion`, elicitation, `StopFailure`, optionally `Stop`) write a marker to
  `~/.cache/devscope/voice/pending/<session>.json` and start a detached `timer.sh`; later
  activity from that session deletes the marker (tool events only for the same tool, so a
  parallel tool does not count as an answer). No hook fires on approval, so
  before speaking a Bash permission marker the timer checks whether the session's `claude`
  process has a child shell running that command (recorded locally at arm time); if so it
  was approved and the marker is dropped. When the grace delay passes with the marker
  still there, the timer takes the global speak lock and speaks every due marker: an AI
  sentence from `/api/ai/voice-summary`, or a local template for `private` sessions or when
  the backend fails; three or more due within 15 s become one sentence. Speech uses the
  server voice by default (`/api/ai/voice-audio`, Kokoro on the homelab; `voice`/`speed` in
  voice.json, default `am_michael`; `speed` 1.2× by default, presets slow 1.0 / normal 1.2 / fast 1.5
  via `/devscope:voice speed`, applied to every engine), never for `private` sessions; if the server has
  no voice or is unreachable it falls back to Piper if installed (`/devscope:voice setup`),
  else `say`/`spd-say`/`espeak`. What is sent follows the
  privacy mode: `standard` sends no more than its events do. Tests: `tests/voice/run.sh`.
- **Reply summaries** (opt-in, `/devscope:voice replies`, `speak_replies` in voice.json) are
  independent of the announcer. On `response.complete`, `_ds_voice_on_reply_event` writes
  `replies/<session>.json` (the reply's first 2800 + last 1100 chars; nothing for `private`)
  and spawns `speak.sh reply`, which asks `/api/ai/voice-summary` with `trigger: "reply"`
  and speaks under the lock; a newer reply from the same session replaces an older one.
  This deliberately sends response text in `standard` mode too: the user turned the
  feature on for exactly that, and the endpoint stores nothing.
- **Long speech** (`/devscope:explain` → `cli.sh say`, text on stdin): `speak.sh say` speaks
  it detached via `_ds_voice_speak_long`, which splits it into pieces of at most 400
  characters (first at most 200, so speech starts fast; `voice-audio` takes 440) and fetches
  the next piece while the current one plays. `say` touches `spoke/<claude-pid>` so that
  turn's reply is not also summarized; the Stop hook consumes it, a new prompt clears it.
  `cli.sh stop` kills every registered `speakers/<pid>` process group.

## Token usage

`response.complete` and `session.end` carry two usage fields:

- `usageSnapshot` (0.23.0+): exact cumulative totals per model for the transcript and its
  `<session>/subagents/*.jsonl`, from `scripts/token_usage.py`. Each API call is logged once
  per content block, so calls are deduplicated by `message.id` (last line wins); entries from
  another `sessionId` and `<synthetic>` messages are skipped. Parsing is incremental, with byte
  offsets cached in `~/.cache/devscope/usage/<transcript>.json`. Tests: `tests/usage/run.sh`.
- `tokenUsage`: the LAST API call's usage only (`_ds_extract_token_usage`). Not a running
  total. Still sent because older servers read it and the server's estimator uses it as the
  per-turn context size.

## Making Changes

1. Edit scripts in `scripts/`
2. Test locally: `claude --plugin-dir .`
3. Bump version in both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
4. Push to main

**Important — two version bumps required:** When releasing, bump the version in both:
- `.claude-plugin/plugin.json` (`"version"` field)
- `.claude-plugin/marketplace.json` (`plugins[0].version` field)

Both must match. Without bumping both, `claude plugin update devscope` won't pick up new code.
