"""Receipt-first AgentEvent normalization for the smallest Circuit surface."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Mapping


MARKER = "CIRCUIT_RECEIPT"
NORMALIZATION_MODE = "headless_receipt_normalizer"
ALLOWED_RECEIPT_STATUSES = {"completed", "blocked", "failed"}
CAPTURED_ADAPTER_STATUSES = {"native_capture_complete", "native_capture_with_nonzero_exit"}
ALLOWED_SESSION_HOSTS = {"codex", "claude_code"}


class NormalizationError(Exception):
    """Raised when raw receipt text cannot be normalized into one AgentEvent."""


def parse_receipt_block(raw_receipt_text: str) -> dict[str, Any]:
    """Parse one visible CIRCUIT_RECEIPT block into its receipt JSON object."""
    lines = [line for line in raw_receipt_text.splitlines() if line.strip()]
    if not lines:
        raise NormalizationError("Raw receipt is empty.")
    if lines[0].strip() != MARKER:
        raise NormalizationError(f"Raw receipt must start with {MARKER}.")

    payload_text = "\n".join(lines[1:]).strip()
    try:
        receipt = json.loads(payload_text)
    except json.JSONDecodeError as error:
        raise NormalizationError(
            f"Invalid receipt JSON: line {error.lineno} column {error.colno}: {error.msg}"
        ) from error
    if not isinstance(receipt, dict):
        raise NormalizationError("Receipt payload must be an object.")
    return receipt


def require_fields(value: Mapping[str, Any], fields: list[str], label: str) -> None:
    missing = [field for field in fields if field not in value]
    if missing:
        raise NormalizationError(f"{label} missing required fields: {', '.join(missing)}")


def validate_inputs(receipt: Mapping[str, Any], adapter_result: Mapping[str, Any], source_raw_receipt_path: Path) -> None:
    require_fields(
        receipt,
        ["kind", "id", "goal_packet_id", "status", "summary", "evidence", "changed_paths", "open_risks", "next_action"],
        "receipt",
    )
    require_fields(adapter_result, ["kind", "status", "finished_at", "goal_packet_id"], "adapter_result")

    if receipt["kind"] != "receipt":
        raise NormalizationError(f"receipt.kind must be receipt, got {receipt['kind']!r}")
    if receipt["status"] not in ALLOWED_RECEIPT_STATUSES:
        raise NormalizationError(
            f"receipt.status must be one of {sorted(ALLOWED_RECEIPT_STATUSES)}, got {receipt['status']!r}"
        )
    if adapter_result["kind"] != "native_receipt_first_proof_result":
        raise NormalizationError(f"adapter_result.kind is not supported: {adapter_result['kind']!r}")
    if adapter_result["status"] not in CAPTURED_ADAPTER_STATUSES:
        raise NormalizationError(f"adapter_result.status is not a captured receipt: {adapter_result['status']!r}")
    if "agent_exit_code" not in adapter_result and "codex_exit_code" not in adapter_result:
        raise NormalizationError("adapter_result missing required field: agent_exit_code or codex_exit_code")
    host = adapter_result.get("host", "codex")
    if host not in ALLOWED_SESSION_HOSTS:
        raise NormalizationError(f"adapter_result.host must be one of {sorted(ALLOWED_SESSION_HOSTS)}, got {host!r}")
    if receipt["goal_packet_id"] != adapter_result["goal_packet_id"]:
        raise NormalizationError(
            "receipt.goal_packet_id must match adapter_result.goal_packet_id: "
            f"{receipt['goal_packet_id']!r} != {adapter_result['goal_packet_id']!r}"
        )

    capture = adapter_result.get("capture")
    if not isinstance(capture, Mapping) or capture.get("raw_receipt_path") != str(source_raw_receipt_path.resolve()):
        raise NormalizationError("adapter_result.capture.raw_receipt_path must point at the raw receipt being normalized")


def stable_session_id(adapter_result: Mapping[str, Any], source_raw_receipt_path: Path) -> str:
    seed = "|".join(
        [
            str(adapter_result["goal_packet_id"]),
            str(adapter_result["finished_at"]),
            str(source_raw_receipt_path.resolve()),
            str(adapter_result.get("visible_surface", "")),
        ]
    )
    return "session-receipt-" + hashlib.sha256(seed.encode("utf-8")).hexdigest()[:16]


def normalize_agent_event(
    raw_receipt_text: str,
    adapter_result: Mapping[str, Any],
    source_raw_receipt_path: str | Path,
) -> dict[str, Any]:
    """Normalize one raw receipt block and adapter result into one AgentEvent."""
    source_path = Path(source_raw_receipt_path).resolve()
    receipt = parse_receipt_block(raw_receipt_text)
    validate_inputs(receipt, adapter_result, source_path)

    return {
        "kind": "agent_event",
        "id": f"event-{receipt['id']}",
        "goal_packet_id": receipt["goal_packet_id"],
        "session": {
            "host": adapter_result.get("host", "codex"),
            "session_id": stable_session_id(adapter_result, source_path),
            "visible_to_owner": True,
        },
        "type": "receipt",
        "payload": receipt,
        "recorded_at": adapter_result["finished_at"],
        "normalization": {
            "mode": NORMALIZATION_MODE,
            "source_raw_receipt_path": str(source_path),
            "circuit_runtime_invoked": False,
        },
    }
