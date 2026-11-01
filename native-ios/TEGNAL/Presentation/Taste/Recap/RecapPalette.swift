import SwiftUI

struct RecapColor: Codable, Hashable, Sendable {
    var red: Double, green: Double, blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
    var hex: String { String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255)) }
    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let high = max(red, green, blue), low = min(red, green, blue), delta = high - low
        guard delta > 0 else { return (0, 0, high) }
        var hue: Double
        if high == red { hue = (green - blue) / delta } else if high == green { hue = (blue - red) / delta + 2 } else { hue = (red - green) / delta + 4 }
        hue /= 6; if hue < 0 { hue += 1 }
        return (hue, delta / high, high)
    }
    func with(saturation: Double? = nil, brightness: Double) -> RecapColor {
        let value = hsb
        return .init(hue: value.hue, saturation: saturation ?? value.saturation, brightness: brightness)
    }
    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(hue: Double, saturation: Double, brightness: Double) {
        let sector = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let index = Int(sector), fraction = sector - Double(index)
        let p = brightness * (1 - saturation), q = brightness * (1 - saturation * fraction), t = brightness * (1 - saturation * (1 - fraction))
        switch index {
        case 0: (red, green, blue) = (brightness, t, p)
        case 1: (red, green, blue) = (q, brightness, p)
        case 2: (red, green, blue) = (p, brightness, t)
        case 3: (red, green, blue) = (p, q, brightness)
        case 4: (red, green, blue) = (t, p, brightness)
        default: (red, green, blue) = (brightness, p, q)
        }
    }
}

/// The colors of a period, measured from the covers the person kept. Five
/// swatches ordered by presence, with stage colors derived for legible type.
struct RecapPalette: Codable, Hashable, Sendable {
    var swatches: [RecapColor]
    private var lead: RecapColor { swatches.max { vividness($0) < vividness($1) } ?? swatches[0] }
    private func vividness(_ color: RecapColor) -> Double { let value = color.hsb; return value.saturation * value.brightness }
    /// Always dark enough for white type, whatever the artwork's colors are.
    var ink: Color { lead.with(saturation: min(0.75, lead.hsb.saturation), brightness: 0.13).color }
    var deep: Color { lead.with(saturation: min(0.8, lead.hsb.saturation), brightness: 0.26).color }
    /// Always bright enough to read on `ink`.
    var accent: Color { lead.with(saturation: min(0.72, max(0.38, lead.hsb.saturation)), brightness: max(0.9, lead.hsb.brightness)).color }
    var paper: Color { lead.with(saturation: min(0.1, lead.hsb.saturation), brightness: 0.96).color }
    var paperInk: Color { lead.with(saturation: min(0.65, lead.hsb.saturation), brightness: 0.17).color }

    var mood: String {
        let color = swatches[0], value = color.hsb
        if value.saturation < 0.16 { return value.brightness < 0.45 ? "ink" : value.brightness > 0.78 ? "paper" : "ash" }
        switch value.hue * 360 {
        case ..<15: return "ember"
        case ..<42: return "amber"
        case ..<68: return "honey"
        case ..<160: return "moss"
        case ..<195: return "lagoon"
        case ..<235: return "deepSea"
        case ..<265: return "twilight"
        case ..<300: return "iris"
        case ..<345: return "peony"
        default: return "ember"
        }
    }
    var moodName: String { L10n.text("palette." + mood) }

    /// Colorless pixels dilute every month into grey, so colors count by how
    /// much they read as color. A page of white margin cannot outvote a blue sky.
    static func extract(_ pixels: [RecapColor]) -> RecapPalette? {
        struct Bucket { var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0 }
        var buckets: [Int: Bucket] = [:]
        for pixel in pixels {
            let value = pixel.hsb
            guard value.brightness > 0.08 else { continue }
            let neutral = value.saturation < 0.14
            let key = neutral ? 100 + Int(value.brightness * 3.99) : Int(value.hue * 12) * 3 + Int(value.brightness * 2.99)
            let weight = neutral ? 0.12 : 0.25 + value.saturation * value.brightness
            var bucket = buckets[key] ?? .init()
            bucket.red += pixel.red * weight; bucket.green += pixel.green * weight; bucket.blue += pixel.blue * weight; bucket.weight += weight
            buckets[key] = bucket
        }
        let ranked = buckets.sorted { $0.value.weight == $1.value.weight ? $0.key < $1.key : $0.value.weight > $1.value.weight }
            .map { RecapColor(red: $0.value.red / $0.value.weight, green: $0.value.green / $0.value.weight, blue: $0.value.blue / $0.value.weight) }
        var chosen: [RecapColor] = []
        for color in ranked where !chosen.contains(where: { distance($0, color) < 0.2 }) {
            chosen.append(color)
            if chosen.count == 5 { break }
        }
        guard !chosen.isEmpty else { return nil }
        while chosen.count < 5 { chosen.append(chosen[chosen.count - 1].with(brightness: min(1, chosen[chosen.count - 1].hsb.brightness * 0.72 + 0.1))) }
        return .init(swatches: chosen)
    }
    private static func distance(_ a: RecapColor, _ b: RecapColor) -> Double {
        ((a.red - b.red) * (a.red - b.red) + (a.green - b.green) * (a.green - b.green) + (a.blue - b.blue) * (a.blue - b.blue)).squareRoot()
    }
    /// Stable colors for a period whose covers are not available yet.
    static func seeded(_ text: String) -> RecapPalette {
        let seed = text.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let hue = Double(seed % 360) / 360
        return .init(swatches: [
            .init(hue: hue, saturation: 0.72, brightness: 0.82), .init(hue: hue + 0.08, saturation: 0.55, brightness: 0.95),
            .init(hue: hue - 0.09, saturation: 0.68, brightness: 0.62), .init(hue: hue + 0.46, saturation: 0.5, brightness: 0.9),
            .init(hue: hue + 0.02, saturation: 0.2, brightness: 0.96)
        ])
    }
    static func pixels(of image: UIImage, side: Int = 24) -> [RecapColor] {
        guard let source = image.cgImage else { return [] }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        return stride(from: 0, to: bytes.count, by: 4).map { .init(red: Double(bytes[$0]) / 255, green: Double(bytes[$0 + 1]) / 255, blue: Double(bytes[$0 + 2]) / 255) }
    }
}

/// Abstract color fields. They stand in for artwork whenever a page must not show
/// any: the private mode, share cards and sample issues.
struct RecapColorField: View {
    let palette: RecapPalette
    var seed = 7
    var body: some View {
        Canvas(opaque: true) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.ink))
            var state = UInt64(truncatingIfNeeded: seed) &* 2654435761 &+ 97
            func next() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double((state >> 33) % 1000) / 1000 }
            context.addFilter(.blur(radius: min(size.width, size.height) * 0.13))
            for index in 0..<7 {
                let color = palette.swatches[index % palette.swatches.count]
                let radius = max(size.width, size.height) * (0.24 + next() * 0.3)
                let center = CGPoint(x: size.width * next(), y: size.height * next())
                context.opacity = 0.62 + next() * 0.38
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(color.color))
            }
        }.accessibilityHidden(true)
    }
}
