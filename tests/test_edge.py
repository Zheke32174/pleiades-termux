import importlib.util
import json
import os
import pathlib
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
        for name in ("PLEIADES_CONFIG", "PLEIADES_STATE", "PLEIADES_QUEUE", "PLEIADES_EXPORTS"):
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

    def test_invalid_event_type_fails_closed(self):
        with self.assertRaises(edge.EdgeError):
            edge.emit("BAD EVENT", "info", "unit-test", {})


if __name__ == "__main__":
    unittest.main()
