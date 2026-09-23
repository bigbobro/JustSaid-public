import SwiftUI

/// 毛玻璃面(owner 2026-09-21 首页参考稿):一层半透明的白纱,透出底下卡面背景图的色相,
/// 一圈亮一点的细边。只给首页两张入口卡里浮在图上的小块:卡头徽章、点名提醒那一块、
/// 导入录音那一块、首页分段的底座。输入框与按钮不用它——那些要实底才读得清。
///
/// 不用系统 `ultraThinMaterial`:build 881 实机上它在浅色卡面上压成一块灰,不是参考稿里
/// 发白透色的玻璃。卡面背景是平滑渐变,没有细节可糊,一层白纱看上去就是毛玻璃。
/// 深色下 raised 是深灰,这层纱就是一块半透明的深色。
struct V1GlassSurface: ViewModifier {
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    content
      .background(
        Tokens.V1.Color.raised.opacity(Tokens.V1.Feedback.glassFill),
        in: RoundedRectangle(cornerRadius: cornerRadius))
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius)
          .strokeBorder(
            Tokens.V1.Color.raised.opacity(Tokens.V1.Feedback.glassEdge),
            lineWidth: Tokens.V1.Size.controlRuleWidth)
      )
  }
}

extension View {
  func v1Glass(cornerRadius: CGFloat) -> some View {
    modifier(V1GlassSurface(cornerRadius: cornerRadius))
  }
}
