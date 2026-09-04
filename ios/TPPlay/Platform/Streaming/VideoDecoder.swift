import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class VideoDecoder: @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    var onRecoveryNeeded: (@Sendable (String) -> Void)?

    struct HealthSnapshot: Sendable {
        let inputFrames: UInt64
        let outputFrames: UInt64
        let queuedFrames: Int
        let lastInputNanoseconds: UInt64
        let lastOutputNanoseconds: UInt64
    }

    private let codec: CMVideoCodecType
    private let decodeQueue = DispatchQueue(label: "com.mb14ck22.tpplay.video-decode", qos: .userInteractive)
    private let diagnosticLock = NSLock()
    private var didLogDecodedFrame = false
    private var diagnosticInputFrames: UInt64 = 0
    private var diagnosticOutputFrames: UInt64 = 0
    private var queuedFrames = 0
    private var lastInputNanoseconds: UInt64 = 0
    private var lastOutputNanoseconds: UInt64 = 0
    private var recoveryRequested = false
    private var parameterSets: [Int: Data] = [:]
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var waitingForKeyframe = false

    // The network reorder queue can legitimately release several complete
    // frames at once after a jitter burst. Keep enough compressed-frame headroom
    // for that burst without allowing an unbounded decode backlog.
    private static let maximumQueuedFrames = 32

    init(hevc: Bool) {
        codec = hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func decode(_ annexB: Data) -> Bool {
        var rejectFrame = false
        diagnosticLock.lock()
        diagnosticInputFrames &+= 1
        lastInputNanoseconds = DispatchTime.now().uptimeNanoseconds
        if queuedFrames >= Self.maximumQueuedFrames {
            rejectFrame = true
        } else {
            queuedFrames += 1
        }
        let inputNumber = diagnosticInputFrames
        diagnosticLock.unlock()

        if rejectFrame {
            // Returning false lets Chiaki request one IDR. Mark the decoder as
            // recovering here, but do not also invoke the Swift recovery
            // callback or the same overflow produces two reliable IDR requests.
            markRecoveryNeeded()
            print("[TPPLAY-DIAG] compressed video queue overflow")
            return false
        }
        if inputNumber == 1 || inputNumber % 60 == 0 {
            print("[TPPLAY-DIAG] decoder input #\(inputNumber): \(annexB.count) bytes")
        }

        decodeQueue.async { [self] in
            let accepted = decodeNow(annexB)
            diagnosticLock.lock()
            queuedFrames = max(0, queuedFrames - 1)
            diagnosticLock.unlock()
            if !accepted {
                signalRecoveryNeeded("VideoToolbox rejected frame")
            }
        }
        return true
    }

    func prepareForRecovery() {
        diagnosticLock.lock()
        recoveryRequested = true
        diagnosticLock.unlock()
    }

    func healthSnapshot() -> HealthSnapshot {
        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        return HealthSnapshot(
            inputFrames: diagnosticInputFrames,
            outputFrames: diagnosticOutputFrames,
            queuedFrames: queuedFrames,
            lastInputNanoseconds: lastInputNanoseconds,
            lastOutputNanoseconds: lastOutputNanoseconds
        )
    }

    private func decodeNow(_ annexB: Data) -> Bool {
        diagnosticLock.lock()
        let mustReset = recoveryRequested
        diagnosticLock.unlock()
        if mustReset {
            if let session {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
            waitingForKeyframe = true
        }

        let units = Self.nalUnits(in: annexB)
        guard !units.isEmpty else { return false }
        let containsKeyframe = units.contains { unit in
            guard let first = unit.first else { return false }
            let type = codec == kCMVideoCodecType_HEVC ? Int((first >> 1) & 0x3f) : Int(first & 0x1f)
            return codec == kCMVideoCodecType_HEVC ? (16...23).contains(type) : type == 5
        }
        let containsVideoSlice = units.contains { unit in
            guard let first = unit.first else { return false }
            let type = codec == kCMVideoCodecType_HEVC ? Int((first >> 1) & 0x3f) : Int(first & 0x1f)
            return codec == kCMVideoCodecType_HEVC ? (0...31).contains(type) : (1...5).contains(type)
        }
        var parameterSetsChanged = false
        for unit in units where !unit.isEmpty {
            let type = codec == kCMVideoCodecType_HEVC ? Int((unit[0] >> 1) & 0x3f) : Int(unit[0] & 0x1f)
            if (codec == kCMVideoCodecType_HEVC && (32...34).contains(type)) ||
                (codec == kCMVideoCodecType_H264 && (7...8).contains(type)) {
                if let previous = parameterSets[type], previous != unit {
                    parameterSetsChanged = true
                }
                parameterSets[type] = unit
            }
        }

        if parameterSetsChanged {
            if let session {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
            formatDescription = nil
            waitingForKeyframe = true
            print("[TPPLAY-DIAG] video parameter sets changed; rebuilding decoder")
        }

        // Chiaki emits the codec parameter sets once before the first frame.
        // They configure the decoder but are not themselves a decodable sample.
        // Submitting this header to VideoToolbox produces -12909 and used to
        // trigger an unnecessary recovery cycle at every stream start.
        guard containsVideoSlice else { return true }

        if waitingForKeyframe && !containsKeyframe {
            return true
        }

        if formatDescription == nil, !createFormatDescription() {
            return true
        }
        guard let formatDescription else { return true }
        if session == nil, !createSession(formatDescription: formatDescription) {
            return false
        }

        var avcc = Data()
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = avcc.withUnsafeBytes { bytes in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avcc.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ).flatMapSuccess {
                guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
                return CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: blockBuffer!, offsetIntoDestination: 0, dataLength: avcc.count)
            }
        }
        guard blockStatus == noErr, let blockBuffer else { return false }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer, let session else { return false }

        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            // This callback runs on Chiaki's video-receiver thread. Synchronous
            // VideoToolbox work blocks packet intake and can eventually starve
            // the receiver completely. Real-time asynchronous decode keeps that
            // network path moving; MetalVideoRenderer independently retains only
            // the newest decoded frame, so stale frames never queue for display.
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if status != noErr {
            // A VideoToolbox session can become unusable after an interruption
            // or a broken reference chain. Recreate it for the next keyframe
            // instead of returning failures forever and leaving the view black.
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            waitingForKeyframe = true
            print("[TPPLAY-DIAG] VideoToolbox submit error: \(status); decoder session reset")
        } else if containsKeyframe {
            waitingForKeyframe = false
            diagnosticLock.lock()
            recoveryRequested = false
            diagnosticLock.unlock()
        }
        return status == noErr
    }

    private func signalRecoveryNeeded(_ reason: String) {
        let shouldNotify = markRecoveryNeeded()
        guard shouldNotify else { return }
        print("[TPPLAY-DIAG] video recovery requested: \(reason)")
        onRecoveryNeeded?(reason)
    }

    @discardableResult
    private func markRecoveryNeeded() -> Bool {
        diagnosticLock.lock()
        let wasAlreadyRequested = recoveryRequested
        recoveryRequested = true
        diagnosticLock.unlock()
        return !wasAlreadyRequested
    }

    private func createFormatDescription() -> Bool {
        var description: CMFormatDescription?
        let status: OSStatus
        if codec == kCMVideoCodecType_HEVC {
            guard let vps = parameterSets[32], let sps = parameterSets[33], let pps = parameterSets[34] else { return false }
            status = withParameterSetPointers([vps, sps, pps]) { pointers, sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 3,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        } else {
            guard let sps = parameterSets[7], let pps = parameterSets[8] else { return false }
            status = withParameterSetPointers([sps, pps]) { pointers, sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { return false }
        formatDescription = description
        return true
    }

    private func createSession(formatDescription: CMVideoFormatDescription) -> Bool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, _, _ in
                guard let refcon else { return }
                let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
                guard status == noErr, let imageBuffer else {
                    if status != noErr {
                        print("[TPPLAY-DIAG] VideoToolbox output error: \(status)")
                        decoder.signalRecoveryNeeded("VideoToolbox asynchronous output failure \(status)")
                    }
                    return
                }
                decoder.diagnosticLock.lock()
                decoder.diagnosticOutputFrames &+= 1
                decoder.lastOutputNanoseconds = DispatchTime.now().uptimeNanoseconds
                if !decoder.didLogDecodedFrame {
                    decoder.didLogDecodedFrame = true
                    print("[TPPLAY-DIAG] first decoded video frame")
                } else if decoder.diagnosticOutputFrames % 300 == 0 {
                    print("[TPPLAY-DIAG] decoded video frame #\(decoder.diagnosticOutputFrames)")
                }
                decoder.diagnosticLock.unlock()
                decoder.onFrame?(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        if status == noErr, let session {
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        } else {
            print("[TPPLAY-DIAG] VideoToolbox session creation error: \(status)")
        }
        return status == noErr
    }

    private func withParameterSetPointers<T>(_ sets: [Data], body: ([UnsafePointer<UInt8>], [Int]) -> T) -> T {
        func recurse(_ index: Int, _ pointers: [UnsafePointer<UInt8>], _ sizes: [Int]) -> T {
            if index == sets.count { return body(pointers, sizes) }
            return sets[index].withUnsafeBytes { bytes in
                recurse(index + 1, pointers + [bytes.bindMemory(to: UInt8.self).baseAddress!], sizes + [sets[index].count])
            }
        }
        return recurse(0, [], [])
    }

    private static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 {
                starts.append((index, 3)); index += 3
            } else if index + 4 < bytes.count && bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 0 && bytes[index + 3] == 1 {
                starts.append((index, 4)); index += 4
            } else {
                index += 1
            }
        }
        return starts.enumerated().compactMap { position, start in
            let begin = start.offset + start.length
            let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            return begin < end ? Data(bytes[begin..<end]) : nil
        }
    }
}

private extension OSStatus {
    func flatMapSuccess(_ operation: () -> OSStatus) -> OSStatus {
        self == noErr ? operation() : self
    }
}
