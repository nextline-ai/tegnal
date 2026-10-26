import XCTest
import SwiftUI
import GRDB
@testable import TEGNAL

final class GridLayoutTests: XCTestCase {
    func testPreviewPaginationKeepsFiveRowsRegardlessOfColumnCountAndCoversEveryPage() {
        for columns in [1, 2, 6, 10] {
            let count = GalleryPreviewLayout.pageCount(total: 123, columns: columns, rows: 5)
            let ranges = (0..<count).map { GalleryPreviewLayout.pageRange($0, total: 123, columns: columns, rows: 5) }
            XCTAssertEqual(ranges.first?.count, columns * 5)
            XCTAssertTrue(ranges.allSatisfy { $0.count <= columns * 5 })
            XCTAssertEqual(ranges.flatMap(Array.init), Array(0..<123), "Changing columns must not skip or duplicate artwork pages")
            let geometry = ArtworkGridGeometry(width: 390, columns: columns, removesPadding: false, maximumColumns: 10)
            XCTAssertEqual(GalleryPreviewLayout.height(rows: 5, geometry: geometry),
                           geometry.cellWidth / 0.72 * 5 + geometry.spacing * 4 + geometry.margin * 2, accuracy: 0.001)
        }
        XCTAssertEqual(GalleryPreviewLayout.pageRange(1, total: 123, columns: 4, rows: 3), 12..<24)
        XCTAssertEqual(GalleryPreviewLayout.pageRange(99, total: 123, columns: 4, rows: 3), 123..<123)
    }

    @MainActor func testModeContainerConnectsOnlyTheSelectedTreeAndRetainsEachHost() async throws {
        let controller = RetainedModeController()
        let manga = AnyView(NavigationStack { Text("Comics") }), booru = AnyView(NavigationStack { Text("Images") })
        func show(_ mode: AppMode) async {
            controller.update(mode: mode, manga: manga, booru: booru)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        await show(.manga)
        let mangaHost = try XCTUnwrap(controller.children.first)
        await show(.booru)
        let booruHost = try XCTUnwrap(controller.children.first)
        XCTAssertNil(mangaHost.parent)
        XCTAssertNil(mangaHost.view.superview)
        for mode: AppMode in [.manga, .booru, .manga, .booru] {
            await show(mode)
            let expected = mode == .manga ? mangaHost : booruHost
            let inactive = mode == .manga ? booruHost : mangaHost
            XCTAssertEqual(controller.children.count, 1, "An inactive navigation tree must not keep owning the toolbar")
            XCTAssertTrue(controller.children.first === expected)
            XCTAssertTrue(expected.view.superview === controller.view)
            XCTAssertTrue(expected.view.isUserInteractionEnabled)
            XCTAssertFalse(expected.view.isHidden)
            XCTAssertNil(inactive.parent)
            XCTAssertNil(inactive.view.superview)
        }
        controller.update(mode: .manga, manga: manga, booru: booru)
        await show(.booru)
        XCTAssertTrue(controller.children.first === booruHost, "Queued updates must apply only the latest requested mode")
    }

    @MainActor func testModeSlideKeepsChromeFixedAndPanelsJoinedDuringReversal() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = RetainedModeController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func screen(_ title: String, color: Color) -> AnyView {
            AnyView(TabView {
                NavigationStack {
                    color.ignoresSafeArea().overlay(Text(title))
                        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                }.tabItem { Label("Saved", systemImage: "folder") }
            })
        }
        let manga = screen("Comics", color: .blue), booru = screen("Images", color: .orange)
        func descendant(_ root: UIView, identifier: String) -> UIView? {
            if root.accessibilityIdentifier == identifier { return root }
            return root.subviews.lazy.compactMap { descendant($0, identifier: identifier) }.first
        }
        func visibleBars(_ root: UIView) -> [UIView] {
            guard !root.isHidden, root.alpha > 0.01 else { return [] }
            if root is UINavigationBar || root is UITabBar { return [root] }
            return root.subviews.flatMap(visibleBars)
        }
        func show(_ mode: AppMode) async {
            controller.update(mode: mode, manga: manga, booru: booru)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        func assertOpaqueScreen() {
            XCTAssertEqual(controller.children.count, 1, "The outgoing screen must be frozen rather than keeping two live glass trees")
            let opacities = controller.children.map { child in
                child.view.layer.presentation().map { CGFloat($0.opacity) } ?? child.view.alpha
            }
            XCTAssertGreaterThanOrEqual(opacities.max() ?? 0, 0.999, "A transition must never fade both screens toward black")
        }
        await show(.booru)
        let original = try XCTUnwrap(controller.children.first)
        try await Task.sleep(for: .milliseconds(40))
        await show(.manga)
        let incoming = try XCTUnwrap(controller.children.first { $0 !== original })
        func assertSlide(to mode: AppMode) throws {
            assertOpaqueScreen()
            XCTAssertEqual(controller.children.first?.view.transform, .identity, "The live bars must stay fixed")
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let stage = try XCTUnwrap(descendant(controller.view, identifier: "mode.transition.body"))
            let outgoing = try XCTUnwrap(stage.subviews.first { $0.accessibilityIdentifier == "mode.transition.outgoing" })
            let incoming = try XCTUnwrap(stage.subviews.first { $0.accessibilityIdentifier == "mode.transition.incoming" })
            let oldFrame = try XCTUnwrap(outgoing.layer.presentation()).frame
            let newFrame = try XCTUnwrap(incoming.layer.presentation()).frame
            let bodyFrame = stage.convert(stage.bounds, to: controller.view)
            XCTAssertEqual(bodyFrame.maxY, controller.view.bounds.maxY, accuracy: 0.5, "Content behind and below the floating dock must also slide")
            let bars = visibleBars(controller.children[0].view)
            let dock = try XCTUnwrap(bars.first { $0 is UITabBar })
            XCTAssertFalse(dock.isDescendant(of: stage), "Keep the real dock outside the moving snapshots")
            XCTAssertEqual(bodyFrame.minY, controller.view.bounds.minY, accuracy: 0.5, "The background behind the top controls must also slide")
            XCTAssertTrue(bars.contains { $0 is UINavigationBar })
            for bar in bars {
                var barBranch = bar
                while let parent = barBranch.superview, !stage.isDescendant(of: parent) { barBranch = parent }
                let common = try XCTUnwrap(barBranch.superview)
                var bodyBranch = stage
                while bodyBranch.superview !== common, let parent = bodyBranch.superview { bodyBranch = parent }
                let barIndex = try XCTUnwrap(common.subviews.firstIndex(of: barBranch))
                let bodyIndex = try XCTUnwrap(common.subviews.firstIndex(of: bodyBranch))
                XCTAssertGreaterThan(barIndex, bodyIndex, "Real navigation/tab controls must stay above the moving background")
            }
            XCTAssertTrue(stage.clipsToBounds)
            XCTAssertEqual(outgoing.alpha, 1); XCTAssertEqual(incoming.alpha, 1)
            if mode == .manga {
                XCTAssertLessThan(newFrame.minX, 0, "Comics must enter from the left")
                XCTAssertGreaterThan(oldFrame.minX, 0)
                XCTAssertEqual(newFrame.maxX, oldFrame.minX, accuracy: 0.5, "Panels must share one edge with no blank gap")
            } else {
                XCTAssertGreaterThan(newFrame.minX, 0, "Images must enter from the right")
                XCTAssertLessThan(oldFrame.minX, 0)
                XCTAssertEqual(oldFrame.maxX, newFrame.minX, accuracy: 0.5)
            }
        }
        func waitForPanels() async throws {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            for _ in 0..<100 {
                let stage = descendant(controller.view, identifier: "mode.transition.body")
                if stage?.subviews.contains(where: { $0.accessibilityIdentifier == "mode.transition.incoming" }) == true {
                    try await Task.sleep(for: .milliseconds(25))
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("The mounted body must begin its slide after display preparation")
        }
        try await waitForPanels()
        try assertSlide(to: .manga)
        XCTAssertEqual(incoming.view.alpha, 1)
        await show(.booru)
        try await waitForPanels()
        try assertSlide(to: .booru)
        for _ in 0..<7 { try await Task.sleep(for: .milliseconds(40)); assertOpaqueScreen() }
        XCTAssertNil(descendant(controller.view, identifier: "mode.transition.body"))
        XCTAssertEqual(controller.children.count, 1)
        XCTAssertTrue(controller.children.first === original)
        XCTAssertTrue(original.view.isUserInteractionEnabled)
    }

    func testPreviewColumnsFollowTwiceTheResolvedArtworkColumnsOrAnExplicitChoice() {
        for width: CGFloat in [280, 390, 678, 1024, 1280] {
            for columns in 0...5 {
                let artwork = ArtworkGridGeometry(width: width, columns: columns, removesPadding: false)
                XCTAssertEqual(GalleryPreviewLayout.columns(width: width, artworkColumns: columns, previewColumns: 0,
                                                            removesArtworkPadding: false), artwork.count * 2)
                XCTAssertEqual(GalleryPreviewLayout.columns(width: width, artworkColumns: columns, previewColumns: 6,
                                                            removesArtworkPadding: false), 6)
            }
        }
    }

    func testDensePreviewUsesTheSameProportionalSpacingAndCornersAsArtwork() {
        let regular = ArtworkGridGeometry(width: 390, columns: 2, removesPadding: false)
        let preview = ArtworkGridGeometry(width: 390, columns: 6, removesPadding: false, maximumColumns: 10)
        XCTAssertEqual(preview.count, 6)
        XCTAssertGreaterThan(preview.spacing, 0); XCTAssertLessThan(preview.spacing, regular.spacing)
        XCTAssertGreaterThan(preview.margin, 0); XCTAssertLessThan(preview.margin, regular.margin)
        let style = ArtworkCellStyle(width: preview.cellWidth)
        XCTAssertEqual(preview.spacing, style.inset(14), accuracy: 0.001)
        XCTAssertEqual(preview.margin, style.inset(16), accuracy: 0.001)
        XCTAssertEqual(style.radius(12), preview.cellWidth / 160 * 12, accuracy: 0.001)
        let noPadding = ArtworkGridGeometry(width: 390, columns: 6, removesPadding: true, maximumColumns: 10)
        XCTAssertEqual(noPadding.spacing, 0); XCTAssertEqual(noPadding.margin, 0)
        XCTAssertEqual(ArtworkCellStyle(width: noPadding.cellWidth, removesPadding: true).radius(12), 0)
    }

    @MainActor func testPreviewColumnPreferenceDefaultsToAutomaticAndPersistsIndependently() throws {
        let suite = "preview-density-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try AppDatabase.inMemory(), store = try BooruStore()
        let env = AppEnvironment(database: database, browserPreferences: defaults, booru: store)
        XCTAssertEqual(env.mangaPreviewColumns, 0)
        XCTAssertEqual(env.mangaPreviewRows, 5)
        env.mode = .manga; env.gridColumns = 3; env.mangaPreviewColumns = 6; env.mangaPreviewRows = 7
        let restored = AppEnvironment(database: database, browserPreferences: defaults, booru: store)
        XCTAssertEqual(restored.mangaPreviewColumns, 6)
        XCTAssertEqual(restored.mangaPreviewRows, 7)
        XCTAssertEqual(restored.gridColumns(for: .manga), 3)
        restored.mangaPreviewColumns = 100; XCTAssertEqual(restored.mangaPreviewColumns, 10)
        restored.mangaPreviewColumns = -1; XCTAssertEqual(restored.mangaPreviewColumns, 0)
        restored.mangaPreviewRows = 100; XCTAssertEqual(restored.mangaPreviewRows, 10)
        restored.mangaPreviewRows = -1; XCTAssertEqual(restored.mangaPreviewRows, 1)
    }

    @MainActor func testModeSwitchCoalescesOverlappingUserInteractions() {
        let motion = AppModeSwitchMotion()
        let now = ContinuousClock().now
        XCTAssertTrue(motion.acceptInteraction(at: now))
        XCTAssertFalse(motion.acceptInteraction(at: now.advanced(by: .milliseconds(60))))
        XCTAssertFalse(motion.acceptInteraction(at: now.advanced(by: .milliseconds(180))))
        XCTAssertTrue(motion.acceptInteraction(at: now.advanced(by: .milliseconds(230))))
        XCTAssertFalse(motion.acceptInteraction(at: now.advanced(by: .milliseconds(280))))
    }

    @MainActor func testModeThumbHandoffKeepsOneContinuousMotionAndIgnoresStaleCompletion() throws {
        let motion = AppModeSwitchMotion(), start = ContinuousClock.now
        motion.prepare(for: .manga)
        motion.move(to: .booru, reducedMotion: false, at: start)
        let first = try XCTUnwrap(motion.transition)
        var previous: CGFloat = 0
        for milliseconds in stride(from: 0, through: 240, by: 20) {
            let now = start.advanced(by: .milliseconds(milliseconds))
            let outgoing = motion.position(for: .manga, at: now)
            let incoming = motion.position(for: .booru, at: now)
            XCTAssertEqual(outgoing, incoming, accuracy: 0.001, "Both toolbars must draw the same bubble during the fade")
            XCTAssertGreaterThanOrEqual(incoming, previous)
            XCTAssertTrue((0...44).contains(incoming))
            previous = incoming
        }
        let handoff = start.advanced(by: .milliseconds(80))
        motion.prepare(for: .booru)
        motion.move(to: .booru, reducedMotion: false, at: handoff)
        XCTAssertEqual(motion.transition?.id, first.id, "An incoming toolbar must not restart the animation")
        let reversal = start.advanced(by: .milliseconds(140))
        let position = motion.position(for: .booru, at: reversal)
        motion.move(to: .manga, reducedMotion: false, at: reversal)
        let second = try XCTUnwrap(motion.transition)
        XCTAssertEqual(motion.position(for: .manga, at: reversal), position, accuracy: 0.001)
        motion.finish(first.id)
        XCTAssertEqual(motion.transition?.id, second.id)
        XCTAssertEqual(motion.position(for: .manga, at: second.deadline), 0, accuracy: 0.001)
        motion.finish(second.id)
        XCTAssertEqual(motion.position(for: .manga), 0)
        motion.move(to: .booru, reducedMotion: true)
        XCTAssertNil(motion.transition)
        XCTAssertEqual(motion.position(for: .booru), 44)
    }

    @MainActor func testDensityPreferencesPersistIndependentlyAndDefaultToVisibleMetadata() throws {
        let suite = "density-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try AppDatabase.inMemory(), store = try BooruStore()
        let env = AppEnvironment(database: database, browserPreferences: defaults, booru: store)
        XCTAssertTrue(env.showsMangaTitles); XCTAssertTrue(env.showsMangaArtists)
        env.mode = .manga; XCTAssertFalse(env.removesGridPadding)
        env.removesGridPadding = true; env.showsMangaTitles = false; env.showsMangaArtists = false
        env.mode = .booru; XCTAssertFalse(env.removesGridPadding)
        env.gridColumns = 5
        let restored = AppEnvironment(database: database, browserPreferences: defaults, booru: store)
        XCTAssertFalse(restored.removesGridPadding(for: .booru)); XCTAssertTrue(restored.removesGridPadding(for: .manga))
        XCTAssertFalse(restored.showsMangaTitles); XCTAssertFalse(restored.showsMangaArtists)
        XCTAssertEqual(restored.gridColumns(for: .booru), 5)
    }

    @MainActor func testRealGridShrinksMarginsAndBecomesEdgeToEdgeInBothModes() async throws {
        let env = AppEnvironment.preview()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        var baselineMargin: CGFloat = 0
        for mode in [AppMode.manga, .booru] {
            for (columns, dense) in [(2, false), (5, false), (5, true)] {
                env.mode = mode; env.gridColumns = columns; env.removesGridPadding = dense
                var frames: [Int: CGRect] = [:]
                let host = UIHostingController(rootView: DensityGridProbe(mode: mode) { frames[$0] = $1 }.environment(env).frame(width: 390, height: 900))
                let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil }
                host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(120)); host.view.layoutIfNeeded()
                let first = try XCTUnwrap(frames[0]), next = try XCTUnwrap(frames[1])
                let row = frames.values.filter { abs($0.minY - first.minY) < 1 }
                XCTAssertEqual(row.count, columns)
                if columns == 2 { baselineMargin = first.minX }
                else if !dense {
                    XCTAssertGreaterThan(first.minX, 0); XCTAssertLessThan(first.minX, baselineMargin)
                    XCTAssertLessThan(next.minX - first.maxX, 14)
                } else {
                    XCTAssertEqual(first.minX, 0, accuracy: 0.6)
                    XCTAssertEqual(next.minX, first.maxX, accuracy: 0.6)
                    XCTAssertEqual(row.map(\.maxX).max()!, 390, accuracy: 0.6)
                }
            }
        }
    }

    @MainActor func testRenderedGalleryMetadataShrinksAndCanBeRemovedWithoutEmptySpace() {
        func size(_ width: CGFloat, titles: Bool = true, artists: Bool = true) -> CGSize {
            let style = ArtworkCellStyle(width: width, showsTitle: titles, showsArtists: artists)
            let view = GalleryCardLayout(title: "A sample title that wraps across two lines", artists: "Example artist", language: "") { Color.blue }.environment(\.artworkCellStyle, style)
            return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 2000))
        }
        let normal = size(170).height - 170 / 0.72
        let small = size(65).height - 65 / 0.72
        XCTAssertLessThan(small, normal)
        XCTAssertEqual(size(65, titles: false, artists: false).height, 65 / 0.72, accuracy: 0.6)
        XCTAssertGreaterThan(size(65, titles: false).height, 65 / 0.72)
        XCTAssertGreaterThan(size(65, artists: false).height, 65 / 0.72)
    }

    @MainActor func testLocalThumbnailsDecodeOnceOffTheRenderingPathAndRespectPixelLimit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 2400), format: format).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 2400))
        }
        try data.write(to: url)
        let cache = LocalThumbnailCache(maximumPixelSize: 160)
        // View evaluation must not synchronously read and decode even a valid file.
        XCTAssertNil(cache.image(forPath: url.path))
        let images = await withTaskGroup(of: UIImage?.self) { group in
            for _ in 0..<20 { group.addTask { await cache.load(forPath: url.path) } }
            var results: [UIImage] = []
            for await image in group { if let image { results.append(image) } }
            return results
        }
        let image = try XCTUnwrap(images.first)
        XCTAssertEqual(images.count, 20)
        XCTAssertTrue(images.allSatisfy { $0 === image }, "Concurrent cells share one decoded image")
        XCTAssertEqual(image.cgImage?.width, 80)
        XCTAssertEqual(image.cgImage?.height, 160)
        XCTAssertTrue(cache.image(forPath: url.path) === image)

        cache.invalidate(path: url.path)
        XCTAssertNil(cache.image(forPath: url.path))
        let refreshed = await cache.load(forPath: url.path)
        XCTAssertNotNil(refreshed)
        XCTAssertFalse(refreshed === image)
        cache.clear()
        XCTAssertNil(cache.image(forPath: url.path))
    }

    @MainActor func testVisibleThumbnailReloadsWhenTheSameFileIsReplaced() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url); LocalThumbnailCache.shared.invalidate(path: url.path) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func writeImage(width: CGFloat, height: CGFloat) throws {
            try UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
                UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }.write(to: url, options: .atomic)
        }
        try writeImage(width: 80, height: 160)
        let imageView = UIImageView()
        let view = LocalThumbnailView(path: url.path) { image in
            LocalThumbnailProbe(image: image, imageView: imageView)
        }
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        // Observe what the hosted view actually displays. Fulfilling an
        // expectation inside onChange and immediately invalidating the file
        // can trigger SwiftUI's per-frame onChange limit in this test harness.
        func waitForDisplayedWidth(_ width: CGFloat) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while imageView.image?.size.width != width && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(imageView.image?.size.width, width)
        }
        try await waitForDisplayedWidth(80)
        try writeImage(width: 160, height: 80)
        LocalThumbnailCache.shared.invalidate(path: url.path)
        try await waitForDisplayedWidth(160)
        XCTAssertTrue(imageView.image === LocalThumbnailCache.shared.image(forPath: url.path))
    }

    func testLocalThumbnailFailuresDoNotPoisonLaterLoads() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let cache = LocalThumbnailCache()
        let missing = await cache.load(forPath: url.path)
        XCTAssertNil(missing)
        let invalid = Data("not an image".utf8)
        try invalid.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = await cache.load(forPath: url.path)
        XCTAssertNil(corrupt)
    }

    @MainActor func testCancelingLastThumbnailConsumerSkipsQueuedDecodeAndRemainsRetryable() async throws {
        let url = try makeThumbnailFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = OperationQueue(); queue.isSuspended = true
        defer { queue.isSuspended = false }
        let cache = LocalThumbnailCache(decodeQueue: queue)
        let cancelled = expectation(description: "Cancelled cell returns before decoder runs")
        let caller = Task {
            let image = await cache.load(forPath: url.path)
            XCTAssertNil(image)
            cancelled.fulfill()
        }
        await waitForThumbnailConsumers(1, cache: cache, path: url.path)
        caller.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(cache.pendingConsumerCount(forPath: url.path), 0)
        XCTAssertTrue(queue.operations.allSatisfy(\.isCancelled), "Offscreen queued files must not be decoded")
        XCTAssertNil(cache.image(forPath: url.path))

        queue.isSuspended = false
        let returningCellImage = await cache.load(forPath: url.path)
        XCTAssertNotNil(returningCellImage, "A cancelled request must not poison the same path")
    }

    @MainActor func testCancelingOneThumbnailConsumerKeepsSharedDecodeAlive() async throws {
        let url = try makeThumbnailFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = OperationQueue(); queue.isSuspended = true
        defer { queue.isSuspended = false }
        let cache = LocalThumbnailCache(decodeQueue: queue)
        let cancelled = expectation(description: "First consumer cancels independently")
        let first = Task {
            let image = await cache.load(forPath: url.path)
            XCTAssertNil(image)
            cancelled.fulfill()
        }
        let visible = Task { await cache.load(forPath: url.path) }
        await waitForThumbnailConsumers(2, cache: cache, path: url.path)
        XCTAssertEqual(queue.operationCount, 1, "Both cells must share one queued decode")
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(cache.pendingConsumerCount(forPath: url.path), 1)
        XCTAssertFalse(try XCTUnwrap(queue.operations.first).isCancelled)

        queue.isSuspended = false
        let image = await visible.value
        XCTAssertNotNil(image)
        XCTAssertTrue(image === cache.image(forPath: url.path))
    }

    @MainActor private func makeThumbnailFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80), format: format).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        }
        try data.write(to: url)
        return url
    }

    private func waitForThumbnailConsumers(_ count: Int, cache: LocalThumbnailCache, path: String) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while cache.pendingConsumerCount(forPath: path) != count && ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(cache.pendingConsumerCount(forPath: path), count)
    }

    func testObservedLibrarySnapshotsIncludeThumbnailAndFolderEdits() async throws {
        let database = try AppDatabase.inMemory()
        let folder = try database.createFolder(name: "Snapshot test")
        let folderID = try XCTUnwrap(folder.id)
        _ = try database.upsertWork(galleryId: 42, folderId: folderID, title: "Original")
        let observation = ValueObservation.tracking { db in
            try (AppDatabase.fetchWorks(db, folderId: folderID), AppDatabase.fetchFolders(db), AppDatabase.fetchFolderPreviews(db))
        }
        var values = observation.values(in: database.dbWriter).makeAsyncIterator()
        let initial = try await values.next()
        XCTAssertEqual(initial?.0.first?.galleryId, 42)
        XCTAssertEqual(initial?.2[folderID]?.first?.galleryId, 42)

        try database.setThumb(galleryId: 42, status: "gone")
        let thumbnail = try await values.next()
        XCTAssertEqual(thumbnail?.0.first?.thumbStatus, "gone")
        XCTAssertEqual(thumbnail?.2[folderID]?.first?.thumbStatus, "gone")

        try database.setFolderColor(id: folderID, color: 0xFF123456)
        let recolored = try await values.next()
        XCTAssertEqual(recolored?.0.first?.folders.first?.color, 0xFF123456)
        XCTAssertEqual(recolored?.1.first { $0.id == folderID }?.color, 0xFF123456)

        try database.deleteWork(galleryId: 42)
        let removed = try await values.next()
        XCTAssertTrue(removed?.0.isEmpty == true)
        XCTAssertEqual(removed?.1.first { $0.id == folderID }?.workCount, 0)
        XCTAssertNil(removed?.2[folderID])
    }

    func testLargeLibrariesLoadFolderMembershipWithoutPerWorkSQLParameters() throws {
        let database = try AppDatabase.inMemory()
        let folderID = try XCTUnwrap(try database.listFolders().first?.id)
        let count = 32_770
        try database.dbWriter.write { db in
            try db.execute(sql: """
                WITH RECURSIVE ids(value) AS (
                    SELECT 1 UNION ALL SELECT value + 1 FROM ids WHERE value < ?
                )
                INSERT INTO works (gallery_id, title, bookmarked_at)
                SELECT value, 'Work ' || value, '2026-10-18' FROM ids
                """, arguments: [count])
            try db.execute(sql: "INSERT INTO folder_works (folder_id, work_id, added_at) SELECT ?, id, bookmarked_at FROM works", arguments: [folderID])
        }
        let works = try database.listWorks(folderId: folderID)
        XCTAssertEqual(works.count, count)
        XCTAssertTrue(works.allSatisfy { $0.folders.first?.id == folderID })
        XCTAssertEqual(try database.listWorks(query: "Work 32770").map(\.galleryId), [32770])
    }

    @MainActor func testAutomaticAndManualColumnsFollowContainerWidth() async throws {
        // Render the real shared grid at phone, split-window, and full iPad/Mac widths.
        for (width, setting, minimum, expected) in [(390.0, 0, 160.0, 2), (768, 0, 160, 4), (1024, 0, 160, 5), (1366, 0, 160, 7), (390, 3, 160, 3), (1024, 2, 160, 2), (768, 0, 240, 2), (1024, 0, 240, 3), (1366, 0, 240, 5)] {
            var frames: [Int: CGRect] = [:]
            let view = GridProbe(columns: setting, minimum: minimum) { frames = $0 }.frame(width: width, height: 900)
            let host = UIHostingController(rootView: view)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let first = try XCTUnwrap(frames[0], "width \(width)")
            let row = frames.values.filter { abs($0.minY - first.minY) < 1 }
            XCTAssertEqual(row.count, expected, "width \(width), setting \(setting)")
            XCTAssertTrue(frames.values.allSatisfy { $0.minX >= 15 && $0.maxX <= width - 15 })
        }
    }

    @MainActor func testFolderPreviewHeightGrowsWithWidth() throws {
        let folder = try XCTUnwrap(try AppDatabase.inMemory().listFolders().first)
        let host = UIHostingController(rootView: FolderBentoCardView(folder: folder))
        let small = host.sizeThatFits(in: CGSize(width: 180, height: 2000))
        let large = host.sizeThatFits(in: CGSize(width: 360, height: 2000))
        XCTAssertEqual(large.height - small.height, (360 - 180) / 1.25, accuracy: 2)
    }

    @MainActor func testAutomaticPersistsAndModesKeepIndependentChoices() throws {
        let suite = "grid-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try AppDatabase.inMemory()
        let store = try BooruStore()
        let env = AppEnvironment(database: database, browserPreferences: defaults, booru: store)
        XCTAssertEqual(env.gridColumns, 0)
        env.mode = .manga; env.gridColumns = 2; env.folderColumns = 1
        env.mode = .booru; env.gridColumns = 3; env.folderColumns = 4
        env.mode = .manga; XCTAssertEqual(env.gridColumns, 2)
        env.gridColumns = 0
        let reopened = AppEnvironment(database: database, browserPreferences: defaults, booru: store)
        XCTAssertEqual(reopened.gridColumns, 0)
        XCTAssertEqual(reopened.folderColumns, 1)
        reopened.mode = .booru; XCTAssertEqual(reopened.gridColumns, 3)
        XCTAssertEqual(reopened.folderColumns, 4)
    }
}

private struct LocalThumbnailProbe: UIViewRepresentable {
    let image: UIImage?
    let imageView: UIImageView
    func makeUIView(context: Context) -> UIImageView { imageView }
    func updateUIView(_ uiView: UIImageView, context: Context) { uiView.image = image }
}

private struct GridFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct GridProbe: View {
    let columns: Int
    let minimum: CGFloat
    let report: ([Int: CGRect]) -> Void
    var body: some View {
        ScrollView {
            LazyVGrid(columns: WorkGridLayout.columns(columns, minimum: minimum), spacing: 14) {
                ForEach(0..<14) { index in
                    Color.blue.frame(height: 80).background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: GridFrames.self, value: [index: geometry.frame(in: .named("grid"))])
                        }
                    }
                }
            }.padding(16)
        }.coordinateSpace(name: "grid").onPreferenceChange(GridFrames.self, perform: report)
    }
}

private struct DensityGridProbe: View {
    let mode: AppMode
    let report: (Int, CGRect) -> Void
    var body: some View {
        ScrollView {
            ArtworkGrid(mode: mode) { _ in
                ForEach(0..<10) { index in
                    Color.blue.frame(height: 80)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("density")) } action: { report(index, $0) }
                }
            }
        }.coordinateSpace(name: "density")
    }
}
