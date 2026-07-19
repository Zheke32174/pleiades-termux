#!/usr/bin/env python3
"""Pleiades Android/Termux edge-node runtime.

The edge node is a sensor, durable observation queue, and operator client. It
does not impersonate systemd, root, a container runtime, an ingress receiver,
or the Pleiades authority broker.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import pathlib
import re
import shutil
import stat
import sys
import time
import uuid
from typing import Any, Iterator

EVENT_SCHEMA = "pleiades.event/v1"
STATUS_SCHEMA = "pleiades.edge-status/v1"
CAPABILITY_SCHEMA = "pleiades.edge-capabilities/v1"
DELIVERY_STATE_API = "modos.pleiades/v1alpha1"
DELIVERY_STATE_KIND = "DeliveryStreamState"
UNCONFIGURED_RECEIVER = "receiver://unconfigured"
EVENT_TYPE_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{2,95}$")
SEVERITIES = {"debug", "info", "notice", "warning", "high", "critical"}
MAX_EVENT_BYTES = 1024 * 1024


class EdgeError(ValueError):
    pass


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def root_path() -> pathlib.Path:
    return pathlib.Path(
        os.environ.get(
            "PLEIADES_ROOT",
            pathlib.Path.home() / ".local" / "share" / "pleiades-edge",
        )
    ).expanduser()


def paths() -> dict[str, pathlib.Path]:
    root = root_path()
    return {
        "root": root,
        "config": pathlib.Path(
            os.environ.get("PLEIADES_CONFIG", root / "config")
        ).expanduser(),
        "state": pathlib.Path(
            os.environ.get("PLEIADES_STATE", root / "state")
        ).expanduser(),
        "queue": pathlib.Path(
            os.environ.get("PLEIADES_QUEUE", root / "queue")
        ).expanduser(),
        "exports": pathlib.Path(
            os.environ.get("PLEIADES_EXPORTS", root / "exports")
        ).expanduser(),
    }


def ensure_private_directory(path: pathlib.Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        path.chmod(0o700)
    except OSError:
        pass


def fsync_directory(path: pathlib.Path) -> None:
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    except OSError:
        return
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    written = 0
    while written < len(view):
        count = os.write(fd, view[written:])
        if count <= 0:
            raise EdgeError("durable write made no progress")
        written += count


@contextlib.contextmanager
def file_lock(path: pathlib.Path, *, shared: bool = False) -> Iterator[None]:
    ensure_private_directory(path.parent)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_SH if shared else fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def atomic_bytes(path: pathlib.Path, data: bytes, mode: int = 0o600) -> None:
    ensure_private_directory(path.parent)
    temporary = path.with_name(
        f".{path.name}.tmp.{os.getpid()}.{uuid.uuid4().hex}"
    )
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
    try:
        write_all(fd, data)
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        temporary.unlink(missing_ok=True)
        raise
    else:
        os.close(fd)
    os.replace(temporary, path)
    try:
        path.chmod(mode)
    except OSError:
        pass
    fsync_directory(path.parent)


def atomic_json(path: pathlib.Path, value: dict[str, Any], mode: int = 0o600) -> None:
    data = (
        json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    ).encode("utf-8")
    atomic_bytes(path, data, mode)


def atomic_text(path: pathlib.Path, value: str, mode: int = 0o600) -> None:
    atomic_bytes(path, value.encode("ascii"), mode)


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise EdgeError(f"cannot read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise EdgeError(f"{path} must contain an object")
    return value


def default_capabilities() -> dict[str, Any]:
    return {
        "schema": CAPABILITY_SCHEMA,
        "authority": "none",
        "implemented": [
            "pleiades.event.enqueue",
            "pleiades.queue.inspect",
            "pleiades.delivery-stream.inspect",
            "pleiades.status.snapshot",
            "pleiades.export.copy",
        ],
        "explicitly_absent": [
            "root",
            "systemd",
            "systemd-nspawn",
            "host-policy-mutation",
            "process-kill-authority",
            "network-containment-authority",
            "arbitrary-command-broker",
            "automatic-event-upload",
            "acknowledgement-compaction",
            "reverse-command-channel",
        ],
    }


def producer_principal_id(node: dict[str, Any]) -> str:
    node_id = node.get("node_id")
    if not isinstance(node_id, str) or not node_id:
        raise EdgeError("node identity is missing or invalid")
    return f"sensor://pleiades/android-termux/{node_id}"


def first_queue_observed_at(queue_path: pathlib.Path) -> str | None:
    try:
        with queue_path.open("r", encoding="utf-8", errors="strict") as handle:
            for number, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                try:
                    value = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise EdgeError(
                        f"queue contains invalid JSON at line {number}"
                    ) from exc
                if not isinstance(value, dict) or value.get("schema") != EVENT_SCHEMA:
                    raise EdgeError(
                        f"queue contains an invalid event at line {number}"
                    )
                observed_at = value.get("observed_at")
                if not isinstance(observed_at, str) or not observed_at:
                    raise EdgeError(
                        f"queue event has no observed_at at line {number}"
                    )
                return observed_at
    except (OSError, UnicodeDecodeError) as exc:
        raise EdgeError(f"cannot read oldest queue event: {exc}") from exc
    return None


def new_delivery_state(
    node: dict[str, Any],
    queued_high_water: int,
    queue_bytes: int,
    oldest_pending_at: str | None,
) -> dict[str, Any]:
    now = utc_now()
    state: dict[str, Any] = {
        "nextSequence": queued_high_water + 1,
        "queuedHighWater": queued_high_water,
        "acknowledgedHighWater": 0,
        "pendingEvents": queued_high_water,
        "pendingBytes": queue_bytes,
        "health": "healthy",
    }
    if queued_high_water > 0:
        if not oldest_pending_at:
            raise EdgeError("nonempty queue has no oldest pending timestamp")
        state["oldestPendingAt"] = oldest_pending_at
    return {
        "apiVersion": DELIVERY_STATE_API,
        "kind": DELIVERY_STATE_KIND,
        "metadata": {
            "producerPrincipalId": producer_principal_id(node),
            "receiverPrincipalId": UNCONFIGURED_RECEIVER,
            "deliveryStreamId": (
                "stream://pleiades/android-termux/"
                f"{node['node_id']}/{uuid.uuid4()}"
            ),
            "generation": 1,
            "createdAt": now,
            "observedAt": now,
        },
        "state": state,
    }


def validate_delivery_state(
    value: dict[str, Any],
    node: dict[str, Any],
) -> None:
    if value.get("apiVersion") != DELIVERY_STATE_API:
        raise EdgeError("delivery stream state has an unsupported apiVersion")
    if value.get("kind") != DELIVERY_STATE_KIND:
        raise EdgeError("delivery stream state has an invalid kind")
    metadata = value.get("metadata")
    state = value.get("state")
    if not isinstance(metadata, dict) or not isinstance(state, dict):
        raise EdgeError("delivery stream state is missing metadata or state")
    if metadata.get("producerPrincipalId") != producer_principal_id(node):
        raise EdgeError("delivery stream producer identity does not match this node")
    if metadata.get("receiverPrincipalId") != UNCONFIGURED_RECEIVER:
        raise EdgeError("edge runtime has no configured ingress receiver")
    stream_id = metadata.get("deliveryStreamId")
    if not isinstance(stream_id, str) or not stream_id.startswith(
        "stream://pleiades/android-termux/"
    ):
        raise EdgeError("delivery stream identity is invalid")
    generation = metadata.get("generation")
    if not isinstance(generation, int) or generation < 1:
        raise EdgeError("delivery stream generation is invalid")
    for field in (
        "nextSequence",
        "queuedHighWater",
        "acknowledgedHighWater",
        "pendingEvents",
        "pendingBytes",
    ):
        item = state.get(field)
        if not isinstance(item, int) or item < 0:
            raise EdgeError(f"delivery stream {field} is invalid")
    queued = state["queuedHighWater"]
    acknowledged = state["acknowledgedHighWater"]
    pending = state["pendingEvents"]
    if acknowledged != 0:
        raise EdgeError(
            "acknowledged delivery state is impossible before ingress is implemented"
        )
    if state["nextSequence"] != queued + 1:
        raise EdgeError("delivery stream next sequence is discontinuous")
    if pending != queued - acknowledged:
        raise EdgeError("delivery stream pending count is inconsistent")
    oldest = state.get("oldestPendingAt")
    if pending > 0 and (not isinstance(oldest, str) or not oldest):
        raise EdgeError("nonempty delivery stream lacks oldest pending time")
    if pending == 0 and oldest is not None:
        raise EdgeError("empty delivery stream must not claim oldest pending time")
    if state.get("health") not in {
        "healthy",
        "backlogged",
        "receiver-unavailable",
        "corrupt",
        "collision",
        "paused",
    }:
        raise EdgeError("delivery stream health is invalid")


def read_sequence_state(path: pathlib.Path) -> int:
    try:
        raw = path.read_text(encoding="ascii").strip() or "0"
        value = int(raw)
    except (OSError, ValueError) as exc:
        raise EdgeError("sequence state is corrupt") from exc
    if value < 0:
        raise EdgeError("sequence state is negative")
    return value


def last_queue_sequence(queue_path: pathlib.Path) -> int:
    try:
        with queue_path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            position = handle.tell()
            collected = bytearray()
            while position > 0:
                position -= 1
                handle.seek(position)
                char = handle.read(1)
                if char == b"\n":
                    if collected:
                        break
                    continue
                collected.extend(char)
    except OSError as exc:
        raise EdgeError(f"cannot read queue high-water mark: {exc}") from exc
    if not collected:
        return 0
    try:
        value = json.loads(bytes(reversed(collected)).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EdgeError("queue ends with an incomplete or invalid event") from exc
    if not isinstance(value, dict) or value.get("schema") != EVENT_SCHEMA:
        raise EdgeError("queue high-water record has an invalid schema")
    sequence = value.get("sequence")
    if not isinstance(sequence, int) or sequence < 1:
        raise EdgeError("queue high-water record has an invalid sequence")
    return sequence


def reconcile_delivery_state(
    node: dict[str, Any],
    layout: dict[str, pathlib.Path],
) -> dict[str, Any]:
    queue_path = layout["queue"] / "events.jsonl"
    state_path = layout["state"] / "delivery-stream.json"
    queued_high_water = last_queue_sequence(queue_path)
    oldest_pending_at = first_queue_observed_at(queue_path)
    try:
        queue_bytes = queue_path.stat().st_size
    except OSError as exc:
        raise EdgeError(f"cannot stat event queue: {exc}") from exc

    if state_path.exists():
        delivery = load_json(state_path)
        validate_delivery_state(delivery, node)
        state = delivery["state"]
        if state["queuedHighWater"] > queued_high_water:
            raise EdgeError(
                "delivery state is ahead of the durable queue; create a new stream "
                "through an explicit recovery procedure"
            )
        changed = False
        if state["queuedHighWater"] < queued_high_water:
            state["queuedHighWater"] = queued_high_water
            state["nextSequence"] = queued_high_water + 1
            state["pendingEvents"] = queued_high_water
            if not oldest_pending_at:
                raise EdgeError("nonempty queue has no oldest pending timestamp")
            state["oldestPendingAt"] = oldest_pending_at
            changed = True
        if state["pendingBytes"] != queue_bytes:
            state["pendingBytes"] = queue_bytes
            changed = True
        if changed:
            delivery["metadata"]["observedAt"] = utc_now()
            atomic_json(state_path, delivery)
        return delivery

    delivery = new_delivery_state(
        node,
        queued_high_water,
        queue_bytes,
        oldest_pending_at,
    )
    atomic_json(state_path, delivery)
    return delivery


def initialize() -> dict[str, Any]:
    layout = paths()
    for key in ("root", "config", "state", "queue", "exports"):
        ensure_private_directory(layout[key])

    with file_lock(layout["state"] / "initialize.lock"):
        node_path = layout["config"] / "node.json"
        if node_path.exists():
            node = load_json(node_path)
        else:
            node = {
                "schema": "pleiades.edge-node/v1",
                "node_id": str(uuid.uuid4()),
                "created_at": utc_now(),
                "platform": "android-termux",
            }
            atomic_json(node_path, node)

        capability_path = layout["config"] / "capabilities.json"
        if not capability_path.exists():
            atomic_json(capability_path, default_capabilities())

        sequence_path = layout["state"] / "sequence"
        if not sequence_path.exists():
            atomic_text(sequence_path, "0\n")

        queue_path = layout["queue"] / "events.jsonl"
        if not queue_path.exists():
            atomic_bytes(queue_path, b"")

        with file_lock(layout["state"] / "queue.lock"):
            reconcile_delivery_state(node, layout)

    return node


def delivery_stream_state() -> dict[str, Any]:
    node = initialize()
    layout = paths()
    with file_lock(layout["state"] / "queue.lock", shared=True):
        delivery = load_json(layout["state"] / "delivery-stream.json")
        validate_delivery_state(delivery, node)
        queued_high_water = last_queue_sequence(layout["queue"] / "events.jsonl")
        if delivery["state"]["queuedHighWater"] != queued_high_water:
            raise EdgeError("delivery stream state does not match queue high-water mark")
        return delivery


def commit_event(event: dict[str, Any]) -> dict[str, Any]:
    node = initialize()
    layout = paths()
    sequence_path = layout["state"] / "sequence"
    queue_path = layout["queue"] / "events.jsonl"
    delivery_path = layout["state"] / "delivery-stream.json"
    with file_lock(layout["state"] / "queue.lock"):
        current = max(
            read_sequence_state(sequence_path),
            last_queue_sequence(queue_path),
        )
        delivery = reconcile_delivery_state(node, layout)
        if delivery["state"]["queuedHighWater"] != current:
            raise EdgeError("delivery stream and queue sequence floors disagree")
        sequence = current + 1
        committed = dict(event)
        committed["sequence"] = sequence
        committed["delivery_sequence"] = sequence
        committed["delivery_stream_id"] = delivery["metadata"]["deliveryStreamId"]
        encoded = (
            json.dumps(
                committed,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
            )
            + "\n"
        ).encode("utf-8")
        if len(encoded) > MAX_EVENT_BYTES:
            raise EdgeError(f"event exceeds {MAX_EVENT_BYTES} encoded bytes")
        fd = os.open(queue_path, os.O_APPEND | os.O_WRONLY)
        try:
            write_all(fd, encoded)
            os.fsync(fd)
        finally:
            os.close(fd)
        atomic_text(sequence_path, f"{sequence}\n")

        state = delivery["state"]
        if state["pendingEvents"] == 0:
            state["oldestPendingAt"] = committed["observed_at"]
        state["nextSequence"] = sequence + 1
        state["queuedHighWater"] = sequence
        state["pendingEvents"] = sequence
        state["pendingBytes"] = queue_path.stat().st_size
        delivery["metadata"]["observedAt"] = utc_now()
        atomic_json(delivery_path, delivery)
        return committed


def emit(
    event_type: str,
    severity: str,
    source: str,
    payload: dict[str, Any],
) -> dict[str, Any]:
    node = initialize()
    if not EVENT_TYPE_RE.fullmatch(event_type):
        raise EdgeError("event type must be a lowercase dotted identifier")
    if severity not in SEVERITIES:
        raise EdgeError(f"severity must be one of {sorted(SEVERITIES)}")
    if not source or len(source) > 96:
        raise EdgeError("source must be 1-96 characters")
    event = {
        "schema": EVENT_SCHEMA,
        "event_id": str(uuid.uuid4()),
        "observed_at": utc_now(),
        "node_id": node["node_id"],
        "platform": "android-termux",
        "source": source,
        "event_type": event_type,
        "severity": severity,
        "payload": payload,
        "authority": "observation-only",
    }
    return commit_event(event)


def read_events(limit: int | None = None) -> list[dict[str, Any]]:
    node = initialize()
    layout = paths()
    queue_path = layout["queue"] / "events.jsonl"
    with file_lock(layout["state"] / "queue.lock", shared=True):
        delivery = load_json(layout["state"] / "delivery-stream.json")
        validate_delivery_state(delivery, node)
        try:
            lines = queue_path.read_text(
                encoding="utf-8",
                errors="strict",
            ).splitlines()
        except (OSError, UnicodeDecodeError) as exc:
            raise EdgeError(f"cannot read event queue: {exc}") from exc
    events: list[dict[str, Any]] = []
    prior_sequence = 0
    seen_ids: set[str] = set()
    stream_id = delivery["metadata"]["deliveryStreamId"]
    for number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise EdgeError(f"queue contains invalid JSON at line {number}") from exc
        if not isinstance(value, dict) or value.get("schema") != EVENT_SCHEMA:
            raise EdgeError(f"queue contains an invalid event at line {number}")
        sequence = value.get("sequence")
        event_id = value.get("event_id")
        if not isinstance(sequence, int) or sequence != prior_sequence + 1:
            raise EdgeError(f"queue delivery sequence is not contiguous at line {number}")
        if not isinstance(event_id, str) or not event_id or event_id in seen_ids:
            raise EdgeError(
                f"queue event identity is invalid or duplicated at line {number}"
            )
        explicit_sequence = value.get("delivery_sequence")
        if explicit_sequence is not None and explicit_sequence != sequence:
            raise EdgeError(f"queue delivery sequence alias differs at line {number}")
        explicit_stream = value.get("delivery_stream_id")
        if explicit_stream is not None and explicit_stream != stream_id:
            raise EdgeError(f"queue event belongs to another delivery stream at line {number}")
        prior_sequence = sequence
        seen_ids.add(event_id)
        events.append(value)
    if prior_sequence != delivery["state"]["queuedHighWater"]:
        raise EdgeError("queue records do not match delivery stream high-water state")
    return events[-limit:] if limit is not None else events


def snapshot() -> dict[str, Any]:
    node = initialize()
    layout = paths()
    events = read_events()
    delivery = delivery_stream_state()
    delivery_meta = delivery["metadata"]
    delivery_state = delivery["state"]
    status = {
        "schema": STATUS_SCHEMA,
        "generated_at": utc_now(),
        "node_id": node["node_id"],
        "platform": "android-termux",
        "authority": "none",
        "queue": {
            "records": len(events),
            "last_sequence": events[-1]["sequence"] if events else 0,
            "path": str(layout["queue"] / "events.jsonl"),
        },
        "delivery": {
            "producer_principal_id": delivery_meta["producerPrincipalId"],
            "receiver_principal_id": delivery_meta["receiverPrincipalId"],
            "delivery_stream_id": delivery_meta["deliveryStreamId"],
            "next_sequence": delivery_state["nextSequence"],
            "queued_high_water": delivery_state["queuedHighWater"],
            "acknowledged_high_water": delivery_state["acknowledgedHighWater"],
            "pending_events": delivery_state["pendingEvents"],
            "pending_bytes": delivery_state["pendingBytes"],
            "oldest_pending_at": delivery_state.get("oldestPendingAt"),
            "health": delivery_state["health"],
            "upload_implemented": False,
            "compaction_implemented": False,
        },
        "capabilities": load_json(layout["config"] / "capabilities.json"),
    }
    atomic_json(layout["state"] / "status.json", status)
    return status


def export_queue(destination: pathlib.Path) -> pathlib.Path:
    initialize()
    layout = paths()
    source = layout["queue"] / "events.jsonl"
    if destination.is_dir():
        destination = destination / f"pleiades-edge-{int(time.time())}.jsonl"
    destination = destination.expanduser()
    if destination.resolve() == source.resolve():
        raise EdgeError("export destination must differ from the live queue")
    ensure_private_directory(destination.parent)
    temporary = destination.with_name(
        f".{destination.name}.tmp.{os.getpid()}.{uuid.uuid4().hex}"
    )
    with file_lock(layout["state"] / "queue.lock", shared=True):
        try:
            with source.open("rb") as reader, temporary.open("xb") as writer:
                shutil.copyfileobj(reader, writer)
                writer.flush()
                os.fsync(writer.fileno())
            temporary.chmod(0o600)
            os.replace(temporary, destination)
            fsync_directory(destination.parent)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    return destination


def permission_string(path: pathlib.Path) -> str:
    return oct(stat.S_IMODE(path.stat().st_mode)) if path.exists() else "missing"


def doctor() -> tuple[dict[str, Any], bool]:
    node = initialize()
    layout = paths()
    prefix = os.environ.get("PREFIX", "")
    try:
        delivery = delivery_stream_state()
        delivery_contiguous = (
            delivery["state"]["nextSequence"]
            == delivery["state"]["queuedHighWater"] + 1
            and delivery["state"]["acknowledgedHighWater"] == 0
        )
    except EdgeError:
        delivery_contiguous = False
    checks = {
        "python3": shutil.which("python3") is not None,
        "termux_prefix": "com.termux" in prefix or prefix.endswith("/usr"),
        "node_private": permission_string(layout["config"] / "node.json")
        in {"0o600", "0o400"},
        "delivery_state_private": permission_string(
            layout["state"] / "delivery-stream.json"
        )
        in {"0o600", "0o400"},
        "delivery_contiguous": delivery_contiguous,
        "root_private": permission_string(layout["root"]) == "0o700",
        "queue_writable": os.access(layout["queue"], os.W_OK),
        "no_root_claim": os.geteuid() != 0,
    }
    report = {
        "schema": "pleiades.edge-doctor/v1",
        "generated_at": utc_now(),
        "node_id": node["node_id"],
        "checks": checks,
    }
    return report, all(checks.values())


def parse_payload(
    raw: str | None,
    path: pathlib.Path | None,
) -> dict[str, Any]:
    if raw and path:
        raise EdgeError("use either --payload-json or --payload-file")
    if path:
        value = load_json(path)
    elif raw:
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise EdgeError(f"invalid --payload-json: {exc}") from exc
        if not isinstance(value, dict):
            raise EdgeError("payload must be a JSON object")
    else:
        value = {}
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("init")
    sub.add_parser("info")
    sub.add_parser("snapshot")
    sub.add_parser("capabilities")
    sub.add_parser("delivery")
    sub.add_parser("doctor")

    emit_parser = sub.add_parser("emit")
    emit_parser.add_argument("event_type")
    emit_parser.add_argument("--severity", default="info")
    emit_parser.add_argument("--source", default="operator")
    emit_parser.add_argument("--payload-json")
    emit_parser.add_argument("--payload-file", type=pathlib.Path)

    show_parser = sub.add_parser("show")
    show_parser.add_argument("--limit", type=int, default=20)

    export_parser = sub.add_parser("export")
    export_parser.add_argument("destination", type=pathlib.Path)

    args = parser.parse_args()
    try:
        if args.command == "init":
            print(json.dumps(initialize(), indent=2, sort_keys=True))
        elif args.command in {"info", "snapshot"}:
            print(json.dumps(snapshot(), indent=2, sort_keys=True))
        elif args.command == "capabilities":
            initialize()
            print(
                json.dumps(
                    load_json(paths()["config"] / "capabilities.json"),
                    indent=2,
                    sort_keys=True,
                )
            )
        elif args.command == "delivery":
            print(json.dumps(delivery_stream_state(), indent=2, sort_keys=True))
        elif args.command == "doctor":
            report, healthy = doctor()
            print(json.dumps(report, indent=2, sort_keys=True))
            return 0 if healthy else 3
        elif args.command == "emit":
            payload = parse_payload(args.payload_json, args.payload_file)
            print(
                json.dumps(
                    emit(args.event_type, args.severity, args.source, payload),
                    indent=2,
                    sort_keys=True,
                )
            )
        elif args.command == "show":
            if args.limit < 1 or args.limit > 1000:
                raise EdgeError("--limit must be between 1 and 1000")
            print(json.dumps(read_events(args.limit), indent=2, sort_keys=True))
        elif args.command == "export":
            print(export_queue(args.destination))
        return 0
    except (EdgeError, OSError) as exc:
        print(f"pleiades-edge: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
