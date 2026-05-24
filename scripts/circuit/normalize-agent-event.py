#!/usr/bin/env python3
"""Normalize one preserved CIRCUIT_RECEIPT block into one AgentEvent artifact."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from circuit_protocol import NormalizationError, normalize_agent_event  # noqa: E402


DEFAULT_RAW_RECEIPT = ROOT / "docs/circuit/proofs/receipt-first-product-loop/native-session/06-native-captured-raw-receipt.txt"
DEFAULT_ADAPTER_RESULT = ROOT / "docs/circuit/proofs/receipt-first-product-loop/native-session/07-native-adapter-result.json"
DEFAULT_OUTPUT = ROOT / "docs/circuit/proofs/receipt-first-product-loop/normalization/01-agent-event.json"


def load_text(path: Path, label: str) -> str:
    try:
        return path.read_text()
    except FileNotFoundError as error:
        raise NormalizationError(f"Missing {label}: {path}") from error


def load_json_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError as error:
        raise NormalizationError(f"Missing JSON artifact: {path}") from error
    except json.JSONDecodeError as error:
        raise NormalizationError(
            f"Invalid JSON in {path}: line {error.lineno} column {error.colno}: {error.msg}"
        ) from error
    if not isinstance(value, dict):
        raise NormalizationError(f"JSON artifact must be an object: {path}")
    return value


def normalize_from_files(raw_receipt_path: Path, adapter_result_path: Path) -> dict[str, Any]:
    raw_receipt_path = raw_receipt_path.resolve()
    raw_receipt_text = load_text(raw_receipt_path, "raw receipt artifact")
    adapter_result = load_json_object(adapter_result_path)
    return normalize_agent_event(raw_receipt_text, adapter_result, raw_receipt_path)


def normalize_from_stdin() -> dict[str, Any]:
    try:
        request = json.loads(sys.stdin.read())
    except json.JSONDecodeError as error:
        raise NormalizationError(f"Invalid JSON on stdin: line {error.lineno} column {error.colno}: {error.msg}") from error
    if not isinstance(request, dict):
        raise NormalizationError("stdin request must be a JSON object")
    if request.get("kind") != "normalize_agent_event_request":
        raise NormalizationError("stdin request kind must be normalize_agent_event_request")
    raw_receipt_text = request.get("raw_receipt_text")
    adapter_result = request.get("adapter_result")
    source_raw_receipt_path = request.get("source_raw_receipt_path")
    if not isinstance(raw_receipt_text, str):
        raise NormalizationError("stdin request must include raw_receipt_text string")
    if not isinstance(adapter_result, dict):
        raise NormalizationError("stdin request must include adapter_result object")
    if not isinstance(source_raw_receipt_path, str):
        raise NormalizationError("stdin request must include source_raw_receipt_path string")
    return normalize_agent_event(raw_receipt_text, adapter_result, source_raw_receipt_path)


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=False) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-receipt", type=Path, default=DEFAULT_RAW_RECEIPT)
    parser.add_argument("--adapter-result", type=Path, default=DEFAULT_ADAPTER_RESULT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--stdin", action="store_true", help="Read a normalize_agent_event_request from stdin and write one AgentEvent JSON object.")
    parser.add_argument("--check", action="store_true", help="Fail if the existing output does not match generated JSON.")
    args = parser.parse_args()

    try:
        agent_event = normalize_from_stdin() if args.stdin else normalize_from_files(args.raw_receipt, args.adapter_result)
        if args.check:
            existing = load_json_object(args.output)
            if existing != agent_event:
                sys.stderr.write(f"{args.output} is stale; rerun {Path(__file__).name} without --check.\n")
                return 1
        else:
            write_json(args.output, agent_event)
        sys.stdout.write(json.dumps(agent_event, indent=2, sort_keys=False) + "\n")
        return 0
    except NormalizationError as error:
        sys.stderr.write(f"normalize-agent-event: {error}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
