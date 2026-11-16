import Foundation

/// Folder colors for both libraries: a fixed set of vivid colors in the order new folders take
/// them, then generated hues once a library uses every one. The color sheet offers the first ten
/// a library doesn't use yet.
enum FolderPalette {
    static let colors: [Int64] = [
        0xFF1F6BFF, // Blue
        0xFFFF3B30, // Red
        0xFF00C853, // Green
        0xFFFF9500, // Orange
        0xFF8E4BFF, // Violet
        0xFFFF2D87, // Pink
        0xFF00C2E8, // Cyan
        0xFFFFCC00, // Yellow
        0xFF4A3DFF, // Indigo
        0xFF00BFA0, // Teal
        0xFFFF6A3D, // Coral
        0xFF7CD200, // Lime
        0xFFD63CFF, // Magenta
        0xFF2FA8FF, // Sky
        0xFFFFB000, // Amber
        0xFF00A86B, // Emerald
        0xFFB026FF, // Purple
        0xFFFF4F7B, // Rose
        0xFF0047D6, // Cobalt
        0xFF2EE0B0, // Mint
        0xFFE3122C, // Crimson
        0xFF3DB500, // Leaf
        0xFFFF4FD8, // Orchid
        0xFF0090C8, // Ocean
        0xFFFF7A00, // Tangerine
        0xFF6A1BE0, // Grape
        0xFFE0006E, // Raspberry
        0xFF00897B, // Pine
        0xFFC8A000, // Gold
        0xFF2D3DB8, // Navy
        0xFF0A84FF, // Azure
        0xFF7B83FF, // Periwinkle
        0xFF00D0D0, // Turquoise
        0xFFB5651D, // Copper
        0xFF9C27B0, // Plum
        0xFF5C6B80, // Slate
    ]
    /// The comics library's Unfiled and the image library's Uncategorized folder when first made.
    static let unfiled: Int64 = 0xFF2FA8FF
    static let unsorted: Int64 = 0xFF00C853
    /// What the two default folders were made with before; sync still treats these as untouched.
    static let earlierUnfiled: Int64 = 0xFF2196F3
    static let earlierUnsorted: Int64 = 0xFF66BB70
    private static let slate: Int64 = 0xFF5C6B80
    private static let generatedCount = 512

    /// Every color earlier versions handed out on their own, each with its own replacement, so
    /// folders that differed still differ.
    static let replacements: [Int64: Int64] = [
        0xFF2196F3: 0xFF2FA8FF,
        0xFF66BB70: 0xFF00C853,
        0xFF2563EB: 0xFF1F6BFF,
        0xFF059669: 0xFF00A86B,
        0xFFEA580C: 0xFFFF6A3D,
        0xFFE11D48: 0xFFE3122C,
        0xFF7C3AED: 0xFF6A1BE0,
        0xFF0891B2: 0xFF0090C8,
        0xFFD97706: 0xFFFF7A00,
        0xFFDB2777: 0xFFE0006E,
        0xFF4F46E5: 0xFF4A3DFF,
        0xFF0D9488: 0xFF00897B,
        0xFF65A30D: 0xFF3DB500,
        0xFFC026D3: 0xFF9C27B0,
        0xFFDC2626: 0xFFFF3B30,
        0xFF9333EA: 0xFFB026FF,
        0xFF0284C7: 0xFF0A84FF,
        0xFFB45309: 0xFFB5651D,
        0xFF16A34A: 0xFF00BFA0,
        0xFFF97316: 0xFFFF9500,
        0xFF6366F1: 0xFF8E4BFF,
        0xFF14B8A6: 0xFF00D0D0,
        0xFF84CC16: 0xFF7CD200,
        0xFFEC4899: 0xFFFF2D87,
        0xFFA855F7: 0xFFD63CFF,
        0xFF3B82F6: 0xFF7B83FF,
        0xFF10B981: 0xFF2EE0B0,
        0xFFF59E0B: 0xFFFFB000,
        0xFFEF4444: 0xFFFF4F7B,
        0xFF64748B: 0xFF5C6B80,
    ]

    static func color(at index: Int) -> Int64 {
        index < colors.count ? colors[index] : generated(index - colors.count)
    }

    /// Golden-angle hues after the palette, bright enough to sit with it.
    static func generated(_ index: Int) -> Int64 {
        AppDatabase.colorFromHSV(h: (Double(index) * 0.618033988749895).truncatingRemainder(dividingBy: 1.0), s: 0.8, v: 0.95)
    }
    private static let generatedColors = Set((0..<generatedCount).map(generated))

    static func isCurrent(_ color: Int64) -> Bool { colors.contains(color) || generatedColors.contains(color) }

    /// The first `count` colors none of `used` takes, in the order new folders get them.
    static func unused(_ used: Set<Int64>, count: Int) -> [Int64] {
        var result: [Int64] = []
        var index = 0
        while result.count < count, index < colors.count + generatedCount {
            let color = color(at: index)
            if !used.contains(color) { result.append(color) }
            index += 1
        }
        return result
    }

    static func next(used: Set<Int64>) -> Int64 { unused(used, count: 1).first ?? colors[0] }

    /// A color from an earlier version, a backup, another device or another app, as the closest
    /// current color. Current colors stay as they are.
    static func vivid(_ color: Int64) -> Int64 {
        let opaque = 0xFF000000 | (color & 0xFFFFFF)
        if isCurrent(opaque) { return opaque }
        return replacements[opaque] ?? nearest(opaque)
    }

    /// New colors for a library's folder colors: earlier palette colors by the table, others by
    /// the nearest color no other folder has taken.
    static func replacing(_ colors: [Int64]) -> [Int64: Int64] {
        var result: [Int64: Int64] = [:]
        var taken = Set<Int64>()
        for color in colors {
            let opaque = 0xFF000000 | (color & 0xFFFFFF)
            if isCurrent(opaque) { result[color] = opaque } else if let new = replacements[opaque] { result[color] = new }
            if let new = result[color] { taken.insert(new) }
        }
        for color in colors where result[color] == nil {
            let new = nearest(0xFF000000 | (color & 0xFFFFFF), avoiding: taken)
            result[color] = new
            taken.insert(new)
        }
        return result
    }

    /// Grays go to slate. Other colors keep their hue, made vivid, and take the closest palette
    /// color in OKLab, skipping `avoiding` while any other is left.
    static func nearest(_ color: Int64, avoiding: Set<Int64> = []) -> Int64 {
        let (lightness, a, b) = oklab(color)
        let chroma = (a * a + b * b).squareRoot()
        let free = colors.filter { !avoiding.contains($0) }
        let pool = free.isEmpty ? colors : free
        if chroma < 0.05, pool.contains(slate) || free.isEmpty { return slate }
        let target: (Double, Double, Double)
        if chroma < 0.05 {
            target = (lightness, a, b)
        } else {
            let boosted = max(chroma, 0.17) / chroma
            target = (min(max(lightness, 0.5), 0.82), a * boosted, b * boosted)
        }
        var best = pool[0], bestDistance = Double.infinity
        for candidate in pool where candidate != slate || chroma < 0.05 {
            let (l, ca, cb) = oklab(candidate)
            let distance = (l - target.0) * (l - target.0) + (ca - target.1) * (ca - target.1) + (cb - target.2) * (cb - target.2)
            if distance < bestDistance { best = candidate; bestDistance = distance }
        }
        return best
    }

    private static func oklab(_ argb: Int64) -> (Double, Double, Double) {
        func linear(_ channel: Int64) -> Double {
            let value = Double(channel & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(argb >> 16), g = linear(argb >> 8), b = linear(argb)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}
