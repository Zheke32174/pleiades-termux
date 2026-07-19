# Security Policy

## Project status

Pleiades Termux Edge is an experimental observation-only runtime for Android/Termux. It is not a root manager, Android security product, policy enforcement service, remote command broker, container runtime, or production evidence-ingestion gateway.

Only the current reviewed default branch and most recent verified source release are eligible for fixes. Historical copied scripts, local queue data, exported files, operator modifications, and future external ingestion services are outside the supported release boundary unless a current reproducer shows otherwise.

## Report vulnerabilities privately

Use GitHub's private vulnerability-reporting or Security Advisory interface when available. Do not post real event queues, node identities, delivery-stream identities, credentials, private device details, personal data, internal endpoints, or exploit-ready material in a public issue.

A useful report includes:

- affected repository commit or release;
- Android and Termux environment information;
- exact CLI command with payloads redacted;
- whether the issue affects initialization, event validation, queue ordering, stream continuity, permissions, export, shell-hook installation, uninstall, or purge;
- expected and observed behavior;
- a synthetic minimal reproducer.

No response-time or remediation-time guarantee is offered.

## Authority boundary

The supported runtime may:

- create private local state and one stable node identity;
- create one durable local delivery-stream identity;
- validate and append typed observation events;
- maintain contiguous local delivery sequence and high-water diagnostics;
- expose local status and capability declarations;
- inspect recent records and stream state;
- create an explicit non-destructive export copy.

It must not:

- claim root, Android system, device-owner, systemd, namespace, container, process-control, network-containment, installation, enforcement, or promotion authority;
- execute arbitrary remote commands;
- treat successful local observation as global truth or promotion approval;
- upload, acknowledge, compact, or delete queue records automatically;
- silently modify shell startup files;
- remove a CLI path it does not own;
- purge queue state without an explicit destructive confirmation.

The MODOS declaration, runtime capability report, and delivery-stream state are contracts and local evidence, not grants of Android or domain authority.

## Queue and delivery-stream integrity

Event append uses a serialized commit fence that covers sequence recovery, allocation, validation, append, flush, sequence-cache update, and delivery-state update. Queue reads and exports share the same fence.

Each new event carries:

- the historical `sequence` field;
- an equal explicit `delivery_sequence`;
- one stable `delivery_stream_id`.

The runtime also maintains a private MODOS-shaped `DeliveryStreamState`. It records the stable producer principal, explicitly unconfigured receiver, stream identity, queued and acknowledged high water, next sequence, pending count/bytes, and health.

A successful append indicates that the local runtime completed its bounded write and durability steps. It does not prove that Android storage hardware can never fail, that backups exist, or that a record has been ingested elsewhere.

The runtime may recover stream state that lags the last durable queue record. It fails closed when:

- stream state is ahead of the queue;
- a queue delivery gap exists;
- an event's stream or delivery alias conflicts with local state;
- event IDs are duplicated;
- acknowledgement is present before an ingress receipt path exists;
- queue and stream high-water state disagree.

Legacy queues are adopted without rewriting event bytes. Their existing contiguous `sequence` becomes the delivery position for the newly recorded stream. Do not manually reset sequence 1 under an existing stream identity.

Do not edit `events.jsonl`, `sequence`, `delivery-stream.json`, or node identity files manually while the runtime is active. Restore from a reviewed backup or use a separately designed repair tool rather than patching queue state in place.

## Export risk

The private queue lives under the app user's home with restrictive permissions. An export can be written to shared Android storage, where other apps, backup services, USB workflows, or users may have broader access.

Exports are copies and are never acknowledgement. Protect, transmit, retain, and delete them according to the data they contain. Do not export credentials, personal information, or private evidence unless the destination and retention policy are approved.

Possession of an export, event ID, stream ID, or high-water value does not authorize compaction or prove receiver admission.

## Future ingestion boundary

Automatic upstream transport is intentionally absent. The shared contract belongs to `Zheke32174/pleiades#19` and requires:

- authenticated stable producer and receiver principals;
- confidentiality and integrity in transit;
- exact canonical event and batch digests;
- contiguous delivery ranges separate from source positions;
- all-or-nothing durable receiver admission;
- receiver-signed exact receipts;
- replay and collision handling;
- bounded retry, backpressure, and queue limits;
- partition behavior that cannot claim fresh global authority;
- explicit retained-window, compaction, recovery, and deletion semantics;
- receipts connecting exact local stream positions to accepted upstream records.

Transport authentication does not retroactively make an unsigned local source observation producer-signed. A gateway-signed admission event identifies the gateway as signer and retains the edge producer in provenance.

No local record may be deleted merely because a network request was attempted, a connection succeeded, or an event ID was returned. Compaction requires a verified durable receipt matching producer, receiver, stream, exact range, and batch digest.

## Installation and removal

The bootstrap creates private directories, initializes node and stream state, and installs a symlink under the current Termux prefix. Shell startup modification is separately opt-in.

The uninstaller removes only a symlink resolving to this checkout. It preserves node identity, delivery-stream state, and queue by default, removes only the exact source line when requested, and requires both `--purge-state` and `--yes` before deleting a recognized state tree under the user's home.

Review source updates before rerunning bootstrap. A source rollback does not automatically migrate or roll back queue/state schemas.

## Sensitive information

Do not commit or publish:

- API keys, passwords, tokens, cookies, private keys, real `.env` data, or authentication material;
- private hostnames, addresses, tailnet names, internal URLs, or device identifiers;
- event queues, exports, node identities, stream identities, status snapshots, personal data, or production evidence;
- realistic secret fixtures that could be mistaken for live credentials.

CI scans the current tracked tree and reachable Git history for configured credential, private-topology, and host-local patterns. That scanner is a review aid, not proof of absence. If a real secret entered history, revoke or rotate it before deciding whether history rewriting is required.

## Release integrity

A valid source release must:

1. originate from a tag equal to `v$(cat VERSION)`;
2. pass Python compilation, unit tests, shell/refusal tests, authority invariants, and public-history scanning;
3. build the exact source archive twice byte-for-byte;
4. include `SHA256SUMS.txt`, an SPDX 2.3 JSON source inventory, and an exact-commit build receipt;
5. state that no APK, credentials, runtime queue, server image, automatic transport, or ingress receipt is bundled;
6. refuse to overwrite an existing release identity.
