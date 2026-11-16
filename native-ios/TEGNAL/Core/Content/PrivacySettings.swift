import Foundation
import Network
import UIKit

/// App-wide privacy choices, kept on this device only (never synced or backed up).
enum PrivacySettings {
    static let incognitoKey = "privacy.incognito"
    static let captureProtectionKey = "privacy.captureProtection"
    static let encryptedDNSKey = "privacy.encryptedDNS"

    /// While on, works opened, searches and viewing time are not recorded: no recent works, no
    /// search history, no taste learning from browsing. Saving a work is a deliberate choice and
    /// still reaches the library.
    static var isIncognito: Bool { ContentPreferences.defaults.bool(forKey: incognitoKey) }

    /// Covers the app while the screen is recorded or mirrored. iOS lets no app block a screenshot.
    static var protectsScreenCapture: Bool { ContentPreferences.defaults.bool(forKey: captureProtectionKey) }
}

/// The app's own encrypted DNS: website names are looked up over HTTPS, so a network that reads
/// or rewrites DNS answers can neither see nor redirect them. It covers every URLSession and
/// Network.framework connection in the app; WebKit pages use the system's resolver.
enum EncryptedDNS: String, CaseIterable, Identifiable {
    case off, cloudflare, google, quad9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return L10n.text("Off")
        case .cloudflare: return "Cloudflare"
        case .google: return "Google"
        case .quad9: return "Quad9"
        }
    }

    var resolver: URL? {
        switch self {
        case .off: return nil
        case .cloudflare: return URL(string: "https://cloudflare-dns.com/dns-query")
        case .google: return URL(string: "https://dns.google/dns-query")
        case .quad9: return URL(string: "https://dns.quad9.net/dns-query")
        }
    }

    /// The resolver's own addresses, so reaching it needs no plain DNS lookup.
    var bootstrapAddresses: [String] {
        switch self {
        case .off: return []
        case .cloudflare: return ["1.1.1.1", "1.0.0.1"]
        case .google: return ["8.8.8.8", "8.8.4.4"]
        case .quad9: return ["9.9.9.9", "149.112.112.112"]
        }
    }

    static var current: EncryptedDNS {
        EncryptedDNS(rawValue: ContentPreferences.defaults.string(forKey: PrivacySettings.encryptedDNSKey) ?? "") ?? .off
    }

    /// Applies the stored choice to the app's default privacy context. Off leaves the system's
    /// own settings (including a DNS profile the person installed) untouched.
    static func applyStored(changed: Bool = false) {
        let choice = current
        guard choice != .off || changed else { return }
        let context = NWParameters.PrivacyContext.default
        if let url = choice.resolver {
            let servers: [NWEndpoint] = choice.bootstrapAddresses.compactMap { address in
                IPv4Address(address).map { .hostPort(host: .ipv4($0), port: 443) }
            }
            context.requireEncryptedNameResolution(true, fallbackResolver: .https(url, serverAddresses: servers))
        } else {
            context.requireEncryptedNameResolution(false, fallbackResolver: nil)
        }
    }
}

/// Puts the privacy cover over every window while the screen is being recorded or mirrored, when
/// the person asked for it. The app switcher cover works on its own and is unaffected.
@MainActor final class ScreenCaptureGuard {
    static let shared = ScreenCaptureGuard()
    private var observer: NSObjectProtocol?
    private var covering = false

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenCaptureGuard.shared.update() }
        }
        update()
    }

    var isCaptured: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .contains { $0.traitCollection.sceneCaptureState == .active }
    }

    func update() {
        if PrivacySettings.protectsScreenCapture && isCaptured {
            PrivacyCoverManager.shared.show()
            covering = true
        } else if covering {
            covering = false
            // A cover kept for the app switcher leaves with the app's own return animation.
            guard UIApplication.shared.applicationState == .active else { return }
            PrivacyCoverManager.shared.hide(timing: SplashTiming(hold: 0, slide: 0))
        }
    }
}
