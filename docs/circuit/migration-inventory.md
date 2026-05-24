# Receipt-First Loop Migration Inventory

Status: source-backed inventory for consolidating the live receipt-first
Capacitor/Circuit loop into this repo.

## Moved Into Capacitor

| Source in `capacitor-circuit` | Destination in `capacitor` | Reason |
| --- | --- | --- |
| `circuit_protocol/__init__.py` | `circuit_protocol/__init__.py` | Keep the headless protocol boundary importable without a sibling repo. |
| `circuit_protocol/goal_packet_planning.py` | `circuit_protocol/goal_packet_planning.py` | Plan one receipt-first `PursuitProposal` and `GoalPacket`. |
| `circuit_protocol/agent_event_normalization.py` | `circuit_protocol/agent_event_normalization.py` | Normalize one raw `CIRCUIT_RECEIPT` into one `AgentEvent`. |
| `scripts/plan-goal-packet.py` | `scripts/circuit/plan-goal-packet.py` | Capacitor-owned CLI boundary for planning. |
| `scripts/normalize-agent-event.py` | `scripts/circuit/normalize-agent-event.py` | Capacitor-owned CLI boundary for normalization. |
| `tests/test_goal_packet_planning.py` | `tests/circuit_protocol/test_goal_packet_planning.py` | Focused protocol test in the implementation repo. |
| `tests/test_agent_event_normalization.py` | `tests/circuit_protocol/test_agent_event_normalization.py` | Focused normalizer test in the implementation repo. |
| `docs/proofs/slice-01-receipt-first/01-idea.json` | `docs/circuit/proofs/receipt-first-fixture/01-idea.json` | Minimal fixture for the static planner check. |
| `docs/proofs/slice-01-receipt-first/02-pursuit-proposal.json` | `docs/circuit/proofs/receipt-first-fixture/02-pursuit-proposal.json` | Expected fixture output for the static planner check. |
| `docs/proofs/slice-01-receipt-first/03-goal-packet.json` | `docs/circuit/proofs/receipt-first-fixture/03-goal-packet.json` | Expected fixture `GoalPacket` for the static planner check. |

## Replaced In Capacitor

| Old dependency | Replacement |
| --- | --- |
| Swift default root `/Users/petepetrash/Code/capacitor-circuit` | `ReceiptFirstProofArtifacts.defaultCapacitorRoot()`, using `CAPACITOR_REPO_ROOT` or the local Capacitor checkout. |
| Swift protocol command `python3 scripts/plan-goal-packet.py` in the sibling repo | `python3 scripts/circuit/plan-goal-packet.py` in this repo. |
| Swift protocol command `python3 scripts/normalize-agent-event.py` in the sibling repo | `python3 scripts/circuit/normalize-agent-event.py` in this repo. |
| Proof artifacts under `docs/proofs/slice-14-claude-code-product-loop/` in the sibling repo | Proof artifacts under `docs/circuit/proofs/receipt-first-product-loop/` in this repo. |
| Old first-slice validator in the sibling repo | `scripts/circuit/validate-receipt-first-loop.py`, scoped to the Capacitor-owned Claude Code loop. |

## Not Moved

- The old Circuit runtime.
- Old Circuit flow engine, method system, generated plugin surfaces, proof
  machinery, tournament/fanout machinery, and broad configuration.
- Historical proof folders that do not participate in the live Claude Code
  receipt loop.
- Broad product strategy notes that are not needed for the next coding agent to
  run or maintain this loop.

## Current Evidence

- Protocol code and scripts now live under Capacitor-owned paths.
- Swift loop defaults no longer point at the sibling `capacitor-circuit` repo.
- Live manual proof artifacts should be written to
  `docs/circuit/proofs/receipt-first-product-loop/`.
- `scripts/circuit/validate-receipt-first-loop.py` is the Capacitor-owned
  successor validator for this consolidated loop.
- A manual Capacitor UI run wrote the live artifacts to the Capacitor repo and
  rendered `live-window-run-01.png`.
- `docs/circuit/proofs/receipt-first-product-loop/validation-result.json`
  passed 13 checks, including no old Swift runtime path tokens and a
  Capacitor-owned source idea.
