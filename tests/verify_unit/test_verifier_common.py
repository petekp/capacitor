from __future__ import annotations

import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/verify"))

from verifier_common import Violation, build_layer_payload, recursive_glob_match  # noqa: E402


class VerifierCommonTests(unittest.TestCase):
    def test_recursive_glob_match_covers_nested_paths(self) -> None:
        self.assertTrue(
            recursive_glob_match(
                "apps/swift/Sources/Capacitor/Models/BadLauncher.swift",
                "apps/swift/Sources/**/*.swift",
            )
        )

    def test_build_layer_payload_counts_errors_and_warnings_separately(self) -> None:
        payload = build_layer_payload(
            violations=[
                Violation(
                    layer="3",
                    rule="warning_rule",
                    path="foo.swift",
                    line=1,
                    message="warning",
                    diagnosis="warning",
                    severity="warning",
                ),
                Violation(
                    layer="1",
                    rule="error_rule",
                    path="bar.swift",
                    line=2,
                    message="error",
                    diagnosis="error",
                ),
            ]
        )

        self.assertEqual(payload["status"], "violated")
        self.assertEqual(payload["error_count"], 1)
        self.assertEqual(payload["warning_count"], 1)
        self.assertEqual(payload["violation_count"], 1)


if __name__ == "__main__":
    unittest.main()
