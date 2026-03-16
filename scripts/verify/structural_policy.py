from __future__ import annotations

from typing import Any


ALLOWED_HARD_LAYER1_FACT_KINDS = frozenset(
    {
        "call_pattern",
        "contains_regex",
        "definition",
        "http_route",
        "identifier_ref",
        "implement",
        "import",
        "path_regex",
        "process_exec",
        "static_http_route",
        "reference",
        "shell_command_literal",
        "string_literal",
    }
)

FACT_CONFIDENCE = {
    "call_pattern": "medium",
    "contains_regex": "low",
    "definition": "medium",
    "doc_claim": "medium",
    "http_route": "high",
    "identifier_ref": "medium",
    "implement": "medium",
    "import": "medium",
    "path_regex": "high",
    "process_exec": "high",
    "reference": "medium",
    "shell_command_literal": "high",
    "static_http_route": "high",
    "string_literal": "high",
}


def flatten_rules(config: dict[str, Any]) -> list[dict[str, Any]]:
    rules: list[dict[str, Any]] = []
    for category, values in config.items():
        if category == "meta":
            continue
        for rule in values or []:
            hydrated = dict(rule)
            hydrated["category"] = category
            rules.append(hydrated)
    return rules


def fact_spec_for_rule(rule: dict[str, Any]) -> str | None:
    selector = rule.get("constraint", {})
    return selector.get("must_not") or selector.get("must") or selector.get("may")


def fact_kind_for_rule(rule: dict[str, Any]) -> str | None:
    fact_spec = fact_spec_for_rule(rule)
    if not fact_spec:
        return None
    return fact_spec.split(":", 1)[0]


def rule_layer(rule: dict[str, Any]) -> int:
    return int(rule.get("layer", 1))


def rule_enforcement(rule: dict[str, Any]) -> str:
    return str(rule.get("enforcement", "hard"))


def rule_decision(rule: dict[str, Any]) -> str:
    if rule_enforcement(rule) == "advisory":
        return "advisory"
    if rule_layer(rule) != 1:
        return "move_to_layer2"
    return "stay_in_layer1"


def build_rule_audit(config: dict[str, Any]) -> list[dict[str, Any]]:
    audit: list[dict[str, Any]] = []
    for rule in flatten_rules(config):
        fact_kind = fact_kind_for_rule(rule)
        layer = rule_layer(rule)
        enforcement = rule_enforcement(rule)
        audit.append(
            {
                "rule": rule["rule"],
                "category": rule["category"],
                "layer": layer,
                "enforcement": enforcement,
                "decision": rule_decision(rule),
                "fact_kind": fact_kind,
                "fact_spec": fact_spec_for_rule(rule),
                "confidence": FACT_CONFIDENCE.get(fact_kind, "unknown"),
                "layer1_sound": layer == 1 and enforcement == "hard" and fact_kind in ALLOWED_HARD_LAYER1_FACT_KINDS,
                "proof": rule.get("proof"),
            }
        )
    return audit


def layer1_policy_violations(config: dict[str, Any]) -> list[dict[str, Any]]:
    violations: list[dict[str, Any]] = []
    for entry in build_rule_audit(config):
        if entry["decision"] != "stay_in_layer1":
            continue
        if entry["layer1_sound"]:
            continue
        violations.append(
            {
                "rule": entry["rule"],
                "fact_kind": entry["fact_kind"],
                "message": "Hard Layer 1 rules must use sound evidence kinds",
                "diagnosis": (
                    f"Rule {entry['rule']} is still classified as hard Layer 1 but relies on "
                    f"{entry['fact_kind']}, which is not allowed for the correctness gate."
                ),
                "fix": "Re-express the rule with an allowed fact kind, move it to Layer 2, or mark it advisory.",
            }
        )
    return violations
