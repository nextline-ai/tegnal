import XCTest
import SwiftUI
import CoreImage
@testable import TEGNAL

final class AppPresentationTests: XCTestCase {
    @MainActor func testImageViewerDragExposesThePresentingScreenInsteadOfABlackBackdrop() async throws {
        let env = AppEnvironment.preview(), state = PresentationProbeState(), server = BooruServer.presets[0]
        env.mode = .booru; try env.booru.saveServer(server)
        var post = BooruFixtureSource.post(101, server: server)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let dataURL = URL(string: "data:image/png;base64," + png.base64EncodedString())!
        post.fileURL = dataURL; post.sampleURL = dataURL; post.previewURL = dataURL
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let window = try show(Color.green.ignoresSafeArea()
            .appFullScreenCover(isPresented: Binding(get: { state.cover }, set: { state.cover = $0 })) {
                BooruPostView(post: post, posts: [post], server: server, source: BooruFixtureSource())
            }.environment(env).environment(env.booru))
        defer { window.rootViewController?.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        state.cover = true
        try await wait { window.rootViewController?.presentedViewController?.view.window != nil }
        let controller = try XCTUnwrap(window.rootViewController?.presentedViewController)
        let surface = ReaderExitSurface.view(for: controller, movesContainer: true)
        let frame = surface.frame, safeArea = surface.safeAreaInsets
        let motion = ReaderExitMotion()
        motion.begin(surface, snapshot: true)
        defer { motion.restore() }
        XCTAssertFalse(motion.surface === surface, "Move the compositor replica without changing the hosting layout")
        XCTAssertTrue(surface.isHidden)
        for distance: CGFloat in [40, 180, 120, 180] {
            motion.update(distance: distance)
            surface.layoutIfNeeded()
            XCTAssertEqual(surface.frame, frame, "Dragging must not resize the navigation/WebKit container")
            XCTAssertEqual(surface.safeAreaInsets, safeArea)
            XCTAssertEqual(motion.surface?.transform.ty, distance)
        }
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let image = try XCTUnwrap(screenshot.cgImage)
        let scale = CGFloat(image.width) / window.bounds.width
        let sample = CGRect(x: CGFloat(image.width) / 2, y: CGFloat(image.height) - 100 * scale, width: 1, height: 1)
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            CIContext().render(CIImage(cgImage: image), toBitmap: bytes.baseAddress!, rowBytes: 4, bounds: sample, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        XCTAssertGreaterThan(Int(pixel[1]), Int(pixel[0]) + 30, "The exposed area must show the green presenting screen, not a black cover")
        XCTAssertGreaterThan(Int(pixel[1]), Int(pixel[2]) + 30)
        motion.restore()
        XCTAssertFalse(surface.isHidden)
        XCTAssertNil(motion.surface)
    }

    @MainActor func testDisabledResumeAnimationRemovesPrivacyCoverImmediately() {
        let manager = PrivacyCoverManager(), window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = UIViewController()
        manager.show(in: [window])
        XCTAssertTrue(window.subviews.contains { $0.accessibilityIdentifier == "privacy.cover" })
        var finished = false
        manager.hide(timing: .init(hold: 0, slide: 0)) { finished = true }
        XCTAssertTrue(finished)
        XCTAssertFalse(window.subviews.contains { $0.accessibilityIdentifier == "privacy.cover" })
    }

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
