import AVFoundation
import Foundation
import ReadyChimeObjCExceptionCatcher

final class ReadyChime {
    typealias AsyncRunner = (@escaping () -> Void) -> Void
    typealias Logger = (String) -> Void

    protocol AudioBackend: AnyObject {
        func ensureEngineRunning() -> Bool
        func playDualTone() -> Bool
    }

    static let shared = ReadyChime()

    private struct PlaybackRequest {
        let id: UInt64
        let trigger: String
        let projectPath: String?
    }

    private enum EnqueueDecision {
        case start(PlaybackRequest)
        case coalesce(PlaybackRequest)
    }

    private let backend: AudioBackend
    private let runAsync: AsyncRunner
    private let logger: Logger
    private let lock = NSLock()
    private var isPlaying = false
    private var pendingRequest: PlaybackRequest?
    private var requestCounter: UInt64 = 0

    init(
        backend: AudioBackend = AVFoundationReadyChimeAudioBackend(),
        runAsync: @escaping AsyncRunner = { work in
            DispatchQueue.global(qos: .userInteractive).async(execute: work)
        },
        logger: @escaping Logger = { line in
            DebugLog.write(line)
        },
    ) {
        self.backend = backend
        self.runAsync = runAsync
        self.logger = logger
    }

    func play(trigger: String = "unspecified", projectPath: String? = nil) {
        let decision = enqueue(trigger: trigger, projectPath: projectPath)
        switch decision {
        case let .start(request):
            log(action: "start", request: request)
            playAsync(request)
        case let .coalesce(request):
            log(action: "coalesced", request: request)
        }
    }

    private func enqueue(trigger: String, projectPath: String?) -> EnqueueDecision {
        lock.lock()
        defer { lock.unlock() }

        requestCounter &+= 1
        let request = PlaybackRequest(
            id: requestCounter,
            trigger: trigger,
            projectPath: projectPath,
        )

        if isPlaying {
            pendingRequest = request
            return .coalesce(request)
        }

        isPlaying = true
        return .start(request)
    }

    private func playAsync(_ request: PlaybackRequest) {
        runAsync { [weak self] in
            guard let self else { return }
            defer { self.completePlayback() }

            guard backend.ensureEngineRunning() else {
                log(action: "engine_start_failed", request: request)
                return
            }

            guard backend.playDualTone() else {
                log(action: "play_failed", request: request)
                return
            }
            log(action: "played", request: request)
        }
    }

    private func completePlayback() {
        let nextRequest: PlaybackRequest?
        lock.lock()
        if let pendingRequest {
            self.pendingRequest = nil
            nextRequest = pendingRequest
        } else {
            isPlaying = false
            nextRequest = nil
        }
        lock.unlock()

        guard let nextRequest else {
            return
        }

        log(action: "drain_pending", request: nextRequest)
        playAsync(nextRequest)
    }

    private func log(action: String, request: PlaybackRequest) {
        var message = "ReadyChime.play action=\(action) request_id=\(request.id) trigger=\(request.trigger)"
        if let projectPath = request.projectPath {
            message += " project_path=\(projectPath)"
        }
        logger(message)
    }
}

private final class AVFoundationReadyChimeAudioBackend: ReadyChime.AudioBackend {
    private var audioEngine: AVAudioEngine?
    private var mixer: AVAudioMixerNode?

    init() {
        setupAudioEngine()
    }

    func ensureEngineRunning() -> Bool {
        guard let engine = audioEngine else { return false }

        if engine.isRunning {
            return true
        }

        do {
            try engine.start()
            return engine.isRunning
        } catch {
            DebugLog.write("ReadyChime: Failed to start audio engine: \(error)")
            return false
        }
    }

    func playDualTone() -> Bool {
        guard let engine = audioEngine, let mixer else {
            return false
        }

        let sampleRate: Double = 44100
        let duration1 = 0.15
        let duration2 = 0.20
        let gap = 0.08

        let totalDuration = duration1 + gap + duration2
        let frameCount = AVAudioFrameCount(totalDuration * sampleRate)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            return false
        }

        buffer.frameLength = frameCount

        guard let floatData = buffer.floatChannelData?[0] else {
            return false
        }

        for i in 0 ..< Int(frameCount) {
            let t = Double(i) / sampleRate
            var sample: Float = 0

            if t < duration1 {
                sample = Float(woodenKnock(t: t, duration: duration1, pitch: 0.9) * 0.35)
            } else if t >= duration1 + gap, t < totalDuration {
                let t2 = t - duration1 - gap
                sample = Float(woodenKnock(t: t2, duration: duration2, pitch: 1.15) * 0.38)
            }

            floatData[i] = sample
        }

        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: mixer, format: format)
        defer {
            playerNode.stop()
            engine.detach(playerNode)
        }

        guard ensureEngineRunning() else {
            return false
        }

        var exceptionName: NSString?
        var exceptionReason: NSString?
        let didStartPlayback = ReadyChimePerformWithExceptionCatcher({
            playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
            playerNode.play()
        }, &exceptionName, &exceptionReason)

        guard didStartPlayback else {
            let name = exceptionName.map(String.init) ?? "unknown"
            let reason = exceptionReason.map(String.init) ?? "unknown"
            DebugLog.write("ReadyChime: AVAudioPlayerNode start raised NSException name=\(name) reason=\(reason)")
            return false
        }

        Thread.sleep(forTimeInterval: totalDuration + 0.05)
        return true
    }

    private func woodenKnock(t: Double, duration _: Double, pitch: Double) -> Double {
        let fundamental: Double = 680 * pitch
        let harmonic2: Double = fundamental * 2.3
        let harmonic3: Double = fundamental * 4.1

        let attackTime = 0.003
        let attack = min(1.0, t / attackTime)
        let attackCurve = attack * attack

        let decayRate = 12.0
        let decay = exp(-decayRate * t)

        let tone1 = sin(2.0 * .pi * fundamental * t)
        let tone2 = sin(2.0 * .pi * harmonic2 * t) * 0.3
        let tone3 = sin(2.0 * .pi * harmonic3 * t) * 0.1

        let noiseAmount = 0.15 * exp(-40.0 * t)
        let noise = (Double.random(in: -1 ... 1)) * noiseAmount

        let vibrato = 1.0 + 0.008 * sin(2.0 * .pi * 25 * t) * exp(-8.0 * t)

        let body = (tone1 + tone2 + tone3) * vibrato

        let envelope = attackCurve * decay

        return (body + noise) * envelope
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        mixer = AVAudioMixerNode()

        guard let engine = audioEngine, let mixer else { return }

        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        _ = ensureEngineRunning()
    }
}
