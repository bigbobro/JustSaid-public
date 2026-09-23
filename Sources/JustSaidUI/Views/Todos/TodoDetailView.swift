import JustSaidCore
import SwiftUI

/// Removed items remain readable in the inspector, with restore as the only mutation.
struct TodoDetailView: View {
  @ObservedObject var model: TodoPageModel
  let itemID: UUID
  var onOpenSource: (URL, TimeInterval?) -> Void

  var body: some View {
    ScrollView {
      if let item = model.item(itemID) {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.lg) {
          HStack(alignment: .top) {
            Text(item.title).font(Tokens.V1.Text.title.font)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
            Button {
              model.closeLayer()
            } label: {
              Image(systemName: "xmark")
            }
            .buttonStyle(.v1Icon).accessibilityLabel("关闭")
            .runtimeAccessibilityIdentifier("todos.inspector.close")
          }
          fact("原负责人", TodoText.assignee(item.assignee))
          fact("优先级", TodoText.priority(item.priority))
          fact("客户 / 项目", TodoText.clientProject(item) ?? "未填写")
          fact("原截止日期", TodoText.duePhrase(item.due, now: model.now, item: item))
          if !item.note.isEmpty { fact("备注与前置条件", item.note) }
          TodoSourceSection(model: model, sources: item.sources, onOpenSource: onOpenSource)
          if item.removedAt != nil {
            Button("恢复此事项") { model.restore(item.id) }
              .buttonStyle(.v1Outline)
              .runtimeAccessibilityIdentifier("todos.detail.restore")
          }
        }
        .padding(Tokens.V1.Space.lg)
      }
    }
    .runtimeAccessibilityIdentifier("todos.detail")
  }

  private func fact(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      Text(label).font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
      Text(value).font(Tokens.V1.Text.body.font).foregroundStyle(Tokens.V1.Color.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct TodoSourceSection: View {
  @ObservedObject var model: TodoPageModel
  let sources: [TodoSource]
  var onOpenSource: (URL, TimeInterval?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
      if !sources.isEmpty {
        Text("会议原话").font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
      }
      ForEach(sources) { source in sourceRow(source) }
    }
  }

  private func sourceRow(_ source: TodoSource) -> some View {
    let location = model.location(of: source)
    return VStack(alignment: .leading, spacing: Tokens.V1.Space.xs) {
      HStack(alignment: .top, spacing: Tokens.V1.Space.xs) {
        Text(source.meetingTitle?.nilIfBlank ?? "未命名会议")
          .font(Tokens.V1.Text.body.font).foregroundStyle(Tokens.V1.Color.ink)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        switch location {
        case .present, .ambiguous:
          Button(source.anchor?.nilIfBlank.map(TodoClock.sourceTime) ?? "查看会议") {
            model.openSource(source, navigate: onOpenSource)
          }
          .buttonStyle(.plain).font(Tokens.V1.Text.timecode.font).foregroundStyle(
            Tokens.V1.Color.accent
          )
          .runtimeAccessibilityIdentifier("todos.detail.source.\(source.id.uuidString)")
        case .deleted:
          Text("已删除").font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
            .runtimeAccessibilityIdentifier("todos.detail.deleted.\(source.id.uuidString)")
        case .unavailable:
          Text("来源暂不可用").font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
            .runtimeAccessibilityIdentifier("todos.detail.unavailable.\(source.id.uuidString)")
        }
      }
      if let text = source.evidence?.nilIfBlank ?? source.candidateText?.nilIfBlank {
        Text("“\(text)”").font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink2)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      if let owner = source.ownerText?.nilIfBlank {
        Text("原负责人：\(owner)").font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
      }
      if let deadline = source.deadlineText?.nilIfBlank {
        Text("原截止：\(deadline)").font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
      }
      if let started = source.meetingStartedAt {
        Text(ChineseDateText.dayAndTime(started, now: model.now))
          .font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
      }
      if case .unavailable = location {
        Text("已保存的来源摘录仍可查看").font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
      }
    }
    .padding(Tokens.V1.Space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Tokens.V1.Color.paper2, in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.md))
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.V1.Radius.md)
        .strokeBorder(Tokens.V1.Color.rule, lineWidth: Tokens.V1.Size.controlRuleWidth))
  }
}
