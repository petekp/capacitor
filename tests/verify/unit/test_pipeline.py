from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPTS_DIR = ROOT / "scripts/verify"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))


def load_module(name: str, relative_path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module {relative_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.pipeline = load_module("pipeline", "scripts/verify/pipeline.py")

    def test_build_base_run_manifest_includes_required_fields(self) -> None:
        manifest = self.pipeline.build_base_run_manifest(
            repo_root=str(ROOT),
            started_at="2026-03-16T00:00:00Z",
            selected_paths=["a.swift", "b.rs"],
            config_hashes={"structural": "abc123"},
            tool_versions={"python": "3.13.0"},
            git_commit="deadbeef",
            git_dirty=True,
        )

        self.assertEqual(str(ROOT), manifest["repo_root"])
        self.assertEqual("2026-03-16T00:00:00Z", manifest["started_at"])
        self.assertEqual("deadbeef", manifest["git_commit"])
        self.assertTrue(manifest["git_dirty"])
        self.assertEqual({"structural": "abc123"}, manifest["config_hashes"])
        self.assertEqual({"python": "3.13.0"}, manifest["tool_versions"])
        self.assertIn("run_id", manifest)
        self.assertIn("selected_paths_hash", manifest)
        self.assertIn("facts_hash", manifest)

    def test_finalize_facts_payload_sets_facts_hash_in_manifest(self) -> None:
        base_manifest = self.pipeline.build_base_run_manifest(
            repo_root=str(ROOT),
            started_at="2026-03-16T00:00:00Z",
            selected_paths=[],
            config_hashes={},
            tool_versions={},
            git_commit="deadbeef",
            git_dirty=False,
        )
        payload = {
            "generated_at": "2026-03-16T00:00:01Z",
            "modules": [{"path": "foo.swift", "references": []}],
            "constants": {},
        }

        finalized = self.pipeline.attach_run_manifest(payload, base_manifest, facts_payload_keys=("modules", "constants"))

        self.assertEqual(
            self.pipeline.payload_hash({"modules": payload["modules"], "constants": payload["constants"]}),
            finalized["run_manifest"]["facts_hash"],
        )

    def test_aggregate_results_fails_closed_on_manifest_drift(self) -> None:
        expected = self.pipeline.build_base_run_manifest(
            repo_root=str(ROOT),
            started_at="2026-03-16T00:00:00Z",
            selected_paths=[],
            config_hashes={"structural": "abc"},
            tool_versions={"python": "3.13.0"},
            git_commit="deadbeef",
            git_dirty=False,
        )
        layer1 = {"passed": True, "violations": [], "run_manifest": dict(expected)}
        layer2 = {"passed": True, "violations": [], "run_manifest": {**expected, "facts_hash": "wrong"}}

        report = self.pipeline.aggregate_run_report(
            repo_root=str(ROOT),
            layers=["1", "2"],
            layer_results={"1": layer1, "2": layer2},
            expected_manifest=expected,
            generated_at="2026-03-16T00:00:05Z",
        )

        self.assertFalse(report["passed"])
        self.assertEqual(1, len(report["manifest_violations"]))
        self.assertIn("facts_hash", report["manifest_violations"][0]["diagnosis"])


if __name__ == "__main__":
    unittest.main()
