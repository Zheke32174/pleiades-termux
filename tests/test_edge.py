import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

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

    def test_initialization_is_private_and_stable(self):
        first = edge.initialize()
        second = edge.initialize()
        self.assertEqual(first["node_id"], second["node_id"])
        root = edge.paths()["root"]
        self.assertEqual(root.stat().st_mode & 0o777, 0o700)

    def test_events_are_typed_and_sequenced(self):
        first = edge.emit("android.test.event", "notice", "unit-test", {"value": 1})
        second = edge.emit("android.test.event", "warning", "unit-test", {"value": 2})
        self.assertEqual(first["sequence"], 1)
        self.assertEqual(second["sequence"], 2)
        self.assertEqual(first["authority"], "observation-only")
        events = edge.read_events()
        self.assertEqual([item["sequence"] for item in events], [1, 2])

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

    def test_concurrent_first_run_emitters_share_identity_and_order(self):
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
        self.assertEqual(len({item["event_id"] for item in events}), 12)
        self.assertEqual(len({item["node_id"] for item in events}), 1)
        status = edge.snapshot()
        self.assertEqual(status["queue"]["last_sequence"], 12)

    def test_snapshot_declares_no_authority(self):
        edge.emit("android.test.event", "info", "unit-test", {})
        status = edge.snapshot()
        self.assertEqual(status["authority"], "none")
        self.assertEqual(status["queue"]["records"], 1)
        self.assertIn("root", status["capabilities"]["explicitly_absent"])

    def test_export_copies_without_acknowledging(self):
        edge.emit("android.test.event", "info", "unit-test", {})
        destination = pathlib.Path(self.temporary.name) / "export.jsonl"
        edge.export_queue(destination)
        self.assertTrue(destination.exists())
        self.assertEqual(len(edge.read_events()), 1)
        record = json.loads(destination.read_text(encoding="utf-8").strip())
        self.assertEqual(record["schema"], edge.EVENT_SCHEMA)

    def test_export_refuses_live_queue_as_destination(self):
        edge.emit("android.test.event", "info", "unit-test", {})
        live_queue = edge.paths()["queue"] / "events.jsonl"
        with self.assertRaises(edge.EdgeError):
            edge.export_queue(live_queue)

    def test_queue_rejects_nonmonotonic_or_duplicate_records(self):
        first = edge.emit("android.test.event", "info", "unit-test", {})
        queue = edge.paths()["queue"] / "events.jsonl"
        duplicate = dict(first)
        duplicate["sequence"] = 2
        with queue.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(duplicate) + "\n")
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

    def test_invalid_event_type_fails_closed(self):
        with self.assertRaises(edge.EdgeError):
            edge.emit("BAD EVENT", "info", "unit-test", {})


if __name__ == "__main__":
    unittest.main()
