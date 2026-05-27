# Receipt-First Product Loop Evidence Log

Status: consolidated into `/Users/petepetrash/Code/capacitor` and verified
with one passing manual Capacitor UI run.

## Boundary

- Capacitor owns native session lifecycle, attention, injection, observation,
  artifact storage, and rendering.
- Circuit is represented by the headless local protocol package
  `circuit_protocol/`.
- Claude Code owns execution in one visible CLI session.
- The old Circuit runtime is not invoked.

## Consolidation Evidence

- Protocol package moved to `circuit_protocol/`.
- Planning and normalization scripts moved to `scripts/circuit/`.
- Protocol tests moved to `tests/circuit_protocol/`.
- Product-loop artifacts now live under
  `docs/circuit/proofs/receipt-first-product-loop/`.
- The Capacitor-owned validator is
  `scripts/circuit/validate-receipt-first-loop.py`.

## Manual Run Evidence

Passing run:

- Triggered from Capacitor menu: `Circuit > Run Claude Receipt Loop`.
- Artifact readiness: complete after 10 seconds.
- Render evidence: `live-window-run-01.png`.
- Validator: `validation-result.json`, status `passed`, 13 checks.

The live Capacitor UI run produced:

- `planning/01-capacitor-idea-source.json`
- `planning/02-contract-idea.json`
- `planning/03-planning-request.json`
- `planning/04-planning-response.json`
- `planning/05-goal-packet.json`
- `native-session/03-native-inserted-goal-body.txt`
- `native-session/04-native-visible-session-transcript.txt`
- `native-session/05-native-agent-last-message.txt`
- `native-session/06-native-captured-raw-receipt.txt`
- `native-session/07-native-adapter-result.json`
- `normalization/00-normalization-request.json`
- `normalization/01-agent-event.json`

Required facts:

- The source idea targets `/Users/petepetrash/Code/capacitor`.
- The `GoalPacket` targets `claude_code`.
- The inserted body exactly matches `GoalPacket.body`.
- The raw receipt starts with `CIRCUIT_RECEIPT`.
- The adapter result records `host: "claude_code"`.
- The normalized `AgentEvent` records `session.host: "claude_code"`.
- Both planning and normalization record that Circuit runtime was not invoked.

## Issues Found And Resolved

1. The first consolidated UI run still selected the old `capacitor-circuit`
   receipt idea. Artifacts were written to Capacitor-owned paths, but the source
   idea targeted the old repo, so the validator failed.
   - Fix: the menu action now prefers the local Capacitor repo for this proof.
2. The next run still selected the old idea because the Capacitor idea cache was
   stale.
   - Fix: the menu action refreshes idea-file changes before selection.
3. The seeded Capacitor idea did not parse because its idea ID was 24
   characters, while the idea parser requires 26 uppercase letters/digits.
   - Fix: the local proof idea ID is now `01KSCAPACITORCIRCUIT000000`.
4. The rendering test expected the old static fixture goal ID.
   - Fix: the test now checks consistency with the live source receipt and the
     `claude_code` host.

## Verification Commands

```sh
python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization
python3 scripts/circuit/plan-goal-packet.py --check
python3 scripts/circuit/normalize-agent-event.py --check
python3 scripts/circuit/validate-receipt-first-loop.py --write docs/circuit/proofs/receipt-first-product-loop/validation-result.json
swift test --package-path apps/swift --filter CircuitReceiptProductLoopTests
swift test --package-path apps/swift --filter ReceiptFirstProofAdapterTests
swift test --package-path apps/swift --filter ReceiptProofRenderingTests
```

All commands passed after the fixes above.

## Deferred

- Useful agent work beyond a transport receipt.
- Checkpoint relay.
- Queue orchestration.
- Retry recovery.
- Codex parity beyond the existing adapter reference.
- Cursor support.
- Broad memory.
- Old Circuit runtime integration.
- A runner, flow engine, task DAG, new terminal/editor, or SaaS workflow.
