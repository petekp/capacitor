from __future__ import annotations

import re
from pathlib import Path

from _helpers import violation

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


def verify(facts):
    del facts

    repo_root = Path(__file__).resolve().parents[2]
    runtime_setup_source = (
        repo_root / "core/capacitor-core/src/runtime_setup.rs"
    ).read_text()

    violations = []

    if "resolve_symlink_target" not in runtime_setup_source:
        violations.append(
            violation(
                "hook_setup_symlink_resolution_helper_missing",
                "Hook setup symlink resolution helper is missing",
                "runtime_setup should centralize symlink target resolution so status checks, binary verification, and reinstall idempotence all agree on what the hook binary points to.",
                path="core/capacitor-core/src/runtime_setup.rs",
                fix="Restore resolve_symlink_target or an equivalent shared helper intentionally.",
            )
        )

    if "remove_managed_inner_hooks" not in runtime_setup_source:
        violations.append(
            violation(
                "hook_setup_managed_inner_hook_removal_helper_missing",
                "Hook setup no longer centralizes managed inner-hook removal",
                "runtime_setup should strip only Capacitor-managed inner hooks from mixed hook entries so unrelated user hooks survive uninstall.",
                path="core/capacitor-core/src/runtime_setup.rs",
                fix="Restore remove_managed_inner_hooks or an equivalent shared helper intentionally.",
            )
        )

    required_call_sites = {
        r"fn check_hooks_status\(&self\) -> HookStatus\s*\{[\s\S]*resolve_symlink_target\(&binary_path\)":
            (
                "hook_status_relative_symlink_gap",
                "SetupChecker status no longer resolves hook symlinks through the shared helper",
                "check_hooks_status should resolve relative symlink targets before deciding the hook binary is broken.",
                "Route hook status symlink checks through resolve_symlink_target so setup health agrees on hook ownership.",
            ),
        r"fn verify_hook_binary\(&self\) -> Result<\(\), String>\s*\{[\s\S]*resolve_symlink_target\(&binary_path\)":
            (
                "hook_binary_verify_relative_symlink_gap",
                "Hook binary verification no longer resolves hook symlinks through the shared helper",
                "verify_hook_binary should treat valid relative symlink installs as healthy instead of misclassifying them as broken.",
                "Route hook binary verification through resolve_symlink_target so valid relative symlinks stay healthy.",
            ),
        r"pub fn install_binary_from_path\([\s\S]*resolve_symlink_target\(&dest_path\)":
            (
                "hook_binary_install_idempotence_gap",
                "Hook binary reinstall path no longer resolves existing symlinks through the shared helper",
                "install_binary_from_path should recognize relative symlinks that already point at the desired binary so installs stay idempotent.",
                "Route install_binary_from_path through resolve_symlink_target so reinstall checks stay idempotent for relative symlinks.",
            ),
        r"pub fn remove_hooks\(&self\) -> Result<InstallResult, HudFfiError>\s*\{[\s\S]*remove_managed_inner_hooks\(hook_config\)":
            (
                "hook_settings_mixed_entry_strip_gap",
                "Hook removal no longer strips managed inner hooks through the shared helper",
                "remove_hooks should remove only Capacitor-managed inner hooks from a mixed entry instead of deleting unrelated user hooks along with them.",
                "Route remove_hooks through remove_managed_inner_hooks so mixed entries keep user-owned hooks.",
            ),
        r"pub fn remove_hooks\(&self\) -> Result<InstallResult, HudFfiError>\s*\{[\s\S]*hook_config_has_remaining_hooks\(hook_config\)":
            (
                "hook_settings_empty_entry_cleanup_gap",
                "Hook removal no longer cleans up emptied hook entries after stripping managed hooks",
                "remove_hooks should drop only those hook configs left empty after managed hooks are stripped so uninstall stays precise and tidy.",
                "Keep the post-strip cleanup guard so remove_hooks drops only empty hook configs.",
            ),
    }

    for pattern, (rule, message, diagnosis, fix) in required_call_sites.items():
        if re.search(pattern, runtime_setup_source) is None:
            violations.append(
                violation(
                    rule,
                    message,
                    diagnosis,
                    path="core/capacitor-core/src/runtime_setup.rs",
                    fix=fix,
                )
            )

    required_tests = {
        "test_verify_hook_binary_accepts_relative_symlink_target":
            (
                "hook_setup_relative_symlink_test_gap",
                "Hook setup relative-symlink proof is incomplete",
                "verify_hook_binary should keep accepting valid relative symlink installs.",
                "Restore the named runtime_setup regression test so relative symlink handling stays executable.",
            ),
        "test_check_hooks_status_accepts_relative_symlink_target":
            (
                "hook_setup_relative_symlink_test_gap",
                "Hook setup relative-symlink proof is incomplete",
                "check_hooks_status should keep accepting valid relative symlink installs.",
                "Restore the named runtime_setup regression test so relative symlink handling stays executable.",
            ),
        "test_install_binary_from_path_keeps_relative_symlink_to_same_target":
            (
                "hook_setup_relative_symlink_test_gap",
                "Hook setup relative-symlink proof is incomplete",
                "install_binary_from_path should keep treating a relative symlink to the same target as already correct.",
                "Restore the named runtime_setup regression test so relative symlink handling stays executable.",
            ),
        "test_remove_hooks_preserves_custom_inner_hooks_in_mixed_entry":
            (
                "hook_setup_mixed_entry_removal_test_gap",
                "Hook setup mixed-entry removal proof is incomplete",
                "remove_hooks should keep preserving user-owned inner hooks when a mixed entry also contains a Capacitor-managed hook.",
                "Restore the named runtime_setup regression test so mixed hook entry removal stays executable.",
            ),
    }

    for test_name, (rule, message, diagnosis, fix) in required_tests.items():
        if f"fn {test_name}()" not in runtime_setup_source:
            violations.append(
                violation(
                    rule,
                    message,
                    diagnosis,
                    path="core/capacitor-core/src/runtime_setup.rs",
                    fix=fix,
                )
            )

    return violations
