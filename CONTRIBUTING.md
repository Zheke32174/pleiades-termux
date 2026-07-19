# Contributing

Pleiades Termux Edge accepts narrowly scoped improvements to observation schemas, queue durability, local inspection/export, bootstrap/removal safety, documentation, and reproducible source releases.

## Before opening a change

- Work from a clean checkout and dedicated branch.
- Do not commit runtime state, node identities, event queues, exports, credentials, private topology, device inventories, or personal data.
- Keep the runtime observation-only. Do not reintroduce fake `sudo`, systemd, container, namespace, process-control, installation, enforcement, or promotion behavior.
- Keep shell-startup edits explicit and idempotent.
- Keep uninstall ownership-aware and preserve queue data by default.
- Do not add automatic upload or compaction without an authenticated acknowledgement and retention design.
- Keep historical scripts quarantined until their provenance, license, authority, and data behavior are reviewed.

## Required local checks

```bash
python3 -m py_compile bin/pleiades-edge.py ci/scan_public_repo.py scripts/write_spdx_sbom.py
python3 -m unittest discover -s tests -v
bash -n env/*.sh scripts/package_source.sh tests/test_uninstall.sh
bash tests/test_uninstall.sh
python3 ci/scan_public_repo.py
bash scripts/package_source.sh dist
(cd dist && sha256sum -c SHA256SUMS.txt)
```

## Pull-request evidence

Explain:

- the defect or limitation being corrected;
- affected identity, sequence, queue, export, permission, install, uninstall, or data-retention boundaries;
- concurrency and crash behavior;
- tests added for malformed, concurrent, stale, oversized, or destructive cases;
- schema, migration, rollback, and state-compatibility effects;
- whether Android shared storage or a network boundary is introduced;
- third-party provenance and license impact.

Do not describe an exported file as upstream acknowledgement. Do not describe local UID/process context as global authority.

## Event and schema changes

Changes to `pleiades.event/v1`, node identity, sequence recovery, queue layout, capabilities, or status snapshots require explicit compatibility and migration notes. Existing durable queues must not be silently rewritten or discarded.

## Releases

Release identities are immutable. Do not edit an existing release to point at a different commit or replace assets under the same version.

Source releases must not contain runtime state, queue data, exports, credentials, APKs, or server/container images.

## Support expectations

This is a small experimental project. Public issues may be used for reproducible non-sensitive defects and documentation problems. Security-sensitive reports belong in GitHub's private vulnerability-reporting channel when available.

No response-time, production-support, Android-version, Termux-distribution, or long-term maintenance guarantee is offered.
