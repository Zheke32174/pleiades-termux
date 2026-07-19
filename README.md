# Pleiades Android Edge Node

`pleiades-termux` is the constrained Android/Termux edge adapter for Pleiades.

It is not a portable copy of the server swarm. It does not emulate systemd, root, `systemd-nspawn`, host policy authority, process-kill authority, or an arbitrary command broker. Its supported job is deliberately smaller:

- create a stable local node identity;
- accept typed observation events;
- preserve them in a private durable queue;
- expose local status and capability declarations;
- export a copy for an authenticated upstream ingestion path;
- serve as an operator client for separately authorized systems.

## Why this repository changed

The earlier adaptation copied server scripts into Termux and replaced unavailable commands such as `systemctl`, `sudo`, and `nsenter` with compatibility functions. That made incompatible scripts appear successful while silently removing their real security and lifecycle semantics.

The v1 edge runtime removes that illusion. Unsupported authority is now declared absent rather than simulated.

## Current boundary

```text
Android / Termux observations
          ↓
pleiades.event/v1 validation
          ↓
private append-only local queue
          ↓ explicit export copy
future authenticated ingestion gateway
          ↓
Pleiades evidence and knowledge planes
```

There is no automatic network transmission in this repository yet. Export does not delete or acknowledge queued records.

## Quick start

```bash
pkg install python git

git clone https://github.com/Zheke32174/pleiades-termux.git
cd pleiades-termux
bash env/bootstrap-termux.sh --install-shell-hook

pleiades doctor
pleiades info
```

Emit a typed observation:

```bash
pleiades emit android.package.observed \
  --severity notice \
  --source package-inventory \
  --payload-json '{"package":"example.app","state":"installed"}'
```

Inspect and export the queue:

```bash
pleiades show --limit 20
pleiades export "$HOME/storage/shared/pleiades-edge.jsonl"
```

The export is a copy. A future authenticated transport must acknowledge event IDs before local compaction is introduced.

## CLI

| Command | Purpose |
|---|---|
| `pleiades init` | Initialize private state and node identity |
| `pleiades info` | Generate and print a local status snapshot |
| `pleiades doctor` | Check Termux, permissions, and runtime assumptions |
| `pleiades capabilities` | Show implemented and explicitly absent capabilities |
| `pleiades emit ...` | Append one typed observation event |
| `pleiades show` | Inspect recent queued events |
| `pleiades export PATH` | Atomically copy the queue to a private export file |

## Runtime layout

By default, state lives under:

```text
~/.local/share/pleiades-edge/
├── config/
│   ├── node.json
│   └── capabilities.json
├── state/
│   ├── sequence
│   └── status.json
├── queue/
│   └── events.jsonl
├── exports/
└── tools/
```

Directories are created with private permissions. Runtime state, exports, credentials, and local overrides must not be committed.

## Legacy scripts

The repository still contains historical copied scripts under `scripts/` and several old top-level helpers so their provenance and prior experiments are not destroyed during this transition. They are **not part of the supported v1 runtime**, are not installed by `bootstrap-termux.sh`, and must not be interpreted as Android-safe simply because they have a Termux shebang.

The intended cleanup path is:

1. extract any genuinely useful sensor mechanism;
2. rewrite it as an observation-only adapter producing `pleiades.event/v1`;
3. test it without fake privilege or lifecycle commands;
4. delete or archive the copied legacy implementation.

## Security properties

- No global command overrides.
- No `sudo`, systemd, container, or namespace emulation.
- No API-key template generation.
- No automatic edits to shell startup files unless `--install-shell-hook` is explicit.
- No automatic third-party repository cloning.
- No direct policy or enforcement action.
- Event IDs and monotonic per-node sequence numbers support future replay protection.
- Queue writes are locked and flushed before success is reported.
- Export is atomic and non-destructive.

## Relationship to the other Termux repositories

- `pleiades-container-termux` is now a deprecation/redirect repository because nspawn containers cannot be meaningfully implemented in ordinary Termux.
- `pleiades-factory-stack-termux` is a thin platform adapter to the canonical locked `pleiades-factory-stack`; it must not maintain a second floating tool list.
- `pleiades-factory` evaluates evidence and promotion eligibility off-device; this edge node has no promotion authority.

## Development

```bash
python3 -m py_compile bin/pleiades-edge.py
python3 -m unittest discover -s tests -v
bash -n env/*.sh
```

## License

MIT — see [LICENSE](LICENSE).
