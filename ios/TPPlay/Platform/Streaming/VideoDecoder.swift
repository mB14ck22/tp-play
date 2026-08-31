import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class VideoDecoder: @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?

    private let codec: CMVideoCodecType
    private let lock = NSLock()
    private var parameterSets: [Int: Data] = [:]
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    init(hevc: Bool) {
        codec = hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func decode(_ annexB: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let units = Self.nalUnits(in: annexB)
        guard !units.isEmpty else { return false }
        for unit in units where !unit.isEmpty {
            let type = codec == kCMVideoCodecType_HEVC ? Int((unit[0] >> 1) & 0x3f) : Int(unit[0] & 0x1f)
            if (codec == kCMVideoCodecType_HEVC && (32...34).contains(type)) ||
                (codec == kCMVideoCodecType_H264 && (7...8).contains(type)) {
                parameterSets[type] = unit
            }
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
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        return status == noErr
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
                guard status == noErr, let refcon, let imageBuffer else { return }
                let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
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
