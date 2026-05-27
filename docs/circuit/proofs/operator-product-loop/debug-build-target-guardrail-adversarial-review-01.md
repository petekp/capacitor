# Debug Build Target Guardrail Adversarial Review 01

Date: 2026-05-26

## Scope

Reviewed the wrong-build prevention change after Computer Use attached to `/Applications/Capacitor.app` instead of the repo Debug app during live Work Batch verification.

## Findings

No medium, high, or critical findings.

Low: The guard prevents accidental mixed release+Debug verification in the dev scripts, but it cannot stop a user from intentionally opening `/Applications/Capacitor.app` after the diagnostic has passed. This is acceptable because the diagnostic now fails in that state, and manual automation should target the Debug bundle by full path.

Low: Computer Use can still pick the installed release app if invoked with the ambiguous name `Capacitor`. This is now documented as an invalid manual-testing practice for this slice, and the correct call using `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app` was verified.

## Rechecked Requirements

- Canonical restart must not leave `/Applications/Capacitor.app` running.
- Diagnostic evidence must include the actual front app path.
- Diagnostic evidence must refuse a mixed release+Debug state by default.
- Tests must prove both release cleanup and explicit override behavior.
- Live manual evidence must target `com.capacitor.app.debug`.

## Verdict

Clean for this milestone. Do not mark the full hardening goal complete yet; terminal/session duplicate matrices, checkpoint live UX, and broader task-routing live checks still need more proof.
