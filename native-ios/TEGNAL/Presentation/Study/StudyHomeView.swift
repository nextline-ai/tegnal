import SwiftUI

/// What the study screens show, read again whenever an answer may have changed it.
@MainActor @Observable
final class StudyBoard {
    let curriculum = StudyCurriculum.bundled
    private(set) var progress: [String: StudyProgress] = [:]
    private(set) var summary = StudySummary()
    func reload(_ store: BooruStore) {
        let study = store.studyStore
        progress = (try? study.progress()) ?? [:]
        summary = StudySummary(curriculum: curriculum, progress: progress, days: (try? study.days()) ?? [])
    }
}

enum StudyStyle {
    static let accent = Color.indigo
    static func count(_ value: Int) -> String { value.formatted(.number.notation(.compactName).locale(Locale(identifier: L10n.language))) }
}

/// An icon and a title centred together across a wide button. A `Label` in a list row keeps a column for its icon,
/// which pushes the title off centre.
struct StudyButtonLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View {
        HStack(spacing: 8) { Image(systemName: symbol).imageScale(.small); Text(title) }
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// How far along a tag is: one bar for each step up to "learned".
struct StudyMastery: View {
    let progress: StudyProgress?
    var body: some View {
        let step = min(progress?.step ?? 0, StudyProgress.learnedStep)
        HStack(spacing: 2) {
            ForEach(0..<StudyProgress.learnedStep, id: \.self) { index in
                Capsule().fill(index < step ? (step >= StudyProgress.learnedStep ? Color.green : StudyStyle.accent) : Color(uiColor: .tertiarySystemFill))
                    .frame(width: 5, height: 12)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.text(progress?.isLearned == true ? "Learned" : progress?.isNew == false ? "Learning" : "Not started"))
    }
}

/// The way into tag study, shown at the top of the image library's Tags tab.
struct StudyEntrySection: View {
    let source: any BooruProviding
    @Environment(BooruStore.self) private var store
    @State private var board = StudyBoard()
    private var detail: String {
        let summary = board.summary
        if summary.started == 0 { return L10n.text("Learn the tags image AI is prompted with, from real pictures.") }
        if summary.due > 0 { return L10n.text("%@ to review · %@ of %@ learned", String(summary.due), String(summary.learned), String(summary.total)) }
        return L10n.text("%@ of %@ learned", String(summary.learned), String(summary.total))
    }
    var body: some View {
        Section {
            Button { StudyMode.shared.enter() } label: {
                HStack(spacing: 14) {
                    Image(systemName: "graduationcap.fill").font(.title3).foregroundStyle(StudyStyle.accent)
                        .frame(width: 42, height: 48)
                        .background(StudyStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Tag Study")).font(.headline)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(.vertical, 4).contentShape(Rectangle())
                    .onAppear { board.reload(store) }
            }.buttonStyle(.plain).accessibilityIdentifier("study.entry")
        }
    }
}

/// A reminder on the Smart tab, shown only while tags are due again, so the tab stays as it is for people who do not study.
struct StudyReviewCard: View {
    let source: any BooruProviding
    @Environment(BooruStore.self) private var store
    @State private var board = StudyBoard()
    @State private var session: StudySession?
    var body: some View {
        VStack(spacing: 0) {
            if board.summary.due > 0 {
                Button { StudyMode.shared.enter(.practice) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "graduationcap.fill").font(.body).foregroundStyle(StudyStyle.accent)
                            .frame(width: 36, height: 48).background(StudyStyle.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Tags to Review")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(L10n.text("Tags due again: %@", String(board.summary.due))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "play.fill").font(.caption.weight(.semibold)).foregroundStyle(StudyStyle.accent)
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityIdentifier("study.reviewCard").padding(.bottom, 12)
            }
        }
        .onAppear { board.reload(store) }
        .appFullScreenCover(item: $session, onDismiss: { board.reload(store) }) { StudyQuizView(session: $0, source: source) }
    }
}

struct StudyHomeView: View {
    let source: any BooruProviding
    @Environment(BooruStore.self) private var store
    @State private var board = StudyBoard()
    @State private var session: StudySession?
    @State private var search = ""
    @State private var confirmingReset = false

    private var matches: [StudyTag] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        let name = text.replacingOccurrences(of: " ", with: "_")
        guard !text.isEmpty else { return [] }
        let all = board.curriculum.tags
        let starts = all.filter { $0.name.hasPrefix(name) }
        let rest = all.filter { tag in
            !tag.name.hasPrefix(name) && (tag.name.contains(name) || (tag.ko ?? "").contains(text) || (tag.ja ?? "").lowercased().contains(text))
        }
        return Array((starts + rest).prefix(60))
    }

    var body: some View {
        List {
            if search.isEmpty { home } else { results }
        }
        .listStyle(.insetGrouped).tint(StudyStyle.accent)
        .navigationTitle(L10n.text("Tag Study")).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: L10n.text("Search tags"))
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L10n.text("Reset Study Progress"), systemImage: "arrow.counterclockwise", role: .destructive) { confirmingReset = true }
                        .disabled(board.summary.started == 0)
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel(L10n.text("More")).accessibilityIdentifier("study.more")
            }
        }
        .confirmationDialog(L10n.text("Reset study progress?"), isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(L10n.text("Reset"), role: .destructive) { try? store.studyStore.reset(); board.reload(store) }
        } message: { Text(L10n.text("Every tag goes back to not started. This cannot be undone.")) }
        .appFullScreenCover(item: $session, onDismiss: { board.reload(store) }) { StudyQuizView(session: $0, source: source) }
        .onAppear { board.reload(store) }
    }

    @ViewBuilder private var home: some View {
        Section {
            summary.listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            Button { start(.today) } label: {
                StudyButtonLabel(L10n.text(board.summary.started == 0 ? "Start Learning" : "Today's Study"), symbol: "play.fill")
                    .font(.headline).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).tint(StudyStyle.accent).accessibilityIdentifier("study.start")
                .listRowSeparator(.hidden, edges: .bottom)
            if board.summary.due > 0 {
                Button { start(.review) } label: {
                    StudyButtonLabel(L10n.text("Review Only (%@)", String(board.summary.due)), symbol: "arrow.triangle.2.circlepath")
                }.accessibilityIdentifier("study.review")
            }
        } footer: {
            if store.selectedServers.isEmpty {
                Text(L10n.text("Choose a server to be asked with real pictures. Without one, questions ask by meaning only."))
            }
        }
        Section(L10n.text("Prompts")) {
            NavigationLink { StudyGuideView() } label: {
                linkRow("text.book.closed", L10n.text("Writing Prompts"), L10n.text("Emphasis, quality tags and what each model recommends."))
            }.accessibilityIdentifier("study.guide")
            NavigationLink { GeneratorView() } label: {
                linkRow("wand.and.stars", L10n.text("Generate a Picture"), L10n.text("Try a prompt with your own Civitai API key."))
            }.accessibilityIdentifier("study.generator")
        }
        Section(L10n.text("Units")) {
            ForEach(board.curriculum.units) { unit in
                NavigationLink { StudyUnitView(unit: unit, source: source, board: board) } label: { unitRow(unit) }
                    .accessibilityIdentifier("study.unit.\(unit.id)")
            }
        }
        Section {} footer: {
            Text(L10n.text("Anime image generators learned from pictures tagged this way. The more posts a tag has, the better such a model tends to follow it."))
        }
    }

    @ViewBuilder private var results: some View {
        let name = StudyDText.tagName(search)
        Section {
            ForEach(matches) { tag in
                NavigationLink { StudyTagView(name: tag.name, source: source) } label: { StudyTagRow(tag: tag, progress: board.progress[tag.name], count: nil) }
            }
            // Any tag can be looked up, taught here or not.
            if !name.isEmpty, !board.curriculum.contains(name), !store.selectedServers.isEmpty {
                NavigationLink { StudyTagView(name: name, source: source) } label: {
                    Label(L10n.text("Look up “%@” on the server", name), systemImage: "magnifyingglass")
                }.accessibilityIdentifier("study.lookup")
            }
        }
    }

    private var summary: some View {
        let value = board.summary
        return HStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 9)
                Circle().trim(from: 0, to: value.total == 0 ? 0 : CGFloat(value.learned) / CGFloat(value.total))
                    .stroke(StudyStyle.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(String(value.learned)).font(.title2.weight(.bold)).monospacedDigit()
                    Text("/ " + String(value.total)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }.frame(width: 88, height: 88)
                .accessibilityElement().accessibilityLabel(L10n.text("%@ of %@ learned", String(value.learned), String(value.total)))
            VStack(alignment: .leading, spacing: 10) {
                stat("arrow.triangle.2.circlepath", L10n.text("To review"), String(value.due))
                stat("checkmark.circle", L10n.text("Answered today"), String(value.today))
                stat("flame", L10n.text("Day streak"), String(value.streak))
            }
            Spacer(minLength: 0)
        }
    }

    private func stat(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.footnote).foregroundStyle(StudyStyle.accent).frame(width: 18)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }

    private func linkRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.body).foregroundStyle(StudyStyle.accent)
                .frame(width: 36, height: 36).background(StudyStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }.padding(.vertical, 2)
    }

    private func unitRow(_ unit: StudyUnit) -> some View {
        let state = StudySummary.unit(unit, progress: board.progress)
        return HStack(spacing: 14) {
            Image(systemName: unit.symbol).font(.body).foregroundStyle(StudyStyle.accent)
                .frame(width: 36, height: 36).background(StudyStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(unit.title.resolved()).font(.body.weight(.medium))
                Text(unit.summary.resolved()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(state.learned)/\(state.total)").font(.footnote).monospacedDigit()
                .foregroundStyle(state.learned == state.total && state.total > 0 ? Color.green : Color.secondary)
        }.padding(.vertical, 2)
    }

    private func start(_ scope: StudyScope) {
        session = StudySession(scope: scope, store: store, source: source)
    }
}

struct StudyTagRow: View {
    let tag: StudyTag
    let progress: StudyProgress?
    let count: Int?
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(tag.english).font(.body.weight(.semibold))
                    if L10n.language != "en" { Text(tag.title()).font(.subheadline).foregroundStyle(.secondary) }
                }.lineLimit(1)
                Text(tag.note.resolved()).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                StudyMastery(progress: progress)
                if let count { Text(StudyStyle.count(count)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
            }
        }.padding(.vertical, 2)
    }
}

struct StudyUnitView: View {
    let unit: StudyUnit
    let source: any BooruProviding
    let board: StudyBoard
    @Environment(BooruStore.self) private var store
    @State private var counts: [String: Int] = [:]
    @State private var session: StudySession?
    var body: some View {
        List {
            Section {
                Text(unit.summary.resolved()).font(.subheadline).foregroundStyle(.secondary)
                Button { session = StudySession(scope: .unit(unit.id), store: store, source: source) } label: {
                    StudyButtonLabel(L10n.text("Quiz This Unit"), symbol: "play.fill").font(.headline).padding(.vertical, 4)
                }.buttonStyle(.borderedProminent).tint(StudyStyle.accent).accessibilityIdentifier("study.unitQuiz")
            }
            ForEach(unit.groups) { group in
                Section(group.title.resolved()) {
                    ForEach(group.tags) { tag in
                        NavigationLink { StudyTagView(name: tag.name, source: source) } label: {
                            StudyTagRow(tag: tag, progress: board.progress[tag.name], count: counts[tag.name])
                        }.accessibilityIdentifier("study.tag.\(tag.name)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped).tint(StudyStyle.accent)
        .navigationTitle(unit.title.resolved()).navigationBarTitleDisplayMode(.inline)
        .appFullScreenCover(item: $session, onDismiss: { board.reload(store) }) { StudyQuizView(session: $0, source: source) }
        .onAppear { board.reload(store) }
        .task(id: store.selectedServerIDs) { counts = await StudyLookup.counts(unit.tags.map(\.name), store: store, source: source) }
    }
}
