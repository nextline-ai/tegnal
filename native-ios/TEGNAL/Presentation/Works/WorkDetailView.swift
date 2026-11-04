import SwiftUI

/// Helper for wrapping flow layout tags
/// Width a subview may grow by later. Lines break as if every subview had already
/// grown, so a star appearing on a tag never pushes it or a neighbor to the next line.
public struct FlowReservedWidth: LayoutValueKey {
    public static let defaultValue: CGFloat = 0
}

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
            let needed = size.width + subview[FlowReservedWidth.self]
            if currentX + needed > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += needed + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: width, height: currentY + lineHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var reservedX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = size.width + subview[FlowReservedWidth.self]
            if reservedX + needed > bounds.maxX && reservedX > bounds.minX {
                currentX = bounds.minX
                reservedX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            reservedX += needed + spacing
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
                    // Rounded like its frame, so a cover with dark or light edges keeps soft corners.
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).padding(8)
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
