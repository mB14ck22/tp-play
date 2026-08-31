import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: size * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("Could not create icon context") }

let navy = CGColor(red: 0.035, green: 0.043, blue: 0.059, alpha: 1)
let blue = CGColor(red: 0.32, green: 0.66, blue: 1, alpha: 1)
let mint = CGColor(red: 0.44, green: 0.94, blue: 0.82, alpha: 1)

context.setFillColor(navy)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

let portal = CGPath(roundedRect: CGRect(x: 174, y: 194, width: 676, height: 636), cornerWidth: 154, cornerHeight: 154, transform: nil)
context.addPath(portal)
context.setStrokeColor(blue)
context.setLineWidth(62)
context.setLineCap(.round)
context.strokePath()

context.setStrokeColor(navy)
context.setLineWidth(82)
context.move(to: CGPoint(x: 512, y: 822))
context.addLine(to: CGPoint(x: 512, y: 740))
context.strokePath()

context.move(to: CGPoint(x: 430, y: 370))
context.addLine(to: CGPoint(x: 430, y: 652))
context.addLine(to: CGPoint(x: 662, y: 511))
context.closePath()
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fillPath()

context.setFillColor(mint)
context.fillEllipse(in: CGRect(x: 730, y: 700, width: 86, height: 86))

guard let image = context.makeImage() else { fatalError("Could not create icon image") }
let output = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
guard let destination = CGImageDestinationCreateWithURL(output, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create PNG destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not encode PNG") }
