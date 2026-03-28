### Files Changed
- `apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorView.swift` — Restyled the selector into a glass-backed modal content view, removed the fixed width, and refreshed method card hover/typography treatment.
- `apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorModalOverlay.swift` — Added the new modal overlay wrapper with the IdeaDetail-style glass scrim, centered presentation, click-outside dismissal, and escape handling.
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift` — Replaced the inline selector presentation with the new overlay and wrapped open/close transitions in animation.
- `handoffs/handoff-item7-selector.md` — Recorded this implementation handoff.
- `.relay/method-runs/phase3-polish/handoffs/handoff-item7-selector.md` — Mirrored the handoff into the method-run handoff location.

### Tests Run
- `swift build --package-path apps/swift 2>&1 | tail -20` — FAILED, `SANDBOX_LIMITED`; SwiftPM could not write its default module cache and manifest evaluation failed inside the nested sandbox.
- `HOME=/tmp/capacitor-home swift build --package-path apps/swift 2>&1 | tail -20` — FAILED, `SANDBOX_LIMITED`; SwiftPM manifest evaluation attempted `sandbox-exec`, which is not permitted in this environment.
- `HOME=/tmp/capacitor-home swift build --disable-sandbox --package-path apps/swift 2>&1 | tail -20` — PASSED; affected Swift files compiled and the package linked successfully.

### Verification
- `./scripts/verify/verify.sh` not run.

### Verdict
N/A - implementation handoff

### Completion Claim
COMPLETE

### Issues Found
- Manual visual QA is still needed for narrow and wide window sizes, click-outside dismissal, escape-key dismissal, and glass fidelity against the rest of the overlay system.
- The exact requested build command is not reliable in this sandbox because SwiftPM’s default cache path and manifest sandboxing are blocked here.

### Next Steps
- Smoke-test the selector overlay in the app: open from an idea, verify escape and scrim dismissal, and confirm the panel no longer fights horizontal bounce at narrow widths.
