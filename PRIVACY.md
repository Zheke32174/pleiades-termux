# Privacy and Data Behavior

Pleiades Termux Edge does not include analytics, advertising, account tracking, or automatic network transmission.

## Local state

By default, private state lives under:

`~/.local/share/pleiades-edge/`

It can contain:

- a stable local node identity;
- capability declarations;
- sequence and status state;
- the append-only event queue;
- explicit export copies;
- operator-managed local tools or overrides.

Directories are created with restrictive permissions. Android backups, rooted-device access, filesystem sharing, debugging tools, or another process running as the same app user can still expose local data; filesystem mode alone is not a complete confidentiality boundary.

## Network behavior

The supported edge runtime does not upload events, contact a Pleiades server, fetch third-party tools, or transmit diagnostics.

Normal network activity can still occur when the operator uses Termux package management, Git, a browser, shared-storage sync, or a separately installed transport. Those tools and services have their own policies and are outside this runtime's automatic behavior.

## Events and payloads

Event payloads are supplied by the operator or a future separately reviewed sensor adapter. The runtime validates structure and bounded size; it does not determine whether the payload contains personal information, credentials, location, installed-package data, evidence, or another sensitive class.

Use minimal payloads. Do not put authentication secrets in events. Define retention before collecting sensitive observations.

## Exports

`pleiades export PATH` creates an atomic copy and does not delete the queue. An export written into shared Android storage may be readable by more apps or users than the private Termux home.

The operator is responsible for destination permissions, transport, acknowledgement, retention, backup, and deletion. An exported file must not be interpreted as proof that any upstream accepted it.

## Retention and deletion

The runtime retains queued observations until the operator explicitly removes them. There is no automatic upload acknowledgement, compaction, expiration, or remote deletion.

Default uninstall preserves node identity and queue data:

```bash
bash env/uninstall-termux.sh
```

Explicit purge requires destructive confirmation:

```bash
bash env/uninstall-termux.sh --purge-state --yes
```

Before purging, export or back up anything that must survive. Purging local state cannot delete copies previously shared, backed up, synced, or ingested elsewhere.

## Public collaboration

Do not attach real queues, exports, node identities, device inventories, screenshots, or status files to public issues. Use synthetic events and remove private paths, identifiers, endpoints, and payload data from diagnostics.
