from __future__ import annotations

from z3 import Int, Solver, sat

from _helpers import module_by_path, violation

SPEC_METADATA = {
    "spec_id": "ReplayParityContracts",
    "proof_kind": "python",
    "claims_proven": ["replay_parity_contracts"],
    "checks_executed": [
        "replay_corpus_present",
        "replay_guard_tests_present",
        "replay_case_names_unique",
        "replay_expectations_satisfiable",
    ],
    "assumptions": [],
    "supporting_artifacts": [
        ".verifier/specs/ReplayParityContracts.py",
        "core/capacitor-core/tests/replay_diff.rs",
        "core/capacitor-core/tests/fixtures/replay",
    ],
}


def verify(facts):
    violations = []
    replay_cases = facts.get("replay_cases", [])
    if not replay_cases:
        return [
            violation(
                "replay_corpus_missing",
                "Replay corpus fixtures are missing",
                "Behavioral verification expects committed replay fixtures under core/capacitor-core/tests/fixtures/replay.",
            )
        ]

    replay_test = module_by_path(facts, "core/capacitor-core/tests/replay_diff.rs")
    required_tests = {
        "replay_diff_corpus_matches_expected_and_is_deterministic",
        "replay_diff_shadow_snapshot_read_model_matches_runtime_snapshot",
    }
    actual_tests = {entry["value"] for entry in replay_test.get("definitions", [])} if replay_test else set()
    missing_tests = sorted(required_tests - actual_tests)
    if missing_tests:
        violations.append(
            violation(
                "replay_guard_tests_missing",
                "Replay parity guard tests are missing",
                f"Missing replay tests: {', '.join(missing_tests)}.",
                path="core/capacitor-core/tests/replay_diff.rs",
                fix="Restore the replay diff guard tests so the runtime parity contract stays executable.",
            )
        )

    names = set()
    for case in replay_cases:
        name = case.get("name")
        if name in names:
            violations.append(
                violation(
                    "duplicate_replay_case_name",
                    "Replay fixture names must be unique",
                    f"Replay case {name} appears more than once.",
                    path=case.get("fixture_path"),
                )
            )
        names.add(name)

        solver = Solver()
        event_count = Int(f"{name}_event_count")
        ingested_count = Int(f"{name}_ingested_count")
        shell_count = Int(f"{name}_shell_count")
        solver.add(event_count == len(case.get("events", [])))
        solver.add(ingested_count == case.get("expected", {}).get("events_ingested", 0))
        solver.add(shell_count == case.get("expected", {}).get("shell_count", 0))
        solver.add(event_count >= 1)
        solver.add(ingested_count >= 0)
        solver.add(shell_count >= 0)
        solver.add(ingested_count <= event_count)
        if solver.check() != sat:
            violations.append(
                violation(
                    "replay_case_impossible_expectation",
                    "Replay fixture expectation is internally inconsistent",
                    f"Replay case {name} has expectations that cannot be satisfied by its event count.",
                    path=case.get("fixture_path"),
                    fix="Fix the replay fixture so expected counts reflect the actual replay corpus.",
                )
            )

    return violations
