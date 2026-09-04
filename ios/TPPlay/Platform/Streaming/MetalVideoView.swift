import CoreImage
import CoreVideo
import MetalKit
import SwiftUI

struct MetalVideoView: UIViewRepresentable {
    let renderer: MetalVideoRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.backgroundColor = .black
        renderer.view = view
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

final class MetalVideoRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    struct HealthSnapshot: Sendable {
        let receivedFrames: UInt64
        let drawnFrames: UInt64
    }

    let device: MTLDevice
    weak var view: MTKView?

    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let lock = NSLock()
    private var pixelBuffer: CVPixelBuffer?
    private var drawRequestPending = false
    private var didLogDisplay = false
    private var didLogDraw = false
    private var receivedFrames: UInt64 = 0
    private var drawnFrames: UInt64 = 0
    private let playbackQueue = DispatchQueue(label: "com.mb14ck22.tpplay.video-playback", qos: .userInteractive)
    private var playbackTimer: DispatchSourceTimer?
    private var bufferedFrames: [CVPixelBuffer] = []
    private let playbackBufferFrameCount: Int
    private let maximumBufferedFrameCount: Int
    private let frameIntervalNanoseconds: Int
    private let onStartupBufferReady: (@Sendable () -> Void)?
    private var bufferedPlaybackStarted = false

    init(
        framesPerSecond: Int = 60,
        startupBufferMilliseconds: Int = 0,
        onStartupBufferReady: (@Sendable () -> Void)? = nil
    ) {
        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        let safeFPS = max(1, framesPerSecond)
        playbackBufferFrameCount = startupBufferMilliseconds > 0
            ? max(2, Int(ceil(Double(safeFPS * startupBufferMilliseconds) / 1_000.0)))
            : 0
        maximumBufferedFrameCount = max(playbackBufferFrameCount * 2, safeFPS / 2)
        frameIntervalNanoseconds = 1_000_000_000 / safeFPS
        self.onStartupBufferReady = onStartupBufferReady
        commandQueue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init()
    }

    deinit {
        playbackTimer?.setEventHandler {}
        playbackTimer?.cancel()
    }

    func display(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        receivedFrames &+= 1
        if !didLogDisplay {
            didLogDisplay = true
            print("[TPPLAY-DIAG] renderer received first pixel buffer")
        }
        if playbackBufferFrameCount > 0 {
            bufferedFrames.append(pixelBuffer)
            if bufferedFrames.count > maximumBufferedFrameCount {
                bufferedFrames.removeFirst(bufferedFrames.count - maximumBufferedFrameCount)
            }
            let shouldStart = !bufferedPlaybackStarted && bufferedFrames.count >= playbackBufferFrameCount
            if shouldStart { bufferedPlaybackStarted = true }
            lock.unlock()
            if shouldStart { startBufferedPlayback() }
            return
        }
        self.pixelBuffer = pixelBuffer
        let shouldRequestDraw = !drawRequestPending
        if shouldRequestDraw {
            drawRequestPending = true
        }
        lock.unlock()
        if shouldRequestDraw {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let view = self.view else {
                    // The session can deliver frames before SwiftUI has mounted
                    // its MTKView. Release the one-slot gate so a later frame can
                    // request the first real draw instead of leaving it shut forever.
                    self.lock.lock()
                    self.drawRequestPending = false
                    self.lock.unlock()
                    return
                }
                view.setNeedsDisplay()
            }
        }
    }

    func stopBufferedPlayback() {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            self.playbackTimer?.setEventHandler {}
            self.playbackTimer?.cancel()
            self.playbackTimer = nil
            self.lock.lock()
            self.bufferedFrames.removeAll(keepingCapacity: false)
            self.bufferedPlaybackStarted = false
            self.lock.unlock()
        }
    }

    private func startBufferedPlayback() {
        playbackQueue.async { [weak self] in
            guard let self, self.playbackTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.playbackQueue)
            timer.schedule(
                deadline: .now(),
                repeating: .nanoseconds(self.frameIntervalNanoseconds),
                leeway: .milliseconds(1)
            )
            timer.setEventHandler { [weak self] in self?.displayNextBufferedFrame() }
            self.playbackTimer = timer
            print("[TPPLAY-DIAG] video startup buffer released at \(self.playbackBufferFrameCount) frames")
            self.onStartupBufferReady?()
            timer.resume()
        }
    }

    private func displayNextBufferedFrame() {
        lock.lock()
        guard !bufferedFrames.isEmpty else {
            lock.unlock()
            return
        }
        pixelBuffer = bufferedFrames.removeFirst()
        let shouldRequestDraw = !drawRequestPending
        if shouldRequestDraw { drawRequestPending = true }
        lock.unlock()
        if shouldRequestDraw {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let view = self.view else {
                    self.lock.lock()
                    self.drawRequestPending = false
                    self.lock.unlock()
                    return
                }
                view.setNeedsDisplay()
            }
        }
    }

    func healthSnapshot() -> HealthSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return HealthSnapshot(receivedFrames: receivedFrames, drawnFrames: drawnFrames)
    }

    func requestRedraw() {
        lock.lock()
        let shouldRequestDraw = pixelBuffer != nil && !drawRequestPending
        if shouldRequestDraw { drawRequestPending = true }
        lock.unlock()
        guard shouldRequestDraw else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let view = self.view else {
                self.lock.lock()
                self.drawRequestPending = false
                self.lock.unlock()
                return
            }
            view.setNeedsDisplay()
        }
    }

    func draw(in view: MTKView) {
        lock.lock()
        let pixelBuffer = self.pixelBuffer
        // Only one main-thread draw request may be pending. Frames arriving while
        // this draw runs replace pixelBuffer and schedule at most one more draw.
        drawRequestPending = false
        lock.unlock()
        guard let pixelBuffer, let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        lock.lock()
        drawnFrames &+= 1
        if !didLogDraw {
            didLogDraw = true
            print("[TPPLAY-DIAG] Metal drew first video frame")
        }
        lock.unlock()

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let source = image.extent
        let destination = CGRect(origin: .zero, size: view.drawableSize)
        let scale = min(destination.width / source.width, destination.height / source.height)
        let transform = CGAffineTransform(
            translationX: (destination.width - source.width * scale) / 2,
            y: (destination.height - source.height * scale) / 2
        ).scaledBy(x: scale, y: scale)
        let transformed = image.transformed(by: transform)
        context.render(
            transformed,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: destination,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
