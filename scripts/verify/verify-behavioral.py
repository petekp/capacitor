#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import pathlib
import subprocess
import sys
from typing import Any

from verifier_common import Violation, ensure_python, load_json, load_yaml, utc_now, write_json


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


def display_path(path: pathlib.Path, repo_root: pathlib.Path) -> str:
    try:
        return str(path.resolve().relative_to(repo_root.resolve()))
    except ValueError:
        return str(path)


def proof_registry_violations(repo_root: pathlib.Path, specs_dir: pathlib.Path) -> list[Violation]:
    registry_path = specs_dir / "proof_registry.yaml"
    if not registry_path.exists():
        return []

    payload = load_yaml(registry_path) or {}
    proofs = payload.get("proofs", [])
    violations: list[Violation] = []
    registry_display_path = display_path(registry_path, repo_root)

    for proof in proofs:
        if str(proof.get("layer", "2")) != "2":
            continue

        command = proof.get("command")
        if not isinstance(command, list) or not command:
            violations.append(
                Violation(
                    layer="2",
                    rule=str(proof.get("name", "behavioral_proof_registry_entry")),
                    path=proof.get("path", registry_display_path),
                    line=None,
                    message="Behavioral proof registry entry is invalid",
                    diagnosis="Each behavioral proof must declare a non-empty command list.",
                    fix="Update .verifier/specs/proof_registry.yaml so every proof defines command as a YAML list of argv tokens.",
                )
            )
            continue

        cwd = repo_root / proof["cwd"] if proof.get("cwd") else repo_root
        try:
            completed = subprocess.run(
                [str(token) for token in command],
                cwd=cwd,
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as error:
            violations.append(
                Violation(
                    layer="2",
                    rule=str(proof.get("name", "behavioral_proof_execution")),
                    path=proof.get("path", registry_display_path),
                    line=None,
                    message=str(proof.get("message", "Behavioral proof failed to launch")),
                    diagnosis=str(error),
                    fix=proof.get("fix"),
                )
            )
            continue

        if completed.returncode == 0:
            continue

        output = "\n".join(
            chunk.strip()
            for chunk in (completed.stdout, completed.stderr)
            if chunk and chunk.strip()
        )
        if len(output) > 4000:
            output = output[-4000:]

        diagnosis = str(
            proof.get(
                "diagnosis",
                "Behavioral proof command returned a non-zero exit status.",
            )
        )
        if output:
            diagnosis = f"{diagnosis}\n\n{output}"

        violations.append(
            Violation(
                layer="2",
                rule=str(proof.get("name", "behavioral_proof")),
                path=proof.get("path", registry_display_path),
                line=None,
                message=str(proof.get("message", "Behavioral proof failed")),
                diagnosis=diagnosis,
                fix=proof.get("fix"),
                severity=str(proof.get("severity", "error")),
            )
        )

    return violations


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
    violations.extend(proof_registry_violations(repo_root, specs_dir))

    payload = {
        "generated_at": utc_now(),
        "passed": not violations,
        "violations": [violation.as_dict() for violation in violations],
    }
    write_json(pathlib.Path(args.out), payload)
    raise SystemExit(0 if payload["passed"] else 1)


if __name__ == "__main__":
    main()
