# Contributing to DevScope Plugin

Thanks for your interest! This repo contains the Claude Code plugin (bash hooks) for DevScope.

## Development

1. Clone this repo
2. Test locally: `claude --plugin-dir /path/to/devscope-plugin`
3. Make changes to scripts in `scripts/`
4. Test that events are sent correctly to a running DevScope server

## Guidelines

- Keep scripts POSIX-compatible where possible
- Test on both Linux and macOS
- All hooks must be async/non-blocking (exit 0 quickly, errors suppressed)
- Use the helpers in `scripts/_helpers.sh` for cross-platform operations

## Server & Dashboard

For changes to the backend, dashboard, or shared types, see the [main DevScope repo](https://github.com/DowLucas/devscope).

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
