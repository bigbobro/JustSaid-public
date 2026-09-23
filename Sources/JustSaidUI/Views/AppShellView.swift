import SwiftUI

/// The shell owns navigation geometry; recording remains owned by AppCoordinator.
struct AppShellView<Rail: View, Content: View>: View {
  @ViewBuilder let rail: () -> Rail
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 0) {
      rail()
        .frame(width: Tokens.V1.Size.railWidth)
        .frame(maxHeight: .infinity)
        .background(Tokens.V1.Color.rail)
        .runtimeAccessibilityIdentifier("app.rail")
        .runtimeAccessibilityIdentifier("cockpit.rail")
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Tokens.V1.Color.paper)
    // 窗口已是 fullSizeContentView,但 SwiftUI 仍按系统标题栏的安全区把布局整体下推
    // 32 点:底色铺到了顶,内容没有,于是内容区顶上空出一条白带,轨的图标也被推低同样的距离
    // (2026-09-20 真机纵扫实测:内容列 0..84 同色,分隔线在 84 = 32 + 顶栏 52)。
    // 忽略顶部安全区,让顶栏自己从 y=0 开始占满整条。红绿灯在 x<70 的轨上,不与顶栏内容相撞。
    .ignoresSafeArea(.container, edges: .top)
    .runtimeAccessibilityIdentifier("app.shell")
  }
}
