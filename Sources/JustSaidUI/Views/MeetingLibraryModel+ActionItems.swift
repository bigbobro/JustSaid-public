import JustSaidCore
import SwiftUI

extension MeetingLibraryModel {
  /// 右栏这一条待办是不是已经勾掉。
  func isActionItemCompleted(_ action: SummaryActionItem, of item: MeetingLibraryItem) -> Bool {
    item.completedActionItems.contains(action.completionKey)
  }

  /// 勾掉或恢复右栏的一条待办(owner 2026-09-22),只写 `meeting.json`;
  /// 写成功才改界面,失败把原因挂出来,不假装存上了。
  func setActionItem(
    _ action: SummaryActionItem,
    completed: Bool,
    of item: MeetingLibraryItem
  ) {
    guard let index = meetings.firstIndex(where: { $0.id == item.id }) else { return }
    do {
      let metadata = try meetingStore.setActionItemCompleted(
        action.completionKey, completed: completed, at: item.paths)
      meetings[index].completedActionItems = metadata.completedActionItems ?? []
      actionItemError = nil
    } catch {
      actionItemError = "这次勾选没能存进 meeting.json：\(error.localizedDescription)"
    }
  }
}
