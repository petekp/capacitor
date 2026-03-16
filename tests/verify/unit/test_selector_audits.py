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


class SelectorAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.check_structural = load_module("check_structural", "scripts/verify/check-structural.py")

    def test_hard_rule_fails_closed_when_scope_is_empty_after_generated_exclusion(self) -> None:
        rule = {
            "rule": "example_rule",
            "category": "ownership",
            "constraint": {"files_matching": ["apps/swift/Sources/**/*.swift"], "must_not": "reference:forbidden"},
        }
        modules = [
            {
                "path": "apps/swift/Sources/Capacitor/Bridge/capacitor_core.swift",
                "name": "capacitor_core",
                "language": "swift",
                "category": "swift_source",
                "generated": True,
                "references": [],
                "imports": [],
                "calls": [],
                "implements": [],
                "definitions": [],
                "string_literals": [],
                "http_routes": [],
                "shell_command_literals": [],
                "doc_claims": [],
            }
        ]

        violations, audit = self.check_structural.check_rule_with_audit(rule, modules, ROOT)

        self.assertEqual("example_rule", violations[0].rule)
        self.assertTrue(audit["scope_empty"])
        self.assertEqual(1, audit["generated_excluded"])
        self.assertEqual(0, audit["modules_selected"])

    def test_allow_empty_scope_suppresses_empty_scope_failure(self) -> None:
        rule = {
            "rule": "example_rule",
            "category": "ownership",
            "constraint": {
                "files_matching": ["apps/swift/Sources/**/*.swift"],
                "must_not": "reference:forbidden",
                "allow_empty_scope": True,
            },
        }
        modules = []

        violations, audit = self.check_structural.check_rule_with_audit(rule, modules, ROOT)

        self.assertEqual([], violations)
        self.assertTrue(audit["scope_empty"])


if __name__ == "__main__":
    unittest.main()
