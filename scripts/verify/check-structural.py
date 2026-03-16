#!/usr/bin/env python3
from __future__ import annotations

import argparse
import pathlib
import re
from typing import Any

from ledger import audit_ledger
from pipeline import attach_run_manifest, manifest_violations
from structural_policy import (
    build_rule_audit,
    flatten_rules as flatten_policy_rules,
    layer1_policy_violations,
    rule_enforcement,
    rule_layer,
)
from verifier_common import (
    Violation,
    ensure_python,
    load_json,
    load_yaml,
    matches_name_or_path,
    normalize_patterns,
    read_text,
    relpath,
    utc_now,
    write_json,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run structural formal verification")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--facts", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--paths-file")
    parser.add_argument("--groups")
    parser.add_argument("--canonical-claims")
    parser.add_argument("--ledger")
    parser.add_argument("--specs-dir")
    parser.add_argument("--run-manifest")
    parser.add_argument("--report-only", action="store_true")
    parser.add_argument("--evolve", action="store_true")
    return parser.parse_args()


def flatten_rules(config: dict[str, Any]) -> list[dict[str, Any]]:
    return flatten_policy_rules(config)


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


def select_modules_with_audit(
    modules: list[dict[str, Any]],
    selector: dict[str, Any],
    *,
    exclude_generated: bool,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    scoped = [module for module in modules if module_in_scope(module, selector)]
    excepted = apply_exceptions(scoped, selector)
    generated_excluded = 0
    if exclude_generated:
        generated_excluded = sum(1 for module in excepted if module.get("generated"))
        excepted = [module for module in excepted if not module.get("generated")]

    audit = {
        "modules_considered": len(modules),
        "modules_scoped": len(scoped),
        "exceptions_applied": len(scoped) - len(apply_exceptions(scoped, selector)),
        "generated_excluded": generated_excluded,
        "modules_selected": len(excepted),
        "scope_empty": not excepted,
        "matches_found": 0,
    }
    return excepted, audit


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
    if kind == "implement":
        return entry_matches_regex(module["implements"], pattern)
    if kind == "http_route":
        return entry_matches_regex(module["http_routes"], pattern)
    if kind == "shell_command_literal":
        return entry_matches_regex(module["shell_command_literals"], pattern)
    if kind == "definition":
        return entry_matches_regex(module["definitions"], pattern)
    if kind == "string_literal":
        return entry_matches_regex(module["string_literals"], pattern)
    if kind == "doc_claim":
        return entry_matches_regex(module["doc_claims"], pattern)
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


def check_rule_with_audit(
    rule: dict[str, Any],
    modules: list[dict[str, Any]],
    repo_root: pathlib.Path,
) -> tuple[list[Violation], dict[str, Any]]:
    if rule_layer(rule) != 1:
        return [], {
            "rule": rule["rule"],
            "modules_considered": len(modules),
            "modules_scoped": 0,
            "exceptions_applied": 0,
            "generated_excluded": 0,
            "modules_selected": 0,
            "scope_empty": True,
            "matches_found": 0,
        }

    selector = rule.get("constraint", {})
    rule_id = rule["rule"]
    description = rule.get("description", rule_id)
    groups = normalize_patterns(rule.get("groups"))
    severity = "warning" if rule_enforcement(rule) == "advisory" else "error"
    hard_gate = rule_enforcement(rule) == "hard"
    exclude_generated = hard_gate and not selector.get("include_generated", False)
    audit = {
        "rule": rule_id,
        "modules_considered": len(modules),
        "modules_scoped": 0,
        "exceptions_applied": 0,
        "generated_excluded": 0,
        "modules_selected": 0,
        "scope_empty": False,
        "matches_found": 0,
    }

    if "only" in selector and "may" in selector:
        allowed_patterns = normalize_patterns(selector["only"])
        violating: list[Violation] = []
        for module in modules:
            if any(matches_name_or_path(module, pattern) for pattern in allowed_patterns):
                continue
            matches = matches_fact(module, repo_root, selector["may"])
            for match in matches:
                audit["matches_found"] += 1
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
                        severity=severity,
                    )
                )
        return violating, audit

    selected, selection_audit = select_modules_with_audit(
        modules,
        selector,
        exclude_generated=exclude_generated,
    )
    audit.update(selection_audit)
    violations: list[Violation] = []
    empty_scope_is_error = (
        hard_gate
        and not selector.get("allow_empty_scope", False)
        and (audit["modules_scoped"] == 0 or (audit["modules_selected"] == 0 and audit["generated_excluded"] > 0))
    )
    if empty_scope_is_error:
        violations.append(
            Violation(
                layer="1",
                rule=rule_id,
                path=None,
                line=None,
                message="Hard structural rule selected zero authored modules",
                diagnosis=(
                    f"Rule {rule_id} scoped zero authored modules after exceptions and generated-surface exclusion. "
                    "This would silently disable a correctness gate."
                ),
                fix="Tighten the selector, set include_generated intentionally, or declare allow_empty_scope for this rule.",
            )
        )
        return violations, audit

    for module in selected:
        fact_key = selector.get("must_not") or selector.get("must")
        if not fact_key:
            continue
        matches = matches_fact(module, repo_root, fact_key)
        audit["matches_found"] += len(matches)
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
                        severity=severity,
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
                    severity=severity,
                )
            )
    return violations, audit


def check_rule(
    rule: dict[str, Any],
    modules: list[dict[str, Any]],
    repo_root: pathlib.Path,
) -> list[Violation]:
    violations, _ = check_rule_with_audit(rule, modules, repo_root)
    return violations


def evolve_violations(
    config: dict[str, Any],
    rules: list[dict[str, Any]],
    facts: dict[str, Any],
) -> list[Violation]:
    canonical_docs = normalize_patterns(config.get("meta", {}).get("canonical_docs"))
    enforced_claim_patterns = [
        re.compile(pattern, flags=re.IGNORECASE)
        for pattern in normalize_patterns(config.get("meta", {}).get("doc_claim_patterns"))
    ]
    doc_modules = [module for module in facts["modules"] if module["path"] in canonical_docs]
    violations: list[Violation] = []

    covered_claims: set[tuple[str, int]] = set()
    for rule in rules:
        source_docs = set(normalize_patterns(rule.get("source_docs")))
        patterns = normalize_patterns(rule.get("doc_patterns"))
        if not source_docs or not patterns:
            continue
        for pattern in patterns:
            regex = re.compile(pattern, flags=re.IGNORECASE)
            matched = False
            for module in doc_modules:
                if module["path"] not in source_docs:
                    continue
                for claim in module.get("doc_claims", []):
                    if regex.search(claim["value"]):
                        matched = True
                        covered_claims.add((module["path"], claim["line"]))
            if not matched:
                violations.append(
                    Violation(
                        layer="1",
                        rule=rule["rule"],
                        path=None,
                        line=None,
                        message="Verifier doc pattern no longer matches source docs",
                        diagnosis=f"Rule {rule['rule']} references stale doc pattern {pattern}.",
                        fix="Update doc_patterns or the source document intentionally.",
                    )
                )

    for module in doc_modules:
        for claim in module.get("doc_claims", []):
            if enforced_claim_patterns and not any(pattern.search(claim["value"]) for pattern in enforced_claim_patterns):
                continue
            key = (module["path"], claim["line"])
            if key in covered_claims:
                continue
            violations.append(
                Violation(
                    layer="1",
                    rule="uncovered_doc_claim",
                    path=module["path"],
                    line=claim["line"],
                    message="Canonical architecture claim is not covered by verifier rules",
                    diagnosis=f"{module['path']} contains an ownership/boundary claim with no matching verifier rule.",
                    fix="Add a structural rule with source_docs/doc_patterns or remove the stale claim.",
                )
            )
    return violations


def main() -> None:
    ensure_python()
    args = parse_args()
    repo_root = pathlib.Path(args.repo_root).resolve()
    facts = load_json(pathlib.Path(args.facts), default={})
    config = load_yaml(pathlib.Path(args.config))
    rules = flatten_rules(config)
    audit = build_rule_audit(config)
    selected_groups = normalize_groups(args.groups)
    selected_paths = load_selected_paths(args.paths_file)
    expected_manifest = load_json(pathlib.Path(args.run_manifest), default={}) if args.run_manifest else None

    violations: list[Violation] = [
        Violation(
            layer="1",
            rule=entry["rule"],
            path=None,
            line=None,
            message=entry["message"],
            diagnosis=entry["diagnosis"],
            fix=entry["fix"],
        )
        for entry in layer1_policy_violations(config)
    ]
    if expected_manifest:
        for issue in manifest_violations(expected_manifest, facts.get("run_manifest")):
            violations.append(
                Violation(
                    layer="1",
                    rule="run_manifest_drift",
                    path=None,
                    line=None,
                    message=issue["message"],
                    diagnosis=issue["diagnosis"],
                    fix="Re-run the verifier so facts and structural checks share the same run manifest.",
                )
            )
    selector_audits: list[dict[str, Any]] = []
    for rule in rules:
        if not matching_rule_groups(rule, selected_groups):
            continue
        rule_violations, rule_audit = check_rule_with_audit(rule, facts["modules"], repo_root)
        violations.extend(rule_violations)
        selector_audits.append(rule_audit)

    if args.evolve:
        violations.extend(evolve_violations(config, rules, facts))

    ledger_audit = None
    if args.canonical_claims and args.ledger and args.specs_dir:
        ledger_audit = audit_ledger(
            structural_config=config,
            canonical_claims=load_yaml(pathlib.Path(args.canonical_claims)),
            ledger_config=load_yaml(pathlib.Path(args.ledger)),
            spec_ids=sorted(
                path.stem
                for path in pathlib.Path(args.specs_dir).glob("*.py")
                if not path.name.startswith("_")
            ),
            repo_root=repo_root,
        )
        for claim_id in ledger_audit["missing_claims"]:
            violations.append(
                Violation(
                    layer="1",
                    rule="ledger_missing_claim",
                    path=None,
                    line=None,
                    message="Hard canonical claim is missing from the verifier ledger",
                    diagnosis=f"{claim_id} has no ledger entry.",
                    fix="Add the claim to .verifier/ledger.yaml with structural rules/specs and proof fixtures.",
                )
            )
        for claim_id in ledger_audit["missing_positive_fixtures"]:
            violations.append(
                Violation(
                    layer="1",
                    rule="ledger_missing_positive_fixture",
                    path=None,
                    line=None,
                    message="Hard canonical claim is missing a positive proof fixture",
                    diagnosis=f"{claim_id} has no positive proof artifact in the ledger.",
                    fix="Add a dedicated positive proof artifact for this claim.",
                )
            )
        for claim_id in ledger_audit["missing_negative_fixtures"]:
            violations.append(
                Violation(
                    layer="1",
                    rule="ledger_missing_negative_fixture",
                    path=None,
                    line=None,
                    message="Hard canonical claim is missing a negative proof fixture",
                    diagnosis=f"{claim_id} has no negative proof artifact in the ledger.",
                    fix="Add a dedicated negative proof artifact for this claim.",
                )
            )
        for claim_id in ledger_audit["missing_fixture_artifacts"]:
            violations.append(
                Violation(
                    layer="1",
                    rule="ledger_missing_fixture_artifact",
                    path=None,
                    line=None,
                    message="Ledger fixture entry points at a missing proof artifact",
                    diagnosis=f"{claim_id} references a fixture path that does not exist in the repo.",
                    fix="Fix the ledger pointer or add the missing proof artifact.",
                )
            )
        for rule_id in ledger_audit["orphaned_rules"]:
            violations.append(
                Violation(
                    layer="1",
                    rule="ledger_orphaned_rule",
                    path=None,
                    line=None,
                    message="Hard structural rule is not mapped to any canonical claim",
                    diagnosis=f"{rule_id} is not mapped in the verifier ledger.",
                    fix="Assign the rule to a canonical claim in .verifier/ledger.yaml.",
                )
            )
        for spec_id in ledger_audit["orphaned_specs"]:
            violations.append(
                Violation(
                    layer="1",
                    rule="ledger_orphaned_spec",
                    path=None,
                    line=None,
                    message="Behavioral spec is not mapped to any canonical claim",
                    diagnosis=f"{spec_id} is not mapped in the verifier ledger.",
                    fix="Assign the behavioral spec to one or more canonical claims in .verifier/ledger.yaml.",
                )
            )

    if selected_paths:
        violations = [violation for violation in violations if not violation.path or violation.path in selected_paths]

    error_violations = [violation for violation in violations if violation.severity != "warning"]
    payload = {
        "generated_at": utc_now(),
        "passed": not error_violations,
        "audit": audit,
        "claim_coverage": ledger_audit["claim_coverage"] if ledger_audit else [],
        "ledger_audit": ledger_audit,
        "selector_audits": selector_audits,
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
