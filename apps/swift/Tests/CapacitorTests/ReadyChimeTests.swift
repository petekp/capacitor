@testable import Capacitor
import XCTest

final class ReadyChimeTests: XCTestCase {
    func testPlaySkipsPlaybackWhenEngineCannotRun() {
        let backend = StubReadyChimeAudioBackend(engineCanRun: false)
        let readyChime = ReadyChime(backend: backend, runAsync: { work in work() })

        readyChime.play()

        XCTAssertEqual(backend.ensureEngineRunningCallCount, 1)
        XCTAssertEqual(backend.playDualToneCallCount, 0)
    }

    func testPlayPreservesSuccessfulPlaybackBehavior() {
        let backend = StubReadyChimeAudioBackend(engineCanRun: true)
        let readyChime = ReadyChime(backend: backend, runAsync: { work in work() })

        readyChime.play()

        XCTAssertEqual(backend.ensureEngineRunningCallCount, 1)
        XCTAssertEqual(backend.playDualToneCallCount, 1)
    }

    func testPlayResetsStateWhenEngineCannotRun() {
        let backend = StubReadyChimeAudioBackend(engineCanRun: false)
        let readyChime = ReadyChime(backend: backend, runAsync: { work in work() })

        readyChime.play()
        readyChime.play()

        XCTAssertEqual(backend.ensureEngineRunningCallCount, 2)
        XCTAssertEqual(backend.playDualToneCallCount, 0)
    }

    func testPlayCoalescesOverlapIntoSinglePendingPlayback() {
        let backend = StubReadyChimeAudioBackend(engineCanRun: true)
        var queuedWork: [() -> Void] = []
        let readyChime = ReadyChime(
            backend: backend,
            runAsync: { work in
                queuedWork.append(work)
            },
        )

        readyChime.play(trigger: "first")
        readyChime.play(trigger: "second")

        XCTAssertEqual(queuedWork.count, 1, "Second overlap should be coalesced until first playback finishes.")

        queuedWork.removeFirst()()
        XCTAssertEqual(queuedWork.count, 1, "Coalesced playback should be scheduled after current playback completes.")

        queuedWork.removeFirst()()

        XCTAssertEqual(backend.ensureEngineRunningCallCount, 2)
        XCTAssertEqual(backend.playDualToneCallCount, 2)
    }

    func testPlayLogsEngineStartFailureWithActionTag() {
        let backend = StubReadyChimeAudioBackend(engineCanRun: false)
        var logLines: [String] = []
        let readyChime = ReadyChime(
            backend: backend,
            runAsync: { work in work() },
            logger: { line in
                logLines.append(line)
            },
        )

        readyChime.play(trigger: "test_failure")

        XCTAssertTrue(logLines.contains { $0.contains("action=engine_start_failed") })
    }

    func testPlayLogsPlaybackFailureWithActionTag() {
        let backend = StubReadyChimeAudioBackend(
            engineCanRun: true,
            playbackOutcomes: [false],
        )
        var logLines: [String] = []
        let readyChime = ReadyChime(
            backend: backend,
            runAsync: { work in work() },
            logger: { line in
                logLines.append(line)
            },
        )

        readyChime.play(trigger: "playback_failure")

        XCTAssertTrue(logLines.contains { $0.contains("action=play_failed") })
    }

    func testPlayDrainsPendingRequestWhenPlaybackFails() {
        let backend = StubReadyChimeAudioBackend(
            engineCanRun: true,
            playbackOutcomes: [false, true],
        )
        var queuedWork: [() -> Void] = []
        var logLines: [String] = []
        let readyChime = ReadyChime(
            backend: backend,
            runAsync: { work in
                queuedWork.append(work)
            },
            logger: { line in
                logLines.append(line)
            },
        )

        readyChime.play(trigger: "first")
        readyChime.play(trigger: "second")

        XCTAssertEqual(queuedWork.count, 1)

        queuedWork.removeFirst()()
        XCTAssertEqual(queuedWork.count, 1, "Pending playback should still drain after a playback failure.")

        queuedWork.removeFirst()()

        XCTAssertEqual(backend.ensureEngineRunningCallCount, 2)
        XCTAssertEqual(backend.playDualToneCallCount, 2)
        XCTAssertTrue(logLines.contains { $0.contains("action=play_failed") })
        XCTAssertTrue(logLines.contains { $0.contains("action=drain_pending") })
        XCTAssertTrue(logLines.contains { $0.contains("action=played") })
    }
}

private final class StubReadyChimeAudioBackend: ReadyChime.AudioBackend {
    var ensureEngineRunningCallCount = 0
    var playDualToneCallCount = 0

    private let engineCanRun: Bool
    private var playbackOutcomes: [Bool]

    init(engineCanRun: Bool, playbackOutcomes: [Bool] = [true]) {
        self.engineCanRun = engineCanRun
        self.playbackOutcomes = playbackOutcomes
    }

    func ensureEngineRunning() -> Bool {
        ensureEngineRunningCallCount += 1
        return engineCanRun
    }

    func playDualTone() -> Bool {
        playDualToneCallCount += 1
        guard !playbackOutcomes.isEmpty else { return true }
        return playbackOutcomes.removeFirst()
    }
}
