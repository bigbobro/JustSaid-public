import SwiftUI

/// 设计系统 `.check` 的方框:14 见方,没勾是 raised 底加控件细边,勾上填 accent、出 accentInk 的对勾。
/// 只画记号,点击由外面的 Button 负责(筛选行整行可点,待办只点方框)。
/// 不用系统 `.checkbox` 样式:它用系统强调色(本机是蓝),与 V1 不符。
public struct V1CheckboxMark: View {
  private let isOn: Bool

  public init(isOn: Bool) {
    self.isOn = isOn
  }

  public var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Tokens.V1.Radius.xs)
        .fill(isOn ? Tokens.V1.Color.accent : Tokens.V1.Color.raised)
        .overlay(
          RoundedRectangle(cornerRadius: Tokens.V1.Radius.xs)
            .strokeBorder(
              isOn ? Tokens.V1.Color.accent : Tokens.V1.Color.controlRule,
              lineWidth: Tokens.V1.Size.controlRuleWidth)
        )
      if isOn {
        Image(systemName: "checkmark")
          .font(.system(size: Tokens.V1.Space.sm - Tokens.V1.Space.s3xs, weight: .bold))
          .foregroundStyle(Tokens.V1.Color.accentInk)
      }
    }
    .frame(width: Tokens.V1.Size.checkBox, height: Tokens.V1.Size.checkBox)
    .accessibilityHidden(true)
  }
}
