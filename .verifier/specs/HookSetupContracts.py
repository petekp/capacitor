from __future__ import annotations

from _helpers import contract

SPEC_METADATA = {
    "spec_id": "HookSetupContracts",
    "proof_kind": "python",
    "claims_proven": ["hook_setup_contracts"],
    "checks_executed": [
        "hook_setup_helpers_present",
        "hook_setup_call_sites_use_helpers",
        "hook_setup_named_regression_tests_present",
    ],
    "assumptions": [],
    "supporting_artifacts": [
        ".verifier/specs/HookSetupContracts.py",
        "core/capacitor-core/src/runtime_setup.rs",
    ],
}


def contracts():
    return [
        contract(
            "hook_setup_contracts",
            proofs=[
                "hook_setup_verify_hook_binary_relative_symlink",
                "hook_setup_check_hooks_status_relative_symlink",
                "hook_setup_install_binary_relative_symlink_idempotence",
                "hook_setup_remove_hooks_preserves_custom_inner_hooks",
            ],
        ),
        contract(
            "hook_server_lifecycle_contracts",
            proofs=[
                "hook_server_lifecycle_starts_running_after_healthy_startup",
                "hook_server_lifecycle_restarts_after_threshold_failures",
                "hook_server_lifecycle_stop_dominates_late_failures",
                "hook_server_lifecycle_stop_prevents_late_restart",
            ],
            tla_specs=["HookServerLifecycle"],
        ),
    ]
