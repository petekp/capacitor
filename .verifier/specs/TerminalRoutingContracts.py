from __future__ import annotations

import re
from pathlib import Path

from _helpers import violation

SPEC_METADATA = {
    "spec_id": "TerminalRoutingContracts",
    "proof_kind": "python",
    "claims_proven": ["no_terminal_switch_cases_inside_launcher"],
    "checks_executed": ["launcher_terminal_switch_absence"],
    "assumptions": [],
    "supporting_artifacts": [
        ".verifier/specs/TerminalRoutingContracts.py",
        "apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift",
    ],
}


def verify(facts):
    del facts

    repo_root = Path(__file__).resolve().parents[2]
    launcher_source = (
        repo_root / "apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift"
    ).read_text()

    if re.search(r"case \.ghostty|case \.iTerm|case \.terminal", launcher_source) is None:
        return []

    return [
        violation(
            "no_terminal_switch_cases_inside_launcher",
            "TerminalLauncher reintroduced per-terminal switch branches",
            "TerminalLauncher should delegate terminal-specific branching to the routing policy and terminal drivers instead of embedding direct .ghostty/.iTerm/.terminal switches.",
            path="apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift",
            fix="Move the per-terminal branch back behind ActivationPolicy or TerminalDrivers.",
        )
    ]
