# Test Audit (Playbook Applied)

Date: 2026-03-01  
Scope: `core/`, `apps/swift/Tests/CapacitorTests/`, `tests/`, `services/ingest-worker/test/`

## Method

1. Inventory all tests by interface and leverage.
2. Flag tests asserting implementation details instead of behavior contracts.
3. Freeze current weak-pattern surface with a CI guard so debt cannot grow.
4. Define next rewrite slices to pay debt down deterministically.

## Current Metrics (After RW-088)

- Swift test files: `43`
- Swift test methods: `253`
- Swift files with `source.contains` assertions: `0`
- `source.contains` assertions (total): `0`
- Swift test methods inside source-coupled files: `0`
- Sleep calls in Swift tests (`Task.sleep`/`Thread.sleep`/`usleep`): `0`
- Rust test files: `22`
- Rust test functions: `237`
- bats files: `4`
- bats test cases: `19`
- Node worker test files: `2`
- Node worker test cases: `10`
- Static script-source assertions in bats (`run grep ... scripts/...`): `0`

## Unit/Interface Pull-Weight Assessment

### High leverage (keep, expand)

1. Deterministic domain contracts:
   - `core/capacitor-core/tests/replay_diff.rs`
2. Hook boundary mapping:
   - `core/hud-hook/tests/session_state_mapping_gate.rs`
3. Runtime behavior and workflow checks:
   - `apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift` (mostly behavior)
   - `tests/hud-hook/hud-hook-smoke.bats`
   - `tests/release-scripts/bump-version.bats`
   - `tests/release-scripts/generate-appcast.bats`
   - `services/ingest-worker/test/index.test.mjs`
   - `services/ingest-worker/test/lib.test.mjs`

### Medium leverage (keep, refactor)

1. `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`
   - Strong behavioral coverage of activation and tmux routing flows.
   - RW-016 replaced sleep-driven ordering with deterministic async gates and condition waits.

### Low leverage (replace)

Source-coupled Swift regression tests have been removed from the active suite (`source.contains` count is now zero).

Static bats source checks that do not execute behavior have been removed from the active suite.

## Hard Conclusions

1. The biggest mismatch is in Swift: too many tests verify code shape instead of observable contracts.
2. Runtime confidence is currently strongest in Rust replay + hook mapping tests, not in Swift architectural seam tests.
3. Script guardrail bats tests are useful tripwires but should not be treated as behavior confidence.
4. RW-015 removed the top four offenders and stripped source-inspection assertions from `RuntimeClientTests` and `TerminalLauncherTests` (43 source assertions removed total) with no behavior loss evidence from existing contract tests.
5. RW-016 removed all test sleep calls and set CI sleep budget to zero without reducing behavior coverage.
6. RW-017 replaced dev-script source-inspection tests with executable script behavior checks, reducing static bats source assertions from 10 to 3.
7. RW-018 removed the remaining source-coupled Swift test files and ratcheted CI to a zero-tolerance budget for `source.contains` assertions.
8. RW-019 removed the remaining static release-flow source checks; the static script-source assertion count is now zero.
9. RW-020 added first-class FFI contract invariants in both Swift and Rust (`RuntimeClientTests` + `core/capacitor-core/tests/ffi_contract.rs`) covering malformed shell timestamp rejection, read-disabled runtime-unavailable behavior, routing lookup fallback scope, reason-code normalization/defaulting, snapshot constructor contracts, and command required-field validation.
10. RW-021 collapsed four overlapping/supersession one-off `TerminalLauncherTests` into one table-driven overlap contract plus shared stale-marker helper, reducing test LOC and method count without behavior loss.
11. RW-022 collapsed snapshot-unavailable fallback permutations into one table-driven `TerminalLauncher` contract test, replacing multiple one-off variants while preserving behavior.
12. RW-024 merged the no-trusted-evidence launch/recovery variants into a single scenario table while preserving marker and latency assertions.
13. RW-023 expanded canonical Rust FFI command-envelope tests (`mutate_project`, `mutate_idea`, `mutate_worktree`) so validation/mutation semantics are locked at the source-of-truth boundary.
14. RW-025 collapsed remaining stale-primary and primary-failure fallback variants into one scenario matrix, deleting three one-off tests while preserving single-fallback and stale-suppression behavior contracts.
15. RW-026 collapsed six one-off launch script shape checks into one scenario-matrix invariant contract, reducing suite surface while retaining terminal support/fallback safety guarantees.
16. RW-027 consolidated duplicate Rust FFI required-field negative permutations into shared fixture builders and case tables, reducing maintenance overhead while preserving diagnostics guarantees.
17. RW-028 removed one exact duplicate activation fallback test and merged three attached-client switch-failure variants into one scenario table without behavior loss.
18. RW-029 centralized replay fixture loading and removed dead test anchor code, making replay-diff failures more maintainable without changing assertions.
19. RW-030 replaced five overlapping no-client Ghostty fallback tests with one scenario matrix while preserving explicit switch/fallback/no-window contracts.
20. RW-031 introduced focused action-shape assertion helpers in `TerminalLauncherTests` and removed repeated switch-case assertion scaffolding without altering coverage.
21. RW-032 replaced four repetitive dependency-backed route tests in `ActivationActionExecutorTests` with one matrix while preserving action/field-specific routing assertions.
22. RW-033 introduced tmux script predicate helpers in `TerminalLauncherTests`, reducing repeated script-shape assertion scaffolding without changing coverage.
23. RW-034 consolidated repeated RuntimeClient snapshot/client setup and routing snapshot expectation blocks into canonical helper contracts, and simplified replay-diff state-map construction through one shared helper with no behavioral assertion loss.
24. RW-035 replaced repeated activation result tuple assertions in `TerminalLauncherTests` with one context-labeled helper, reducing copy-paste while preserving per-scenario outcome checks.
25. RW-036 replaced one-off core-routing reason-code and diagnostics scope tests in `RuntimeClientTests` with explicit scenario matrices, reducing Swift test methods by three while preserving route and scope contracts.
26. RW-037 consolidated duplicate activation-app routing and ensure-fallback one-off tests in `ActivationActionExecutorTests` into scenario matrices, reducing Swift test methods by two with no assertion-surface regression.
27. RW-038 consolidated overlap-primary-stale, sequential ordering, and snapshot-unavailable debounce one-off tests in `TerminalLauncherTests` into scenario matrices, reducing Swift test methods by three while preserving stale-marker and fallback contracts.
28. RW-039 extracted canonical snapshot/last-error/mutate-project helpers in `core/capacitor-core/tests/ffi_contract.rs`, reducing repeated diagnostics assertion scaffolding while preserving FFI boundary validation semantics.
29. RW-040 introduced a canonical `withLogCollector` harness in `TerminalLauncherTests`, removing repeated DebugLog observer lifecycle scaffolding across arbitration, snapshot-fallback, and no-trusted-evidence scenario suites without changing behavior assertions.
30. RW-041 introduced a shared Rust hook-event test fixture module and removed cross-file fixture duplication between `ffi_contract.rs` and `replay_diff.rs` without changing contract coverage.
31. RW-042 collapsed one-off runtime snapshot failure tests (missing snapshot, read-disabled, invalid shell timestamp) and unavailable-routing fallback tests into two labeled scenario matrices in `RuntimeClientTests`, reducing Swift method count by three while preserving error-shape and fallback contracts.
32. RW-043 introduced canonical expected-action matching/assertion helpers in `TerminalLauncherTests` and rewired remaining scenario matrices to remove repeated action-branch assertion wiring without changing behavior expectations.
33. RW-044 introduced canonical ensure-fallback/no-window assertion helpers in `ActivationActionExecutorTests` and rewired repeated fallback-route assertions across scenario suites without changing behavior contracts.
34. RW-045 introduced a canonical `assertEventually` harness in `TerminalLauncherTests`, removing repeated async completion assertion scaffolding while preserving per-scenario timeout and marker contracts.
35. RW-046 introduced a canonical fixture builder in `ActivationActionExecutorTests`, reducing repeated stub/executor setup while preserving explicit per-scenario override configuration.
36. RW-047 introduced explicit named core-snapshot fixtures in `RuntimeClientTests` (`default`, `invalidShellTimestamp`, `routingReason`) and narrowed the base fixture constructor surface, reducing ad-hoc parameterized variants without changing behavior coverage.
37. RW-048 introduced a canonical expected-route assertion helper in `ActivationActionExecutorTests`, removing repeated per-field route assertions in scenario tables while preserving context-specific failure messages.
38. RW-049 introduced canonical required/forbidden script snippet helpers in `TerminalLauncherTests`, replacing repeated manual `scriptsContain` assertions while preserving script-level branch diagnostics.
39. RW-050 introduced a canonical activate-app result-route outcome helper in `ActivationActionExecutorTests`, replacing repeated success/dependency-route/Ghostty-route assertion bundles.
40. RW-052 replaced repeated inline `"[scenario]"` context-string interpolation in `ActivationActionExecutorTests`, `RuntimeClientTests`, and `TerminalLauncherTests` with localized `scenarioContext` helpers + per-loop `context` bindings, reducing assertion scaffolding noise without changing behavior contracts.
41. RW-053 replaced positional tuple-heavy route scenario setup in `RuntimeClientTests` with named scenario/expectation structs, reducing field-order ambiguity while preserving unavailable/attached route and diagnostics scope contracts.
42. RW-054 refactored `TerminalLauncherTests` snapshot-failure and no-trusted-evidence matrices to use shared expectation record structs, reducing repeated scalar expectation wiring while preserving action/result/debounce-marker contracts.
43. RW-055 introduced compact fallback expectation records and a shared host-switch fallback assertion helper in `ActivationActionExecutorTests`, removing repeated ensure-route/no-window assertion bundles while preserving branch-specific expectations.
44. RW-057 hardened hook settings compatibility in `runtime_setup` by supporting both string and object matcher forms, with regression coverage for preserving custom object-matcher entries and wildcard matcher detection logic.
45. RW-058 introduced shared typed expectation records for remaining repeated route-target assertions in `RuntimeClientTests` and `ActivationActionExecutorTests`, reducing scalar duplication while preserving scenario-specific behavior assertions.
46. RW-059 removed Swift-side direct JSON mutation for hook cleanup and moved uninstall semantics into canonical Rust `runtime_setup`, with regression tests proving managed-hook removal preserves user hooks and unrelated settings.
47. RW-060 pruned low-leverage script guardrail assertions in bats suites by removing duplicate invalid-version coverage and redundant restart help/runtime-state checks while preserving executable behavior coverage for release/dev script flows.
48. RW-061 collapsed repeated hook install orchestration from `AppState`, `SetupRequirements`, and startup auto-repair into `HookInstaller.ensureHooksInstalled` and added focused unit tests that lock binary-failure, install-failure, throw, status-mismatch, and success paths.
49. RW-062 removed `Helpers/RuntimeDateParser.swift` and made `Utilities/DateFormatting.swift` the single date parsing surface (including microsecond normalization), with all call sites rewired and tests renamed to `DateFormattingTests`.
50. RW-063 removed remaining ad-hoc `ISO8601DateFormatter()` allocations from hot paths (`DebugLog`, `RuntimeClient`, UniFFI date adapters) by routing through canonical date helpers.
51. RW-064 split conflicting config ownership by moving `CapacitorConfig` persistence to `~/.capacitor/runtime-config.json` (with legacy-read migration) and added contract tests that lock non-collision with `AppConfig` file semantics.
52. RW-065 removed remaining private ISO8601 formatter duplicates in `Telemetry`, `QuickFeedback`, and `DiagnosticsSnapshotLogger`, routing all timestamp formatting through canonical date helpers.
53. RW-066 removed dead `CapacitorConfig` persistence fields/mutations (`setupCompletedAt`, `hooksVersion`, `markSetupComplete`) and deleted the redundant setup-complete write path in `WelcomeView`.
54. RW-067 introduced a canonical `HookSetupCopy` mapper for setup-step status copy, setup-card presentation copy, and startup hook diagnostics messaging, replacing duplicated hook-status text branches across `SetupRequirements`, `HookDiagnosticPresentation`, and `AppDelegate` with focused contract tests.
55. RW-068 moved the remaining `Utils/*` files into explicit `Support/*` namespaces (`Config`, `Accessibility`, `Health`, `Updates`), deleted `Utils/`, and added a rewrite denylist to prevent ambiguous utility sprawl from re-entering the active codebase.
56. RW-069 introduced a canonical `SetupStepCatalog` and rewired runtime + preview setup step construction through that single factory surface, eliminating repeated step literals and locking metadata/status contracts with focused catalog tests.
57. RW-070 moved pure pathing/identity helpers (`GitRepositoryInfo`, `PathNormalizer`, `WorkspaceIdentity`) from ambiguous `Helpers/` into `Support/Pathing`, keeping only IO-oriented adapters in `Helpers/` and reducing role confusion for new contributors/agents.
58. RW-071 introduced a startup `SetupReadinessCoordinator` decision surface (driven by `checkSetupStatus()`), rewired `AppDelegate.validateHookSetup` to consume it, and added focused coordinator tests so startup/setup policy no longer diverges across independent branches.
59. RW-072 replaced parallel hook presentation layers by renaming `HookSetupCopy` to canonical `HookPresentationPolicy` and keeping `HookDiagnosticPresentation` as a thin adapter over that policy, removing split ownership of hook UI/status copy semantics.
60. RW-073 replaced startup log string assembly with typed `DebugLog.StartupEvent` contracts and moved formatting ownership to `DebugLog`, preventing copy drift across startup decision call sites.
61. RW-074 removed low-leverage source-inspection regression suites and added a dedicated CI `test-surface-audit` gate so weak-pattern test debt cannot regrow unnoticed.
62. RW-075 added canonical Rust FFI contract coverage (`core/capacitor-core/tests/ffi_contract.rs`) and shared replay/contract fixtures to tighten boundary invariants while reducing duplicated test scaffolding.
63. RW-076 replaced stringly setup-step routing with a typed `SetupStepID` surface across `SetupRequirementsManager`, `SetupStepCatalog`, and `WelcomeView`, and added focused manager execution contracts to guard the new typed path.
64. RW-077 consolidated remaining release-script bats duplication with shared helper assertions and compact invalid-input loops, preserving behavior checks while reducing repetitive scaffolding.
65. RW-078 replaced repetitive setup preview scenario array literals with typed scenario records and added explicit preview scenario contract tests for step-order/status parity.
66. RW-079 consolidated setup onboarding contract assertions into labeled scenario-table tests (`HookPresentationPolicyTests`, `SetupReadinessCoordinatorTests`), reducing one-off test method count while preserving explicit branch coverage.
67. RW-080 centralized shell/hook setup status copy assertions into one canonical scenario-table suite (`SetupStatusCopyContractTests`) and removed redundant copies from adjacent setup suites without reducing behavior coverage.
68. RW-081 introduced a shared setup fixture module (`SetupTestFixtures`) and removed duplicated setup status/diagnostic constructor scaffolding from readiness and hook diagnostic suites without changing behavior assertions.
69. RW-082 consolidated hook diagnostic presentation assertions into two labeled contract matrices (visibility + header/guidance), reducing one-off test methods while preserving behavior semantics.
70. RW-083 introduced a shared labeled setup scenario harness (`SetupScenarioHarness`) and rewired setup readiness/status contract suites to remove repeated local scenario record scaffolding without changing test-method coverage.
71. RW-084 collapsed setup manager `executeStep` one-off assertions into a labeled action-routing matrix (`SetupRequirementsManagerTests`) and extended the shared setup scenario harness with async contract support, reducing Swift test methods by one without behavior loss.
72. RW-085 converged remaining setup presentation scenario tables (`HookPresentationPolicyTests`, `HookDiagnosticPresentationTests`) onto the shared labeled harness, removing parallel scenario struct patterns while preserving explicit projected expectation records.
73. RW-086 pruned duplicate scenario rows from setup/hook contract suites and kept one-row-per-branch semantics by adding a healthy visibility branch case while removing duplicate branch-equivalent rows.
74. RW-087 extended shared labeled scenario records beyond setup suites by replacing ad-hoc local scenario structs in `RuntimeClientTests`, improving scenario-definition consistency across contract suites.
75. RW-088 added an explicit scenario-coverage checklist to the rewrite playbook so table-driven suites maintain one-row-per-branch rigor and avoid branch-equivalent duplicate regrowth.
76. Next reductions should continue collapsing duplicate edge-case assertions into explicit contract tables rather than proliferating one-off tests.

## Guardrails Added

CI now enforces a frozen debt budget via:

- `scripts/ci/test-surface-audit.sh --check`

Blocked-on-growth patterns:

1. New Swift files using `source.contains` outside allowlist.
2. Growth in source-coupled file/method/assert counts.
3. New sleep usage outside allowlist.
4. Growth in static bats script-source grep assertions.

This does not claim these patterns are good. It prevents regression while we pay them down slice-by-slice.

## Next Slices (proposed)

1. `RW-089` Extend shared harness usage to remaining non-setup suites with repeated local scenario records (`ActivationActionExecutorTests`, `TerminalLauncherTests`) where it improves clarity.
2. `RW-090` Re-evaluate test-surface metrics and tighten guard budgets if no regressions appear after RW-089 convergence.

Each slice should delete replaced tests in the same PR and ratchet the audit limits downward.
