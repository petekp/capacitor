from __future__ import annotations

import copy
import hashlib
import importlib.metadata
import json
import pathlib
import subprocess
import sys
from typing import Any, Iterable

from verifier_common import read_text, sha256_text, write_json


def payload_hash(payload: Any) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def git_commit(repo_root: pathlib.Path) -> str | None:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        return None
    return completed.stdout.strip() or None


def git_dirty(repo_root: pathlib.Path) -> bool:
    completed = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        return True
    return bool(completed.stdout.strip())


def safe_version(distribution: str) -> str | None:
    try:
        return importlib.metadata.version(distribution)
    except importlib.metadata.PackageNotFoundError:
        return None


def build_tool_versions() -> dict[str, Any]:
    return {
        "python": ".".join(str(part) for part in sys.version_info[:3]),
        "pyyaml": safe_version("PyYAML"),
        "z3-solver": safe_version("z3-solver"),
        "tree-sitter": safe_version("tree-sitter"),
        "tree-sitter-language-pack": safe_version("tree-sitter-language-pack"),
    }


def build_config_hashes(
    *,
    structural_config: pathlib.Path,
    canonical_claims: pathlib.Path,
    ledger: pathlib.Path,
    specs_dir: pathlib.Path,
    bootstrap_manifest: pathlib.Path | None = None,
) -> dict[str, Any]:
    config_hashes: dict[str, Any] = {
        "structural": sha256_text(read_text(structural_config)) if structural_config.exists() else None,
        "canonical_claims": sha256_text(read_text(canonical_claims)) if canonical_claims.exists() else None,
        "ledger": sha256_text(read_text(ledger)) if ledger.exists() else None,
        "specs": {},
    }
    for path in sorted(specs_dir.glob("*")):
        if path.is_file():
            config_hashes["specs"][path.name] = sha256_text(read_text(path))
    if bootstrap_manifest is not None and bootstrap_manifest.exists():
        config_hashes["bootstrap_manifest"] = sha256_text(read_text(bootstrap_manifest))
    return config_hashes


def write_manifest(path: pathlib.Path, manifest: dict[str, Any]) -> None:
    write_json(path, manifest)


def build_base_run_manifest(
    *,
    repo_root: str,
    started_at: str,
    selected_paths: list[str],
    config_hashes: dict[str, Any],
    tool_versions: dict[str, Any],
    git_commit: str | None,
    git_dirty: bool,
) -> dict[str, Any]:
    selected_paths_hash = payload_hash(sorted(selected_paths))
    seed = {
        "repo_root": repo_root,
        "started_at": started_at,
        "selected_paths_hash": selected_paths_hash,
        "config_hashes": config_hashes,
        "git_commit": git_commit,
        "git_dirty": git_dirty,
    }
    run_id = payload_hash(seed)[:16]
    return {
        "run_id": run_id,
        "repo_root": repo_root,
        "git_commit": git_commit,
        "git_dirty": git_dirty,
        "selected_paths_hash": selected_paths_hash,
        "facts_hash": None,
        "config_hashes": copy.deepcopy(config_hashes),
        "tool_versions": copy.deepcopy(tool_versions),
        "started_at": started_at,
    }


def attach_run_manifest(
    payload: dict[str, Any],
    base_manifest: dict[str, Any],
    *,
    facts_payload_keys: Iterable[str] | None = None,
) -> dict[str, Any]:
    finalized = copy.deepcopy(payload)
    manifest = copy.deepcopy(base_manifest)
    if facts_payload_keys is not None:
        facts_payload = {key: finalized[key] for key in facts_payload_keys}
        manifest["facts_hash"] = payload_hash(facts_payload)
    finalized["run_manifest"] = manifest
    return finalized


def manifest_violations(expected_manifest: dict[str, Any], actual_manifest: dict[str, Any] | None) -> list[dict[str, str]]:
    if actual_manifest is None:
        return [
            {
                "message": "Layer artifact is missing run manifest",
                "diagnosis": "Expected every verifier artifact to embed the shared run manifest, but one artifact omitted it.",
            }
        ]
    violations = []
    for key, expected_value in expected_manifest.items():
        actual_value = actual_manifest.get(key)
        if actual_value == expected_value:
            continue
        violations.append(
            {
                "message": "Layer artifact run manifest drifted from the shared verifier run",
                "diagnosis": f"Run manifest field {key} expected {expected_value!r} but found {actual_value!r}.",
            }
        )
    return violations


def aggregate_run_report(
    *,
    repo_root: str,
    layers: list[str],
    layer_results: dict[str, dict[str, Any]],
    expected_manifest: dict[str, Any],
    generated_at: str,
) -> dict[str, Any]:
    manifest_errors = []
    passed = True
    for layer in layers:
        payload = layer_results.get(layer, {"passed": True, "violations": []})
        manifest_errors.extend(manifest_violations(expected_manifest, payload.get("run_manifest")))
        if not payload.get("passed", False):
            passed = False

    if manifest_errors:
        passed = False

    return {
        "generated_at": generated_at,
        "repo_root": repo_root,
        "layers": layers,
        "run_manifest": copy.deepcopy(expected_manifest),
        "passed": passed,
        "layer_results": layer_results,
        "manifest_violations": manifest_errors,
        "violation_count": sum(len(layer_results[layer].get("violations", [])) for layer in layer_results) + len(manifest_errors),
    }
