// Turns the home scene's vector drawings into the pictures the Android app carries.
// Run through `sync_home_assets.py`, which says where the drawings are and how wide each one is.
//
//     swift home_art.swift <svg> <png> <width in pixels>
//
// macOS reads the drawings with the reader the iOS app's asset catalogue uses, so both apps show the same shapes.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 4, let width = Int(arguments[3]), let image = NSImage(contentsOfFile: arguments[1]), image.size.width > 0 else {
    FileHandle.standardError.write("usage: home_art.swift <svg> <png> <width>\n".data(using: .utf8)!)
    exit(1)
}
let height = Int((Double(width) * image.size.height / image.size.width).rounded(.up))
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: arguments[2]))
