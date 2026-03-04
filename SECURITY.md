# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest  | Yes       |

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Instead, report them privately via GitHub's [private vulnerability reporting](https://github.com/DowLucas/devscope-plugin/security/advisories/new) feature, or email the maintainer directly (see GitHub profile).

Include as much detail as possible:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

You can expect an acknowledgement within 48 hours and a resolution timeline within 7 days for critical issues.

## Scope

This plugin runs bash scripts on your local machine and sends anonymized telemetry to a DevScope server. Key security properties:

- **No credentials are ever sent** — only hashed developer identity (SHA256 of git email)
- **API key is read from config file** and sent only as an HTTP header to your configured server
- **All network requests are fire-and-forget** — failures are silently suppressed
- Config file permissions are set to `600` on creation

If you find a way to leak credentials, exfiltrate data, or execute arbitrary code through the plugin, please report it privately.
