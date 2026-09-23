import SwiftUI

struct TodoHighlightedText: View {
  let text: String
  var query: String

  var body: some View { Text(highlighted) }

  private var highlighted: AttributedString {
    var result = AttributedString(text)
    guard !query.isEmpty else { return result }
    var start = text.startIndex
    while start < text.endIndex,
      let range = text.range(
        of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex),
      let lower = AttributedString.Index(range.lowerBound, within: result),
      let upper = AttributedString.Index(range.upperBound, within: result)
    {
      result[lower..<upper].foregroundColor = Tokens.V1.Color.accent
      result[lower..<upper].backgroundColor = Tokens.V1.Color.accentSoft
      start = range.upperBound
    }
    return result
  }
}

/// A wrapping metadata line keeps long client names readable without fixed data columns.
struct TodoMetadataFlow: Layout {
  var spacing: CGFloat = Tokens.V1.Space.xs

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var height: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
      if x > 0, x + size.width > width {
        x = 0
        y += height + Tokens.V1.Space.s3xs
        height = 0
      }
      x += size.width + spacing
      height = max(height, size.height)
    }
    return CGSize(width: proposal.width ?? max(0, x - spacing), height: y + height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX
    var y = bounds.minY
    var height: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX
        y += height + Tokens.V1.Space.s3xs
        height = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      height = max(height, size.height)
    }
  }
}
