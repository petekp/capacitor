from __future__ import annotations

from _helpers import contract


def contracts():
    return [
        contract(
            "runtime_health_contracts",
            proofs=[
                "runtime_health_rust_rejects_unexpected_protocol_version",
                "runtime_health_rust_rejects_unexpected_auth_mode",
                "runtime_health_rust_rejects_unexpected_service_mode",
                "runtime_health_swift_rejects_unexpected_protocol_version",
                "runtime_health_swift_rejects_unexpected_auth_mode",
                "runtime_health_swift_rejects_unexpected_service_mode",
                "hook_server_manager_rejects_unexpected_protocol_version",
                "hook_server_manager_rejects_unexpected_auth_mode",
                "hook_server_manager_rejects_unexpected_service_mode",
            ],
        ),
        contract(
            "activation_policy_contracts",
            proofs=[
                "activation_policy_ignores_client_tty_shell_evidence_on_route_miss",
                "activation_policy_ignores_session_shell_evidence_on_route_miss",
                "activation_policy_ignores_project_path_shell_evidence_on_route_miss",
            ],
        ),
        contract(
            "terminal_activation_coordinator_contracts",
            proofs=[
                "terminal_activation_request_arbitration",
                "terminal_activation_unified_flow_reports_results",
            ],
            tla_specs=["TerminalActivationCoordinator"],
        ),
        contract(
            "session_projection_hysteresis_contracts",
            proofs=[
                "session_projection_holds_single_empty_snapshot_then_commits_second",
                "session_projection_idle_stabilization_commits_after_threshold",
                "session_projection_idle_stabilization_resets_on_active",
                "app_state_repeated_runtime_snapshot_failures_clear_stale_activity",
            ],
            tla_specs=["SessionProjectionHysteresis"],
        ),
    ]
