import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.tegnalcourse`, a deck course in one JSON file (`LabCourseFile`). Plain `.json` course files open as well.
    static let tegnalCourse = UTType(exportedAs: "work.nextline.tegnal.course", conformingTo: .json)
}

/// The 코스 tab, in every course alike: each course of `LearningCourses` as a card, the way the 2D course was shown before it was
/// bought. The course on screen is marked on its card; another one owned opens with a tap; one not bought yet shows its price and
/// the balance. At the foot, a course file can be imported; an imported course is removed from its card's menu.
struct LabCoursesView: View {
    @Environment(BooruStore.self) private var booru
    @State private var store = LabStore.shared
    @State private var courses = LearningCourses.shared
    @State private var confirming: LearningCourse?
    @State private var removing: LearningCourse?
    @State private var importing = false
    @State private var failure: String?
    /// The last import was a course for a newer app: the alert asks for an update rather than calling the file broken.
    @State private var needsUpdate = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LabHeader(kicker: Text(L10n.text("lab.courses.subtitle")), title: L10n.text("lab.tab.courses"))
                ForEach(courses.all) { course in
                    opening(course) { card(course) }
                }
                ForEach(courses.waiting) { waiting in waitingCard(waiting) }
                importer
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .labLines()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.tegnalCourse, .json]) { result in
            guard case .success(let url) = result else { return }
            do {
                let course = try courses.add(url)
                LabHaptic.pass()
                StudyMode.shared.open(course.id)
            } catch {
                needsUpdate = error as? LabCourseFileError == .newer
                failure = (error as? LocalizedError)?.errorDescription ?? L10n.text("lab.import.notCourse")
            }
        }
        .alert(L10n.text(needsUpdate ? "lab.import.updateTitle" : "lab.import.failed"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L10n.text("OK"), role: .cancel) {}
        } message: { Text(failure ?? "") }
        .alert(L10n.text("lab.shop.confirm", confirming.map(title) ?? ""), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let course = confirming, let item = course.item.flatMap(store.shop.item) {
                Button(L10n.text("lab.shop.buy", String(item.price ?? 0))) {
                    if store.buy(item) == .bought { LabHaptic.pass(); StudyMode.shared.open(course.id) }
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("lab.shop.confirmNote", String(store.balance - (confirming?.item.flatMap(store.shop.item)?.price ?? 0))))
        }
        .alert(L10n.text("lab.courses.removeConfirm", removing.map(title) ?? ""), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L10n.text("lab.courses.remove"), role: .destructive) {
                guard let course = removing else { return }
                if StudyMode.shared.courseID == course.id { StudyMode.shared.open(LearningCourse.labID) }
                courses.remove(course.id)
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: { Text(L10n.text("lab.courses.removeNote")) }
    }

    private func title(_ course: LearningCourse) -> String { course.title }

    // MARK: Cards

    @ViewBuilder private func card(_ course: LearningCourse) -> some View {
        let here = StudyMode.shared.courseID == course.id
        switch course.engine {
        case .tags:
            if let lessons = course.lessons {
                // An imported course on the 2D engine: its own colour, with its symbol in the corner.
                let color = Color(studyHex: lessons.color)
                card(kicker: L10n.text("lab.courses.imported.kicker"), title: title(course), current: here, fill: color.gradient, glow: color.opacity(0.35),
                     features: [("map.fill", L10n.text("lab.2d.lessons", String(lessons.path.lessons.count))),
                                ("tag.fill", L10n.text("lab.2d.tags", String(lessons.unit?.tags.count ?? 0))),
                                ("checkmark.circle.fill", L10n.text("lab.courses.lessonsDone", String(lessons.path.lessons.filter { lessonDone.contains($0.id) }.count), String(lessons.path.lessons.count)))]) {
                    Image(systemName: lessons.symbol).font(.system(size: 86, weight: .bold)).foregroundStyle(.white.opacity(0.22))
                        .offset(x: -18, y: -14).accessibilityHidden(true)
                }
            } else {
            // 2D AI 배우기: the course's purple, with its guide leaning in from the corner.
            card(kicker: L10n.text("lab.courses.tags.kicker"), title: title(course), current: here, fill: StudyTheme.primary.gradient, glow: StudyTheme.primary.opacity(0.35),
                 footer: purchase(course, ink: StudyTheme.primary),
                 features: [("map.fill", L10n.text("lab.2d.lessons", String(StudyPath.bundled.lessons.count))),
                            ("tag.fill", L10n.text("lab.2d.tags", String(StudyCurriculum.bundled.tags.count))),
                            ("wand.and.stars", L10n.text("lab.2d.studio"))]) {
                StudyMascot(pose: .wave, size: 132).offset(x: 8, y: 6).accessibilityHidden(true)
            }
            }
        case .deck:
            if let deck = course.deck {
                // A deck course: the AI lab in ink, an imported one in its first card colour, each with a fan of its card colours.
                let colors = deck.info.cardColors ?? [LabPalette.ink]
                let features: [(String, String)] = [("rectangle.stack.fill", L10n.text("lab.courses.lab.cards", String(deck.episodes.count), String(deck.seasons.count)))]
                    + (deck.imported ? [] : [("doc.text.fill", L10n.text("lab.courses.lab.sheet"))])
                    + [("gauge.with.dots.needle.67percent", L10n.text("lab.courses.lab.rate", deck.info.gauge.text, "\(rate(deck))%"))]
                card(kicker: L10n.text(deck.imported ? "lab.courses.imported.kicker" : "lab.courses.lab.kicker"), title: deck.title, current: here,
                     fill: (deck.imported ? Color(labHex: colors.first ?? LabPalette.ink) : Color(labHex: "2C2C2E")).gradient, glow: .black.opacity(0.3),
                     features: features) { fan(colors) }
            }
        }
    }

    /// A deck course's rate, read whether or not it is the course on screen.
    private func rate(_ deck: LabCourse) -> Int {
        deck.base + deck.episodes.filter { store.progress.cards[LabStore.key($0.id, in: deck)] != nil }.reduce(0) { $0 + $1.impact }
    }

    private func fan(_ colors: [String]) -> some View {
        ZStack {
            ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { index, hex in
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(labHex: hex))
                    .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.75) }
                    .frame(width: 58, height: 78)
                    .rotationEffect(.degrees(Double(index - 1) * 11), anchor: .bottom)
                    .offset(x: CGFloat(index - 1) * 14)
                    .labCardShadow(.black.opacity(0.35), radius: 6, y: 3)
            }
        }
        .offset(x: -30, y: 16)
        .accessibilityHidden(true)
    }

    /// A course as a card: what it is above, and, for a course not bought yet, its price and the buy button in a band across
    /// the foot of the same card, so each price sits with its own course.
    private func card<Fill: ShapeStyle, Art: View>(kicker: String, title: String, current: Bool, fill: Fill, glow: Color, footer: AnyView? = nil,
                                                   features: [(String, String)], @ViewBuilder art: () -> Art) -> some View {
        VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(kicker).font(.system(size: 11, weight: .bold)).tracking(1.6).foregroundStyle(.white.opacity(0.75))
                    Spacer(minLength: 8)
                    if current {
                        Label(L10n.text("lab.courses.here"), systemImage: "checkmark")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).frame(height: 26).background(.white.opacity(0.2), in: Capsule())
                            .accessibilityIdentifier("lab.courses.here")
                    }
                }
                Text(title).font(LabFont.voice(30)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(features, id: \.1) { symbol, text in
                    Label(text, systemImage: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .padding(.trailing, 96)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottomTrailing) { art() }
            if let footer {
                footer
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.24))
            }
        }
        .background(fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .labCardShadow(glow, radius: 20, y: 10)
        .accessibilityElement(children: .contain)
    }

    /// A card that opens its course when tapped, or just the card when it is the course on screen or not bought yet.
    /// An imported course's card has a menu to remove it.
    @ViewBuilder private func opening<Card: View>(_ course: LearningCourse, @ViewBuilder card: () -> Card) -> some View {
        let opens = StudyMode.shared.courseID != course.id && courses.owned(course)
        Group {
            if opens {
                Button { LabHaptic.tick(); StudyMode.shared.open(course.id) } label: { card() }
                    .buttonStyle(LabPressStyle())
                    .accessibilityHint(L10n.text("lab.shop.open"))
                    .accessibilityIdentifier("lab.courses.open." + course.id)
            } else {
                card().accessibilityIdentifier("lab.courses.card." + course.id)
            }
        }
        .contextMenu {
            if course.imported {
                Button(L10n.text("lab.courses.remove"), systemImage: "trash", role: .destructive) { removing = course }
            }
        }
    }

    /// The foot of a course not bought yet: what the learner has, what is missing and how it is earned, and the buy button.
    /// Nil for a course owned or free.
    private func purchase(_ course: LearningCourse, ink: Color) -> AnyView? {
        guard !courses.owned(course), let item = course.item.flatMap(store.shop.item), let price = item.price else { return nil }
        let state = store.canBuy(item)
        return AnyView(HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state == .bought ? L10n.text("lab.2d.balance", String(store.balance)) : L10n.text("lab.2d.short", String(store.balance), String(price - store.balance)))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                // A learner who studied the course before it was sold: the lessons stay, waiting for it to be bought.
                if course.id == LearningCourse.tagsID, store.tagCoursePaid.lessons > 0 {
                    Text(L10n.text("lab.2d.kept", String(store.tagCoursePaid.lessons))).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state != .bought {
                    Text(L10n.text("lab.2d.how")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if state == .bought {
                Button { confirming = course } label: {
                    Text(L10n.text("lab.shop.buy", String(price))).font(.system(size: 15, weight: .bold)).padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                .tint(.white).foregroundStyle(ink)
                .accessibilityIdentifier(course.id == LearningCourse.tagsID ? "lab.2d.buy" : "lab.courses.buy." + course.id)
            } else {
                // Not enough yet: the price, readable on the card, with nothing to press.
                Text(L10n.text("lab.shop.buy", String(price))).font(.system(size: 15, weight: .bold)).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 18).frame(height: 44)
                    .overlay { Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 1.2) }
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier(course.id == LearningCourse.tagsID ? "lab.2d.buy" : "lab.courses.buy." + course.id)
            }
        })
    }

    /// Lessons finished in any course on the tags engine, for an imported course's count.
    private var lessonDone: Set<String> { Set(((try? booru.studyStore.lessons()) ?? [:]).keys) }

    /// A course kept although this app is too old for it: named, greyed, and asking for an update.
    private func waitingCard(_ waiting: WaitingCourse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("lab.courses.waiting.kicker")).font(.system(size: 11, weight: .bold)).tracking(1.6).foregroundStyle(.secondary)
            Text(waiting.title).font(LabFont.voice(24))
            Label(L10n.text("lab.courses.waiting.note"), systemImage: "arrow.down.app.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lab.courses.waiting.\(waiting.id)")
        .contextMenu {
            Button(L10n.text("lab.courses.remove"), systemImage: "trash", role: .destructive) { courses.remove(waiting.id) }
        }
    }

    // MARK: Importing

    /// The way in for course files: a stock button and what an imported course is.
    private var importer: some View {
        VStack(spacing: 8) {
            Button { importing = true } label: {
                Label(L10n.text("lab.courses.import"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large).buttonBorderShape(.roundedRectangle(radius: 18))
            .accessibilityIdentifier("lab.courses.import")
            Text(L10n.text("lab.courses.importNote")).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }
}
