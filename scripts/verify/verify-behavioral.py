#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import pathlib
import subprocess
import sys
from typing import Any

from pipeline import attach_run_manifest, manifest_violations
from verifier_common import Violation, ensure_python, load_json, load_yaml, read_text, relpath, sha256_text, utc_now, write_json


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run behavioral verifier layers")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--facts", required=True)
    parser.add_argument("--specs-dir", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--paths-file")
    parser.add_argument("--canonical-claims")
    parser.add_argument("--run-manifest")
    parser.add_argument("--report-only", action="store_true")
    return parser.parse_args()


def load_module(path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load spec {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def python_spec_result(spec_path: pathlib.Path, facts: dict[str, Any], repo_root: pathlib.Path | None = None) -> dict[str, Any]:
    if repo_root is None:
        repo_root = spec_path.resolve().parents[2]
    module = load_module(spec_path)
    metadata = getattr(module, "SPEC_METADATA")

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

    return {
        "spec_id": metadata["spec_id"],
        "proof_kind": metadata["proof_kind"],
        "claims_proven": list(metadata.get("claims_proven", [])),
        "checks_executed": list(metadata.get("checks_executed", [])),
        "assumptions": list(metadata.get("assumptions", [])),
        "supporting_artifacts": list(metadata.get("supporting_artifacts", [relpath(spec_path, repo_root)])),
        "passed": not violations,
        "violations": [violation.as_dict() for violation in violations],
    }


def cfg_checks(cfg_path: pathlib.Path) -> list[str]:
    checks = []
    for line in cfg_path.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith(("INIT ", "NEXT ", "INVARIANT ")):
            checks.append(stripped)
    return checks


def apalache_version() -> str | None:
    completed = subprocess.run(
        ["apalache-mc", "version"],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        return None
    output = completed.stdout.strip() or completed.stderr.strip()
    return output.splitlines()[0] if output else None


def tla_spec_result(repo_root: pathlib.Path, facts_path: pathlib.Path, spec_path: pathlib.Path) -> dict[str, Any]:
    runner = repo_root / "scripts/verify/run-apalache.sh"
    cfg_path = spec_path.with_suffix(".cfg")
    out_dir = repo_root / ".verifier/reports/apalache" / spec_path.stem
    out_dir.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        [
            str(runner),
            "--repo-root",
            str(repo_root),
            "--facts",
            str(facts_path),
            "--spec",
            str(spec_path),
            "--out-dir",
            str(out_dir),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    violations: list[Violation] = []
    if completed.returncode != 0:
        message = completed.stdout.strip() or completed.stderr.strip() or "Apalache check failed"
        violations.append(
            Violation(
                layer="2",
                rule=spec_path.stem,
                path=str(spec_path.relative_to(repo_root)),
                line=None,
                message="Behavioral TLA+ spec failed",
                diagnosis=message,
                fix="Inspect the counterexample trace and update the implementation or spec intentionally.",
            )
        )

    return {
        "spec_id": spec_path.stem,
        "proof_kind": "tla",
        "claims_proven": [],
        "checks_executed": cfg_checks(cfg_path) if cfg_path.exists() else [],
        "assumptions": [],
        "supporting_artifacts": [str(spec_path.relative_to(repo_root)), str(cfg_path.relative_to(repo_root))],
        "spec_hash": sha256_text(read_text(spec_path)),
        "cfg_hash": sha256_text(read_text(cfg_path)) if cfg_path.exists() else None,
        "tool_version": apalache_version(),
        "counterexample_path": str(out_dir.relative_to(repo_root)) if violations else None,
        "passed": not violations,
        "violations": [violation.as_dict() for violation in violations],
    }


def main() -> None:
    ensure_python()
    args = parse_args()
    if args.paths_file:
        raise SystemExit("Layer 2 does not support path-scoped runs. Drop --changed-only or omit layer 2.")

    repo_root = pathlib.Path(args.repo_root).resolve()
    specs_dir = pathlib.Path(args.specs_dir)
    facts_path = pathlib.Path(args.facts)
    facts = load_json(facts_path, default={})
    if str(specs_dir.resolve()) not in sys.path:
        sys.path.insert(0, str(specs_dir.resolve()))

    spec_results = []
    canonical_claim_ids = set()
    if args.canonical_claims:
        claims_payload = load_yaml(pathlib.Path(args.canonical_claims))
        canonical_claim_ids = {str(claim["claim_id"]) for claim in claims_payload.get("claims", [])}
    for spec_path in sorted(specs_dir.glob("*.py")):
        if spec_path.name.startswith("_"):
            continue
        spec_result = python_spec_result(spec_path, facts, repo_root)
        unknown_claims = sorted(set(spec_result["claims_proven"]) - canonical_claim_ids) if canonical_claim_ids else []
        if unknown_claims:
            spec_result["passed"] = False
            for claim_id in unknown_claims:
                spec_result["violations"].append(
                    Violation(
                        layer="2",
                        rule="behavioral_spec_unknown_claim",
                        path=str(spec_path.relative_to(repo_root)),
                        line=None,
                        message="Behavioral spec declared an unknown canonical claim",
                        diagnosis=f"{spec_result['spec_id']} declares unknown claim {claim_id}.",
                        fix="Add the claim to .verifier/canonical-claims.yaml or correct the spec metadata.",
                    ).as_dict()
                )
        spec_results.append(spec_result)
    for spec_path in sorted(specs_dir.glob("*.tla")):
        spec_results.append(tla_spec_result(repo_root, facts_path, spec_path))

    violations = []
    expected_manifest = load_json(pathlib.Path(args.run_manifest), default={}) if args.run_manifest else None
    if expected_manifest:
        for issue in manifest_violations(expected_manifest, facts.get("run_manifest")):
            violations.append(
                Violation(
                    layer="2",
                    rule="run_manifest_drift",
                    path=None,
                    line=None,
                    message=issue["message"],
                    diagnosis=issue["diagnosis"],
                    fix="Re-run the verifier so facts and behavioral specs use the same manifest envelope.",
                )
            )
    for spec_result in spec_results:
        for payload in spec_result["violations"]:
            violations.append(
                Violation(
                    layer=payload["layer"],
                    rule=payload["rule"],
                    path=payload.get("path"),
                    line=payload.get("line"),
                    message=payload["message"],
                    diagnosis=payload["diagnosis"],
                    fix=payload.get("fix"),
                    severity=payload.get("severity", "error"),
                )
            )

    payload = {
        "generated_at": utc_now(),
        "passed": not violations,
        "spec_results": spec_results,
        "violations": [violation.as_dict() for violation in violations],
    }
    if expected_manifest:
        payload = attach_run_manifest(payload, expected_manifest)
    write_json(pathlib.Path(args.out), payload)
    if args.report_only:
        raise SystemExit(0)
    raise SystemExit(0 if payload["passed"] else 1)


if __name__ == "__main__":
    main()
