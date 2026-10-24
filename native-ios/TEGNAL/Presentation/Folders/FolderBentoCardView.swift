import SwiftUI

public struct FolderBentoCardView: View {
    @Environment(\.artworkCellStyle) private var style
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) private var captionSize: CGFloat = 11
    public let folder: Folder
    public let previews: [Work]
    public let onChangeColor: (() -> Void)?

    public init(folder: Folder, previews: [Work] = [], onChangeColor: (() -> Void)? = nil) {
        self.folder = folder
        self.previews = previews
        self.onChangeColor = onChangeColor
    }

    private var folderColor: Color {
        Color(argb: folder.color)
    }

    /// Determines white or black text depending on background luminance
    private var textColor: Color {
        let r = Double((folder.color >> 16) & 0xFF) / 255.0
        let g = Double((folder.color >> 8) & 0xFF) / 255.0
        let b = Double(folder.color & 0xFF) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.48 ? Color.black : Color.white
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top: 2x2 thumbnails preview
            Color.clear.aspectRatio(1.25, contentMode: .fit).overlay {
                VStack(spacing: style.inset(4)) {
                    HStack(spacing: style.inset(4)) {
                        thumbCell(index: 0)
                        thumbCell(index: 1)
                    }
                    HStack(spacing: style.inset(4)) {
                        thumbCell(index: 2)
                        thumbCell(index: 3)
                    }
                }
                .padding(style.inset(6))
                .frame(maxWidth: .infinity)
            }
            .clipped()

            // Bottom: Folder title & count
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: style.inset(2)) {
                    Text(folder.displayName)
                        .font(.system(size: style.fontSize(titleSize, minimum: 10), weight: .bold))
                        .lineLimit(1)
                        .foregroundColor(textColor)

                    Text(L10n.text("%@ items", String(describing: folder.workCount)))
                        .font(.system(size: style.fontSize(captionSize, minimum: 9), weight: .semibold))
                        .foregroundColor(textColor.opacity(0.85))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, style.inset(10))
            .padding(.vertical, style.inset(8))
        }
        .background(folderColor)
        .clipShape(RoundedRectangle(cornerRadius: style.radius(16), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: style.radius(16), style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: style.removesPadding ? 0 : 0.5)
        )
        .shadow(color: .black.opacity(0.1), radius: style.inset(8), y: style.inset(3))
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
                                RoundedRectangle(cornerRadius: style.radius(8), style: .continuous)
                                    .fill(textColor.opacity(0.14))
                                    .overlay(
                                        Text(verbatim: String(work.galleryId))
                                            .font(.system(size: style.fontSize(10), weight: .semibold))
                                            .foregroundColor(textColor.opacity(0.85))
                                            .lineLimit(1)
                                            .padding(style.inset(2))
                                    )
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
