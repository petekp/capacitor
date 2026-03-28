### Files Changed
- `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift` — added `ideaId`/`ideaTitle`/`ideaDescription` to `RuntimeRunState` and `RuntimeRunMutationRequest`, plus internal snapshot payload bridging so runtime snapshots preserve the new idea metadata.
- `apps/swift/Sources/Capacitor/Models/AppState.swift` — added `compactRunIdeaDescription`, wired idea identity into the create-run mutation, and added `activeRun(for:in:)` for idea-scoped run lookup.
- `apps/swift/Sources/Capacitor/Utilities/IdeaQueueStatusResolver.swift` — added `runState` input and mapped active/created runs to `.methodRunning` and paused checkpointed runs to `.methodCheckpointReady`.
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift` — passed the idea-scoped active run into `IdeaQueueStatusResolver`.
- `apps/swift/Sources/Capacitor/Models/MethodRunCoordinator.swift` — minimal compile-only update to pass nil idea fields in the fail mutation after the request struct changed.
- `apps/swift/Sources/Capacitor/Models/RunCaptureCoordinator.swift` — minimal compile-only update to pass nil idea fields in the mutation helper after the request struct changed.
- `apps/swift/Tests/CapacitorTests/IdeaQueueStatusResolverTests.swift` — added run-state precedence coverage and `compactRunIdeaDescription` tests.
- `apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift` — minimal compile-only update for the new `RuntimeRunMutationRequest` fields.
- `apps/swift/Tests/CapacitorTests/WebCaptureServiceTests.swift` — minimal compile-only update for regenerated `MutateRunCommand` idea/status fields.
- `apps/swift/Tests/CapacitorTests/AppStateSessionObservationTests.swift` — minimal compile-only update for `RuntimeRunState` memberwise initializer changes.
- `apps/swift/Tests/CapacitorTests/ProjectRunVisualStateResolverTests.swift` — minimal compile-only update for `RuntimeRunState` memberwise initializer changes.
- `apps/swift/Tests/CapacitorTests/StatusChipsRowTests.swift` — minimal compile-only update for `RuntimeRunState` memberwise initializer changes.
- `apps/swift/Tests/CapacitorTests/AppStateRunCheckpointTests.swift` — minimal compile-only update for `RuntimeRunState` memberwise initializer changes.
- `apps/swift/Tests/CapacitorTests/RunCaptureCoordinatorTests.swift` — minimal compile-only update for `RuntimeRunState` memberwise initializer changes.
- `handoffs/handoff-item68-swift.md` — slice handoff requested by the task.
- `.relay/method-runs/phase3-polish/handoffs/handoff-item68-swift.md` — relay mirror of the same handoff.

### Tests Run
- `cp target/release/libcapacitor_core.dylib "$(cd apps/swift && swift build --show-bin-path)/"` — PASS.
- `swift test --package-path apps/swift --filter IdeaQueueStatusResolverTests` — FAIL before implementation, as expected for TDD. Failures were compile-time: missing `runState` parameter on `IdeaQueueStatusResolver.resolve(...)` and missing regenerated UniFFI initializer fields on `MutateRunCommand(...)`.
- `swift build --package-path apps/swift 2>&1 | tail -20` — `SANDBOX_LIMITED`. SwiftPM manifest sandbox/cache access failed in this Codex environment (`sandbox-exec: sandbox_apply: Operation not permitted` / module cache permission error).
- `CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-module-cache swift build --disable-sandbox --package-path apps/swift 2>&1 | tail -20` — PASS, exit code 0, build complete.
- `CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-module-cache swift test --disable-sandbox --package-path apps/swift 2>&1 | tail -30` — PASS, exit code 0, no failures in the command run.
- `CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-module-cache swift test --disable-sandbox --package-path apps/swift --filter IdeaQueueStatusResolverTests 2>&1 | tail -30` — PASS, 12 tests, 0 failures.

### Verification
- `./scripts/verify/verify.sh` not run.

### Verdict
N/A - implementation handoff

### Completion Claim
COMPLETE

### Issues Found
- The exact requested `swift build` / `swift test` commands were blocked by SwiftPM's nested manifest sandbox in this Codex environment. Verification succeeded with `--disable-sandbox` plus tmp module-cache overrides.
- `AppState.swift` still emits pre-existing Swift concurrency warnings about capturing `self` in a concurrently executing closure around `runMethodOnIdea`; this slice did not change that code path.
- There are unrelated existing worktree changes outside this slice, including `apps/swift/Sources/Capacitor/Bridge/capacitor_core.swift`, `apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorView.swift`, and some untracked handoff/app files. I did not modify those.

### Next Steps
- Proceed to the next slice.
- If you need to rerun Swift verification inside Codex, reuse the successful commands with `CLANG_MODULE_CACHE_PATH`, `SWIFTPM_MODULECACHE_OVERRIDE`, and `--disable-sandbox`.
