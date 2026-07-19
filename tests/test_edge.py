import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
import uuid

MODULE_PATH = pathlib.Path(__file__).parents[1] / "bin" / "pleiades-edge.py"
SPEC = importlib.util.spec_from_file_location("pleiades_edge", MODULE_PATH)
edge = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(edge)


class EdgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.old_root = os.environ.get("PLEIADES_ROOT")
        os.environ["PLEIADES_ROOT"] = str(pathlib.Path(self.temporary.name) / "edge")
        for name in (
            "PLEIADES_CONFIG",
            "PLEIADES_STATE",
            "PLEIADES_QUEUE",
            "PLEIADES_EXPORTS",
        ):
            os.environ.pop(name, None)

    def tearDown(self):
        if self.old_root is None:
            os.environ.pop("PLEIADES_ROOT", None)
        else:
            os.environ["PLEIADES_ROOT"] = self.old_root
        self.temporary.cleanup()

    def delivery_path(self):
        return edge.paths()["state"] / "delivery-stream.json"

    def test_initialization_is_private_and_stable(self):
        first = edge.initialize()
        first_delivery = edge.delivery_stream_state()
        second = edge.initialize()
        second_delivery = edge.delivery_stream_state()
        self.assertEqual(first["node_id"], second["node_id"])
        self.assertEqual(
            first_delivery["metadata"]["deliveryStreamId"],
            second_delivery["metadata"]["deliveryStreamId"],
        )
        self.assertEqual(first_delivery["state"]["nextSequence"], 1)
        self.assertEqual(first_delivery["state"]["acknowledgedHighWater"], 0)
        root = edge.paths()["root"]
        self.assertEqual(root.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.delivery_path().stat().st_mode & 0o777, 0o600)

    def test_events_are_typed_and_delivery_sequenced(self):
        first = edge.emit("android.test.event", "notice", "unit-test", {"value": 1})
        second = edge.emit("android.test.event", "warning", "unit-test", {"value": 2})
        self.assertEqual(first["sequence"], 1)
        self.assertEqual(second["sequence"], 2)
        self.assertEqual(first["delivery_sequence"], 1)
        self.assertEqual(second["delivery_sequence"], 2)
        self.assertEqual(first["delivery_stream_id"], second["delivery_stream_id"])
        self.assertEqual(first["authority"], "observation-only")
        events = edge.read_events()
        self.assertEqual([item["sequence"] for item in events], [1, 2])
        delivery = edge.delivery_stream_state()
        self.assertEqual(delivery["state"]["queuedHighWater"], 2)
        self.assertEqual(delivery["state"]["nextSequence"], 3)
        self.assertEqual(delivery["state"]["pendingEvents"], 2)
        self.assertEqual(delivery["state"]["acknowledgedHighWater"], 0)
        self.assertGreater(delivery["state"]["pendingBytes"], 0)

    def test_sequence_cache_recovers_from_last_durable_event(self):
        edge.emit("android.test.event", "info", "unit-test", {"value": 1})
        sequence_path = edge.paths()["state"] / "sequence"
        sequence_path.write_text("0\n", encoding="ascii")
        recovered = edge.emit(
            "android.test.event",
            "info",
            "unit-test",
            {"value": 2},
        )
        self.assertEqual(recovered["sequence"], 2)
        self.assertEqual(
            [item["sequence"] for item in edge.read_events()],
            [1, 2],
        )
        self.assertEqual(sequence_path.read_text(encoding="ascii"), "2\n")
        self.assertEqual(edge.delivery_stream_state()["state"]["queuedHighWater"], 2)

    def test_delivery_state_recovers_after_queue_commit(self):
        edge.emit("android.test.event", "info", "unit-test", {"value": 1})
        delivery = json.loads(self.delivery_path().read_text(encoding="utf-8"))
        delivery["state"].update(
            {
                "nextSequence": 1,
                "queuedHighWater": 0,
                "acknowledgedHighWater": 0,
                "pendingEvents": 0,
                "pendingBytes": 0,
            }
        )
        self.delivery_path().write_text(json.dumps(delivery), encoding="utf-8")
        edge.initialize()
        recovered = edge.delivery_stream_state()
        self.assertEqual(recovered["state"]["queuedHighWater"], 1)
        self.assertEqual(recovered["state"]["nextSequence"], 2)
        self.assertEqual(recovered["state"]["pendingEvents"], 1)
        self.assertGreater(recovered["state"]["pendingBytes"], 0)

    def test_delivery_state_ahead_of_queue_fails_closed(self):
        edge.emit("android.test.event", "info", "unit-test", {"value": 1})
        delivery = json.loads(self.delivery_path().read_text(encoding="utf-8"))
        delivery["state"].update(
            {
                "nextSequence": 3,
                "queuedHighWater": 2,
                "acknowledgedHighWater": 0,
                "pendingEvents": 2,
            }
        )
        self.delivery_path().write_text(json.dumps(delivery), encoding="utf-8")
        with self.assertRaises(edge.EdgeError):
            edge.initialize()

    def test_acknowledgement_cannot_be_fabricated_before_ingress(self):
        edge.emit("android.test.event", "info", "unit-test", {})
        delivery = json.loads(self.delivery_path().read_text(encoding="utf-8"))
        delivery["state"]["acknowledgedHighWater"] = 1
        delivery["state"]["pendingEvents"] = 0
        self.delivery_path().write_text(json.dumps(delivery), encoding="utf-8")
        with self.assertRaises(edge.EdgeError):
            edge.delivery_stream_state()

    def test_legacy_queue_is_adopted_without_rewriting_evidence(self):
        layout = edge.paths()
        for name in ("root", "config", "state", "queue", "exports"):
            edge.ensure_private_directory(layout[name])
        node = {
            "schema": "pleiades.edge-node/v1",
            "node_id": str(uuid.uuid4()),
            "created_at": edge.utc_now(),
            "platform": "android-termux",
        }
        edge.atomic_json(layout["config"] / "node.json", node)
        edge.atomic_text(layout["state"] / "sequence", "1\n")
        legacy = {
            "schema": edge.EVENT_SCHEMA,
            "event_id": str(uuid.uuid4()),
            "observed_at": edge.utc_now(),
            "node_id": node["node_id"],
            "platform": "android-termux",
            "source": "legacy-test",
            "event_type": "android.legacy.event",
            "severity": "info",
            "payload": {},
            "authority": "observation-only",
            "sequence": 1,
        }
        original = (json.dumps(legacy, sort_keys=True, separators=(",", ":")) + "\n").encode()
        edge.atomic_bytes(layout["queue"] / "events.jsonl", original)

        edge.initialize()
        self.assertEqual((layout["queue"] / "events.jsonl").read_bytes(), original)
        delivery = edge.delivery_stream_state()
        self.assertEqual(delivery["state"]["queuedHighWater"], 1)
        self.assertEqual(edge.read_events()[0]["event_id"], legacy["event_id"])
        next_event = edge.emit("android.legacy.followup", "info", "unit-test", {})
        self.assertEqual(next_event["sequence"], 2)
        self.assertEqual(
            next_event["delivery_stream_id"],
            delivery["metadata"]["deliveryStreamId"],
        )

    def test_concurrent_first_run_emitters_share_identity_stream_and_order(self):
        environment = os.environ.copy()
        commands = []
        for worker in range(12):
            commands.append(
                subprocess.Popen(
                    [
                        sys.executable,
                        str(MODULE_PATH),
                        "emit",
                        "android.concurrent.event",
                        "--source",
                        f"worker-{worker}",
                        "--payload-json",
                        json.dumps({"worker": worker}),
                    ],
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
            )
        outputs = [process.communicate(timeout=30) for process in commands]
        for process, (stdout, stderr) in zip(commands, outputs, strict=True):
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(json.loads(stdout)["schema"], edge.EVENT_SCHEMA)

        events = edge.read_events()
        self.assertEqual(
            [item["sequence"] for item in events],
            list(range(1, 13)),
        )
        self.assertEqual(
            [item["delivery_sequence"] for item in events],
            list(range(1, 13)),
        )
        self.assertEqual(len({item["event_id"] for item in events}), 12)
        self.assertEqual(len({item["node_id"] for item in events}), 1)
        self.assertEqual(len({item["delivery_stream_id"] for item in events}), 1)
        status = edge.snapshot()
        self.assertEqual(status["queue"]["last_sequence"], 12)
        self.assertEqual(status["delivery"]["queued_high_water"], 12)
        self.assertEqual(status["delivery"]["pending_events"], 12)
        self.assertEqual(status["delivery"]["acknowledged_high_water"], 0)

    def test_snapshot_declares_no_authority_or_transport(self):
        edge.emit("android.test.event", "info", "unit-test", {})
        status = edge.snapshot()
        self.assertEqual(status["authority"], "none")
        self.assertEqual(status["queue"]["records"], 1)
        self.assertFalse(status["delivery"]["upload_implemented"])
        self.assertFalse(status["delivery"]["compaction_implemented"])
        self.assertEqual(
            status["delivery"]["receiver_principal_id"],
            edge.UNCONFIGURED_RECEIVER,
        )
        self.assertIn("root", status["capabilities"]["explicitly_absent"])
        self.assertIn(
            "automatic-event-upload",
            status["capabilities"]["explicitly_absent"],
        )

    def test_export_copies_without_acknowledging(self):
        edge.emit("android.test.event", "info", "unit-test", {})
        destination = pathlib.Path(self.temporary.name) / "export.jsonl"
        edge.export_queue(destination)
        self.assertTrue(destination.exists())
        self.assertEqual(len(edge.read_events()), 1)
        record = json.loads(destination.read_text(encoding="utf-8").strip())
        self.assertEqual(record["schema"], edge.EVENT_SCHEMA)
        delivery = edge.delivery_stream_state()["state"]
        self.assertEqual(delivery["acknowledgedHighWater"], 0)
        self.assertEqual(delivery["pendingEvents"], 1)

    def test_export_refuses_live_queue_as_destination(self):
        edge.emit("android.test.event", "info", "unit-test", {})
        live_queue = edge.paths()["queue"] / "events.jsonl"
        with self.assertRaises(edge.EdgeError):
            edge.export_queue(live_queue)

    def test_queue_rejects_delivery_gap(self):
        first = edge.emit("android.test.event", "info", "unit-test", {})
        queue = edge.paths()["queue"] / "events.jsonl"
        gap = dict(first)
        gap["event_id"] = str(uuid.uuid4())
        gap["sequence"] = 3
        gap["delivery_sequence"] = 3
        with queue.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(gap) + "\n")
        delivery = json.loads(self.delivery_path().read_text(encoding="utf-8"))
        delivery["state"].update(
            {
                "nextSequence": 4,
                "queuedHighWater": 3,
                "pendingEvents": 3,
                "pendingBytes": queue.stat().st_size,
            }
        )
        self.delivery_path().write_text(json.dumps(delivery), encoding="utf-8")
        with self.assertRaises(edge.EdgeError):
            edge.read_events()

    def test_queue_rejects_duplicate_records(self):
        first = edge.emit("android.test.event", "info", "unit-test", {})
        queue = edge.paths()["queue"] / "events.jsonl"
        duplicate = dict(first)
        duplicate["sequence"] = 2
        duplicate["delivery_sequence"] = 2
        with queue.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(duplicate) + "\n")
        delivery = json.loads(self.delivery_path().read_text(encoding="utf-8"))
        delivery["state"].update(
            {
                "nextSequence": 3,
                "queuedHighWater": 2,
                "pendingEvents": 2,
                "pendingBytes": queue.stat().st_size,
            }
        )
        self.delivery_path().write_text(json.dumps(delivery), encoding="utf-8")
        with self.assertRaises(edge.EdgeError):
            edge.read_events()

    def test_oversized_event_fails_before_queue_mutation(self):
        with self.assertRaises(edge.EdgeError):
            edge.emit(
                "android.test.event",
                "info",
                "unit-test",
                {"blob": "x" * edge.MAX_EVENT_BYTES},
            )
        self.assertEqual(edge.read_events(), [])
        self.assertEqual(edge.delivery_stream_state()["state"]["queuedHighWater"], 0)

    def test_invalid_event_type_fails_closed(self):
        with self.assertRaises(edge.EdgeError):
            edge.emit("BAD EVENT", "info", "unit-test", {})


if __name__ == "__main__":
    unittest.main()
