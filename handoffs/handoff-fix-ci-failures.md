# Resume: Fix two pre-existing CI failures and harden CI reliability

## Mission
Fix the two CI jobs that have been failing across multiple commits (`Verifier Self-Test` and `Test Swift`), then harden CI so these classes of failure are less likely in the future.

## Resume Point
- Last meaningful action: confirmed both failures are pre-existing (failing since before commit `20b8126`, at least 20 consecutive red runs)
- Next action: fix `DelegationReviewManifestTests.swift` SwiftFormat lint errors, then fix the 12 behavioral spec violations in `test_runtime_boundary_contracts_pass_on_repo`
- Success criterion: `gh run view <latest> --json conclusion` returns `success` for all jobs

## Current State
- Elegance refactoring complete: score 92 / Grade A (committed and pushed)
- Two CI jobs failing — both pre-existing, not introduced by our work
- All other CI jobs passing: Test Rust, Test Hook Binary, Runtime Reliability Gate, Surface Audit, Release Scripts, Verifier Bootstrap

## Failing Job 1: Test Swift — SwiftFormat lint

**Root cause: SwiftFormat version drift**
- CI config (`.github/workflows/ci.yml:253`) pins `SWIFTFORMAT_VERSION: "0.59.1"`
- But CI logs show the downloaded binary reports **0.60.1**
- The GitHub Release at `https://github.com/nicklockwood/SwiftFormat/releases/download/0.59.1/swiftformat.zip` appears to serve 0.60.1 (the binary was likely overwritten upstream)
- Local dev machines have 0.59.1 via Homebrew, so local lint passes but CI fails
- New 0.60.x rules triggering: `redundantSwiftTestingSuite`, `swiftTestingTestCaseNames`

**Affected file:** `apps/swift/Tests/CapacitorTests/DelegationReviewManifestTests.swift`
- 10 lint errors, all about Swift Testing `@Suite` and `@Test` naming conventions

**Fix options (pick one):**
1. **Run `swiftformat` with 0.60.1 locally** to fix the file, then update the pin to 0.60.1 everywhere (local + CI + `.swiftformat`)
2. **Pin CI to a checksum or specific artifact** to prevent upstream drift (e.g., download from a mirrored URL or vendor the binary)
3. **Disable the two new rules** in `.swiftformat` if they're not wanted

**Recommendation:** Option 1 — install SwiftFormat 0.60.1 locally (`brew upgrade swiftformat` or pin in CI to a known-good artifact URL), run it over the test file, and commit. Then harden the CI pin (option 2) so this can't recur.

**Memory note:** CLAUDE.md says "SwiftFormat pinned to 0.59.1 in CI via GitHub Release binary (not `brew install`)" — update memory after fixing.

## Failing Job 2: Verifier Self-Test — behavioral spec violations

**Root cause: 12 pre-existing violations in `test_runtime_boundary_contracts_pass_on_repo`**

The test at `tests/verify/unit/test_behavioral_specs.py:171` calls `.verifier/specs/RuntimeBoundaryContracts.py:verify(facts)` and expects zero violations. It currently returns 12.

**First violation** (representative): `attached_tmux_terminal_app_regression` — "Reducer regression coverage for attached tmux terminal-app inference is missing"

**What this means:** The behavioral spec defines contracts about what the codebase should contain (regression tests, specific fields, symbols). The codebase has drifted from these contracts — features were added/changed without updating the spec expectations.

**Key files:**
- `.verifier/specs/RuntimeBoundaryContracts.py` — the spec that defines runtime boundary contracts
- `tests/verify/unit/test_behavioral_specs.py:171` — the test that asserts zero violations
- `core/capacitor-core/src/reduce/mod.rs` — referenced by several violations

**Fix approach:**
1. Run the test with `self.maxDiff = None` to see ALL 12 violations clearly
2. For each violation, determine: (a) is the contract still valid and code needs fixing, or (b) has the code intentionally evolved and the spec needs updating?
3. Most likely outcome: the specs need updating to match the current codebase state (specs were written when certain regression tests and patterns existed that have since been refactored)
4. After fixing, the `Verifier Full` job should also pass (it was `skipped` because it depends on Self-Test)

**Quick diagnostic command:**
```bash
.verifier/.venv/bin/python -c "
import unittest; unittest.TestCase.maxDiff = None
" && .verifier/.venv/bin/python -m pytest tests/verify/unit/test_behavioral_specs.py::BehavioralSpecProofTests::test_runtime_boundary_contracts_pass_on_repo -x -s 2>&1 | tail -80
```

## Hardening CI (post-fix)

After fixing both failures, consider:
1. **SwiftFormat:** Pin by checksum or vendor the binary in-repo to prevent upstream version drift
2. **Verifier specs:** Add a CI step that reports behavioral spec violations as warnings instead of failing the build, or maintain a known-violations allowlist that ratchets down over time
3. **Pre-commit alignment:** Ensure the pre-commit hook runs the same checks CI does (currently local SwiftFormat is 0.59.1 but CI gets 0.60.1)

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `main`
- Working tree: clean (only untracked handoff files)
- HEAD: `49bae79 fix(verifier): update specs and fact extraction for RuntimeClientTypes.swift split`

## Key Artifacts
- `.github/workflows/ci.yml:251-258` — SwiftFormat install + version pin
- `apps/swift/Tests/CapacitorTests/DelegationReviewManifestTests.swift` — the file with lint errors
- `.verifier/specs/RuntimeBoundaryContracts.py` — behavioral spec with 12+ contract checks
- `tests/verify/unit/test_behavioral_specs.py:171` — the failing assertion
- `.swiftformat` — SwiftFormat config (uses `--swiftversion 6.2`)
- `scripts/ci/swiftformat-lint.sh` — the lint script CI runs

## Project Rules
- Use Codex workers for ALL implementation (manage-codex skill)
- SwiftFormat pinned to 0.59.1 in CI — needs updating to match actual binary
- `.swiftformat` uses `--swiftversion 6.2` — must match CI's Swift version
- Package.swift excluded from swiftformat
- Dylib must be copied to Swift build dir before `swift test`

## Established Decisions
- The elegance refactoring (B→A) is done and merged
- The `RuntimeClientTypes.swift` split required spec/fact-extraction updates (already committed in `49bae79`)
- The remaining 4 elegance violations (moveProject lizard false positive, 2 Rust nesting, 1 Python cc) are diminishing returns — not blocking

## Verification Commands
```bash
# SwiftFormat lint (local)
swiftformat --lint apps/swift

# Verifier self-test
.verifier/.venv/bin/python -m pytest tests/verify/unit/ -x

# Full CI check
./scripts/dev/run-tests.sh

# Push and watch CI
git push origin main && gh run watch
```

## Notes for the Next Agent
- CI has been red for 20+ consecutive runs across multiple features. Fixing these two jobs would be the first green CI in weeks.
- The SwiftFormat version drift is subtle — the CI config looks correct (`0.59.1`) but the downloaded binary is actually 0.60.1. Verify by checking the `swiftformat --version` output in CI logs.
- The behavioral spec violations are NOT about our RuntimeClient split — those were fixed in `49bae79`. The remaining 12 are about Rust reducer regression tests, tmux routing contracts, and other runtime boundary checks that drifted over time.
- `pip install pytest` in `.verifier/.venv/` is needed for local test runs (already installed in this session).
