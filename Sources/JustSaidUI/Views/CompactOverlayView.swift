import JustSaidCore
import SwiftUI

/// 把手展开与悬浮小窗共用五态内容卡。关闭只关显示,确认只针对渲染时的点名。
public struct CompactOverlayView: View {
  @ObservedObject var model: CompactOverlayViewModel
  @Environment(\.textScale) private var textScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.presenceDecorationActive) private var isActive

  public init(model: CompactOverlayViewModel) { self.model = model }

  static let closeZoneWidth = Tokens.V1.Size.overlayCloseZone
  private var isPending: Bool { model.pendingEvent != nil }
  private var hasTopBand: Bool {
    isPending || model.isMicrophonePaused || model.actionConfirmation != nil
  }
  private var transition: Animation {
    .easeInOut(
      duration: reduceMotion ? Tokens.Motion.presenceReducedFade : Tokens.Motion.presenceTransition)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.carrier == .window {
        Capsule()
          .fill(Tokens.V1.Color.ink4)
          .frame(width: Tokens.V1.Size.controlSm, height: Tokens.V1.Size.overlayGripHeight)
          .frame(maxWidth: .infinity)
          .padding(.top, Tokens.V1.Space.xs)
          .padding(.bottom, hasTopBand ? Tokens.V1.Space.xs : 0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
          .runtimeAccessibilityIdentifier("compact.grip")
      }
      if let event = model.pendingEvent {
        NameAlertNameZone(event: event, onAcknowledge: model.onAcknowledge)
          .padding(.leading, Tokens.V1.Space.md)
          .padding(.trailing, Self.closeZoneWidth)
          .padding(.vertical, Tokens.V1.Space.sm)
          .background(Tokens.V1.Color.callSoft)
          .transition(.opacity)
          .runtimeAccessibilityIdentifier("compact.name-alert")
      }
      // 暂停是常驻状态,即使点名出现也保留恢复入口。
      if model.isMicrophonePaused { microphonePausedStrip.transition(.opacity) }
      if let text = model.actionConfirmation { receiptStrip(text).transition(.opacity) }
      header
      summaryContent
      footer
    }
    .frame(width: Tokens.V1.Size.overlayWidth, alignment: .topLeading)
    // 按住时面板几何冻结:先压摘要,不足时再裁非交互头部,操作始终留在窗内。
    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    .background(Tokens.V1.Color.raised)
    .clipShape(RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg))
    .overlay { PresenceCardRim(isPending: isPending) }
    .overlay(alignment: .topTrailing) { closeButton }
    .animation(transition, value: model.pendingEvent?.id)
    .animation(transition, value: model.isMicrophonePaused)
    .animation(transition, value: model.actionConfirmation)
    .accessibilityElement(children: .contain)
  }

  private var closeButton: some View {
    Button(action: model.onClose) {
      Image(systemName: "xmark")
        .font(.system(size: Tokens.V1.Text.micro.size, weight: .semibold))
    }
    .buttonStyle(.v1Icon.height(Tokens.V1.Size.controlSm))
    .accessibilityLabel("关闭悬浮显示")
    .help("关闭悬浮显示；不改变点名提醒设置，录音与总结继续")
    .runtimeAccessibilityIdentifier("compact.close")
    .padding(.top, Tokens.V1.Space.s2xs)
    .padding(.trailing, Tokens.V1.Space.s2xs)
  }

  private var header: some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      Circle()
        .fill(model.lines.isEmpty ? Tokens.V1.Color.accent : Tokens.V1.Color.rec)
        .frame(width: Tokens.V1.Space.xs, height: Tokens.V1.Space.xs)
        .accessibilityHidden(true)
      Text(model.lines.isEmpty ? "正在听…" : (model.topicTitle.map { "当前正在聊 · \($0)" } ?? "当前正在聊"))
        .font(Tokens.V1.Text.micro.font)
        .foregroundStyle(Tokens.V1.Color.ink2)
      Spacer(minLength: Tokens.V1.Space.xs)
      Group {
        if model.lines.isEmpty {
          TimelineView(.animation(minimumInterval: 1, paused: !isActive)) { context in
            Text(
              ElapsedTime.shortLabel(
                model.startedAt.map { context.date.timeIntervalSince($0) } ?? 0))
          }
        } else {
          Text("覆盖至 \(model.coveredUntilLabel)")
        }
      }
      .font(Tokens.V1.Text.meta.font)
      .monospacedDigit()
      .foregroundStyle(Tokens.V1.Color.ink3)
    }
    .lineLimit(1)
    .frame(
      minHeight: model.isContentGeometryHeld ? 0 : Tokens.V1.Size.controlLg,
      idealHeight: Tokens.V1.Size.controlLg, maxHeight: Tokens.V1.Size.controlLg
    )
    .clipped()
    .layoutPriority(-1)
    .runtimeAccessibilityIdentifier("compact.header")
    .padding(.leading, Tokens.V1.Space.md)
    .padding(.trailing, Self.closeZoneWidth)
  }

  private var bodyFont: Font { .system(size: textScale.size(Tokens.V1.Text.body.size)) }

  private var summaryContent: some View {
    Group {
      if model.lines.isEmpty {
        Text("第一段大约半分钟后成形。")
          .font(bodyFont)
          .foregroundStyle(Tokens.V1.Color.ink3)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
          .runtimeAccessibilityIdentifier("compact.content.text")
      } else {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
          ForEach(Array(model.lines.enumerated()), id: \.element.id) { index, line in
            HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
              Text("•").foregroundStyle(Tokens.V1.Color.ink4).accessibilityHidden(true)
              RichText(line.text)
                .foregroundStyle(Tokens.V1.Color.ink2)
                .lineLimit(model.lines.count == 1 ? 3 : (index == 0 ? 2 : 1))
                .truncationMode(.tail)
                .runtimeAccessibilityIdentifier("compact.content.text")
            }
            .font(bodyFont)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .frame(
      minHeight: model.isContentGeometryHeld
        ? 0 : textScale.size(Tokens.V1.Size.overlaySummaryMinHeight),
      idealHeight: textScale.size(Tokens.V1.Size.overlaySummaryMinHeight),
      maxHeight: textScale.size(Tokens.V1.Size.overlaySummaryMinHeight), alignment: .topLeading
    )
    .clipped()
    .layoutPriority(-2)
    .padding(.horizontal, Tokens.V1.Space.md)
    .runtimeAccessibilityIdentifier("compact.content")
  }

  private var footer: some View {
    HStack(spacing: Tokens.V1.Space.s2xs) {
      Button(action: model.onMark) {
        Label(
          model.markConfirmation == nil ? "标记重点" : "已标记",
          systemImage: model.markConfirmation == nil ? "flag" : "checkmark")
      }
      .buttonStyle(
        (model.markConfirmation == nil ? V1ButtonStyle.v1Outline : V1ButtonStyle.v1Quiet)
          .height(Tokens.V1.Size.controlSm).labelFont(Tokens.V1.Text.meta.font)
      )
      .background(
        model.markConfirmation == nil ? Color.clear : Tokens.V1.Color.paper3,
        in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.sm)
      )
      .runtimeAccessibilityIdentifier("compact.mark")
      Spacer(minLength: 0)
      carrierButton
      Button(action: model.onReturnToMain) {
        HStack(spacing: Tokens.V1.Space.s2xs) {
          Text("回主窗")
          Image(systemName: "arrow.up.right.square").accessibilityHidden(true)
        }
      }
      .buttonStyle(.v1Quiet.height(Tokens.V1.Size.controlSm).labelFont(Tokens.V1.Text.meta.font))
      .runtimeAccessibilityIdentifier("compact.return-main")
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(.leading, Tokens.V1.Space.md)
    .padding(.trailing, Tokens.V1.Space.xs)
    .padding(.vertical, Tokens.V1.Space.xs)
    .padding(.top, Tokens.V1.Space.xs)
    .overlay(alignment: .top) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
        .padding(.top, Tokens.V1.Space.xs)
    }
    .runtimeAccessibilityIdentifier("compact.footer")
  }

  @ViewBuilder private var carrierButton: some View {
    switch model.carrier {
    case .dock:
      Button(action: model.onKeepOpen) { Label("保持展开", systemImage: "pin") }
        .buttonStyle(.v1Quiet.height(Tokens.V1.Size.controlSm).labelFont(Tokens.V1.Text.meta.font))
        .help("保持展开（切换为悬浮小窗）")
        .runtimeAccessibilityIdentifier("compact.keep-open")
    case .window:
      Button(action: model.onCollapseToSide) { Label("收起到侧边", systemImage: "sidebar.right") }
        .buttonStyle(.v1Quiet.height(Tokens.V1.Size.controlSm).labelFont(Tokens.V1.Text.meta.font))
        .help("收起到侧边（切换为侧边吸附）")
        .runtimeAccessibilityIdentifier("compact.collapse-to-side")
    }
  }

  private var microphonePausedStrip: some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      Image(systemName: "pause").foregroundStyle(Tokens.V1.Color.warn).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
        Text("本侧不再收音，对方/系统声仍在录")
          .font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink2)
        Text("麦克风已暂停")
          .font(Tokens.V1.Text.strong.font).foregroundStyle(Tokens.V1.Color.warn)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: model.onResumeMicrophone) { Label("恢复麦克风", systemImage: "mic") }
        .buttonStyle(
          .v1Outline.height(Tokens.V1.Size.controlSm).labelFont(Tokens.V1.Text.meta.font)
        )
        .fixedSize()
        .accessibilityLabel("恢复麦克风，本侧重新开始收音")
        .runtimeAccessibilityIdentifier("compact.mic-paused.resume")
    }
    .padding(.leading, Tokens.V1.Space.md)
    .padding(.trailing, Self.closeZoneWidth)
    .padding(.vertical, Tokens.V1.Space.sm)
    .background(Tokens.V1.Color.warnSoft)
    .fixedSize(horizontal: false, vertical: true)
    .runtimeAccessibilityIdentifier("compact.mic-paused")
  }

  private func receiptStrip(_ text: String) -> some View {
    HStack(spacing: Tokens.V1.Space.sm) {
      Image(systemName: "text.bubble").accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
        Text("热键回执").font(Tokens.V1.Text.meta.font)
        Text(text).font(Tokens.V1.Text.strong.font).foregroundStyle(Tokens.V1.Color.ink)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(Tokens.V1.Color.ink2)
    .padding(.leading, Tokens.V1.Space.md)
    .padding(.trailing, Self.closeZoneWidth)
    .padding(.vertical, Tokens.V1.Space.sm)
    .background(Tokens.V1.Color.paper2)
    .runtimeAccessibilityIdentifier("compact.action-confirmation")
  }
}
