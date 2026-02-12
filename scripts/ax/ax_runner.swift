#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

private struct RawScenario: Decodable {
    let steps: [RawStep]
}

private struct RawStep: Decodable {
    let type: String
    let duration: TimeInterval?
    let identifier: String?
    let chord: String?
    let timeout: TimeInterval?
    let visible: Bool?
}

private enum Step {
    case wait(duration: TimeInterval)
    case click(identifier: String, timeout: TimeInterval, visible: Bool)
    case key(chord: String)

    static func from(raw: RawStep) throws -> Step {
        switch raw.type {
        case "wait":
            guard let duration = raw.duration, duration >= 0 else {
                throw RunnerError.invalidScenario("wait step requires non-negative duration")
            }
            return .wait(duration: duration)

        case "click":
            guard let identifier = raw.identifier, !identifier.isEmpty else {
                throw RunnerError.invalidScenario("click step requires identifier")
            }
            return .click(identifier: identifier, timeout: raw.timeout ?? 10, visible: raw.visible ?? false)

        case "key":
            guard let chord = raw.chord, !chord.isEmpty else {
                throw RunnerError.invalidScenario("key step requires chord")
            }
            return .key(chord: chord)

        default:
            throw RunnerError.invalidScenario("unsupported step type: \(raw.type)")
        }
    }
}

private enum ClickMode: String {
    case scenario
    case ax
    case visible
}

private struct RunnerConfig {
    let bundleID: String
    let scenarioPath: String
    let processTimeout: TimeInterval
    let clickMode: ClickMode
}

private enum RunnerError: LocalizedError {
    case invalidArguments(String)
    case invalidScenario(String)
    case accessibilityNotTrusted
    case appNotFound(bundleID: String, timeout: TimeInterval)
    case windowNotFound(bundleID: String)
    case elementNotFound(identifier: String, timeout: TimeInterval)
    case actionFailed(identifier: String, status: AXError)
    case unsupportedKeyChord(String)
    case eventSourceUnavailable

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message):
            return message
        case let .invalidScenario(message):
            return message
        case .accessibilityNotTrusted:
            return "Accessibility permission is required for AX automation."
        case let .appNotFound(bundleID, timeout):
            return "Timed out waiting \(timeout)s for app \(bundleID)."
        case let .windowNotFound(bundleID):
            return "No AX windows were found for \(bundleID)."
        case let .elementNotFound(identifier, timeout):
            return "Timed out waiting \(timeout)s for AX identifier \(identifier)."
        case let .actionFailed(identifier, status):
            return "AXPress failed for \(identifier) with status \(status.rawValue)."
        case let .unsupportedKeyChord(chord):
            return "Unsupported key chord: \(chord)."
        case .eventSourceUnavailable:
            return "Could not create CGEvent source for key synthesis."
        }
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private func log(_ event: String, _ fields: [String: Any] = [:]) {
    var payload = fields
    payload["event"] = event
    payload["ts"] = isoFormatter.string(from: Date())

    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8)
    {
        print(line)
    } else {
        print("[ax_runner] \(event) \(fields)")
    }
}

private func parseArgs() throws -> RunnerConfig {
    var bundleID = "com.capacitor.app.debug"
    var scenarioPath: String?
    var processTimeout: TimeInterval = 30
    var clickMode: ClickMode = .scenario

    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--bundle-id":
            index += 1
            guard index < args.count else {
                throw RunnerError.invalidArguments("--bundle-id requires a value")
            }
            bundleID = args[index]

        case "--scenario":
            index += 1
            guard index < args.count else {
                throw RunnerError.invalidArguments("--scenario requires a value")
            }
            scenarioPath = args[index]

        case "--process-timeout":
            index += 1
            guard index < args.count, let timeout = TimeInterval(args[index]), timeout > 0 else {
                throw RunnerError.invalidArguments("--process-timeout requires a positive numeric value")
            }
            processTimeout = timeout

        case "--click-mode":
            index += 1
            guard index < args.count, let value = ClickMode(rawValue: args[index]) else {
                throw RunnerError.invalidArguments("--click-mode requires one of: scenario, ax, visible")
            }
            clickMode = value

        default:
            throw RunnerError.invalidArguments("Unknown argument: \(arg)")
        }
        index += 1
    }

    guard let scenarioPath else {
        throw RunnerError.invalidArguments("Missing required --scenario argument")
    }

    return RunnerConfig(
        bundleID: bundleID,
        scenarioPath: scenarioPath,
        processTimeout: processTimeout,
        clickMode: clickMode,
    )
}

private func loadScenario(path: String) throws -> [Step] {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    let raw = try JSONDecoder().decode(RawScenario.self, from: data)
    return try raw.steps.map(Step.from(raw:))
}

private func ensureAccessibilityTrusted() throws {
    let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else {
        throw RunnerError.accessibilityNotTrusted
    }
}

private func waitForRunningApp(bundleID: String, timeout: TimeInterval) throws -> NSRunningApplication {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated })
        {
            return app
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    throw RunnerError.appNotFound(bundleID: bundleID, timeout: timeout)
}

private func copyAttribute(_ element: AXUIElement, name: CFString) -> AnyObject? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name, &value)
    guard result == .success else { return nil }
    return value
}

private func copyPointAttribute(_ element: AXUIElement, name: CFString) -> CGPoint? {
    guard let value = copyAttribute(element, name: name) else { return nil }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
    return point
}

private func copySizeAttribute(_ element: AXUIElement, name: CFString) -> CGSize? {
    guard let value = copyAttribute(element, name: name) else { return nil }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
    return size
}

private func elementCenterPoint(_ element: AXUIElement) -> CGPoint? {
    guard let position = copyPointAttribute(element, name: kAXPositionAttribute as CFString),
          let size = copySizeAttribute(element, name: kAXSizeAttribute as CFString)
    else {
        return nil
    }
    return CGPoint(x: position.x + (size.width / 2), y: position.y + (size.height / 2))
}

private func childElements(of element: AXUIElement) -> [AXUIElement] {
    let attributes: [CFString] = [
        kAXWindowsAttribute as CFString,
        kAXChildrenAttribute as CFString,
        kAXVisibleChildrenAttribute as CFString,
        kAXRowsAttribute as CFString,
        kAXContentsAttribute as CFString,
        kAXTabsAttribute as CFString,
    ]

    var children: [AXUIElement] = []
    for attribute in attributes {
        if let value = copyAttribute(element, name: attribute) as? [AXUIElement] {
            children.append(contentsOf: value)
        }
    }
    return children
}

private func findElement(
    identifier: String,
    in appElement: AXUIElement,
) -> AXUIElement? {
    var queue = childElements(of: appElement)
    if queue.isEmpty {
        queue = [appElement]
    }

    while !queue.isEmpty {
        let current = queue.removeFirst()
        if let value = copyAttribute(current, name: kAXIdentifierAttribute as CFString) as? String,
           value == identifier
        {
            return current
        }
        queue.append(contentsOf: childElements(of: current))
    }

    return nil
}

private func waitForElement(
    identifier: String,
    in appElement: AXUIElement,
    timeout: TimeInterval,
) throws -> AXUIElement {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let element = findElement(identifier: identifier, in: appElement) {
            return element
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    throw RunnerError.elementNotFound(identifier: identifier, timeout: timeout)
}

private func waitForWindow(in appElement: AXUIElement, timeout: TimeInterval, bundleID: String) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let windows = copyAttribute(appElement, name: kAXWindowsAttribute as CFString) as? [AXUIElement],
           !windows.isEmpty
        {
            return
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    throw RunnerError.windowNotFound(bundleID: bundleID)
}

private struct KeyChord {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

private func parseKeyChord(_ raw: String) throws -> KeyChord {
    let normalized = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    if normalized == "escape" || normalized == "esc" {
        return KeyChord(keyCode: 53, flags: [])
    }

    let parts = normalized.split(separator: "+").map(String.init)
    guard let keyToken = parts.last else {
        throw RunnerError.unsupportedKeyChord(raw)
    }

    var flags: CGEventFlags = []
    for modifier in parts.dropLast() {
        switch modifier {
        case "cmd", "command", "⌘":
            flags.insert(.maskCommand)
        case "shift", "⇧":
            flags.insert(.maskShift)
        case "opt", "option", "⌥":
            flags.insert(.maskAlternate)
        case "ctrl", "control", "⌃":
            flags.insert(.maskControl)
        default:
            throw RunnerError.unsupportedKeyChord(raw)
        }
    }

    let keyMap: [String: CGKeyCode] = [
        "1": 18,
        "2": 19,
        "3": 20,
        "4": 21,
        "5": 23,
        "6": 22,
        "7": 26,
        "8": 28,
        "9": 25,
        "0": 29,
    ]

    guard let keyCode = keyMap[keyToken] else {
        throw RunnerError.unsupportedKeyChord(raw)
    }

    return KeyChord(keyCode: keyCode, flags: flags)
}

private func sendKeyChord(_ chord: KeyChord) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw RunnerError.eventSourceUnavailable
    }

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: false)
    else {
        throw RunnerError.eventSourceUnavailable
    }

    keyDown.flags = chord.flags
    keyUp.flags = chord.flags

    keyDown.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.04)
    keyUp.post(tap: .cghidEventTap)
}

private func sendMouseClick(at point: CGPoint) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw RunnerError.eventSourceUnavailable
    }

    guard let move = CGEvent(
        mouseEventSource: source,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    ),
        let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ),
        let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )
    else {
        throw RunnerError.eventSourceUnavailable
    }

    move.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.04)
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    up.post(tap: .cghidEventTap)
}

private func activateApp(_ app: NSRunningApplication) {
    if #available(macOS 14.0, *) {
        _ = app.activate()
    } else {
        _ = app.activate(options: [.activateIgnoringOtherApps])
    }
}

private func performClick(
    identifier: String,
    app: NSRunningApplication,
    appElement: AXUIElement,
    timeout: TimeInterval,
    visible: Bool,
) throws {
    let element = try waitForElement(identifier: identifier, in: appElement, timeout: timeout)

    if visible {
        if let point = elementCenterPoint(element) {
            activateApp(app)
            Thread.sleep(forTimeInterval: 0.12)
            try sendMouseClick(at: point)
            return
        }
        log("step.click.visible_fallback", ["identifier": identifier, "reason": "missing_element_geometry"])
    }

    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else {
        throw RunnerError.actionFailed(identifier: identifier, status: result)
    }
}

private func run() throws {
    let config = try parseArgs()
    let steps = try loadScenario(path: config.scenarioPath)

    log("runner.start", [
        "bundleID": config.bundleID,
        "clickMode": config.clickMode.rawValue,
        "scenarioPath": config.scenarioPath,
        "stepCount": steps.count,
    ])

    try ensureAccessibilityTrusted()

    let app = try waitForRunningApp(bundleID: config.bundleID, timeout: config.processTimeout)
    activateApp(app)

    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    try waitForWindow(in: appElement, timeout: config.processTimeout, bundleID: config.bundleID)

    for (index, step) in steps.enumerated() {
        log("step.start", ["index": index])

        switch step {
        case let .wait(duration):
            log("step.wait", ["index": index, "duration": duration])
            Thread.sleep(forTimeInterval: duration)

        case let .click(identifier, timeout, stepVisible):
            let effectiveVisible = switch config.clickMode {
            case .scenario:
                stepVisible
            case .ax:
                false
            case .visible:
                true
            }
            log("step.click", [
                "index": index,
                "identifier": identifier,
                "timeout": timeout,
                "visible": effectiveVisible,
            ])
            try performClick(
                identifier: identifier,
                app: app,
                appElement: appElement,
                timeout: timeout,
                visible: effectiveVisible,
            )

        case let .key(chord):
            log("step.key", ["index": index, "chord": chord])
            let parsed = try parseKeyChord(chord)
            activateApp(app)
            Thread.sleep(forTimeInterval: 0.15)
            try sendKeyChord(parsed)
        }

        log("step.complete", ["index": index])
    }

    log("runner.complete")
}

do {
    try run()
} catch {
    log("runner.error", ["message": error.localizedDescription])
    fputs("ax_runner error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
