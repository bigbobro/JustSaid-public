import Foundation
import JustSaidCore

/// 会中总结引擎（design.md 步骤 4）尚未落地前的预览数据源：初始状态与
/// `ui-final-v2.html` 逐字对齐（TE/Kavach 客户会示例），用于让界面在真实引擎接入前
/// 可运行、可核对视觉。`start()` 后短暂展示“正在听…”空态，再落定为定版截图内容，
/// 之后只做只读的呼吸/新鲜度演示（生成中骨架屏、云端失败降级各演示一轮即恢复），
/// 不会持续新增话题块——避免和验收时用作视觉基准的截图产生内容漂移。
@MainActor
public final class PreviewSummaryFeed: SummaryFeed {
  @Published public private(set) var topics: [SummaryTopic] = []
  @Published public private(set) var now: SummaryNowState = .empty
  @Published public private(set) var engineStatus: SummaryEngineStatus = .idle(
    lastFollowedLabel: "--:--"
  )
  @Published public private(set) var actionItems: [SummaryActionItem] = []

  private var demoTask: Task<Void, Never>?
  private var freshnessTask: Task<Void, Never>?

  public init() {}

  public func start() {
    stopTasks()
    topics = []
    now = .empty
    actionItems = []
    engineStatus = .idle(lastFollowedLabel: "--:--")

    demoTask = Task { [weak self] in
      await self?.runDemoTimeline()
    }
  }

  public func stop() {
    stopTasks()
    topics = []
    now = .empty
    actionItems = []
    engineStatus = .idle(lastFollowedLabel: "--:--")
  }

  public func retry() {
    guard case .unavailable = engineStatus else {
      return
    }
    engineStatus = .idle(lastFollowedLabel: now.coveredUntilLabel)
    now = SummaryNowState(
      coveredUntilLabel: now.coveredUntilLabel,
      coveredUntil: now.coveredUntil,
      lines: now.lines,
      context: now.context,
      updatedAt: Date()
    )
  }

  private func stopTasks() {
    demoTask?.cancel()
    freshnessTask?.cancel()
    demoTask = nil
    freshnessTask = nil
  }

  /// 单轮演示时间线：空态 → 落定为定版截图内容 → 一次“生成中”演示 → 一次“不可用”演示 →
  /// 此后维持新鲜度自动续期。所有延时都刻意拉长（不在几秒内就演变），
  /// 避免评审第一眼打开时看到的画面已经偏离 `ui-final-v2.html`。
  private func runDemoTimeline() async {
    guard await sleep(seconds: 2.5) else { return }

    topics = Self.demoTopics
    now = Self.demoNow
    actionItems = Self.demoActions
    engineStatus = .running

    guard await sleep(seconds: 3) else { return }
    engineStatus = .idle(lastFollowedLabel: now.coveredUntilLabel)

    beginFreshnessRefresh()

    guard await sleep(seconds: 40) else { return }
    engineStatus = .generatingNewTopic
    guard await sleep(seconds: 6) else { return }
    engineStatus = .idle(lastFollowedLabel: now.coveredUntilLabel)
    bumpFreshness()

    guard await sleep(seconds: 35) else { return }
    freshnessTask?.cancel()
    engineStatus = .unavailable(
      SummaryDegradation(
        issues: [
          SummaryDegradationIssue(
            source: .liveNow,
            cause: .timeout,
            lastUpdatedLabel: now.coveredUntilLabel,
            retryState: .waiting,
            consecutiveFailures: 1
          )
        ],
        organizerCoveredLabel: now.coveredUntilLabel,
        canRetry: true
      )
    )
    guard await sleep(seconds: 10) else { return }
    engineStatus = .idle(lastFollowedLabel: now.coveredUntilLabel)
    bumpFreshness()
    beginFreshnessRefresh()
  }

  /// 演示期间“覆盖至”仍保持新鲜（每 20 秒静默续期一次），让评审在正常查看时长内
  /// 看到的是绿色新鲜指示，而不是一打开就先看到“更新较慢”。
  private func beginFreshnessRefresh() {
    freshnessTask?.cancel()
    freshnessTask = Task { [weak self] in
      while let self, !Task.isCancelled {
        guard await self.sleep(seconds: 20) else { return }
        self.bumpFreshness()
      }
    }
  }

  private func bumpFreshness() {
    now = SummaryNowState(
      coveredUntilLabel: now.coveredUntilLabel,
      coveredUntil: now.coveredUntil,
      lines: now.lines,
      context: now.context,
      updatedAt: Date()
    )
  }

  private func sleep(seconds: Double) async -> Bool {
    do {
      try await Task.sleep(for: .seconds(seconds))
      return true
    } catch {
      return false
    }
  }
}

extension PreviewSummaryFeed {
  /// 16:00 记为相对会议开始的第 0 秒，全部演示文案内的钟点标签据此换算，
  /// 只是为了让“来自”弹层的溯源锚点与话题时间范围在内部保持一致。
  fileprivate static func elapsed(_ hour: Int, _ minute: Int, _ second: Int = 0) -> TimeInterval {
    TimeInterval((hour * 3_600 + minute * 60 + second) - 16 * 3_600)
  }

  fileprivate static let demoTopics: [SummaryTopic] = [
    SummaryTopic(
      title: "开场与项目背景",
      timeRangeLabel: "16:00 – 16:10",
      bullets: [
        SummaryBullet(
          text: .plain("TE 数字化改造整体节奏;本次会议目标:对齐平台方案与现场实施方案")
        )
      ]
    ),
    SummaryTopic(
      title: "平台方案介绍与需求对齐",
      timeRangeLabel: "16:10 – 16:35",
      bullets: [
        SummaryBullet(
          text: SummaryRichText(runs: [
            SummaryTextRun("TE 三条诉求:"),
            SummaryTextRun("报表自动化", style: .strong),
            SummaryTextRun("、新产线数据接入、管理层 "),
            SummaryTextRun("dashboard", style: .strong),
            SummaryTextRun(";共同硬约束是 "),
            SummaryTextRun("monsoon", style: .strong),
            SummaryTextRun(" 停产窗口"),
          ]),
          sourceRef: SummarySourceReference(
            sourceLabel: "系统音频（对方）",
            rangeLabel: "16:24:10 – 16:24:41",
            lines: [
              SummaryQuotedLine(
                source: .others,
                timestamp: elapsed(16, 24, 10),
                text: "We need automated reporting, sensor data from the new line, "
                  + "and a management dashboard."
              ),
              SummaryQuotedLine(
                source: .others,
                timestamp: elapsed(16, 24, 33),
                text: "And whatever we do, the monsoon shutdown window is the real "
                  + "deadline for us."
              ),
            ],
            transcriptAnchor: elapsed(16, 24, 10)
          )
        ),
        SummaryBullet(
          text: SummaryRichText(runs: [
            SummaryTextRun("新打开的点:"),
            SummaryTextRun("audit", style: .strong),
            SummaryTextRun(" 需要历史产量数据 → 历史数据迁移是前置(我方周三前给评估)"),
          ]),
          sourceRef: SummarySourceReference(
            sourceLabel: "系统音频（对方）",
            rangeLabel: "16:31:02 – 16:31:20",
            lines: [
              SummaryQuotedLine(
                source: .others,
                timestamp: elapsed(16, 31, 2),
                text: "Actually, before that — our quarterly audit needs historical "
                  + "production data, so the legacy migration isn't optional."
              )
            ],
            transcriptAnchor: elapsed(16, 31, 2)
          )
        ),
      ],
      annotations: [
        SummaryAnnotation(
          kind: .revision,
          label: "历史迁移由可选项修订为审计前置",
          anchor: TranscriptAnchor(seconds: elapsed(16, 31, 2))
        )
      ],
      revisions: [
        SummaryRevisionTrace(
          originalText: "历史数据迁移可在第二阶段再安排",
          reason: "季度审计必须使用历史产量数据",
          revisedAt: TranscriptAnchor(seconds: elapsed(16, 31, 2))
        )
      ]
    ),
    SummaryTopic(
      title: "Kavach 实施方案与讨论",
      timeRangeLabel: "16:35 – 16:57",
      bullets: [
        SummaryBullet(
          text: SummaryRichText(runs: [
            SummaryTextRun("Kavach 提出三阶段 "),
            SummaryTextRun("rollout", style: .strong),
            SummaryTextRun(",前置是约 "),
            SummaryTextRun("40 台", style: .strong),
            SummaryTextRun("老设备加装数据网关(Kavach 负责采购)"),
          ]),
          sourceRef: SummarySourceReference(
            sourceLabel: "系统音频（对方）",
            rangeLabel: "16:41:05 – 16:41:38",
            lines: [
              SummaryQuotedLine(
                source: .others,
                timestamp: elapsed(16, 41, 5),
                text: "Roughly forty legacy units need the data gateway retrofit first."
              ),
              SummaryQuotedLine(
                source: .others,
                timestamp: elapsed(16, 41, 22),
                text: "We take the procurement, that's on Kavach."
              ),
            ],
            transcriptAnchor: elapsed(16, 41, 5)
          )
        )
      ],
      visualizations: [
        .steps(
          title: "Kavach 三阶段实施流程",
          items: [
            SummaryStepItem(title: "前置", detail: "40 台加装网关", isPrerequisite: true),
            SummaryStepItem(title: "试点", detail: "2 条产线 · monsoon 前"),
            SummaryStepItem(title: "联调", detail: "与平台侧对接"),
            SummaryStepItem(title: "推广", detail: "全厂分车间"),
          ]
        ),
        .table(
          title: "双方分工确认",
          table: SummaryTable(
            headers: ["事项", "责任方", "时点"],
            rows: [
              SummaryTableRow(cells: [.plain("网关采购与安装"), .plain("Kavach"), .plain("试点前")]),
              SummaryTableRow(cells: [
                .plain("历史数据迁移评估"),
                SummaryRichText(runs: [SummaryTextRun("我方", style: .strong)]),
                .plain("下周三"),
              ]),
            ]
          )
        ),
        .timeline(
          title: "关键窗口",
          items: [
            SummaryTimelineItem(
              timeLabel: "周三",
              title: "提交迁移评估",
              anchor: TranscriptAnchor(seconds: elapsed(16, 31, 2))
            ),
            SummaryTimelineItem(
              timeLabel: "monsoon 前",
              title: "完成两条产线试点",
              anchor: TranscriptAnchor(seconds: elapsed(16, 41, 5))
            ),
          ]
        ),
        .tree(
          title: "交付范围",
          roots: [
            SummaryTreeNode(
              title: "平台侧",
              children: [
                SummaryTreeNode(title: "自动化报表"),
                SummaryTreeNode(title: "管理 dashboard"),
              ]
            ),
            SummaryTreeNode(
              title: "现场侧",
              children: [SummaryTreeNode(title: "40 台网关改造")]
            ),
          ]
        ),
        .nums(
          title: "数字口径",
          items: [
            SummaryNumberItem(
              value: "40 台",
              label: "老设备",
              context: "由 Kavach 采购网关",
              anchor: TranscriptAnchor(seconds: elapsed(16, 41, 5))
            ),
            SummaryNumberItem(value: "3 周", label: "压缩后集成期"),
          ]
        ),
        .chain(
          title: "约束到行动",
          items: [
            SummaryChainItem(
              title: "审计要历史数据",
              relationToNext: "因此"
            ),
            SummaryChainItem(
              title: "先做迁移评估",
              relationToNext: "再"
            ),
            SummaryChainItem(title: "锁定试点窗口"),
          ]
        ),
      ],
      disagreements: [
        SummaryDisagreement(
          status: .open,
          positions: [
            SummaryDisagreementPosition(
              speaker: "TE",
              text: "试点必须在 monsoon 前完成"
            ),
            SummaryDisagreementPosition(
              speaker: "Kavach",
              text: "网关采购周期仍待供应商确认"
            ),
          ]
        )
      ],
      actionItems: [
        SummaryActionItem(
          text: "周三前提交历史数据迁移评估",
          owner: "我方",
          topicTitle: "Kavach 实施方案与讨论",
          ownership: .me,
          recordedAt: TranscriptAnchor(seconds: elapsed(16, 31, 2))
        )
      ]
    ),
  ]

  fileprivate static let demoNow = SummaryNowState(
    coveredUntilLabel: "16:58",
    coveredUntil: elapsed(16, 58),
    lines: [
      SummaryNowLine(
        text: SummaryRichText(runs: [
          SummaryTextRun("对方", style: .strong),
          SummaryTextRun("确认:联调窗口若延误,集成期"),
          SummaryTextRun("压缩为三周", style: .strong),
        ])
      ),
      SummaryNowLine(
        text: SummaryRichText(runs: [
          SummaryTextRun("对方", style: .strong),
          SummaryTextRun("正在向你征询 rollout 意见", style: .callout),
          SummaryTextRun(" —— 刚点到你的名字"),
        ])
      ),
    ],
    context: SummaryNowContext(
      topicTitle: "Kavach 实施方案与讨论",
      speaker: "TE 项目负责人",
      speakingAbout: "联调窗口与压缩后的集成期",
      recentLines: [
        SummaryCurrentTranscriptLine(
          speaker: "TE",
          text: "如果联调窗口延误，集成期只能压到三周。",
          anchor: TranscriptAnchor(seconds: elapsed(16, 58))
        )
      ]
    )
  )

  fileprivate static let demoActions: [SummaryActionItem] = [
    SummaryActionItem(
      text: "周三前提交历史数据迁移评估",
      owner: "我方",
      topicTitle: "平台方案介绍与需求对齐",
      ownership: .me,
      recordedAt: TranscriptAnchor(seconds: elapsed(16, 31, 2)),
      updates: [
        SummaryActionUpdate(
          text: "Kavach 补充约 40 台设备清单",
          anchor: TranscriptAnchor(seconds: elapsed(16, 41, 5))
        )
      ]
    ),
    SummaryActionItem(
      text: "确认网关采购交期",
      owner: "Kavach",
      topicTitle: "Kavach 实施方案与讨论",
      ownership: .other,
      recordedAt: TranscriptAnchor(seconds: elapsed(16, 41, 22))
    ),
  ]
}
