from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest

import yaml


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


def entry_list(values: list[str]) -> list[dict[str, object]]:
    return [{"value": value, "line": 1} for value in values]


def fact_kind_for_rule(rule: dict[str, object]) -> str | None:
    selector = rule.get("constraint", {})
    fact_spec = selector.get("must_not") or selector.get("must") or selector.get("may")
    if not fact_spec:
        return None
    return str(fact_spec).split(":", 1)[0]


def make_module(payload: dict[str, object]) -> dict[str, object]:
    return {
        "path": payload["path"],
        "name": pathlib.Path(str(payload["path"])).stem,
        "language": payload.get("language", "swift"),
        "category": payload.get("category", "other"),
        "imports": entry_list(payload.get("imports", [])),
        "calls": entry_list(payload.get("calls", [])),
        "implements": entry_list(payload.get("implements", [])),
        "definitions": entry_list(payload.get("definitions", [])),
        "references": entry_list(payload.get("references", [])),
        "string_literals": entry_list(payload.get("string_literals", [])),
        "http_routes": entry_list(payload.get("http_routes", [])),
        "shell_command_literals": entry_list(payload.get("shell_command_literals", [])),
        "doc_claims": entry_list(payload.get("doc_claims", [])),
    }


class StructuralRuleMatrixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.policy = load_module("structural_policy", "scripts/verify/structural_policy.py")
        cls.check_structural = load_module("check_structural", "scripts/verify/check-structural.py")
        cls.config = yaml.safe_load((ROOT / ".verifier/structural.yaml").read_text())
        cls.matrix = yaml.safe_load((ROOT / "tests/verify/fixtures/structural_rule_matrix.yaml").read_text())

    def test_every_hard_layer1_rule_has_a_pass_and_fail_fixture(self) -> None:
        all_rules = self.check_structural.flatten_rules(self.config)
        rules_by_id = {rule["rule"]: rule for rule in all_rules}
        audit = self.policy.build_rule_audit(self.config)
        # Rules that use contains_regex read from disk and cannot be exercised
        # with purely synthetic module fixtures.
        disk_rules = {
            entry["rule"]
            for entry in audit
            if entry["decision"] == "stay_in_layer1"
            and fact_kind_for_rule(rules_by_id[entry["rule"]]) == "contains_regex"
        }
        hard_layer1 = sorted(
            entry["rule"]
            for entry in audit
            if entry["decision"] == "stay_in_layer1" and entry["rule"] not in disk_rules
        )
        self.assertEqual(hard_layer1, sorted(self.matrix))

    def test_rule_matrix_exercises_each_hard_layer1_rule(self) -> None:
        rules = {rule["rule"]: rule for rule in self.check_structural.flatten_rules(self.config)}

        for rule_id, cases in self.matrix.items():
            with self.subTest(rule=rule_id, case="pass"):
                violations = self.check_structural.check_rule(
                    rules[rule_id],
                    [make_module(module) for module in cases["pass"]],
                    ROOT,
                )
                self.assertEqual([], violations)

            with self.subTest(rule=rule_id, case="fail"):
                violations = self.check_structural.check_rule(
                    rules[rule_id],
                    [make_module(module) for module in cases["fail"]],
                    ROOT,
                )
                self.assertEqual([rule_id], [violation.rule for violation in violations])


if __name__ == "__main__":
    unittest.main()
