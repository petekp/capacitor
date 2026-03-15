from __future__ import annotations

import re
from pathlib import Path

from z3 import BoolVal, Solver, sat

from _helpers import module_by_path, module_has_regex, violation


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


def verify(facts):
    violations = []
    modules = facts.get("modules", [])
    by_path = {module["path"]: module for module in modules}
    repo_root = Path(__file__).resolve().parents[2]

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
        present = module_has_regex(module, "references", r"\btmux_pane\b")
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
    verify_reducer_tmux_ownership(reducer_module, violations)
    verify_activation_policy_guards(repo_root, violations)
    verify_activation_policy_test_proofs(repo_root, violations)
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
