# Security Policy

## Project status

Pleiades Termux Edge is an experimental observation-only runtime for Android/Termux. It is not a root manager, Android security product, policy enforcement service, remote command broker, container runtime, or production evidence-ingestion gateway.

Only the current reviewed default branch and most recent verified source release are eligible for fixes. Historical copied scripts, local queue data, exported files, operator modifications, and future external ingestion services are outside the supported release boundary unless a current reproducer shows otherwise.

## Report vulnerabilities privately

Use GitHub's private vulnerability-reporting or Security Advisory interface when available. Do not post real event queues, node identities, credentials, private device details, personal data, internal endpoints, or exploit-ready material in a public issue.

A useful report includes:

- affected repository commit or release;
- Android and Termux environment information;
- exact CLI command with payloads redacted;
- whether the issue affects initialization, event validation, queue ordering, permissions, export, shell-hook installation, uninstall, or purge;
- expected and observed behavior;
- a synthetic minimal reproducer.

No response-time or remediation-time guarantee is offered.

## Authority boundary

The supported runtime may:

- create private local state and one stable node identity;
- validate and append typed observation events;
- expose local status and capability declarations;
- inspect recent records;
- create an explicit non-destructive export copy.

It must not:

- claim root, Android system, device-owner, systemd, namespace, container, process-control, network-containment, installation, enforcement, or promotion authority;
- execute arbitrary remote commands;
- treat successful local observation as global truth or promotion approval;
- upload, acknowledge, compact, or delete queue records automatically;
- silently modify shell startup files;
- remove a CLI path it does not own;
- purge queue state without an explicit destructive confirmation.

The MODOS declaration and runtime capability report are contracts, not grants of Android privilege.

## Queue integrity and concurrency

Event append uses a serialized commit fence that covers sequence recovery, allocation, validation, append, flush, and sequence-cache update. Queue reads and exports share the same fence.

A successful append indicates that the local runtime completed its bounded write and durability steps. It does not prove that Android storage hardware can never fail, that backups exist, or that an exported copy has been ingested elsewhere.

Event IDs and strictly increasing per-node sequence numbers support later replay detection. They do not replace authentication, signed transport, server-side deduplication, acknowledgement, or retention policy.

Do not edit `events.jsonl`, `sequence`, or node identity files manually while the runtime is active. Restore from a reviewed backup or use a separately designed repair tool rather than patching queue state in place.

## Export risk

The private queue lives under the app user's home with restrictive permissions. An export can be written to shared Android storage, where other apps, backup services, USB workflows, or users may have broader access.

Exports are copies and are never acknowledgement. Protect, transmit, retain, and delete them according to the data they contain. Do not export credentials, personal information, or private evidence unless the destination and retention policy are approved.

## Future ingestion boundary

Automatic upstream transport is intentionally absent. Before adding it, require:

- authenticated source identity;
- confidentiality and integrity in transit;
- exact event acknowledgement;
- replay and duplicate handling;
- bounded retry, backpressure, and queue limits;
- partition behavior that cannot claim fresh global authority;
- explicit retention, compaction, recovery, and deletion semantics;
- receipts connecting local event IDs to accepted upstream records.

No local record may be deleted merely because a network request was attempted.

## Installation and removal

The bootstrap creates private directories, initializes state, and installs a symlink under the current Termux prefix. Shell startup modification is separately opt-in.

The uninstaller removes only a symlink resolving to this checkout. It preserves state by default, removes only the exact source line when requested, and requires both `--purge-state` and `--yes` before deleting a recognized state tree under the user's home.

Review source updates before rerunning bootstrap. A source rollback does not automatically migrate or roll back queue/state schemas.

## Sensitive information

Do not commit or publish:

- API keys, passwords, tokens, cookies, private keys, real `.env` data, or authentication material;
- private hostnames, addresses, tailnet names, internal URLs, or device identifiers;
- event queues, exports, node identities, status snapshots, personal data, or production evidence;
- realistic secret fixtures that could be mistaken for live credentials.

CI scans the current tracked tree and reachable Git history for configured credential, private-topology, and host-local patterns. That scanner is a review aid, not proof of absence. If a real secret entered history, revoke or rotate it before deciding whether history rewriting is required.

## Release integrity

A valid source release must:

1. originate from a tag equal to `v$(cat VERSION)`;
2. pass Python compilation, unit tests, shell/refusal tests, authority invariants, and public-history scanning;
3. build the exact source archive twice byte-for-byte;
4. include `SHA256SUMS.txt`, an SPDX 2.3 JSON source inventory, and an exact-commit build receipt;
5. state that no APK, credentials, runtime queue, server image, or automatic transport is bundled;
6. refuse to overwrite an existing release identity.
