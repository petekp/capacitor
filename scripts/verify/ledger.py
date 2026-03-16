from __future__ import annotations

from typing import Any


def hard_structural_rules(structural_config: dict[str, Any]) -> list[dict[str, Any]]:
    rules: list[dict[str, Any]] = []
    for category, values in structural_config.items():
        if category == "meta":
            continue
        for rule in values or []:
            if str(rule.get("enforcement", "hard")) != "hard":
                continue
            hydrated = dict(rule)
            hydrated["category"] = category
            hydrated["claim_id"] = str(rule.get("claim_id", rule["rule"]))
            rules.append(hydrated)
    return rules


def hard_claim_ids(canonical_claims: dict[str, Any]) -> set[str]:
    return {
        str(claim["claim_id"])
        for claim in canonical_claims.get("claims", [])
        if str(claim.get("enforcement", "hard")) == "hard"
    }


def audit_ledger(
    *,
    structural_config: dict[str, Any],
    canonical_claims: dict[str, Any],
    ledger_config: dict[str, Any],
    spec_ids: list[str],
    repo_root=None,
) -> dict[str, Any]:
    claims_index = {
        str(claim["claim_id"]): claim
        for claim in canonical_claims.get("claims", [])
    }
    ledger_claims = {
        str(claim_id): value
        for claim_id, value in (ledger_config.get("claims", {}) or {}).items()
    }
    hard_rules = hard_structural_rules(structural_config)
    hard_rule_ids = {rule["rule"] for rule in hard_rules}
    hard_rule_claims = {rule["claim_id"] for rule in hard_rules}
    hard_claims = hard_claim_ids(canonical_claims)

    rule_to_claim = {}
    spec_to_claims = {spec_id: [] for spec_id in spec_ids}
    for claim_id, entry in ledger_claims.items():
        for rule_id in entry.get("structural_rules", []) or []:
            rule_to_claim[str(rule_id)] = claim_id
        for spec_id in entry.get("behavioral_specs", []) or []:
            spec_to_claims.setdefault(str(spec_id), []).append(claim_id)

    missing_claims = sorted(claim_id for claim_id in hard_claims if claim_id not in ledger_claims)
    orphaned_rules = sorted(rule_id for rule_id in hard_rule_ids if rule_id not in rule_to_claim)
    orphaned_specs = sorted(spec_id for spec_id, claims in spec_to_claims.items() if not claims)

    missing_positive_fixtures = []
    missing_negative_fixtures = []
    missing_fixture_artifacts = []
    claim_coverage: list[dict[str, Any]] = []
    for claim_id in sorted(hard_claims):
        entry = ledger_claims.get(claim_id, {})
        positive_fixtures = list(entry.get("positive_fixtures", []) or [])
        negative_fixtures = list(entry.get("negative_fixtures", []) or [])
        structural_rules = [str(rule_id) for rule_id in entry.get("structural_rules", []) or []]
        behavioral_specs = [str(spec_id) for spec_id in entry.get("behavioral_specs", []) or []]

        if not positive_fixtures:
            missing_positive_fixtures.append(claim_id)
        if not negative_fixtures:
            missing_negative_fixtures.append(claim_id)
        if repo_root is not None:
            referenced_paths = []
            for fixture in positive_fixtures + negative_fixtures:
                referenced_paths.append(str(fixture).split("#", 1)[0])
            if any(not (repo_root / referenced_path).exists() for referenced_path in referenced_paths):
                missing_fixture_artifacts.append(claim_id)

        claim_coverage.append(
            {
                "claim_id": claim_id,
                "description": claims_index.get(claim_id, {}).get("description"),
                "structural_rules": structural_rules,
                "behavioral_specs": behavioral_specs,
                "positive_fixtures": positive_fixtures,
                "negative_fixtures": negative_fixtures,
                "proof_artifact_count": len(structural_rules) + len(behavioral_specs),
            }
        )

    return {
        "missing_claims": missing_claims,
        "orphaned_rules": orphaned_rules,
        "orphaned_specs": orphaned_specs,
        "missing_positive_fixtures": sorted(missing_positive_fixtures),
        "missing_negative_fixtures": sorted(missing_negative_fixtures),
        "missing_fixture_artifacts": sorted(missing_fixture_artifacts),
        "claim_coverage": claim_coverage,
        "hard_rule_claims": sorted(hard_rule_claims),
    }
