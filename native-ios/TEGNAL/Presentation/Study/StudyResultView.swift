import SwiftUI

/// The end of a round: the score, what the round changed, and the answers to look back at.
struct StudyResultView: View {
    let session: StudySession
    let before: StudySummary
    let after: StudySummary
    let open: (StudyTag) -> Void
    let again: () -> Void
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private var total: Int { session.results.count }
    private var right: Int { session.rightCount }
    private var grade: StudyGrade { StudyGrade(right: right, total: total) }
    private var gained: Int { max(0, after.learned - before.learned) }

    var body: some View {
        ZStack(alignment: .top) {
            List {
                if session.results.isEmpty {
                    Section {
                        ContentUnavailableView(L10n.text("Nothing to Review"), systemImage: "checkmark.seal",
                                               description: Text(L10n.text("No tag is due right now. Learn new tags or come back later.")))
                    }
                } else {
                    Section { hero.listRowBackground(Color.clear).listRowInsets(EdgeInsets()) } footer: {
                        if session.withoutPictures { Text(L10n.text("Some questions asked by meaning because no picture could be read.")) }
                    }
                    Section { tiles.listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                    Section { journey }
                    Section(L10n.text("Answers")) {
                        ForEach(session.results) { result in
                            Button { open(result.tag) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: result.right ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(result.right ? Color.green : Color.red)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.tag.english).font(.body.weight(.medium)).foregroundStyle(Color.primary)
                                        Text(result.tag.note.resolved()).font(.footnote).foregroundStyle(Color.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }.listStyle(.insetGrouped)
            // Finishing a round is worth marking however it went; a better round gets more paper.
            if !session.results.isEmpty, !reduceMotion {
                StudyConfetti(pieces: grade.confetti).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        // The way on stays in reach however long the list of answers is.
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button(action: done) { Text(L10n.text("Done")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                    .buttonStyle(.bordered).accessibilityIdentifier("study.done")
                if !session.results.isEmpty {
                    Button(action: again) { Text(L10n.text("Another Round")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("study.again")
                }
            }.frame(maxWidth: 640).padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: .infinity).background(.bar)
        }
        .sensoryFeedback(.success, trigger: shown)
        .onAppear {
            if reduceMotion { shown = true } else { withAnimation(.spring(duration: 0.9, bounce: 0.25).delay(0.15)) { shown = true } }
        }
    }

    // MARK: Score

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 14)
                Circle().trim(from: 0, to: shown && total > 0 ? CGFloat(right) / CGFloat(total) : 0)
                    .stroke(AngularGradient(colors: grade.colors + [grade.colors[0]], center: .center), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Image(systemName: grade.symbol).font(.title2).foregroundStyle(grade.colors[0])
                        .symbolEffect(.bounce, value: shown)
                    Text("\(shown ? right : 0) / \(total)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(shown ? right : 0)))
                        .accessibilityIdentifier("study.score")
                }
            }
            .frame(width: 176, height: 176).padding(.top, 8)
            .scaleEffect(shown ? 1 : 0.82)
            VStack(spacing: 4) {
                Text(L10n.text(grade.title)).font(.title2.weight(.bold))
                Text(L10n.text(grade == .perfect ? "Every answer right." : "Tags you missed come back sooner.")).font(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    // MARK: What the round changed

    private var tiles: some View {
        HStack(spacing: 10) {
            tile("flame.fill", .orange, String(after.streak), L10n.text("Day streak"), raised: after.streak > before.streak)
            tile("checkmark.seal.fill", .green, gained > 0 ? "+\(gained)" : String(after.learned), L10n.text(gained > 0 ? "Newly learned" : "Learned"), raised: gained > 0)
            tile("bolt.fill", StudyStyle.accent, String(after.today), L10n.text("Answered today"), raised: false)
        }
    }

    private func tile(_ symbol: String, _ color: Color, _ value: String, _ title: String, raised: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color).symbolEffect(.bounce, value: raised && shown)
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 96).padding(.vertical, 10).padding(.horizontal, 4)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay { if raised { RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(0.5), lineWidth: 1.5) } }
        .accessibilityElement(children: .combine)
    }

    /// How far through the whole curriculum the round has brought the learner.
    private var journey: some View {
        let fraction = after.total == 0 ? 0 : Double(shown ? after.learned : before.learned) / Double(after.total)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("%@ of %@ learned", String(after.learned), String(after.total))).font(.subheadline.weight(.semibold))
                Spacer()
                if after.due > 0 { Text(L10n.text("%@ to review", String(after.due))).font(.caption).foregroundStyle(.secondary) }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .tertiarySystemFill))
                    Capsule().fill(LinearGradient(colors: [StudyStyle.accent, .purple], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(fraction > 0 ? 8 : 0, proxy.size.width * fraction))
                }
            }.frame(height: 8)
        }.padding(.vertical, 4)
    }
}

/// How a round went, which decides how much the results screen celebrates.
enum StudyGrade: Equatable {
    case perfect, great, practice
    init(right: Int, total: Int) {
        self = total > 0 && right == total ? .perfect : total > 0 && Double(right) / Double(total) >= 0.7 ? .great : .practice
    }
    var confetti: Int { self == .perfect ? 120 : self == .great ? 70 : 30 }
    var title: String { self == .perfect ? "Perfect Round!" : self == .great ? "Well Done!" : "Keep Going!" }
    var symbol: String { self == .perfect ? "trophy.fill" : self == .great ? "star.fill" : "figure.walk" }
    var colors: [Color] { self == .perfect ? [.yellow, .orange, .pink] : self == .great ? [.indigo, .purple, .teal] : [.indigo, .blue] }
}

/// Paper falling once from the top of the screen.
struct StudyConfetti: View {
    let pieces: Int
    @State private var began = Date.now
    private static let colors: [Color] = [.indigo, .purple, .pink, .orange, .yellow, .teal, .green]
    private static let length = 3.6
    /// A steady value in 0..<1 for a piece, so every frame draws the same piece the same way.
    private func unit(_ index: Int, _ salt: Int) -> Double {
        var value = UInt64(truncatingIfNeeded: index &* 2_654_435_761 &+ salt &* 40_503 &+ 12_345)
        value ^= value >> 15; value = value &* 2_246_822_519; value ^= value >> 13
        return Double(value % 10_000) / 10_000
    }
    var body: some View {
        TimelineView(.animation(paused: Date.now.timeIntervalSince(began) > Self.length)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSince(began)
                guard time < Self.length else { return }
                for index in 0..<pieces {
                    let age = time - unit(index, 1) * 0.9
                    guard age > 0 else { continue }
                    let speed = 180 + unit(index, 2) * 260
                    let x = unit(index, 3) * size.width + sin(age * (2 + unit(index, 4) * 3) + unit(index, 5) * 6) * 26
                    let y = -24 + speed * age + 120 * age * age
                    guard y < size.height + 24 else { continue }
                    var piece = context
                    piece.opacity = min(1, max(0, (Self.length - time) / 0.8))
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(age * (3 + unit(index, 6) * 6)))
                    let width = 6 + unit(index, 7) * 6
                    piece.fill(Path(roundedRect: CGRect(x: -width / 2, y: -width * 0.3, width: width, height: width * 0.6), cornerRadius: 1.5),
                               with: .color(Self.colors[index % Self.colors.count]))
                }
            }
        }.ignoresSafeArea()
    }
}
