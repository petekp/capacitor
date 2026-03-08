import Foundation

@MainActor
protocol RuntimeAutomationTimer: AnyObject {
    func invalidate()
}

@MainActor
final class RuntimeAutomationController {
    private let bootstrapRuntime: @MainActor () async -> Void
    private let onTimerTick: @MainActor () -> Void
    private let scheduleRepeatingTimer: @MainActor (TimeInterval, @escaping () -> Void) -> RuntimeAutomationTimer

    private var bootstrapTask: _Concurrency.Task<Void, Never>?
    private var refreshTimer: RuntimeAutomationTimer?

    private(set) var didScheduleBootstrapForTesting = false
    private(set) var didStartRefreshTimerForTesting = false

    init(
        bootstrapRuntime: @escaping @MainActor () async -> Void,
        onTimerTick: @escaping @MainActor () -> Void,
        scheduleRepeatingTimer: @escaping @MainActor (TimeInterval, @escaping () -> Void) -> RuntimeAutomationTimer = { interval, block in
            LiveRuntimeAutomationTimer(interval: interval, block: block)
        }
    ) {
        self.bootstrapRuntime = bootstrapRuntime
        self.onTimerTick = onTimerTick
        self.scheduleRepeatingTimer = scheduleRepeatingTimer
    }

    func startBootstrap() {
        didScheduleBootstrapForTesting = true
        bootstrapTask?.cancel()
        bootstrapTask = _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            await bootstrapRuntime()
        }
    }

    func startRefreshLoop() {
        didStartRefreshTimerForTesting = true
        refreshTimer?.invalidate()
        refreshTimer = scheduleRepeatingTimer(2.0) { [weak self] in
            self?.onTimerTick()
        }
    }

    func stopAutomation() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

@MainActor
private final class LiveRuntimeAutomationTimer: RuntimeAutomationTimer {
    private var timer: Timer?

    init(interval: TimeInterval, block: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            DispatchQueue.main.async {
                block()
            }
        }
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}
