#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import pathlib
import re
import subprocess
import sys
from typing import Any

from verifier_common import (
    Violation,
    build_error_payload,
    build_layer_payload,
    ensure_python,
    load_json,
    load_yaml,
    write_json_atomic,
)


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
        raise RuntimeError(f"Unable to load behavioral spec {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_contracts(specs_dir: pathlib.Path) -> list[dict[str, Any]]:
    contracts: list[dict[str, Any]] = []
    for spec_path in sorted(specs_dir.glob("*.py")):
        if spec_path.name.startswith("_"):
            continue
        module = load_module(spec_path)
        if not hasattr(module, "contracts"):
            raise RuntimeError(f"Behavioral spec {spec_path.name} must define contracts().")
        declared = module.contracts()
        if not isinstance(declared, list):
            raise RuntimeError(f"Behavioral spec {spec_path.name} contracts() must return a list.")
        contracts.extend(declared)
    return contracts


def load_proof_registry(specs_dir: pathlib.Path) -> dict[str, Any]:
    registry_path = specs_dir / "proof_registry.yaml"
    if not registry_path.exists():
        raise RuntimeError(f"Behavioral proof registry is missing: {registry_path}")
    return load_yaml(registry_path)


def validate_contract_descriptor(contract: dict[str, Any]) -> None:
    if not isinstance(contract.get("rule"), str) or not contract["rule"]:
        raise ValueError(f"Invalid behavioral contract rule: {contract}")
    proofs = contract.get("proofs")
    if not isinstance(proofs, list) or not proofs:
        raise ValueError(f"Behavioral contract {contract['rule']} must declare at least one proof.")
    tla_specs = contract.get("tla_specs", [])
    if not isinstance(tla_specs, list):
        raise ValueError(f"Behavioral contract {contract['rule']} tla_specs must be a list.")


def validate_proof_registry_entry(proof_id: str, proof: dict[str, Any]) -> None:
    required = {"language", "path", "symbol", "command"}
    missing = sorted(required - set(proof.keys()))
    if missing:
        raise ValueError(f"Behavioral proof {proof_id} is missing required keys: {', '.join(missing)}.")
    if not isinstance(proof["command"], list) or not proof["command"]:
        raise ValueError(f"Behavioral proof {proof_id} must declare a non-empty command array.")


def code_symbol_present(language: str, symbol: str, source: str) -> bool:
    escaped = re.escape(symbol)
    if language == "rust":
        pattern = re.compile(rf"^\s*(?:#\[[^\n]+\]\s*\n\s*)*(?:async\s+)?fn\s+{escaped}\s*\(", re.MULTILINE)
    elif language == "swift":
        pattern = re.compile(rf"^\s*func\s+{escaped}\s*\(", re.MULTILINE)
    elif language == "python":
        pattern = re.compile(rf"^\s*(?:async\s+def|def)\s+{escaped}\s*\(", re.MULTILINE)
    else:
        raise ValueError(f"Unsupported behavioral proof language: {language}")
    return pattern.search(source) is not None


def missing_artifact_violation(contract_rule: str, proof_id: str, path: str, diagnosis: str) -> Violation:
    return Violation(
        layer="2",
        rule=contract_rule,
        path=path,
        line=None,
        message="Behavioral proof artifact is missing or misbound",
        diagnosis=f"{proof_id}: {diagnosis}",
        fix="Restore the named proof artifact or update the proof registry intentionally.",
    )


def command_failure_violation(contract_rule: str, proof_id: str, path: str, command: list[str], output: str) -> Violation:
    compact_output = re.sub(r"\s+", " ", output).strip()
    diagnosis = f"{proof_id} failed while running {' '.join(command)}."
    if compact_output:
        diagnosis = f"{diagnosis} Output: {compact_output}"
    return Violation(
        layer="2",
        rule=contract_rule,
        path=path,
        line=None,
        message="Behavioral executable proof failed",
        diagnosis=diagnosis,
        fix="Fix the underlying regression or update the proof binding intentionally.",
    )


def tla_failure_violation(contract_rule: str, spec_id: str, path: str, output: str) -> Violation:
    compact_output = re.sub(r"\s+", " ", output).strip()
    diagnosis = f"Supplemental TLA spec {spec_id} failed."
    if compact_output:
        diagnosis = f"{diagnosis} Output: {compact_output}"
    return Violation(
        layer="2",
        rule=contract_rule,
        path=path,
        line=None,
        message="Supplemental TLA+ proof failed",
        diagnosis=diagnosis,
        fix="Inspect the counterexample and restore the paired implementation behavior.",
    )


def run_command(command: list[str], repo_root: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )


def verify_contract(
    contract: dict[str, Any],
    registry: dict[str, Any],
    repo_root: pathlib.Path,
    facts: dict[str, Any],
) -> list[Violation]:
    del facts

    proofs = registry.get("proofs", {})
    tla_specs = registry.get("tla_specs", {})
    violations: list[Violation] = []

    contract_rule = contract["rule"]
    for proof_id in contract["proofs"]:
        if proof_id not in proofs:
            raise ValueError(f"Behavioral contract {contract_rule} references missing proof id {proof_id}.")
        proof = proofs[proof_id]
        validate_proof_registry_entry(proof_id, proof)

        proof_path = repo_root / proof["path"]
        if not proof_path.exists():
            violations.append(
                missing_artifact_violation(contract_rule, proof_id, proof["path"], "proof path does not exist")
            )
            continue

        source = proof_path.read_text()
        if not code_symbol_present(proof["language"], proof["symbol"], source):
            violations.append(
                missing_artifact_violation(
                    contract_rule,
                    proof_id,
                    proof["path"],
                    f"symbol {proof['symbol']} is not defined in executable code",
                )
            )
            continue

        try:
            completed = run_command([str(part) for part in proof["command"]], repo_root)
        except FileNotFoundError as error:
            raise RuntimeError(f"Unable to execute behavioral proof {proof_id}: {error}") from error

        if completed.returncode != 0:
            violations.append(
                command_failure_violation(
                    contract_rule,
                    proof_id,
                    proof["path"],
                    [str(part) for part in proof["command"]],
                    completed.stdout or completed.stderr,
                )
            )

    for spec_id in contract.get("tla_specs", []):
        if spec_id not in tla_specs:
            raise ValueError(f"Behavioral contract {contract_rule} references missing TLA spec {spec_id}.")
        spec_meta = tla_specs[spec_id]
        paired_proofs = spec_meta.get("paired_proofs")
        implementation_paths = spec_meta.get("implementation_paths")
        if not paired_proofs or not implementation_paths:
            raise ValueError(
                f"Supplemental TLA spec {spec_id} must declare implementation_paths and paired_proofs."
            )
        if not set(contract["proofs"]).issubset(set(paired_proofs)):
            raise ValueError(
                f"Supplemental TLA spec {spec_id} is not paired with all proofs required by {contract_rule}."
            )

        spec_path = repo_root / ".verifier/specs" / spec_meta["spec"]
        if not spec_path.exists():
            raise ValueError(f"Supplemental TLA spec file is missing: {spec_path}")

        completed = run_command(
            [
                str(repo_root / "scripts/verify/run-apalache.sh"),
                "--repo-root",
                str(repo_root),
                "--facts",
                str(repo_root / ".verifier/facts/current.json"),
                "--spec",
                str(spec_path),
            ],
            repo_root,
        )
        if completed.returncode != 0:
            violations.append(
                tla_failure_violation(
                    contract_rule,
                    spec_id,
                    str(spec_path.relative_to(repo_root)),
                    completed.stdout or completed.stderr,
                )
            )

    return violations


def main() -> None:
    ensure_python()
    args = parse_args()
    repo_root = pathlib.Path(args.repo_root).resolve()
    specs_dir = pathlib.Path(args.specs_dir)
    out_path = pathlib.Path(args.out)

    try:
        if str(specs_dir.resolve()) not in sys.path:
            sys.path.insert(0, str(specs_dir.resolve()))
        facts = load_json(pathlib.Path(args.facts), default={})
        registry = load_proof_registry(specs_dir)
        contracts = load_contracts(specs_dir)
        for contract in contracts:
            validate_contract_descriptor(contract)

        violations: list[Violation] = []
        for contract in contracts:
            violations.extend(verify_contract(contract, registry, repo_root, facts))

        payload = build_layer_payload(violations=violations)
        write_json_atomic(out_path, payload)
        raise SystemExit(0 if payload["passed"] else 1)
    except Exception as error:
        payload = build_error_payload(str(error))
        write_json_atomic(out_path, payload)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
