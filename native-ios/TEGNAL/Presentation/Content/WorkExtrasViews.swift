import SwiftUI

/// Rating, how often a work is kept, who uploaded it, comments and torrents, on websites that
/// keep them. Nothing shows for websites that don't.
struct WorkExtrasSection: View {
    @Environment(AppEnvironment.self) private var env
    let galleryID: Int64
    let source: any ContentProviding
    @State private var extras: WorkExtras?
    @State private var showsComments = false
    @State private var showsTorrents = false
    @State private var rating: String?
    @State private var rateError: String?

    private var provider: (any WorkExtrasProviding)? { source as? any WorkExtrasProviding }

    var body: some View {
        Group {
            if let extras, Self.hasContent(extras) {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()
                    ratingRow(extras)
                    FlowLayout(spacing: 6) { stats(extras) }
                    if !extras.comments.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("Comments")).font(.headline)
                            ForEach(Self.preview(extras.comments)) { comment in
                                WorkCommentRow(comment: comment, lineLimit: 4)
                                    .padding(12)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            Button { showsComments = true } label: {
                                Label(L10n.text("All Comments"), systemImage: "text.bubble")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).accessibilityIdentifier("content.detail.comments")
                        }
                    }
                    if extras.torrentCount > 0 {
                        Button { showsTorrents = true } label: {
                            Label(L10n.text("Torrents (%@)", String(extras.torrentCount)), systemImage: "arrow.down.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).accessibilityIdentifier("content.detail.torrents")
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
        .appSheet(isPresented: $showsTorrents) {
            WorkTorrentsView(galleryID: galleryID, provider: provider)
        }
        .alert(L10n.text("Unable to Rate"), isPresented: Binding(get: { rateError != nil }, set: { if !$0 { rateError = nil } })) {
            Button(L10n.text("OK"), role: .cancel) {}
        } message: { Text(rateError ?? "") }
    }

    static func hasContent(_ extras: WorkExtras) -> Bool {
        extras.rating != nil || extras.favorited != nil || extras.uploader != nil || extras.fileSize != nil || !extras.comments.isEmpty || extras.torrentCount > 0
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

struct WorkTorrentsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let galleryID: Int64
    let provider: (any WorkExtrasProviding)?
    @State private var torrents: [WorkTorrent]?
    @State private var error: String?
    @State private var copied: String?

    var body: some View {
        NavigationStack {
            Group {
                if let torrents {
                    if torrents.isEmpty { ContentUnavailableView(L10n.text("No Torrents"), systemImage: "arrow.down.doc") }
                    else {
                        List(torrents) { torrent in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(torrent.name).font(.subheadline.weight(.semibold)).lineLimit(3)
                                Text(details(torrent)).font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    if let magnet = torrent.magnet {
                                        Button(L10n.text("Copy Magnet Link"), systemImage: "link") {
                                            UIPasteboard.general.string = magnet.absoluteString
                                            copied = torrent.id
                                        }
                                    }
                                    ShareLink(item: torrent.url) { Label(L10n.text("Share"), systemImage: "square.and.arrow.up") }
                                }
                                .font(.caption).buttonStyle(.bordered).controlSize(.small)
                                if copied == torrent.id {
                                    Text(L10n.text("Copied")).font(.caption2).foregroundStyle(.green)
                                }
                            }
                            .padding(.vertical, 4)
                            .contextMenu {
                                Button(L10n.text("Open"), systemImage: "safari") { openURL(torrent.url) }
                            }
                        }
                        .listStyle(.plain)
                    }
                } else if let error {
                    ContentFailureView(message: error) { self.error = nil; Task { await load() } }
                } else { ProgressView() }
            }
            .navigationTitle(L10n.text("Torrents")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
            .task { await load() }
        }
    }

    private func details(_ torrent: WorkTorrent) -> String {
        var parts: [String] = []
        if let size = torrent.size { parts.append(size) }
        if let seeds = torrent.seeds { parts.append(L10n.text("Seeds %@", String(seeds))) }
        if let peers = torrent.peers { parts.append(L10n.text("Peers %@", String(peers))) }
        if let downloads = torrent.downloads { parts.append(L10n.text("Downloads %@", String(downloads))) }
        if let posted = torrent.posted { parts.append(posted) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let provider else { torrents = []; return }
        do { torrents = try await provider.torrents(galleryID) }
        catch { self.error = ContentError.message(error) }
    }
}
