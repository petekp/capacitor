#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import pathlib
import subprocess
import sys
from typing import Any

from verifier_common import Violation, ensure_python, load_json, utc_now, write_json


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run behavioral verifier layers")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--facts", required=True)
    parser.add_argument("--specs-dir", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--paths-file")
    return parser.parse_args()


def load_module(path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load spec {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def python_spec_violations(spec_path: pathlib.Path, facts: dict[str, Any]) -> list[Violation]:
    module = load_module(spec_path)
    violations = []
    for payload in module.verify(facts):
        violations.append(
            Violation(
                layer="2",
                rule=payload["rule"],
                path=payload.get("path"),
                line=payload.get("line"),
                message=payload["message"],
                diagnosis=payload["diagnosis"],
                fix=payload.get("fix"),
                severity=payload.get("severity", "error"),
            )
        )
    return violations


def tla_spec_violations(repo_root: pathlib.Path, facts_path: pathlib.Path, spec_path: pathlib.Path) -> list[Violation]:
    runner = repo_root / "scripts/verify/run-apalache.sh"
    completed = subprocess.run(
        [
            str(runner),
            "--repo-root",
            str(repo_root),
            "--facts",
            str(facts_path),
            "--spec",
            str(spec_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode == 0:
        return []
    message = completed.stdout.strip() or completed.stderr.strip() or "Apalache check failed"
    return [
        Violation(
            layer="2",
            rule=spec_path.stem,
            path=str(spec_path.relative_to(repo_root)),
            line=None,
            message="Behavioral TLA+ spec failed",
            diagnosis=message,
            fix="Inspect the counterexample trace and update the implementation or spec intentionally.",
        )
    ]


def main() -> None:
    ensure_python()
    args = parse_args()
    repo_root = pathlib.Path(args.repo_root).resolve()
    specs_dir = pathlib.Path(args.specs_dir)
    facts_path = pathlib.Path(args.facts)
    facts = load_json(facts_path, default={})
    if str(specs_dir.resolve()) not in sys.path:
        sys.path.insert(0, str(specs_dir.resolve()))

    violations: list[Violation] = []
    for spec_path in sorted(specs_dir.glob("*.py")):
        if spec_path.name.startswith("_"):
            continue
        violations.extend(python_spec_violations(spec_path, facts))
    for spec_path in sorted(specs_dir.glob("*.tla")):
        violations.extend(tla_spec_violations(repo_root, facts_path, spec_path))

    payload = {
        "generated_at": utc_now(),
        "passed": not violations,
        "violations": [violation.as_dict() for violation in violations],
    }
    write_json(pathlib.Path(args.out), payload)
    raise SystemExit(0 if payload["passed"] else 1)


if __name__ == "__main__":
    main()
