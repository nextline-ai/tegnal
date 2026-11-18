import SwiftUI

/// The lessons on writing prompts, listed.
struct StudyGuideView: View {
    @SwiftUI.AppStorage("study.guideFinished", store: ReaderPreferences.booruDefaults) private var stored = ""
    private let guide = StudyGuide.bundled
    var body: some View {
        let finished = StudyGuide.finished(stored)
        List {
            Section {
                ForEach(guide.lessons) { lesson in
                    NavigationLink { StudyLessonView(lesson: lesson) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: lesson.symbol).font(.body).foregroundStyle(StudyStyle.accent)
                                .frame(width: 36, height: 36).background(StudyStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(lesson.title.resolved()).font(.body.weight(.medium))
                                Text(lesson.summary.resolved()).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            if finished.contains(lesson.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel(L10n.text("Learned"))
                            }
                        }.padding(.vertical, 2)
                    }.accessibilityIdentifier("study.lesson.\(lesson.id)")
                }
            } footer: {
                Text(L10n.text("Written from the documentation of NovelAI, the Stable Diffusion web UI and the model cards, as read in %@. Each lesson lists its sources.", guide.checked))
            }
        }
        .listStyle(.insetGrouped).tint(StudyStyle.accent)
        .navigationTitle(L10n.text("Writing Prompts")).navigationBarTitleDisplayMode(.inline)
    }
}

/// Prompt text in a box, copied with a tap.
struct StudyCodeBlock: View {
    let code: String
    var note: String?
    @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.string = code; copied = true
            Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if let note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                HStack(alignment: .top, spacing: 8) {
                    Text(code).font(.callout.monospaced()).foregroundStyle(Color.primary).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption).foregroundStyle(copied ? Color.green : Color.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(code).accessibilityHint(L10n.text("Copy Prompt"))
    }
}

struct StudyLessonView: View {
    let lesson: StudyLesson
    @SwiftUI.AppStorage("study.guideFinished", store: ReaderPreferences.booruDefaults) private var stored = ""
    /// The choice made for each question, by its place in the lesson.
    @State private var chosen: [Int: Int] = [:]

    /// Running text with the words between backticks set as prompt syntax.
    static func text(_ source: String) -> AttributedString {
        var result = AttributedString()
        for (index, piece) in source.components(separatedBy: "`").enumerated() where !piece.isEmpty {
            var part = AttributedString(piece)
            if index % 2 == 1 { part.font = .callout.monospaced().weight(.medium); part.foregroundColor = StudyStyle.accent }
            result += part
        }
        return result
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(lesson.parts.enumerated()), id: \.offset) { _, part in
                    VStack(alignment: .leading, spacing: 10) {
                        if let heading = part.heading?.resolved(), !heading.isEmpty { Text(heading).font(.headline) }
                        if let body = part.body?.resolved(), !body.isEmpty { Text(Self.text(body)).font(.body) }
                        ForEach(part.examples ?? [], id: \.self) { StudyCodeBlock(code: $0.code, note: $0.note?.resolved()) }
                    }.padding(.vertical, 6)
                }
            } header: { Text(lesson.summary.resolved()).textCase(nil) }
            if lesson.tool == "emphasis" { StudyEmphasisTool() }
            if !lesson.checks.isEmpty {
                Section {
                    ForEach(Array(lesson.checks.enumerated()), id: \.offset) { index, check in question(index, check) }
                } header: { Text(L10n.text("Check Yourself")) }
            }
            if !lesson.sources.isEmpty {
                Section(L10n.text("Sources")) {
                    ForEach(lesson.sources, id: \.self) { source in
                        if let url = URL(string: source) {
                            Link(destination: url) {
                                Text(source.replacingOccurrences(of: "https://", with: "")).font(.footnote).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped).tint(StudyStyle.accent)
        .navigationTitle(lesson.title.resolved()).navigationBarTitleDisplayMode(.inline)
        .onChange(of: chosen) { _, value in
            if lesson.checks.indices.allSatisfy({ value[$0] == lesson.checks[$0].answer }) { stored = StudyGuide.finishing(lesson.id, in: stored) }
        }
    }

    private func question(_ index: Int, _ check: StudyLesson.Check) -> some View {
        let picked = chosen[index]
        return VStack(alignment: .leading, spacing: 10) {
            Text(check.question.resolved()).font(.subheadline.weight(.semibold))
            ForEach(Array(check.choices.enumerated()), id: \.offset) { place, choice in
                let color: Color? = picked == nil ? nil : place == check.answer ? .green : place == picked ? .red : nil
                Button { if picked == nil { withAnimation(.snappy) { chosen[index] = place } } } label: {
                    HStack(spacing: 8) {
                        Text(choice).font(.callout.monospaced()).foregroundStyle(Color.primary).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let color { Image(systemName: color == .green ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(color) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background((color ?? .clear).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color ?? .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain).allowsHitTesting(picked == nil)
                .accessibilityIdentifier("study.check.\(index).\(place)")
                .accessibilityValue(color == .green ? L10n.text("Correct") : color == .red ? L10n.text("Incorrect") : "")
            }
            if let picked {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: picked == check.answer ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(picked == check.answer ? Color.green : Color.red)
                    Text(Self.text(check.why.resolved())).font(.footnote).foregroundStyle(.secondary)
                }.accessibilityIdentifier("study.check.\(index).why")
                if picked != check.answer {
                    Button(L10n.text("Try Again")) { withAnimation(.snappy) { chosen[index] = nil } }.font(.footnote)
                }
            }
        }.padding(.vertical, 6)
    }
}

/// Type a tag, set how strongly it should count, and read it in each notation.
struct StudyEmphasisTool: View {
    @State private var words = "rain"
    @State private var weight = 1.2
    var body: some View {
        Section {
            TextField(L10n.text("Tag"), text: $words).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.body.monospaced()).accessibilityIdentifier("study.emphasis.tag")
            Stepper(value: $weight, in: 0.5...2, step: 0.05) {
                HStack { Text(L10n.text("Weight")); Spacer(); Text(StudyEmphasis.number(weight)).monospacedDigit().foregroundStyle(.secondary) }
            }.accessibilityIdentifier("study.emphasis.weight")
            row("NovelAI { }", .braces)
            row("NovelAI ::", .numbered)
            row("Stable Diffusion", .weighted)
        } header: { Text(L10n.text("Try It")) } footer: {
            Text(L10n.text("Braces move in steps of 1.05, so they give the nearest weight they can."))
        }
    }

    private func row(_ title: String, _ kind: StudyEmphasis) -> some View {
        let tag = StudyPrompt.words(StudyDText.tagName(words))
        let real = kind.effective(weight)
        let note = abs(real - weight) > 0.000_1 ? "\(title) · \(StudyEmphasis.number((real * 1000).rounded() / 1000))" : title
        return StudyCodeBlock(code: kind.written(tag, weight: weight), note: note)
            .listRowSeparator(.hidden).accessibilityIdentifier("study.emphasis.\(kind.rawValue)")
    }
}
