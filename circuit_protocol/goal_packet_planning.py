"""Receipt-first planning for the smallest headless Circuit surface."""

from __future__ import annotations

import re
from typing import Any, Mapping

from .agent_event_normalization import MARKER


PLANNING_MODE = "headless_receipt_first_planner"
SUPPORTED_TARGET_AGENT = "codex"
SUPPORTED_TARGET_AGENTS = {"codex", "claude_code"}
SUPPORTED_ID_PREFIX = "idea-"
SUPPORTED_ID_SUFFIX = "receipt-first-001"
SUPPORTED_IDEA_PHRASE = "receipt-first Capacitor <-> Circuit slice"


class PlanningError(Exception):
    """Raised when one captured Idea cannot become the receipt-first packet."""


def require_fields(value: Mapping[str, Any], fields: list[str], label: str) -> None:
    missing = [field for field in fields if get_path(value, field) is None]
    if missing:
        raise PlanningError(f"{label} missing required fields: {', '.join(missing)}")


def get_path(value: Mapping[str, Any], dotted_path: str) -> Any:
    current: Any = value
    for part in dotted_path.split("."):
        if not isinstance(current, Mapping) or part not in current:
            return None
        current = current[part]
    return current


def id_suffix_from_idea(idea_id: str) -> str:
    if not idea_id.startswith(SUPPORTED_ID_PREFIX):
        raise PlanningError(f"idea.id must start with {SUPPORTED_ID_PREFIX!r}")
    suffix = idea_id.removeprefix(SUPPORTED_ID_PREFIX)
    if suffix == SUPPORTED_ID_SUFFIX:
        return suffix

    normalized = re.sub(r"[^a-z0-9]+", "-", suffix.lower()).strip("-")
    if not normalized:
        raise PlanningError(f"unsupported receipt-first idea id: {idea_id!r}")
    return normalized[:48]


def validate_idea(idea: Mapping[str, Any]) -> None:
    require_fields(idea, ["kind", "id", "project.name", "project.path", "text"], "idea")
    if idea["kind"] != "idea":
        raise PlanningError(f"idea.kind must be idea, got {idea['kind']!r}")
    if SUPPORTED_IDEA_PHRASE not in str(idea["text"]):
        raise PlanningError("Only the receipt-first slice idea is supported by this planner.")


def plan_goal_packet(
    idea: Mapping[str, Any],
    *,
    target_agent: str = SUPPORTED_TARGET_AGENT,
) -> dict[str, dict[str, Any]]:
    """Return one deterministic PursuitProposal and GoalPacket for one Idea."""
    validate_idea(idea)
    if target_agent not in SUPPORTED_TARGET_AGENTS:
        raise PlanningError(f"Only {sorted(SUPPORTED_TARGET_AGENTS)!r} are supported by this proof planner.")

    suffix = id_suffix_from_idea(str(idea["id"]))
    pursuit_id = f"pursuit-{suffix}"
    goal_packet_id = f"goal-packet-{suffix}"
    project_path = str(get_path(idea, "project.path"))

    host_phrase = "one visible Codex session"
    if target_agent == "claude_code":
        host_phrase = "one visible Claude Code CLI session"
    idea_text = str(idea["text"]).strip()

    proposal_goal = f"Prove the receipt-first Capacitor <-> Circuit slice with one captured idea and {host_phrase} receipt."
    if target_agent == "codex" and suffix == SUPPORTED_ID_SUFFIX:
        proposal_goal = "Prove the receipt-first Capacitor <-> Circuit slice with one fixture-backed path and one visible Codex session receipt."

    pursuit_proposal = {
        "kind": "pursuit_proposal",
        "id": pursuit_id,
        "idea_id": idea["id"],
        "goal": proposal_goal,
        "why_now": "docs/circuit/receipt-first-product-loop.md defines the Claude Code CLI receipt loop as the smallest live product proof.",
        "dependencies": [
            "AGENTS.md",
            "README.md",
            "docs/circuit/receipt-first-product-loop.md",
            "docs/circuit/migration-inventory.md",
        ],
        "risks": [
            "Mistaking fixture artifacts for product-code Capacitor injection.",
            "Letting receipt return expand into a runner, flow engine, or status platform.",
            "Skipping the raw receipt capture boundary.",
        ],
        "suggested_agent": target_agent,
        "checkpoint_condition": "Stop if the proof requires a runner, flow engine, method system, product platform, broad memory store, new terminal, new editor, or SaaS framing.",
        "delivery_target": "docs/circuit/proofs/receipt-first-product-loop/",
    }
    receipt_id = f"receipt-{suffix}"
    body = f"""/goal {idea_text}

This is a transport proof for the Capacitor <-> Circuit product loop. Do not edit files, run broad investigation, spawn subagents, or continue into open-ended work.

Confirm only this smallest handoff: Capacitor injected this exact GoalPacket.body into {host_phrase}; you can return one receipt; Capacitor can capture it in the background; Circuit can normalize it; Capacitor can render it.

Preserve the boundary: Capacitor orchestrates native agent sessions and attention, Circuit is the headless intent/protocol layer, and Claude Code/Codex own execution and native subagent primitives. Do not build agent-reasoning orchestration, a runner, flow engine, task DAG, retry platform, broad memory store, new terminal/editor, or SaaS framing.

End immediately with this visible marker and one JSON Receipt object:

{MARKER}
{{"kind":"receipt","id":"{receipt_id}","goal_packet_id":"{goal_packet_id}","status":"completed","summary":"Claude Code CLI received the Circuit-produced GoalPacket body and returned the receipt for the receipt-first transport proof.","evidence":["GoalPacket.body was injected into {host_phrase}.","Receipt marker was returned in the native CLI output for Capacitor capture."],"changed_paths":[],"open_risks":["This proves the transport receipt path, not useful agent work or checkpoint relay."],"next_action":"Normalize this raw receipt through the headless Circuit protocol boundary and render it in Capacitor."}}"""
    if target_agent == "codex" and suffix == SUPPORTED_ID_SUFFIX:
        body = f"/goal Prove the receipt-first Capacitor <-> Circuit slice with the smallest live path: one captured idea, one Circuit-shaped pursuit proposal, one GoalPacket whose body contains the visible {MARKER} return instruction, one visible Codex session, one captured raw receipt block, one normalized AgentEvent, and one Capacitor rendering expectation. Use fixture artifacts where product integration does not exist yet, preserve the owner-first boundary, and do not build a runner, flow engine, method system, product platform, broad memory store, new terminal/editor, or SaaS framing. When finished, end with a visible {MARKER} line followed by one JSON Receipt object whose status is exactly one of completed, blocked, or failed."

    goal_packet = {
        "kind": "goal_packet",
        "id": goal_packet_id,
        "idea_id": idea["id"],
        "pursuit_id": pursuit_id,
        "target_agent": target_agent,
        "project_path": project_path,
        "body": body,
        "expected_return": "receipt",
        "receipt_expectation": "Return a compact summary of artifacts created, evidence checked, unresolved risk, and next action.",
        "checkpoint_expectation": "Ask only if owner input changes the work.",
    }
    return {
        "pursuit_proposal": pursuit_proposal,
        "goal_packet": goal_packet,
    }


def plan_goal_packet_response(
    idea: Mapping[str, Any],
    *,
    target_agent: str = SUPPORTED_TARGET_AGENT,
) -> dict[str, Any]:
    """Return the one-shot planning boundary response for Capacitor."""
    planned = plan_goal_packet(idea, target_agent=target_agent)
    return {
        "kind": "plan_goal_packet_response",
        "planning": {
            "mode": PLANNING_MODE,
            "circuit_runtime_invoked": False,
        },
        "pursuit_proposal": planned["pursuit_proposal"],
        "goal_packet": planned["goal_packet"],
    }
