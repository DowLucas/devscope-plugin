# DevScope Plugin

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Claude Code plugin for [DevScope](https://github.com/DowLucas/devscope) — real-time developer session monitoring.

This plugin hooks into Claude Code lifecycle events (session start/end, tool use, prompts, etc.) and sends them to a DevScope server for real-time visualization.

## Install

**One-liner (recommended):**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DowLucas/devscope-plugin/main/install.sh)
```

This interactive installer handles plugin installation, server configuration, and connection testing.

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
DEVSCOPE_URL=https://devscope.example.com
DEVSCOPE_API_KEY=your-api-key-here
EOF
```

## Configuration

The plugin reads configuration in this priority order:

1. **Environment variables**: `DEVSCOPE_URL`, `DEVSCOPE_API_KEY`
2. **Config file**: `~/.config/devscope/config` (or `$XDG_CONFIG_HOME/devscope/config`)
3. **Default**: `http://localhost:6767`

## Prerequisites

- [Claude Code](https://claude.ai/code) CLI
- `jq` (JSON processor)
- `curl`
- A running [DevScope](https://github.com/DowLucas/devscope) server

## How It Works

The plugin registers bash hooks for Claude Code lifecycle events:

| Event | What's Tracked |
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

## Contributing

For plugin-specific changes, open a PR here. For server/dashboard changes, see the [main DevScope repo](https://github.com/DowLucas/devscope).

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE)
