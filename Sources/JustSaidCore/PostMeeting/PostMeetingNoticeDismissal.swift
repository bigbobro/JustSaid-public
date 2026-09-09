import Foundation

/// 成功提示的展示门(08-10)。
///
/// 这里的 `Task` 是**界面计时器**,与会后长任务是两回事:计时器可取消、也必须可取消
/// (用户点「查看本场会议」当场收、⌘L 边界收呈现态、同一身份排新的一条时都要停掉旧的);
/// 会后长任务永远不取消——窗口与 View 销毁只释放呈现,那条红线不受本文件影响。
///
/// 刻意与 `PostMeetingTaskCoordinator.swift` **分文件**:那份源码有一条
/// 「`.cancel()` 零出现」的结构断言(UIHierarchy 所有权红线),守的是"窗口销毁不得触碰任务"。
/// 计时器的 cancel 与那条红线无关,但混进同一份源码就会让那条断言彻底失去判别力。
///
/// **取消不是正确性的依靠**:被取消的 `try? await Task.sleep` 会吞掉 `CancellationError`
/// 直接往下走,所以这里在 body 里先查 `Task.isCancelled`;真正的守卫在协调者侧——
/// identity(标准化会议目录)+ runID(世代)+ 当前仍是同一条 `.finished` 三重比对。
/// 旧计时器就算漏网跑起来,也只会在守卫处空转。
@MainActor
public final class PostMeetingNoticeDismissalScheduler {
  /// 「约 5 秒」里的那个 5:成功提示是瞬时反馈,给一眼看见的时间,不该长期占着顶部。
  public static let successNoticeDuration: TimeInterval = 5

  /// 延时注入点。验证里换成可控时钟(手动放行),不真的等 5 秒——
  /// 固定墙钟等待是隐式假设,受载机上一挤就翻车。
  public typealias Delay = @Sendable () async -> Void

  private let delay: Delay
  private var pending: [String: Task<Void, Never>] = [:]

  init(delay: Delay? = nil) {
    self.delay =
      delay
      ?? {
        try? await Task.sleep(
          nanoseconds: UInt64(Self.successNoticeDuration * 1_000_000_000)
        )
      }
  }

  /// 为某条成功提示排一次隐藏。同一身份的旧计时先停掉:一条身份同一时刻只有一条提示。
  func schedule(identity: String, perform: @escaping @MainActor () -> Void) {
    cancel(identity: identity)
    pending[identity] = Task { @MainActor [weak self, delay] in
      await delay()
      guard !Task.isCancelled else { return }
      self?.pending.removeValue(forKey: identity)
      perform()
    }
  }

  func cancel(identity: String) {
    pending.removeValue(forKey: identity)?.cancel()
  }
}
