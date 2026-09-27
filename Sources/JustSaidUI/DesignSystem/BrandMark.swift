import SwiftUI

/// App 内小尺寸品牌标志；以整数 pt 绘制，不依赖系统应用图标的位图表示层。
struct BrandMark: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Tokens.V1.BrandMark.cornerRadius, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Tokens.V1.Color.brandStart, Tokens.V1.Color.brandEnd],
            startPoint: .topLeading, endPoint: .bottomTrailing))
      Canvas { context, _ in
        for (index, bar) in Tokens.V1.BrandMark.bars.enumerated() {
          let rect = CGRect(
            x: bar.centerX - Tokens.V1.BrandMark.barWidth / 2, y: bar.topY,
            width: Tokens.V1.BrandMark.barWidth, height: bar.height)
          context.fill(
            Path(roundedRect: rect, cornerRadius: Tokens.V1.BrandMark.strokeRadius),
            with: .color(
              index == Tokens.V1.BrandMark.bars.count / 2
                ? Tokens.V1.Color.brandCenterBar : Tokens.V1.Color.brandBar))
        }
        context.fill(
          Path(
            roundedRect: Tokens.V1.BrandMark.line,
            cornerRadius: Tokens.V1.BrandMark.strokeRadius),
          with: .color(Tokens.V1.Color.brandLine))
      }
    }
    .frame(width: Tokens.V1.Size.railBrand, height: Tokens.V1.Size.railBrand)
  }
}
