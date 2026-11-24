import SwiftUI
import UIKit

// MARK: - Style

/// The shop's goods each have a colour (`LabShopItem.color`, else their kind's) and a symbol, from which their art is drawn.
enum LabShopStyle {
    static let kindColors = ["course": "6B4EFF", "feature": "0A84FF", "addon": "2F9E62", "home": "E8743B", "ticket": "C9971C"]

    static func hex(_ item: LabShopItem) -> String { item.color ?? kindColors[item.kind] ?? "636366" }
    static func color(_ item: LabShopItem) -> Color { Color(labHex: hex(item)) }

    /// The colour moved toward white (`amount` > 0) or black (< 0).
    static func shade(_ hex: String, _ amount: Double) -> Color {
        let value = UInt32(hex, radix: 16) ?? 0x636366
        let target: Double = amount > 0 ? 1 : 0, t = abs(amount)
        func channel(_ shift: UInt32) -> Double { let c = Double((value >> shift) & 0xFF) / 255; return c + (target - c) * t }
        return Color(red: channel(16), green: channel(8), blue: channel(0))
    }

    /// The item's symbol, or a bag for a name this system does not draw.
    static func symbol(_ item: LabShopItem) -> String {
        guard let name = item.symbol, UIImage(systemName: name) != nil else { return "bag.fill" }
        return name
    }

    static func kind(_ item: LabShopItem) -> String {
        LabShopItem.kinds.contains(item.kind) ? L10n.text("lab.shop.kind." + item.kind) : ""
    }
}

/// An item's art: its picture filling the frame when it has one (`LabShopItem.image`), else its colour as a deep gradient
/// under a soft light with its symbol large and glowing and a faint echo of it. Only the frame given sets its size: the
/// symbols are overlays, so a tall symbol never makes one card's art taller than another's.
struct LabShopArt: View {
    let item: LabShopItem
    var symbolSize: CGFloat = 40
    /// Hidden while something stands in its place, such as the seal of a purchase.
    var symbolShown = true
    @State private var images = LabShopImages.shared

    var body: some View {
        let hex = LabShopStyle.hex(item), symbol = LabShopStyle.symbol(item)
        let picture = item.image.flatMap(images.image)
        Rectangle()
            .fill(LinearGradient(colors: [LabShopStyle.shade(hex, 0.22), LabShopStyle.shade(hex, 0), LabShopStyle.shade(hex, -0.45)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if let picture {
                    Image(uiImage: picture).resizable().scaledToFill().transition(.opacity)
                } else {
                    ZStack {
                        RadialGradient(colors: [.white.opacity(0.32), .white.opacity(0)], center: UnitPoint(x: 0.15, y: 0.05), startRadius: 0, endRadius: symbolSize * 5)
                        Image(systemName: symbol).font(.system(size: symbolSize * 2.6, weight: .bold)).foregroundStyle(.white.opacity(0.09))
                            .rotationEffect(.degrees(-14)).offset(x: symbolSize * 1.35, y: symbolSize * 0.55)
                        Image(systemName: symbol).font(.system(size: symbolSize, weight: .semibold)).foregroundStyle(.white)
                            .shadow(color: .white.opacity(0.45), radius: symbolSize * 0.25)
                            .shadow(color: LabShopStyle.shade(hex, -0.6).opacity(0.6), radius: symbolSize * 0.4, y: symbolSize * 0.12)
                            .scaleEffect(symbolShown ? 1 : 0.6).opacity(symbolShown ? 1 : 0)
                    }
                }
            }
            .animation(.easeOut(duration: 0.25), value: picture != nil)
            .clipped()
            .task(id: item.image?.sha256) { if let image = item.image { await images.load(image) } }
            .accessibilityHidden(true)
    }
}

/// Pictures of shop items: downloaded once from TEGNAL's server, refused unless they match the list's size and SHA-256, and
/// kept in Caches by digest.
@MainActor @Observable
final class LabShopImages {
    static let shared = LabShopImages()
    private var pictures: [String: UIImage] = [:]
    @ObservationIgnored private var loading = Set<String>()
    @ObservationIgnored var market = AddonMarket.live
    private var folder: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "ShopImages", directoryHint: .isDirectory) }

    func image(_ file: LabShopFile) -> UIImage? { pictures[file.sha256] }

    func load(_ file: LabShopFile) async {
        guard pictures[file.sha256] == nil, !loading.contains(file.sha256), file.valid else { return }
        loading.insert(file.sha256)
        defer { loading.remove(file.sha256) }
        let kept = folder.appending(path: file.sha256)
        if let data = try? Data(contentsOf: kept), LabCourseFile.digest(data) == file.sha256, let picture = UIImage(data: data) {
            pictures[file.sha256] = picture
            return
        }
        guard let data = try? await fetch(file), data.count == file.size, LabCourseFile.digest(data) == file.sha256,
              let picture = UIImage(data: data) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: kept, options: .atomic)
        pictures[file.sha256] = picture
    }

    private func fetch(_ file: LabShopFile) async throws -> Data {
        #if DEBUG
        // `--lab-goods=<folder>` reads goods from a local folder laid out as the server is, for tests and screenshots.
        if let folder = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--lab-goods=") })?.dropFirst(12) {
            return try Data(contentsOf: URL(fileURLWithPath: String(folder)).appending(path: file.path))
        }
        #endif
        return try await market.fetch(market.base.appending(path: file.path), file.size)
    }
}

/// A price with the gem before it.
struct LabPriceTag: View {
    let price: Int
    var size: CGFloat = 15
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "diamond.fill").font(.system(size: size * 0.72, weight: .bold)).foregroundStyle(LabPalette.gauge)
            Text(String(price)).font(LabFont.number(size)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The shop

/// The shop: what 보석 buys.
struct LabShopView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LabHeader(kicker: Text(L10n.text("lab.shop.subtitle")), title: L10n.text("lab.tab.shop"))
                LabShopContent()
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// What the shop holds: the wallet, then each section's cards. Its own page in the lab; the foot of the
/// 연습 tab in the 2D AI course. The list comes from TEGNAL's server each time the shop is shown (`LabShopSource`); until it
/// does, the goods the app carries are for sale (`LabShop.builtIn`). A card opens the item's page, where it is bought.
struct LabShopContent: View {
    @State private var store = LabStore.shared
    @State private var goods = LabGoods.shared
    @State private var opened: ShopItemID?
    @State private var appeared = false
    @State private var sheen = 0.0
    @SwiftUI.AppStorage(HomeScenes.chosenKey) private var chosenScene = ""
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            wallet
            status
            ForEach(store.shop.sections) { section in
                VStack(alignment: .leading, spacing: 12) {
                    Text(section.title.text).font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
                    // A grid of two, each row as tall as its taller card: a title on two lines makes room in its row rather
                    // than every card keeping an empty second line.
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        ForEach(Array(stride(from: 0, to: section.items.count, by: 2)), id: \.self) { start in
                            GridRow {
                                ForEach(start..<min(start + 2, section.items.count), id: \.self) { index in
                                    card(section.items[index])
                                        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 16)
                                        .animation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.2).delay(0.05 * Double(index)), value: appeared)
                                }
                                if start + 1 == section.items.count { Color.clear.gridCellUnsizedAxes(.vertical) }
                            }
                        }
                    }
                }
            }
        }
        .animation(.snappy, value: store.balance)
        .task {
            appeared = true
            if !reduceMotion { withAnimation(.easeInOut(duration: 1.1).delay(0.3)) { sheen = 1 } }
            await store.refreshShop()
        }
        .appSheet(item: $opened) { LabShopItemSheet(itemID: $0.id) }
    }

    // MARK: Wallet

    /// The balance as the shop's front: a dark vault lit by its gem, with the next thing within reach.
    private var wallet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(labHex: "FFD36B"), Color(labHex: "E08A00")], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "diamond.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                        .shadow(color: .white.opacity(0.6), radius: 6)
                }
                .frame(width: 54, height: 54)
                .shadow(color: Color(labHex: "FFB02E").opacity(0.45), radius: 14, y: 4)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.shop.currency.text).font(.system(size: 13, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.65))
                    Text(String(store.balance)).font(LabFont.number(40)).foregroundStyle(.white)
                        .contentTransition(.numericText(value: Double(store.balance)))
                        .accessibilityIdentifier("lab.shop.balance")
                }
                Spacer(minLength: 0)
            }
            if let goal { progress(goal) }
            if let note = store.shop.note { Text(note.text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(20)
        .background {
            ZStack {
                LinearGradient(colors: [Color(labHex: "2A2118"), Color(labHex: "141416")], startPoint: .topTrailing, endPoint: .bottomLeading)
                RadialGradient(colors: [Color(labHex: "FFB02E").opacity(0.35), .clear], center: .topTrailing, startRadius: 0, endRadius: 260)
            }
        }
        .overlay { LabSheen(progress: sheen) }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1) }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lab.shop.wallet")
    }

    /// The cheapest thing on sale that is not owned yet and needs nothing else first.
    private var goal: LabShopItem? {
        store.shop.items
            .filter { $0.supported && !$0.isRepeat && !$0.isSoon && $0.price != nil && !store.owns($0.id) && ($0.requires.map(store.owns) ?? true) }
            .min { ($0.price ?? 0) < ($1.price ?? 0) }
    }

    private func progress(_ item: LabShopItem) -> some View {
        let price = max(1, item.price ?? 1), ready = store.balance >= price
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("lab.gems.next")).foregroundStyle(.white.opacity(0.65))
                Text(item.name.text).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Text(ready ? L10n.text("lab.gems.ready") : L10n.text("lab.gems.left", String(price - store.balance)))
                    .foregroundStyle(ready ? LabPalette.pass : .white.opacity(0.65))
            }
            .font(.system(size: 13, weight: .semibold))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(LinearGradient(colors: [Color(labHex: "FFD36B"), ready ? LabPalette.pass : Color(labHex: "FFB02E")], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * min(1, Double(store.balance) / Double(price)))
                }
            }
            .frame(height: 7)
        }
        .contentShape(Rectangle())
        .onTapGesture { opened = ShopItemID(id: item.id) }
        .accessibilityElement(children: .combine)
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        switch store.shopState {
        case .ready: EmptyView()
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L10n.text("lab.shop.loading")) }
                .font(.system(size: 13)).foregroundStyle(.secondary)
        case .failed:
            notice(symbol: "wifi.slash", text: L10n.text("lab.shop.offline"), button: L10n.text("Try Again")) { Task { await store.refreshShop() } }
                .accessibilityIdentifier("lab.shop.failed")
        case .newer:
            notice(symbol: "arrow.down.app", text: L10n.text("lab.shop.newer"), button: L10n.text("notice.update")) { openURL(AppNotices.shared.storeURL) }
                .accessibilityIdentifier("lab.shop.newer")
        }
    }

    private func notice(symbol: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Button(button, action: action).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
        }
        .padding(14)
        .background(LabPalette.surface(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Cards

    /// One thing for sale: its art with the price (or the thing to do with it) at its top right and a lock or a limited-sale
    /// tag at its top left, then its kind, name and one line of where it stands. A tap opens its page.
    private func card(_ item: LabShopItem) -> some View {
        let state = store.canBuy(item)
        let owned = store.owns(item.id) && !item.isRepeat
        let dimmed = item.isSoon || state == .update
        return VStack(alignment: .leading, spacing: 0) {
            LabShopArt(item: item, symbolSize: 34)
                .saturation(dimmed ? 0.2 : 1)
                .frame(height: 112)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        // Something kept for good once bought, not bought yet.
                        if !owned, !item.isRepeat {
                            Image(systemName: "lock.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 26, height: 26).background(.black.opacity(0.35), in: Circle())
                                .accessibilityLabel(L10n.text("lab.shop.locked"))
                                .accessibilityIdentifier("lab.shop.lock.\(item.id)")
                        }
                        if item.isLimited {
                            Text(L10n.text("lab.shop.limited")).font(.system(size: 10, weight: .heavy)).foregroundStyle(LabPalette.paperInk)
                                .padding(.horizontal, 8).padding(.vertical, 5).background(LabPalette.paper, in: Capsule())
                        }
                    }
                    .padding(9)
                }
                .overlay(alignment: .topTrailing) { corner(item, state: state, owned: owned).padding(9) }
                .overlay(alignment: .bottom) { shortBar(item, state: state) }
            VStack(alignment: .leading, spacing: 3) {
                Text(LabShopStyle.kind(item).uppercased()).font(.system(size: 10, weight: .heavy)).tracking(1).foregroundStyle(LabShopStyle.color(item))
                Text(item.name.text).font(.system(size: 16, weight: .bold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note(item, state: state, owned: owned)).font(.system(size: 12))
                    .foregroundStyle(goods.failures[item.id] == nil ? .secondary : Color.red).lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("lab.shop.note.\(item.id)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LabPalette.surface(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opacity(dimmed ? 0.7 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { LabHaptic.tick(); opened = ShopItemID(id: item.id) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("lab.shop.item.\(item.id)")
    }

    private func note(_ item: LabShopItem, state: LabStore.BuyResult, owned: Bool) -> String {
        if let failure = goods.failures[item.id] { return failure }
        if state == .update { return L10n.text("lab.shop.update") }
        if owned {
            if goods.working.contains(item.id) { return L10n.text("lab.shop.downloading") }
            if item.downloads, !goods.delivered(item) { return L10n.text(goods.outdated(item) ? "lab.shop.newVersion" : "lab.shop.notHere") }
            if item.home != nil { return L10n.text(chosenScene == item.id ? "lab.shop.inUse" : "lab.shop.owned") }
            return L10n.text("lab.shop.owned")
        }
        if item.isSoon { return L10n.text("lab.shop.soon") }
        if case .needs(let id) = state { return L10n.text("lab.shop.needs", store.shop.item(id)?.name.text ?? id) }
        if item.kind == "ticket", store.tickets > 0 { return L10n.text("lab.shop.tickets", String(store.tickets)) }
        return item.summary?.text ?? ""
    }

    /// The art's top right: the price with its gem, or once owned the thing to do with it, or a check.
    @ViewBuilder private func corner(_ item: LabShopItem, state: LabStore.BuyResult, owned: Bool) -> some View {
        if state == .update {
            action(L10n.text("notice.update"), id: "lab.shop.update.\(item.id)") { openURL(AppNotices.shared.storeURL) }
        } else if owned, goods.working.contains(item.id) {
            ProgressView().tint(.white).frame(width: 30, height: 30).background(.black.opacity(0.35), in: Circle())
        } else if owned, item.downloads, !goods.delivered(item) {
            action(L10n.text(goods.outdated(item) ? "lab.shop.getUpdate" : "lab.shop.get"), id: "lab.shop.get.\(item.id)") { Task { await goods.deliver(item) } }
        } else if owned, item.home != nil {
            let using = chosenScene == item.id
            action(L10n.text(using ? "lab.shop.useDefault" : "lab.shop.use"), id: "lab.shop.use.\(item.id)") { HomeScenes.choose(using ? nil : item.id) }
        } else if owned, let course = LearningCourses.shared.all.first(where: { $0.item == item.id }), StudyMode.shared.courseID != course.id {
            action(L10n.text("lab.shop.open"), id: "lab.shop.open.\(item.id)") { StudyMode.shared.open(course.id) }
        } else if owned {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.white, LabPalette.pass)
                .accessibilityLabel(L10n.text("lab.shop.ownedShort"))
        } else if let price = item.price {
            let ready = state == .bought
            LabPriceTag(price: price, size: 14)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(ready ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.38)), in: Capsule())
                .foregroundStyle(ready ? Color.black : Color.white)
                .accessibilityIdentifier("lab.shop.price.\(item.id)")
        }
    }

    /// How far the balance has come toward an item not affordable yet, as a thin line along the art's foot.
    @ViewBuilder private func shortBar(_ item: LabShopItem, state: LabStore.BuyResult) -> some View {
        if case .short = state, !item.isSoon, let price = item.price {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.3))
                    Rectangle().fill(LabPalette.gauge).frame(width: proxy.size.width * min(1, Double(store.balance) / Double(max(price, 1))))
                }
            }
            .frame(height: 4)
        }
    }

    private func action(_ title: String, id: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 6).background(.white, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// An item's id, as a sheet presents it.
struct ShopItemID: Identifiable, Hashable { let id: String }

// MARK: - An item's page

/// One item's page: its art large, what it is, and the one thing to do now — buy it, see what it needs first, or use it once
/// owned. Buying happens here, so the page is the confirmation; what is left afterwards is shown under the button. A purchase
/// is met with the art lighting up, gems bursting from a seal, and the next thing to do. Image mode opens the prompt analyzer's
/// page from a picture (`outside`), where what is missing leads to learning mode.
struct LabShopItemSheet: View {
    @State var itemID: String
    var outside = false
    /// Pushed onto a navigation stack (the picture details) rather than presented as its own sheet.
    var pushed = false
    /// What "open" does once a feature is bought, such as showing the prompt analyzer in place of this page.
    var onOpen: (() -> Void)?
    @State private var store = LabStore.shared
    @State private var goods = LabGoods.shared
    @State private var celebrated = false
    @State private var sheen = 0.0
    @SwiftUI.AppStorage(HomeScenes.chosenKey) private var chosenScene = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(itemID: String, outside: Bool = false, pushed: Bool = false, onOpen: (() -> Void)? = nil) {
        _itemID = State(initialValue: itemID)
        self.outside = outside
        self.pushed = pushed
        self.onOpen = onOpen
    }

    private var item: LabShopItem? { store.shop.item(itemID) }

    var body: some View {
        if pushed {
            content.task { await store.refreshShop() }
        } else {
            NavigationStack {
                content.toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { dismiss() } } }
            }
            .task { await store.refreshShop() }
        }
    }

    private var content: some View {
        Group {
            if let item { page(item) } else { ContentUnavailableView(L10n.text("lab.shop.failed"), systemImage: "bag") }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func page(_ item: LabShopItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LabShopArt(item: item, symbolSize: 80, symbolShown: !celebrated)
                    .frame(height: 250)
                    .overlay { if celebrated { LabShopBurst(color: LabShopStyle.color(item)) } }
                    .overlay { LabSheen(progress: sheen) }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .labCardShadow(LabShopStyle.color(item).opacity(0.35), radius: 20, y: 10)
                    .scaleEffect(celebrated && !reduceMotion ? 1.02 : 1)
                    .animation(.spring(duration: 0.5, bounce: 0.45), value: celebrated)
                VStack(alignment: .leading, spacing: 6) {
                    Text(LabShopStyle.kind(item).uppercased()).font(.system(size: 12, weight: .heavy)).tracking(1.2).foregroundStyle(LabShopStyle.color(item))
                    Text(item.name.text).font(.system(size: 30, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("lab.shop.page.\(item.id)")
                    if let summary = item.summary { Text(summary.text).font(.system(size: 17)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                chips(item)
                if let detail = item.detail, !detail.isEmpty {
                    LabMarkdown(text: detail.text)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) { actionBar(item) }
    }

    private func chips(_ item: LabShopItem) -> some View {
        let labels: [(String, String)] = [
            item.isLimited ? ("clock", L10n.text("lab.shop.limited")) : nil,
            item.isRepeat ? ("arrow.triangle.2.circlepath", L10n.text("lab.shop.repeat")) : nil,
            item.requires.flatMap { id in store.owns(id) ? nil : store.shop.item(id).map { ("lock", L10n.text("lab.shop.needsFirst", $0.name.text)) } },
        ].compactMap { $0 }
        return HStack(spacing: 8) {
            ForEach(labels, id: \.1) { symbol, text in
                Label(text, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(LabPalette.surface(1), in: Capsule())
            }
        }
    }

    // MARK: The one thing to do

    private func actionBar(_ item: LabShopItem) -> some View {
        VStack(spacing: 10) {
            actionContent(item)
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder private func actionContent(_ item: LabShopItem) -> some View {
        let state = store.canBuy(item)
        let owned = store.owns(item.id) && !item.isRepeat
        if celebrated || owned {
            if celebrated {
                Label(L10n.text("lab.shop.bought"), systemImage: "checkmark.seal.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(LabPalette.pass)
                    .symbolEffect(.bounce, value: celebrated)
                    .accessibilityIdentifier("lab.shop.bought")
            }
            ownedAction(item)
        } else {
            switch state {
            case .bought:
                let price = item.price ?? 0
                wide(L10n.text("lab.shop.buy", String(price)), prominent: true, id: "lab.shop.buy.\(item.id)") { buy(item) }
                Text(L10n.text("lab.shop.after", String(store.balance - price))).font(.system(size: 12)).foregroundStyle(.secondary)
            case .short(let missing):
                let price = max(1, item.price ?? 1)
                VStack(spacing: 8) {
                    HStack {
                        LabPriceTag(price: price)
                        Spacer()
                        Text("\(store.balance) / \(price)").font(LabFont.number(13)).foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(1, Double(store.balance) / Double(price))).tint(LabPalette.gauge)
                }
                if outside {
                    // From a picture: the way to more 보석 is learning mode.
                    wide(L10n.text("prompt.offer.learn"), prominent: false, id: "prompt.offer.learn") { dismiss(); StudyMode.shared.enterLab(.deck) }
                    Text(L10n.text("prompt.offer.short", String(missing))).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    wide(L10n.text("lab.shop.shortButton", String(missing)), prominent: false, id: "lab.shop.short.\(item.id)", disabled: true) {}
                    Text(L10n.text("lab.shop.earnMore")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .needs(let id):
                let needed = store.shop.item(id)
                wide(L10n.text("lab.shop.see", needed?.name.text ?? id), prominent: false, id: "lab.shop.see.\(id)") {
                    withAnimation(.snappy) { itemID = id }
                }
                Text(L10n.text("lab.shop.needsFirst", needed?.name.text ?? id)).font(.system(size: 12)).foregroundStyle(.secondary)
            case .update:
                wide(L10n.text("notice.update"), prominent: true, id: "lab.shop.update.\(item.id)") { openURL(AppNotices.shared.storeURL) }
                Text(L10n.text("lab.shop.update")).font(.system(size: 12)).foregroundStyle(.secondary)
            case .unavailable, .owned:
                wide(L10n.text("lab.shop.soon"), prominent: false, id: "lab.shop.soon.\(item.id)", disabled: true) {}
            }
        }
    }

    @ViewBuilder private func ownedAction(_ item: LabShopItem) -> some View {
        if goods.working.contains(item.id) {
            ProgressView().frame(height: 50)
        } else if item.downloads, !goods.delivered(item) {
            if let failure = goods.failures[item.id] { Text(failure).font(.system(size: 12)).foregroundStyle(.red) }
            wide(L10n.text(goods.outdated(item) ? "lab.shop.getUpdate" : "lab.shop.get"), prominent: true, id: "lab.shop.get.\(item.id)") { Task { await goods.deliver(item) } }
        } else if item.home != nil {
            let using = chosenScene == item.id
            wide(L10n.text(using ? "lab.shop.useDefault" : "lab.shop.use"), prominent: !using, id: "lab.shop.use.\(item.id)") { HomeScenes.choose(using ? nil : item.id) }
        } else if let course = LearningCourses.shared.all.first(where: { $0.item == item.id }), StudyMode.shared.courseID != course.id || outside {
            wide(L10n.text("lab.shop.open"), prominent: true, id: "lab.shop.open.\(item.id)") {
                dismiss()
                if outside { StudyMode.shared.enterLab(.courses) }
                StudyMode.shared.open(course.id)
            }
        } else if let onOpen {
            wide(L10n.text("lab.shop.open"), prominent: true, id: "lab.shop.open.\(item.id)", onOpen)
        } else {
            // Nothing more to do with it here: say where it is used, and close.
            wide(L10n.text("OK"), prominent: true, id: "lab.shop.done.\(item.id)") { dismiss() }
            Text(L10n.text(item.feature == LabFeature.promptAnalyzer.rawValue ? "prompt.offer.bought" : "lab.shop.owned"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func wide(_ title: String, prominent: Bool, id: String, disabled: Bool = false, _ run: @escaping () -> Void) -> some View {
        Group {
            if prominent {
                Button(action: run) { Text(title).font(.system(size: 17, weight: .bold)).frame(maxWidth: .infinity).frame(minHeight: 30) }.labPrimary()
            } else {
                Button(action: run) { Text(title).font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 30) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .buttonBorderShape(.capsule)
        .disabled(disabled)
        .accessibilityIdentifier(id)
    }

    private func buy(_ item: LabShopItem) {
        guard store.buy(item) == .bought else { return }
        LabHaptic.pass()
        withAnimation(.spring(duration: 0.5, bounce: 0.4)) { celebrated = true }
        if !reduceMotion { sheen = 0; withAnimation(.easeInOut(duration: 0.9)) { sheen = 1 } }
        if item.downloads { Task { await goods.deliver(item) } }
    }
}

/// Gems bursting from the middle of an item's art when it is bought, around a seal that springs in.
struct LabShopBurst: View {
    let color: Color
    @State private var out = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<14, id: \.self) { index in
                    let angle = Double(index) / 14 * 2 * .pi + (index.isMultiple(of: 2) ? 0.2 : 0)
                    let distance: CGFloat = index.isMultiple(of: 3) ? 120 : 92
                    Image(systemName: "diamond.fill").font(.system(size: index.isMultiple(of: 2) ? 14 : 10, weight: .bold))
                        .foregroundStyle(index.isMultiple(of: 3) ? Color(labHex: "FFD36B") : .white)
                        .offset(x: out ? cos(angle) * distance : 0, y: out ? sin(angle) * distance : 0)
                        .opacity(out ? 0 : 1)
                        .scaleEffect(out ? 1.2 : 0.3)
                }
            }
            Image(systemName: "checkmark.seal.fill").font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white, color)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .scaleEffect(out ? 1 : 0.3).opacity(out ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.35)) { out = true } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
