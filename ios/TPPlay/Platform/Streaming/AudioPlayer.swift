import AVFAudio
import AudioToolbox
import Foundation

private let audioQueueOutputCallback: AudioQueueOutputCallback = { context, queue, buffer in
    guard let context else { return }
    Unmanaged<AudioPlayer>.fromOpaque(context).takeUnretainedValue().fill(queue: queue, buffer: buffer)
}

final class AudioPlayer: @unchecked Sendable {
    private static let outputBufferMilliseconds = 10
    private static let outputBufferCount = 3
    private static let recoveryBufferMilliseconds = 60
    // Keep the existing 60 ms underrun recovery cushion, but never replay half
    // a second of obsolete sound after a network burst.
    private static let maximumBacklogMilliseconds = 120

    private let lock = NSLock()
    private var queue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var ring: [UInt8] = []
    private var readOffset = 0
    private var byteCount = 0
    private var running = false
    private var queueStarted = false
    private var rebuffering = true
    private var outputBufferBytes = 0
    private var prebufferBytes = 0
    private var droppedBytes: UInt64 = 0
    private var underflowCount: UInt64 = 0
    private var callbackCount: UInt64 = 0
    private let startupBufferMilliseconds: Int
    private var playbackPermitted: Bool
    private var recoveryPrebufferBytes = 0
    private var startupPrebufferBytes = 0

    init(startupBufferMilliseconds: Int = 0) {
        self.startupBufferMilliseconds = max(0, startupBufferMilliseconds)
        playbackPermitted = startupBufferMilliseconds <= 0
    }

    func configure(channels: UInt32, sampleRate: UInt32) {
        disposeQueue(resetPlaybackGate: false)
        guard channels > 0, sampleRate > 0 else { return }

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false)
        try? audioSession.setCategory(.playback, mode: .moviePlayback)
        try? audioSession.setPreferredSampleRate(Double(sampleRate))
        try? audioSession.setPreferredIOBufferDuration(0.005)
        try? audioSession.setActive(true)

        let frameBytes = Int(channels) * MemoryLayout<Int16>.size
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(frameBytes),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(frameBytes),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var newQueue: AudioQueueRef?
        let createStatus = AudioQueueNewOutput(
            &description,
            audioQueueOutputCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &newQueue
        )
        guard createStatus == noErr, let newQueue else {
            print("[TPPLAY-DIAG] AudioQueue creation error: \(createStatus)")
            return
        }

        let outputBytes = max(
            frameBytes,
            Int(sampleRate) * frameBytes * Self.outputBufferMilliseconds / 1_000
        )
        let backlogBytes = max(
            outputBytes,
            Int(sampleRate) * frameBytes * Self.maximumBacklogMilliseconds / 1_000
        )

        var allocated: [AudioQueueBufferRef] = []
        for _ in 0..<Self.outputBufferCount {
            var buffer: AudioQueueBufferRef?
            let status = AudioQueueAllocateBuffer(newQueue, UInt32(outputBytes), &buffer)
            guard status == noErr, let buffer else {
                AudioQueueDispose(newQueue, true)
                print("[TPPLAY-DIAG] AudioQueue buffer allocation error: \(status)")
                return
            }
            allocated.append(buffer)
        }

        lock.lock()
        queue = newQueue
        buffers = allocated
        ring = [UInt8](repeating: 0, count: backlogBytes)
        readOffset = 0
        byteCount = 0
        queueStarted = false
        rebuffering = true
        outputBufferBytes = outputBytes
        prebufferBytes = max(
            outputBytes * Self.outputBufferCount,
            Int(sampleRate) * frameBytes * Self.recoveryBufferMilliseconds / 1_000
        )
        recoveryPrebufferBytes = prebufferBytes
        startupPrebufferBytes = max(
            recoveryPrebufferBytes,
            Int(sampleRate) * frameBytes * startupBufferMilliseconds / 1_000
        )
        droppedBytes = 0
        underflowCount = 0
        callbackCount = 0
        running = true
        lock.unlock()
    }

    func enqueue(samples: UnsafePointer<Int16>, count: Int) {
        guard count > 0 else { return }
        let source = UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self)
        var sourceOffset = 0
        var incomingBytes = count * MemoryLayout<Int16>.size

        lock.lock()
        guard running, !ring.isEmpty else {
            lock.unlock()
            return
        }

        if incomingBytes > ring.count {
            let excess = incomingBytes - ring.count
            sourceOffset += excess
            incomingBytes = ring.count
            droppedBytes += UInt64(excess)
        }
        if byteCount + incomingBytes > ring.count {
            let drop = byteCount + incomingBytes - ring.count
            readOffset = (readOffset + drop) % ring.count
            byteCount -= drop
            droppedBytes += UInt64(drop)
        }

        let writeOffset = (readOffset + byteCount) % ring.count
        let firstCount = min(incomingBytes, ring.count - writeOffset)
        ring.withUnsafeMutableBytes { destination in
            memcpy(destination.baseAddress!.advanced(by: writeOffset), source.advanced(by: sourceOffset), firstCount)
            if firstCount < incomingBytes {
                memcpy(destination.baseAddress!, source.advanced(by: sourceOffset + firstCount), incomingBytes - firstCount)
            }
        }
        byteCount += incomingBytes
        let activeQueue = queue
        let shouldStart = playbackPermitted && !queueStarted && byteCount >= prebufferBytes && activeQueue != nil
        if shouldStart, let activeQueue {
            rebuffering = false
            for buffer in buffers {
                copyFullBufferLocked(buffer)
                AudioQueueEnqueueBuffer(activeQueue, buffer, 0, nil)
            }
            queueStarted = true
            prebufferBytes = recoveryPrebufferBytes
        }
        var startStatus: OSStatus = noErr
        if shouldStart, let activeQueue {
            // Keep stop() from disposing the queue between priming and start.
            // The audio callback may wait briefly on this lock, but it runs on
            // AudioQueue's worker thread rather than synchronously here.
            startStatus = AudioQueueStart(activeQueue, nil)
        }
        lock.unlock()

        if startStatus != noErr {
            print("[TPPLAY-DIAG] AudioQueue start error: \(startStatus)")
            stop()
        }
    }

    func releasePlaybackGate() {
        lock.lock()
        playbackPermitted = true
        if startupPrebufferBytes > 0, byteCount > startupPrebufferBytes {
            let drop = byteCount - startupPrebufferBytes
            readOffset = (readOffset + drop) % ring.count
            byteCount -= drop
            droppedBytes += UInt64(drop)
        }
        let activeQueue = queue
        let shouldStart = !queueStarted && byteCount >= prebufferBytes && activeQueue != nil
        if shouldStart, let activeQueue {
            rebuffering = false
            for buffer in buffers {
                copyFullBufferLocked(buffer)
                AudioQueueEnqueueBuffer(activeQueue, buffer, 0, nil)
            }
            queueStarted = true
            prebufferBytes = recoveryPrebufferBytes
        }
        var startStatus: OSStatus = noErr
        if shouldStart, let activeQueue {
            startStatus = AudioQueueStart(activeQueue, nil)
        }
        lock.unlock()

        if startStatus != noErr {
            print("[TPPLAY-DIAG] AudioQueue gated start error: \(startStatus)")
            stop()
        } else if shouldStart {
            print("[TPPLAY-DIAG] audio startup buffer released")
        }
    }

    fileprivate func fill(queue callbackQueue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        lock.lock()
        guard running, queue == callbackQueue else {
            lock.unlock()
            return
        }

        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        callbackCount &+= 1
        if rebuffering && byteCount >= prebufferBytes {
            rebuffering = false
        }

        if !rebuffering && byteCount >= capacity {
            copyFullBufferLocked(buffer)
        } else {
            if !rebuffering {
                underflowCount &+= 1
                rebuffering = true
            }
            memset(buffer.pointee.mAudioData, 0, capacity)
            buffer.pointee.mAudioDataByteSize = UInt32(capacity)
        }
        AudioQueueEnqueueBuffer(callbackQueue, buffer, 0, nil)
        if callbackCount % 100 == 0 {
            let queuedMilliseconds = outputBufferBytes > 0 ? byteCount * Self.outputBufferMilliseconds / outputBufferBytes : 0
            print("[TPPLAY-DIAG] audio health: queued=\(queuedMilliseconds)ms rebuffering=\(rebuffering) underflows=\(underflowCount) droppedBytes=\(droppedBytes)")
        }
        lock.unlock()
    }

    private func copyFullBufferLocked(_ buffer: AudioQueueBufferRef) {
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        precondition(byteCount >= capacity)
        let firstCount = min(capacity, ring.count - readOffset)
        ring.withUnsafeBytes { source in
            memcpy(buffer.pointee.mAudioData, source.baseAddress!.advanced(by: readOffset), firstCount)
            if firstCount < capacity {
                memcpy(buffer.pointee.mAudioData.advanced(by: firstCount), source.baseAddress!, capacity - firstCount)
            }
        }
        readOffset = (readOffset + capacity) % ring.count
        byteCount -= capacity
        buffer.pointee.mAudioDataByteSize = UInt32(capacity)
    }

    func stop() {
        disposeQueue(resetPlaybackGate: true)
    }

    private func disposeQueue(resetPlaybackGate: Bool) {
        lock.lock()
        running = false
        let oldQueue = queue
        queue = nil
        buffers.removeAll()
        ring.removeAll(keepingCapacity: false)
        readOffset = 0
        byteCount = 0
        queueStarted = false
        rebuffering = true
        outputBufferBytes = 0
        prebufferBytes = 0
        recoveryPrebufferBytes = 0
        startupPrebufferBytes = 0
        if resetPlaybackGate {
            playbackPermitted = startupBufferMilliseconds <= 0
        }
        lock.unlock()

        if let oldQueue {
            AudioQueueStop(oldQueue, true)
            AudioQueueDispose(oldQueue, true)
        }
    }
}
