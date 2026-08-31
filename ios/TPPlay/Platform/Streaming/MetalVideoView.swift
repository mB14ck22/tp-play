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
    let device: MTLDevice
    weak var view: MTKView?

    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let lock = NSLock()
    private var pixelBuffer: CVPixelBuffer?

    override init() {
        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        commandQueue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init()
    }

    func display(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        self.pixelBuffer = pixelBuffer
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.view?.setNeedsDisplay()
        }
    }

    func draw(in view: MTKView) {
        lock.lock()
        let pixelBuffer = self.pixelBuffer
        lock.unlock()
        guard let pixelBuffer, let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else { return }

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
