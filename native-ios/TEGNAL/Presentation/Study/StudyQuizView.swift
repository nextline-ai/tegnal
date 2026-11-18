import SwiftUI

/// One round of questions, shown over the whole screen.
struct StudyQuizView: View {
    @State var session: StudySession
    let source: any BooruProviding
    @Environment(BooruStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var opened: StudyTag?
    @State private var board = StudyBoard()
    /// How things stood when the round began, so the results can show what the round changed.
    @State private var before: StudySummary?
    private var answered: Int? { if case .answered(let choice) = session.phase { return choice } else { return nil } }

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .finished: StudyResultView(session: session, before: before ?? board.summary, after: board.summary, open: { opened = $0 }, again: again, done: { dismiss() })
                case .loading where session.question == nil: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                default: if let question = session.question { asking(question) }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { dismiss() }.accessibilityIdentifier("study.close") }
                ToolbarItem(placement: .principal) {
                    if session.phase != .finished, !session.tags.isEmpty {
                        ProgressView(value: Double(session.index + (answered == nil ? 0 : 1)), total: Double(session.tags.count))
                            .tint(StudyStyle.accent).frame(width: 160)
                            .accessibilityLabel(L10n.text("Question %@ of %@", String(session.index + 1), String(session.tags.count)))
                    }
                }
            }
            .navigationDestination(item: $opened) { StudyTagView(name: $0.name, source: source) }
        }
        .tint(StudyStyle.accent)
        .task(id: session.id) { board.reload(store); before = board.summary; await session.start() }
        .onChange(of: session.phase) { _, phase in if phase == .finished { board.reload(store) } }
    }

    // MARK: Asking

    private func asking(_ question: StudyQuestion) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 18) {
                Color.clear.frame(height: 0).id("top")
                switch question.kind {
                case .pictureToTag:
                    if let post = question.posts.first, let server = store.servers.first(where: { $0.id == post.serverID }) {
                        StudyPicture(post: post, server: server)
                            .aspectRatio(aspect(post), contentMode: .fit).frame(maxHeight: sizeClass == .regular ? 520 : 320)
                            .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("study.picture")
                    }
                    prompt(L10n.text("Which tag does this picture carry?"))
                    choices(question)
                case .meaningToTag:
                    Text(question.tag.note.resolved()).font(.title3.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    prompt(L10n.text("Which tag means this?"))
                    choices(question)
                case .tagToPicture:
                    Text(question.tag.english).font(.title.weight(.bold)).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                    prompt(L10n.text("Which picture carries this tag?"))
                    pictures(question)
                }
                if answered != nil { explanation(question).id("explanation") }
            }
            .frame(maxWidth: 640).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        // The meaning of the right answer is the lesson, so it is brought into view once an answer is given.
        .onChange(of: answered) { _, value in
            guard value != nil else { return }
            Task { try? await Task.sleep(for: .milliseconds(120)); withAnimation(.snappy) { proxy.scrollTo("explanation", anchor: .bottom) } }
        }
        .onChange(of: question.id) { proxy.scrollTo("top", anchor: .top) }
        .safeAreaInset(edge: .bottom) {
            if answered != nil {
                Button { Task { await session.advance() } } label: {
                    Text(L10n.text(session.index + 1 >= session.tags.count ? "See Results" : "Next")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("study.next")
                    .frame(maxWidth: 640).padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: .infinity).background(.bar)
            }
        }
        .disabled(session.phase == .loading)
        .animation(.snappy(duration: 0.22), value: session.phase)
        }
    }

    private func aspect(_ post: BooruPost) -> CGFloat {
        guard post.width > 0, post.height > 0 else { return 1 }
        return min(2, max(0.6, CGFloat(post.width) / CGFloat(post.height)))
    }

    private func prompt(_ text: String) -> some View {
        Text(text).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mark(_ index: Int, _ question: StudyQuestion) -> Color? {
        guard let answered else { return nil }
        if index == question.answer { return .green }
        return index == answered ? .red : nil
    }

    /// Tags are asked in the words a prompt is written in, so no translated name is shown beside them.
    /// Short tags share a line two by two; a long one keeps a line to itself.
    private func choices(_ question: StudyQuestion) -> some View {
        let limit = typeSize.isAccessibilitySize ? 0 : sizeClass == .regular ? 22 : 13
        return VStack(spacing: 10) {
            ForEach(StudyQuestion.rows(question.choices.map(\.english.count), limit: limit), id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { index in choice(index, question, paired: row.count > 1) }
                }
            }
        }
    }

    private func choice(_ index: Int, _ question: StudyQuestion, paired: Bool) -> some View {
        let color = mark(index, question)
        let symbol = color.map { Image(systemName: $0 == .green ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle($0) }
        return Button { session.choose(index) } label: {
            HStack(spacing: 10) {
                Text(question.choices[index].english).font(.title3.weight(.semibold)).foregroundStyle(Color.primary)
                    .lineLimit(2).minimumScaleFactor(0.75).multilineTextAlignment(paired ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: paired ? .center : .leading)
                if !paired, let symbol { symbol.font(.title3) }
            }
            .padding(.horizontal, paired ? 10 : 16).padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: 58)
            .background((color ?? .clear).opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color ?? .clear, lineWidth: 1.5))
            .overlay(alignment: .topTrailing) { if paired, let symbol { symbol.font(.subheadline).padding(6) } }
        }.buttonStyle(.plain).allowsHitTesting(answered == nil)
            .accessibilityIdentifier("study.choice.\(index)")
            .accessibilityValue(color == .green ? L10n.text("Correct") : color == .red ? L10n.text("Incorrect") : "")
    }

    private func pictures(_ question: StudyQuestion) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Array(question.posts.enumerated()), id: \.element.id) { index, post in
                let color = mark(index, question)
                Button { session.choose(index) } label: {
                    Group {
                        if let server = store.servers.first(where: { $0.id == post.serverID }) { StudyPicture(post: post, server: server, fills: true) }
                        else { Color(uiColor: .tertiarySystemFill) }
                    }
                    .frame(maxWidth: .infinity).aspectRatio(0.8, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color ?? .clear, lineWidth: 4))
                    .overlay(alignment: .topTrailing) {
                        if let color {
                            Image(systemName: color == .green ? "checkmark.circle.fill" : "xmark.circle.fill").font(.title2)
                                .symbolRenderingMode(.palette).foregroundStyle(.white, color).padding(8)
                        }
                    }
                }.buttonStyle(.plain).allowsHitTesting(answered == nil)
                    .accessibilityIdentifier("study.choice.\(index)")
                    .accessibilityLabel(L10n.text("Picture %@", String(index + 1)))
            }
        }
    }

    /// After an answer: what the right tag means, and what the chosen one means when it was wrong.
    private func explanation(_ question: StudyQuestion) -> some View {
        let right = answered == question.answer
        let chosen = answered.flatMap { question.kind == .tagToPicture ? nil : question.choices.indices.contains($0) ? question.choices[$0] : nil }
        return VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text(right ? "Correct" : "Incorrect"), systemImage: right ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.headline).foregroundStyle(right ? Color.green : Color.red).accessibilityIdentifier("study.verdict")
            meaning(question.tag)
            if !right, let chosen, chosen.name != question.tag.name { Divider(); meaning(chosen) }
            Button { opened = question.tag } label: { Label(L10n.text("About This Tag"), systemImage: "info.circle").font(.subheadline) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func meaning(_ tag: StudyTag) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tag.english).font(.subheadline.weight(.semibold))
            Text(tag.note.resolved()).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func again() {
        board.reload(store); before = board.summary
        session = StudySession(scope: session.scope, store: store, source: source)
    }
}
