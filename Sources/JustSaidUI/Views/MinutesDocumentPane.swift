import JustSaidCore
import SwiftUI

/// 纪要页签正文:生成期间把**同一份缓冲区**投影成可读雏形(或按开关显示逐字节原文),
/// 平时显示盘上产物。同一个缓冲区、两种画法——纪律「内容同一 ≠ 像素同一」的落地(prd)。
///
/// 显隐判断全部收在本视图内(verification-discipline 红线 6):调用点无条件实例化;
/// `liveBuffer == nil` 时不渲染任何 live-minutes 标识(UIHierarchy 有空态反断言),
/// 「查看原始数据」开关只在有生成中缓冲区时出现——它既是取证视图,
/// 也是对「界面没在骗你」的可见承诺(D3),失败取证态同样保留。
public struct MinutesDocumentPane: View {
  private let language: MeetingLanguage
  private let liveBuffer: String?
  private let document: MeetingDocument
  private let scrollOffset: Binding<CGFloat>?
  @Binding private var showsRaw: Bool
  /// 核对工作台上下文(08-17 R-a)。nil = 调用点没有核对能力(纯布局探针/截图),
  /// 入口整行缺席;显隐仍由本视图裁决(生成态/无等价 sidecar 一律不出现)。
  private let checkContext: MinutesCheckContext?
  @Binding private var showsCheck: Bool
  /// false = 核对开关已在纪要页工具行,本 pane 不再画一份。
  private let embedsCheckToggle: Bool

  @Environment(\.textScale) private var textScale

  public init(
    language: MeetingLanguage,
    liveBuffer: String?,
    document: MeetingDocument,
    showsRaw: Binding<Bool>,
    scrollOffset: Binding<CGFloat>? = nil,
    checkContext: MinutesCheckContext? = nil,
    showsCheck: Binding<Bool> = .constant(false),
    embedsCheckToggle: Bool = true
  ) {
    self.language = language
    self.liveBuffer = liveBuffer
    self.document = document
    self.scrollOffset = scrollOffset
    self._showsRaw = showsRaw
    self.checkContext = checkContext
    self._showsCheck = showsCheck
    self.embedsCheckToggle = embedsCheckToggle
  }

  public var body: some View {
    if let liveBuffer {
      let snapshot = PartialMinutesScanner.scan(liveBuffer)
      VStack(alignment: .leading, spacing: 0) {
        toolbar(snapshot)
        Divider()
        if showsRaw {
          rawView(liveBuffer)
        } else {
          progressiveView(snapshot)
        }
      }
    } else if let checkContext, isCheckEligible {
      VStack(alignment: .leading, spacing: 0) {
        if embedsCheckToggle {
          checkToolbar
          Divider()
        }
        if showsCheck {
          VerifyWorkbenchView(
            context: checkContext,
            onJumpToTranscript: document.onJumpToTranscript
          )
          // 换场/纪要再生都要重置工作台内部状态(判定记录随指纹走)。
          .id("\(checkContext.meetingID)#\(checkContext.currentFingerprint)")
        } else {
          MeetingDocumentView(document: document, scrollOffset: scrollOffset)
        }
      }
    } else {
      MeetingDocumentView(document: document, scrollOffset: scrollOffset)
    }
  }

  /// 核对入口门(PRD):有规范化 minutes.json 且结构化视图**真能构造**(五节全等),
  /// 非生成态(上面的 liveBuffer 分支已排除)。英文版/历史修订的 document 不带
  /// structuredMinutes,自然不出现。
  private var isCheckEligible: Bool {
    guard
      let structuredMinutes = document.structuredMinutes,
      let body = document.body
    else {
      return false
    }
    return MinutesStructuredView.canRender(
      document: structuredMinutes,
      minutesMarkdown: body
    )
  }

  /// 「核对」开关行:开启后正文区切换为核对工作台;关闭回到结构化纪要。
  /// 呈现态不落盘,重开默认关(由窗口级 model 持有并在换场时复位)。
  private var checkToolbar: some View {
    HStack(spacing: Tokens.Spacing.sm) {
      Spacer()
      Toggle("核对", isOn: $showsCheck)
        .toggleStyle(.checkbox)
        .font(.system(size: Tokens.FontSize.secondary))
        .foregroundStyle(Tokens.Color.ink3)
        .help(
          "把待核数字、决定与待办列成核对队列，与转写原话并排逐条判定；"
            + "判定只写 check.json，纪要与转写产物一个字节不动"
        )
        .runtimeAccessibilityIdentifier("library.minutes.check-toggle")
    }
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.xxs)
    .background(Tokens.Color.pane)
  }

  /// 工具行:真实计数(D4,只报解析出的完整条目) + 「查看原始数据」开关(D3)。
  private func toolbar(_ snapshot: PartialMinutesSnapshot) -> some View {
    HStack(spacing: Tokens.Spacing.sm) {
      if let summary = snapshot.progressSummary(language: language) {
        Text(summary)
          .font(.system(size: Tokens.FontSize.secondary))
          .foregroundStyle(Tokens.Color.ink3)
          .runtimeAccessibilityIdentifier("library.live-minutes-counts")
      }
      Spacer()
      Toggle("查看原始数据", isOn: $showsRaw)
        .toggleStyle(.checkbox)
        .font(.system(size: Tokens.FontSize.secondary))
        .foregroundStyle(Tokens.Color.ink3)
        .help("切到模型返回的逐字节原文——与排版视图是同一份内容，也与盘上的半成品文件一致")
        .runtimeAccessibilityIdentifier("library.live-minutes-raw-toggle")
    }
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.xxs)
    .background(Tokens.Color.pane)
  }

  /// 排版视图:正文只能从缓冲区切出(`rendering.text(for:)`),装饰仅限
  /// 固定板块标题、列表圆点与未完成光标——见 `PartialMinutesRendering` 的类型约束。
  private func progressiveView(_ snapshot: PartialMinutesSnapshot) -> some View {
    let rendering = PartialMinutesRenderer.render(snapshot)
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if rendering.lines.isEmpty {
            // 状态提示,不是纪要内容:模型还在写结构前奏(标题/路径),没有可投影的条目。
            Text(language == .english ? "Drafting…" : "正在起草，正文马上开始写出…")
              .font(.system(size: textScale.size(Tokens.FontSize.bodyMinimum)))
              .foregroundStyle(Tokens.Color.ink3)
          }
          ForEach(Array(rendering.lines.enumerated()), id: \.offset) { _, line in
            lineView(line, rendering: rendering)
          }
          Color.clear.frame(height: 1).id("live-minutes-bottom")
        }
        .frame(maxWidth: Tokens.Layout.readingContentWidth, alignment: .leading)
        .padding(.horizontal, Tokens.Spacing.lg)
        .padding(.vertical, Tokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .onChange(of: snapshot.source) {
        proxy.scrollTo("live-minutes-bottom", anchor: .bottom)
      }
    }
    .runtimeAccessibilityIdentifier("library.live-minutes-preview")
  }

  @ViewBuilder
  private func lineView(
    _ line: PartialMinutesRendering.Line,
    rendering: PartialMinutesRendering
  ) -> some View {
    switch line {
    case .sectionHeading(let kind):
      Text(kind.title(for: language))
        .font(.system(size: textScale.size(Tokens.FontSize.headingCompact), weight: .bold))
        .foregroundStyle(Tokens.Color.ink)
        .padding(.top, Tokens.Spacing.smd)
        .padding(.bottom, Tokens.Spacing.hairline)
    case .item:
      HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
        Circle()
          .fill(Tokens.Color.ink4)
          .frame(width: 4, height: 4)
          .padding(.top, textScale.size(Tokens.FontSize.body) * 0.5)
        Text(rendering.text(for: line) ?? "")
          .font(.system(size: textScale.size(Tokens.FontSize.body)))
          .foregroundStyle(Tokens.Color.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, Tokens.Spacing.hairline)
    case .inFlight:
      // 未完成标记:空心圆点 + 光标,与完成条目在视觉上可区分(R1)。
      HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
        Circle()
          .stroke(Tokens.Color.ink4, lineWidth: 1)
          .frame(width: 4, height: 4)
          .padding(.top, textScale.size(Tokens.FontSize.body) * 0.5)
        (Text(rendering.text(for: line) ?? "")
          + Text("▌").foregroundStyle(Tokens.Color.acDeep))
          .font(.system(size: textScale.size(Tokens.FontSize.body)))
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, Tokens.Spacing.hairline)
    }
  }

  /// 取证视图:逐字节原文,与排版视图共用同一个 `liveBuffer`,
  /// 也就是与盘上 `.md.partial` 同一份(AC3 既有断言看护)。
  private func rawView(_ buffer: String) -> some View {
    ScrollView {
      Text(buffer)
        .font(.system(size: textScale.size(Tokens.FontSize.ui), design: .monospaced))
        .foregroundStyle(Tokens.Color.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.Spacing.lg)
        .padding(.vertical, Tokens.Spacing.md)
    }
    .runtimeAccessibilityIdentifier("library.live-minutes-raw")
  }
}
