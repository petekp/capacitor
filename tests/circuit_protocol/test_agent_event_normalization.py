from __future__ import annotations

import unittest
from pathlib import Path

from circuit_protocol import NormalizationError, normalize_agent_event


class AgentEventNormalizationTests(unittest.TestCase):
    def test_normalizes_raw_receipt_into_deterministic_agent_event(self) -> None:
        raw_receipt_path = Path("/tmp/capacitor/06-native-captured-raw-receipt.txt")
        adapter_result = make_adapter_result(raw_receipt_path)
        raw_receipt = make_raw_receipt(status="completed")

        event = normalize_agent_event(raw_receipt, adapter_result, raw_receipt_path)

        self.assertEqual(event["kind"], "agent_event")
        self.assertEqual(event["id"], "event-receipt-test")
        self.assertEqual(event["goal_packet_id"], "goal-packet-test")
        self.assertEqual(event["session"]["host"], "codex")
        self.assertEqual(event["session"]["visible_to_owner"], True)
        self.assertTrue(event["session"]["session_id"].startswith("session-receipt-"))
        self.assertEqual(event["type"], "receipt")
        self.assertEqual(event["recorded_at"], "2026-05-24T04:01:51Z")
        self.assertEqual(event["payload"]["id"], "receipt-test")
        self.assertEqual(event["payload"]["status"], "completed")
        self.assertEqual(event["normalization"]["mode"], "headless_receipt_normalizer")
        self.assertEqual(event["normalization"]["source_raw_receipt_path"], str(raw_receipt_path.resolve()))
        self.assertEqual(event["normalization"]["circuit_runtime_invoked"], False)

        second_event = normalize_agent_event(raw_receipt, adapter_result, raw_receipt_path)
        self.assertEqual(event, second_event)

    def test_normalizes_claude_code_adapter_result(self) -> None:
        raw_receipt_path = Path("/tmp/capacitor/claude-raw-receipt.txt")
        adapter_result = make_adapter_result(raw_receipt_path, host="claude_code", include_codex_exit_code=False)
        raw_receipt = make_raw_receipt(status="completed")

        event = normalize_agent_event(raw_receipt, adapter_result, raw_receipt_path)

        self.assertEqual(event["session"]["host"], "claude_code")
        self.assertEqual(event["normalization"]["circuit_runtime_invoked"], False)

    def test_rejects_raw_receipt_without_marker(self) -> None:
        with self.assertRaisesRegex(NormalizationError, "must start with CIRCUIT_RECEIPT"):
            normalize_agent_event("{}", make_adapter_result(Path("/tmp/receipt.txt")), Path("/tmp/receipt.txt"))

    def test_rejects_disallowed_receipt_status(self) -> None:
        raw_receipt_path = Path("/tmp/receipt.txt")
        with self.assertRaisesRegex(NormalizationError, "receipt.status must be one of"):
            normalize_agent_event(
                make_raw_receipt(status="completed_with_warnings"),
                make_adapter_result(raw_receipt_path),
                raw_receipt_path,
            )

    def test_rejects_mismatched_goal_packet_id(self) -> None:
        raw_receipt_path = Path("/tmp/receipt.txt")
        adapter_result = make_adapter_result(raw_receipt_path, goal_packet_id="goal-from-adapter")
        with self.assertRaisesRegex(NormalizationError, "goal_packet_id must match"):
            normalize_agent_event(
                make_raw_receipt(goal_packet_id="goal-from-receipt"),
                adapter_result,
                raw_receipt_path,
            )

    def test_rejects_adapter_result_for_different_raw_receipt_path(self) -> None:
        raw_receipt_path = Path("/tmp/receipt.txt")
        adapter_result = make_adapter_result(Path("/tmp/other-receipt.txt"))
        with self.assertRaisesRegex(NormalizationError, "raw_receipt_path must point at the raw receipt"):
            normalize_agent_event(make_raw_receipt(), adapter_result, raw_receipt_path)


def make_raw_receipt(
    *,
    goal_packet_id: str = "goal-packet-test",
    status: str = "completed",
) -> str:
    return (
        "CIRCUIT_RECEIPT\n"
        "{"
        f'"kind":"receipt","id":"receipt-test","goal_packet_id":"{goal_packet_id}",'
        f'"status":"{status}","summary":"done","evidence":[],"changed_paths":[],'
        '"open_risks":[],"next_action":"stop"'
        "}\n"
    )


def make_adapter_result(
    raw_receipt_path: Path,
    *,
    goal_packet_id: str = "goal-packet-test",
    host: str = "codex",
    include_codex_exit_code: bool = True,
) -> dict[str, object]:
    result: dict[str, object] = {
        "kind": "native_receipt_first_proof_result",
        "status": "native_capture_complete",
        "finished_at": "2026-05-24T04:01:51Z",
        "goal_packet_id": goal_packet_id,
        "host": host,
        "agent_exit_code": 0,
        "visible_surface": "Ghostty launched by Capacitor Circuit first-slice action",
        "capture": {
            "raw_receipt_path": str(raw_receipt_path.resolve()),
        },
    }
    if include_codex_exit_code:
        result["codex_exit_code"] = 0
    return result


if __name__ == "__main__":
    unittest.main()
