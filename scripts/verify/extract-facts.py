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
    get_tree_sitter_parser,
    grep_lines,
    list_repo_files,
    load_json,
    module_name_for,
    read_text,
    relpath,
    sha256_text,
    strip_string_delimiters,
    tree_sitter_string_literals,
    unique_entries,
    utc_now,
    write_json_atomic,
)


DOC_CLAIM_PATTERN = re.compile(
    r"\b(owner|owns|owned by|boundary|single source of truth|canonical|authoritative|must remain|only)\b",
    re.IGNORECASE,
)
CLAIM_MARKER_PATTERN = re.compile(r"VERIFIER_CLAIM\((?P<id>[A-Za-z0-9_.-]+)\):\s*(?P<body>.+)")
OWNER_SCOPE_PATTERN = re.compile(r"owner_scope=(?P<scopes>[^;]+);\s*(?P<body>.*)")
HTTP_ROUTE_LITERAL_PATTERN = re.compile(r"^(/health|/runtime/[A-Za-z0-9/_-]+)$")
HTTP_ROUTE_URL_PATTERN = re.compile(r"https?://[^/]+(/health|/runtime/[A-Za-z0-9/_-]+)")
SHELL_COMMAND_PATTERN = re.compile(
    r"(tmux\s+[A-Za-z0-9_-]+|open -a Ghostty\.app|tell process \"Ghostty\"|tell application \"Ghostty\"|curl\s+[^\"']*/runtime/[A-Za-z0-9/_-]+)"
)
SWIFT_HELPER_CALL_PATTERN = re.compile(
    r"\b(?:runScript|runBashScript|runBashScriptWithResult)\(\s*([A-Za-z_][A-Za-z0-9_]*|\"(?:[^\"\\\\]|\\\\.)*\"(?:\s*\+\s*\"(?:[^\"\\\\]|\\\\.)*\")*)\s*\)"
)
RUST_COMMAND_PATTERN = re.compile(r"Command::new\(\s*\"([^\"]+)\"\s*\)(?P<chain>[\s\S]*?)(?:;|\n\s*\})")
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SWIFT_PROCESS_EXECUTABLE_PATTERN = re.compile(
    r"([A-Za-z_][A-Za-z0-9_]*)\.executableURL\s*=\s*URL\(fileURLWithPath:\s*\"([^\"]+)\"\s*\)"
)
SWIFT_PROCESS_ARGUMENTS_PATTERN = re.compile(
    r"([A-Za-z_][A-Za-z0-9_]*)\.arguments\s*=\s*\[(.*?)\]",
    re.DOTALL,
)
EXTRACTOR_VERSION = 3

LANGUAGE_KEYWORDS = {
    "python": {
        "and",
        "as",
        "assert",
        "async",
        "await",
        "break",
        "class",
        "continue",
        "def",
        "del",
        "elif",
        "else",
        "except",
        "False",
        "finally",
        "for",
        "from",
        "if",
        "import",
        "in",
        "is",
        "lambda",
        "None",
        "nonlocal",
        "not",
        "or",
        "pass",
        "raise",
        "return",
        "True",
        "try",
        "while",
        "with",
        "yield",
    },
    "rust": {
        "Self",
        "as",
        "async",
        "await",
        "break",
        "const",
        "continue",
        "crate",
        "else",
        "enum",
        "extern",
        "false",
        "fn",
        "for",
        "if",
        "impl",
        "in",
        "let",
        "loop",
        "match",
        "mod",
        "move",
        "mut",
        "pub",
        "ref",
        "return",
        "self",
        "static",
        "struct",
        "super",
        "trait",
        "true",
        "type",
        "unsafe",
        "use",
        "where",
        "while",
    },
    "swift": {
        "actor",
        "as",
        "async",
        "await",
        "break",
        "case",
        "class",
        "continue",
        "default",
        "defer",
        "do",
        "else",
        "enum",
        "extension",
        "fallthrough",
        "false",
        "for",
        "func",
        "guard",
        "if",
        "import",
        "in",
        "init",
        "let",
        "nil",
        "private",
        "protocol",
        "public",
        "repeat",
        "return",
        "self",
        "static",
        "struct",
        "switch",
        "throw",
        "throws",
        "true",
        "var",
        "where",
        "while",
    },
}


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
        marker = CLAIM_MARKER_PATTERN.search(stripped)
        if not marker:
            continue

        body = marker.group("body").strip()
        owner_scope_match = OWNER_SCOPE_PATTERN.match(body)
        owner_scopes: list[str] = []
        if owner_scope_match:
            owner_scopes = [scope.strip() for scope in owner_scope_match.group("scopes").split(",") if scope.strip()]
            body = owner_scope_match.group("body").strip()

        if len(body) < 8 and not DOC_CLAIM_PATTERN.search(body):
            continue
        claims.append(
            {
                "id": marker.group("id"),
                "value": body,
                "line": line_number,
                "owner_scopes": owner_scopes,
            }
        )
    return unique_entries(claims)


def http_routes_for(content: str) -> list[dict[str, Any]]:
    matches = []
    for line_number, line in enumerate(content.splitlines(), start=1):
        if ".capacitor/runtime" in line:
            continue
        stripped = line.strip().strip('",')
        if HTTP_ROUTE_LITERAL_PATTERN.match(stripped):
            matches.append({"value": stripped, "line": line_number})
        for match in HTTP_ROUTE_URL_PATTERN.finditer(line):
            matches.append({"value": match.group(1), "line": line_number})
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


def raw_text_entries(content: str) -> list[dict[str, Any]]:
    return unique_entries(
        {"value": line.strip(), "line": line_number}
        for line_number, line in enumerate(content.splitlines(), start=1)
        if line.strip()
    )


def identifier_refs_for(language: str, content: str) -> list[dict[str, Any]]:
    if language not in {"python", "rust", "swift"}:
        return []

    parser = get_tree_sitter_parser(language)
    tree = parser.parse(content.encode("utf-8"))
    excluded_node_types = {
        "comment",
        "block_comment",
        "line_comment",
        "string",
        "string_literal",
        "line_string_literal",
        "multi_line_string_literal",
        "raw_string_literal",
        "interpreted_string_literal",
    }
    keywords = LANGUAGE_KEYWORDS.get(language, set())
    source = content.encode("utf-8")
    tokens: list[dict[str, Any]] = []

    def visit(node) -> None:
        if node.type in excluded_node_types:
            return
        if node.child_count == 0:
            text = source[node.start_byte : node.end_byte].decode("utf-8", "replace")
            if IDENTIFIER_PATTERN.match(text) and text not in keywords:
                tokens.append({"value": text, "line": node.start_point[0] + 1})
            return
        for child in node.children:
            visit(child)

    visit(tree.root_node)
    return unique_entries(tokens)


def resolve_static_string_expression(
    expression: str,
    bindings: dict[str, dict[str, Any]],
) -> dict[str, Any] | None:
    trimmed = expression.strip().rstrip(",").rstrip(";")
    if not trimmed:
        return None

    if IDENTIFIER_PATTERN.match(trimmed):
        return bindings.get(trimmed)

    parts = [part.strip() for part in trimmed.split("+")]
    values: list[str] = []
    line: int | None = None
    for part in parts:
        if not part:
            return None
        if IDENTIFIER_PATTERN.match(part):
            binding = bindings.get(part)
            if binding is None:
                return None
            if line is None:
                line = binding["line"]
            values.append(binding["value"])
            continue
        if part.startswith('"') and part.endswith('"'):
            values.append(strip_string_delimiters(part))
            continue
        return None

    if not values:
        return None
    return {"value": "".join(values), "line": line}


def static_string_bindings(language: str, content: str) -> dict[str, dict[str, Any]]:
    bindings: dict[str, dict[str, Any]] = {}
    if language == "swift":
        pattern = re.compile(r"^\s*(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$", re.MULTILINE)
    elif language == "rust":
        pattern = re.compile(r"^\s*let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+);$", re.MULTILINE)
    else:
        return bindings

    for match in pattern.finditer(content):
        resolved = resolve_static_string_expression(match.group(2), bindings)
        if resolved is None:
            continue
        bindings[match.group(1)] = {
            "value": resolved["value"],
            "line": content[: match.start()].count("\n") + 1,
        }
    return bindings


def parse_string_array_expression(expression: str, bindings: dict[str, dict[str, Any]]) -> list[str] | None:
    parts = [part.strip() for part in expression.split(",")]
    values: list[str] = []
    for part in parts:
        if not part:
            continue
        resolved = resolve_static_string_expression(part, bindings)
        if resolved is None:
            return None
        values.append(resolved["value"])
    return values


def static_http_routes_for(
    string_literals: list[dict[str, Any]],
    bindings: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    matches: list[dict[str, Any]] = []
    for literal in string_literals:
        value = literal["value"].strip()
        if HTTP_ROUTE_LITERAL_PATTERN.match(value):
            matches.append({"value": value, "line": literal["line"]})
        for match in HTTP_ROUTE_URL_PATTERN.finditer(value):
            matches.append({"value": match.group(1), "line": literal["line"]})
    for binding in bindings.values():
        value = binding["value"].strip()
        if HTTP_ROUTE_LITERAL_PATTERN.match(value):
            matches.append({"value": value, "line": binding["line"]})
        for match in HTTP_ROUTE_URL_PATTERN.finditer(value):
            matches.append({"value": match.group(1), "line": binding["line"]})
    return unique_entries(matches)


def process_execs_for(language: str, content: str, bindings: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    matches: list[dict[str, Any]] = []

    if language == "swift":
        for match in SWIFT_HELPER_CALL_PATTERN.finditer(content):
            resolved = resolve_static_string_expression(match.group(1), bindings)
            if resolved is None:
                continue
            line = content[: match.start()].count("\n") + 1
            matches.append({"value": resolved["value"], "line": resolved["line"] or line})

        executables: dict[str, dict[str, Any]] = {}
        for match in SWIFT_PROCESS_EXECUTABLE_PATTERN.finditer(content):
            executables[match.group(1)] = {
                "value": match.group(2),
                "line": content[: match.start()].count("\n") + 1,
            }

        for match in SWIFT_PROCESS_ARGUMENTS_PATTERN.finditer(content):
            variable = match.group(1)
            executable = executables.get(variable)
            if executable is None:
                continue
            args = parse_string_array_expression(match.group(2), bindings)
            if args is None:
                continue

            line = content[: match.start()].count("\n") + 1
            matches.append({"value": " ".join([executable["value"], *args]).strip(), "line": line})

            executable_value = executable["value"]
            if executable_value.endswith("/bash") or executable_value.endswith("/sh"):
                if len(args) >= 2 and args[0] == "-c":
                    matches.append({"value": args[1], "line": line})
            if executable_value.endswith("/env"):
                if len(args) >= 3 and args[0] in {"bash", "sh"} and args[1] == "-c":
                    matches.append({"value": args[2], "line": line})

    if language == "rust":
        for match in RUST_COMMAND_PATTERN.finditer(content):
            executable = match.group(1)
            line = content[: match.start()].count("\n") + 1
            args: list[str] = [executable]
            args.extend(re.findall(r'\.arg\(\s*"([^"]+)"\s*\)', match.group("chain")))
            for arg_list in re.findall(r"\.args\(\s*\[(.*?)\]\s*\)", match.group("chain"), flags=re.DOTALL):
                args.extend(re.findall(r'"([^"]+)"', arg_list))
            matches.append({"value": " ".join(args), "line": line})

    return unique_entries(matches)


def extract_module(path: pathlib.Path, repo_root: pathlib.Path) -> dict[str, Any]:
    content = read_text(path)
    language = detect_language(path, content)
    relative_path = relpath(path, repo_root)
    string_literals: list[dict[str, Any]] = []
    if language in {"rust", "swift"}:
        string_literals = tree_sitter_string_literals(language, content)

    bindings = static_string_bindings(language, content)

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

    return {
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
        "identifier_refs": identifier_refs_for(language, content),
        "raw_text": raw_text_entries(content),
        "string_literals": unique_entries(string_literals),
        "http_routes": http_routes_for(content),
        "static_http_routes": static_http_routes_for(string_literals, bindings),
        "shell_command_literals": shell_command_literals_for(content, string_literals),
        "process_execs": process_execs_for(language, content, bindings),
        "doc_claims": doc_claims_for(content) if language in {"markdown", "yaml", "toml"} else [],
    }


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

    modules: list[dict[str, Any]] = []
    for path in list_repo_files(repo_root):
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
    write_json_atomic(out_path, payload)


if __name__ == "__main__":
    main()
