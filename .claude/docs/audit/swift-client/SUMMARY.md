# Swift Client Audit Summary

## Findings Count
- High: 8
- Medium: 7
- Low: 1
- Total: 16

## Top 5 Most Critical Issues
1. **Setup crash path**: onboarding can hard-crash when `CoreRuntime` init fails (`SetupRequirementsManager` fatalError).
2. **State consistency gap**: stale runtime snapshot suppression does not protect shell-state commits.
3. **Session metadata correctness bug**: stabilization hold in one project freezes attribution/session metadata for all projects.
4. **Terminal subprocess race**: unsynchronized `outputData` mutation in process output callbacks.
5. **User-visible ingestion race**: drag-drop flow can drop valid URLs due `DispatchGroup` ordering bug.

## Recommended Fix Order
1. **Crash + hard correctness first**
   - Replace onboarding `fatalError` path with recoverable setup error state.
   - Fix stale shell-state commit gating.
   - Fix global metadata freeze during stabilization hold.
2. **Concurrency hazards in process/runtime paths**
   - Synchronize `runBashScriptWithResult` output capture.
   - Add cancellation/timeout + child process termination for async shell commands.
   - Fix drag-drop `DispatchGroup` race.
3. **Lifecycle race cleanup**
   - Prevent cancelled creations from being reactivated by monitors.
   - Track/cancel monitor tasks and health-check tasks.
4. **Performance and UX stability**
   - Move blocking git subprocess calls off `@MainActor`.
   - Avoid main-thread blocking in hook-server `stop()`.
5. **Reliability hardening**
   - Harden hook pid adoption checks.
   - Repair time-dependent tests and add missing regression tests for new edge cases.
   - Update stale comments to match current architecture.

## Artifact Index
- `00-analysis-plan.md`
- `01-runtime-state-and-resolution.md`
- `02-terminal-activation-and-process.md`
- `03-creation-and-ingestion.md`
- `04-setup-and-lifecycle.md`
- `05-tests-and-regressions.md`
