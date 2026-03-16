from __future__ import annotations

import fnmatch
import re

from _helpers import violation

SPEC_METADATA = {
    "spec_id": "GhosttyAutomationContracts",
    "proof_kind": "python",
    "claims_proven": ["ghostty_applescript_adapter_exclusive"],
    "checks_executed": ["ghostty_tokens_outside_adapter"],
    "assumptions": [],
    "supporting_artifacts": [
        ".verifier/specs/GhosttyAutomationContracts.py",
        "apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift",
    ],
}


REFERENCE_PATTERN = re.compile(
    r"GhosttyAXReader|bestGhosttyTabMatch|ghosttyWindowTitleMatchesSession|resolveGhosttyAXRouting|activateGhosttyWithAXRouting|AXUIElement|kAX|AXPress|AXRaise"
)
SHELL_PATTERN = re.compile(r'open -a Ghostty\.app|tell process "Ghostty"')
IN_SCOPE = [
    "apps/swift/Sources/Capacitor/**/*.swift",
    "apps/swift/Tests/**/*.swift",
    "README.md",
    ".claude/docs/terminal-activation-ux-spec.md",
    ".claude/docs/debugging-guide.md",
    ".claude/docs/gotchas.md",
    "docs/PRE_RELEASE_CHECKLIST.md",
    "docs/ARCHITECTURE.md",
]
EXCLUDED = {"apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift"}


def matches(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


def verify(facts):
    violations = []
    for module in facts.get("modules", []):
        path = module["path"]
        if path in EXCLUDED or not matches(path, IN_SCOPE):
            continue

        reference_hit = next(
            (entry for entry in module.get("references", []) if REFERENCE_PATTERN.search(str(entry.get("value", "")))),
            None,
        )
        shell_hit = next(
            (
                entry
                for entry in module.get("shell_command_literals", [])
                if SHELL_PATTERN.search(str(entry.get("value", "")))
            ),
            None,
        )
        if reference_hit or shell_hit:
            hit = reference_hit or shell_hit
            violations.append(
                violation(
                    "ghostty_applescript_adapter_exclusive",
                    "Ghostty AppleScript escaped the dedicated adapter boundary",
                    f"{path} reintroduced Ghostty AX or legacy launch tokens outside GhosttyAutomationClient.",
                    path=path,
                    line=hit.get("line"),
                    fix="Keep Ghostty AX and launch tokens inside GhosttyAutomationClient or delete the legacy path.",
                )
            )
    return violations
