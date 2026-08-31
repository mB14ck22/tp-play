import AVFAudio
import Foundation

final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var format: AVAudioFormat?

    init() {
        engine.attach(player)
    }

    func configure(channels: UInt32, sampleRate: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else { return }
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        self.format = format
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .gameChat, options: [.allowBluetoothA2DP])
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        player.play()
    }

    func enqueue(samples: UnsafePointer<Int16>, count: Int) {
        lock.lock()
        guard let format, format.channelCount > 0 else { lock.unlock(); return }
        let frames = AVAudioFrameCount(count / Int(format.channelCount))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { lock.unlock(); return }
        buffer.frameLength = frames
        let audioBuffer = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)[0]
        if let destination = audioBuffer.mData {
            memcpy(destination, samples, count * MemoryLayout<Int16>.size)
        }
        lock.unlock()
        player.scheduleBuffer(buffer)
    }

    func stop() {
        lock.lock()
        player.stop()
        engine.stop()
        format = nil
        lock.unlock()
    }
}
