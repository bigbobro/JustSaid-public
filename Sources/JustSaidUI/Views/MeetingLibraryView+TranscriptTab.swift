import AppKit
import JustSaidCore
import SwiftUI
import UniformTypeIdentifiers

// 2026-08-20 批3 拆分:自 MeetingLibraryView.swift 按 MARK 边界机械迁出,零行为变更。
extension MeetingLibraryView {
  /// 说话人命名行(F2)。
  ///
  /// 痛点实证:A/B 仲裁时「这个参数收集的责任人到底是 张三 还是 李四」无法定论,
  /// 因为我方转写通篇只有「发言人 N」。填一次真名,这场会的转写与后续重生成的纪要都认得人。
  /// 转写还没跑出来时整行不出现——没有发言人可命名。
  @ViewBuilder
  func speakerNamingRow(_ item: MeetingLibraryItem) -> some View {
    let labels = model.speakerLabels(for: item)
    if !labels.isEmpty {
      VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Tokens.Spacing.sm) {
            Text("说话人")
              .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
              .foregroundStyle(Tokens.Color.ink3)
            ForEach(labels, id: \.self) { label in
              // 高亮/只看的建桶口径 = 生效后的显示名(真名优先,回退原始标签),
              // 与 displaySpeakers 主映射一致;单段 override 不按它建桶。
              let displayName = {
                let name = model.speakerName(label, for: item)
                return name.isEmpty ? label : name
              }()
              SpeakerNameField(
                label: label,
                name: model.speakerName(label, for: item),
                isHighlighted: model.speakerHighlight == displayName,
                isExcluded: item.excludedSpeakers.contains(label),
                channelHint: SpeakerChannelHint.presentation(for: item.channelStats?[label]),
                onToggleHighlight: { model.toggleSpeakerHighlight(displayName) },
                onToggleExcluded: {
                  model.setSpeakerExcluded(
                    label,
                    excluded: !item.excludedSpeakers.contains(label),
                    of: item
                  )
                },
                onFilter: { model.toggleSpeakerFilter(displayName) }
              ) { newName in
                model.setSpeakerName(newName, for: label, of: item)
              }
            }
          }
          .padding(.horizontal, Tokens.Spacing.lg)
        }
        Group {
          if let error = model.speakerNameError {
            Text(error)
              .foregroundStyle(Tokens.Color.warn)
          } else {
            Text("填了真名，这一页的转写立刻换成真名，之后重新生成的纪要也会用它；transcript.md 原文不动。")
              .foregroundStyle(Tokens.Color.ink4)
          }
        }
        .font(.system(size: Tokens.FontSize.secondary))
        .padding(.horizontal, Tokens.Spacing.lg)
      }
      .padding(.vertical, Tokens.Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Tokens.Color.pane)
      .overlay(alignment: .bottom) { Divider() }
    }
  }

  /// 搜索/只看/排除三通道的组合状态 + 「新名字…」就地输入。
  ///
  /// 呈现变窄或变灰都必须可见地说明原因；三通道都未激活时不占版面。
  @ViewBuilder
  func transcriptFilterRow(_ item: MeetingLibraryItem) -> some View {
    // 出错信息也挂在这一行:命名行只在「有非我说话人」时才出现,而右键更正对每一段都开放
    // (包括「我」的段落)。只靠命名行报错,通篇都是「我」的会议就会静默失败——
    // 那正是 speakerNameError 存在要防的事。
    let overrideError = model.speakerNameError
    let normalizedQuery = normalizedTranscriptSearchQuery
    let transcriptRows = model.transcriptRows(for: item)
    let filteredCount = TranscriptDocumentView.filteredSpeechCount(
      in: transcriptRows,
      speaker: model.speakerFilter,
      query: normalizedQuery
    )
    let excludedRangeCount = item.excludedRanges.count
    let excludedSpeakerCount = item.excludedSpeakers.count
    let hasExclusions = excludedRangeCount > 0 || excludedSpeakerCount > 0
    let hasFilterCombination =
      !normalizedQuery.isEmpty
      || model.speakerFilter != nil
      || hasExclusions
    if isTranscriptSearchPresented || hasFilterCombination
      || model.speakerHighlight != nil
      || model.pendingOverrideLine != nil
      || model.exclusionError != nil
      || (overrideError != nil && model.speakerLabels(for: item).isEmpty)
    {
      VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
        if isTranscriptSearchPresented {
          HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
              .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
              .foregroundStyle(Tokens.Color.ink4)
              .accessibilityHidden(true)
            TextField("搜索完整转写", text: $transcriptSearchQuery)
              .textFieldStyle(.plain)
              .font(.system(size: Tokens.FontSize.uiEmphasis))
              .focused($isTranscriptSearchFocused)
              .onKeyPress(.escape) {
                closeTranscriptSearch()
                return .handled
              }
              .runtimeAccessibilityIdentifier("transcript.search.field")
            Text(
              normalizedQuery.isEmpty
                ? "共 \(filteredCount) 条"
                : "命中 \(filteredCount) 条"
            )
            .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
            .foregroundStyle(Tokens.Color.ink3)
            .fixedSize(horizontal: true, vertical: false)
            .runtimeAccessibilityIdentifier("transcript.search.count")
            Button {
              closeTranscriptSearch()
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: Tokens.FontSize.micro, weight: .bold))
            }
            .buttonStyle(.iconHover)
            .accessibilityLabel("关闭转写搜索")
            .runtimeAccessibilityIdentifier("transcript.search.close")
          }
          .padding(.horizontal, Tokens.Spacing.sm)
          .padding(.vertical, Tokens.Spacing.xsm)
          .background(
            Tokens.Color.cardWash,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.widget)
          )
          .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.widget)
              .stroke(
                isTranscriptSearchFocused ? Tokens.Color.ac : Tokens.Color.line,
                lineWidth: 1
              )
          )
        }
        if hasFilterCombination {
          HStack(spacing: Tokens.Spacing.xs) {
            Text("当前呈现")
              .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
              .foregroundStyle(Tokens.Color.ink3)
            if !normalizedQuery.isEmpty {
              TranscriptFilterStatePill(
                text: "搜索：\(normalizedQuery) · \(filteredCount) 条",
                identifier: "transcript.filter-summary.search"
              )
            }
            if let filter = model.speakerFilter {
              TranscriptFilterStatePill(
                text: "只看：\(filter)",
                identifier: "transcript.filter-summary.speaker"
              )
            }
            if hasExclusions {
              TranscriptFilterStatePill(
                text: exclusionStateLabel(
                  rangeCount: excludedRangeCount,
                  speakerCount: excludedSpeakerCount
                ),
                identifier: "transcript.filter-summary.excluded"
              )
            }
            Spacer(minLength: 0)
          }
          .runtimeAccessibilityIdentifier("transcript.filter-summary")
        }
        if let exclusionError = model.exclusionError {
          Text(exclusionError)
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.warn)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let overrideError, model.speakerLabels(for: item).isEmpty {
          Text(overrideError)
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.warn)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let filter = model.speakerFilter {
          HStack(spacing: Tokens.Spacing.xs) {
            SpeakerFilterChip(filter: filter) {
              model.speakerFilter = nil
            }
            Text("其余发言暂时藏起来了，原文没有改动。")
              .font(.system(size: Tokens.FontSize.secondary))
              .foregroundStyle(Tokens.Color.ink4)
            Spacer(minLength: 0)
          }
        }
        // 高亮常驻条与「只看」同款纪律:隐蔽状态必须可见。两者互斥(model 里结算),
        // 不会同时出现;高亮对象在当前行集里一段都没有时整条不出现。
        if let highlight = model.speakerHighlight,
          let progress = model.speakerHighlightProgress(for: item)
        {
          SpeakerHighlightBar(
            speaker: highlight,
            index: progress.index,
            count: progress.count,
            onPrevious: { model.stepSpeakerHighlight(by: -1, of: item) },
            onNext: { model.stepSpeakerHighlight(by: 1, of: item) },
            onClear: { model.clearSpeakerHighlight() }
          )
        }
        if let line = model.pendingOverrideLine {
          NewSpeakerNameField(line: line) { name in
            model.setSpeakerOverride(name, for: line, of: item)
          } onCancel: {
            model.pendingOverrideLine = nil
          }
        }
      }
      .padding(.horizontal, Tokens.Spacing.lg)
      .padding(.vertical, Tokens.Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Tokens.Color.pane)
      .overlay(alignment: .bottom) { Divider() }
    }
  }
}

// MARK: - 列表行

/// 「只看：某人」筛选 chip:点击清除筛选;悬停描边加深(可点元素悬停态纪律)。
private struct SpeakerFilterChip: View {
  let filter: String
  let onClear: () -> Void
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @State private var isHovering = false

  var body: some View {
    Button(action: onClear) {
      HStack(spacing: Tokens.Spacing.xxs) {
        Text("只看：\(filter)")
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        Image(systemName: "xmark")
          .font(.system(size: Tokens.FontSize.glyphTiny, weight: .bold))
      }
      .foregroundStyle(Tokens.Color.acDeep)
      .padding(.horizontal, Tokens.Spacing.xsm)
      .padding(.vertical, Tokens.Spacing.xxs)
      .background(Capsule().fill(Tokens.Color.acSoft))
      .overlay(
        Capsule()
          .stroke(isHovering ? Tokens.Color.acDeep : Tokens.Color.acLine, lineWidth: 1)
      )
      .contentShape(Capsule())
      .onHover { isHovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.hover), value: isHovering)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("清除「只看 \(filter)」的筛选")
  }
}

/// 只读状态徽签：说清哪些呈现通道正在叠加，不承担清除动作。
private struct TranscriptFilterStatePill: View {
  let text: String
  let identifier: String

  var body: some View {
    Text(text)
      .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
      .foregroundStyle(Tokens.Color.ink2)
      .lineLimit(1)
      .truncationMode(.middle)
      .padding(.horizontal, Tokens.Spacing.xsm)
      .padding(.vertical, Tokens.Spacing.xxs)
      .background(Capsule().fill(Tokens.Color.cardWash))
      .overlay(Capsule().stroke(Tokens.Color.line, lineWidth: 1))
      .help(text)
      .runtimeAccessibilityIdentifier(identifier)
  }
}

// MARK: - 高亮通读常驻条

/// 「高亮:X · 第 k/n 处 · 上一处 下一处 ✕」(08-14 chip 交互单)。
///
/// 高亮是隐蔽状态:全文都还在,只是一个人着了色——激活期顶上必须常驻这一条,
/// 与「只看」同一纪律。与「只看」互斥(在 model 的 toggle 里结算),两条不会同时出现。
/// public:验证程序直接摆出来断言结构(整页 probe 预置不了高亮态)。
public struct SpeakerHighlightBar: View {
  private let speaker: String
  /// 0-based;展示时 +1。
  private let index: Int
  private let count: Int
  private let onPrevious: () -> Void
  private let onNext: () -> Void
  private let onClear: () -> Void

  public init(
    speaker: String,
    index: Int,
    count: Int,
    onPrevious: @escaping () -> Void,
    onNext: @escaping () -> Void,
    onClear: @escaping () -> Void
  ) {
    self.speaker = speaker
    self.index = index
    self.count = count
    self.onPrevious = onPrevious
    self.onNext = onNext
    self.onClear = onClear
  }

  public var body: some View {
    HStack(spacing: Tokens.Spacing.xs) {
      Text("高亮：\(speaker) · 第 \(index + 1)/\(count) 处")
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        .foregroundStyle(Tokens.Color.acDeep)
      Button("上一处", action: onPrevious)
        .runtimeAccessibilityIdentifier("transcript.highlight-bar.previous")
      Button("下一处", action: onNext)
        .runtimeAccessibilityIdentifier("transcript.highlight-bar.next")
      Button(action: onClear) {
        Image(systemName: "xmark")
          .font(.system(size: Tokens.FontSize.glyphTiny, weight: .bold))
      }
      .accessibilityLabel("退出对「\(speaker)」的高亮")
      .runtimeAccessibilityIdentifier("transcript.highlight-bar.clear")
      Text("全文都还在，只是这个人的发言着了色。")
        .font(.system(size: Tokens.FontSize.secondary))
        .foregroundStyle(Tokens.Color.ink4)
      Spacer(minLength: 0)
    }
    .buttonStyle(.textAction)
    .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
    .foregroundStyle(Tokens.Color.acDeep)
    .runtimeAccessibilityIdentifier("transcript.highlight-bar")
  }
}
