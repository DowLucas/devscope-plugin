# DevScope Plugin

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Cloud](https://img.shields.io/badge/Cloud-devscope.sh-blueviolet)](https://devscope.sh)
[![GitHub](https://img.shields.io/badge/GitHub-DowLucas%2Fdevscope-181717?logo=github)](https://github.com/DowLucas/devscope)

Claude Code plugin for [DevScope](https://github.com/DowLucas/devscope) — real-time developer session monitoring.

This plugin hooks into Claude Code lifecycle events (session start/end, tool use, prompts, agents, etc.) and sends them to a DevScope server for real-time visualization and team insights.

## Quick Start

**One-liner install:**

```bash
curl -fsSL https://raw.githubusercontent.com/DowLucas/devscope-plugin/main/install.sh | bash
```

The interactive installer handles plugin installation, server selection, and connection testing.

> **Using the cloud?** Select `https://devscope.sh` during setup — no server to run. Sign up at [devscope.sh](https://devscope.sh) to get your API key.

**Manual install:**

```bash
# Add the marketplace (one-time)
claude plugin marketplace add DowLucas/devscope-plugin

# Install the plugin
claude plugin install devscope
```

## Setup

Type `/devscope:setup` in Claude Code to interactively configure your server URL and API key.

Or manually create `~/.config/devscope/config`:

```bash
mkdir -p ~/.config/devscope
cat > ~/.config/devscope/config <<EOF
DEVSCOPE_URL=https://devscope.sh
DEVSCOPE_API_KEY=your-api-key-here
EOF
```

## Server Options

| Option | URL | Description |
|---|---|---|
| **Cloud (recommended)** | `https://devscope.sh` | Hosted for you — sign up, get an API key, done |
| Self-hosted (Docker) | `https://your-domain.com` | Run your own instance with [Docker](https://github.com/DowLucas/devscope#self-hosting-with-docker) |
| Local development | `http://localhost:6767` | For contributors working on DevScope itself |

## Configuration

The plugin reads configuration in this priority order:

1. **Environment variables**: `DEVSCOPE_URL`, `DEVSCOPE_API_KEY`
2. **Config file**: `~/.config/devscope/config` (or `$XDG_CONFIG_HOME/devscope/config`)
3. **Default**: `http://localhost:6767`

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- `jq` (JSON processor)
- `curl`
- A DevScope server — [devscope.sh](https://devscope.sh) (cloud) or [self-hosted](https://github.com/DowLucas/devscope)

## Privacy Modes

Control what data is sent to the server with the `DEVSCOPE_PRIVACY` setting in `~/.config/devscope/config`:

| Mode | What's sent | Use when |
|---|---|---|
| `private` | Tool names, file paths, durations only | Maximum privacy — no prompt or response content |
| `standard` | Everything in `private` + prompt text + full tool inputs | **Default** — good balance for team insights |
| `open` | Everything in `standard` + Claude's response text | Full session replay in the dashboard |

**Set your privacy mode:**

```bash
# In ~/.config/devscope/config
DEVSCOPE_PRIVACY=standard   # default
DEVSCOPE_PRIVACY=private    # metadata only
DEVSCOPE_PRIVACY=open       # include response text
```

Or run `/devscope:setup` in Claude Code to reconfigure interactively.

> **Backwards compatibility**: Old values `redacted` and `full` are automatically mapped to `private` and `open` respectively — no config changes needed.

## What's Tracked

| Event | Data Sent |
|---|---|
| Session start/end | Session duration, permission mode |
| Tool use | Tool name, duration, success/failure |
| Prompt submit | Prompt length |
| Subagent start/stop | Agent type |
| Response complete | Tools used, response length |
| Task completed | Task details |
| And more... | Notifications, compaction, config changes |

All hooks are **async and non-blocking** — they won't slow down your Claude Code sessions.

## Platform Support

Works on **Linux** and **macOS**. Cross-platform compatibility is handled automatically for:
- SHA256 hashing (`sha256sum` / `shasum` / `openssl`)
- Nanosecond timestamps (GNU date / python3 / perl fallback)
- UUID generation (`/proc/sys/kernel/random/uuid` / `uuidgen`)

## Links

- [DevScope Cloud](https://devscope.sh) — hosted dashboard
- [DevScope Server](https://github.com/DowLucas/devscope) — self-host the backend & dashboard
- [Issues](https://github.com/DowLucas/devscope/issues) — bug reports & feature requests

## Troubleshooting

### Events not appearing in dashboard

**Missing git identity** — the plugin derives your developer ID from `git config user.email`. If it's not set, events can't be attributed:

```bash
git config --global user.email "you@example.com"
git config --global user.name "Your Name"
```

The installer checks for this, but if you skipped the warning, set them now.

**Config not loaded** — verify your config:

```bash
cat ~/.config/devscope/config
# Should show DEVSCOPE_URL and DEVSCOPE_API_KEY
```

**Server unreachable** — test the connection:

```bash
curl -sf "$(grep DEVSCOPE_URL ~/.config/devscope/config | cut -d= -f2)/api/health"
```

**Invalid API key** — generate a new key from Dashboard > Settings > API Keys.

### Plugin not running

Check that the plugin is installed and enabled:

```bash
claude plugin list
```

If missing, reinstall:

```bash
claude plugin marketplace add DowLucas/devscope-plugin
claude plugin install devscope
```

### Update not taking effect

Claude Code caches plugins by version. After updating:

```bash
claude plugin update devscope
# Restart Claude Code for changes to take effect
```

## Contributing

For plugin-specific changes, open a PR here. For server/dashboard changes, see the [main DevScope repo](https://github.com/DowLucas/devscope).

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE)
