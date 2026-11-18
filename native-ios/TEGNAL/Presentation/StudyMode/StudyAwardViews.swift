import SwiftUI

// Badges are drawn, not pictured: a metal body with a bevelled rim, a sunken plate, an embossed sign and a light
// that sweeps across. A badge not yet earned is the same shape in shadow, ringed by how far along it is.

// MARK: - Shape and metal

/// The outline of a badge. Each family has its own, so that a shelf of badges reads at a glance.
struct StudyBadgeShape: Shape {
    let family: StudyAward.Family

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height), center = CGPoint(x: rect.midX, y: rect.midY), radius = side / 2
        func ring(_ count: Int, inner: CGFloat = 1, turn: Double = -.pi / 2) -> [CGPoint] {
            (0..<count).map { index in
                let length = radius * (inner < 1 && index % 2 == 1 ? inner : 1)
                let angle = turn + Double(index) / Double(count) * 2 * .pi
                return CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
            }
        }
        switch family {
        case .lessons: return Self.rounded(ring(6), corner: side * 0.1)
        case .streak: return Self.rounded(ring(24, inner: 0.9), corner: side * 0.05)
        case .tags: return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: side, height: side))
        case .perfect: return Self.rounded(ring(10, inner: 0.62), corner: side * 0.07)
        case .combo: return Self.rounded(ring(16, inner: 0.8), corner: side * 0.045)
        case .xp: return Self.rounded(ring(4), corner: side * 0.14)
        case .studio: return Self.rounded(ring(8, turn: -.pi / 2 + .pi / 8), corner: side * 0.09)
        case .speed: return Self.rounded(ring(5), corner: side * 0.11)
        case .sections:
            // A shield: flat across the top, drawn in to a point at the foot.
            let left = center.x - radius * 0.86, right = center.x + radius * 0.86, top = center.y - radius * 0.92
            var path = Path()
            path.move(to: CGPoint(x: center.x, y: top + radius * 0.1))
            path.addQuadCurve(to: CGPoint(x: right, y: top), control: CGPoint(x: center.x + radius * 0.5, y: top + radius * 0.14))
            path.addLine(to: CGPoint(x: right, y: center.y + radius * 0.12))
            path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: CGPoint(x: right, y: center.y + radius * 0.72))
            path.addQuadCurve(to: CGPoint(x: left, y: center.y + radius * 0.12), control: CGPoint(x: left, y: center.y + radius * 0.72))
            path.addLine(to: CGPoint(x: left, y: top))
            path.addQuadCurve(to: CGPoint(x: center.x, y: top + radius * 0.1), control: CGPoint(x: center.x - radius * 0.5, y: top + radius * 0.14))
            path.closeSubpath()
            return path
        }
    }

    /// A polygon through the points with its corners rounded off.
    private static func rounded(_ points: [CGPoint], corner: CGFloat) -> Path {
        var path = Path()
        guard points.count > 2, let last = points.last else { return path }
        path.move(to: CGPoint(x: (last.x + points[0].x) / 2, y: (last.y + points[0].y) / 2))
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            path.addArc(tangent1End: points[index], tangent2End: CGPoint(x: (points[index].x + next.x) / 2, y: (points[index].y + next.y) / 2), radius: corner)
        }
        path.closeSubpath()
        return path
    }
}

/// The colours a badge is cast in.
struct StudyMetal {
    let light: Color, mid: Color, dark: Color
    /// More than one hue running round the badge, for the rarest.
    var hues: [Color]?

    init(_ award: StudyAward) {
        if let hex = award.color {
            let base = Color(studyHex: hex)
            self.init(light: base.studyLifted(), mid: base, dark: base.studyEdge())
        } else {
            switch award.metal {
            case .bronze: self.init(light: Color(studyHex: "F3B37C"), mid: Color(studyHex: "CC7A3A"), dark: Color(studyHex: "7E4219"))
            case .silver: self.init(light: Color(studyHex: "F7F9FC"), mid: Color(studyHex: "B4BDCB"), dark: Color(studyHex: "6C7686"))
            case .gold: self.init(light: Color(studyHex: "FFEC9E"), mid: Color(studyHex: "FFB627"), dark: Color(studyHex: "B36B00"))
            case .prism:
                self.init(light: Color(studyHex: "E9E4FF"), mid: Color(studyHex: "9B8CFF"), dark: Color(studyHex: "4A2FB8"),
                          hues: ["9B8CFF", "5CE1E6", "8DF5B6", "FFE27A", "FF8AD8", "9B8CFF"].map { Color(studyHex: $0) })
            }
        }
    }
    init(light: Color, mid: Color, dark: Color, hues: [Color]? = nil) { self.light = light; self.mid = mid; self.dark = dark; self.hues = hues }
}

extension Color {
    /// A paler shade of the same colour, for where light falls on a badge.
    func studyLifted() -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: saturation * 0.45, brightness: min(1, brightness * 1.25 + 0.1), opacity: alpha)
    }
}

// MARK: - The badge

struct StudyMedal: View {
    let award: StudyAward
    var earned = true
    /// From zero to one, shown as a ring round a badge not yet earned.
    var progress = 0.0
    var size: CGFloat = 92
    /// A light sweeps across an earned badge now and then.
    var shines = true
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = StudyBadgeShape(family: award.family), metal = StudyMetal(award)
        ZStack {
            if earned {
                // The edge the badge stands on gives it thickness.
                shape.fill(metal.dark).offset(y: size * 0.05)
                shape.fill(LinearGradient(colors: [metal.light, metal.mid, metal.dark], startPoint: .topLeading, endPoint: .bottomTrailing))
                if let hues = metal.hues {
                    shape.fill(AngularGradient(colors: hues, center: .center)).opacity(0.75).blendMode(.softLight)
                    shape.fill(AngularGradient(colors: hues, center: .center)).opacity(0.35)
                }
                // The bevel: lit from above, shaded below.
                shape.stroke(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.1), .black.opacity(0.3)], startPoint: .top, endPoint: .bottom), lineWidth: size * 0.09)
                    .clipShape(shape)
                // The plate the sign sits in, sunk below the rim.
                shape.fill(LinearGradient(colors: [metal.dark, metal.mid], startPoint: .top, endPoint: .bottom)).scaleEffect(0.74)
                shape.stroke(LinearGradient(colors: [.black.opacity(0.35), .clear, .white.opacity(0.55)], startPoint: .top, endPoint: .bottom), lineWidth: size * 0.035)
                    .scaleEffect(0.74)
                Image(systemName: award.symbol).font(.system(size: size * 0.3, weight: .heavy))
                    .foregroundStyle(LinearGradient(colors: [.white, metal.light], startPoint: .top, endPoint: .bottom))
                    .shadow(color: metal.dark.opacity(0.9), radius: 0, y: size * 0.022)
                    .offset(y: award.family == .sections ? -size * 0.04 : 0)
                if shines, !reduceMotion {
                    LinearGradient(colors: [.clear, .white.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: size * 0.34).rotationEffect(.degrees(22))
                        .offset(x: sweep ? size * 0.9 : -size * 0.9)
                        .frame(width: size, height: size).clipShape(shape).blendMode(.plusLighter)
                        .animation(.easeInOut(duration: 1.1).delay(2.4).repeatForever(autoreverses: false), value: sweep)
                }
            } else {
                shape.fill(StudyTheme.line).offset(y: size * 0.04)
                shape.fill(StudyTheme.sunken)
                shape.stroke(StudyTheme.line, lineWidth: size * 0.06).clipShape(shape)
                Image(systemName: award.symbol).font(.system(size: size * 0.3, weight: .heavy)).foregroundStyle(StudyTheme.muted.opacity(0.45))
                    .offset(y: award.family == .sections ? -size * 0.04 : 0)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if !earned {
                Circle().stroke(StudyTheme.line.opacity(0.6), lineWidth: size * 0.045).padding(-size * 0.09)
                Circle().trim(from: 0, to: progress).stroke(StudyTheme.primary, style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(-size * 0.09)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !earned {
                Image(systemName: "lock.fill").font(.system(size: size * 0.15, weight: .heavy)).foregroundStyle(StudyTheme.muted)
                    .padding(size * 0.055).background(StudyTheme.surface, in: Circle()).overlay { Circle().strokeBorder(StudyTheme.line, lineWidth: 1.5) }
            }
        }
        .padding(earned ? 0 : size * 0.09)
        .onAppear { if earned, shines { sweep = true } }
        .accessibilityElement().accessibilityLabel(award.name)
        .accessibilityValue(L10n.text(earned ? "Earned" : "Locked"))
    }
}

// MARK: - On the Me tab

/// The latest badges and how many there are, leading to all of them.
struct StudyAwardsCard: View {
    let model: StudyModeModel
    let open: () -> Void
    var body: some View {
        let all = model.awards, earned = all.filter { model.earned[$0.id] != nil }
        // Newest first; with none yet, the ones nearest to being earned stand in as a promise.
        let shown = earned.isEmpty
            ? Array(all.sorted { model.facts.progress($0) > model.facts.progress($1) }.prefix(4))
            : Array(earned.sorted { (model.earned[$0.id]?.earned ?? .distantPast) > (model.earned[$1.id]?.earned ?? .distantPast) }.prefix(4))
        Button { StudySound.tap.play(); open() } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(L10n.text("Achievements"), systemImage: "trophy.fill").font(StudyTheme.title(20)).foregroundStyle(StudyTheme.ink)
                    Spacer()
                    Text(verbatim: "\(earned.count) / \(all.count)").font(StudyTheme.body(15, .heavy)).foregroundStyle(StudyTheme.gold).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .heavy)).foregroundStyle(StudyTheme.muted)
                }
                HStack(spacing: 0) {
                    ForEach(shown) { award in
                        StudyMedal(award: award, earned: model.earned[award.id] != nil, progress: model.facts.progress(award), size: 62).frame(maxWidth: .infinity)
                    }
                }
                StudyBar(value: all.isEmpty ? 0 : Double(earned.count) / Double(all.count), color: StudyTheme.gold, height: 10)
            }.padding(18)
        }
        .buttonStyle(StudyPressStyle(radius: 22, outlined: true))
        .accessibilityIdentifier("study.awards")
    }
}

// MARK: - The gallery

struct StudyAwardsGallery: View {
    let model: StudyModeModel
    @Environment(\.dismiss) private var dismiss
    @State private var opened: StudyAward?

    var body: some View {
        let all = model.awards, count = all.filter { model.earned[$0.id] != nil }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(StudyTheme.sunken, lineWidth: 12)
                        Circle().trim(from: 0, to: all.isEmpty ? 0 : Double(count) / Double(all.count))
                            .stroke(LinearGradient(colors: [StudyTheme.gold, StudyTheme.flame], startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text(String(count)).font(StudyTheme.title(34)).foregroundStyle(StudyTheme.ink).monospacedDigit()
                            Text(verbatim: "/ \(all.count)").font(StudyTheme.body(13, .heavy)).foregroundStyle(StudyTheme.muted).monospacedDigit()
                        }
                    }
                    .frame(width: 112, height: 112).padding(6)
                    .accessibilityElement().accessibilityLabel(L10n.text("Achievements") + " \(count) / \(all.count)").accessibilityIdentifier("study.awards.count")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("Achievements")).font(StudyTheme.title(28)).foregroundStyle(StudyTheme.ink)
                        Text(L10n.text("Every badge is something you really did. Tap one to see how it is earned."))
                            .font(StudyTheme.body(14, .medium)).foregroundStyle(StudyTheme.muted)
                    }
                }
                ForEach(StudyAward.Family.allCases, id: \.self) { family in
                    let awards = all.filter { $0.family == family }
                    if !awards.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(family.title).font(StudyTheme.title(19)).foregroundStyle(StudyTheme.ink)
                                Spacer()
                                Text(verbatim: "\(awards.filter { model.earned[$0.id] != nil }.count) / \(awards.count)").font(StudyTheme.body(13, .heavy)).foregroundStyle(StudyTheme.muted).monospacedDigit()
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10, alignment: .top)], spacing: 18) {
                                ForEach(awards) { award in
                                    let earned = model.earned[award.id] != nil
                                    Button { StudySound.pick.play(); opened = award } label: {
                                        VStack(spacing: 8) {
                                            StudyMedal(award: award, earned: earned, progress: model.facts.progress(award), size: 78).frame(height: 96)
                                            Text(award.name).font(StudyTheme.body(12, .heavy)).foregroundStyle(earned ? StudyTheme.ink : StudyTheme.muted)
                                                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                                            if !earned {
                                                Text(verbatim: "\(min(model.facts.value(for: award), award.goal)) / \(award.goal)")
                                                    .font(StudyTheme.body(11, .heavy)).foregroundStyle(StudyTheme.primary).monospacedDigit()
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain).accessibilityIdentifier("study.award.\(award.id)")
                                }
                            }
                        }
                        .padding(18).background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(StudyTheme.line, lineWidth: 2) }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background(StudyTheme.background.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .heavy)).foregroundStyle(StudyTheme.muted).frame(width: 40, height: 40)
                        .background(StudyTheme.surface, in: Circle()).overlay { Circle().strokeBorder(StudyTheme.line, lineWidth: 2) }
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("Close")).accessibilityIdentifier("study.awards.close")
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 8).background(StudyTheme.background)
        }
        .tint(StudyTheme.primary)
        .sheet(item: $opened) { award in
            StudyAwardDetail(award: award, record: model.earned[award.id], facts: model.facts, family: all.filter { $0.family == award.family }, earned: model.earned)
                .presentationDetents([.medium, .large]).presentationBackground(StudyTheme.background)
        }
    }
}

/// One badge up close. It tilts under a finger, as a medal turned over in the hand would.
struct StudyAwardDetail: View {
    let award: StudyAward
    let record: StudyAwardRecord?
    let facts: StudyFacts
    let family: [StudyAward]
    let earned: [String: StudyAwardRecord]
    @State private var tilt = CGSize.zero
    @State private var shown = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StudyMedal(award: award, earned: record != nil, progress: facts.progress(award), size: 168)
                    .rotation3DEffect(.degrees(Double(tilt.width) / 4), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    .rotation3DEffect(.degrees(Double(-tilt.height) / 4), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                    .gesture(DragGesture().onChanged { tilt = CGSize(width: max(-120, min(120, $0.translation.width)), height: max(-120, min(120, $0.translation.height))) }
                        .onEnded { _ in withAnimation(.spring(duration: 0.7, bounce: 0.6)) { tilt = .zero } })
                    .studyPop(shown, from: 0.3)
                    .overlay { if record != nil { StudyBurst(trigger: shown ? 1 : 0, count: 20, reach: 120, colors: [StudyTheme.gold, .white, StudyTheme.primary]) } }
                    .padding(.top, 30).padding(.bottom, 6)
                Text(award.name).font(StudyTheme.title(26)).foregroundStyle(StudyTheme.ink).multilineTextAlignment(.center).accessibilityIdentifier("study.award.name")
                Text(award.explanation).font(StudyTheme.body(16, .medium)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center)
                if let record {
                    Label(L10n.text("Earned on %@", record.earned.formatted(.dateTime.year().month().day().locale(Locale(identifier: L10n.language)))), systemImage: "checkmark.seal.fill")
                        .font(StudyTheme.body(14, .heavy)).foregroundStyle(StudyTheme.good)
                } else {
                    VStack(spacing: 6) {
                        StudyBar(value: facts.progress(award), color: StudyTheme.primary, height: 14)
                        Text(verbatim: "\(min(facts.value(for: award), award.goal)) / \(award.goal)").font(StudyTheme.body(14, .heavy)).foregroundStyle(StudyTheme.primary).monospacedDigit()
                    }.padding(.horizontal, 24)
                }
                if family.count > 1, award.family != .sections {
                    // The rest of the family, so that the next rung is in sight.
                    HStack(spacing: 14) {
                        ForEach(family) { other in
                            StudyMedal(award: other, earned: earned[other.id] != nil, progress: facts.progress(other), size: 46, shines: false)
                                .opacity(other.id == award.id ? 1 : 0.75)
                                .overlay(alignment: .bottom) { if other.id == award.id { Capsule().fill(StudyTheme.primary).frame(width: 18, height: 4).offset(y: 12) } }
                        }
                    }.padding(.top, 14)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity)
        }
        .onAppear { shown = true }
    }
}

// MARK: - The moment it is earned

/// A full page for a badge just earned: it spins in, lands, and the light catches it.
struct StudyAwardCelebration: View {
    let award: StudyAward
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let metal = StudyMetal(award)
        VStack(spacing: 20) {
            Spacer(minLength: 20)
            Text(L10n.text("Achievement Unlocked!")).font(StudyTheme.body(16, .heavy)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(LinearGradient(colors: [StudyTheme.gold, StudyTheme.flame], startPoint: .leading, endPoint: .trailing), in: Capsule())
                .studyPop(shown, delay: 0.5)
            ZStack {
                ForEach(0..<14, id: \.self) { index in
                    Capsule().fill(metal.mid.opacity(0.28)).frame(width: 12, height: 190).offset(y: -95).rotationEffect(.degrees(Double(index) * 360 / 14))
                }
                .rotationEffect(.degrees(shown && !reduceMotion ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 28).repeatForever(autoreverses: false), value: shown)
                .scaleEffect(shown ? 1 : 0.1).opacity(shown ? 1 : 0)
                .animation(.spring(duration: 0.7, bounce: 0.3).delay(0.25), value: shown)
                StudyMedal(award: award, size: 190)
                    .rotation3DEffect(.degrees(shown || reduceMotion ? 0 : 900), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    .scaleEffect(shown ? 1 : 0.15).offset(y: shown ? 0 : -260)
                    .animation(.spring(duration: 1.0, bounce: 0.35), value: shown)
            }
            .frame(width: 240, height: 250)
            .overlay { StudyBurst(trigger: shown ? 1 : 0, count: 30, reach: 170, colors: [metal.mid, metal.light, StudyTheme.gold, .white]) }
            Text(award.name).font(StudyTheme.title(32)).foregroundStyle(StudyTheme.ink).multilineTextAlignment(.center)
                .studyRise(shown, delay: 0.7).accessibilityIdentifier("study.milestone")
            Text(award.explanation).font(StudyTheme.body(17, .medium)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center)
                .studyRise(shown, delay: 0.8)
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        .overlay(alignment: .top) { if !reduceMotion { StudyConfetti(pieces: 120).allowsHitTesting(false).accessibilityHidden(true) } }
        .sensoryFeedback(.success, trigger: shown)
        .onAppear { shown = true; StudySound.levelup.play() }
    }
}

/// Badges earned away from a lesson, such as by generating a picture, are celebrated one after another on return.
struct StudyAwardParade: View {
    let awards: [StudyAward]
    let done: () -> Void
    @State private var page = 0
    var body: some View {
        ZStack {
            if awards.indices.contains(page) {
                StudyAwardCelebration(award: awards[page]).id(page)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyTheme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StudyMainButton(title: L10n.text("Continue")) { StudySound.tap.play(); if page + 1 < awards.count { page += 1 } else { done() } }
                .frame(maxWidth: 560).padding(.horizontal, 18).padding(.vertical, 10).frame(maxWidth: .infinity).accessibilityIdentifier("study.done")
        }
    }
}
