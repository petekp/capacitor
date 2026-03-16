from __future__ import annotations

from _helpers import contract


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
