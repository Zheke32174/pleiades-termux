# Changelog

This project uses semantic versioning for the Pleiades-owned Termux edge runtime, bootstrap/removal helpers, schemas, and source-release tooling.

## Unreleased

- Design and validate authenticated ingestion, exact acknowledgement, bounded retry/backpressure, replay handling, retention, and compaction before any automatic upload is introduced.
- Verify the first immutable `v0.2.0` GitHub Release assets after stacked review and integration.

## 0.2.0

Observation-only edge and public-distribution hardening:

- replace fake server/system compatibility with an honest Android/Termux observation edge;
- add stable node identity and typed `pleiades.event/v1` records;
- serialize first-run initialization and queue commits across concurrent emitters;
- recover a lagging sequence cache from the durable queue;
- enforce unique event IDs, strictly increasing per-node sequence numbers, bounded event size, complete writes, and durability flushes;
- provide local status, capability declarations, inspection, and non-destructive export;
- explicitly declare absent root, systemd, container, process-control, enforcement, arbitrary-command, and promotion authority;
- remove implicit shell edits, secret templates, external settings mutation, and duplicate factory-tool execution;
- quarantine historical scripts outside the supported runtime;
- add ownership-safe uninstall, exact shell-hook removal, state preservation by default, and confirmed purge of recognized queue state;
- add the MIT license previously claimed but missing from the repository;
- replace mutable branch-triggered showcase releases and a nonexistent GHCR image claim with immutable tag-only source releases;
- add versioned deterministic source packaging, SHA-256 verification, SPDX 2.3 inventory, and exact-commit build receipts;
- add current-tree and reachable-history sensitivity scanning;
- add security, privacy, third-party, contribution, update, rollback, retention, and deletion documentation;
- restrict feature-branch validation to one pull-request workflow and cancel superseded runs.

`0.2.0` is not considered published until the reviewed tag produces and verifies the named source archive and accompanying verification assets.

## Historical state

Earlier revisions copied server scripts into Termux and simulated unavailable commands, creating false success signals without the original lifecycle or security semantics. Historical scripts remain for provenance but are not installed or supported.

Earlier release automation could update `v0.1.0` from ordinary branch pushes and advertised `ghcr.io/zheke32174/pleiades-termux:latest` although this repository did not build or publish such an image. Historical identities must not be overwritten to impersonate the verified `0.2.0` checkpoint.
