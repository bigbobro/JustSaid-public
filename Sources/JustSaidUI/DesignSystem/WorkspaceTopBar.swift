import SwiftUI

/// 壳里每一页的顶栏:页名在左、这一页的动作在右、底下一条分割线。
///
/// 2026-09-21 收口。此前三页各写各的,owner 走查时看出来了:
///
/// | 页 | 分割线 | 高度 |
/// | --- | --- | --- |
/// | 首页 | 栏**外**一个兄弟 Rectangle | 固定 52 |
/// | 会议库 | 栏**内** overlay | 固定 52 |
/// | 设置 | **没有** | `minHeight` + 垂直 padding,会超过 52 |
///
/// 线在栏内还是栏外,决定它是否被栏的背景盖住、是否跟着栏的横向 padding;
/// `minHeight` 则让设置页的顶栏比另外两页高一点点——切页时那条横线会跳。
/// 页名的字号本来就一致(`barTitle`),不一致的是这两样。
public struct WorkspaceTopBar<Trailing: View>: View {
  let title: String
  /// 页名右边那句小字:首页的日期、会议库的「N 场」。没有就不画。
  var detail: String?
  @ViewBuilder var trailing: () -> Trailing

  public init(
    _ title: String,
    detail: String? = nil,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.title = title
    self.detail = detail
    self.trailing = trailing
  }

  public var body: some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      Text(title)
        .font(Tokens.V1.Text.barTitle.font)
        .foregroundStyle(Tokens.V1.Color.ink)
        .fixedSize()
      if let detail, !detail.isEmpty {
        Text(detail)
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
          .fixedSize()
      }
      Spacer(minLength: Tokens.V1.Space.sm)
      trailing()
    }
    .padding(.horizontal, Tokens.V1.Space.md)
    // 固定 52,不用 minHeight:切页时那条横线不能跳。
    .frame(height: Tokens.V1.Size.barHeight)
    .background(Tokens.V1.Color.paper)
    // 线画在栏内底边:跟着栏的背景与横向范围走,三页才对得齐。
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Tokens.V1.Color.rule)
        .frame(height: Tokens.V1.Size.controlRuleWidth)
    }
  }
}

extension WorkspaceTopBar where Trailing == EmptyView {
  public init(_ title: String, detail: String? = nil) {
    self.init(title, detail: detail, trailing: { EmptyView() })
  }
}
