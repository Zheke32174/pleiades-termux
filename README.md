# Pleiades Android Edge Node for Termux

> **Status:** experimental but working local edge runtime. The queue, identity, contiguous delivery stream, event validation, export, and refusal behavior are tested. Automatic authenticated upload, receipt processing, and acknowledged compaction are not implemented.

`pleiades-termux` is the constrained Android/Termux observation edge for Pleiades. It is not an Android APK, server swarm, root manager, container runtime, policy authority, ingress receiver, or arbitrary command broker.

Its supported role is deliberately small:

- create one stable local node identity;
- create one durable local delivery-stream identity;
- accept typed `pleiades.event/v1` observations;
- append them to a private durable local queue with contiguous delivery sequence;
- expose local status, stream continuity, and explicit capability declarations;
- export a non-destructive copy for later reviewed ingestion;
- remain honest about absent root, systemd, container, enforcement, process-control, upload, acknowledgement, compaction, and global-authority capabilities.

## Download

Open the [GitHub Releases page](https://github.com/Zheke32174/pleiades-termux/releases) and download:

`pleiades-termux-<version>.tar.gz`

A proper release also contains:

- `SHA256SUMS.txt`;
- an SPDX 2.3 JSON source inventory;
- an exact-commit build receipt.

This is a **Termux source bundle**, not an APK. The release does not contain Android app binaries, credentials, local queue data, an OCI image, or an automatic upstream transport.

Until the first verified asset-bearing tag is published, use a reviewed checkout:

```bash
pkg install python git
git clone https://github.com/Zheke32174/pleiades-termux.git
cd pleiades-termux
```

## Install

Preview without changing state or shell configuration:

```bash
bash env/bootstrap-termux.sh --dry-run
```

Initialize private state and install the `pleiades` CLI symlink:

```bash
bash env/bootstrap-termux.sh
pleiades doctor
pleiades info
```

Add the environment source line to the active Bash or Zsh startup file only when explicitly requested:

```bash
bash env/bootstrap-termux.sh --install-shell-hook
```

The bootstrap does not install server agents, fake system services, containers, credentials, or third-party research tools.

## Event and delivery flow

```text
Android / Termux observation
          ↓
pleiades.event/v1 validation
          ↓
private append-only local queue
          ↓
contiguous local delivery sequence
          ↓ explicit non-destructive export
future authenticated observation-ingress gateway
          ↓
receiver-signed durable receipt
          ↓
reviewed evidence and knowledge planes
```

There is **no automatic network transmission** in this repository. Export does not acknowledge or delete queued records. The local receiver identity remains explicitly `receiver://unconfigured`, and acknowledged high water remains zero.

The shared transport contract is defined in `Zheke32174/pleiades#19` and the stacked public MODOS ingress-contract draft. A future sender must authenticate the stable producer principal, submit exact bounded batches, verify receiver-signed receipts, apply bounded retry/backpressure, preserve restart continuity, and define retained-window compaction before any local record can be removed.

## Source position and delivery sequence

Source position and delivery order are different concepts.

- `sequence` is retained as the historical local queue field.
- `delivery_sequence` is the explicit contiguous delivery position and currently equals `sequence`.
- `delivery_stream_id` identifies one durable queue lineage.
- queue or lineage replacement must create a new stream identity rather than silently restarting sequence 1.

Legacy records that predate explicit delivery fields are adopted without rewriting their bytes. Their existing contiguous `sequence` remains the delivery position for the newly recorded stream. New records carry both the compatibility sequence and explicit delivery fields.

## Use

Emit a typed observation:

```bash
pleiades emit android.package.observed \
  --severity notice \
  --source package-inventory \
  --payload-json '{"package":"example.app","state":"installed"}'
```

Inspect recent events, delivery continuity, and capabilities:

```bash
pleiades show --limit 20
pleiades delivery
pleiades capabilities
pleiades info
```

Export a copy:

```bash
pleiades export "$HOME/storage/shared/pleiades-edge.jsonl"
```

The exported file may enter shared Android storage and inherit broader access than the private queue. Review and move or delete exports deliberately.

## CLI

| Command | Purpose |
|---|---|
| `pleiades init` | Initialize private state, stable node identity, and delivery stream |
| `pleiades info` | Generate and print a local status snapshot |
| `pleiades doctor` | Check Termux, permissions, queue, and stream continuity |
| `pleiades capabilities` | Show implemented and explicitly absent capabilities |
| `pleiades delivery` | Show the local `DeliveryStreamState` without event bodies |
| `pleiades emit ...` | Append one typed observation event |
| `pleiades show` | Inspect recent queued events |
| `pleiades export PATH` | Atomically copy the queue without acknowledgement or deletion |

## Local data

Default state:

```text
~/.local/share/pleiades-edge/
├── config/
│   ├── node.json
│   └── capabilities.json
├── state/
│   ├── sequence
│   ├── delivery-stream.json
│   └── status.json
├── queue/
│   └── events.jsonl
├── exports/
└── tools/
```

Directories and state files are created with private permissions. The node identity, stream identity, event queue, status snapshots, exports, and local overrides must not be committed.

Queue writes use one serialized commit fence covering sequence recovery, allocation, append, flush, sequence-cache update, and delivery-state update. Reads and exports share the queue fence. Event records have bounded size, unique IDs, and contiguous per-stream delivery sequences.

`delivery-stream.json` uses the public MODOS `DeliveryStreamState` shape. It records:

- stable producer principal;
- explicitly unconfigured receiver;
- stable delivery-stream identity;
- next sequence;
- queued and acknowledged high water;
- pending event and byte counts;
- stream health.

The runtime recovers a lagging local stream state from the last durable queue record. It refuses state ahead of the durable queue, forged acknowledgement, delivery gaps, stream mismatch, duplicate event IDs, or queue/state disagreement. There is no automatic repair that deletes or rewrites evidence.

## Uninstall and retention

Remove only the CLI symlink owned by this checkout while preserving queue, node identity, and delivery-stream state:

```bash
bash env/uninstall-termux.sh
```

Also remove this checkout's exact shell-startup hook:

```bash
bash env/uninstall-termux.sh --remove-shell-hook
```

Delete recognized edge state and queued observations only with explicit destructive confirmation:

```bash
bash env/uninstall-termux.sh --remove-shell-hook --purge-state --yes
```

The uninstaller refuses to remove a foreign/non-symlink CLI path, refuses state outside the user's home, and refuses an unrecognized state tree.

## Legacy material

Historical copied scripts remain under `scripts/` for provenance. They are not installed, placed on `PATH`, or supported merely because they use a Termux shebang.

A legacy mechanism can re-enter the supported runtime only after it is rewritten as an observation-only adapter, emits typed events, avoids fake authority, and has tests for its data and failure boundaries.

## Security boundary

- No global command overrides.
- No `sudo`, systemd, namespace, nspawn, or process-control emulation.
- No API-key template generation.
- No automatic shell-startup modification.
- No automatic third-party cloning.
- No direct policy, installation, enforcement, or promotion action.
- No automatic upload, receipt acceptance, deletion, or queue compaction.
- Export is not acknowledgement.
- A stream high-water value is not upstream acceptance.
- Durable writes and exports report success only after bounded validation and flush behavior.

UIDs, Termux process context, possession of an exported file, or possession of the local stream state do not establish global Pleiades authority.

See [SECURITY.md](SECURITY.md) for vulnerability and trust boundaries and [PRIVACY.md](PRIVACY.md) for local storage, exports, retention, and deletion.

## Related public repositories

- [`pleiades`](https://github.com/Zheke32174/pleiades) — public contracts and bounded host/runtime architecture;
- [`pleiades-factory-stack-termux`](https://github.com/Zheke32174/pleiades-factory-stack-termux) — thin Termux adapter to the locked public source catalog;
- [`pleiades-container-termux`](https://github.com/Zheke32174/pleiades-container-termux) — deprecation/redirect surface because ordinary Termux cannot provide systemd-nspawn.

Off-device evaluation and promotion remain separate authority domains; this edge runtime cannot promote its own observations.

## Development and release validation

```bash
python3 -m py_compile bin/pleiades-edge.py ci/scan_public_repo.py scripts/write_spdx_sbom.py
python3 -m unittest discover -s tests -v
bash -n env/*.sh scripts/package_source.sh tests/test_uninstall.sh
bash tests/test_uninstall.sh
python3 ci/scan_public_repo.py
bash scripts/package_source.sh dist
(cd dist && sha256sum -c SHA256SUMS.txt)
```

CI also builds the source distribution twice and requires byte-identical outputs.

## Update and rollback

Update by moving to a reviewed tag or commit and rerunning the bootstrap. The CLI symlink follows the selected checkout. Runtime queue and identity state are not replaced by a source update.

A source rollback does not automatically roll back queue or delivery-stream state. Preserve the local state directory, verify schema compatibility, and use an explicit reviewed migration or recovery procedure rather than deleting or resetting sequence state.

## License and support

MIT — see [LICENSE](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [CHANGELOG.md](CHANGELOG.md).

This is a small experimental project. No response-time, production-support, Android-version, Termux-distribution, transport, or long-term compatibility guarantee is offered.
