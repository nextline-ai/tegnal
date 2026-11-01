import SwiftUI

/// Illustrated covers drawn entirely in code, so a cover can sit on a shelf or be
/// shared without ever showing a saved work. Each issue takes its hue from the
/// period's measured colors, and neighboring issues always get different scenes.
struct RecapCoverArt: View {
    static let styles = 8
    let palette: RecapPalette
    let seed: Int
    var body: some View {
        Canvas(opaque: true) { context, size in
            var scene = RecapCoverScene(seed: seed, hue: palette.leadHue, size: size)
            scene.draw(&context)
        }.accessibilityHidden(true)
    }
}

extension TasteRecap {
    /// Months count up, so consecutive issues step through every scene in turn.
    var coverSeed: Int {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let date = calendar.dateComponents([.year, .month], from: interval.start.addingTimeInterval(43200))
        return (date.year ?? 0) * 12 + (date.month ?? 0)
    }
}

private struct RecapCoverScene {
    let seed: Int
    let hue: Double
    let size: CGSize
    private var state: UInt64
    private let shift: Double
    private var width: CGFloat { size.width }
    private var height: CGFloat { size.height }

    init(seed: Int, hue: Double, size: CGSize) {
        self.seed = seed; self.hue = hue; self.size = size
        state = UInt64(truncatingIfNeeded: seed) &* 2654435761 &+ 12345
        state = state &* 6364136223846793005 &+ 1442695040888963407
        shift = 0.06 + Double((state >> 33) % 1000) / 1000 * 0.14
    }
    private mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 1000) / 1000
    }
    private func tone(_ offset: Double, _ saturation: Double, _ brightness: Double) -> Color {
        RecapColor(hue: hue + offset, saturation: saturation, brightness: brightness).color
    }
    private func sky(_ context: inout GraphicsContext, _ colors: [Color]) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
    }
    private func disc(_ context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, color: Color) {
        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
    }
    /// A filled horizon. Two summed sines keep the outline from looking mechanical.
    private func ridge(_ context: inout GraphicsContext, floor: CGFloat, swell: CGFloat, waves: CGFloat, phase: CGFloat, color: Color) {
        var path = Path(); path.move(to: CGPoint(x: 0, y: height))
        for step in 0...180 {
            let x = width * CGFloat(step) / 180, position = x / width * .pi * 2
            path.addLine(to: CGPoint(x: x, y: floor + sin(position * waves + phase) * swell + sin(position * waves * 2.3 + phase * 1.7) * swell * 0.28))
        }
        path.addLine(to: CGPoint(x: width, y: height)); path.closeSubpath()
        context.fill(path, with: .color(color))
    }
    private mutating func stars(_ context: inout GraphicsContext, count: Int, limit: CGFloat, color: Color) {
        for _ in 0..<count {
            let radius = width * (0.0025 + next() * 0.004)
            disc(&context, at: CGPoint(x: width * next(), y: height * limit * next()), radius: radius, color: color.opacity(0.4 + next() * 0.6))
        }
    }

    mutating func draw(_ context: inout GraphicsContext) {
        switch ((seed % RecapCoverArt.styles) + RecapCoverArt.styles) % RecapCoverArt.styles {
        case 0: ridges(&context)
        case 1: sea(&context)
        case 2: arches(&context)
        case 3: orbit(&context)
        case 4: clouds(&context)
        case 5: forest(&context)
        case 6: city(&context)
        default: aurora(&context)
        }
    }

    private mutating func ridges(_ context: inout GraphicsContext) {
        sky(&context, [tone(0, 0.62, 0.34), tone(shift, 0.72, 0.82), tone(shift * 2, 0.5, 1)])
        disc(&context, at: CGPoint(x: width * (0.3 + next() * 0.4), y: height * (0.3 + next() * 0.14)), radius: width * 0.2, color: tone(shift * 2.6, 0.28, 1))
        for layer in 0..<4 {
            ridge(&context, floor: height * (0.54 + CGFloat(layer) * 0.12), swell: height * (0.05 + next() * 0.06), waves: 1.2 + next() * 1.8, phase: next() * 6,
                  color: tone(-shift * Double(layer) * 0.8, 0.55 + Double(layer) * 0.08, 0.62 - Double(layer) * 0.14))
        }
    }
    private mutating func sea(_ context: inout GraphicsContext) {
        sky(&context, [tone(0, 0.68, 0.26), tone(shift, 0.6, 0.62), tone(shift * 2, 0.38, 0.96)])
        let horizon = height * 0.56
        disc(&context, at: CGPoint(x: width * (0.35 + next() * 0.3), y: horizon - height * 0.08), radius: width * 0.21, color: tone(shift * 2.5, 0.2, 1))
        for band in 0..<7 {
            let progress = Double(band) / 6
            ridge(&context, floor: horizon + height * 0.44 * CGFloat(progress * progress) + height * 0.02, swell: height * (0.006 + 0.012 * CGFloat(progress)), waves: 5 + next() * 3, phase: next() * 6,
                  color: tone(-shift * progress * 0.7, 0.62 + 0.14 * progress, 0.64 - 0.46 * progress))
        }
    }
    private mutating func arches(_ context: inout GraphicsContext) {
        sky(&context, [tone(shift * 2, 0.32, 0.97), tone(shift * 1.4, 0.42, 0.92)])
        let center = width * 0.5, base = height * 1.02
        let bands = [tone(-shift * 1.5, 0.66, 0.34), tone(-shift * 0.6, 0.72, 0.6), tone(shift * 0.4, 0.68, 0.84), tone(shift * 1.6, 0.46, 0.96), tone(-shift, 0.7, 0.46), tone(0, 0.7, 0.26)]
        for (index, color) in bands.enumerated() {
            let radius = width * (0.62 - 0.1 * CGFloat(index))
            var path = Path()
            path.move(to: CGPoint(x: center - radius, y: base))
            path.addLine(to: CGPoint(x: center - radius, y: height * 0.74))
            path.addArc(center: CGPoint(x: center, y: height * 0.74), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: center + radius, y: base)); path.closeSubpath()
            context.fill(path, with: .color(color))
        }
    }
    private mutating func orbit(_ context: inout GraphicsContext) {
        sky(&context, [tone(-shift, 0.7, 0.14), tone(0, 0.72, 0.3), tone(shift, 0.68, 0.46)])
        stars(&context, count: 70, limit: 1, color: tone(shift * 2, 0.12, 1))
        let center = CGPoint(x: width * (0.44 + next() * 0.14), y: height * 0.58), radius = width * 0.3
        var ring = Path(ellipseIn: CGRect(x: -radius * 1.75, y: -radius * 0.42, width: radius * 3.5, height: radius * 0.84))
        ring = ring.applying(CGAffineTransform(rotationAngle: -0.36)).applying(CGAffineTransform(translationX: center.x, y: center.y))
        context.stroke(ring, with: .color(tone(shift * 2.4, 0.3, 0.98).opacity(0.75)), lineWidth: width * 0.02)
        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                     with: .linearGradient(Gradient(colors: [tone(shift * 2, 0.42, 1), tone(0, 0.74, 0.74), tone(-shift, 0.8, 0.36)]), startPoint: CGPoint(x: center.x - radius, y: center.y - radius), endPoint: CGPoint(x: center.x + radius, y: center.y + radius)))
        var front = Path(); front.addArc(center: .zero, radius: 1, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        front = front.applying(CGAffineTransform(scaleX: radius * 1.75, y: radius * 0.42)).applying(CGAffineTransform(rotationAngle: -0.36)).applying(CGAffineTransform(translationX: center.x, y: center.y))
        context.stroke(front, with: .color(tone(shift * 2.4, 0.3, 0.98)), style: StrokeStyle(lineWidth: width * 0.02, lineCap: .round))
        disc(&context, at: CGPoint(x: width * 0.8, y: height * 0.34), radius: width * 0.04, color: tone(shift * 2.6, 0.18, 1))
    }
    private mutating func clouds(_ context: inout GraphicsContext) {
        sky(&context, [tone(0, 0.56, 0.5), tone(shift, 0.5, 0.78), tone(shift * 1.8, 0.3, 0.98)])
        disc(&context, at: CGPoint(x: width * (0.28 + next() * 0.44), y: height * 0.46), radius: width * 0.17, color: tone(shift * 2.6, 0.24, 1))
        for layer in 0..<4 {
            let floor = height * (0.56 + CGFloat(layer) * 0.12), color = tone(shift * (1.6 - Double(layer) * 0.7), 0.2 + Double(layer) * 0.12, 0.98 - Double(layer) * 0.12)
            var path = Path(CGRect(x: 0, y: floor, width: width, height: height - floor))
            var x = -width * 0.08 - next() * width * 0.1
            while x < width * 1.1 {
                let radius = width * (0.09 + next() * 0.09)
                path.addEllipse(in: CGRect(x: x - radius, y: floor - radius * (0.7 + next() * 0.5), width: radius * 2, height: radius * 2))
                x += radius * 1.25
            }
            context.fill(path, with: .color(color))
        }
    }
    private mutating func forest(_ context: inout GraphicsContext) {
        sky(&context, [tone(0, 0.56, 0.3), tone(shift, 0.5, 0.66), tone(shift * 1.9, 0.3, 0.98)])
        disc(&context, at: CGPoint(x: width * (0.3 + next() * 0.4), y: height * 0.44), radius: width * 0.16, color: tone(shift * 2.6, 0.2, 1))
        for layer in 0..<3 {
            let floor = height * (0.62 + CGFloat(layer) * 0.13), tree = height * (0.15 + CGFloat(layer) * 0.05)
            let color = tone(-shift * Double(layer) * 0.7, 0.58, 0.48 - Double(layer) * 0.15)
            var x = -width * 0.05
            while x < width * 1.05 {
                let tall = tree * (0.72 + next() * 0.5), wide = tall * 0.36
                for tier in 0..<3 {
                    let top = floor - tall + tall * CGFloat(tier) * 0.26, bottom = top + tall * 0.5, half = wide * (0.6 + CGFloat(tier) * 0.26)
                    var path = Path(); path.move(to: CGPoint(x: x, y: top)); path.addLine(to: CGPoint(x: x + half, y: bottom)); path.addLine(to: CGPoint(x: x - half, y: bottom)); path.closeSubpath()
                    context.fill(path, with: .color(color))
                }
                x += wide * (0.9 + next() * 0.8)
            }
            context.fill(Path(CGRect(x: 0, y: floor - tree * 0.12, width: width, height: height - floor + tree * 0.12)), with: .color(color))
        }
    }
    private mutating func city(_ context: inout GraphicsContext) {
        sky(&context, [tone(-shift, 0.72, 0.2), tone(0, 0.74, 0.5), tone(shift * 1.6, 0.62, 0.98)])
        disc(&context, at: CGPoint(x: width * (0.3 + next() * 0.4), y: height * 0.46), radius: width * 0.18, color: tone(shift * 2.4, 0.32, 1))
        for layer in 0..<3 {
            let color = tone(-shift * (Double(layer) + 0.5), 0.62, 0.44 - Double(layer) * 0.14)
            let ground = height * (0.68 + CGFloat(layer) * 0.09)
            var x = -width * 0.02
            while x < width {
                let wide = width * (0.09 + next() * 0.09), tall = height * (0.12 + next() * 0.16)
                context.fill(Path(CGRect(x: x, y: ground - tall, width: wide, height: height)), with: .color(color))
                if layer == 2 {
                    let cell = width * 0.018
                    for row in 0..<Int(tall / (cell * 2.4)) {
                        for column in 0..<max(1, Int(wide / (cell * 2.2))) where next() > 0.55 {
                            context.fill(Path(CGRect(x: x + cell * 0.8 + CGFloat(column) * cell * 2.2, y: ground - tall + cell + CGFloat(row) * cell * 2.4, width: cell, height: cell * 1.3)), with: .color(tone(shift * 2.4, 0.42, 1).opacity(0.9)))
                        }
                    }
                }
                x += wide + width * 0.004
            }
        }
    }
    private mutating func aurora(_ context: inout GraphicsContext) {
        sky(&context, [tone(-shift, 0.7, 0.12), tone(0, 0.7, 0.24), tone(shift * 0.6, 0.62, 0.38)])
        stars(&context, count: 60, limit: 0.7, color: tone(shift * 2, 0.1, 1))
        for ribbon in 0..<5 {
            let base = height * (0.34 + CGFloat(ribbon) * 0.06), swell = height * 0.07, waves = 0.9 + next() * 0.8, phase = next() * 6, length = height * (0.22 + next() * 0.1)
            var path = Path(); path.move(to: CGPoint(x: 0, y: base + sin(phase) * swell))
            for step in 1...120 {
                let x = width * CGFloat(step) / 120
                path.addLine(to: CGPoint(x: x, y: base + sin(x / width * .pi * 2 * waves + phase) * swell))
            }
            path.addLine(to: CGPoint(x: width, y: height)); path.addLine(to: CGPoint(x: 0, y: height)); path.closeSubpath()
            context.fill(path, with: .linearGradient(Gradient(colors: [tone(shift * Double(ribbon) * 0.8 + 0.25, 0.62, 1).opacity(0.42), .clear]),
                                                     startPoint: CGPoint(x: 0, y: base - swell), endPoint: CGPoint(x: 0, y: base + length)))
        }
        ridge(&context, floor: height * 0.76, swell: height * 0.04, waves: 1.3 + next(), phase: next() * 6, color: tone(-shift, 0.6, 0.26))
        ridge(&context, floor: height * 0.86, swell: height * 0.024, waves: 1.8 + next(), phase: next() * 6, color: tone(-shift * 1.5, 0.66, 0.14))
    }
}
