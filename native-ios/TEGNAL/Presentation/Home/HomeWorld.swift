import UIKit

/// One drawing standing somewhere in the world the camera travels through.
struct HomeSprite {
    enum Side { case free, leading, trailing }
    let art: String
    /// The camera's place, in screen heights from the home scene, at which the drawing is level with the middle of the screen.
    let at: Double
    /// Its middle across the screen, from 0 to 1. A drawing on a side hugs that edge instead.
    var x: Double = 0.5
    /// Its width, as a share of a phone's width. A drawing that spans is measured against the screen's width.
    var width: Double = 1
    var side = Side.free
    var spans = false
    var mirrored = false
    var opacity: Float = 1
}

/// Drawings at one distance. A plane nearer than 1 passes faster than the camera, a farther one slower.
struct HomePlane {
    let depth: Double
    let sprites: [HomeSprite]
}

enum HomeWorld {
    static func planes(_ realm: HomeRealm) -> [HomePlane] { realm == .library ? underground : sky }

    /// The drawing the world ends in: the cave's roof, or the top of the clouds.
    static func edge(_ realm: HomeRealm) -> String { realm == .library ? "HomeCeiling" : "HomeCloudBank" }
    /// The share of that drawing's height, from its top, that lies on the world's last line.
    static func edgeLine(_ realm: HomeRealm) -> CGFloat { realm == .library ? 0.2 : 0.7 }

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// The colours behind everything, from the home scene to the world's end.
    static func backdrop(_ realm: HomeRealm) -> (colors: [UIColor], stops: [NSNumber]) {
        realm == .library
            ? ([0x1E1430, 0x1A112C, 0x150D26, 0x120B21, 0x0D0716].map { color($0) }, [0, 0.2, 0.45, 0.7, 1])
            : ([0x0B0717, 0x100B2A, 0x1C1354, 0x33248C, 0x5B45C4, 0x8F78EA].map { color($0) }, [0, 0.18, 0.42, 0.64, 0.84, 1])
    }

    /// What lies just past the end, thinning out over the place: the cave's shade, or mist off the clouds.
    static func veil(_ realm: HomeRealm) -> [UIColor] {
        realm == .library ? [color(0x0D0716, 0.86), color(0x0D0716, 0.5), color(0x0D0716, 0)] : [color(0xF4EEFF, 0.75), color(0xE2D6FF, 0.35), color(0xE2D6FF, 0)]
    }

    private static let underground: [HomePlane] = [
        HomePlane(depth: 0.45, sprites: [
            HomeSprite(art: "HomeStrataA", at: 0.9, width: 1.5, spans: true, mirrored: true, opacity: 0.4),
            HomeSprite(art: "HomeGems", at: 1.3, x: 0.35, width: 1.1, opacity: 0.8),
            HomeSprite(art: "HomeLantern", at: 1.5, x: 0.78, width: 0.3, opacity: 0.5),
            HomeSprite(art: "HomeStrataB", at: 2.1, width: 1.5, spans: true, opacity: 0.35),
            HomeSprite(art: "HomeGems", at: 2.5, x: 0.6, width: 1.1, mirrored: true, opacity: 0.8),
        ]),
        HomePlane(depth: 0.75, sprites: [
            HomeSprite(art: "HomeCrystals", at: 0.95, width: 0.52, side: .leading),
            HomeSprite(art: "HomeLantern", at: 1.3, x: 0.72, width: 0.44, opacity: 0.9),
            HomeSprite(art: "HomeCrystals", at: 1.75, width: 0.5, side: .trailing, mirrored: true),
            HomeSprite(art: "HomeMushrooms", at: 2.3, x: 0.3, width: 0.34),
        ]),
        HomePlane(depth: 1, sprites: [
            HomeSprite(art: "HomeStrataA", at: 0.6, spans: true),
            HomeSprite(art: "HomeGems", at: 0.97, width: 1),
            HomeSprite(art: "HomeRelicFrame", at: 0.98, x: 0.7, width: 0.3),
            HomeSprite(art: "HomeStrataB", at: 1.34, spans: true),
            HomeSprite(art: "HomeGems", at: 1.68, width: 1, mirrored: true),
            HomeSprite(art: "HomeRelicBooks", at: 1.7, x: 0.3, width: 0.3),
            HomeSprite(art: "HomeStrataA", at: 2.06, spans: true, mirrored: true),
            HomeSprite(art: "HomeGems", at: 2.42, width: 1),
        ]),
        HomePlane(depth: 1.35, sprites: [
            HomeSprite(art: "HomeRockSide", at: 1.15, width: 0.4, side: .leading),
            HomeSprite(art: "HomeRockSide", at: 1.85, width: 0.4, side: .trailing, mirrored: true),
            HomeSprite(art: "HomeCrystals", at: 2.25, width: 0.56, side: .leading),
        ]),
        HomePlane(depth: 1.8, sprites: [
            HomeSprite(art: "HomeRockSide", at: 2.05, width: 0.44, side: .trailing, mirrored: true),
        ]),
    ]

    private static let sky: [HomePlane] = [
        HomePlane(depth: 0.45, sprites: [
            HomeSprite(art: "HomeStarfield", at: 0.5, x: 0.4, width: 1.3, opacity: 0.8),
            HomeSprite(art: "HomeStarfield", at: 1.2, x: 0.6, width: 1.3, mirrored: true, opacity: 0.75),
            HomeSprite(art: "HomeCloudC", at: 1.9, x: 0.7, width: 0.8, opacity: 0.45),
            HomeSprite(art: "HomeStarfield", at: 2.1, x: 0.45, width: 1.3, opacity: 0.7),
            HomeSprite(art: "HomeCloudB", at: 2.6, x: 0.25, width: 0.7, opacity: 0.5),
        ]),
        HomePlane(depth: 0.75, sprites: [
            HomeSprite(art: "HomeCloudB", at: 0.5, x: 0.84, width: 0.62, opacity: 0.55),
            HomeSprite(art: "HomeShootingStar", at: 0.75, x: 0.62, width: 0.5),
            HomeSprite(art: "HomeCloudA", at: 1.1, x: 0.14, width: 0.9, opacity: 0.85),
            HomeSprite(art: "HomeMoon", at: 1.45, x: 0.74, width: 0.6),
            HomeSprite(art: "HomeCloudB", at: 1.95, x: 0.82, width: 0.74, opacity: 0.9),
            HomeSprite(art: "HomeCloudC", at: 2.4, x: 0.24, width: 0.86, opacity: 0.9),
        ]),
        HomePlane(depth: 1, sprites: [
            HomeSprite(art: "HomeStarfield", at: 0.45, width: 1),
            HomeSprite(art: "HomeConstellation", at: 0.92, x: 0.36, width: 0.56),
            HomeSprite(art: "HomeStarfield", at: 1.1, width: 1, mirrored: true),
            HomeSprite(art: "HomeStarfield", at: 1.75, width: 1, opacity: 0.9),
            HomeSprite(art: "HomeSparkle", at: 2.02, x: 0.3, width: 0.34),
            HomeSprite(art: "HomeStarfield", at: 2.36, width: 1, mirrored: true, opacity: 0.9),
        ]),
        HomePlane(depth: 1.35, sprites: [
            HomeSprite(art: "HomeCloudA", at: 1.45, x: 0.86, width: 1.05, mirrored: true),
            HomeSprite(art: "HomeCloudC", at: 2.0, x: 0.1, width: 1.1),
        ]),
        HomePlane(depth: 1.8, sprites: [
            HomeSprite(art: "HomeCloudB", at: 2.1, x: 0.8, width: 1.3),
        ]),
    ]
}

/// Turns the drawings into pictures the right size for this screen, once, away from the main thread.
enum HomeArt {
    struct Request: Hashable, Sendable {
        let art: String
        let width: Int
        /// 1 for what stays far away and dim, 2 for the rest.
        let detail: Int
    }

    nonisolated static func render(_ request: Request, screenScale: CGFloat) -> CGImage? {
        guard let image = UIImage(named: request.art), image.size.width > 0 else { return nil }
        let width = CGFloat(request.width)
        let size = CGSize(width: width, height: (width * image.size.height / image.size.width).rounded(.up))
        let format = UIGraphicsImageRendererFormat()
        // Soft, painted shapes do not need every pixel of a 3x screen, and far ones need fewer still.
        format.scale = min(screenScale, CGFloat(request.detail))
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.cgImage
    }

    /// Every picture the two journeys need on a screen of this size.
    static func requests(for size: CGSize) -> Set<Request> {
        var all: Set<Request> = [ground(size), lantern(size)]
        for realm in HomeRealm.allCases {
            all.insert(edge(realm, size: size, wide: false)); all.insert(edge(realm, size: size, wide: true))
            for plane in HomeWorld.planes(realm) { for sprite in plane.sprites { all.insert(request(sprite, depth: plane.depth, size: size)) } }
        }
        return all
    }

    static func unit(_ size: CGSize) -> CGFloat { min(size.width, size.height * 0.46) }

    static func ground(_ size: CGSize) -> Request { Request(art: "HomeGroundEdge", width: Int(size.width.rounded(.up)), detail: 2) }
    static func lantern(_ size: CGSize) -> Request { Request(art: "HomeLantern", width: Int((unit(size) * 0.4).rounded(.up)), detail: 2) }
    static func edge(_ realm: HomeRealm, size: CGSize, wide: Bool) -> Request {
        Request(art: HomeWorld.edge(realm), width: Int((size.width * (wide ? 1.3 : 1.04)).rounded(.up)), detail: 2)
    }

    static func request(_ sprite: HomeSprite, depth: Double, size: CGSize) -> Request {
        let width = sprite.spans ? size.width * sprite.width : unit(size) * sprite.width
        return Request(art: sprite.art, width: Int(width.rounded(.up)), detail: depth < 0.5 ? 1 : 2)
    }
}

/// The layers of one journey.
///
/// Everything between the home scene and the world's end lives in `world`, which is cut off
/// along that end, so that slow, far-off drawings never trail out over the place beyond it. The
/// end itself, with what hangs past it, is `edge`. Both move with the camera; the planes inside
/// the world move a little more or less, by their distance.
@MainActor final class HomeRealmLayers {
    let realm: HomeRealm
    let container = CALayer()
    let world = CALayer()
    let edge = CALayer()
    private(set) var planes: [(depth: Double, layer: CALayer)] = []
    let drift = CAEmitterLayer()

    init(realm: HomeRealm, size: CGSize, images: [HomeArt.Request: CGImage]) {
        self.realm = realm
        let bounds = CGRect(origin: .zero, size: size)
        let direction = realm.direction, height = size.height
        let length = height * HomeTravel.depth
        // Where the world begins on screen before the camera has moved: under the picture, or over it.
        let top = realm == .library ? height : -length
        let line = realm == .library ? height + length : -length
        container.frame = bounds
        world.frame = CGRect(x: 0, y: top, width: size.width, height: length)
        world.masksToBounds = true
        world.addSublayer(backdrop(size: CGSize(width: size.width, height: length)))
        for plane in HomeWorld.planes(realm) {
            let layer = CALayer()
            layer.frame = world.bounds
            for sprite in plane.sprites {
                let request = HomeArt.request(sprite, depth: plane.depth, size: size)
                guard let image = images[request] else { continue }
                let width = CGFloat(request.width), tall = width * CGFloat(image.height) / CGFloat(image.width)
                let piece = CALayer()
                piece.contents = image
                piece.bounds = CGRect(x: 0, y: 0, width: width, height: tall)
                let x: CGFloat
                switch sprite.side {
                case .free: x = size.width * sprite.x
                case .leading: x = width / 2 - width * 0.1
                case .trailing: x = size.width - width / 2 + width * 0.1
                }
                piece.position = CGPoint(x: x, y: height / 2 + direction * sprite.at * plane.depth * height - top)
                piece.opacity = sprite.opacity
                if sprite.mirrored { piece.transform = CATransform3DMakeScale(-1, 1, 1) }
                layer.addSublayer(piece)
            }
            world.addSublayer(layer)
            planes.append((plane.depth, layer))
        }
        container.addSublayer(world)

        edge.frame = bounds
        // The shade under the roof, or the mist over the clouds, reaches out over the place.
        let veil = CAGradientLayer()
        veil.colors = HomeWorld.veil(realm).map(\.cgColor)
        veil.locations = [0, 0.4, 1]
        let reach = height * HomeTravel.overhang
        if realm == .library {
            veil.frame = CGRect(x: 0, y: line - 2, width: size.width, height: reach)
        } else {
            veil.frame = CGRect(x: 0, y: line + 2 - reach, width: size.width, height: reach)
            veil.startPoint = CGPoint(x: 0.5, y: 1); veil.endPoint = CGPoint(x: 0.5, y: 0)
        }
        edge.addSublayer(veil)
        if realm == .library, let image = images[HomeArt.lantern(size)] {
            // Two lanterns hang from the roof on their chains, the last things passed.
            let width = HomeArt.unit(size) * 0.4, tall = width * CGFloat(image.height) / CGFloat(image.width)
            for (x, scale) in [(0.2, 1.0), (0.83, 0.78)] {
                let lantern = CALayer()
                lantern.contents = image
                lantern.frame = CGRect(x: size.width * x - width * scale / 2, y: line, width: width * scale, height: tall * scale)
                edge.addSublayer(lantern)
            }
        }
        // The edge is two deep: a wider copy, turned round, stands a little behind the nearer one.
        for wide in [true, false] {
            let request = HomeArt.edge(realm, size: size, wide: wide)
            guard let image = images[request] else { continue }
            let width = CGFloat(request.width), tall = width * CGFloat(image.height) / CGFloat(image.width)
            let piece = CALayer()
            piece.contents = image
            piece.frame = CGRect(x: (size.width - width) / 2, y: line - tall * HomeWorld.edgeLine(realm) - (wide ? height * 0.035 : 0), width: width, height: tall)
            if wide { piece.transform = CATransform3DMakeScale(-1, 1, 1); piece.opacity = realm == .library ? 1 : 0.85 }
            edge.addSublayer(piece)
        }
        container.addSublayer(edge)

        drift.frame = bounds
        drift.opacity = 0
        drift.birthRate = 0
        drift.renderMode = .additive
        if realm == .library {
            drift.emitterShape = .rectangle
            drift.emitterMode = .surface
            drift.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
            drift.emitterSize = CGSize(width: size.width, height: size.height * 1.2)
            drift.emitterCells = [mote(UIColor(red: 1, green: 0.84, blue: 0.56, alpha: 0.9), rate: 7), mote(UIColor(red: 0.74, green: 0.62, blue: 1, alpha: 0.8), rate: 5)]
        } else {
            drift.emitterShape = .line
            drift.emitterPosition = CGPoint(x: bounds.midX, y: -60)
            drift.emitterSize = CGSize(width: size.width, height: 1)
            drift.emitterCells = [streak(), twinkle()]
        }
    }

    private func backdrop(size: CGSize) -> CALayer {
        let gradient = CAGradientLayer()
        let colours = HomeWorld.backdrop(realm)
        gradient.colors = colours.colors.map(\.cgColor)
        gradient.locations = colours.stops
        gradient.frame = CGRect(origin: .zero, size: size)
        // The colours run outward from the home scene: downward under the ground, upward in the sky.
        if realm == .study { gradient.startPoint = CGPoint(x: 0.5, y: 1); gradient.endPoint = CGPoint(x: 0.5, y: 0) }
        return gradient
    }

    private static let dot: CGImage? = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
        let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.35).cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 1]) else { return }
        context.cgContext.drawRadialGradient(gradient, startCenter: CGPoint(x: 16, y: 16), startRadius: 0, endCenter: CGPoint(x: 16, y: 16), endRadius: 16, options: [])
    }.cgImage

    private static let line: CGImage? = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 72)).image { context in
        let colors = [UIColor.white.withAlphaComponent(0).cgColor, UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.8, 1]) else { return }
        context.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 1.5, y: 0), end: CGPoint(x: 1.5, y: 72), options: [])
    }.cgImage

    private func mote(_ color: UIColor, rate: Float) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = Self.dot
        cell.birthRate = rate
        cell.lifetime = 5; cell.lifetimeRange = 2
        cell.velocity = 34; cell.velocityRange = 26
        cell.emissionLongitude = -.pi / 2; cell.emissionRange = .pi / 2.5
        cell.yAcceleration = -8
        cell.scale = 0.13; cell.scaleRange = 0.09; cell.scaleSpeed = -0.008
        cell.color = color.cgColor
        cell.alphaRange = 0.4; cell.alphaSpeed = -0.16
        return cell
    }

    private func streak() -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = Self.line
        cell.birthRate = 9
        cell.lifetime = 2.2
        cell.velocity = 640; cell.velocityRange = 300
        cell.emissionLongitude = .pi / 2
        cell.scale = 0.7; cell.scaleRange = 0.5
        cell.color = UIColor(red: 0.9, green: 0.86, blue: 1, alpha: 0.5).cgColor
        cell.alphaRange = 0.3
        return cell
    }

    private func twinkle() -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = Self.dot
        cell.birthRate = 16
        cell.lifetime = 4.5
        cell.velocity = 150; cell.velocityRange = 90
        cell.emissionLongitude = .pi / 2
        cell.scale = 0.12; cell.scaleRange = 0.1
        cell.color = UIColor(white: 1, alpha: 0.9).cgColor
        cell.alphaRange = 0.5; cell.alphaSpeed = -0.12
        return cell
    }
}
