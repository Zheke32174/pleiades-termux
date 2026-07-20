from __future__ import annotations

import contextlib
import importlib.util
import os
import pathlib
import tempfile
import unittest

RUNTIME = pathlib.Path(__file__).resolve().parents[1] / "bin" / "pleiades-edge.py"
SPEC = importlib.util.spec_from_file_location("pleiades_edge_path_safety", RUNTIME)
assert SPEC and SPEC.loader
edge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(edge)

ENV_KEYS = (
    "PLEIADES_ROOT",
    "PLEIADES_CONFIG",
    "PLEIADES_STATE",
    "PLEIADES_QUEUE",
    "PLEIADES_EXPORTS",
)


@contextlib.contextmanager
def isolated_layout(root: pathlib.Path, **overrides: pathlib.Path):
    previous = {key: os.environ.get(key) for key in ENV_KEYS}
    try:
        for key in ENV_KEYS:
            os.environ.pop(key, None)
        os.environ["PLEIADES_ROOT"] = str(root)
        for key, value in overrides.items():
            os.environ[key] = str(value)
        yield
    finally:
        for key in ENV_KEYS:
            os.environ.pop(key, None)
        for key, value in previous.items():
            if value is not None:
                os.environ[key] = value


class EdgePathSafetyTests(unittest.TestCase):
    def test_symlink_root_is_refused_before_initialization(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            real = base / "real"
            real.mkdir()
            linked = base / "linked"
            linked.symlink_to(real, target_is_directory=True)
            with isolated_layout(linked):
                with self.assertRaisesRegex(edge.EdgeError, "symlink"):
                    edge.initialize()

    def test_live_state_overrides_must_remain_inside_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            root = base / "root"
            outside = base / "outside"
            with isolated_layout(root, PLEIADES_STATE=outside):
                with self.assertRaisesRegex(
                    edge.EdgeError, "state path must remain within PLEIADES_ROOT"
                ):
                    edge.paths()

    def test_symlink_lock_file_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            root = base / "root"
            with isolated_layout(root):
                edge.initialize()
                layout = edge.paths()
                lock = layout["state"] / "hostile.lock"
                target = base / "target"
                target.write_text("untouched", encoding="utf-8")
                lock.symlink_to(target)
                with self.assertRaisesRegex(edge.EdgeError, "symlink"):
                    with edge.file_lock(lock):
                        self.fail("symlink lock unexpectedly acquired")
                self.assertEqual(target.read_text(encoding="utf-8"), "untouched")

    def test_symlink_queue_is_refused_without_touching_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            root = base / "root"
            with isolated_layout(root):
                edge.initialize()
                layout = edge.paths()
                queue = layout["queue"] / "events.jsonl"
                queue.unlink()
                target = base / "target.jsonl"
                target.write_text("sentinel\n", encoding="utf-8")
                queue.symlink_to(target)
                with self.assertRaisesRegex(edge.EdgeError, "symlink"):
                    edge.emit("test.path-safety", "info", "unit-test", {})
                self.assertEqual(target.read_text(encoding="utf-8"), "sentinel\n")

    def test_export_destination_may_be_outside_live_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            root = base / "root"
            export_dir = base / "operator-selected-export"
            with isolated_layout(root):
                edge.initialize()
                edge.emit("test.export", "info", "unit-test", {"ok": True})
                destination = edge.export_queue(export_dir / "events.jsonl")
                self.assertEqual(destination, export_dir / "events.jsonl")
                self.assertIn("test.export", destination.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
