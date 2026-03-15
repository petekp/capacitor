#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
import re
from typing import Any

from verifier_common import (
    category_for,
    detect_language,
    ensure_python,
    find_git_changed_files,
    grep_lines,
    list_repo_files,
    load_json,
    module_name_for,
    read_text,
    relpath,
    sha256_text,
    tree_sitter_string_literals,
    unique_entries,
    utc_now,
    write_json,
)


DOC_CLAIM_PATTERN = re.compile(
    r"\b(owner|owns|owned by|boundary|single source of truth|canonical|authoritative|must remain|only)\b",
    re.IGNORECASE,
)
HTTP_ROUTE_PATTERN = re.compile(r"(/health|/runtime/[A-Za-z0-9/_-]+)")
SHELL_COMMAND_PATTERN = re.compile(
    r"(tmux\s+[A-Za-z0-9_-]+|open -a Ghostty\.app|tell process \"Ghostty\"|tell application \"Ghostty\"|curl\s+[^\"']*/runtime/[A-Za-z0-9/_-]+)"
)
EXTRACTOR_VERSION = 2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract formal verification facts")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--out", required=True)
    parser.add_argument("--paths-file")
    parser.add_argument("--changed-only", action="store_true")
    return parser.parse_args()


def load_selected_paths(args: argparse.Namespace, repo_root: pathlib.Path) -> set[str] | None:
    if args.paths_file:
        path = pathlib.Path(args.paths_file)
        if not path.exists():
            return set()
        return {line.strip() for line in path.read_text().splitlines() if line.strip()}
    if args.changed_only:
        return set(find_git_changed_files(repo_root))
    return None


def rust_imports(content: str) -> list[dict[str, Any]]:
    return grep_lines(r"^\s*use\s+([^;]+);", content, flags=re.MULTILINE)


def swift_imports(content: str) -> list[dict[str, Any]]:
    return grep_lines(r"^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)", content, flags=re.MULTILINE)


def rust_calls(content: str) -> list[dict[str, Any]]:
    raw = grep_lines(r"\b([A-Za-z_][A-Za-z0-9_:]*)\s*\(", content)
    return [entry for entry in raw if entry["value"] not in {"if", "for", "while", "match"}]


def swift_calls(content: str) -> list[dict[str, Any]]:
    raw = grep_lines(r"\b([A-Za-z_][A-Za-z0-9_\.]*)\s*\(", content)
    return [
        entry
        for entry in raw
        if entry["value"] not in {"if", "for", "while", "switch", "return", "guard", "func", "init"}
    ]


def rust_implements(content: str) -> list[dict[str, Any]]:
    return grep_lines(r"impl(?:<[^>]+>)?\s+([A-Za-z_][A-Za-z0-9_:<>]+)\s+for\s+[A-Za-z_][A-Za-z0-9_:<>]+", content)


def swift_implements(content: str) -> list[dict[str, Any]]:
    matches = []
    decl_regex = re.compile(r"^\s*(?:struct|class|enum|actor)\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*([^{]+)\{?", re.MULTILINE)
    for match in decl_regex.finditer(content):
        line = content[: match.start()].count("\n") + 1
        protocols = [item.strip() for item in match.group(1).split(",") if item.strip()]
        for protocol in protocols:
            matches.append({"value": protocol, "line": line})
    return matches


def definitions(language: str, content: str) -> list[dict[str, Any]]:
    if language == "rust":
        return unique_entries(
            grep_lines(r"^\s*(?:pub\s+)?(?:struct|enum|trait|fn)\s+([A-Za-z_][A-Za-z0-9_]*)", content, flags=re.MULTILINE)
        )
    if language == "swift":
        return unique_entries(
            grep_lines(
                r"^\s*(?:final\s+)?(?:class|struct|enum|protocol|actor|func)\s+([A-Za-z_][A-Za-z0-9_]*)",
                content,
                flags=re.MULTILINE,
            )
        )
    return []


def doc_claims_for(content: str) -> list[dict[str, Any]]:
    claims = []
    in_code_block = False
    for line_number, line in enumerate(content.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("```"):
            in_code_block = not in_code_block
            continue
        if in_code_block:
            continue
        if not stripped or stripped.startswith("#") or stripped.startswith("|"):
            continue
        if len(stripped) < 24:
            continue
        if DOC_CLAIM_PATTERN.search(line):
            claims.append({"value": stripped, "line": line_number})
    return unique_entries(claims)


def http_routes_for(content: str) -> list[dict[str, Any]]:
    matches = []
    for line_number, line in enumerate(content.splitlines(), start=1):
        if ".capacitor/runtime" in line:
            continue
        for match in HTTP_ROUTE_PATTERN.finditer(line):
            value = match.group(1)
            if value == "/health" or value.startswith("/runtime/"):
                matches.append({"value": value, "line": line_number})
    return unique_entries(matches)


def shell_command_literals_for(content: str, string_literals: list[dict[str, Any]]) -> list[dict[str, Any]]:
    matches = []
    for line_number, line in enumerate(content.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("#") or stripped.startswith("*"):
            continue
        for match in SHELL_COMMAND_PATTERN.finditer(line):
            matches.append({"value": match.group(1).strip(), "line": line_number})
    for literal in string_literals:
        value = literal["value"]
        if SHELL_COMMAND_PATTERN.search(value):
            matches.append({"value": value.strip(), "line": literal["line"]})
    return unique_entries(matches)


def references_for(content: str) -> list[dict[str, Any]]:
    return unique_entries(grep_lines(r"\b([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)\b", content))


def extract_module(path: pathlib.Path, repo_root: pathlib.Path) -> dict[str, Any]:
    content = read_text(path)
    language = detect_language(path, content)
    relative_path = relpath(path, repo_root)
    string_literals = []
    if language in {"rust", "swift"}:
        string_literals = tree_sitter_string_literals(language, content)

    imports = []
    calls = []
    implements = []
    if language == "rust":
        imports = rust_imports(content)
        calls = rust_calls(content)
        implements = rust_implements(content)
    elif language == "swift":
        imports = swift_imports(content)
        calls = swift_calls(content)
        implements = swift_implements(content)

    module = {
        "path": relative_path,
        "name": module_name_for(path),
        "language": language,
        "category": category_for(relative_path),
        "content_hash": sha256_text(content),
        "line_count": len(content.splitlines()),
        "imports": unique_entries(imports),
        "calls": unique_entries(calls),
        "implements": unique_entries(implements),
        "definitions": definitions(language, content),
        "references": references_for(content),
        "string_literals": unique_entries(string_literals),
        "http_routes": http_routes_for(content),
        "shell_command_literals": shell_command_literals_for(content, string_literals),
        "doc_claims": doc_claims_for(content) if language in {"markdown", "yaml", "toml"} else [],
    }
    return module


def extract_constants(repo_root: pathlib.Path) -> dict[str, Any]:
    constants: dict[str, Any] = {}

    hook_server = repo_root / "apps/swift/Sources/Capacitor/Models/HookServerManager.swift"
    if hook_server.exists():
        content = read_text(hook_server)
        match = re.search(r"maxConsecutiveFailures\s*=\s*(\d+)", content)
        if match:
            constants["hook_server_max_consecutive_failures"] = int(match.group(1))

    session_manager = repo_root / "apps/swift/Sources/Capacitor/Models/SessionStateManager.swift"
    if session_manager.exists():
        content = read_text(session_manager)
        for key, pattern in {
            "session_empty_snapshot_commit_threshold": r"emptySnapshotCommitThreshold\s*=\s*(\d+)",
            "session_idle_commit_threshold": r"idleCommitThreshold\s*=\s*(\d+)",
        }.items():
            match = re.search(pattern, content)
            if match:
                constants[key] = int(match.group(1))

    routing_fields = []
    runtime_client = repo_root / "apps/swift/Sources/Capacitor/Models/RuntimeClient.swift"
    if runtime_client.exists():
        content = read_text(runtime_client)
        for field in re.findall(r'case\s+([A-Za-z0-9_]+)\s*=\s*"([A-Za-z0-9_]+)"', content):
            routing_fields.append({"symbol": field[0], "wire": field[1]})
    if routing_fields:
        constants["runtime_client_coding_keys"] = routing_fields

    return constants


def extract_replay_cases(repo_root: pathlib.Path) -> list[dict[str, Any]]:
    fixtures_dir = repo_root / "core/capacitor-core/tests/fixtures/replay"
    if not fixtures_dir.exists():
        return []
    cases: list[dict[str, Any]] = []
    for path in sorted(fixtures_dir.glob("*.json")):
        payload = json.loads(path.read_text())
        payload["fixture_path"] = relpath(path, repo_root)
        cases.append(payload)
    return cases


def main() -> None:
    ensure_python()
    args = parse_args()
    repo_root = pathlib.Path(args.repo_root).resolve()
    out_path = pathlib.Path(args.out)
    selected_paths = load_selected_paths(args, repo_root)

    previous = load_json(out_path, default={}) if out_path.exists() else {}
    if previous.get("extractor_version") != EXTRACTOR_VERSION:
        previous = {}
    previous_modules = {module["path"]: module for module in previous.get("modules", [])}

    files = list_repo_files(repo_root)
    modules: list[dict[str, Any]] = []
    for path in files:
        relative_path = relpath(path, repo_root)
        content = read_text(path)
        content_hash = sha256_text(content)
        cached = previous_modules.get(relative_path)
        if cached and cached.get("content_hash") == content_hash:
            modules.append(cached)
            continue
        modules.append(extract_module(path, repo_root))

    payload = {
        "generated_at": utc_now(),
        "extractor_version": EXTRACTOR_VERSION,
        "repo_root": str(repo_root),
        "selected_paths": sorted(selected_paths) if selected_paths else None,
        "modules": sorted(modules, key=lambda item: item["path"]),
        "constants": extract_constants(repo_root),
        "replay_cases": extract_replay_cases(repo_root),
    }
    write_json(out_path, payload)


if __name__ == "__main__":
    main()
EXTRACTOR_VERSION = 2
