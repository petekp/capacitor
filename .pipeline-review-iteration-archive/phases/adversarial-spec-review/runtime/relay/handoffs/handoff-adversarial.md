### Files Changed
None - review only.

### Tests Run
- `cargo fmt --all -- --check` — PASS
- `cargo clippy -- -D warnings` — PASS
- `cargo test` — PASS, 258 passed, 0 failed
- `cargo test -p capacitor-core` — PASS, 227 passed, 0 failed
- `cargo test -p capacitor-core --test delegation_contract` — PASS, 2 passed, 0 failed
- `swift test --package-path apps/swift` — PASS, 329 passed, 0 failed
- `./scripts/verify/verify.sh --layers 1,2` — PASS, layer 1 passed with 0 violations / 0 errors, layer 2 passed with 0 violations / 0 errors
- `./scripts/verify/verify.sh --grade` — PASS, overall verifier passed with grade `C` and 12 elegance warnings in `.verifier/reports/last-run.json`

Extra prep run to make `swift test` reliable with the release dylib linkage:
- `cargo build -p capacitor-core --release` — PASS
- `swift build --package-path apps/swift --show-bin-path` — PASS
- `cp target/release/libcapacitor_core.dylib apps/swift/.build/arm64-apple-macosx/debug/` — PASS

### Verification
`./scripts/verify/verify.sh --layers 1,2` passed. `./scripts/verify/verify.sh --grade` also passed, but the grade report is `C` with 12 pre-existing elegance warnings, not a clean elegance result.

### Verdict
ISSUES FOUND

### Completion Claim
COMPLETE

### Issues Found
- The spec's planned "decision preserved on disk" recovery path is incompatible with its own active-milestone invariant and will not survive restart.
- Wrong-directory, skipped-number, and completion-marker conflict cases are still unvalidated, so off-protocol worker behavior can deadlock the loop or skip review.
- There is no stuck/protocol-violation state for incomplete or never-finished milestones.
- The standalone review window is missing a concrete per-project state owner and conflicts with current main-window navigation side effects.
- The spec is internally inconsistent about readiness, sentinel usage, corrupt manifests, and request-changes exit behavior.

### Next Steps
- Revise the spec before implementation to define recovery semantics for failures after `decision.json` is written, validate the expected next milestone number explicitly, add a stuck/protocol-violation surface, and specify how review-window identity is carried independently of `projectView`.
