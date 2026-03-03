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
scripts/
  _helpers.sh          # Shared helpers (config loading, SHA256, timestamps)
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
  worktree-create.sh   # WorktreeCreate hook
  worktree-remove.sh   # WorktreeRemove hook
  config-change.sh     # ConfigChange hook
  setup.sh             # Interactive setup (used by install.sh)
install.sh             # One-liner installer with gum UI
```

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

- All hook scripts are **async and non-blocking** — they must exit quickly and suppress errors
- Cross-platform support: Linux + macOS (SHA256, timestamps, UUID all have OS-specific fallbacks in `_helpers.sh`)
- Config is read from `~/.config/devscope/config` (or `$XDG_CONFIG_HOME/devscope/config`)
- Developer identity: `SHA256(git config user.email)`
- Events POST to `$DEVSCOPE_URL/api/events` with optional `x-api-key` header

## Making Changes

1. Edit scripts in `scripts/`
2. Test locally: `claude --plugin-dir .`
3. Bump version in both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
4. Push to main

**Important — two version bumps required:** When releasing, bump the version in both:
- `.claude-plugin/plugin.json` (`"version"` field)
- `.claude-plugin/marketplace.json` (`plugins[0].version` field)

Both must match. Without bumping both, `claude plugin update devscope` won't pick up new code.
