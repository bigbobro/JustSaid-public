import AppKit
import JustSaidCore
import SwiftUI

/// 核对工作台的数据上下文(08-17 R-a):队列与指纹由 Core 纯派生,判定读写走
/// check.json;纪要/转写产物零写入。View 只渲染与转发动作,不自己碰磁盘。
public struct MinutesCheckContext {
  public let meetingID: String
  public let queue: [CheckQueueItem]
  /// 当前 minutes.json 的字节 SHA-256:判定与哪一版纪要对应的唯一凭据。
  public let currentFingerprint: String
  /// 盘上已有的核对记录(可能对应旧指纹);nil = 从未核对过。
  public let storedRecord: MeetingCheckRecord?
  /// 已结算显示名的转写行(复用既有解析,不重写解析器),摘录从这里切。
  public let transcriptRows: [TranscriptDisplayRow]
  public let ledgerContext: CheckLedgerContext
  /// 落盘 check.json;返回错误描述,nil = 成功。静默失败等于骗用户判定存上了。
  public let save: (MeetingCheckRecord) -> String?
  /// 复制反馈走既有通道(G2 的 reportCopySuccess),不另起 toast。
  public let reportCopy: (String) -> Void

  public init(
    meetingID: String,
    queue: [CheckQueueItem],
    currentFingerprint: String,
    storedRecord: MeetingCheckRecord?,
    transcriptRows: [TranscriptDisplayRow],
    ledgerContext: CheckLedgerContext,
    save: @escaping (MeetingCheckRecord) -> String?,
    reportCopy: @escaping (String) -> Void
  ) {
    self.meetingID = meetingID
    self.queue = queue
    self.currentFingerprint = currentFingerprint
    self.storedRecord = storedRecord
    self.transcriptRows = transcriptRows
    self.ledgerContext = ledgerContext
    self.save = save
    self.reportCopy = reportCopy
  }
}

/// 核对工作台正文:待核队列 + 纪要条目与转写原话并排 + 一键判定 + 补漏登记。
/// 判定永远是用户做的,产品只搬运和记账。
///
/// 红线:列表容器**不开启文本选择**(08-16 卡死事故同款组合,UIHierarchy 对本文件
/// 有零词面反断言——连注释都不许出现那个修饰符);跳转复用 `onJumpToTranscript`
/// (B4 回程自动生效)。
public struct VerifyWorkbenchView: View {
  let context: MinutesCheckContext
  let onJumpToTranscript: ((TimeInterval) -> Void)?

  @Environment(\.textScale) private var textScale
  @State private var record: MeetingCheckRecord
  /// 最近一次成功落盘(或初始)的记录:onDisappear 兜底只在真有未存改动时才写,
  /// 光开关工作台看一眼不许凭空生出 check.json。
  @State private var lastPersisted: MeetingCheckRecord
  @State private var saveError: String?
  @State private var isAddingMiss = false
  @State private var missDraftText = ""
  @State private var missDraftTime = ""
  @State private var missTimeWarning: String?
  @FocusState private var focusedNoteKey: String?

  public init(
    context: MinutesCheckContext,
    onJumpToTranscript: ((TimeInterval) -> Void)?
  ) {
    self.context = context
    self.onJumpToTranscript = onJumpToTranscript
    // 指纹匹配:接着上次判;指纹不符(纪要已再生):旧判定移入 superseded 只读留存,
    // 新队列从零开始——不静默丢弃,不自动搬移(R3)。补漏是用户自己的输入,保留可删。
    let stored = context.storedRecord
    let initial: MeetingCheckRecord
    if let stored, stored.minutesFingerprint == context.currentFingerprint {
      initial = stored
    } else if let stored {
      let displaced = stored.items.filter {
        $0.verdict != nil || $0.note?.isEmpty == false
      }
      initial = MeetingCheckRecord(
        minutesFingerprint: context.currentFingerprint,
        items: [],
        misses: stored.misses,
        supersededItems: displaced + (stored.supersededItems ?? [])
      )
    } else {
      initial = MeetingCheckRecord(minutesFingerprint: context.currentFingerprint)
    }
    _record = State(initialValue: initial)
    _lastPersisted = State(initialValue: initial)
  }

  private var tally: CheckTally {
    CheckTally.compute(record: record, queue: context.queue)
  }

  private var supersededItems: [CheckItemRecord] {
    record.supersededItems ?? []
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      summaryBar
      if let saveError {
        Text(saveError)
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.warn)
          .padding(.horizontal, Tokens.Spacing.lg)
          .padding(.bottom, Tokens.Spacing.xxs)
          .runtimeAccessibilityIdentifier("library.minutes.check.save-error")
      }
      if isAddingMiss {
        missForm
      }
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
          if !supersededItems.isEmpty {
            staleSection
          }
          if !record.misses.isEmpty {
            missesSection
          }
          if context.queue.isEmpty {
            Text("这份纪要没有需要核对的条目(无待核标记、无决定/待办、无含数字条目)。")
              .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
              .foregroundStyle(Tokens.Color.ink3)
          }
          ForEach(context.queue) { item in
            queueRow(item)
          }
        }
        .frame(maxWidth: Tokens.Layout.workbenchContentWidth, alignment: .leading)
        .padding(.horizontal, Tokens.Spacing.lg)
        .padding(.vertical, Tokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .runtimeAccessibilityIdentifier("library.minutes.check.workbench")
    // 兜底:关工作台开关/切场/切页签时 TextField 不一定先失焦,敲了一半的备注不许
    // 静默丢。视图已在拆除,存不上也无处报错,尽力写一次;无改动时零写盘。
    .onDisappear {
      if record != lastPersisted {
        _ = context.save(record)
      }
    }
  }

  // MARK: - 汇总条

  private var summaryBar: some View {
    HStack(spacing: Tokens.Spacing.sm) {
      Text(
        "核对 \(tally.decided)/\(tally.total) · 捏造 \(tally.fabricated)"
          + " · 漏 \(tally.missed) · 存疑 \(tally.doubts)"
      )
      .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
      .foregroundStyle(Tokens.Color.ink2)
      .runtimeAccessibilityIdentifier("library.minutes.check.summary")
      Spacer()
      Button("+ 补漏") {
        isAddingMiss.toggle()
        missTimeWarning = nil
      }
      .buttonStyle(.textAction)
      .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
      .foregroundStyle(Tokens.Color.acDeep)
      .help("登记 JustSaid 漏掉的关键信息(计入漏关键数)；时间戳可选，不发明时间")
      .runtimeAccessibilityIdentifier("library.minutes.check.add-miss")
      Button("复制台账行") {
        copyLedgerRow()
      }
      .buttonStyle(.textAction)
      .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
      .foregroundStyle(Tokens.Color.acDeep)
      .help("输出与 research/acceptance/ledger.md 表头同构的一行；完整单等脚本列留空不冒填")
      .runtimeAccessibilityIdentifier("library.minutes.check.copy-ledger")
    }
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.xs)
    .background(Tokens.Color.pane)
  }

  // MARK: - 补漏

  private var missForm: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      HStack(spacing: Tokens.Spacing.xs) {
        TextField("JustSaid 漏了什么(必填)", text: $missDraftText)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: Tokens.FontSize.uiEmphasis))
          .runtimeAccessibilityIdentifier("library.minutes.check.miss-text")
        TextField("时间 mm:ss(可选)", text: $missDraftTime)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: Tokens.FontSize.uiEmphasis))
          .frame(width: 130)
          .runtimeAccessibilityIdentifier("library.minutes.check.miss-time")
        Button("登记") {
          commitMiss()
        }
        .disabled(
          missDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .runtimeAccessibilityIdentifier("library.minutes.check.miss-commit")
        Button("取消") {
          isAddingMiss = false
          missDraftText = ""
          missDraftTime = ""
          missTimeWarning = nil
        }
      }
      if let missTimeWarning {
        Text(missTimeWarning)
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.warn)
      }
    }
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.bottom, Tokens.Spacing.xs)
  }

  private func commitMiss() {
    let text = missDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let timeText = missDraftTime.trimmingCharacters(in: .whitespaces)
    var seconds: Double?
    if !timeText.isEmpty {
      // 不发明时间:格式解析不了就明说,不静默丢、不猜。
      guard let parsed = TranscriptAnchor(timecode: timeText).seconds else {
        missTimeWarning = "时间格式要 mm:ss 或 hh:mm:ss；留空表示不记时间"
        return
      }
      seconds = parsed
    }
    record.misses.append(CheckMissEntry(text: text, atSeconds: seconds))
    persist()
    missDraftText = ""
    missDraftTime = ""
    missTimeWarning = nil
    isAddingMiss = false
  }

  private var missesSection: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      ForEach(record.misses) { miss in
        HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
          Text("漏")
            .font(.system(size: Tokens.FontSize.badge, weight: .semibold))
            .foregroundStyle(Tokens.Color.warn)
            .padding(.horizontal, Tokens.Spacing.xs)
            .padding(.vertical, Tokens.Spacing.hairline)
            .background(Tokens.Color.warnSoft)
            .clipShape(Capsule())
          Text(missLabel(miss))
            .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
            .foregroundStyle(Tokens.Color.ink2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer()
          // 删的是用户自己的补漏输入,不属不可逆操作,不过确认。
          Button {
            record.misses.removeAll { $0.id == miss.id }
            persist()
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(IconHoverButtonStyle(base: Tokens.Color.ink4, hover: Tokens.Color.ink2))
          .help("删除这条补漏")
          .runtimeAccessibilityIdentifier("library.minutes.check.miss-remove")
        }
      }
    }
    .padding(Tokens.Spacing.xsm)
    .background(RoundedRectangle(cornerRadius: Tokens.Radius.widget).fill(Tokens.Color.cardWash))
  }

  private func missLabel(_ miss: CheckMissEntry) -> String {
    guard let seconds = miss.atSeconds, seconds.isFinite else { return miss.text }
    return "\(TranscriptAnchor(seconds: seconds).timecode) \(miss.text)"
  }

  // MARK: - 旧版纪要判定(只读留存)

  private var staleSection: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      Text("以下判定对应旧版纪要(纪要已重新生成，新队列从零开始)")
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        .foregroundStyle(Tokens.Color.warn)
        .runtimeAccessibilityIdentifier("library.minutes.check.stale-banner")
      ForEach(Array(supersededItems.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
          if let sectionLabel = item.sectionLabel {
            sectionChip(sectionLabel)
          }
          Text(item.text ?? item.itemKey)
            .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
            .foregroundStyle(Tokens.Color.ink3)
            .fixedSize(horizontal: false, vertical: true)
          if let verdict = item.verdict {
            Text(verdictLabel(verdict))
              .font(.system(size: Tokens.FontSize.caption, weight: .semibold))
              .foregroundStyle(verdictColor(verdict))
          }
          if let note = item.note, !note.isEmpty {
            Text(note)
              .font(.system(size: Tokens.FontSize.caption))
              .foregroundStyle(Tokens.Color.ink4)
          }
        }
      }
    }
    .padding(Tokens.Spacing.xsm)
    .background(RoundedRectangle(cornerRadius: Tokens.Radius.widget).fill(Tokens.Color.warnSoft))
  }

  // MARK: - 队列行

  private func queueRow(_ item: CheckQueueItem) -> some View {
    let stored = record.items.first { $0.itemKey == item.itemKey }
    return VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      HStack(alignment: .top, spacing: Tokens.Spacing.md) {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
          HStack(spacing: Tokens.Spacing.xs) {
            if stored?.verdict != nil {
              Image(systemName: "checkmark.circle.fill")
                .font(.system(size: Tokens.FontSize.caption))
                .foregroundStyle(Tokens.Color.ink4)
                .accessibilityLabel("已判定")
                .runtimeAccessibilityIdentifier("library.minutes.check.decided")
            }
            sectionChip(item.sectionLabel)
            evidenceBadge(item)
            TranscriptAnchorButton(anchor: item.anchor, onJump: onJumpToTranscript)
          }
          Text(item.text)
            .font(.system(size: textScale.size(Tokens.FontSize.body)))
            .foregroundStyle(stored?.verdict == nil ? Tokens.Color.ink2 : Tokens.Color.ink3)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        excerptColumn(item)
      }
      verdictRow(item, stored: stored)
    }
    .padding(Tokens.Spacing.sm)
    // 08-09 层级语义(批5 接线):队列卡是坐在 card 页底上的浮起层,用 surface2,
    // 不再 card 叠 card(深色下倒挂成凹槽)。
    .background(
      RoundedRectangle(cornerRadius: Tokens.Radius.card).fill(Tokens.Color.surface2)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.card)
        .stroke(Tokens.Color.surface2Line, lineWidth: 1)
    )
  }

  @ViewBuilder
  private func evidenceBadge(_ item: CheckQueueItem) -> some View {
    if item.isMarkedToVerify {
      SummaryMarkerBadge(kind: .toVerify)
    } else if item.evidence == .confirmed {
      SummaryMarkerBadge(kind: .convergence, label: "✓ 已确认")
    } else if item.evidence == .corrected {
      SummaryMarkerBadge(kind: .revision)
    }
  }

  // MARK: - 转写摘录(右列)

  private func excerptColumn(_ item: CheckQueueItem) -> some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
      if let seconds = item.anchor?.seconds {
        let lines = Self.excerptLines(around: seconds, in: context.transcriptRows)
        if lines.isEmpty {
          Text("锚点附近没有转写行")
            .font(.system(size: Tokens.FontSize.secondary))
            .foregroundStyle(Tokens.Color.ink4)
        } else {
          ForEach(lines, id: \.overrideKey) { line in
            (Text("[\(line.timestamp)] \(line.speaker)：")
              .foregroundStyle(Tokens.Color.ink4)
              + Text(line.text).foregroundStyle(Tokens.Color.ink3))
              .font(.system(size: textScale.size(Tokens.FontSize.secondary)))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      } else {
        // 无锚点照样可判;不发明时间(既有纪律)。
        Text("无锚点")
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.ink4)
          .runtimeAccessibilityIdentifier("library.minutes.check.no-anchor")
      }
    }
    .frame(width: Tokens.Layout.workbenchExcerptWidth, alignment: .leading)
    .padding(Tokens.Spacing.xs)
    .background(
      RoundedRectangle(cornerRadius: Tokens.Radius.widget).fill(Tokens.Color.cardWash)
    )
  }

  /// 摘录:anchor ±20 秒内的发言行,取离锚点最近的最多 5 行(按行序展示)。
  /// 锚点落在一段长发言中间时窗口可能空:补上覆盖行(最后一条起点 ≤ 锚点的行),
  /// 那正是锚点所指的发言——仍是真实转写行,不是发明。
  static func excerptLines(
    around seconds: TimeInterval,
    in rows: [TranscriptDisplayRow]
  ) -> [TranscriptSpeechLine] {
    let speech: [(line: TranscriptSpeechLine, seconds: TimeInterval)] = rows.compactMap { row in
      guard
        case .speech(let line) = row,
        let lineSeconds = TranscriptAnchor(timecode: line.timestamp).seconds
      else {
        return nil
      }
      return (line, lineSeconds)
    }
    var window = speech.filter { abs($0.seconds - seconds) <= 20 }
    if window.isEmpty, let covering = speech.last(where: { $0.seconds <= seconds }) {
      window = [covering]
    }
    let sorted = window.sorted {
      abs($0.seconds - seconds) < abs($1.seconds - seconds)
    }
    let nearest = sorted.prefix(5)
    return nearest.sorted { $0.line.index < $1.line.index }.map(\.line)
  }

  // MARK: - 判定

  private func verdictRow(_ item: CheckQueueItem, stored: CheckItemRecord?) -> some View {
    HStack(spacing: Tokens.Spacing.xs) {
      verdictButton(
        item,
        verdict: .correct,
        label: "对",
        identifier: "library.minutes.check.verdict-correct",
        stored: stored
      )
      verdictButton(
        item,
        verdict: .wrong,
        label: "错",
        identifier: "library.minutes.check.verdict-wrong",
        stored: stored
      )
      verdictButton(
        item,
        verdict: .doubt,
        label: "存疑",
        identifier: "library.minutes.check.verdict-doubt",
        stored: stored
      )
      noteField(item, stored: stored)
    }
  }

  private func verdictButton(
    _ item: CheckQueueItem,
    verdict: CheckVerdict,
    label: String,
    identifier: String,
    stored: CheckItemRecord?
  ) -> some View {
    let isActive = stored?.verdict == verdict
    return Button {
      setVerdict(verdict, for: item)
    } label: {
      Text(label)
        .font(.system(size: Tokens.FontSize.ui, weight: isActive ? .semibold : .regular))
        .foregroundStyle(isActive ? verdictColor(verdict) : Tokens.Color.ink3)
        .padding(.horizontal, Tokens.Spacing.sm)
        .padding(.vertical, Tokens.Spacing.hairline)
        .background(
          Capsule().fill(isActive ? verdictSoftColor(verdict) : Color.clear)
        )
        .overlay(
          Capsule().stroke(
            isActive ? verdictColor(verdict) : Tokens.Color.line,
            lineWidth: 1
          )
        )
    }
    .buttonStyle(.plain)
    // 已选中时描边本就是判定色,悬停只对未选中的两颗生效(与 SourceTagLabel 同口径)。
    .hoverStrokeOutline(cornerRadius: Tokens.Radius.pill)
    .runtimeAccessibilityIdentifier(identifier)
  }

  private func noteField(_ item: CheckQueueItem, stored: CheckItemRecord?) -> some View {
    TextField(
      "备注",
      text: Binding(
        get: { stored?.note ?? "" },
        set: { newValue in
          mutateItem(item, persistNow: false) { $0.note = newValue }
        }
      )
    )
    .textFieldStyle(.plain)
    .font(.system(size: Tokens.FontSize.ui))
    .foregroundStyle(Tokens.Color.ink2)
    .padding(.horizontal, Tokens.Spacing.xs)
    .padding(.vertical, Tokens.Spacing.hairline)
    .background(
      RoundedRectangle(cornerRadius: Tokens.Radius.widget).fill(Tokens.Color.cardWash)
    )
    .focused($focusedNoteKey, equals: item.itemKey)
    // 失焦即存(提交也存):不逐键写盘,也不让敲了一半的备注静默丢掉。
    .onSubmit { persist() }
    .onChange(of: focusedNoteKey) { previous, _ in
      if previous == item.itemKey {
        persist()
      }
    }
    .runtimeAccessibilityIdentifier("library.minutes.check.note")
  }

  /// 同键再点一次 = 取消判定(可改判的自然延伸);换键 = 改判。
  private func setVerdict(_ verdict: CheckVerdict, for item: CheckQueueItem) {
    mutateItem(item) { stored in
      if stored.verdict == verdict {
        stored.verdict = nil
        stored.decidedAt = nil
      } else {
        stored.verdict = verdict
        stored.decidedAt = Date()
      }
    }
  }

  private func mutateItem(
    _ item: CheckQueueItem,
    persistNow: Bool = true,
    _ mutation: (inout CheckItemRecord) -> Void
  ) {
    var items = record.items
    if let index = items.firstIndex(where: { $0.itemKey == item.itemKey }) {
      mutation(&items[index])
    } else {
      // text/sectionLabel 快照只服务纪要再生后的只读展示;指纹匹配时以现算队列为准。
      var fresh = CheckItemRecord(
        itemKey: item.itemKey,
        category: item.category,
        text: item.text,
        sectionLabel: item.sectionLabel
      )
      mutation(&fresh)
      items.append(fresh)
    }
    record.items = items
    if persistNow {
      persist()
    }
  }

  private func persist() {
    saveError = context.save(record)
    if saveError == nil {
      lastPersisted = record
    }
  }

  private func copyLedgerRow() {
    let row = CheckLedgerRow.markdown(
      context: context.ledgerContext,
      record: record,
      queue: context.queue
    )
    NSPasteboard.general.clearContents()
    if NSPasteboard.general.setString(row, forType: .string) {
      context.reportCopy("已复制台账行")
    }
  }

  // MARK: - 小件

  private func sectionChip(_ label: String) -> some View {
    Text(label)
      .font(.system(size: Tokens.FontSize.badge, weight: .semibold))
      .foregroundStyle(Tokens.Color.ink3)
      .padding(.horizontal, Tokens.Spacing.xs)
      .padding(.vertical, Tokens.Spacing.hairline)
      .overlay(Capsule().stroke(Tokens.Color.line, lineWidth: 1))
  }

  private func verdictLabel(_ verdict: CheckVerdict) -> String {
    switch verdict {
    case .correct: return "对"
    case .wrong: return "错"
    case .doubt: return "存疑"
    }
  }

  private func verdictColor(_ verdict: CheckVerdict) -> Color {
    switch verdict {
    case .correct: return Tokens.Color.resolved
    case .wrong: return Tokens.Color.disagreement
    case .doubt: return Tokens.Color.warn
    }
  }

  private func verdictSoftColor(_ verdict: CheckVerdict) -> Color {
    switch verdict {
    case .correct: return Tokens.Color.resolvedSoft
    case .wrong: return Tokens.Color.disagreementSoft
    case .doubt: return Tokens.Color.warnSoft
    }
  }
}
