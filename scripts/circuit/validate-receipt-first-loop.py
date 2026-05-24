#!/usr/bin/env python3
"""Validate the Capacitor-owned receipt-first product loop artifacts."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
PROOF = ROOT / "docs/circuit/proofs/receipt-first-product-loop"
MARKER = "CIRCUIT_RECEIPT"


class ValidationFailure(Exception):
    pass


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError as error:
        raise ValidationFailure(f"missing JSON artifact: {path}") from error
    except json.JSONDecodeError as error:
        raise ValidationFailure(f"invalid JSON in {path}: line {error.lineno} column {error.colno}: {error.msg}") from error
    if not isinstance(value, dict):
        raise ValidationFailure(f"JSON artifact must be an object: {path}")
    return value


def load_text(path: Path) -> str:
    try:
        return path.read_text()
    except FileNotFoundError as error:
        raise ValidationFailure(f"missing text artifact: {path}") from error


def require_fields(value: dict[str, Any], fields: list[str], label: str) -> None:
    missing = [field for field in fields if field not in value]
    if missing:
        raise ValidationFailure(f"{label} missing required fields: {', '.join(missing)}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationFailure(message)


def validate_no_old_runtime_path() -> list[dict[str, str]]:
    checked: list[dict[str, str]] = []
    old_tokens = ["/Users/petepetrash/Code/capacitor-circuit", "CAPACITOR_CIRCUIT_ROOT", "capacitorCircuitRoot"]
    source_paths = [
        ROOT / "apps/swift/Sources/Capacitor/Debug/CircuitReceiptProductLoop.swift",
        ROOT / "apps/swift/Sources/Capacitor/Debug/ReceiptFirstProofAdapter.swift",
        ROOT / "apps/swift/Sources/Capacitor/Debug/ReceiptProofRendering.swift",
        ROOT / "apps/swift/Sources/Capacitor/Features/CircuitFirstSliceCommands.swift",
    ]
    for path in source_paths:
        text = load_text(path)
        for token in old_tokens:
            require(token not in text, f"old capacitor-circuit runtime token remains in {path}: {token}")
        checked.append({"path": str(path.relative_to(ROOT)), "evidence": "no old capacitor-circuit runtime path tokens"})
    return checked


def validate_artifacts() -> list[dict[str, str]]:
    checked: list[dict[str, str]] = []
    paths = {
        "source_idea": PROOF / "planning/01-capacitor-idea-source.json",
        "idea": PROOF / "planning/02-contract-idea.json",
        "planning_request": PROOF / "planning/03-planning-request.json",
        "planning_response": PROOF / "planning/04-planning-response.json",
        "goal_packet": PROOF / "planning/05-goal-packet.json",
        "inserted_body": PROOF / "native-session/03-native-inserted-goal-body.txt",
        "transcript": PROOF / "native-session/04-native-visible-session-transcript.txt",
        "raw_receipt": PROOF / "native-session/06-native-captured-raw-receipt.txt",
        "adapter_result": PROOF / "native-session/07-native-adapter-result.json",
        "normalization_request": PROOF / "normalization/00-normalization-request.json",
        "agent_event": PROOF / "normalization/01-agent-event.json",
    }

    source_idea = load_json(paths["source_idea"])
    idea = load_json(paths["idea"])
    planning_request = load_json(paths["planning_request"])
    planning_response = load_json(paths["planning_response"])
    goal_packet = load_json(paths["goal_packet"])
    inserted_body = load_text(paths["inserted_body"])
    transcript = load_text(paths["transcript"])
    raw_receipt_text = load_text(paths["raw_receipt"])
    adapter_result = load_json(paths["adapter_result"])
    normalization_request = load_json(paths["normalization_request"])
    agent_event = load_json(paths["agent_event"])

    require_fields(source_idea, ["kind", "id", "title", "description", "project_path"], "source_idea")
    require(source_idea["kind"] == "capacitor_captured_idea", "source_idea must be a Capacitor-captured idea")
    require(Path(str(source_idea["project_path"])).resolve() == ROOT.resolve(), "source_idea must target this Capacitor repo")
    checked.append({"path": str(paths["source_idea"].relative_to(ROOT)), "evidence": "Capacitor idea source targets this repo"})

    require_fields(idea, ["kind", "id", "project", "text"], "idea")
    require(idea["kind"] == "idea", "contract idea kind must be idea")
    require(idea["project"]["path"] == str(ROOT), "contract idea project path must be Capacitor root")
    require("receipt-first Capacitor <-> Circuit slice" in idea["text"], "contract idea must be receipt-first")
    checked.append({"path": str(paths["idea"].relative_to(ROOT)), "evidence": "contract Idea is receipt-first and Capacitor-owned"})

    require(planning_request["kind"] == "plan_goal_packet_request", "planning request kind mismatch")
    require(planning_request["target_agent"] == "claude_code", "planning request must target claude_code")
    checked.append({"path": str(paths["planning_request"].relative_to(ROOT)), "evidence": "planning request targets Claude Code"})

    require(planning_response["kind"] == "plan_goal_packet_response", "planning response kind mismatch")
    require(planning_response["planning"]["mode"] == "headless_receipt_first_planner", "planning mode mismatch")
    require(planning_response["planning"]["circuit_runtime_invoked"] is False, "planning must not invoke Circuit runtime")
    checked.append({"path": str(paths["planning_response"].relative_to(ROOT)), "evidence": "headless planning response recorded"})

    require_fields(goal_packet, ["kind", "id", "idea_id", "pursuit_id", "target_agent", "project_path", "body", "expected_return"], "goal_packet")
    require(goal_packet == planning_response["goal_packet"], "goal packet artifact must match planning response")
    require(goal_packet["target_agent"] == "claude_code", "goal packet must target claude_code")
    require(goal_packet["project_path"] == str(ROOT), "goal packet project path must be Capacitor root")
    require(goal_packet["expected_return"] == "receipt", "goal packet must expect one receipt")
    require(MARKER in goal_packet["body"], "goal packet body must include visible receipt marker")
    require(inserted_body == goal_packet["body"], "inserted body must exactly match GoalPacket.body")
    checked.append({"path": str(paths["goal_packet"].relative_to(ROOT)), "evidence": "GoalPacket is Claude receipt-first and exactly inserted"})

    require("Claude Code CLI" in transcript, "transcript must show visible Claude Code CLI surface")
    require(MARKER in raw_receipt_text, "raw receipt must include marker")
    require(raw_receipt_text.lstrip().startswith(MARKER), "raw receipt must start with marker")
    checked.append({"path": str(paths["raw_receipt"].relative_to(ROOT)), "evidence": "raw CIRCUIT_RECEIPT preserved"})

    require(adapter_result["kind"] == "native_receipt_first_proof_result", "adapter result kind mismatch")
    require(adapter_result["status"] in {"native_capture_complete", "native_capture_with_nonzero_exit"}, "adapter result must be captured")
    require(adapter_result["host"] == "claude_code", "adapter result must be Claude Code")
    require(adapter_result["goal_packet_id"] == goal_packet["id"], "adapter result goal packet mismatch")
    require(adapter_result["injection"]["exact_body_match"] is True, "adapter must prove exact body insertion")
    require(adapter_result["capture"]["preserved_for_normalization"] is True, "adapter must preserve capture for normalization")
    require(Path(adapter_result["capture"]["raw_receipt_path"]).resolve() == paths["raw_receipt"].resolve(), "adapter raw receipt path mismatch")
    checked.append({"path": str(paths["adapter_result"].relative_to(ROOT)), "evidence": "adapter captured Claude receipt from Capacitor-owned path"})

    require(normalization_request["kind"] == "normalize_agent_event_request", "normalization request kind mismatch")
    require(normalization_request["raw_receipt_text"] == raw_receipt_text, "normalization request must preserve raw receipt text")
    require(normalization_request["adapter_result"] == adapter_result, "normalization request must preserve adapter result")
    checked.append({"path": str(paths["normalization_request"].relative_to(ROOT)), "evidence": "normalization request preserves raw inputs"})

    require(agent_event["kind"] == "agent_event", "AgentEvent kind mismatch")
    require(agent_event["type"] == "receipt", "AgentEvent must be receipt type")
    require(agent_event["session"]["host"] == "claude_code", "AgentEvent host must be Claude Code")
    require(agent_event["goal_packet_id"] == goal_packet["id"], "AgentEvent goal packet mismatch")
    require(agent_event["payload"]["goal_packet_id"] == goal_packet["id"], "receipt payload goal packet mismatch")
    require(agent_event["normalization"]["mode"] == "headless_receipt_normalizer", "normalization mode mismatch")
    require(agent_event["normalization"]["circuit_runtime_invoked"] is False, "normalization must not invoke Circuit runtime")
    require(Path(agent_event["normalization"]["source_raw_receipt_path"]).resolve() == paths["raw_receipt"].resolve(), "AgentEvent source receipt path mismatch")
    checked.append({"path": str(paths["agent_event"].relative_to(ROOT)), "evidence": "headless AgentEvent normalized from Claude receipt"})

    return checked


def validate() -> dict[str, Any]:
    checked = []
    checked.extend(validate_no_old_runtime_path())
    checked.extend(validate_artifacts())
    return {
        "kind": "capacitor_receipt_first_loop_validation_result",
        "status": "passed",
        "root": str(ROOT),
        "proof": str(PROOF),
        "check_count": len(checked),
        "checks": checked,
        "limits": [
            "Validates the Claude Code CLI receipt-first product loop only.",
            "Does not validate checkpoint relay, queues, retries, Cursor, or generalized session management.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", type=Path, help="Write the validation result JSON to this path.")
    args = parser.parse_args()

    try:
        result = validate()
    except ValidationFailure as error:
        failure = {
            "kind": "capacitor_receipt_first_loop_validation_result",
            "status": "failed",
            "root": str(ROOT),
            "proof": str(PROOF),
            "failure": str(error),
        }
        sys.stdout.write(json.dumps(failure, indent=2) + "\n")
        return 1

    if args.write:
        output_path = args.write if args.write.is_absolute() else ROOT / args.write
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(result, indent=2) + "\n")
    sys.stdout.write(json.dumps(result, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
