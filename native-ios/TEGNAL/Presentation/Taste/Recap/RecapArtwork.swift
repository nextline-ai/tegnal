import SwiftUI

/// Resolves works to images once per screen. Failures stay quiet: a tile without
/// artwork falls back to the issue's own colors instead of a broken placeholder.
@MainActor @Observable
final class RecapArtwork {
    @ObservationIgnored private var posts: [String: (BooruPost, BooruServer)] = [:]
    @ObservationIgnored private var cache: [String: UIImage] = [:]
    @ObservationIgnored private let env: AppEnvironment
    init(env: AppEnvironment) {
        self.env = env
        let servers = env.booru.servers
        for post in env.booru.visibleFavorites() {
            guard let server = servers.first(where: { $0.id == post.serverID }) else { continue }
            posts[server.canonicalAddress + "#" + String(post.postID)] = (post, server)
        }
    }
    func post(_ work: RecapWork) -> BooruPost? { posts[work.id]?.0 }
    func cached(_ work: RecapWork, large: Bool = false) -> UIImage? { cache[work.id + (large ? "+" : "")] ?? cache[work.id] }
    func image(_ work: RecapWork, large: Bool = false, generated: Bool = false) async -> UIImage? {
        let key = work.id + (large ? "+" : "")
        if let image = cache[key] { return image }
        var image: UIImage?
        if generated || Self.usesFixtures { image = RecapGeneratedArt.image(seed: Int(truncatingIfNeeded: work.item.id)) }
        else if let (post, server) = posts[work.id] {
            // Previews are small; the page's lead image can afford one sample request.
            let sample = large && !post.isVideo && !post.isAnimated ? post.sampleURL : nil
            if let url = sample ?? post.previewURL ?? post.sampleURL {
                image = try? await BooruThumbnailCache.shared.image(url: url, server: server)
            }
        } else if let path = work.info.thumbPath { image = await LocalThumbnailCache.shared.load(forPath: path) }
        if let image { cache[key] = image }
        return image
    }
    private static var usesFixtures: Bool {
        #if DEBUG
        return BooruUITestSupport.enabled
        #else
        return false
        #endif
    }
}

/// Procedural landscapes for the sample issue, which has no library to draw from.
enum RecapGeneratedArt {
    static func image(seed: Int, size: CGSize = CGSize(width: 480, height: 640)) -> UIImage {
        var state = UInt64(truncatingIfNeeded: seed) &* 2654435761 &+ 12345
        func next() -> CGFloat { state = state &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((state >> 33) % 1000) / 1000 }
        let hue = next(), shift = 0.06 + next() * 0.14
        func tone(_ offset: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> UIColor { UIColor(hue: (hue + offset).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness, alpha: 1) }
        return UIGraphicsImageRenderer(size: size).image { renderer in
            let context = renderer.cgContext
            let colors = [tone(0, 0.62, 0.34).cgColor, tone(shift, 0.72, 0.82).cgColor, tone(shift * 2, 0.5, 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.62, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            tone(shift * 2.6, 0.28, 1).setFill()
            let sun = size.width * (0.1 + next() * 0.12)
            context.fillEllipse(in: CGRect(x: size.width * (0.15 + next() * 0.6), y: size.height * (0.16 + next() * 0.3), width: sun * 2, height: sun * 2))
            for layer in 0..<4 {
                let path = UIBezierPath(), floor = size.height * (0.5 + CGFloat(layer) * 0.13)
                let swell = size.height * (0.05 + next() * 0.09), phase = next() * 6, wave = 1.2 + next() * 2.4
                path.move(to: CGPoint(x: 0, y: size.height))
                for step in 0...40 {
                    let x = size.width * CGFloat(step) / 40
                    path.addLine(to: CGPoint(x: x, y: floor + sin(x / size.width * wave * .pi * 2 + phase) * swell))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height)); path.close()
                tone(-shift * CGFloat(layer) * 0.8, 0.55 + CGFloat(layer) * 0.08, 0.62 - CGFloat(layer) * 0.14).setFill()
                path.fill()
            }
        }
    }
}

/// One tile of a recap. Private mode swaps the image for the issue's colors
/// before any pixels reach the screen.
struct RecapArtTile: View {
    let work: RecapWork?
    let palette: RecapPalette
    var large = false
    var generated = false
    var seed = 3
    @Environment(RecapArtwork.self) private var artwork
    @Environment(\.recapPrivate) private var isPrivate
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            Group {
                if !isPrivate, let image = image ?? work.flatMap({ artwork.cached($0, large: large) }) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else { RecapColorField(palette: palette, seed: seed + (work.map { Int(truncatingIfNeeded: $0.item.id) } ?? 0)) }
            }.transition(.opacity)
        }
        .accessibilityHidden(true)
        .task(id: "\(work?.id ?? ""):\(large):\(isPrivate)") {
            guard !isPrivate, let work else { return }
            let loaded = await artwork.image(work, large: large, generated: generated)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { image = loaded }
        }
    }
}

private struct RecapPrivateKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var recapPrivate: Bool {
        get { self[RecapPrivateKey.self] }
        set { self[RecapPrivateKey.self] = newValue }
    }
}
