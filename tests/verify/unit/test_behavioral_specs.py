from __future__ import annotations

import importlib.util
import pathlib
import shutil
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPTS_DIR = ROOT / "scripts/verify"
SPECS_DIR = ROOT / ".verifier/specs"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
if str(SPECS_DIR) not in sys.path:
    sys.path.insert(0, str(SPECS_DIR))
for site_packages in sorted((ROOT / ".verifier/.venv/lib").glob("python*/site-packages")):
    if str(site_packages) not in sys.path:
        sys.path.insert(0, str(site_packages))


def load_module_from_path(name: str, path: pathlib.Path, extra_paths: list[pathlib.Path] | None = None):
    extra_paths = extra_paths or []
    original = list(sys.path)
    for extra_path in reversed(extra_paths):
        if str(extra_path) not in sys.path:
            sys.path.insert(0, str(extra_path))
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"Unable to load module {path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path[:] = original


class BehavioralSpecProofTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.extractor = load_module_from_path("extract_facts", ROOT / "scripts/verify/extract-facts.py")

    def build_facts(self, repo_root: pathlib.Path, relative_paths: list[str], *, replay_cases=None) -> dict:
        modules = [
            self.extractor.extract_module(repo_root / relative_path, repo_root)
            for relative_path in relative_paths
            if (repo_root / relative_path).exists()
        ]
        return {
            "modules": modules,
            "constants": self.extractor.extract_constants(repo_root),
            "replay_cases": list(replay_cases or []),
        }

    def copy_spec_repo(self, spec_name: str, relative_paths: list[str]) -> tuple[tempfile.TemporaryDirectory[str], pathlib.Path]:
        temp_dir = tempfile.TemporaryDirectory()
        repo_root = pathlib.Path(temp_dir.name)
        spec_root = repo_root / ".verifier/specs"
        spec_root.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / ".verifier/specs/_helpers.py", spec_root / "_helpers.py")
        shutil.copy2(ROOT / ".verifier/specs" / f"{spec_name}.py", spec_root / f"{spec_name}.py")
        for relative_path in relative_paths:
            destination = repo_root / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative_path, destination)
        return temp_dir, repo_root

    def test_hook_setup_contracts_pass_on_repo(self) -> None:
        module = load_module_from_path(
            "HookSetupContracts",
            ROOT / ".verifier/specs/HookSetupContracts.py",
            extra_paths=[ROOT / ".verifier/specs"],
        )

        self.assertEqual([], module.verify({}))

    def test_hook_setup_contracts_fail_when_helper_missing(self) -> None:
        temp_dir, repo_root = self.copy_spec_repo("HookSetupContracts", ["core/capacitor-core/src/runtime_setup.rs"])
        self.addCleanup(temp_dir.cleanup)
        target = repo_root / "core/capacitor-core/src/runtime_setup.rs"
        target.write_text(target.read_text().replace("resolve_symlink_target", "symlink_target_removed"))
        module = load_module_from_path(
            "HookSetupContractsTemp",
            repo_root / ".verifier/specs/HookSetupContracts.py",
            extra_paths=[repo_root / ".verifier/specs"],
        )

        violations = module.verify({})

        self.assertIn("hook_setup_symlink_resolution_helper_missing", {violation["rule"] for violation in violations})

    def test_replay_parity_contracts_pass_on_repo(self) -> None:
        module = load_module_from_path(
            "ReplayParityContracts",
            ROOT / ".verifier/specs/ReplayParityContracts.py",
            extra_paths=[ROOT / ".verifier/specs"],
        )
        facts = {
            "modules": [
                {
                    "path": "core/capacitor-core/tests/replay_diff.rs",
                    "definitions": [
                        {"value": "replay_diff_corpus_matches_expected_and_is_deterministic", "line": 1},
                        {"value": "replay_diff_shadow_snapshot_read_model_matches_runtime_snapshot", "line": 2},
                    ],
                }
            ],
            "replay_cases": [
                {
                    "name": "case-one",
                    "fixture_path": "core/capacitor-core/tests/fixtures/replay/case-one.json",
                    "events": [{"kind": "shell"}],
                    "expected": {"events_ingested": 1, "shell_count": 1},
                }
            ],
        }

        self.assertEqual([], module.verify(facts))

    def test_replay_parity_contracts_fail_when_fixture_names_duplicate(self) -> None:
        module = load_module_from_path(
            "ReplayParityContracts",
            ROOT / ".verifier/specs/ReplayParityContracts.py",
            extra_paths=[ROOT / ".verifier/specs"],
        )
        facts = {
            "modules": [
                {
                    "path": "core/capacitor-core/tests/replay_diff.rs",
                    "definitions": [
                        {"value": "replay_diff_corpus_matches_expected_and_is_deterministic", "line": 1},
                        {"value": "replay_diff_shadow_snapshot_read_model_matches_runtime_snapshot", "line": 2},
                    ],
                }
            ],
            "replay_cases": [
                {"name": "dup", "fixture_path": "a.json", "events": [{"kind": "shell"}], "expected": {"events_ingested": 1, "shell_count": 1}},
                {"name": "dup", "fixture_path": "b.json", "events": [{"kind": "shell"}], "expected": {"events_ingested": 1, "shell_count": 1}},
            ],
        }

        violations = module.verify(facts)

        self.assertIn("duplicate_replay_case_name", {violation["rule"] for violation in violations})

    def test_runtime_boundary_contracts_pass_on_repo(self) -> None:
        module = load_module_from_path(
            "RuntimeBoundaryContracts",
            ROOT / ".verifier/specs/RuntimeBoundaryContracts.py",
            extra_paths=[ROOT / ".verifier/specs"],
        )
        facts = self.build_facts(
            ROOT,
            [
                "core/hud-hook/src/runtime_client.rs",
                "core/capacitor-core/src/domain/types.rs",
                "core/capacitor-core/src/reduce/mod.rs",
                "apps/swift/Sources/Capacitor/Models/RuntimeClient.swift",
                "apps/swift/Sources/Capacitor/Models/ShellStateStore.swift",
                "core/hud-hook/src/cwd.rs",
                "core/capacitor-core/src/ingest/mod.rs",
                "apps/swift/Sources/Capacitor/Models/AppState.swift",
                "apps/swift/Sources/Capacitor/Models/HookServerManager.swift",
                "core/hud-hook/src/serve.rs",
            ],
        )

        self.assertEqual([], module.verify(facts))

    def test_runtime_boundary_contracts_fail_when_status_only_check_returns(self) -> None:
        copied_paths = [
            "core/hud-hook/src/runtime_client.rs",
            "core/capacitor-core/src/domain/types.rs",
            "core/capacitor-core/src/reduce/mod.rs",
            "apps/swift/Sources/Capacitor/Models/RuntimeClient.swift",
            "apps/swift/Sources/Capacitor/Models/ShellStateStore.swift",
            "core/hud-hook/src/cwd.rs",
            "core/capacitor-core/src/ingest/mod.rs",
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            "apps/swift/Sources/Capacitor/Models/HookServerManager.swift",
            "core/hud-hook/src/serve.rs",
            "core/capacitor-core/src/runtime_service/mod.rs",
            "apps/swift/Sources/Capacitor/Models/ActivationPolicy.swift",
            "apps/swift/Tests/CapacitorTests/ActivationPolicyTests.swift",
            "core/capacitor-core/src/runtime_state/snapshot.rs",
            "apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift",
            "apps/swift/Tests/CapacitorTests/HookServerManagerTests.swift",
        ]
        temp_dir, repo_root = self.copy_spec_repo("RuntimeBoundaryContracts", copied_paths)
        self.addCleanup(temp_dir.cleanup)
        target = repo_root / "apps/swift/Sources/Capacitor/Models/HookServerManager.swift"
        target.write_text(target.read_text() + '\nlet verifierRegression = health.status == "ok"\n')
        module = load_module_from_path(
            "RuntimeBoundaryContractsTemp",
            repo_root / ".verifier/specs/RuntimeBoundaryContracts.py",
            extra_paths=[repo_root / ".verifier/specs"],
        )
        facts = self.build_facts(
            repo_root,
            [
                "core/hud-hook/src/runtime_client.rs",
                "core/capacitor-core/src/domain/types.rs",
                "core/capacitor-core/src/reduce/mod.rs",
                "apps/swift/Sources/Capacitor/Models/RuntimeClient.swift",
                "apps/swift/Sources/Capacitor/Models/ShellStateStore.swift",
                "core/hud-hook/src/cwd.rs",
                "core/capacitor-core/src/ingest/mod.rs",
                "apps/swift/Sources/Capacitor/Models/AppState.swift",
                "apps/swift/Sources/Capacitor/Models/HookServerManager.swift",
                "core/hud-hook/src/serve.rs",
            ],
        )

        violations = module.verify(facts)

        self.assertIn("runtime_health_status_only_checks_stay_deleted", {violation["rule"] for violation in violations})

    def test_terminal_routing_contracts_pass_on_repo(self) -> None:
        module = load_module_from_path(
            "TerminalRoutingContracts",
            ROOT / ".verifier/specs/TerminalRoutingContracts.py",
            extra_paths=[ROOT / ".verifier/specs"],
        )

        self.assertEqual([], module.verify({}))

    def test_terminal_routing_contracts_fail_when_switch_returns(self) -> None:
        temp_dir, repo_root = self.copy_spec_repo("TerminalRoutingContracts", ["apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift"])
        self.addCleanup(temp_dir.cleanup)
        target = repo_root / "apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift"
        target.write_text(target.read_text() + "\nswitch app { case .ghostty: break default: break }\n")
        module = load_module_from_path(
            "TerminalRoutingContractsTemp",
            repo_root / ".verifier/specs/TerminalRoutingContracts.py",
            extra_paths=[repo_root / ".verifier/specs"],
        )

        violations = module.verify({})

        self.assertIn("no_terminal_switch_cases_inside_launcher", {violation["rule"] for violation in violations})

    def test_ghostty_automation_contracts_passes_on_repo(self) -> None:
        module = load_module_from_path(
            "GhosttyAutomationContracts",
            ROOT / ".verifier/specs/GhosttyAutomationContracts.py",
            extra_paths=[ROOT / ".verifier/specs"],
        )
        facts = self.build_facts(
            ROOT,
            [
                "apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift",
                "apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift",
                "docs/ARCHITECTURE.md",
            ],
        )

        self.assertEqual([], module.verify(facts))

    def test_ghostty_automation_contracts_fails_when_legacy_tokens_return(self) -> None:
        module = load_module_from_path(
            "GhosttyAutomationContracts",
            ROOT / ".verifier/specs/GhosttyAutomationContracts.py",
            extra_paths=[ROOT / ".verifier/specs"],
        )
        facts = {
            "modules": [
                {
                    "path": "apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift",
                    "references": [{"value": "GhosttyAXReader", "line": 10}],
                    "shell_command_literals": [],
                }
            ]
        }

        violations = module.verify(facts)

        self.assertIn("ghostty_applescript_adapter_exclusive", {violation["rule"] for violation in violations})


if __name__ == "__main__":
    unittest.main()
