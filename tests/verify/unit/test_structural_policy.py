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


class StructuralPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.policy = load_module("structural_policy", "scripts/verify/structural_policy.py")
        cls.config = yaml.safe_load((ROOT / ".verifier/structural.yaml").read_text())

    def test_hard_layer1_rules_use_only_allowed_fact_kinds(self) -> None:
        audit = self.policy.build_rule_audit(self.config)
        hard_layer1 = {entry["rule"]: entry for entry in audit if entry["decision"] == "stay_in_layer1"}

        self.assertEqual(
            {
                "swift_runtime_service_reads_owned",
                "runtime_shadow_owners_stay_deleted",
                "activation_policy_not_distributed",
                "tmux_router_exclusive_command_owner",
                "hud_hook_owns_runtime_routes",
                "rust_runtime_health_probe_validates_bootstrap_contract",
                "swift_runtime_health_consumers_validate_bootstrap_contract",
                "no_snapshot_file_first_live_boundary",
                "no_launcher_detect_available_fallback",
                "launcher_does_not_own_session_discovery_fallback",
                "swift_tmux_session_discovery_stays_deleted",
                "swift_tmux_pane_recovery_stays_deleted",
                "no_legacy_raw_route_shape",
                "host_focus_applescript_stays_in_terminal_drivers",
                "runtime_activation_shadow_path_stays_deleted",
            },
            set(hard_layer1),
        )
        self.assertTrue(all(entry["layer1_sound"] for entry in hard_layer1.values()))
        self.assertTrue(
            all(entry["fact_kind"] in self.policy.ALLOWED_HARD_LAYER1_FACT_KINDS for entry in hard_layer1.values())
        )

    def test_unsound_rules_are_explicitly_reclassified(self) -> None:
        audit = {entry["rule"]: entry for entry in self.policy.build_rule_audit(self.config)}

        self.assertEqual("move_to_layer2", audit["ghostty_applescript_adapter_exclusive"]["decision"])
        self.assertEqual("move_to_layer2", audit["runtime_health_status_only_checks_stay_deleted"]["decision"])
        self.assertEqual("move_to_layer2", audit["no_terminal_switch_cases_inside_launcher"]["decision"])
        self.assertEqual("advisory", audit["no_legacy_ghostty_keystroke_or_ax_tokens"]["decision"])
        self.assertEqual("low", audit["no_legacy_ghostty_keystroke_or_ax_tokens"]["confidence"])

    def test_policy_flags_unsound_hard_layer1_rules(self) -> None:
        config = {
            "meta": {"canonical_docs": []},
            "patterns": [
                {
                    "rule": "bad_regex_rule",
                    "description": "bad",
                    "constraint": {"files_matching": ["src/**/*.swift"], "must_not": "not_a_fact_kind:bad"},
                }
            ],
        }

        audit = self.policy.build_rule_audit(config)

        self.assertEqual("not_a_fact_kind", audit[0]["fact_kind"])
        self.assertFalse(audit[0]["layer1_sound"])


if __name__ == "__main__":
    unittest.main()
