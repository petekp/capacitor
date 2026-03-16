#!/usr/bin/env python3
from __future__ import annotations

import argparse
import pathlib
import re
from typing import Any

from doc_governance import doc_governance_violations
from verifier_common import (
    Violation,
    VALID_FACT_KINDS,
    build_error_payload,
    build_layer_payload,
    dedupe_violations,
    ensure_python,
    fact_kind_from,
    load_json,
    load_yaml,
    matches_name_or_path,
    normalize_patterns,
    read_text,
    relpath,
    validate_selector_glob,
    write_json_atomic,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run structural formal verification")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--facts", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--paths-file")
    parser.add_argument("--groups")
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--evolve", action="store_true")
    return parser.parse_args()


def flatten_rules(config: dict[str, Any]) -> list[dict[str, Any]]:
    rules: list[dict[str, Any]] = []
    for category, values in config.items():
        if category == "meta":
            continue
        for rule in values or []:
            rule["category"] = category
            rules.append(rule)
    return rules


def normalize_groups(value: str | None) -> set[str] | None:
    if not value:
        return None
    groups = {item.strip() for item in value.split(",") if item.strip()}
    return groups or None


def module_in_scope(module: dict[str, Any], selector: dict[str, Any]) -> bool:
    if selector.get("all_modules") is True:
        return True

    if "files_matching" in selector:
        return any(matches_name_or_path(module, pattern) for pattern in normalize_patterns(selector["files_matching"]))

    if "files_in" in selector:
        for value in normalize_patterns(selector["files_in"]):
            if module["path"] == value or module["path"].startswith(value.rstrip("/") + "/"):
                return True
        return False

    if "modules_matching" in selector:
        return any(matches_name_or_path(module, pattern) for pattern in normalize_patterns(selector["modules_matching"]))

    if "modules_in" in selector:
        descriptor = selector["modules_in"]
        if isinstance(descriptor, dict):
            language = descriptor.get("language")
            directory = descriptor.get("directory")
            category = descriptor.get("category")
            if language and module["language"] != language:
                return False
            if directory and not module["path"].startswith(str(directory).rstrip("/") + "/"):
                return False
            if category and module["category"] != category:
                return False
            return True
        if descriptor in {"rust", "swift", "shell", "markdown", "yaml", "javascript"}:
            return module["language"] == descriptor
        return module["path"].startswith(str(descriptor).rstrip("/") + "/")

    return True


def apply_exceptions(modules: list[dict[str, Any]], selector: dict[str, Any]) -> list[dict[str, Any]]:
    patterns = normalize_patterns(selector.get("except"))
    if not patterns:
        return modules
    return [
        module
        for module in modules
        if not any(matches_name_or_path(module, pattern) for pattern in patterns)
    ]


def select_modules(modules: list[dict[str, Any]], selector: dict[str, Any]) -> list[dict[str, Any]]:
    selected = [module for module in modules if module_in_scope(module, selector)]
    return apply_exceptions(selected, selector)


def load_selected_paths(path_file: str | None) -> set[str] | None:
    if not path_file:
        return None
    path = pathlib.Path(path_file)
    if not path.exists():
        return set()
    return {line.strip() for line in path.read_text().splitlines() if line.strip()}


def entry_matches_regex(entries: list[dict[str, Any]], pattern: str) -> list[dict[str, Any]]:
    regex = re.compile(pattern)
    return [entry for entry in entries if regex.search(str(entry.get("value", "")))]


def entry_matches_glob(entries: list[dict[str, Any]], pattern: str) -> list[dict[str, Any]]:
    regex = re.compile("^" + pattern.replace(".", r"\.").replace("*", ".*").replace("?", ".") + "$")
    return [entry for entry in entries if regex.search(str(entry.get("value", "")))]


def matches_fact(module: dict[str, Any], repo_root: pathlib.Path, fact_spec: str) -> list[dict[str, Any]]:
    kind, _, pattern = fact_spec.partition(":")
    if not pattern:
        raise ValueError(f"Invalid fact specification: {fact_spec}")
    if kind == "path_regex":
        regex = re.compile(pattern)
        if regex.search(module["path"]):
            return [{"value": module["path"], "line": None}]
        return []
    if kind == "import":
        return entry_matches_regex(module["imports"], pattern)
    if kind == "call_pattern":
        matches = []
        for part in pattern.split("|"):
            matches.extend(entry_matches_glob(module["calls"], part))
        return matches
    if kind == "reference":
        return entry_matches_regex(module["references"], pattern)
    if kind == "identifier_ref":
        return entry_matches_regex(module["identifier_refs"], pattern)
    if kind == "implement":
        return entry_matches_regex(module["implements"], pattern)
    if kind == "http_route":
        return entry_matches_regex(module["http_routes"], pattern)
    if kind == "static_http_route":
        return entry_matches_regex(module["static_http_routes"], pattern)
    if kind == "shell_command_literal":
        return entry_matches_regex(module["shell_command_literals"], pattern)
    if kind == "process_exec":
        return entry_matches_regex(module["process_execs"], pattern)
    if kind == "doc_claim":
        return entry_matches_regex(module["doc_claims"], pattern)
    if kind == "raw_text":
        return entry_matches_regex(module["raw_text"], pattern)
    if kind == "contains_regex":
        content = read_text(repo_root / module["path"])
        regex = re.compile(pattern, flags=re.MULTILINE)
        matches = []
        for line_number, line in enumerate(content.splitlines(), start=1):
            if regex.search(line):
                matches.append({"value": line.strip(), "line": line_number})
        return matches
    raise ValueError(f"Unsupported fact kind: {kind}")


def matching_rule_groups(rule: dict[str, Any], selected_groups: set[str] | None) -> bool:
    if selected_groups is None:
        return True
    rule_groups = set(normalize_patterns(rule.get("groups")))
    return bool(rule_groups & selected_groups)


def validate_selector(rule: dict[str, Any], selector: dict[str, Any]) -> None:
    if not selector:
        raise ValueError(f"Rule {rule['rule']} must declare a constraint.")

    scope_keys = {"all_modules", "files_matching", "files_in", "modules_matching", "modules_in"}
    if selector.get("all_modules") is not True and not any(key in selector for key in scope_keys - {"all_modules"}):
        raise ValueError(
            f"Rule {rule['rule']} must declare a non-empty scope or set all_modules: true."
        )

    for key in ("files_matching", "files_in", "modules_matching", "except"):
        for pattern in normalize_patterns(selector.get(key)):
            validate_selector_glob(pattern)

    if "modules_in" in selector:
        descriptor = selector["modules_in"]
        if isinstance(descriptor, dict):
            directory = descriptor.get("directory")
            if directory is not None:
                validate_selector_glob(str(directory).rstrip("/") + "/**")

    fact_specs = [
        selector.get("must"),
        selector.get("must_not"),
        selector.get("may"),
    ]
    for fact_spec in fact_specs:
        kind = fact_kind_from(fact_spec)
        if kind and kind not in VALID_FACT_KINDS:
            raise ValueError(f"Rule {rule['rule']} references unsupported fact kind '{kind}'.")

    if "only" in selector:
        allowed_patterns = normalize_patterns(selector["only"])
        if not allowed_patterns:
            raise ValueError(f"Rule {rule['rule']} must declare at least one allowed owner pattern.")
        for pattern in allowed_patterns:
            validate_selector_glob(pattern)
        if "may" not in selector:
            raise ValueError(f"Rule {rule['rule']} uses 'only' without a matching 'may' fact.")


def validate_config(config: dict[str, Any], rules: list[dict[str, Any]]) -> None:
    for rule in rules:
        validate_selector(rule, rule.get("constraint", {}))
        if "source_docs" in rule or "doc_patterns" in rule:
            raise ValueError(f"Rule {rule['rule']} must use claim_ids instead of source_docs/doc_patterns.")
        if "claim_ids" in rule and not normalize_patterns(rule.get("claim_ids")):
            raise ValueError(f"Rule {rule['rule']} must not declare an empty claim_ids list.")


def check_rule(
    rule: dict[str, Any],
    modules: list[dict[str, Any]],
    repo_root: pathlib.Path,
) -> list[Violation]:
    selector = rule.get("constraint", {})
    rule_id = rule["rule"]
    description = rule.get("description", rule_id)
    groups = normalize_patterns(rule.get("groups"))

    if "only" in selector and "may" in selector:
        allowed_patterns = normalize_patterns(selector["only"])
        violating: list[Violation] = []
        for module in modules:
            if any(matches_name_or_path(module, pattern) for pattern in allowed_patterns):
                continue
            matches = matches_fact(module, repo_root, selector["may"])
            for match in matches:
                violating.append(
                    Violation(
                        layer="1",
                        rule=rule_id,
                        path=module["path"],
                        line=match.get("line"),
                        message=description,
                        diagnosis=f"{module['path']} is outside the allowed owner set for {selector['may']}.",
                        fix=f"Move this usage into one of: {', '.join(allowed_patterns)}",
                        group=groups[0] if groups else None,
                    )
                )
        return violating

    selected = select_modules(modules, selector)
    violations: list[Violation] = []
    for module in selected:
        fact_key = selector.get("must_not") or selector.get("must")
        if not fact_key:
            continue
        matches = matches_fact(module, repo_root, fact_key)
        if selector.get("must_not"):
            for match in matches:
                violations.append(
                    Violation(
                        layer="1",
                        rule=rule_id,
                        path=module["path"],
                        line=match.get("line"),
                        message=description,
                        diagnosis=f"{module['path']} contains forbidden fact {fact_key}.",
                        fix="Move the behavior to the declared owner or delete the shadow path.",
                        group=groups[0] if groups else None,
                    )
                )
        elif selector.get("must") and not matches:
            violations.append(
                Violation(
                    layer="1",
                    rule=rule_id,
                    path=module["path"],
                    line=None,
                    message=description,
                    diagnosis=f"{module['path']} is missing required fact {fact_key}.",
                    fix="Restore the required ownership signal or update the verifier spec intentionally.",
                    group=groups[0] if groups else None,
                )
            )
    return violations


def evolve_violations(
    config: dict[str, Any],
    rules: list[dict[str, Any]],
    facts: dict[str, Any],
    repo_root: pathlib.Path,
) -> list[Violation]:
    canonical_docs = normalize_patterns(config.get("meta", {}).get("canonical_docs"))
    doc_modules = [module for module in facts["modules"] if module["path"] in canonical_docs]
    violations: list[Violation] = []

    claims_by_id: dict[str, dict[str, Any]] = {}
    for module in doc_modules:
        for claim in module.get("doc_claims", []):
            claim_id = claim.get("id")
            if not claim_id:
                continue
            claims_by_id[claim_id] = {
                "module_path": module["path"],
                "line": claim["line"],
                "value": claim["value"],
                "owner_scopes": claim.get("owner_scopes", []),
            }

    covered_claim_ids: set[str] = set()
    for rule in rules:
        for claim_id in normalize_patterns(rule.get("claim_ids")):
            if claim_id not in claims_by_id:
                violations.append(
                    Violation(
                        layer="1",
                        rule="missing_claim_id",
                        path=None,
                        line=None,
                        message="Structural rule references a missing canonical claim id",
                        diagnosis=f"Rule {rule['rule']} references missing claim id {claim_id}.",
                        fix="Update claim_ids or restore the canonical claim marker intentionally.",
                    )
                )
                continue
            covered_claim_ids.add(claim_id)

    for claim_id, claim in claims_by_id.items():
        if claim_id not in covered_claim_ids:
            violations.append(
                Violation(
                    layer="1",
                    rule="uncovered_doc_claim",
                    path=claim["module_path"],
                    line=claim["line"],
                    message="Canonical architecture claim is not covered by verifier rules",
                    diagnosis=f"Claim {claim_id} has no enforcing structural rule.",
                    fix="Add a structural rule with claim_ids or remove the stale claim marker.",
                )
            )
        owner_scopes = normalize_patterns(claim.get("owner_scopes"))
        if owner_scopes and not any(
            any(matches_name_or_path(module, pattern) for pattern in owner_scopes)
            for module in facts["modules"]
        ):
            violations.append(
                Violation(
                    layer="1",
                    rule="orphaned_claim_owner_scope",
                    path=claim["module_path"],
                    line=claim["line"],
                    message="Canonical claim owner scope no longer matches any modules",
                    diagnosis=f"Claim {claim_id} declares owner_scope values that match no modules.",
                    fix="Update owner_scope metadata or restore the intended owner module intentionally.",
                )
            )
    violations.extend(doc_governance_violations(repo_root, config))
    return violations


def main() -> None:
    ensure_python()
    args = parse_args()
    repo_root = pathlib.Path(args.repo_root).resolve()
    out_path = pathlib.Path(args.out)

    try:
        facts = load_json(pathlib.Path(args.facts), default={})
        config = load_yaml(pathlib.Path(args.config))
        rules = flatten_rules(config)
        validate_config(config, rules)

        selected_groups = normalize_groups(args.groups)
        selected_paths = load_selected_paths(args.paths_file)

        violations: list[Violation] = []
        for rule in rules:
            if not matching_rule_groups(rule, selected_groups):
                continue
            violations.extend(check_rule(rule, facts["modules"], repo_root))

        if args.evolve:
            violations.extend(evolve_violations(config, rules, facts, repo_root))

        if selected_paths:
            violations = [violation for violation in violations if not violation.path or violation.path in selected_paths]

        payload = build_layer_payload(violations=dedupe_violations(violations))
        write_json_atomic(out_path, payload)

        if args.status:
            raise SystemExit(0)
        raise SystemExit(0 if payload["passed"] else 1)
    except Exception as error:
        payload = build_error_payload(str(error))
        write_json_atomic(out_path, payload)
        if args.status:
            raise SystemExit(0)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
