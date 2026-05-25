from __future__ import annotations

import unittest

from circuit_protocol import PlanningError, plan_goal_packet


class GoalPacketPlanningTests(unittest.TestCase):
    def test_plans_deterministic_proposal_and_goal_packet(self) -> None:
        idea = make_idea()

        planned = plan_goal_packet(idea)

        proposal = planned["pursuit_proposal"]
        goal_packet = planned["goal_packet"]
        self.assertEqual(proposal["kind"], "pursuit_proposal")
        self.assertEqual(proposal["id"], "pursuit-receipt-first-001")
        self.assertEqual(proposal["idea_id"], idea["id"])
        self.assertEqual(proposal["suggested_agent"], "codex")
        self.assertEqual(goal_packet["kind"], "goal_packet")
        self.assertEqual(goal_packet["id"], "goal-packet-receipt-first-001")
        self.assertEqual(goal_packet["idea_id"], idea["id"])
        self.assertEqual(goal_packet["pursuit_id"], proposal["id"])
        self.assertEqual(goal_packet["target_agent"], "codex")
        self.assertEqual(goal_packet["project_path"], idea["project"]["path"])
        self.assertEqual(goal_packet["expected_return"], "receipt")
        self.assertIn("CIRCUIT_RECEIPT", goal_packet["body"])

        second_planned = plan_goal_packet(idea)
        self.assertEqual(planned, second_planned)

    def test_body_contains_the_visible_receipt_contract(self) -> None:
        body = plan_goal_packet(make_idea())["goal_packet"]["body"]

        self.assertIn("visible CIRCUIT_RECEIPT return instruction", body)
        self.assertIn("end with a visible CIRCUIT_RECEIPT line", body)
        self.assertIn("status is exactly one of completed, blocked, or failed", body)

    def test_plans_claude_code_goal_packet_for_captured_receipt_first_idea(self) -> None:
        idea = make_idea()
        idea["id"] = "idea-01HRCLAUDE"
        idea["text"] = "Prove the receipt-first Capacitor <-> Circuit slice from a captured Capacitor idea."

        planned = plan_goal_packet(idea, target_agent="claude_code")

        self.assertEqual(planned["pursuit_proposal"]["suggested_agent"], "claude_code")
        self.assertEqual(planned["goal_packet"]["target_agent"], "claude_code")
        self.assertEqual(planned["goal_packet"]["id"], "goal-packet-01hrclaude")
        self.assertIn("visible Claude Code CLI session", planned["goal_packet"]["body"])
        self.assertIn("Capacitor orchestrates native agent sessions and attention", planned["goal_packet"]["body"])

    def test_plans_claude_code_goal_packet_for_ordinary_captured_intent(self) -> None:
        idea = make_idea()
        idea["id"] = "idea-evidence-packets"
        idea["text"] = "Improve checkpoint evidence packets for high-level review."
        idea["intent"] = "Improve checkpoint evidence packets for high-level review."
        idea["success_criteria"] = "I can approve or reject without reading the diff first."

        planned = plan_goal_packet(idea, target_agent="claude_code")

        proposal = planned["pursuit_proposal"]
        goal_packet = planned["goal_packet"]
        self.assertEqual(proposal["idea_id"], idea["id"])
        self.assertEqual(proposal["suggested_agent"], "claude_code")
        self.assertEqual(goal_packet["target_agent"], "claude_code")
        self.assertEqual(goal_packet["id"], "goal-packet-evidence-packets")
        self.assertIn("/goal Improve checkpoint evidence packets for high-level review.", goal_packet["body"])
        self.assertIn("Success means: I can approve or reject without reading the diff first.", goal_packet["body"])
        self.assertIn("Do the smallest useful slice", goal_packet["body"])
        self.assertIn("You may inspect and edit files", goal_packet["body"])
        self.assertIn("CIRCUIT_RECEIPT", goal_packet["body"])
        self.assertNotIn("This is a transport proof", goal_packet["body"])
        self.assertNotIn("Do not edit files", goal_packet["body"])

    def test_keeps_fixture_codex_goal_packet_as_transport_proof(self) -> None:
        planned = plan_goal_packet(make_idea())

        proposal = planned["pursuit_proposal"]
        body = planned["goal_packet"]["body"]
        self.assertEqual(proposal["delivery_target"], "docs/circuit/proofs/receipt-first-product-loop/")
        self.assertIn("fixture artifacts", body)
        self.assertIn("one visible Codex session", body)
        self.assertNotIn("Do the smallest useful slice", body)

    def test_blank_optional_intent_falls_back_to_idea_text(self) -> None:
        idea = make_idea()
        idea["id"] = "idea-blank-intent"
        idea["text"] = "Tighten the ordinary captured idea path."
        idea["intent"] = "   "

        planned = plan_goal_packet(idea, target_agent="claude_code")

        self.assertIn("/goal Tighten the ordinary captured idea path.", planned["goal_packet"]["body"])

    def test_rejects_non_idea_kind(self) -> None:
        idea = make_idea()
        idea["kind"] = "note"

        with self.assertRaisesRegex(PlanningError, "idea.kind must be idea"):
            plan_goal_packet(idea)

    def test_rejects_blank_idea_text(self) -> None:
        idea = make_idea()
        idea["text"] = "   "

        with self.assertRaisesRegex(PlanningError, "idea.text must not be blank"):
            plan_goal_packet(idea)

    def test_rejects_unsupported_agent_selection(self) -> None:
        with self.assertRaisesRegex(PlanningError, "supported by this proof planner"):
            plan_goal_packet(make_idea(), target_agent="cursor")


def make_idea() -> dict[str, object]:
    return {
        "kind": "idea",
        "id": "idea-receipt-first-001",
        "project": {
            "name": "capacitor",
            "path": "/Users/petepetrash/Code/capacitor",
        },
        "text": "Prove the receipt-first Capacitor <-> Circuit slice with the smallest live path and fixture artifacts.",
        "captured_at": "2026-05-24T01:30:00Z",
    }


if __name__ == "__main__":
    unittest.main()
