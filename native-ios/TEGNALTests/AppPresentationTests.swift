import XCTest
import SwiftUI
@testable import TEGNAL

final class AppPresentationTests: XCTestCase {
    @MainActor func testDetachedModalRootSuppliesModelsBeforeRenderingRealScreens() async throws {
        let env = AppEnvironment.preview()
        for screen in [AnyView(OnboardingView()), AnyView(WebsiteConnectionEditor(server: nil)), AnyView(DownloadsSheet(mode: .booru))] {
            let state = PresentationProbeState()
            // Deliberately no environment on the host. A newly created modal
            // must not need inherited values before evaluating its content.
            let root = AppPresentationRoot(environment: env, content: VStack {
                PresentationModelProbe(name: "detached", expected: env, state: state)
                screen
            })
            let window = try show(root)
            defer { window.isHidden = true; window.rootViewController = nil }
            try await wait { state.seen.contains("detached") }
            XCTAssertTrue(state.identitiesMatch)
        }
    }

    @MainActor func testModalBindingsDismissalAndNestedRootsKeepOriginalModels() async throws {
        let env = AppEnvironment.preview(), state = PresentationProbeState()
        let window = try show(PresentationHarness(state: state, expected: env).environment(env).environment(env.booru))
        defer { window.isHidden = true; window.rootViewController = nil }

        state.sheet = true
        try await wait { state.seen.contains("sheet") }
        state.nested = true
        try await wait { state.seen.contains("nested") }
        XCTAssertTrue(state.identitiesMatch)
        state.dismiss["nested"]?()
        try await wait { !state.nested && state.dismissals == 1 }
        XCTAssertTrue(state.sheet, "Dismissing a nested cover must leave its presenting sheet open")
        state.sheet = false
        try await wait { state.dismissals == 2 }

        state.sheetItem = .init(id: "sheet-item")
        try await wait { state.seen.contains("sheet-item") }
        state.dismiss["sheet-item"]?()
        try await wait { state.sheetItem == nil && state.dismissals == 3 }

        env.mode = .manga
        state.cover = true
        try await wait { state.seen.contains("cover") }
        state.dismiss["cover"]?()
        try await wait { !state.cover && state.dismissals == 4 }

        state.coverItem = .init(id: "cover-item")
        try await wait { state.seen.contains("cover-item") }
        state.dismiss["cover-item"]?()
        try await wait { state.coverItem == nil && state.dismissals == 5 }
        XCTAssertTrue(state.identitiesMatch)
        XCTAssertEqual(state.seen, ["sheet", "nested", "sheet-item", "cover", "cover-item"])
    }

    @MainActor private func show<Content: View>(_ content: Content) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    @MainActor private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "Presentation did not reach the expected state", file: file, line: line)
        // onAppear precedes UIKit's presentation animation completion. A
        // dismiss during that transition can be ignored by the system.
        try await Task.sleep(for: .milliseconds(800))
    }
}

@MainActor @Observable private final class PresentationProbeState {
    struct Item: Identifiable { let id: String }
    var sheet = false
    var nested = false
    var cover = false
    var sheetItem: Item?
    var coverItem: Item?
    var seen: Set<String> = []
    var identitiesMatch = true
    var dismissals = 0
    @ObservationIgnored var dismiss: [String: () -> Void] = [:]
}

private struct PresentationModelProbe: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(BooruStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let name: String
    let expected: AppEnvironment
    let state: PresentationProbeState
    var body: some View {
        // Read both required environment values during body evaluation, the
        // stage that trapped in the external tester's build 16 crash.
        let sameModels = environment === expected && store === expected.booru
        Text(name).frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                state.identitiesMatch = state.identitiesMatch && sameModels
                state.seen.insert(name)
                state.dismiss[name] = { dismiss() }
            }
    }
}

private struct PresentationHarness: View {
    @Bindable var state: PresentationProbeState
    let expected: AppEnvironment
    var body: some View {
        Color.clear
            .appSheet(isPresented: $state.sheet, onDismiss: { state.dismissals += 1 }) {
                probe("sheet")
                    .appFullScreenCover(isPresented: $state.nested, onDismiss: { state.dismissals += 1 }) { probe("nested") }
            }
            .appSheet(item: $state.sheetItem, onDismiss: { state.dismissals += 1 }) { probe($0.id) }
            .appFullScreenCover(isPresented: $state.cover, onDismiss: { state.dismissals += 1 }) { probe("cover") }
            .appFullScreenCover(item: $state.coverItem, onDismiss: { state.dismissals += 1 }) { probe($0.id) }
    }
    private func probe(_ name: String) -> some View {
        PresentationModelProbe(name: name, expected: expected, state: state)
    }
}
