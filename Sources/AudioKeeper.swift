import AVFoundation

final class AudioKeeper {
    static let shared = AudioKeeper()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false

    func start() {
        guard !started else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1) else { return }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000) else { return }
            buffer.frameLength = 8000
            player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            try engine.start()
            player.play()
            started = true
        } catch {
            started = false
        }
    }
}
