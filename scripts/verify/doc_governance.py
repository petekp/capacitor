from __future__ import annotations

import pathlib
import re
from typing import Any

from verifier_common import Violation, list_repo_files, normalize_patterns, read_text, recursive_glob_match, utc_now


DOC_ROLE_PATTERN = re.compile(r"^\s*(?:>\s*|#\s*)Doc role: `([^`]+)`\s*$", re.MULTILINE)
ARCHITECTURE_AUTHORITY_PATTERNS = [
    re.compile(r"\barchitecture source of truth\b", re.IGNORECASE),
    re.compile(r"\bsource of truth for the active app architecture\b", re.IGNORECASE),
    re.compile(r"\bcurrent architecture truth\b", re.IGNORECASE),
    re.compile(r"\bauthoritative current architecture\b", re.IGNORECASE),
]
CANONICAL_ROLES = {
    "agent-entrypoint",
    "canonical-spec",
    "canonical-rationale",
    "recent-deltas",
    "generated-aid",
}
HISTORICAL_WARNING = "Do not treat this as the current architecture spec."


def doc_role_for(content: str) -> str | None:
    match = DOC_ROLE_PATTERN.search(content)
    return match.group(1) if match else None


def doc_governance_config(config: dict[str, Any]) -> dict[str, Any]:
    return config.get("meta", {}).get("doc_governance") or {}


def expected_role_map(config: dict[str, Any]) -> dict[str, str]:
    governance = doc_governance_config(config)
    roles: dict[str, str] = {}

    if governance.get("primer"):
        roles[str(governance["primer"])] = "agent-entrypoint"
    if governance.get("spec"):
        roles[str(governance["spec"])] = "canonical-spec"
    if governance.get("rationale"):
        roles[str(governance["rationale"])] = "canonical-rationale"
    if governance.get("recent_deltas"):
        roles[str(governance["recent_deltas"])] = "recent-deltas"
    if governance.get("generated_aid"):
        roles[str(governance["generated_aid"])] = "generated-aid"

    for path in normalize_patterns(governance.get("support_docs")):
        roles[path] = "task-runbook"

    return roles


def markdown_paths_matching(repo_root: pathlib.Path, patterns: list[str]) -> list[str]:
    matches: list[str] = []
    for path in list_repo_files(repo_root):
        relative = str(path.relative_to(repo_root)).replace("\\", "/")
        if path.suffix.lower() != ".md":
            continue
        if any(recursive_glob_match(relative, pattern) for pattern in patterns):
            matches.append(relative)
    return sorted(set(matches))


def section_between(text: str, heading: str, next_heading: str | None = None) -> str:
    marker = f"## {heading}"
    if marker not in text:
        return ""
    section = text.split(marker, 1)[1]
    if next_heading:
        next_marker = f"## {next_heading}"
        if next_marker in section:
            section = section.split(next_marker, 1)[0]
    return section


def backticked_paths(section: str) -> list[str]:
    return re.findall(r"`([^`]+)`", section)


def render_architecture_packet_content(
    *,
    canonical_docs: list[str],
    recent_deltas_doc: str,
    historical_globs: list[str],
    archived_globs: list[str],
) -> str:
    canonical_labels = {
        0: "agent entrypoint",
        1: "current-state spec",
        2: "accepted rationale",
    }

    historical_roots = []
    for pattern in historical_globs + archived_globs:
        root = pattern.replace("/**/*.md", "/").replace("/**", "/")
        if root not in historical_roots:
            historical_roots.append(root)

    lines = [
        "# Architecture Packet",
        "",
        "> Doc role: `generated-aid`",
        "> Status: Generated aid only. Do not treat this as the current architecture spec.",
        f"> Generated: {utc_now()}",
        "",
        "This packet is a support artifact for coding-agent bootstrap. Checked-in authority lives in the primer, the current-state spec, and the accepted rationale doc.",
        "",
        "## Canonical Read Path",
        "",
    ]

    for index, path in enumerate(canonical_docs, start=1):
        label = canonical_labels.get(index - 1, "canonical doc")
        lines.append(f"{index}. `{path}` - {label}")

    lines.extend(
        [
            "",
            "## Recent Deltas",
            "",
            f"- `{recent_deltas_doc}` - recent migration context and retired seams to avoid resurrecting",
            "",
            "## Historical Evidence",
            "",
        ]
    )

    for root in historical_roots:
        lines.append(f"- `{root}`")

    lines.append("")
    return "\n".join(lines)


def validate_architecture_packet_content(
    content: str,
    *,
    canonical_docs: list[str],
    recent_deltas_doc: str,
    path: str | None = None,
) -> list[Violation]:
    violations: list[Violation] = []
    packet_path = path or ".verifier/reports/architecture-packet.md"

    if doc_role_for(content) != "generated-aid":
        violations.append(
            Violation(
                layer="1",
                rule="architecture_packet_role_mismatch",
                path=packet_path,
                line=None,
                message="Architecture packet role marker drifted",
                diagnosis="The generated packet no longer identifies itself as a generated aid.",
                fix="Restore the generated-aid role header.",
            )
        )

    canonical_section = section_between(content, "Canonical Read Path", "Recent Deltas")
    canonical_paths = [path for path in backticked_paths(canonical_section) if path in canonical_docs or path == recent_deltas_doc]
    if canonical_paths != canonical_docs:
        violations.append(
            Violation(
                layer="1",
                rule="architecture_packet_canonical_path_drift",
                path=packet_path,
                line=None,
                message="Architecture packet canonical read path drifted",
                diagnosis=f"The packet canonical read path is {canonical_paths!r}, expected {canonical_docs!r}.",
                fix="Render the packet from the primer/spec/ADR hierarchy only.",
            )
        )

    recent_section = section_between(content, "Recent Deltas", "Historical Evidence")
    recent_paths = backticked_paths(recent_section)
    if recent_deltas_doc not in recent_paths:
        violations.append(
            Violation(
                layer="1",
                rule="architecture_packet_recent_deltas_missing",
                path=packet_path,
                line=None,
                message="Architecture packet lost the recent-deltas link",
                diagnosis=f"The packet recent-deltas section does not mention {recent_deltas_doc}.",
                fix="Restore the changelog path in the Recent Deltas section.",
            )
        )

    return violations


def write_architecture_packet(repo_root: pathlib.Path, config: dict[str, Any]) -> tuple[str, str]:
    governance = doc_governance_config(config)
    canonical_docs = normalize_patterns(config.get("meta", {}).get("canonical_docs"))
    recent_deltas_doc = str(governance["recent_deltas"])
    packet_path = str(governance["generated_aid"])
    content = render_architecture_packet_content(
        canonical_docs=canonical_docs,
        recent_deltas_doc=recent_deltas_doc,
        historical_globs=normalize_patterns(governance.get("historical_globs")),
        archived_globs=normalize_patterns(governance.get("archived_globs")),
    )

    destination = repo_root / packet_path
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(content)
    return packet_path, content


def expected_role_violations(repo_root: pathlib.Path, expected_roles: dict[str, str]) -> list[Violation]:
    violations: list[Violation] = []
    for path, expected_role in expected_roles.items():
        document = repo_root / path
        if not document.exists():
            violations.append(
                Violation(
                    layer="1",
                    rule="doc_role_mismatch",
                    path=path,
                    line=None,
                    message="Expected architecture doc is missing",
                    diagnosis=f"{path} is missing; expected role {expected_role}.",
                    fix="Restore the document or update doc_governance intentionally.",
                )
            )
            continue

        role = doc_role_for(read_text(document))
        if role != expected_role:
            violations.append(
                Violation(
                    layer="1",
                    rule="doc_role_mismatch",
                    path=path,
                    line=None,
                    message="Architecture doc role marker drifted",
                    diagnosis=f"{path} declares role {role!r}; expected {expected_role!r}.",
                    fix="Restore the expected Doc role header.",
                )
            )
    return violations


def repo_markdown_paths(repo_root: pathlib.Path) -> list[str]:
    return [
        str(path.relative_to(repo_root)).replace("\\", "/")
        for path in list_repo_files(repo_root)
        if path.suffix.lower() == ".md"
    ]


def unexpected_canonical_role_violations(
    repo_root: pathlib.Path,
    markdown_paths: list[str],
    expected_roles: dict[str, str],
) -> list[Violation]:
    violations: list[Violation] = []
    canonical_role_owners = {path for path, role in expected_roles.items() if role in CANONICAL_ROLES}
    for path in markdown_paths:
        role = doc_role_for(read_text(repo_root / path))
        if role in CANONICAL_ROLES and path not in canonical_role_owners:
            violations.append(
                Violation(
                    layer="1",
                    rule="unexpected_canonical_doc_role",
                    path=path,
                    line=None,
                    message="Non-canonical doc claimed a canonical architecture role",
                    diagnosis=f"{path} declares canonical role {role!r} outside the approved hierarchy.",
                    fix="Downgrade the role marker or move the doc into the approved hierarchy intentionally.",
                )
            )
    return violations


def read_order_violations(repo_root: pathlib.Path, canonical_docs: list[str]) -> list[Violation]:
    violations: list[Violation] = []
    if not canonical_docs:
        return violations

    primer = repo_root / canonical_docs[0]
    primer_text = read_text(primer)
    positions = [primer_text.find(path) for path in canonical_docs]
    if any(position == -1 for position in positions) or positions != sorted(positions):
        violations.append(
            Violation(
                layer="1",
                rule="canonical_read_order_link_drift",
                path=canonical_docs[0],
                line=None,
                message="Primer read order drifted",
                diagnosis="The primer no longer links the primer/spec/ADR read path in order.",
                fix="Restore the ordered primer/spec/ADR read path in the primer.",
            )
        )

    if len(canonical_docs) < 3:
        return violations

    spec_text = read_text(repo_root / canonical_docs[1])
    if canonical_docs[0] not in spec_text or canonical_docs[2] not in spec_text:
        violations.append(
            Violation(
                layer="1",
                rule="canonical_read_order_link_drift",
                path=canonical_docs[1],
                line=None,
                message="Architecture spec backlinks drifted",
                diagnosis="The spec no longer points back to the primer and rationale docs.",
                fix="Restore primer and ADR backlinks in the spec header.",
            )
        )

    rationale_text = read_text(repo_root / canonical_docs[2])
    if canonical_docs[0] not in rationale_text or canonical_docs[1] not in rationale_text:
        violations.append(
            Violation(
                layer="1",
                rule="canonical_read_order_link_drift",
                path=canonical_docs[2],
                line=None,
                message="ADR backlinks drifted",
                diagnosis="The rationale doc no longer points back to the primer and current-state spec.",
                fix="Restore primer and spec backlinks in the ADR header.",
            )
        )
    return violations


def non_canonical_authority_violations(
    repo_root: pathlib.Path,
    markdown_paths: list[str],
    canonical_docs: list[str],
    packet_path: str,
) -> list[Violation]:
    violations: list[Violation] = []
    non_canonical_docs = set(markdown_paths) - set(canonical_docs) - {packet_path}
    for path in sorted(non_canonical_docs):
        content = read_text(repo_root / path)
        if any(pattern.search(content) for pattern in ARCHITECTURE_AUTHORITY_PATTERNS):
            violations.append(
                Violation(
                    layer="1",
                    rule="non_canonical_doc_claims_architecture_authority",
                    path=path,
                    line=None,
                    message="Non-canonical doc claims architecture authority",
                    diagnosis=f"{path} still presents itself as part of the architecture source-of-truth surface.",
                    fix="Point to the primer/spec instead of restating architecture authority here.",
                )
            )
    return violations


def historical_header_violations(
    repo_root: pathlib.Path,
    *,
    historical_globs: list[str],
    archived_globs: list[str],
) -> list[Violation]:
    violations: list[Violation] = []
    for path in markdown_paths_matching(repo_root, historical_globs):
        content = read_text(repo_root / path)
        if doc_role_for(content) != "historical-evidence" or HISTORICAL_WARNING not in content:
            violations.append(
                Violation(
                    layer="1",
                    rule="historical_doc_missing_historical_header",
                    path=path,
                    line=None,
                    message="Historical evidence doc is missing its warning header",
                    diagnosis=f"{path} is in a historical-evidence directory but does not carry the required warning header.",
                    fix="Add the historical-evidence role marker and warning banner.",
                )
            )

    for path in markdown_paths_matching(repo_root, archived_globs):
        content = read_text(repo_root / path)
        if doc_role_for(content) != "historical-evidence" or "Archived." not in content or HISTORICAL_WARNING not in content:
            violations.append(
                Violation(
                    layer="1",
                    rule="archived_doc_missing_historical_header",
                    path=path,
                    line=None,
                    message="Archived architecture doc is missing its archive header",
                    diagnosis=f"{path} is archived but does not carry the required archive warning header.",
                    fix="Add the archived historical-evidence header and backlink to the current read path.",
                )
            )
    return violations


def doc_governance_violations(repo_root: pathlib.Path, config: dict[str, Any]) -> list[Violation]:
    governance = doc_governance_config(config)
    if not governance:
        return []

    canonical_docs = normalize_patterns(config.get("meta", {}).get("canonical_docs"))
    recent_deltas_doc = str(governance["recent_deltas"])
    packet_path, packet_content = write_architecture_packet(repo_root, config)

    expected_roles = expected_role_map(config)
    expected_roles[packet_path] = "generated-aid"
    markdown_paths = repo_markdown_paths(repo_root)

    violations = expected_role_violations(repo_root, expected_roles)
    violations.extend(unexpected_canonical_role_violations(repo_root, markdown_paths, expected_roles))
    violations.extend(read_order_violations(repo_root, canonical_docs))
    violations.extend(non_canonical_authority_violations(repo_root, markdown_paths, canonical_docs, packet_path))
    violations.extend(
        historical_header_violations(
            repo_root,
            historical_globs=normalize_patterns(governance.get("historical_globs")),
            archived_globs=normalize_patterns(governance.get("archived_globs")),
        )
    )

    violations.extend(
        validate_architecture_packet_content(
            packet_content,
            canonical_docs=canonical_docs,
            recent_deltas_doc=recent_deltas_doc,
            path=packet_path,
        )
    )
    return violations
