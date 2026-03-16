from __future__ import annotations


def contract(rule: str, proofs: list[str], *, tla_specs: list[str] | None = None) -> dict[str, object]:
    return {
        "rule": rule,
        "proofs": proofs,
        "tla_specs": tla_specs or [],
    }
