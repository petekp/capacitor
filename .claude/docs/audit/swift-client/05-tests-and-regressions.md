# Tests And Regression Risks

### [TESTS] Finding 1: Time-Dependent Session Tests Fail As Calendar Advances

**Severity:** Medium
**Type:** Bug
**Location:** `apps/swift/Tests/CapacitorTests/SessionStateManagerTests.swift:322`, `apps/swift/Sources/Capacitor/Utilities/SessionStaleness.swift:10`, `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:464`

**Problem:**
Tests hardcode old timestamps (`2026-02-28...`) while production logic downgrades `working` to `ready` after 30s. As real time advances, assertions expecting `.working` fail.

**Evidence:**
`swift test --filter SessionStateManagerTests --skip-build` on March 5, 2026 fails 4 tests (`testApplyRuntimeProjectStatesHoldsSingleEmptySnapshotThenCommitsSecond`, `testIdleStabilizationCommitsAfterThreshold`, `testIdleStabilizationResetsOnActive`, plus an additional assertion in first test).

**Recommendation:**
Make tests deterministic by injecting `now` or generating timestamps relative to current test execution time.

### [TESTS] Finding 2: Critical New Edge Cases Lack Coverage

**Severity:** Medium
**Type:** Design flaw
**Location:** `apps/swift/Tests/CapacitorTests/SessionStateManagerTests.swift`, `apps/swift/Tests/CapacitorTests/AppStateSessionObservationTests.swift`

**Problem:**
Current tests do not cover several high-risk behaviors found in this audit.

**Evidence:**
No tests currently assert:
- Per-project metadata behavior when stabilization holds only subset of projects.
- Stale snapshot generation suppression for shell-state commits.
- Creation cancellation race against `startSessionMonitor`.

**Recommendation:**
Add focused regression tests for these paths before refactors.
