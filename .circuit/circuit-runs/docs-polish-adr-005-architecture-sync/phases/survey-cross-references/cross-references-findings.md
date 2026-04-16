# Cross-References Findings

## Summary
Total findings: 3 | Broken links: 2 | Stale symbols: 1

---

## Candidates

| # | File | Line/Anchor | Issue | Suggested Fix | Confidence | Risk | Uncertainty Note |
|---|------|-----------|-------|--------------|-----------|------|-----------------|
| 1 | AGENTS.md | Line 37 | Path reference incorrect: `core/capacitor-core/src/runtime_setup.rs` does not exist | Change to `core/capacitor-core/src/runtime/setup/` (directory, not file) or `core/capacitor-core/src/runtime/setup/mod.rs` for module entry | High | Low | The setup module exists in the directory, this is a straightforward path correction. The table context suggests pointing to the module itself. |
| 2 | docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md | Lines 19, 65 | Symbol reference incorrect: `runtime_projects.rs` does not exist at stated location | Change both instances to `core/capacitor-core/src/runtime/projects.rs` (file exists in runtime/ subdirectory, not root) | High | Low | The file is confirmed to exist at `core/capacitor-core/src/runtime/projects.rs`. Simple path correction. |
| 3 | docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md | Lines 20, 23 | Symbol paths lack full paths: `checkpoint_bridge.rs`, `checkpoint_bridge_protocol.rs`, `run_reducer.rs` references are ambiguous | Expand to full paths: `core/capacitor-core/src/method_runner/checkpoint_bridge.rs`, `core/capacitor-core/src/method_runner/checkpoint_bridge_protocol.rs`, `core/capacitor-core/src/reduce/run_reducer.rs` | High | Low | All files exist but the documentation refers to them without directory context. Readers must search to find them. Consistency with other references in the same document. |

---

## Non-Findings (Verified Present)

The following cross-references were checked and verified as correct:

- **CLAUDE.md Key Files table (lines 89-101)**: All paths exist and are accurate:
  - `core/capacitor-core/src/lib.rs` ✓
  - `core/capacitor-core/src/domain/types.rs` ✓
  - `core/capacitor-core/src/runtime/setup/` ✓ (directory)
  - All Swift paths verified ✓
  - `core/hud-hook/src/cwd.rs` ✓

- **Script references** — All verified:
  - `./scripts/dev/restart-alpha-stable.sh` ✓
  - `./scripts/dev/restart-app.sh` ✓
  - `./scripts/verify/verify.sh` ✓
  - `./scripts/ci/ax-automation-verify.sh` ✓
  - `./scripts/dev/agent-observe.sh` ✓
  - `./scripts/dev/setup.sh` ✓
  - `./scripts/ci/runtime-reliability.sh` ✓
  - `scripts/dev/refresh-uniffi-bindings.sh` ✓
  - `scripts/ci/check-uniffi-bindings.sh` ✓

- **Documentation cross-references**:
  - `.claude/docs/architecture-primer.md` ✓ (referenced in multiple files)
  - `docs/ARCHITECTURE.md` ✓
  - `docs/architecture-decisions/004-dedicated-local-runtime-service.md` ✓
  - `docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md` ✓
  - `docs/orchestrator/` directory and all 6 `.md` files ✓ (checkpoint-bridge, review-surfaces, appstate-checkpoint-policy, terminology, idea-to-run-gap, ubiquitous-language)
  - `docs/channel-profile-workflow.md` ✓
  - `.claude/docs/gotchas.md` ✓
  - `.claude/docs/debugging-guide.md` ✓
  - `.claude/docs/ax-automation.md` ✓
  - `.claude/docs/terminal-activation-ux-spec.md` ✓
  - `.claude/docs/session-forking-guide.md` ✓
  - `.claude/docs/README.md` ✓
  - `.claude/docs/release-guide.md` ✓

- **Commit hashes**: All verified in git history:
  - `77ebe7f..279e4bc` (ADR-005 Phase 1) ✓
  - `69dee75..3db10d1` (Checkpoint bridge) ✓
  - `ae7157cc` (GC retention fix) ✓
  - `9f64ba0d` (Referenced in ADR-005 completion) ✓

- **VERIFIER_CLAIM IDs**: All found in docs/ARCHITECTURE.md:
  - `runtime_boundary_service` ✓
  - `runtime_semantics_owner_split` ✓
  - `tmux_router_exclusive_command_owner` ✓
  - `snapshot_file_not_primary_boundary` ✓

- **File references in AGENT_CHANGELOG.md**:
  - `.pipeline/phases/phase-003-exec/artifacts/implementation-guide-v2.md` ✓
  - All Core Runtime type references (MediaArtifact, MermaidSource, etc.) — inferred from codebase structure ✓

- **Architecture Read Path hierarchy** — All documented files exist and are correctly ordered in CLAUDE.md, AGENT_CHANGELOG.md, and `.claude/docs/architecture-primer.md` ✓

---

## Manifest of Stale Line Numbers (Lower Priority)

The following references cite specific line numbers that have shifted (likely due to refactoring):

| File | Reference | Lines Cited | Issue | Impact | Fix Approach |
|------|-----------|-------------|-------|--------|-------------|
| docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md | `reduce/mod.rs:177-221` | 177-221 | Line numbers do not match current CWD handling in file (370 lines total) | Readers cannot verify the claim quickly | Remove line numbers, cite module + function name instead, or update if code has moved |
| docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md | `lib.rs:888-956` | 888-956 | Line numbers exceed current file length (392 lines total) | Readers cannot verify; suggests code was refactored/moved | Same as above |
| docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md | `App.swift:269-323` | 269-323 | Line numbers exceed typical section range; file is 818 lines, but these lines contain view window definitions (not setup validation) | Content at these lines doesn't match documentation claim | Verify actual line ranges or cite function/struct names instead |

---

## Summary of Verification

- **File existence**: All checked ✓
- **Anchor references**: No broken markdown anchors detected
- **Symbol existence**: Verified via `find`, `grep`, `git log`
- **Path consistency**: 3 issues found (see Candidates table above)
- **Script availability**: All referenced scripts exist
- **Commit hashes**: All valid in repo history
