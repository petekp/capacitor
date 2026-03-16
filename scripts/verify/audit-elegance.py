#!/usr/bin/env python3
from __future__ import annotations

import argparse
import pathlib
import re
from typing import Any

import lizard

from verifier_common import (
    Violation,
    build_layer_payload,
    ensure_python,
    load_json,
    load_yaml,
    read_text,
    write_json_atomic,
)


GRADE_ORDER = ["F", "D", "C", "B", "A"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run elegance audit")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--facts", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--paths-file")
    return parser.parse_args()


def grade_for(score: int) -> str:
    if score >= 90:
        return "A"
    if score >= 80:
        return "B"
    if score >= 70:
        return "C"
    if score >= 60:
        return "D"
    return "F"


def threshold_for(config: dict[str, Any], path: str, key: str) -> int:
    thresholds = config.get("thresholds", {})
    value = thresholds.get(key)
    overrides = config.get("overrides", {})
    for pattern, override in overrides.items():
        regex = re.compile("^" + pattern.replace(".", r"\.").replace("*", ".*") + "$")
        if regex.search(path):
            value = override.get(key, value)
    return int(value)


def excluded(config: dict[str, Any], path: str) -> bool:
    patterns = config.get("exclude", [])
    for pattern in patterns:
        regex = re.compile("^" + pattern.replace(".", r"\.").replace("*", ".*") + "$")
        if regex.search(path):
            return True
    return False


def weight_for(config: dict[str, Any], key: str) -> int:
    return int(config.get("weights", {}).get(key, 5))


def nesting_depth(content: str) -> int:
    depth = 0
    max_depth = 0
    for character in content:
        if character == "{":
            depth += 1
            max_depth = max(max_depth, depth)
        elif character == "}":
            depth = max(0, depth - 1)
    return max_depth


def pass_through_wrappers(content: str, language: str) -> list[int]:
    wrappers: list[int] = []
    if language == "swift":
        regex = re.compile(
            r"^\s*func\s+[A-Za-z_][A-Za-z0-9_]*[^{]*\{\s*\n\s*(?:return\s+)?[A-Za-z_][A-Za-z0-9_\.]*\([^\n]*\)\s*\n\s*\}",
            re.MULTILINE,
        )
    elif language == "rust":
        regex = re.compile(
            r"^\s*(?:pub\s+)?fn\s+[A-Za-z_][A-Za-z0-9_]*[^{]*\{\s*\n\s*(?:return\s+)?[A-Za-z_][A-Za-z0-9_:]*\([^\n]*\);\s*\n\s*\}",
            re.MULTILINE,
        )
    else:
        return wrappers
    for match in regex.finditer(content):
        wrappers.append(content[: match.start()].count("\n") + 1)
    return wrappers


def main() -> None:
    ensure_python()
    args = parse_args()
    repo_root = pathlib.Path(args.repo_root).resolve()
    facts = load_json(pathlib.Path(args.facts), default={})
    config = load_yaml(pathlib.Path(args.config))

    score = 100
    deductions: list[Violation] = []
    for module in facts["modules"]:
        is_primary_code = module["category"] in {"swift_source", "rust_source"}
        is_verifier_surface = module["path"].startswith("scripts/verify/") or module["path"].startswith(".verifier/")
        if not (is_primary_code or is_verifier_surface):
            continue
        if excluded(config, module["path"]):
            continue
        path = repo_root / module["path"]
        content = read_text(path)

        file_length_threshold = threshold_for(config, module["path"], "file_length")
        if module["line_count"] > file_length_threshold:
            score -= weight_for(config, "file_length")
            deductions.append(
                Violation(
                    layer="3",
                    rule="file_length",
                    path=module["path"],
                    line=None,
                    message="File length exceeds elegance threshold",
                    diagnosis=f"{module['path']} has {module['line_count']} lines (limit {file_length_threshold}).",
                    severity="warning",
                )
            )

        if module["language"] in {"rust", "swift", "python"}:
            analysis = lizard.analyze_file(str(path))
            function_length_threshold = threshold_for(config, module["path"], "function_length")
            complexity_threshold = threshold_for(config, module["path"], "cyclomatic_complexity")
            parameter_threshold = threshold_for(config, module["path"], "parameter_count")
            nesting_threshold = threshold_for(config, module["path"], "nesting_depth")

            if nesting_depth(content) > nesting_threshold:
                score -= weight_for(config, "nesting_depth")
                deductions.append(
                    Violation(
                        layer="3",
                        rule="nesting_depth",
                        path=module["path"],
                        line=None,
                        message="Nesting depth exceeds elegance threshold",
                        diagnosis=f"{module['path']} nesting depth exceeds {nesting_threshold}.",
                        severity="warning",
                    )
                )

            for function in analysis.function_list:
                if function.length > function_length_threshold:
                    score -= weight_for(config, "function_length")
                    deductions.append(
                        Violation(
                            layer="3",
                            rule="function_length",
                            path=module["path"],
                            line=function.start_line,
                            message="Function length exceeds elegance threshold",
                            diagnosis=f"{function.name} is {function.length} lines (limit {function_length_threshold}).",
                            severity="warning",
                        )
                    )
                if function.cyclomatic_complexity > complexity_threshold:
                    score -= weight_for(config, "cyclomatic_complexity")
                    deductions.append(
                        Violation(
                            layer="3",
                            rule="cyclomatic_complexity",
                            path=module["path"],
                            line=function.start_line,
                            message="Cyclomatic complexity exceeds elegance threshold",
                            diagnosis=f"{function.name} complexity is {function.cyclomatic_complexity} (limit {complexity_threshold}).",
                            severity="warning",
                        )
                    )
                if function.parameter_count > parameter_threshold:
                    score -= weight_for(config, "parameter_count")
                    deductions.append(
                        Violation(
                            layer="3",
                            rule="parameter_count",
                            path=module["path"],
                            line=function.start_line,
                            message="Parameter count exceeds elegance threshold",
                            diagnosis=f"{function.name} has {function.parameter_count} parameters (limit {parameter_threshold}).",
                            severity="warning",
                        )
                    )

            if module["path"].startswith("scripts/verify/") or module["path"].startswith(".verifier/"):
                for wrapper_line in pass_through_wrappers(content, module["language"]):
                    score -= weight_for(config, "craft")
                    deductions.append(
                        Violation(
                            layer="3",
                            rule="craft_pass_through_wrapper",
                            path=module["path"],
                            line=wrapper_line,
                            message="Pass-through wrapper detected",
                            diagnosis="Thin forwarding wrappers make ownership harder for coding agents to read.",
                            severity="warning",
                        )
                    )

        if module["language"] == "yaml" and module["path"].startswith(".verifier/"):
            if "TODO" in content or "FIXME" in content:
                score -= weight_for(config, "craft")
                deductions.append(
                    Violation(
                        layer="3",
                        rule="craft_unfinished_verifier_config",
                        path=module["path"],
                        line=None,
                        message="Verifier config contains unfinished markers",
                        diagnosis="Verifier config should be production-ready and free of TODO/FIXME residue.",
                        severity="warning",
                    )
                )

    score = max(0, score)
    grade = grade_for(score)
    minimum_grade = str(config.get("minimum_grade", "B"))
    passed = GRADE_ORDER.index(grade) >= GRADE_ORDER.index(minimum_grade)
    payload = build_layer_payload(
        violations=deductions,
        status="passed" if passed else "violated",
        extra={
            "score": score,
            "grade": grade,
            "minimum_grade": minimum_grade,
        },
    )
    payload["passed"] = passed
    write_json_atomic(pathlib.Path(args.out), payload)
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
