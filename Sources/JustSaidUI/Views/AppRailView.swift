import AppKit
import JustSaidCore
import SwiftUI

struct AppRailView<SessionControls: View>: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var session: RecordingSession
  let harvestCount: Int
  let onDictionary: () -> Void
  let onSettings: () -> Void
  @ViewBuilder let sessionControls: () -> SessionControls

  private var hasSession: Bool {
    session.phase == .recording || session.phase == .stopping
  }

  var body: some View {
    VStack(spacing: Tokens.V1.Space.s2xs) {
      brand
      navigation("首页", symbol: "house", selected: coordinator.workspaceMode == .home) {
        coordinator.showHome()
      }
      .runtimeAccessibilityIdentifier("app.rail.home")
      navigation("会议库", symbol: "tray.full", selected: coordinator.workspaceMode == .library) {
        coordinator.openLibrary()
      }
      .runtimeAccessibilityIdentifier("app.rail.library")
      .runtimeAccessibilityIdentifier("cockpit.rail.library")
      navigation("待办", symbol: "checkmark.circle", selected: coordinator.workspaceMode == .todos) {
        coordinator.showTodos()
      }
      .runtimeAccessibilityIdentifier("app.rail.todos")
      if hasSession {
        Rectangle().fill(Tokens.V1.Color.rule)
          .frame(height: Tokens.V1.Size.controlRuleWidth)
          .padding(.horizontal, Tokens.V1.Space.sm)
          .padding(.vertical, Tokens.V1.Space.xs)
        sessionControls()
      }
      Spacer(minLength: Tokens.V1.Space.sm)
      navigation("词典", symbol: "book", selected: coordinator.workspaceMode == .dictionary, action: onDictionary)
        .overlay(alignment: .topTrailing) {
          if harvestCount > 0 {
            Text(harvestCount.formatted())
              .font(Tokens.V1.Text.micro.font)
              .foregroundStyle(Tokens.V1.Color.accentInk)
              .padding(.horizontal, Tokens.V1.Space.s2xs)
              .background(Tokens.V1.Color.accent, in: Capsule())
              .allowsHitTesting(false)
          }
        }
        .accessibilityLabel("词典，收割箱 \(harvestCount) 个候选")
        .runtimeAccessibilityIdentifier("app.rail.dictionary")
      navigation("设置", symbol: "gearshape", selected: coordinator.workspaceMode == .settings, action: onSettings)
        .runtimeAccessibilityIdentifier("app.rail.settings")
        .runtimeAccessibilityIdentifier("cockpit.rail.settings")
    }
    // 顶端让出一条顶栏的高度(52)给系统红绿灯:窗口没有独立标题栏,内容顶到 y=0,
    // 红绿灯就落在轨的这条顶带上,宽度由 Tokens.V1.Size.railWidth 留足余量。那个角落归红绿灯;
    // 应用图标放在这条带子正下方的第一格(见 brand),不进红绿灯那一角。
    .padding(.top, Tokens.V1.Size.barHeight)
    .padding(.bottom, Tokens.V1.Space.sm)
  }

  /// 应用图标,放在红绿灯正下方的第一格,明显大于导航字形(露出的方块 rail-brand 32 对 rail-icon 20)
  /// ——owner 2026-09-21:「应该放在最左侧轨道的红绿灯正下方,而且图标要比其他图标略大一些」,
  /// 28 的画框上线后:「不是说了比其他图标都大吗？现在这么小」。
  /// 原来放在设置分区栏底部。它是静态的,不是按钮:没有目的地,做成可点就是一个假入口。
  /// 版本号写进悬停提示与无障碍标签;要复制版本号去设置页底部那一行。
  /// macOS 应用图标栅格:1024 画布里圆角方块只占 824,四周是透明边,
  /// `applicationIconImage` 带着这圈边。画框按 rail-brand 等比放大,露出来的方块才是 rail-brand。
  /// 28 的画框实际只露出约 22,和 20 点的房子字形一样大,就是这个原因。
  private static var brandCanvas: CGFloat { Tokens.V1.Size.railBrand * 1024 / 824 }

  private var brand: some View {
    Image(nsImage: NSApplication.shared.applicationIconImage)
      .resizable()
      .scaledToFit()
      .frame(width: Self.brandCanvas, height: Self.brandCanvas)
      .frame(width: Tokens.V1.Size.railItem.width, height: Tokens.V1.Size.railItem.height)
      // 图标格下再空 8,加上栈间距 4 共 12,再往下才是「首页」。
      .padding(.bottom, Tokens.V1.Space.xs)
      .help("JustSaid  \(ProviderSettingsView.buildLabel)")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("JustSaid,版本 \(ProviderSettingsView.buildLabel)")
      .runtimeAccessibilityIdentifier("app.rail.brand")
  }

  private func navigation(
    _ title: String, symbol: String, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: Tokens.V1.Size.railIcon))
        .frame(width: Tokens.V1.Size.railItem.width, height: Tokens.V1.Size.railItem.height)
        .background(
          selected ? Tokens.V1.Color.paper3 : .clear,
          in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.md))
    }
    .buttonStyle(AppRailButtonStyle())
    .help(title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct AppRailButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    RailLabel(configuration: configuration)
  }

  private struct RailLabel: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    var body: some View {
      configuration.label
        .foregroundStyle(Tokens.V1.Color.ink2)
        .background(
          hovered ? Tokens.V1.Color.scrim : .clear,
          in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.md)
        )
        .opacity(configuration.isPressed ? Tokens.V1.Feedback.pressedOpacity : 1)
        .contentShape(RoundedRectangle(cornerRadius: Tokens.V1.Radius.md))
        .onHover { hovered = $0 }
    }
  }
}
