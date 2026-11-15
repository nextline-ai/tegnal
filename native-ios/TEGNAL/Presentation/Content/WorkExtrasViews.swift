import SwiftUI

/// Rating, how often a work is kept, who uploaded it and comments, on websites that keep them,
/// with the account's actions in a box of rows. Nothing shows for websites that don't.
struct WorkExtrasSection: View {
    @Environment(AppEnvironment.self) private var env
    let galleryID: Int64
    let source: any ContentProviding
    @State private var extras: WorkExtras?
    @State private var showsComments = false
    @State private var votingTags = false
    @State private var writingComment = false
    @State private var showsArchive = false
    @State private var rating: String?
    @State private var rateError: String?

    private var provider: (any WorkExtrasProviding)? { source as? any WorkExtrasProviding }

    var body: some View {
        // A stack, not a Group: a Group with nothing to show yet has no view to start the load from.
        VStack(alignment: .leading, spacing: 0) {
            if let extras, Self.hasContent(extras) {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        ratingRow(extras)
                        FlowLayout(spacing: 6) { stats(extras) }
                    }.padding(.horizontal, GalleryDetailInset.text)
                    if !extras.comments.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("Comments")).font(.headline).padding(.horizontal, GalleryDetailInset.text)
                            // One box, its corners the same as every other box on the page.
                            VStack(spacing: 0) {
                                ForEach(Array(Self.preview(extras.comments).enumerated()), id: \.element.id) { index, comment in
                                    if index > 0 { Divider().padding(.horizontal, GalleryDetailInset.text) }
                                    WorkCommentRow(comment: comment, lineLimit: 4)
                                        .padding(.horizontal, GalleryDetailInset.text).padding(.vertical, 12)
                                }
                            }
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: GalleryDetailInset.boxRadius, style: .continuous))
                        }
                    }
                    let actions = actions(extras)
                    if !actions.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                                if index > 0 { Divider().padding(.leading, GalleryDetailInset.iconColumn).padding(.trailing, GalleryDetailInset.text) }
                                Button(action: action.open) {
                                    HStack(spacing: 0) {
                                        Image(systemName: action.icon).foregroundStyle(Color.accentColor).frame(width: GalleryDetailInset.iconColumn)
                                        Text(action.title).foregroundStyle(Color.accentColor)
                                        Spacer(minLength: 8)
                                    }
                                    .padding(.trailing, GalleryDetailInset.text)
                                    .frame(minHeight: GalleryDetailInset.rowHeight).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).accessibilityIdentifier(action.id)
                            }
                        }
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: GalleryDetailInset.boxRadius, style: .continuous))
                    }
                }
                .accessibilityIdentifier("content.detail.extras")
            }
        }
        .task(id: galleryID) {
            guard let provider else { return }
            let value = try? await provider.extras(galleryID)
            if !Task.isCancelled { extras = value }
        }
        .appSheet(isPresented: $showsComments) {
            WorkCommentsView(galleryID: galleryID, initial: extras?.comments ?? [], loadsAll: extras?.hasMoreComments == true, provider: provider)
        }
        .appSheet(isPresented: $votingTags) {
            WorkTagVotesView(galleryID: galleryID, votes: extras?.tagVotes ?? [], provider: provider) { extras?.tagVotes = $0 }
        }
        .appSheet(isPresented: $writingComment) {
            WorkCommentComposer(galleryID: galleryID, provider: provider) { comments in
                extras?.comments = comments
                extras?.hasMoreComments = false
            }
        }
        .appSheet(isPresented: $showsArchive) {
            WorkArchiveView(galleryID: galleryID, provider: provider)
        }
        .alert(L10n.text("Unable to Rate"), isPresented: Binding(get: { rateError != nil }, set: { if !$0 { rateError = nil } })) {
            Button(L10n.text("OK"), role: .cancel) {}
        } message: { Text(rateError ?? "") }
    }

    static func hasContent(_ extras: WorkExtras) -> Bool {
        extras.rating != nil || extras.favorited != nil || extras.uploader != nil || extras.fileSize != nil || !extras.comments.isEmpty
            || extras.canComment || extras.canRate
    }

    private struct Action: Identifiable {
        let id: String
        let title: String
        let icon: String
        let open: () -> Void
    }

    /// Comments first, then what the account can do on the website.
    private func actions(_ extras: WorkExtras) -> [Action] {
        var actions: [Action] = []
        if !extras.comments.isEmpty {
            actions.append(Action(id: "content.detail.comments", title: L10n.text("All Comments"), icon: "text.bubble") { showsComments = true })
        }
        if extras.canComment && provider != nil {
            actions.append(Action(id: "content.detail.writeComment", title: L10n.text("Write Comment"), icon: "square.and.pencil") { writingComment = true })
        }
        // The page hands its rating key, and so its votes and archives, only to a signed-in account.
        if extras.canRate && !extras.tagVotes.isEmpty && provider != nil {
            actions.append(Action(id: "content.detail.voteTags", title: L10n.text("Vote on Tags"), icon: "hand.thumbsup") { votingTags = true })
        }
        if extras.canRate && extras.archiveURL != nil && provider != nil {
            actions.append(Action(id: "content.detail.archive", title: L10n.text("Archive Download"), icon: "archivebox") { showsArchive = true })
        }
        return actions
    }

    /// The uploader's note first, then the best-scored comments.
    static func preview(_ comments: [WorkComment]) -> [WorkComment] {
        let note = comments.filter(\.isUploader)
        let others = comments.filter { !$0.isUploader }.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        return Array((note + others).prefix(2))
    }

    @ViewBuilder private func ratingRow(_ extras: WorkExtras) -> some View {
        let canRate = extras.canRate && env.siteAccountSignedIn && provider != nil
        let content = HStack(spacing: 8) {
            WorkRatingStars(rating: extras.rating ?? 0).font(.subheadline)
            if let value = extras.rating {
                Text(value.formatted(.number.precision(.fractionLength(2)))).font(.subheadline.weight(.semibold).monospacedDigit())
            } else {
                Text(L10n.text("Not Rated Yet")).font(.subheadline).foregroundStyle(.secondary)
            }
            if let count = extras.ratingCount {
                Text(L10n.text("%@ ratings", count.formatted())).font(.subheadline).foregroundStyle(.secondary)
            }
            if rating != nil { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
            if canRate { Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary) }
        }
        if canRate {
            Menu {
                ForEach((1...10).reversed(), id: \.self) { halfStars in
                    Button { rate(halfStars) } label: {
                        Text(String(repeating: "★", count: halfStars / 2) + (halfStars % 2 == 1 ? "½" : "")
                             + " " + (Double(halfStars) / 2).formatted(.number.precision(.fractionLength(1))))
                    }
                }
            } label: { content.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Rate This Work"))
            .accessibilityIdentifier("content.detail.rate")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func stats(_ extras: WorkExtras) -> some View {
        if let favorited = extras.favorited {
            stat(L10n.text("%@ favorites", favorited.formatted()), systemImage: "heart")
        }
        if let name = extras.favoriteName, extras.favoriteCategory != nil {
            stat(name, systemImage: "heart.fill", tint: .pink)
        }
        if let size = extras.fileSize { stat(size, systemImage: "internaldrive") }
        if let posted = extras.posted { stat(posted.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar") }
        if let uploader = extras.uploader { stat(uploader, systemImage: "person") }
    }

    private func stat(_ text: String, systemImage: String, tint: Color = .secondary) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote).lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1), in: Capsule())
    }

    private func rate(_ halfStars: Int) {
        guard let provider else { return }
        rating = String(halfStars)
        Task {
            defer { rating = nil }
            do {
                let result = try await provider.rate(galleryID, halfStars: halfStars)
                extras?.rating = result.average
                extras?.ratingCount = result.count
            } catch { rateError = ContentError.message(error) }
        }
    }
}

struct WorkRatingStars: View {
    let rating: Double
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                let value = rating - Double(index)
                Image(systemName: value >= 0.75 ? "star.fill" : value >= 0.25 ? "star.leadinghalf.filled" : "star")
            }
        }
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
    }
}

struct WorkCommentRow: View {
    let comment: WorkComment
    var lineLimit: Int? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(comment.author).font(.subheadline.weight(.semibold)).lineLimit(1)
                if comment.isUploader {
                    Text(L10n.text("Uploader")).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 4)
                if let score = comment.score {
                    Text(score > 0 ? "+\(score)" : String(score))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(score > 0 ? Color.green : score < 0 ? Color.red : Color.secondary)
                }
            }
            if let posted = comment.posted {
                Text(posted.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Text(comment.text).font(.callout).lineLimit(lineLimit).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkCommentsView: View {
    @Environment(\.dismiss) private var dismiss
    let galleryID: Int64
    let initial: [WorkComment]
    let loadsAll: Bool
    let provider: (any WorkExtrasProviding)?
    @State private var comments: [WorkComment]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let comments {
                    if comments.isEmpty {
                        ContentUnavailableView(L10n.text("No Comments"), systemImage: "text.bubble")
                    } else {
                        List(comments) { WorkCommentRow(comment: $0) }.listStyle(.plain)
                    }
                } else if let error {
                    ContentFailureView(message: error) { self.error = nil; Task { await load() } }
                } else { ProgressView() }
            }
            .navigationTitle(L10n.text("Comments")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        guard loadsAll, let provider else { comments = initial; return }
        do { comments = try await provider.allComments(galleryID) }
        catch {
            if initial.isEmpty { self.error = ContentError.message(error) } else { comments = initial }
        }
    }
}

/// The work's tags with the account's votes. A vote decides, with everyone else's, which tags the
/// work keeps on the website; voting against the account's own vote withdraws it.
struct WorkTagVotesView: View {
    let galleryID: Int64
    @State var votes: [WorkTagVote]
    let provider: (any WorkExtrasProviding)?
    let changed: ([WorkTagVote]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var voting: String?
    @State private var failure: String?

    init(galleryID: Int64, votes: [WorkTagVote], provider: (any WorkExtrasProviding)?, changed: @escaping ([WorkTagVote]) -> Void) {
        self.galleryID = galleryID
        _votes = State(initialValue: votes)
        self.provider = provider
        self.changed = changed
    }

    private var namespaces: [String] {
        var seen = Set<String>()
        return votes.map(\.localNamespace).filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(namespaces, id: \.self) { namespace in
                    Section {
                        ForEach(votes.filter { $0.localNamespace == namespace }) { tag in row(tag) }
                    } header: { Text(namespace.isEmpty ? L10n.text("Tags") : namespace) }
                }
                Section {} footer: { Text(L10n.text("Votes decide, with everyone else’s, which tags the work keeps on the website.")) }
            }
            .navigationTitle(L10n.text("Vote on Tags")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
            .alert(L10n.text("Unable to Vote"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(L10n.text("OK"), role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
    }

    private func row(_ tag: WorkTagVote) -> some View {
        Menu {
            // The menu opens over the row it came from, so it names the tag itself.
            Section(tag.localNamespace.isEmpty ? tag.name : "\(tag.localNamespace): \(tag.name)") {
                if tag.vote == 0 {
                    Button(L10n.text("Vote Up"), systemImage: "hand.thumbsup") { vote(tag, 1) }
                    Button(L10n.text("Vote Down"), systemImage: "hand.thumbsdown") { vote(tag, -1) }
                } else {
                    Button(L10n.text("Withdraw Vote"), systemImage: "arrow.uturn.backward") { vote(tag, -tag.vote) }
                }
            }
        } label: {
            HStack {
                Text(tag.name).foregroundStyle(.primary)
                Spacer()
                if voting == tag.tag { ProgressView().controlSize(.small) }
                else if tag.vote > 0 { Label(L10n.text("Voted Up"), systemImage: "hand.thumbsup.fill").labelStyle(.iconOnly).foregroundStyle(.green) }
                else if tag.vote < 0 { Label(L10n.text("Voted Down"), systemImage: "hand.thumbsdown.fill").labelStyle(.iconOnly).foregroundStyle(.red) }
            }.contentShape(Rectangle())
        }
        .disabled(voting != nil)
        .accessibilityIdentifier("content.tagVote.\(tag.tag)")
    }

    private func vote(_ tag: WorkTagVote, _ vote: Int) {
        guard let provider else { return }
        voting = tag.tag
        Task {
            defer { voting = nil }
            do {
                votes = try await provider.voteTag(galleryID, tag: tag.tag, vote: vote)
                changed(votes)
            } catch { failure = (error as? SiteMessage)?.text ?? ContentError.message(error) }
        }
    }
}

/// Writes a comment under the work, posted on the website under the signed-in account.
struct WorkCommentComposer: View {
    let galleryID: Int64
    let provider: (any WorkExtrasProviding)?
    let posted: ([WorkComment]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var posting = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).frame(minHeight: 180).accessibilityIdentifier("content.comment.text")
                } footer: {
                    Text(L10n.text("Your comment is posted on the website under your account, where everyone can read it."))
                }
            }
            .navigationTitle(L10n.text("Write Comment")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if posting { ProgressView() }
                    else {
                        Button(L10n.text("Post")) { post() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("content.comment.post")
                    }
                }
            }
            .interactiveDismissDisabled(posting || !text.isEmpty)
            .alert(L10n.text("Unable to Post"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(L10n.text("OK"), role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
    }

    private func post() {
        guard let provider else { return }
        posting = true
        Task {
            defer { posting = false }
            do {
                posted(try await provider.postComment(galleryID, text: text))
                dismiss()
            } catch { failure = (error as? SiteMessage)?.text ?? ContentError.message(error) }
        }
    }
}

/// The work's archives as the website offers them, with what each costs the account, and a
/// download of the one chosen, saved wherever the person picks.
struct WorkArchiveView: View {
    let galleryID: Int64
    let provider: (any WorkExtrasProviding)?
    @Environment(\.dismiss) private var dismiss
    @State private var offer: WorkArchiveOffer?
    @State private var failure: String?
    @State private var confirming: WorkArchiveOffer.Option?
    @State private var downloading = false
    @State private var file: URL?

    var body: some View {
        NavigationStack {
            List {
                if let offer {
                    if let funds = offer.funds {
                        Section { LabeledContent(L10n.text("Account Balance"), value: funds) }
                    }
                    Section {
                        ForEach(offer.options) { option in
                            Button { confirming = option } label: {
                                LabeledContent {
                                    Text(option.cost).monospacedDigit()
                                } label: {
                                    Text(L10n.text(option.isOriginal ? "Original Archive" : "Resampled Archive"))
                                    Text(option.size).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!option.available || downloading)
                            .accessibilityIdentifier("content.archive.\(option.kind)")
                        }
                    } footer: {
                        Text(L10n.text("The website takes the cost shown from your account when it prepares the archive. Save the file where you like."))
                    }
                    if downloading {
                        Section { HStack { ProgressView(); Text(L10n.text("Preparing Archive…")) } }
                    }
                    if let file {
                        Section {
                            ShareLink(item: file) { Label(L10n.text("Save or Share Archive"), systemImage: "square.and.arrow.up") }
                                .accessibilityIdentifier("content.archive.share")
                        }
                    }
                } else if let failure {
                    ContentUnavailableView(L10n.text("Unable to Load"), systemImage: "archivebox", description: Text(failure))
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle(L10n.text("Archive Download")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
            .interactiveDismissDisabled(downloading)
            .task { await load() }
            .confirmationDialog(L10n.text("Download This Archive?"), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible, presenting: confirming) { option in
                Button(L10n.text("Download")) { download(option) }
            } message: { option in Text(L10n.text("It costs %@.", option.cost)) }
            .alert(L10n.text("Unable to Download"), isPresented: Binding(get: { failure != nil && offer != nil }, set: { if !$0 { failure = nil } })) {
                Button(L10n.text("OK"), role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
    }

    private func load() async {
        guard let provider else { failure = ContentError.unsupportedFormat.localizedDescription; return }
        do { offer = try await provider.archiveOffer(galleryID) }
        catch { failure = (error as? SiteMessage)?.text ?? ContentError.message(error) }
    }

    private func download(_ option: WorkArchiveOffer.Option) {
        guard let provider else { return }
        downloading = true
        Task {
            defer { downloading = false }
            do {
                let address = try await provider.archiveDownloadURL(galleryID, option: option)
                file = try await ArchiveFile.download(address, name: "\(galleryID)-\(option.kind)")
            } catch { failure = (error as? SiteMessage)?.text ?? ContentError.message(error) }
        }
    }
}

/// An archive the website prepared, downloaded to a file the person can save.
enum ArchiveFile {
    static func download(_ url: URL, name: String) async throws -> URL {
        guard url.scheme == "https", KeyedCatalogSource.safeMediaURL(url) else { throw ContentError.unsupportedFormat }
        var request = URLRequest(url: url)
        request.setValue(ContentTransport.userAgent, forHTTPHeaderField: "User-Agent")
        let (downloaded, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ContentError.unavailable((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("archives", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suggested = response.suggestedFilename.flatMap { $0.lowercased().hasSuffix(".zip") ? $0 : nil } ?? name + ".zip"
        let file = folder.appendingPathComponent(suggested.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: downloaded, to: file)
        return file
    }
}
