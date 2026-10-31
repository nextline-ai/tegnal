#if DEBUG
import SwiftUI

// Local capture fixture. Never added to the production project or a release archive.
enum MarketingCapture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--marketing-capture") }
    static let backup = try! BooruBackup.read(Bundle.main.url(forResource: "marketing-library", withExtension: "json")!)
    static let posts = backup.favorites.map(\.post)
    static func data(_ url: URL) -> Data? {
        guard url.host == "marketing.invalid", let file = Bundle.main.url(forResource: url.deletingPathExtension().lastPathComponent, withExtension: url.pathExtension) else { return nil }
        return try? Data(contentsOf: file)
    }
    @MainActor static func environment() -> AppEnvironment {
        let defaults = UserDefaults(suiteName: "work.nextline.tegnal.marketing")!
        defaults.removePersistentDomain(forName: "work.nextline.tegnal.marketing")
        defaults.set(false, forKey: LibraryCloudSync.enabledKey)
        defaults.set("ko", forKey: "app.language")
        defaults.set("dark", forKey: "booru.app_theme")
        let store = try! BooruStore()
        try! store.restoreBackup(backup)
        let env = AppEnvironment(database: try! .inMemory(), browserPreferences: defaults, booru: store)
        env.mode = .booru; env.gridColumns = 3; env.folderColumns = 2; env.isOnboardingCompleted = true
        env.acknowledgeModeSwitch()
        ReaderPreferences.defaults.set(true, forKey: "onboarding.importReminderDismissed")
        ReaderPreferences.booruDefaults.set("general", forKey: "booru.rating")
        ReaderPreferences.booruDefaults.set(true, forKey: "reader.helpHidden")
        return env
    }
}

struct MarketingSource: BooruProviding {
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        let tags = query.split(separator: " ").map(String.init).filter { !$0.contains(":") }
        let posts = MarketingCapture.posts.filter { post in tags.allSatisfy { post.tags.contains($0) } }
        return .init(posts: page == 0 ? posts : [], hasMore: false)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] {
        let tags = Set(MarketingCapture.posts.flatMap(\.tags)).filter { $0.hasPrefix(token) }.sorted()
        return tags.map { name in .init(name: name, count: MarketingCapture.posts.filter { $0.tags.contains(name) }.count, category: 0) }
    }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}
#endif
