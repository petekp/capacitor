from __future__ import annotations

import re
from typing import Any


def module_by_path(facts: dict[str, Any], path: str) -> dict[str, Any] | None:
    for module in facts.get("modules", []):
        if module["path"] == path:
            return module
    return None


def module_has_regex(module: dict[str, Any] | None, field: str, pattern: str) -> bool:
    if module is None:
        return False
    regex = re.compile(pattern)
    return any(regex.search(str(entry.get("value", ""))) for entry in module.get(field, []))


def violation(
    rule: str,
    message: str,
    diagnosis: str,
    *,
    path: str | None = None,
    line: int | None = None,
    fix: str | None = None,
) -> dict[str, Any]:
    return {
        "rule": rule,
        "message": message,
        "diagnosis": diagnosis,
        "path": path,
        "line": line,
        "fix": fix,
    }
