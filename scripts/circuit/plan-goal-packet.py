#!/usr/bin/env python3
"""Plan one receipt-first PursuitProposal and GoalPacket from one Idea."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from circuit_protocol import PlanningError, plan_goal_packet, plan_goal_packet_response  # noqa: E402


DEFAULT_IDEA = ROOT / "docs/circuit/proofs/receipt-first-fixture/01-idea.json"
DEFAULT_PROPOSAL_OUTPUT = ROOT / "docs/circuit/proofs/receipt-first-fixture/02-pursuit-proposal.json"
DEFAULT_GOAL_PACKET_OUTPUT = ROOT / "docs/circuit/proofs/receipt-first-fixture/03-goal-packet.json"


def load_json_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError as error:
        raise PlanningError(f"Missing JSON artifact: {path}") from error
    except json.JSONDecodeError as error:
        raise PlanningError(f"Invalid JSON in {path}: line {error.lineno} column {error.colno}: {error.msg}") from error
    if not isinstance(value, dict):
        raise PlanningError(f"JSON artifact must be an object: {path}")
    return value


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=False) + "\n")


def plan_from_file(idea_path: Path, target_agent: str) -> dict[str, dict[str, Any]]:
    idea = load_json_object(idea_path)
    return plan_goal_packet(idea, target_agent=target_agent)


def plan_from_stdin(target_agent: str) -> dict[str, Any]:
    try:
        request = json.loads(sys.stdin.read())
    except json.JSONDecodeError as error:
        raise PlanningError(f"Invalid JSON on stdin: line {error.lineno} column {error.colno}: {error.msg}") from error
    if not isinstance(request, dict):
        raise PlanningError("stdin request must be a JSON object")
    if request.get("kind") != "plan_goal_packet_request":
        raise PlanningError("stdin request kind must be plan_goal_packet_request")
    idea = request.get("idea")
    if not isinstance(idea, dict):
        raise PlanningError("stdin request must include idea object")
    request_target_agent = request.get("target_agent", target_agent)
    if not isinstance(request_target_agent, str):
        raise PlanningError("target_agent must be a string")
    return plan_goal_packet_response(idea, target_agent=request_target_agent)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--idea", type=Path, default=DEFAULT_IDEA)
    parser.add_argument("--proposal-output", type=Path, default=DEFAULT_PROPOSAL_OUTPUT)
    parser.add_argument("--goal-packet-output", type=Path, default=DEFAULT_GOAL_PACKET_OUTPUT)
    parser.add_argument("--target-agent", default="codex")
    parser.add_argument("--stdin", action="store_true", help="Read a plan_goal_packet_request from stdin and write one response JSON object.")
    parser.add_argument("--check", action="store_true", help="Fail if existing outputs do not match planned JSON.")
    args = parser.parse_args()

    try:
        if args.stdin:
            response = plan_from_stdin(args.target_agent)
            sys.stdout.write(json.dumps(response, indent=2, sort_keys=False) + "\n")
            return 0

        planned = plan_from_file(args.idea, args.target_agent)
        proposal = planned["pursuit_proposal"]
        goal_packet = planned["goal_packet"]

        if args.check:
            existing_proposal = load_json_object(args.proposal_output)
            existing_goal_packet = load_json_object(args.goal_packet_output)
            if existing_proposal != proposal or existing_goal_packet != goal_packet:
                sys.stderr.write("receipt-first proposal or goal packet is stale; rerun plan-goal-packet.py without --check.\n")
                return 1
        else:
            write_json(args.proposal_output, proposal)
            write_json(args.goal_packet_output, goal_packet)

        sys.stdout.write(json.dumps(planned, indent=2, sort_keys=False) + "\n")
        return 0
    except PlanningError as error:
        sys.stderr.write(f"plan-goal-packet: {error}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
