import SwiftUI
import UIKit

/// A work waiting to be read, kept with what the list shows so the list never has to load it.
struct ReadingQueueItem: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    var title: String
    var artists: String
    var details: String
    /// The comics site the work was found on, so it opens there.
    var site: String?

    init(id: Int64, title: String, artists: String, details: String, site: String?) {
        self.id = id; self.title = title; self.artists = artists; self.details = details; self.site = site
    }
    init(gallery: NativeGallery?, id: Int64, title: String?, artists: String?, language: String?, type: String?, site: String?) {
        self.init(id: id,
                  title: gallery?.title ?? title ?? "",
                  artists: gallery.map { $0.artists.joined(separator: ", ") } ?? artists ?? "",
                  details: [gallery?.language ?? language, gallery?.type ?? type].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                  site: site)
    }
    init(work: Work) {
        self.init(gallery: nil, id: work.galleryId, title: work.hasTitle ? work.title : nil, artists: work.artists, language: work.language, type: work.type, site: work.site)
    }
    var displayTitle: String { title.isEmpty ? L10n.text("Work %@", String(describing: id)) : title }
}

/// Up Next for comics, like a music queue: works held and carried down, or added from a menu,
/// wait here in order. A work leaves once it is read to its last page or removed.
@MainActor @Observable final class ReadingQueue {
    static let key = "manga.readingQueue"
    private(set) var items: [ReadingQueueItem] = []
    /// Changes with every work that joins, for the bar's arrival bounce.
    private(set) var arrivals = 0
    /// The work being carried to the drop panel, and where the finger is.
    private(set) var carried: ReadingQueueItem?
    private(set) var carryLocation: CGPoint = .zero
    private(set) var isOverDropZone = false
    @ObservationIgnored private(set) var carriedCover: UIImage?
    /// The drop panel's frame on screen, measured while it shows.
    @ObservationIgnored var dropZone: CGRect = .null
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let covers: URL

    init(defaults: UserDefaults, covers: URL? = nil) {
        self.defaults = defaults
        self.covers = covers ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ReadingQueue", isDirectory: true)
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode([ReadingQueueItem].self, from: data) { items = stored }
    }

    func contains(_ id: Int64) -> Bool { items.contains { $0.id == id } }

    /// Adds the work at the end. A work already waiting keeps its place.
    @discardableResult func add(_ item: ReadingQueueItem, cover: UIImage?) -> Bool {
        guard !contains(item.id) else { return false }
        items.append(item)
        if let cover { store(cover, for: item.id) }
        arrivals += 1
        save()
        return true
    }
    func remove(_ id: Int64) {
        guard contains(id) else { return }
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: coverURL(id))
        save()
    }
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }
    func clear() {
        items.removeAll()
        try? FileManager.default.removeItem(at: covers)
        save()
    }
    /// A work read to its last page has been read.
    func finished(_ id: Int64) { remove(id) }

    /// The works from the given one to the end, in the order the reader pages through them.
    func sequence(from id: Int64) -> [Int64] {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return [id] }
        return items[index...].map(\.id)
    }

    // MARK: Carrying

    func beginCarry(_ item: ReadingQueueItem, cover: UIImage?, at location: CGPoint, isHeld: @escaping () -> Bool = { true }) {
        carried = item; carriedCover = cover
        moveCarry(to: location)
        watchCarry(isHeld)
    }
    /// A safety net: if the finger's gesture ends without saying so (its view removed, its touch
    /// taken by the system), the carried card and panel still go away.
    private func watchCarry(_ isHeld: @escaping () -> Bool) {
        carryWatch?.cancel()
        carryWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.carried != nil else { return }
                if !isHeld() { withAnimation(.easeOut(duration: 0.2)) { _ = self.endCarry() }; return }
            }
        }
    }
    @ObservationIgnored private var carryWatch: Task<Void, Never>?
    func moveCarry(to location: CGPoint) {
        guard carried != nil else { return }
        carryLocation = location
        let over = dropZone.contains(location)
        if over != isOverDropZone { isOverDropZone = over }
    }
    /// Lets go of the carried work: it joins the list when let go over the drop panel.
    @discardableResult func endCarry() -> Bool {
        defer { carried = nil; carriedCover = nil; isOverDropZone = false; carryWatch?.cancel(); carryWatch = nil }
        guard let carried, isOverDropZone else { return false }
        return add(carried, cover: carriedCover)
    }

    // MARK: Covers

    func cover(_ id: Int64) -> UIImage? { UIImage(contentsOfFile: coverURL(id).path) }
    private func coverURL(_ id: Int64) -> URL { covers.appendingPathComponent("\(id).jpg") }
    private func store(_ image: UIImage, for id: Int64) {
        // Small enough for a list row, sharp enough for the bar.
        let scale = min(1, 240 / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = small.jpegData(compressionQuality: 0.8) else { return }
        try? FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        try? data.write(to: coverURL(id), options: .atomic)
    }
    private func save() {
        if items.isEmpty { defaults.removeObject(forKey: Self.key) }
        else if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.key) }
    }
}

extension View {
    /// Holding a work bookmarks it, while the finger is still down; moving the finger soon after
    /// the hold carries it down to the Up Next panel instead.
    func workHold(_ queue: ReadingQueue, item: @escaping () -> ReadingQueueItem, cover: @escaping () -> UIImage?,
                  bookmark: @escaping () -> Void) -> some View {
        modifier(WorkHoldModifier(queue: queue, item: item, cover: cover, bookmark: bookmark))
    }
    /// Holding a work saves it, with the same press and timing as comics, where nothing is carried.
    func holdToSave(_ save: @escaping () -> Void) -> some View {
        modifier(WorkHoldModifier(queue: nil, item: nil, cover: { nil }, bookmark: save))
    }
}

private struct WorkHoldModifier: ViewModifier {
    let queue: ReadingQueue?
    let item: (() -> ReadingQueueItem)?
    let cover: () -> UIImage?
    let bookmark: () -> Void
    @State private var pressed = false

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .scaleEffect(pressed ? 0.95 : 1)
                .opacity(queue?.carried != nil && pressed ? 0.45 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: pressed)
                .gesture(WorkHoldGesture(
                    carries: queue != nil && item != nil,
                    pressed: { pressed = true; UIImpactFeedbackGenerator(style: .light).impactOccurred() },
                    bookmark: {
                        // A work that can be carried springs back as it is bookmarked; one that is
                        // only saved stays pressed until the finger lifts, so the press shows.
                        if queue != nil && item != nil { pressed = false }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        bookmark()
                    },
                    lifted: { pressed = false },
                    carry: { location, isHeld in
                        guard let queue, let item else { return }
                        if queue.carried == nil { queue.beginCarry(item(), cover: cover(), at: location, isHeld: isHeld) } else { queue.moveCarry(to: location) }
                    },
                    release: {
                        pressed = false
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                            if queue?.endCarry() == true { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                        }
                    },
                    cancel: {
                        pressed = false
                        withAnimation(.easeOut(duration: 0.2)) { _ = queue?.endCarry() }
                    }))
                // A cell scrolled away or rebuilt mid-gesture never reports the gesture's end.
                .onDisappear {
                    guard pressed else { return }
                    pressed = false
                    _ = queue?.endCarry()
                }
        } else {
            content.onLongPressGesture(minimumDuration: 0.55, perform: bookmark)
        }
    }
}

/// A long press that keeps following the finger. A short hold is a bookmark, made while the
/// finger is still down; moving soon after the hold carries the work instead. While it is held
/// the list under it does not scroll, so a carried work stays where the finger takes it.
@available(iOS 18.0, *)
private struct WorkHoldGesture: UIGestureRecognizerRepresentable {
    /// Whether moving after the hold carries the work; without it a hold saves at once.
    let carries: Bool
    let pressed: () -> Void
    let bookmark: () -> Void
    let lifted: () -> Void
    let carry: (CGPoint, _ isHeld: @escaping () -> Bool) -> Void
    let release: () -> Void
    let cancel: () -> Void
    /// How long a still finger is held before the hold is noticed.
    static let holdDuration: TimeInterval = 0.45
    /// How long after the hold a move still means "carry" rather than "bookmark".
    static let decisionWindow: TimeInterval = 0.6
    /// How far the finger moves before a held work is being carried.
    static let carryDistance: CGFloat = 8

    enum Phase { case deciding, bookmarked, carrying }
    final class Coordinator {
        var start: CGPoint = .zero
        var phase = Phase.deciding
        var decision: DispatchWorkItem?
        weak var scrollPan: UIPanGestureRecognizer?
    }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = Self.holdDuration
        recognizer.allowableMovement = 10
        return recognizer
    }
    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let location = context.converter.location(in: .global)
        let state = context.coordinator
        switch recognizer.state {
        case .began:
            state.start = location; state.phase = .deciding
            var view = recognizer.view
            while let current = view, !(current is UIScrollView) { view = current.superview }
            if let pan = (view as? UIScrollView)?.panGestureRecognizer, pan.isEnabled {
                pan.isEnabled = false
                state.scrollPan = pan
            }
            pressed()
            guard carries else {
                state.phase = .bookmarked
                bookmark()
                return
            }
            let decision = DispatchWorkItem { [weak state] in
                guard let state, state.phase == .deciding else { return }
                state.phase = .bookmarked
                bookmark()
            }
            state.decision = decision
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.decisionWindow, execute: decision)
        case .changed:
            if state.phase == .deciding, hypot(location.x - state.start.x, location.y - state.start.y) > Self.carryDistance {
                state.decision?.cancel()
                state.phase = .carrying
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            if state.phase == .carrying {
                carry(location) { [weak recognizer] in
                    guard let recognizer else { return false }
                    return recognizer.state == .began || recognizer.state == .changed
                }
            }
        case .ended:
            finish(state)
            switch state.phase {
            // Let go before the window closed, the hold was still a bookmark.
            case .deciding: bookmark()
            case .carrying: release()
            case .bookmarked: break
            }
        case .cancelled, .failed:
            finish(state)
            if state.phase == .carrying { cancel() }
        default: break
        }
    }
    private func finish(_ state: Coordinator) {
        lifted()
        state.decision?.cancel(); state.decision = nil
        state.scrollPan?.isEnabled = true
        state.scrollPan = nil
    }
}

/// The large panel a carried work is let go on, with the card following the finger above it.
struct ReadingQueueCarryOverlay: View {
    let queue: ReadingQueue
    /// The last carried work, kept so the card can fade where it was let go.
    @State private var shown: ReadingQueueItem?
    @State private var shownCover: UIImage?
    var body: some View {
        // Both stay in place and only fade and scale: a removal transition interrupted mid-way
        // could leave them frozen on screen.
        let active = queue.carried != nil
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .bottom) {
                if shown != nil {
                    ReadingQueueDropPanel(over: queue.isOverDropZone, count: queue.items.count)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { queue.dropZone = $0 }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 64)
                        .opacity(active ? 1 : 0)
                        .offset(y: active ? 0 : 40)
                }
                if let item = queue.carried ?? shown {
                    GalleryContextPreview(item: item, tags: [], image: queue.carried == nil ? shownCover : queue.carriedCover, width: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.12)))
                        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
                        .scaleEffect(active ? (queue.isOverDropZone ? 0.82 : 1) : 0.3)
                        .opacity(active ? 1 : 0)
                        // Centred on the finger, even where that reaches past the screen's edge.
                        .position(x: queue.carryLocation.x - origin.x, y: queue.carryLocation.y - origin.y)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: queue.isOverDropZone)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: active)
        .onChange(of: queue.carried?.id, initial: true) { _, _ in
            if let carried = queue.carried { shown = carried; shownCover = queue.carriedCover }
        }
        .onChange(of: queue.isOverDropZone) { _, over in if over { UISelectionFeedbackGenerator().selectionChanged() } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ReadingQueueDropPanel: View {
    let over: Bool
    let count: Int
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: over ? "plus.circle.fill" : "text.line.last.and.arrowtriangle.forward")
                .font(.system(size: 28, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(L10n.text(over ? "Release to Add to Up Next" : "Drag Here to Read Later"))
                .font(.subheadline.weight(.semibold)).multilineTextAlignment(.center).padding(.horizontal, 12)
            if count > 0 {
                Text(L10n.text("Up Next · %@", String(count))).font(.caption).foregroundStyle(over ? Color.accentColor.opacity(0.8) : .secondary)
            }
        }
        .foregroundStyle(over ? Color.accentColor : .primary)
        .frame(maxWidth: .infinity)
        .frame(height: 133)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.regularMaterial)
                if over { RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.accentColor.opacity(0.16)) }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(over ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: over ? [] : [8, 6]))
        }
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
        .scaleEffect(over ? 1.04 : 1)
        .accessibilityHidden(true)
    }
}

/// The Up Next bar's glass: clear Liquid Glass in a capsule, the same over the tabs and in the
/// reader, which the viewers' quick menu shares.
struct ReadingQueueBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}

/// How much room the Up Next bar takes at the bottom of the comics tabs.
private struct ReadingQueueInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var readingQueueInset: CGFloat {
        get { self[ReadingQueueInsetKey.self] }
        set { self[ReadingQueueInsetKey.self] = newValue }
    }
}
extension View {
    /// Keeps a tab's screen clear of the Up Next bar: its lists end above the bar and the notices
    /// shown over it rise above the bar. Applied inside each navigation stack, since room added
    /// outside one does not reach the screens it shows.
    func readingQueueClearance() -> some View { modifier(ReadingQueueClearance()) }
}
private struct ReadingQueueClearance: ViewModifier {
    @Environment(\.readingQueueInset) private var inset
    func body(content: Content) -> some View {
        content.safeAreaPadding(.bottom, inset)
            .animation(.snappy, value: inset)
    }
}

/// The horizontal card a carried work shows, as Saved shows a held work.
struct GalleryContextPreview: View {
    let item: ReadingQueueItem
    let tags: [String]
    let image: UIImage?
    var width: CGFloat = 340
    private var visibleTags: [String] {
        ArtworkTagGroup.make(tags: tags).flatMap(\.tags).filter { $0.category != .language && $0.category != .artist }.prefix(6).map(\.name)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(Color.secondary.opacity(0.12)).overlay { Image(systemName: AppMode.manga.icon).foregroundStyle(.secondary) } }
            }.frame(width: 104, height: 148).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayTitle).font(.headline).lineLimit(3)
                if !item.artists.isEmpty { Text(item.artists).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                if !item.details.isEmpty { Text(item.details).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                if !visibleTags.isEmpty { Text(visibleTags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).frame(width: width, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
}

/// The bar above the tabs, like a music app's mini player: the next work to read and a button
/// that starts reading.
struct ReadingQueueBar: View {
    @Environment(AppEnvironment.self) private var env
    let read: (Int64) -> Void
    let showList: () -> Void
    var compact = false
    /// The work to show instead of the list's first, as the reader shows the one after the work open.
    var next: ReadingQueueItem? = nil
    @State private var bounce = 0

    private var queue: ReadingQueue { env.readingQueue }

    var body: some View {
        Group { if let next = next ?? queue.items.first { player(next) } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onChange(of: queue.arrivals) { bounce += 1 }
            .accessibilityIdentifier("readingQueue.bar")
    }

    private func player(_ next: ReadingQueueItem) -> some View {
        HStack(spacing: 10) {
            Button(action: showList) {
                HStack(spacing: 10) {
                    ReadingQueueCover(id: next.id, width: compact ? 26 : 50, height: compact ? 26 : 50, cornerRadius: compact ? 7 : 13)
                        .phaseAnimator([1.0, 1.18, 1.0], trigger: bounce) { cover, scale in cover.scaleEffect(scale) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(next.displayTitle).font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold)).lineLimit(1)
                        if !compact {
                            Text(L10n.text("Up Next · %@", String(queue.items.count))).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                .contentTransition(.numericText())
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Up Next"))
            .accessibilityValue(L10n.text("%@ works", String(queue.items.count)))
            .accessibilityIdentifier("readingQueue.list")
            Button { read(next.id) } label: {
                Image(systemName: "book.fill").font(.system(size: compact ? 17 : 22, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Read Next"))
            .accessibilityIdentifier("readingQueue.read")
        }
        .padding(.leading, compact ? 8 : 14).padding(.trailing, 10)
    }
}

struct ReadingQueueCover: View {
    @Environment(AppEnvironment.self) private var env
    let id: Int64
    let width: CGFloat
    let height: CGFloat
    var cornerRadius: CGFloat? = nil
    var body: some View {
        Group {
            if let image = env.readingQueue.cover(id) {
                // Covers are tall; a shorter frame keeps their top, where titles and faces are.
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: width, height: height, alignment: .top)
            } else { Rectangle().fill(Color.secondary.opacity(0.15)).overlay { Image(systemName: AppMode.manga.icon).font(.caption).foregroundStyle(.secondary) } }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? max(4, width / 7), style: .continuous))
    }
}

/// The whole list: reorder, swipe away, or tap a work to read from there on.
struct ReadingQueueView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let read: (Int64) -> Void
    @State private var confirmingClear = false
    private var queue: ReadingQueue { env.readingQueue }

    var body: some View {
        NavigationStack {
            Group {
                if queue.items.isEmpty {
                    ContentUnavailableView(L10n.text("Nothing Up Next"), systemImage: "text.line.last.and.arrowtriangle.forward",
                                           description: Text(L10n.text("Hold a work in Explore and drag it down to the panel that appears.")))
                } else {
                    List {
                        Section {
                            ForEach(queue.items) { item in
                                Button { read(item.id) } label: { row(item) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("readingQueue.item.\(item.id)")
                            }
                            .onMove { queue.move(fromOffsets: $0, toOffset: $1) }
                            .onDelete { offsets in offsets.map { queue.items[$0].id }.forEach(queue.remove) }
                        } footer: {
                            Text(L10n.text("A work leaves the list once you read it to the last page."))
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(L10n.text("Up Next"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L10n.text("Done")) { dismiss() } }
                if !queue.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.text("Delete All"), role: .destructive) { confirmingClear = true }
                            .tint(.red)
                            .accessibilityIdentifier("readingQueue.deleteAll")
                    }
                }
            }
            .confirmationDialog(L10n.text("Delete All"), isPresented: $confirmingClear, titleVisibility: .hidden) {
                Button(L10n.text("Delete All"), role: .destructive) { queue.clear() }
            }
        }
    }

    private func row(_ item: ReadingQueueItem) -> some View {
        HStack(spacing: 12) {
            ReadingQueueCover(id: item.id, width: 46, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).font(.body.weight(.medium)).lineLimit(2)
                let byline = [item.artists, item.details].filter { !$0.isEmpty }.joined(separator: " · ")
                if !byline.isEmpty { Text(byline).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
