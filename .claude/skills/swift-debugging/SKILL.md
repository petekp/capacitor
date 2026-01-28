---
name: swift-debugging
description: Debug Swift applications where Logger/OSLog output isn't visible. Use when (1) debugging unsigned Swift builds run via `swift run`, (2) OSLog/Logger calls produce no output in Console.app or `log stream`, (3) need to capture logs from SPM packages or CLI tools during development, or (4) troubleshooting why Swift logging isn't working.
---

# Swift Debugging

Debug Swift applications, especially unsigned debug builds where standard logging doesn't capture output.

## OSLog Limitation: Unsigned Debug Builds

Swift's `Logger` (OSLog) writes to the unified logging system, but **for unsigned debug builds run via `swift run`, logs are NOT captured** by `log show` or `log stream`.

### Symptoms

- `logger.info()` calls produce no output in Console.app
- `log stream --predicate 'subsystem == "com.myapp"'` shows nothing
- App runs fine, but no log output visible

### Why This Happens

Unsigned binaries lack entitlements for the unified logging system. Affects:
- SPM packages run with `swift run`
- Debug builds without development certificate signing
- CLI tools during development

## Workaround: Stderr Telemetry

Write directly to stderr for debugging sessions:

```swift
private func telemetry(_ message: String) {
    FileHandle.standardError.write(Data("[TELEMETRY] \(message)\n".utf8))
}
```

Capture output:
```bash
./MyApp 2> /tmp/telemetry.log &
tail -f /tmp/telemetry.log
```

For backgrounded apps:
```bash
nohup ./MyApp > /tmp/app.stdout 2> /tmp/app.stderr &
```

## When to Use Each Approach

| Scenario | Approach |
|----------|----------|
| Production/signed builds | OSLog `Logger` |
| Debug builds needing log visibility | Stderr telemetry |
| CI/automated testing | Stderr (always captured) |
| Quick local debugging | Print statements (stdout) |

## Conditional Telemetry

Add during debugging, remove before committing:

```swift
#if DEBUG
private func telemetry(_ message: String) {
    FileHandle.standardError.write(Data("[TELEMETRY] \(message)\n".utf8))
}
#endif
```

Or use compile flag:
```swift
#if TELEMETRY_ENABLED
telemetry("Debug info: \(value)")
#endif
```

## Log File Patterns

```bash
# Combined stdout/stderr
./MyApp > /tmp/app.log 2>&1

# Separate files
./MyApp > /tmp/stdout.log 2> /tmp/stderr.log

# Watch updates
tail -f /tmp/app.log
```

## OSLog for Signed Builds

When OSLog works (signed builds):

```swift
import OSLog

private let logger = Logger(subsystem: "com.company.app", category: "networking")

logger.debug("Request started")   // Debug builds only
logger.info("User logged in")     // Informational
logger.error("Failed: \(error.localizedDescription)")
```
