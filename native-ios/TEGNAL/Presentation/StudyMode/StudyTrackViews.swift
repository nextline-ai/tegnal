import SwiftUI

/// Chooses between the main path and the tracks that add-ons bring. Shown only while a track is on.
struct StudyTrackPicker: View {
    let model: StudyModeModel
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(id: nil, title: L10n.text("Main Track"), symbol: "map.fill", color: StudyTheme.primary, done: false)
                ForEach(model.tracks) { track in
                    chip(id: track.id, title: track.title.resolved(), symbol: track.symbol, color: Color(studyHex: track.color), done: track.complete(model.records))
                }
            }.padding(.horizontal, 18).padding(.bottom, 6)
        }
        .accessibilityIdentifier("study.tracks")
    }

    private func chip(id: String?, title: String, symbol: String, color: Color, done: Bool) -> some View {
        let chosen = model.trackID == id
        return Button {
            StudySound.tap.play()
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { model.trackID = id }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark.seal.fill" : symbol)
                Text(title).lineLimit(1)
            }
            .font(StudyTheme.body(14, .heavy)).padding(.horizontal, 14).padding(.vertical, 9)
        }
        .buttonStyle(StudyPressStyle(color: color, radius: 16, depth: 4, outlined: !chosen))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityValue(done ? L10n.text("Track Completed") : "")
        .accessibilityIdentifier("study.track." + (id ?? "main"))
    }
}

/// What a track is, how far along it is, and its seal once every lesson is done.
struct StudyTrackHeader: View {
    let track: StudyTrack
    let records: [String: StudyLessonRecord]
    var body: some View {
        let lessons = track.path.lessons
        let done = lessons.filter { records[$0.id] != nil }.count
        let color = Color(studyHex: track.color)
        StudyCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: track.symbol).font(.system(size: 22, weight: .heavy)).foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title.resolved()).font(StudyTheme.title(20)).foregroundStyle(StudyTheme.ink)
                        Text(L10n.text("Add-on Track")).font(StudyTheme.body(12, .bold)).foregroundStyle(StudyTheme.muted)
                    }
                    Spacer()
                    if done == lessons.count {
                        Label(L10n.text("Completed"), systemImage: "checkmark.seal.fill")
                            .font(StudyTheme.body(13, .heavy)).foregroundStyle(StudyTheme.good)
                            .accessibilityIdentifier("study.track.completed")
                    }
                }
                Text(track.summary.resolved()).font(StudyTheme.body(14, .medium)).foregroundStyle(StudyTheme.muted)
                HStack(spacing: 8) {
                    StudyBar(value: lessons.isEmpty ? 0 : Double(done) / Double(lessons.count), color: color, height: 10)
                    Text("\(done)/\(lessons.count)").font(StudyTheme.body(13, .heavy)).foregroundStyle(StudyTheme.muted).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .combine).accessibilityIdentifier("study.track.header")
    }
}

/// The page that marks a track finished: every one of its lessons done.
struct StudyTrackCertificate: View {
    let track: StudyTrack
    let close: () -> Void
    @State private var shown = false
    var body: some View {
        let color = Color(studyHex: track.color)
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(color.opacity(0.16)).frame(width: 190, height: 190)
                Image(systemName: "checkmark.seal.fill").font(.system(size: 96, weight: .bold)).foregroundStyle(color)
                    .scaleEffect(shown ? 1 : 0.3).opacity(shown ? 1 : 0)
                StudyBurst(trigger: 1, count: 30, reach: 150, onAppear: true)
            }
            VStack(spacing: 8) {
                Text(L10n.text("Track Completed")).font(StudyTheme.body(16, .heavy)).foregroundStyle(color)
                Text(track.title.resolved()).font(StudyTheme.title(30)).foregroundStyle(StudyTheme.ink).multilineTextAlignment(.center)
                    .accessibilityIdentifier("study.track.certificate")
                Text(L10n.text("You finished every lesson of this track.")).font(StudyTheme.body(16, .medium)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center)
            }.padding(.horizontal, 28)
            Spacer()
            StudyMainButton(title: L10n.text("Continue"), color: color, action: close)
                .accessibilityIdentifier("study.done")
                .padding(.horizontal, 22).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyTheme.background.ignoresSafeArea())
        .onAppear {
            StudySound.complete.play()
            withAnimation(.spring(duration: 0.6, bounce: 0.45)) { shown = true }
        }
    }
}
