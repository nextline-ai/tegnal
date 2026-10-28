import SwiftUI

/// Helper for wrapping flow layout tags
public struct FlowLayout: Layout {
    public var spacing: CGFloat

    public init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: width, height: currentY + lineHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}


/// Reserves the thumbnail slot even during loading/failure, so actions never move under a finger.
struct WorkDetailCover: View {
    let image: UIImage?
    var loading = false
    var body: some View {
        RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .secondarySystemBackground))
            .frame(height: 300)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().padding(8)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: AppMode.manga.icon).font(.largeTitle).foregroundStyle(.tertiary)
                        if loading { ProgressView() }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Thumbnail"))
            .accessibilityValue(L10n.text(image == nil ? (loading ? "Loading" : "Thumbnail unavailable") : "Thumbnail loaded"))
            .accessibilityIdentifier("content.detail.cover")
    }
}
