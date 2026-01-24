import AVFoundation
import Foundation

final class ReadyChime {
    static let shared = ReadyChime()

    private var audioEngine: AVAudioEngine?
    private var mixer: AVAudioMixerNode?
    private var isPlaying = false

    private init() {
        setupAudioEngine()
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        mixer = AVAudioMixerNode()

        guard let engine = audioEngine, let mixer = mixer else { return }

        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)

        do {
            try engine.start()
        } catch {
            print("ReadyChime: Failed to start audio engine: \(error)")
        }
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.playDualTone()
        }
    }

    private func playDualTone() {
        guard let engine = audioEngine, let mixer = mixer else {
            isPlaying = false
            return
        }

        let sampleRate: Double = 44100
        let duration1: Double = 0.15
        let duration2: Double = 0.20
        let gap: Double = 0.08

        let totalDuration = duration1 + gap + duration2
        let frameCount = AVAudioFrameCount(totalDuration * sampleRate)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            isPlaying = false
            return
        }

        buffer.frameLength = frameCount

        guard let floatData = buffer.floatChannelData?[0] else {
            isPlaying = false
            return
        }

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            var sample: Float = 0

            if t < duration1 {
                sample = Float(woodenKnock(t: t, duration: duration1, pitch: 0.9) * 0.35)
            } else if t >= duration1 + gap && t < totalDuration {
                let t2 = t - duration1 - gap
                sample = Float(woodenKnock(t: t2, duration: duration2, pitch: 1.15) * 0.38)
            }

            floatData[i] = sample
        }

        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: mixer, format: format)

        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        playerNode.play()

        Thread.sleep(forTimeInterval: totalDuration + 0.05)

        playerNode.stop()
        engine.detach(playerNode)
        isPlaying = false
    }

    private func woodenKnock(t: Double, duration: Double, pitch: Double) -> Double {
        let fundamental: Double = 680 * pitch
        let harmonic2: Double = fundamental * 2.3
        let harmonic3: Double = fundamental * 4.1

        let attackTime: Double = 0.003
        let attack = min(1.0, t / attackTime)
        let attackCurve = attack * attack

        let decayRate: Double = 12.0
        let decay = exp(-decayRate * t)

        let tone1 = sin(2.0 * .pi * fundamental * t)
        let tone2 = sin(2.0 * .pi * harmonic2 * t) * 0.3
        let tone3 = sin(2.0 * .pi * harmonic3 * t) * 0.1

        let noiseAmount = 0.15 * exp(-40.0 * t)
        let noise = (Double.random(in: -1...1)) * noiseAmount

        let vibrato = 1.0 + 0.008 * sin(2.0 * .pi * 25 * t) * exp(-8.0 * t)

        let body = (tone1 + tone2 + tone3) * vibrato

        let envelope = attackCurve * decay

        return (body + noise) * envelope
    }
}
