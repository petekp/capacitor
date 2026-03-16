from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Iterable

import yaml


EXCLUDED_DIRS = {
    ".git",
    ".claude/worktrees",
    ".worktrees",
    ".verifier/facts",
    ".verifier/reports",
    ".verifier/.venv",
    ".venv",
    ".playwright-mcp",
    ".serena",
    "node_modules",
    "target",
    "dist",
    "dist-guide",
    "apps/swift/.build",
    "apps/swift/.swiftpm",
}

PRODUCTION_EXTENSIONS = {
    ".rs",
    ".swift",
    ".py",
    ".sh",
    ".bash",
    ".zsh",
    ".md",
    ".yaml",
    ".yml",
    ".mjs",
    ".js",
    ".toml",
}

VALID_FACT_KINDS = {
    "call_pattern",
    "contains_regex",
    "definition",
    "doc_claim",
    "http_route",
    "identifier_ref",
    "implement",
    "import",
    "path_regex",
    "process_exec",
    "raw_text",
    "reference",
    "shell_command_literal",
    "static_http_route",
    "string_literal",
}


@dataclass
class Violation:
    layer: str
    rule: str
    path: str | None
    line: int | None
    message: str
    diagnosis: str
    fix: str | None = None
    group: str | None = None
    severity: str = "error"

    def as_dict(self) -> dict[str, Any]:
        return {
            "layer": self.layer,
            "rule": self.rule,
            "path": self.path,
            "line": self.line,
            "message": self.message,
            "diagnosis": self.diagnosis,
            "fix": self.fix,
            "group": self.group,
            "severity": self.severity,
        }


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def repo_root_from(value: str | None) -> pathlib.Path:
    if value:
        return pathlib.Path(value).resolve()
    return pathlib.Path.cwd().resolve()


def load_json(path: pathlib.Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    return json.loads(path.read_text())


def write_json(path: pathlib.Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def write_json_atomic(path: pathlib.Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temp_path = pathlib.Path(handle.name)
    os.replace(temp_path, path)


def load_yaml(path: pathlib.Path) -> Any:
    return yaml.safe_load(path.read_text())


def sha256_text(content: str) -> str:
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def read_text(path: pathlib.Path) -> str:
    try:
        return path.read_text()
    except UnicodeDecodeError:
        return path.read_text(encoding="utf-8", errors="replace")


def is_excluded_path(relative_path: str) -> bool:
    normalized = relative_path.replace("\\", "/")
    for excluded in EXCLUDED_DIRS:
        excluded_norm = excluded.replace("\\", "/")
        if normalized == excluded_norm or normalized.startswith(excluded_norm + "/"):
            return True
    return False


def list_repo_files(repo_root: pathlib.Path) -> list[pathlib.Path]:
    paths: list[pathlib.Path] = []
    for path in repo_root.rglob("*"):
        if not path.is_file():
            continue
        relative = relpath(path, repo_root)
        if is_excluded_path(relative):
            continue
        if path.suffix in PRODUCTION_EXTENSIONS or path.name in {"Brewfile", "justfile"}:
            paths.append(path)
    return sorted(paths)


def relpath(path: pathlib.Path, repo_root: pathlib.Path) -> str:
    return str(path.relative_to(repo_root)).replace("\\", "/")


def detect_language(path: pathlib.Path, content: str) -> str:
    suffix = path.suffix.lower()
    if suffix == ".rs":
        return "rust"
    if suffix == ".swift":
        return "swift"
    if suffix == ".py":
        return "python"
    if suffix in {".sh", ".bash", ".zsh"}:
        return "shell"
    if suffix in {".md"}:
        return "markdown"
    if suffix in {".yaml", ".yml"}:
        return "yaml"
    if suffix in {".mjs", ".js"}:
        return "javascript"
    if suffix == ".toml":
        return "toml"
    if content.startswith("#!/usr/bin/env bash") or content.startswith("#!/bin/bash"):
        return "shell"
    return "text"


def module_name_for(path: pathlib.Path) -> str:
    stem = path.stem
    if stem == "mod" and path.parent.name:
        return path.parent.name
    return stem


def category_for(relative_path: str) -> str:
    if relative_path.startswith("apps/swift/Sources/"):
        return "swift_source"
    if relative_path.startswith("apps/swift/Tests/"):
        return "swift_test"
    if relative_path.startswith("core/"):
        return "rust_source"
    if relative_path.startswith("tests/"):
        return "repo_test"
    if relative_path.startswith("scripts/"):
        return "script"
    if relative_path.startswith("docs/") or relative_path in {"README.md", "CLAUDE.md", "AGENT_CHANGELOG.md"}:
        return "doc"
    return "other"


def matches_glob(value: str, patterns: str | list[str]) -> bool:
    pattern_list = [patterns] if isinstance(patterns, str) else list(patterns)
    return any(fnmatch.fnmatch(value, pattern) for pattern in pattern_list)


def _match_segments(path_segments: list[str], pattern_segments: list[str]) -> bool:
    if not pattern_segments:
        return not path_segments
    if pattern_segments[0] == "**":
        if _match_segments(path_segments, pattern_segments[1:]):
            return True
        if path_segments:
            return _match_segments(path_segments[1:], pattern_segments)
        return False
    if not path_segments:
        return False
    if not fnmatch.fnmatchcase(path_segments[0], pattern_segments[0]):
        return False
    return _match_segments(path_segments[1:], pattern_segments[1:])


def recursive_glob_match(value: str, pattern: str) -> bool:
    normalized_value = value.replace("\\", "/")
    normalized_pattern = pattern.replace("\\", "/")
    return _match_segments(normalized_value.split("/"), normalized_pattern.split("/"))


def matches_name_or_path(module: dict[str, Any], pattern: str) -> bool:
    path = module["path"]
    if recursive_glob_match(path, pattern):
        return True
    if fnmatch.fnmatch(module["name"], pattern):
        return True
    return False


def validate_selector_glob(pattern: str) -> None:
    normalized = pattern.strip()
    if not normalized:
        raise ValueError("Selector patterns must not be empty.")
    recursive_glob_match("", normalized)


def fact_kind_from(spec: str | None) -> str | None:
    if not spec:
        return None
    kind, _, _ = spec.partition(":")
    return kind or None


def normalize_patterns(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item) for item in value]
    return [str(value)]


def find_git_changed_files(repo_root: pathlib.Path) -> list[str]:
    def run(args: list[str]) -> list[str]:
        completed = subprocess.run(
            args,
            cwd=repo_root,
            capture_output=True,
            check=False,
            text=True,
        )
        if completed.returncode != 0:
            return []
        return [line.strip() for line in completed.stdout.splitlines() if line.strip()]

    tracked = set(run(["git", "diff", "--name-only", "HEAD"]))
    staged = set(run(["git", "diff", "--cached", "--name-only"]))
    untracked = set(run(["git", "ls-files", "--others", "--exclude-standard"]))
    return sorted(tracked | staged | untracked)


def get_tree_sitter_parser(language: str):
    last_error: Exception | None = None
    try:
        from tree_sitter_language_pack import get_parser  # type: ignore

        return get_parser(language)
    except Exception as error:  # pragma: no cover - dependency import fallback
        last_error = error
    try:
        from tree_sitter_languages import get_parser  # type: ignore

        return get_parser(language)
    except Exception as error:  # pragma: no cover - dependency import fallback
        last_error = error
    raise RuntimeError(
        f"Unable to load tree-sitter parser for '{language}'. Install verifier dependencies first."
    ) from last_error


def tree_sitter_string_literals(language: str, content: str) -> list[dict[str, Any]]:
    parser = get_tree_sitter_parser(language)
    tree = parser.parse(content.encode("utf-8"))
    string_types = {
        "rust": {"string_literal", "raw_string_literal"},
        "swift": {"line_string_literal", "multi_line_string_literal", "string_literal"},
    }.get(language, set())
    literals: list[dict[str, Any]] = []

    def visit(node) -> None:
        if node.type in string_types:
            text = content.encode("utf-8")[node.start_byte : node.end_byte].decode("utf-8", "replace")
            literals.append(
                {
                    "value": strip_string_delimiters(text),
                    "line": node.start_point[0] + 1,
                    "kind": "string_literal",
                    "language": language,
                    "confidence": "high",
                    "source_span": {
                        "start": {
                            "line": node.start_point[0] + 1,
                            "column": node.start_point[1] + 1,
                        },
                        "end": {
                            "line": node.end_point[0] + 1,
                            "column": node.end_point[1] + 1,
                        },
                    },
                }
            )
        for child in node.children:
            visit(child)

    visit(tree.root_node)
    return literals


def strip_string_delimiters(value: str) -> str:
    result = value.strip()
    if result.startswith('"""') and result.endswith('"""'):
        return result[3:-3]
    if result.startswith('"') and result.endswith('"'):
        return result[1:-1]
    if result.startswith('r#"') and result.endswith('"#'):
        return result[3:-2]
    return result


def grep_lines(pattern: str, content: str, flags: int = 0) -> list[dict[str, Any]]:
    regex = re.compile(pattern, flags)
    matches: list[dict[str, Any]] = []
    for line_number, line in enumerate(content.splitlines(), start=1):
        for match in regex.finditer(line):
            value = match.group(1) if match.groups() else match.group(0)
            matches.append({"value": value.strip(), "line": line_number})
    return matches


def unique_entries(entries: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[tuple[str, int | None]] = set()
    unique: list[dict[str, Any]] = []
    for entry in entries:
        key = (str(entry.get("value")), entry.get("line"))
        if key in seen:
            continue
        seen.add(key)
        unique.append(entry)
    return unique


def dedupe_violations(violations: Iterable[Violation]) -> list[Violation]:
    seen: set[tuple[str, str | None, int | None, str]] = set()
    deduped: list[Violation] = []
    for violation in violations:
        key = (violation.rule, violation.path, violation.line, violation.message)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(violation)
    return deduped


def build_layer_payload(
    *,
    violations: Iterable[Violation] = (),
    status: str | None = None,
    execution_error: str | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    normalized = list(violations)
    error_count = sum(1 for violation in normalized if violation.severity != "warning")
    warning_count = sum(1 for violation in normalized if violation.severity == "warning")

    if status is None:
        if execution_error:
            status = "error"
        elif error_count > 0:
            status = "violated"
        else:
            status = "passed"

    payload = {
        "generated_at": utc_now(),
        "passed": status == "passed",
        "status": status,
        "violations": [violation.as_dict() for violation in normalized],
        "violation_count": error_count,
        "error_count": error_count,
        "warning_count": warning_count,
    }
    if execution_error:
        payload["execution_error"] = execution_error
    if extra:
        payload.update(extra)
    return payload


def build_error_payload(message: str, *, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    return build_layer_payload(status="error", execution_error=message, extra=extra)


def ensure_python() -> None:
    if sys.version_info < (3, 10):
        raise SystemExit("Python 3.10+ is required for scripts/verify")
