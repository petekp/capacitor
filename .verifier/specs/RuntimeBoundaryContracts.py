from __future__ import annotations

import re
from pathlib import Path

from z3 import BoolVal, Solver, sat

from _helpers import module_by_path, module_has_regex, violation

SPEC_METADATA = {
    "spec_id": "RuntimeBoundaryContracts",
    "proof_kind": "python",
    "claims_proven": [
        "rust_runtime_health_probe_validates_bootstrap_contract",
        "swift_runtime_health_consumers_validate_bootstrap_contract",
        "runtime_health_status_only_checks_stay_deleted",
    ],
    "checks_executed": [
        "tmux_contract_surface_complete",
        "runtime_route_wire_shape_complete",
        "legacy_runtime_boundary_symbols_absent",
        "runtime_service_endpoints_present",
        "runtime_health_contract_enforced",
        "reducer_tmux_ownership_regression_proofs_present",
        "activation_policy_runtime_ownership_guards_present",
        "activation_policy_route_miss_proofs_present",
        "runtime_health_regression_tests_present",
        "runtime_service_activation_route_query_present",
        "app_state_requests_activation_route_query",
    ],
    "assumptions": [],
    "supporting_artifacts": [
        ".verifier/specs/RuntimeBoundaryContracts.py",
        "core/capacitor-core/src/runtime_service/mod.rs",
        "core/hud-hook/src/serve.rs",
        "core/capacitor-core/src/reduce/mod.rs",
        "apps/swift/Sources/Capacitor/Models/RuntimeClient.swift",
        "apps/swift/Sources/Capacitor/Models/HookServerManager.swift",
        "apps/swift/Sources/Capacitor/Models/AppState.swift",
        "apps/swift/Sources/Capacitor/Models/ActivationPolicy.swift",
    ],
}


def verify_reducer_tmux_ownership(reducer_module, violations):
    if not module_has_regex(reducer_module, "references", r"\binfer_attached_tmux_terminal_app\b"):
        violations.append(
            violation(
                "attached_tmux_terminal_app_inference",
                "Reducer no longer infers host terminal app for attached tmux routes",
                "core/capacitor-core/src/reduce/mod.rs must keep the attached-tmux terminal-app inference seam so Swift does not have to recover host-terminal identity from shell evidence alone.",
                path="core/capacitor-core/src/reduce/mod.rs",
                fix="Restore attached tmux terminal-app inference in the reducer or update the verifier intentionally.",
            )
        )

    if not module_has_regex(
        reducer_module,
        "definitions",
        r"\brouting_infers_attached_tmux_terminal_app_from_host_tty_shell_evidence\b",
    ):
        violations.append(
            violation(
                "attached_tmux_terminal_app_regression",
                "Reducer regression coverage for attached tmux terminal-app inference is missing",
                "The Rust reducer no longer carries the regression test that proves attached tmux routes preserve host-terminal identity from host-tty shell evidence.",
                path="core/capacitor-core/src/reduce/mod.rs",
                fix="Restore the reducer regression test or replace it with an equivalent proof artifact intentionally.",
            )
        )

    if not module_has_regex(
        reducer_module,
        "definitions",
        r"\brouting_derives_non_active_tmux_pane_from_inventory\b",
    ):
        violations.append(
            violation(
                "tmux_pane_inventory_regression",
                "Reducer regression coverage for tmux pane inventory routing is missing",
                "The Rust reducer no longer carries the regression test that proves pane inventory can route a project from a non-active tmux pane.",
                path="core/capacitor-core/src/reduce/mod.rs",
                fix="Restore the pane-inventory routing regression test or replace it with an equivalent proof artifact intentionally.",
            )
        )


def verify_runtime_service_endpoints(runtime_client, hook_manager, violations):
    if not module_has_regex(runtime_client, "http_routes", r"^/runtime/snapshot$"):
        violations.append(
            violation(
                "runtime_client_snapshot_route",
                "RuntimeClient no longer targets the runtime snapshot endpoint",
                "Live Swift runtime reads should continue to use the authenticated runtime-service snapshot route.",
                path="apps/swift/Sources/Capacitor/Models/RuntimeClient.swift",
            )
        )

    if not module_has_regex(hook_manager, "http_routes", r"^/health$"):
        violations.append(
            violation(
                "hook_server_manager_health_route",
                "HookServerManager no longer targets the health endpoint",
                "HookServerManager should remain the Swift-side owner of runtime-service health supervision.",
                path="apps/swift/Sources/Capacitor/Models/HookServerManager.swift",
            )
        )
    if not module_has_regex(runtime_client, "http_routes", r"^/runtime/routing/resolve$"):
        violations.append(
            violation(
                "runtime_client_activation_route_query",
                "RuntimeClient no longer targets the activation-route query endpoint",
                "Swift activation should be able to ask the runtime service for an on-demand route when snapshot routing is missing for an ad hoc project.",
                path="apps/swift/Sources/Capacitor/Models/RuntimeClient.swift",
            )
        )


def verify_runtime_health_contract(repo_root, violations):
    runtime_client_source = (
        repo_root / "apps/swift/Sources/Capacitor/Models/RuntimeClient.swift"
    ).read_text()
    hook_manager_source = (
        repo_root / "apps/swift/Sources/Capacitor/Models/HookServerManager.swift"
    ).read_text()
    app_state_source = (
        repo_root / "apps/swift/Sources/Capacitor/Models/AppState.swift"
    ).read_text()
    runtime_service_source = (
        repo_root / "core/capacitor-core/src/runtime_service/mod.rs"
    ).read_text()

    if re.search(r'case authMode = "auth_mode"[\s\S]*case serviceMode = "service_mode"', runtime_client_source) is None:
        violations.append(
            violation(
                "runtime_health_wire_contract_gap",
                "Swift runtime health model no longer decodes auth_mode and service_mode",
                "Swift health consumers must decode the full runtime bootstrap contract so they can reject unauthenticated or non-bootstrap services.",
                path="apps/swift/Sources/Capacitor/Models/RuntimeClient.swift",
                fix="Restore auth_mode/service_mode decoding and keep the runtime health contract explicit.",
            )
        )

    if "isCompatibleBootstrapService" not in runtime_client_source:
        violations.append(
            violation(
                "runtime_health_validation_helper_missing",
                "Swift runtime health compatibility helper is missing",
                "RuntimeClient should centralize runtime bootstrap contract validation instead of leaving lifecycle code to reinterpret health payloads ad hoc.",
                path="apps/swift/Sources/Capacitor/Models/RuntimeClient.swift",
                fix="Restore RuntimeHealth.isCompatibleBootstrapService or an equivalent shared validation seam intentionally.",
            )
        )

    if re.search(r"fetchServiceHealth\(\)[\s\S]*isCompatibleBootstrapService", runtime_client_source) is None:
        violations.append(
            violation(
                "runtime_client_health_contract_not_enforced",
                "RuntimeClient no longer rejects unexpected runtime health contracts",
                "RuntimeClient.fetchHealth should fail when the runtime service reports the wrong protocol, auth mode, or service mode.",
                path="apps/swift/Sources/Capacitor/Models/RuntimeClient.swift",
                fix="Validate the decoded RuntimeHealth payload before returning it to callers.",
            )
        )

    if re.search(r"isCompatibleBootstrapServiceHealth[\s\S]*isCompatibleBootstrapService", hook_manager_source) is None:
        violations.append(
            violation(
                "hook_server_manager_health_contract_not_enforced",
                "HookServerManager no longer validates the full runtime bootstrap health contract",
                "HookServerManager readiness and adoption checks should only succeed for the authenticated bootstrap runtime service, not any server that returns status=ok.",
                path="apps/swift/Sources/Capacitor/Models/HookServerManager.swift",
                fix="Decode RuntimeHealth and require isCompatibleBootstrapService in HookServerManager.fetchHealth.",
            )
        )

    if "health.isCompatibleBootstrapService" not in app_state_source:
        violations.append(
            violation(
                "app_state_health_status_only",
                "AppState no longer records runtime health via the shared bootstrap contract helper",
                "AppState should derive RuntimeStatus.isHealthy from the same validated health contract the runtime client enforces.",
                path="apps/swift/Sources/Capacitor/Models/AppState.swift",
                fix="Use health.isCompatibleBootstrapService when updating RuntimeStatus.",
            )
        )

    if re.search(r'health\.status == "ok"|status == "ok"', hook_manager_source) or re.search(
        r'health\.status == "ok"|status == "ok"',
        app_state_source,
    ):
        violations.append(
            violation(
                "runtime_health_status_only_checks_stay_deleted",
                "Swift lifecycle code reintroduced status-only runtime health checks",
                "HookServerManager and AppState should rely on the shared bootstrap compatibility contract instead of treating status=ok as sufficient.",
                path="apps/swift/Sources/Capacitor/Models/HookServerManager.swift",
                fix="Delete the status-only check and route the decision through isCompatibleBootstrapService.",
            )
        )

    if "validate_bootstrap_contract" not in runtime_service_source:
        violations.append(
            violation(
                "rust_runtime_health_validation_helper_missing",
                "Rust runtime-service health validation helper is missing",
                "Rust callers should centralize runtime bootstrap contract validation so runtime_health cannot accept protocol/auth drift silently.",
                path="core/capacitor-core/src/runtime_service/mod.rs",
                fix="Restore RuntimeServiceHealth::validate_bootstrap_contract or an equivalent helper intentionally.",
            )
        )

    if re.search(r"probe_health\(&self\) -> Result<RuntimeServiceHealth, String>\s*\{[\s\S]*validate_bootstrap_contract\(\)\?;", runtime_service_source) is None:
        violations.append(
            violation(
                "rust_probe_health_contract_not_enforced",
                "Rust runtime-service probe no longer validates the bootstrap contract",
                "RuntimeServiceEndpoint::probe_health should reject non-bootstrap or unauthenticated health payloads instead of treating any 200 JSON response as healthy.",
                path="core/capacitor-core/src/runtime_service/mod.rs",
                fix="Call validate_bootstrap_contract from probe_health before returning success.",
            )
        )


def verify_activation_policy_guards(repo_root, violations):
    activation_policy_source = (
        repo_root / "apps/swift/Sources/Capacitor/Models/ActivationPolicy.swift"
    ).read_text()

    attached_route_runtime_guard = re.search(
        r"if routeRequiresRuntimeTerminalApp\(route: route\)\s*\{\s*return ActivationPolicyIntent\([\s\S]*?source: \.fallback",
        activation_policy_source,
    )
    if attached_route_runtime_guard is None:
        violations.append(
            violation(
                "attached_tmux_terminal_app_is_runtime_owned_in_swift",
                "ActivationPolicy still repairs attached tmux terminal-app inference with shell evidence",
                "Swift should treat attached tmux terminal-app identity as runtime-owned and fall back locally instead of re-deriving that host-app choice from shell evidence.",
                path="apps/swift/Sources/Capacitor/Models/ActivationPolicy.swift",
                fix="Add an explicit attached-tmux runtime-terminal-app guard before shell-evidence fallback and keep the host-app seam owned by Rust.",
            )
        )

    if "preferredTmuxPaneFromShellState" in activation_policy_source:
        violations.append(
            violation(
                "tmux_pane_routing_is_runtime_owned_in_swift",
                "ActivationPolicy still recovers tmux pane targets from shell evidence",
                "Swift should stop reconstructing tmux pane routing from shell state now that Rust owns pane selection through routed tmux_panes inventory.",
                path="apps/swift/Sources/Capacitor/Models/ActivationPolicy.swift",
                fix="Delete shell-state tmux pane recovery from ActivationPolicy and rely on routed pane ids only.",
            )
        )

    if re.search(r"\bpreferredTerminalAppFromShellState\b|\.shellEvidence\b", activation_policy_source):
        violations.append(
            violation(
                "terminal_app_ranking_is_runtime_owned_in_swift",
                "ActivationPolicy still ranks terminal apps from shell evidence",
                "Swift activation should now treat terminal-app selection as runtime-route-or-fallback only. Shell state can inform diagnostics, but production activation should not keep a .shellEvidence path or reconstruct terminal-app ranking locally.",
                path="apps/swift/Sources/Capacitor/Models/ActivationPolicy.swift",
                fix="Delete preferredTerminalAppFromShellState, remove the .shellEvidence activation path, and keep runtime-route-or-fallback as the only production terminal-app sources.",
            )
        )


def verify_activation_policy_test_proofs(repo_root, violations):
    activation_policy_tests = (
        repo_root / "apps/swift/Tests/CapacitorTests/ActivationPolicyTests.swift"
    ).read_text()

    required_test_proofs = {
        "testResolveIntentIgnoresShellEvidenceClientTtyMatchWhenRouteMissing":
            "When runtime routing is absent, matching shell evidence should no longer choose the terminal app from client-tty ranking. The policy should preserve the caller session hint and fall back locally without recovering pane or host hints.",
        "testResolveIntentIgnoresShellEvidenceSessionMatchWhenRouteMissing":
            "When runtime routing is absent, shell-session matches should no longer choose the terminal app. The policy should preserve the caller session hint and fall back locally without recovering pane or host hints.",
        "testResolveIntentIgnoresShellEvidenceProjectPathMatchWhenRouteMissing":
            "When runtime routing is absent, project-path shell matches should no longer choose the terminal app. The policy should preserve the caller session hint and fall back locally without recovering pane or host hints.",
    }

    for test_name, diagnosis in required_test_proofs.items():
        pattern = rf"func {test_name}\(\)\s*\{{[\s\S]*?XCTAssertEqual\(intent\.terminalApp\.source, \.fallback\)[\s\S]*?XCTAssertEqual\(intent\.sessionName,[\s\S]*?XCTAssertNil\(intent\.paneId\)[\s\S]*?XCTAssertNil\(intent\.hostTty\)"
        if re.search(pattern, activation_policy_tests) is None:
            violations.append(
                violation(
                    "activation_policy_shell_evidence_test_gap",
                    "ActivationPolicy route-miss fallback proof is incomplete",
                    diagnosis,
                    path="apps/swift/Tests/CapacitorTests/ActivationPolicyTests.swift",
                    fix="Add or tighten the named ActivationPolicy regression test so it proves shell evidence is ignored for terminal-app ranking when runtime routing is missing.",
                )
            )


def verify_runtime_health_test_proofs(repo_root, violations):
    runtime_snapshot_tests = (
        repo_root / "core/capacitor-core/src/runtime_state/snapshot.rs"
    ).read_text()
    runtime_client_tests = (
        repo_root / "apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift"
    ).read_text()
    hook_manager_tests = (
        repo_root / "apps/swift/Tests/CapacitorTests/HookServerManagerTests.swift"
    ).read_text()

    required_rust_tests = {
        "runtime_health_rejects_unexpected_protocol_version":
            "Rust health checks should reject mismatched protocol versions.",
        "runtime_health_rejects_unexpected_auth_mode":
            "Rust health checks should reject non-bearer auth modes.",
        "runtime_health_rejects_unexpected_service_mode":
            "Rust health checks should reject non-bootstrap service modes.",
    }
    for test_name, diagnosis in required_rust_tests.items():
        if f"fn {test_name}()" not in runtime_snapshot_tests:
            violations.append(
                violation(
                    "runtime_health_rust_test_gap",
                    "Rust runtime health contract proof is incomplete",
                    diagnosis,
                    path="core/capacitor-core/src/runtime_state/snapshot.rs",
                    fix="Restore the named runtime health regression test so protocol/auth/service-mode drift stays executable.",
                )
            )

    required_swift_tests = {
        "testFetchHealthRejectsUnexpectedProtocolVersion":
            "RuntimeClient should reject mismatched protocol versions.",
        "testFetchHealthRejectsUnexpectedAuthMode":
            "RuntimeClient should reject unexpected auth modes.",
        "testFetchHealthRejectsUnexpectedServiceMode":
            "RuntimeClient should reject unexpected service modes.",
    }
    for test_name, diagnosis in required_swift_tests.items():
        if f"func {test_name}()" not in runtime_client_tests:
            violations.append(
                violation(
                    "runtime_health_swift_test_gap",
                    "Swift runtime health contract proof is incomplete",
                    diagnosis,
                    path="apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift",
                    fix="Restore the named RuntimeClient regression test so health contract drift stays executable.",
                )
            )

    required_hook_manager_tests = {
        "testBootstrapHealthPayloadRejectsUnexpectedProtocolVersion":
            "HookServerManager readiness checks should reject mismatched protocol versions.",
        "testBootstrapHealthPayloadRejectsUnexpectedAuthMode":
            "HookServerManager readiness checks should reject unexpected auth modes.",
        "testBootstrapHealthPayloadRejectsUnexpectedServiceMode":
            "HookServerManager readiness checks should reject unexpected service modes.",
    }
    for test_name, diagnosis in required_hook_manager_tests.items():
        if f"func {test_name}()" not in hook_manager_tests:
            violations.append(
                violation(
                    "hook_server_manager_health_test_gap",
                    "HookServerManager bootstrap health proof is incomplete",
                    diagnosis,
                    path="apps/swift/Tests/CapacitorTests/HookServerManagerTests.swift",
                    fix="Restore the named HookServerManager regression test so server adoption and readiness cannot regress to status-only checks silently.",
                )
            )


def verify(facts):
    violations = []
    modules = facts.get("modules", [])
    by_path = {module["path"]: module for module in modules}
    repo_root = Path(__file__).resolve().parents[2]

    def module_has_tmux_pane_contract(module) -> bool:
        return module_has_regex(module, "references", r"\btmux_pane\b|\btmuxPane\b") or module_has_regex(
            module,
            "string_literals",
            r"\btmux_pane\b",
        )

    required_tmux_contract_paths = [
        "core/hud-hook/src/runtime_client.rs",
        "core/capacitor-core/src/domain/types.rs",
        "core/capacitor-core/src/reduce/mod.rs",
        "apps/swift/Sources/Capacitor/Models/RuntimeClient.swift",
        "apps/swift/Sources/Capacitor/Models/ShellStateStore.swift",
    ]

    solver = Solver()
    for path in required_tmux_contract_paths:
        module = by_path.get(path)
        present = module_has_tmux_pane_contract(module)
        solver.add(BoolVal(present))
        if not present:
            violations.append(
                violation(
                    "tmux_pane_contract_surface",
                    "tmux pane contract surface is incomplete",
                    f"{path} no longer references tmux_pane, which risks breaking the Rust -> service -> Swift routing contract.",
                    path=path,
                    fix="Restore the tmux_pane contract surface or update the verifier intentionally.",
                )
            )

    required_tmux_inventory_paths = [
        "core/hud-hook/src/cwd.rs",
        "core/hud-hook/src/runtime_client.rs",
        "core/capacitor-core/src/domain/types.rs",
        "core/capacitor-core/src/ingest/mod.rs",
        "core/capacitor-core/src/reduce/mod.rs",
    ]
    for path in required_tmux_inventory_paths:
        module = by_path.get(path)
        if not module_has_regex(module, "references", r"\btmux_panes\b"):
            violations.append(
                violation(
                    "tmux_pane_inventory_contract_surface",
                    "tmux pane inventory contract surface is incomplete",
                    f"{path} no longer references tmux_panes, which risks pushing shared-session pane discovery back into Swift.",
                    path=path,
                    fix="Restore the tmux pane inventory contract surface or update the verifier intentionally.",
                )
            )

    if solver.check() != sat:
        violations.append(
            violation(
                "runtime_boundary_contract_unsat",
                "Runtime boundary contract constraints are inconsistent",
                "The tmux pane contract surface cannot be satisfied with the current verifier facts.",
                fix="Inspect the missing contract fields and restore the canonical routing shape.",
            )
        )

    coding_keys = facts.get("constants", {}).get("runtime_client_coding_keys", [])
    actual_wires = {entry["wire"] for entry in coding_keys}
    expected_wires = {"terminal_app", "session_name", "pane_id", "host_tty"}
    missing_wires = sorted(expected_wires - actual_wires)
    if missing_wires:
        violations.append(
            violation(
                "runtime_route_wire_shape",
                "RuntimeClient coding keys no longer expose the canonical routing fields",
                f"Missing routing wire fields: {', '.join(missing_wires)}.",
                path="apps/swift/Sources/Capacitor/Models/RuntimeClient.swift",
                fix="Restore the explicit routing target keys instead of reconstructing them heuristically.",
            )
        )

    legacy_fields = {"target_kind", "target_value", "fetchRuntimeConfig", "fetchCoreRoutingDiagnostics"}
    for module in modules:
        if not (
            module["path"].startswith("apps/swift/Sources/")
            or module["path"].startswith("core/")
        ):
            continue
        for field in legacy_fields:
            if module_has_regex(module, "references", rf"\b{field}\b"):
                violations.append(
                    violation(
                        "legacy_runtime_boundary_field",
                        "Legacy runtime-boundary symbol reintroduced",
                        f"{module['path']} references {field}, which reopens the old shadow boundary confusion.",
                        path=module["path"],
                        fix="Delete the legacy symbol usage and keep the current canonical boundary naming.",
                    )
                )

    runtime_client = module_by_path(facts, "apps/swift/Sources/Capacitor/Models/RuntimeClient.swift")
    app_state = module_by_path(facts, "apps/swift/Sources/Capacitor/Models/AppState.swift")
    hook_manager = module_by_path(facts, "apps/swift/Sources/Capacitor/Models/HookServerManager.swift")
    reducer_module = module_by_path(facts, "core/capacitor-core/src/reduce/mod.rs")
    serve_module = module_by_path(facts, "core/hud-hook/src/serve.rs")
    verify_runtime_service_endpoints(runtime_client, hook_manager, violations)
    verify_runtime_health_contract(repo_root, violations)
    verify_reducer_tmux_ownership(reducer_module, violations)
    verify_activation_policy_guards(repo_root, violations)
    verify_activation_policy_test_proofs(repo_root, violations)
    verify_runtime_health_test_proofs(repo_root, violations)
    if not module_has_regex(serve_module, "http_routes", r"^/runtime/routing/resolve$"):
        violations.append(
            violation(
                "runtime_service_activation_route_query",
                "hud-hook serve no longer exposes the activation-route query endpoint",
                "The runtime service should expose an authenticated on-demand route query so Swift can resolve ad hoc activation targets without reimplementing shell ranking locally.",
                path="core/hud-hook/src/serve.rs",
                fix="Restore the /runtime/routing/resolve runtime-service endpoint or update the verifier intentionally.",
            )
        )
    if not module_has_regex(app_state, "references", r"\bfetchCoreRoutingSnapshot\b"):
        violations.append(
            violation(
                "app_state_activation_route_query",
                "AppState no longer asks RuntimeClient for on-demand activation routes",
                "Swift activation should consult the runtime service for a route when the cached routing snapshot does not include the project, instead of falling straight back to local shell evidence.",
                path="apps/swift/Sources/Capacitor/Models/AppState.swift",
                fix="Restore the on-demand fetchCoreRoutingSnapshot activation query or update the verifier intentionally.",
            )
        )

    return violations
