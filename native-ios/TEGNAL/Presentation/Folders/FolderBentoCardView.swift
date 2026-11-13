import SwiftUI

public struct FolderBentoCardView: View {
    @Environment(\.artworkCellStyle) private var style
    public let folder: Folder
    public let previews: [Work]
    public let onChangeColor: (() -> Void)?

    public init(folder: Folder, previews: [Work] = [], onChangeColor: (() -> Void)? = nil) {
        self.folder = folder
        self.previews = previews
        self.onChangeColor = onChangeColor
    }

    private var textColor: Color { FolderBentoFrame<EmptyView>.textColor(folder.color) }

    public var body: some View {
        FolderBentoFrame(color: folder.color, title: folder.plainName, isSmart: folder.isSmart, count: folder.workCount) { thumbCell(index: $0) }
    }

    @ViewBuilder
    private func thumbCell(index: Int) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                Group {
                    if index < previews.count {
                        let work = previews[index]
                        LocalThumbnailView(path: work.thumbStatus == "ready" ? work.thumbPath : nil, revision: String(work.thumbPage ?? 1)) { image in
                            if let image {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                FolderBentoPlaceholder(galleryID: work.galleryId, color: textColor)
                            }
                        }
                    } else {
                        RoundedRectangle(cornerRadius: style.radius(8), style: .continuous)
                            .fill(textColor.opacity(0.08))
                    }
                }
            )
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: style.radius(8), style: .continuous))
    }
}

/// A cover not available yet: the work's number on a tinted tile.
struct FolderBentoPlaceholder: View {
    @Environment(\.artworkCellStyle) private var style
    let galleryID: Int64
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: style.radius(8), style: .continuous)
            .fill(color.opacity(0.14))
            .overlay(
                Text(verbatim: String(galleryID))
                    .font(.system(size: style.fontSize(10), weight: .semibold))
                    .foregroundColor(color.opacity(0.85))
                    .lineLimit(1)
                    .padding(style.inset(2))
            )
    }
}

/// The comics folder card: a 2×2 preview above the caption, on the folder's color.
struct FolderBentoFrame<Cell: View>: View {
    @Environment(\.artworkCellStyle) private var style
    let color: Int64
    let title: String
    var isSmart = false
    let count: Int
    @ViewBuilder let cell: (Int) -> Cell

    /// Determines white or black text depending on background luminance
    static func textColor(_ argb: Int64) -> Color {
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.48 ? Color.black : Color.white
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top: 2x2 thumbnails preview
            Color.clear.aspectRatio(1.25, contentMode: .fit).overlay {
                VStack(spacing: style.inset(4)) {
                    HStack(spacing: style.inset(4)) {
                        cell(0)
                        cell(1)
                    }
                    HStack(spacing: style.inset(4)) {
                        cell(2)
                        cell(3)
                    }
                }
                .padding(style.inset(6))
                .frame(maxWidth: .infinity)
            }
            .clipped()

            // Bottom: Folder title & count
            FolderCardCaption(title: title, isSmart: isSmart, count: count, color: Self.textColor(color))
        }
        .background(Color(argb: color))
        .clipShape(RoundedRectangle(cornerRadius: style.radius(16), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: style.radius(16), style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: style.removesPadding ? 0 : 0.5)
        )
        .shadow(color: .black.opacity(0.1), radius: style.inset(8), y: style.inset(3))
    }
}

/// Both libraries keep the count at the lower trailing edge of the title row.
struct FolderCardCaption: View {
    let title: String
    var isSmart = false
    let count: Int
    let color: Color
    @Environment(\.artworkCellStyle) private var style
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) private var captionSize: CGFloat = 11
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: style.inset(6)) {
            // A long name truncates before the mark, never over it.
            HStack(alignment: .lastTextBaseline, spacing: style.inset(3)) {
                Text(title).lineLimit(1)
                if isSmart { Text(verbatim: "✦").fixedSize().accessibilityLabel(L10n.text("Smart Folder")) }
            }.font(.system(size: style.fontSize(titleSize, minimum: 10), weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            Text(count, format: .number)
                .font(.system(size: style.fontSize(captionSize, minimum: 9), weight: .semibold))
                .foregroundStyle(color.opacity(0.85)).fixedSize()
        }.foregroundStyle(color)
            .padding(.horizontal, style.inset(10))
            // Thumbnail inset 6 + caption inset 8 was 14; use 2/3 of that gap.
            .padding(.top, style.inset(10.0 / 3.0))
            .padding(.bottom, style.inset(8))
            .accessibilityElement(children: .combine)
    }
}
