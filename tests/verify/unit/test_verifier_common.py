from __future__ import annotations

import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPTS_DIR = ROOT / "scripts/verify"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from verifier_common import matches_name_or_path


class VerifierCommonTests(unittest.TestCase):
    def test_matches_name_or_path_supports_globstar_segments(self) -> None:
        module = {
            "path": "apps/swift/Sources/Capacitor/Models/AppState.swift",
            "name": "AppState",
        }

        self.assertTrue(matches_name_or_path(module, "apps/swift/Sources/**/*.swift"))
        self.assertTrue(matches_name_or_path(module, "apps/swift/Sources/*/*/*.swift"))
        self.assertFalse(matches_name_or_path(module, "apps/swift/Tests/**/*.swift"))


if __name__ == "__main__":
    unittest.main()
