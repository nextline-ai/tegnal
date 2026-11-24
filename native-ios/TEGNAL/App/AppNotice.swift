import Foundation
import Observation
import SwiftUI

/// A notice TEGNAL can publish to ask older copies of the app to update (`v1/app/notice.json`, signed with the add-on key).
/// It applies to builds below the number given for this platform. Format: `docs/features/live-shop.md` §3.
struct AppNotice: Decodable, Equatable, Sendable {
    static let format = "tegnal-app-notice"
    static let schemaVersion = 1
    static let maximumBytes = 64 * 1024
    static let url = AddonMarket.liveBase.appending(path: "app/notice.json")
    /// Where the app is sold, for a notice that names no address.
    static let storeURL = URL(string: "https://apps.apple.com/app/id6825935560")!

    enum Level: String, Decodable, Sendable {
        /// Cannot be closed: the only way on is to update.
        case required
        /// Can be put off; the same notice is not shown again once put off.
        case recommended
    }

    struct Platform: Decodable, Equatable, Sendable {
        /// Builds below this number see the notice.
        var below: Int
        var url: URL?
    }

    var id: String
    var level: Level
    var title: LabText
    var message: LabText
    var ios: Platform?
    var android: Platform?

    /// True when this build is old enough for the notice.
    func applies(to build: Int) -> Bool { build < (ios?.below ?? 0) }
    var store: URL { ios?.url.flatMap { ["https"].contains($0.scheme) ? $0 : nil } ?? Self.storeURL }

    static func decode(_ data: Data) throws -> AppNotice {
        struct Head: Decodable { var format: String; var schemaVersion: Int }
        guard let head = try? JSONDecoder().decode(Head.self, from: data), head.format == format, (1...schemaVersion).contains(head.schemaVersion),
              let notice = try? JSONDecoder().decode(AppNotice.self, from: data), !notice.id.isEmpty, notice.id.count <= 64 else { throw LabShopError.invalid }
        return notice
    }

    static var build: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
}

/// Reads TEGNAL's update notice when the app opens or comes back, at most once an hour, and holds the one to show.
@MainActor @Observable
final class AppNotices {
    static let shared = AppNotices()
    static let putOffKey = "app.notice.putOff"

    /// The notice to show now, if any.
    private(set) var current: AppNotice?
    /// The last notice read, shown or not. The shop's "update the app" button uses its store address.
    private(set) var latest: AppNotice?
    @ObservationIgnored private var checked: Date?
    @ObservationIgnored private let fetch: @Sendable () async throws -> Data
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let build: Int

    init(defaults: UserDefaults = .standard, build: Int = AppNotice.build,
         fetch: @escaping @Sendable () async throws -> Data = { try await AddonMarket.live.fetch(AppNotice.url, AppNotice.maximumBytes * 2) }) {
        self.defaults = defaults
        self.build = build
        self.fetch = fetch
    }

    var storeURL: URL { latest?.store ?? AppNotice.storeURL }

    func check(force: Bool = false) async {
        #if DEBUG
        if let notice = Self.debugNotice() { show(notice); return }
        if ProcessInfo.processInfo.arguments.contains(where: { $0.contains("ui-test") || $0.hasPrefix("--lab-") }) { return }
        #endif
        if !force, let checked, Date().timeIntervalSince(checked) < 3600 { return }
        checked = Date()
        guard let file = try? await fetch(),
              let payload = try? LabSigned.payload(file, key: AddonMarket.live.publicKey, limit: AppNotice.maximumBytes),
              let notice = try? AppNotice.decode(payload) else { return }
        show(notice)
    }

    /// Takes a notice read and decides whether it is shown.
    func show(_ notice: AppNotice) {
        latest = notice
        guard notice.applies(to: build) else { current = nil; return }
        if notice.level == .recommended, defaults.string(forKey: Self.putOffKey) == notice.id { current = nil; return }
        current = notice
    }

    /// "Later" on a recommended notice: that notice is not shown again.
    func putOff() {
        guard let current, current.level == .recommended else { return }
        defaults.set(current.id, forKey: Self.putOffKey)
        self.current = nil
    }

    #if DEBUG
    /// `--app-notice=required` or `=recommended` shows a sample notice, for tests and screenshots.
    private static func debugNotice() -> AppNotice? {
        guard let level = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--app-notice=") })?.dropFirst(13),
              let parsed = AppNotice.Level(rawValue: String(level)) else { return nil }
        return AppNotice(id: "test", level: parsed, title: LabText(values: ["ko": "업데이트가 필요합니다", "en": "Update Required"]),
                         message: LabText(values: ["ko": "테스트 알림입니다.", "en": "This is a test notice."]),
                         ios: .init(below: Int.max, url: nil), android: nil)
    }
    #endif
}

/// Shows TEGNAL's update notice over the whole app: a recommended one as an alert, a required one as a screen that stays.
struct AppNoticeModifier: ViewModifier {
    let active: Bool
    @State private var notices = AppNotices.shared
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .task(id: active) { if active { await notices.check() } }
            .alert(notices.current?.title.text ?? "", isPresented: Binding(get: { active && notices.current?.level == .recommended },
                                                                         set: { if !$0 { notices.putOff() } })) {
                Button(L10n.text("notice.update")) { openURL(notices.storeURL); notices.putOff() }
                Button(L10n.text("notice.later"), role: .cancel) { notices.putOff() }
            } message: { Text(notices.current?.message.text ?? "") }
            .fullScreenCover(isPresented: Binding(get: { active && notices.current?.level == .required }, set: { _ in })) {
                AppNoticeScreen(notice: notices.current) { openURL(notices.storeURL) }
                    .interactiveDismissDisabled()
            }
    }
}

/// The screen a required update leaves: what happened, and the one way on.
struct AppNoticeScreen: View {
    let notice: AppNotice?
    let update: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "arrow.down.app.fill").font(.system(size: 64, weight: .semibold)).foregroundStyle(.tint).symbolRenderingMode(.hierarchical)
            Text(notice?.title.text ?? "").font(.title2.bold()).multilineTextAlignment(.center).accessibilityIdentifier("notice.title")
            Text(notice?.message.text ?? "").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Button(action: update) {
                Text(L10n.text("notice.update")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
            .accessibilityIdentifier("notice.update")
        }
        .padding(.horizontal, 28).padding(.bottom, 24)
    }
}

extension View {
    /// Shows TEGNAL's update notice when one applies to this build.
    func appNotice(active: Bool) -> some View { modifier(AppNoticeModifier(active: active)) }
}
