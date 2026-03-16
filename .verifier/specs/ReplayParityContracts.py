from __future__ import annotations

from _helpers import contract

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


def contracts():
    return [
        contract(
            "replay_parity_contracts",
            proofs=[
                "replay_diff_corpus_matches_expected_and_is_deterministic",
                "replay_diff_shadow_snapshot_read_model_matches_runtime_snapshot",
            ],
        ),
    ]
