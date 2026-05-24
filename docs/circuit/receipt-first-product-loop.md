# Receipt-First Capacitor/Circuit Product Loop

Status: live Claude Code CLI-first loop owned by the Capacitor repo.

This document defines the smallest product loop that should run without a
runtime dependency on `/Users/petepetrash/Code/capacitor-circuit`.

## Boundary

- Capacitor owns native session lifecycle, attention, injection, observation,
  artifact storage, and rendering.
- Circuit is represented here as a headless intent/protocol layer:
  JSON-compatible planning and normalization functions under `circuit_protocol/`.
- Claude Code owns execution. Capacitor launches or focuses one visible Claude
  Code CLI session and captures its returned receipt.
- Codex remains a secondary adapter reference. Cursor is deferred.

This is not a runner, flow engine, task DAG, retry platform, broad memory store,
new terminal/editor, SaaS workflow, or agent-reasoning orchestrator.

## Live Loop

1. Capacitor selects one captured receipt-first idea for this repo.
2. Capacitor maps it to an `Idea` JSON object.
3. Capacitor calls `scripts/circuit/plan-goal-packet.py --stdin`.
4. The headless planner returns one `PursuitProposal` and one Claude Code
   `GoalPacket`.
5. Capacitor launches one visible Claude Code CLI session through the existing
   terminal substrate.
6. Capacitor injects the exact `GoalPacket.body`.
7. Claude Code returns one visible `CIRCUIT_RECEIPT` block.
8. Capacitor preserves the raw receipt and adapter result under
   `docs/circuit/proofs/receipt-first-product-loop/native-session/`.
9. Capacitor calls `scripts/circuit/normalize-agent-event.py --stdin`.
10. The headless normalizer returns one receipt `AgentEvent`.
11. Capacitor renders the normalized result in the Claude receipt window.

## Owned Paths

- Protocol package: `circuit_protocol/`
- Protocol scripts: `scripts/circuit/`
- Protocol tests: `tests/circuit_protocol/`
- Fixture proof: `docs/circuit/proofs/receipt-first-fixture/`
- Live product-loop proof: `docs/circuit/proofs/receipt-first-product-loop/`
- Swift bridge: `apps/swift/Sources/Capacitor/Debug/CircuitReceiptProductLoop.swift`
- Native adapter: `apps/swift/Sources/Capacitor/Debug/ReceiptFirstProofAdapter.swift`
- Rendering surface: `apps/swift/Sources/Capacitor/Debug/ReceiptProofRendering.swift`
- Menu entry: `apps/swift/Sources/Capacitor/Features/CircuitFirstSliceCommands.swift`

## Validation

Run the protocol checks:

```sh
python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization
python3 scripts/circuit/plan-goal-packet.py --check
```

After a manual Capacitor UI run, validate the live proof artifacts:

```sh
python3 scripts/circuit/validate-receipt-first-loop.py --write docs/circuit/proofs/receipt-first-product-loop/validation-result.json
```

Run the focused Swift checks:

```sh
swift test --package-path apps/swift --filter CircuitReceiptProductLoopTests
swift test --package-path apps/swift --filter ReceiptFirstProofAdapterTests
swift test --package-path apps/swift --filter ReceiptProofRenderingTests
```

## Deferred

- Useful agent work beyond a transport receipt.
- Checkpoint relay and owner decision injection.
- Queues, retries, dependency graphs, or task DAGs.
- Codex parity beyond the existing adapter reference.
- Cursor.
- Hook-rich background receipt capture beyond stdout/last-message capture.
