# Pleiades Termux Companion

Android/Termux companion repo for Pleiades. It adapts the desktop/container-oriented Pleiades workflow so it can run from Termux with no systemd, no root requirement, and no systemd-nspawn dependency.

## What This Is

Pleiades Termux Companion provides the mobile-side environment, compatibility helpers, setup scripts, and adapted agent scripts used to run Pleiades workflows from Android/Termux.

It is intended for owner-authorized development, defensive research, local automation, and lab testing.

## What's Adapted

| Original | Termux Adaptation |
|----------|------------------|
| Gentoo `systemd-nspawn` container | Direct bash script execution |
| `/var/`, `/run/`, `/etc/` paths | `$PREFIX/var/pleiades/`, `$TMPDIR/pleiades/` |
| `systemctl`, `systemd-nspawn`, `sudo`, `nsenter` | Compatibility stubs in `pleiades-termux-lib.sh` |
| Agent scripts in container `root.x86_64/scripts/` | Symlinked to `$PLEIADES_SCRIPTS` |
| WSL-specific boot scripts | Skipped with Termux guard |

## Quick Start

```bash
# Source environment (add to ~/.zshrc or ~/.bashrc)
source env/pleiades-env.sh

# Bootstrap the environment
bash env/bootstrap-termux.sh

# Verify
pleiades info
```

## Repo Map

| Sister Repo | Original | Purpose |
|-------------|----------|---------|
| **pleiades-termux** | [pleiades](https://github.com/Zheke32174/pleiades) | Host scripts, agent suite, env config |
| [pleiades-container-termux](https://github.com/Zheke32174/pleiades-container-termux) | [pleiades-container](https://github.com/Zheke32174/pleiades-container) | Container bootstrap/reference stubs |
| [pleiades-factory-stack-termux](https://github.com/Zheke32174/pleiades-factory-stack-termux) | [pleiades-factory-stack](https://github.com/Zheke32174/pleiades-factory-stack) | Toolchain bootstrap |

## Files Layout

```
pleiades-termux/
├── env/
│   ├── pleiades-env.sh           — Source this for environment
│   ├── pleiades-termux-lib.sh    — Compatibility layer (stubs, path maps)
│   ├── pleiades-termux-cli.sh    — `pleiades` CLI command
│   ├── bootstrap-termux.sh       — One-shot setup
│   ├── pleiades-mcp-config.json.tpl  — MCP config template
│   └── tool-manifest.json.tpl        — Tool manifest template
├── scripts/                      — Adapted agent scripts
├── pleiades-backup.sh            — Backup helper
├── pleiades-factory-tools.sh     — Factory tools CLI
├── tm-context.sh                 — Task Master context bridge
└── setup-agent-tools.sh          — Agent tool setup
```

## Key Differences from Original

- `PLEIADES_ENV=termux` environment variable enables Termux mode
- All scripts source `pleiades-termux-lib.sh` for path/stub compatibility
- No systemd, systemd-nspawn, WSL, or sudo dependency
- Data stored under `$PREFIX/var/pleiades/` and `$TMPDIR/pleiades/`
- Factory tools bootstrap clones to `$PLEIADES_TOOLS`

## Safety Notes

- Review scripts before running them on a daily-use device.
- Lab/stress-test scripts are intended for controlled local testing only.
- Do not commit local config files, API keys, tokens, evidence logs, or device-specific output.
