# Adversarial Review: Consolidated Receipt-First Product Loop

Status: two consecutive clean reviews after resolving the medium-or-higher
issues found during consolidation.

Scope:

- Capacitor-owned protocol package: `circuit_protocol/`
- Capacitor-owned protocol scripts and validator: `scripts/circuit/`
- Capacitor docs and proof artifacts: `docs/circuit/`
- Swift loop, adapter, command, and rendering surfaces under `apps/swift/`

## Resolved Before Clean Reviews

1. [High] Manual UI run still selected the old `capacitor-circuit` idea
   - Evidence: the first consolidated manual run wrote artifacts under
     `docs/circuit/proofs/receipt-first-product-loop/`, but
     `planning/01-capacitor-idea-source.json` contained
     `project_path: "/Users/petepetrash/Code/capacitor-circuit"`.
   - Why it mattered: the app no longer depended on the old repo for scripts or
     artifacts, but the live product loop still targeted the old planning repo.
   - Resolution: `CircuitFirstSliceCommands` now prefers the local Capacitor
     repo for this proof.
   - Verification: `scripts/circuit/validate-receipt-first-loop.py` now passes
     and checks the source idea targets `/Users/petepetrash/Code/capacitor`.

2. [Medium] The command could select from stale idea cache
   - Evidence: after preferring the Capacitor project, the next manual run still
     selected the old idea until project idea files were refreshed.
   - Why it mattered: the menu action could ignore a newly captured or seeded
     receipt-first idea.
   - Resolution: the command refreshes idea-file changes before selecting the
     proof idea.
   - Verification: the passing manual run selected the Capacitor-owned idea.

3. [Medium] The seeded Capacitor idea did not parse
   - Evidence: Capacitor's idea parser requires 26 uppercase letters/digits; the
     seeded idea ID was 24 characters.
   - Why it mattered: the app could not see the intended Capacitor proof idea,
     so it fell back to the old project.
   - Resolution: the local proof idea ID was corrected to
     `01KSCAPACITORCIRCUIT000000`.
   - Verification: the passing manual run source artifact records that ID.

4. [Medium] Rendering test expected the old static fixture goal ID
   - Evidence: `ReceiptProofRenderingTests` failed when the live consolidated
     run used `goal-packet-01kscapacitorcircuit000000`.
   - Why it mattered: the test would reject valid dynamic GoalPackets produced
     from real captured ideas.
   - Resolution: the test now checks consistency with the source receipt and
     verifies `session.host == "claude_code"`.
   - Verification: `swift test --package-path apps/swift --filter
     ReceiptProofRenderingTests` passes with 11 tests and no skips.

## Review 1

Findings:

- No medium, high, or critical findings remain.

Low residual risks:

- [Low] `ReceiptFirstProofArtifacts.defaultCapacitorRoot()` still has a local
  checkout fallback for this development proof. That is acceptable for the
  owner-first local loop, but a future packaged build should use an explicit
  configured workspace root.
- [Low] The proof intentionally keeps the receipt marker visible in the native
  Claude Code CLI transcript. Richer background hook capture should wait until
  the receipt path stays stable.

Checks:

- `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization`
- `python3 scripts/circuit/plan-goal-packet.py --check`
- `python3 scripts/circuit/normalize-agent-event.py --check`
- `python3 scripts/circuit/validate-receipt-first-loop.py --write docs/circuit/proofs/receipt-first-product-loop/validation-result.json`
- `swift test --package-path apps/swift --filter CircuitReceiptProductLoopTests`
- `swift test --package-path apps/swift --filter ReceiptFirstProofAdapterTests`
- `swift test --package-path apps/swift --filter ReceiptProofRenderingTests`
- `python3 -m json.tool` over the focused result, validation result,
  GoalPacket, adapter result, and AgentEvent artifacts.
- `git diff --check` over the scoped changed docs, Python, and Swift files.
- `rg` check over runtime Swift/Python/test surfaces for the old
  `/Users/petepetrash/Code/capacitor-circuit` runtime dependency.

Result: clean. No medium-or-higher findings.

## Review 2

Findings:

- No medium, high, or critical findings remain.

Low residual risks:

- [Low] The consolidated loop remains receipt-first and Claude Code CLI-first.
  Checkpoint relay, retries, queues, Cursor, and generalized multi-host
  management are deliberately deferred.
- [Low] The local `circuit_protocol/` package is a small embedded protocol
  boundary, not yet a separately versioned module. That is fine until the loop
  proves product value beyond this first receipt path.

Checks:

- Re-read `docs/circuit/receipt-first-product-loop.md`,
  `docs/circuit/migration-inventory.md`, `evidence-log.md`, and
  `validation-result.json` against the goal boundary.
- Confirmed the app no longer shells into `/Users/petepetrash/Code/capacitor-circuit`
  for planning, normalization, or proof artifacts.
- Confirmed the implementation does not invoke old Circuit runtime or add a
  runner, flow engine, task DAG, retry platform, broad memory store, new
  terminal/editor, SaaS workflow, or agent-reasoning orchestrator.

Result: clean. This is the second consecutive review with no medium-or-higher
findings.

## Follow-Up Cleanup

- Resolved the low naming debt from Review 1 by renaming the last-message
  capture artifact to `05-native-agent-last-message.txt`.
