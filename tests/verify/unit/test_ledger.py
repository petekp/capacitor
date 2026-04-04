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


class LedgerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.ledger = load_module("ledger", "scripts/verify/ledger.py")
        cls.structural = yaml.safe_load((ROOT / ".verifier/structural.yaml").read_text())
        cls.claims = yaml.safe_load((ROOT / ".verifier/canonical-claims.yaml").read_text())
        cls.ledger_config = yaml.safe_load((ROOT / ".verifier/ledger.yaml").read_text())

    def test_hard_claims_have_dedicated_proof_pairs(self) -> None:
        audit = self.ledger.audit_ledger(
            structural_config=self.structural,
            canonical_claims=self.claims,
            ledger_config=self.ledger_config,
            repo_root=ROOT,
        )

        self.assertEqual([], audit["missing_claims"])
        self.assertEqual([], audit["orphaned_rules"])
        self.assertEqual([], audit["missing_positive_fixtures"])
        self.assertEqual([], audit["missing_negative_fixtures"])
        self.assertEqual([], audit["missing_fixture_artifacts"])

    def test_ledger_flags_missing_negative_fixture(self) -> None:
        claims = {"claims": [{"claim_id": "claim.alpha", "enforcement": "hard"}]}
        structural = {"meta": {}, "ownership": [{"rule": "rule.alpha", "claim_id": "claim.alpha", "constraint": {}}]}
        ledger = {
            "claims": {
                "claim.alpha": {
                    "structural_rules": ["rule.alpha"],
                    "positive_fixtures": ["tests/verify/fixtures/example.yaml#pass"],
                    "negative_fixtures": [],
                }
            }
        }

        audit = self.ledger.audit_ledger(
            structural_config=structural,
            canonical_claims=claims,
            ledger_config=ledger,
            repo_root=ROOT,
        )

        self.assertEqual(["claim.alpha"], audit["missing_negative_fixtures"])

    def test_ledger_flags_missing_fixture_artifact_paths(self) -> None:
        claims = {"claims": [{"claim_id": "claim.alpha", "enforcement": "hard"}]}
        structural = {"meta": {}, "ownership": [{"rule": "rule.alpha", "claim_id": "claim.alpha", "constraint": {}}]}
        ledger = {
            "claims": {
                "claim.alpha": {
                    "structural_rules": ["rule.alpha"],
                    "positive_fixtures": ["tests/verify/unit/does-not-exist.py#pass"],
                    "negative_fixtures": ["tests/verify/unit/does-not-exist.py#fail"],
                }
            }
        }

        audit = self.ledger.audit_ledger(
            structural_config=structural,
            canonical_claims=claims,
            ledger_config=ledger,
            repo_root=ROOT,
        )

        self.assertEqual(["claim.alpha"], audit["missing_fixture_artifacts"])


if __name__ == "__main__":
    unittest.main()
