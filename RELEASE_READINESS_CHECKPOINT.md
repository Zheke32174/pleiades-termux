# Public Release-Readiness Checkpoint

Repository: `Zheke32174/pleiades-termux`  
Draft branch: `hardening/public-release-readiness-v1`  
Draft pull request: `#4`  
Default branch changed: no  
Release publication authority: tag-only draft workflow; no tag or release authorized by this checkpoint

## Last reviewed heads and receipts

- Last fully validated release-readiness head before workflow hardening: `3f93a8a119681be5d157bb31731bc9d9e0d46148`
- Exact CI run: `29669850443`
- CI supply-chain hardening head: `7ded37f8e0e6e415fc1adbc48889279117697d0e`
- Release-workflow hardening head: `df9fc5b2d5c26693bad1256cda7cbad00fd15b29`
- Current ledger head: pending this commit

## Completed scope

- Reframed the public repository as an observation-only Android/Termux edge runtime rather than a server-swarm substitute.
- Added MIT licensing, security, privacy, contribution, changelog, and third-party notice boundaries.
- Added deterministic source packaging from a reviewed file manifest.
- Added SHA-256 checksums, SPDX 2.3 source inventory, and an exact-commit build receipt.
- Added current-tree and reachable-history sensitivity scanning that preserves hashed diagnostics without echoing sensitive values.
- Added ownership-safe uninstall behavior with default queue and node-state preservation and explicit confirmed purge.
- Added deterministic uninstall and refusal-path tests.
- Added clear source acquisition, local bootstrap, update, rollback, export, retention, and removal documentation.
- Removed false package/container publication claims and kept automatic network ingestion explicitly absent.
- Pinned third-party Actions to reviewed full-length commit SHAs.
- Replaced mutable `ubuntu-latest` runners with explicit `ubuntu-24.04` identities.
- Disabled persisted checkout credentials in read-only and release checkout steps.
- Added proof that a release tag's commit is reachable from `main` before release creation.
- Preserved exact `VERSION`/tag matching and release-overwrite refusal.

## Validation receipts

At exact head `3f93a8a119681be5d157bb31731bc9d9e0d46148`, CI run `29669850443` passed.

The validated scope included:

- Python compilation and unit tests;
- shell parsing and uninstall/refusal tests;
- observation-only authority invariants;
- current-tree and reachable-history sensitivity scanning;
- two deterministic source builds and byte-for-byte comparison;
- exact archive-manifest checks;
- checksum verification;
- exact-head candidate upload.

The workflow-hardening and ledger commits require a fresh exact-head CI receipt. The release workflow has not been executed because doing so would require an unauthorized public tag and release.

## External practices applied

- GitHub secure-use guidance: full-length Action commit SHAs are the only immutable Action references.
- Explicit runner-image identities reduce unreviewed environment drift relative to mutable convenience labels.
- Tag publication is bound to exact package version, exact source commit, `main` ancestry, checksum verification, and overwrite refusal.
- GitHub artifact attestations can bind assets to repository, workflow, event, and commit, but consumer verification must be exercised before they are treated as a completed release control.
- GitHub immutable releases can protect published tags and assets when enabled administratively; source review alone cannot verify that setting.

Primary references reviewed on 2026-07-21:

- https://docs.github.com/en/actions/reference/security/secure-use
- https://docs.github.com/en/actions/concepts/security/artifact-attestations
- https://docs.github.com/en/enterprise-cloud@latest/code-security/concepts/supply-chain-security/immutable-releases
- https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/add-security-policy

## Open blockers

1. The stacked edge-runtime PR and this release-readiness PR must be reviewed and integrated in dependency order.
2. The delivery-stream continuity draft remains stacked above this branch and must preserve the release and retention boundaries during integration.
3. Automatic authenticated ingestion, exact acknowledgement, bounded retry/backpressure, replay handling, and verified compaction remain deliberately absent.
4. Installation, update, rollback, shell-hook removal, export, and confirmed purge require one disposable real-Termux receipt in addition to host-side fixtures.
5. Repository rules, branch protection, full-SHA Action policy, immutable-release settings, and private vulnerability reporting remain outside source-level verification.
6. One explicitly authorized disposable prerelease is needed to prove real GitHub assets, checksum consumption, download/extraction behavior, overwrite refusal, and consumer verification instructions.

## Deferred work

- Add GitHub artifact attestations only when a real disposable prerelease is authorized and both online and intended offline verification can be exercised.
- Decide whether GitHub immutable releases should be required administratively before stable publication.
- Add dependency review or CodeQL only where repository manifests and supported languages produce useful signal rather than policy noise.
- Design ingestion and compaction as a separate authority-bearing protocol; do not infer acknowledgement from attempted transport.

## Reconsideration triggers

Reprocess this repository only when one or more of the following changes:

- draft branch or stacked base head;
- exact-head CI result;
- release workflow or source manifest;
- Android/Termux installation, update, rollback, uninstall, export, or purge behavior;
- delivery-stream or ingestion authority model;
- public capability, security, privacy, support, or installation claims;
- dependency or advisory status;
- repository administrative settings;
- explicit steward instruction.

## Next action

Inspect exact-head CI for the workflow-and-ledger commits. If it passes, skip ordinary source reprocessing and move to stacked integration review plus a disposable real-Termux lifecycle fixture. Keep the repository on `HOLD` until dependency-order integration and a separately authorized prerelease validate the public distribution path.
