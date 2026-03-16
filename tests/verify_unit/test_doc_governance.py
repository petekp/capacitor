from __future__ import annotations

import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/verify"))

from doc_governance import validate_architecture_packet_content  # noqa: E402


class DocGovernanceTests(unittest.TestCase):
    def test_packet_validation_rejects_recent_deltas_in_canonical_section(self) -> None:
        violations = validate_architecture_packet_content(
            """
# Architecture Packet

> Doc role: `generated-aid`
> Status: Generated aid only. Do not treat this as the current architecture spec.

## Canonical Read Path

1. `.claude/docs/architecture-primer.md`
2. `docs/ARCHITECTURE.md`
3. `AGENT_CHANGELOG.md`

## Recent Deltas

- `AGENT_CHANGELOG.md`
""".strip(),
            canonical_docs=[
                ".claude/docs/architecture-primer.md",
                "docs/ARCHITECTURE.md",
                "docs/architecture-decisions/004-dedicated-local-runtime-service.md",
            ],
            recent_deltas_doc="AGENT_CHANGELOG.md",
        )

        self.assertIn("architecture_packet_canonical_path_drift", {violation.rule for violation in violations})


if __name__ == "__main__":
    unittest.main()
