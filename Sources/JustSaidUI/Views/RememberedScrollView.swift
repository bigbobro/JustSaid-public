import JustSaidCore
import SwiftUI

/// 滚轮事件只更新这个非观察对象；不得把每一帧都升级成 SwiftUI 状态发布。
private final class ScrollOffsetTracker {
  var latestOffset: CGFloat?
}

/// 页签互斥切走会销毁 ScrollView;把 contentOffset.y 写回调用方,回来时按点还原。
/// 精度就是 SwiftUI `ScrollPosition.scrollTo(y:)` 能稳定做到的程度:内容高度没变时
/// 对齐到点,字号/窗宽变了只是近似落点。
struct RememberedScrollOffsetModifier: ViewModifier {
  @Binding var offset: CGFloat
  var restoresOnAppear: Bool

  @State private var position = ScrollPosition()
  @State private var isTracking = false
  @State private var tracker = ScrollOffsetTracker()

  func body(content: Content) -> some View {
    content
      .scrollPosition($position)
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentOffset.y
      } action: { _, y in
        guard isTracking else { return }
        tracker.latestOffset = y
      }
      .onScrollPhaseChange { _, phase in
        guard
          isTracking,
          phase == .idle,
          let latestOffset = tracker.latestOffset,
          abs(offset - latestOffset) > 0.5
        else {
          return
        }
        // `offset` 来自 AppCoordinator 的 @Published；只在滚动停下时提交一次。
        // 逐帧提交会让整个主窗边滚边重算，并与文字选择布局形成反馈循环。
        offset = latestOffset
        HangSentinel.shared.note("scroll-commit:\(Int(latestOffset))")
      }
      .onAppear {
        tracker.latestOffset = nil
        if restoresOnAppear, offset > 0.5 {
          position.scrollTo(y: offset)
        }
        Task { @MainActor in
          await Task.yield()
          isTracking = true
        }
      }
      .onDisappear {
        isTracking = false
        tracker.latestOffset = nil
      }
  }
}

extension View {
  @ViewBuilder
  func rememberedScrollOffset(
    _ offset: Binding<CGFloat>?,
    restoresOnAppear: Bool = true
  ) -> some View {
    if let offset {
      modifier(
        RememberedScrollOffsetModifier(offset: offset, restoresOnAppear: restoresOnAppear)
      )
    } else {
      self
    }
  }
}
