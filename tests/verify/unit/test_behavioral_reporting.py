from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPTS_DIR = ROOT / "scripts/verify"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
SPECS_DIR = ROOT / ".verifier/specs"
if str(SPECS_DIR) not in sys.path:
    sys.path.insert(0, str(SPECS_DIR))
for site_packages in sorted((ROOT / ".verifier/.venv/lib").glob("python*/site-packages")):
    if str(site_packages) not in sys.path:
        sys.path.insert(0, str(site_packages))


def load_module(name: str, relative_path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module {relative_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BehavioralReportingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.behavioral = load_module("verify_behavioral", "scripts/verify/verify-behavioral.py")

    def test_python_specs_declare_metadata(self) -> None:
        for spec_path in sorted((ROOT / ".verifier/specs").glob("*.py")):
            if spec_path.name.startswith("_"):
                continue
            module = load_module(spec_path.stem, str(spec_path.relative_to(ROOT)))
            with self.subTest(spec=spec_path.stem):
                metadata = module.SPEC_METADATA
                self.assertEqual(spec_path.stem, metadata["spec_id"])
                self.assertTrue(metadata["claims_proven"])
                self.assertTrue(metadata["checks_executed"])
                self.assertEqual("python", metadata["proof_kind"])

    def test_python_spec_result_is_structured(self) -> None:
        spec_path = ROOT / ".verifier/specs/HookSetupContracts.py"
        result = self.behavioral.python_spec_result(spec_path, facts={})

        self.assertEqual("HookSetupContracts", result["spec_id"])
        self.assertIn("claims_proven", result)
        self.assertIn("checks_executed", result)
        self.assertIn("supporting_artifacts", result)
        self.assertIn("violations", result)
        self.assertIn("passed", result)


if __name__ == "__main__":
    unittest.main()
