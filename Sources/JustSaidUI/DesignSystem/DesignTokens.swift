import AppKit
import SwiftUI

/// UI 施工规格书（ui-spec.md）V1/V2/V9/V10 与「设计变量」区块的取值原样迁入，
/// 变量命名对应 `ui-final-v2.html` 的 CSS 自定义属性，便于逐条对照核验。
/// 任何颜色/圆角/阴影数值改动都必须能在 ui-spec.md 或 ui-final-v2.html 里找到出处。
enum Tokens {
  enum Color {
    // 中性色阶
    static let ink = SwiftUI.Color(light: 0x191d24, dark: 0xf2f2f4)
    static let ink2 = SwiftUI.Color(light: 0x4a52_61, dark: 0xb9b9c0)
    static let ink3 = SwiftUI.Color(light: 0x8b93_a3, dark: 0x96969e)
    static let ink4 = SwiftUI.Color(light: 0xb4bb_c7, dark: 0x7c7c84)
    static let line = SwiftUI.Color(light: 0xe7ea_ef, dark: 0x3a3a3e)
    static let line2 = SwiftUI.Color(light: 0xf0f2_f6, dark: 0x323236)
    static let bg = SwiftUI.Color(light: 0xf4f5_f7, dark: 0x1e1e20)
    static let card = SwiftUI.Color(light: 0xffffff, dark: 0x2a2a2d)
    static let pane = SwiftUI.Color(light: 0xfafb_fc, dark: 0x242427)
    /// 浮起层(2026-08-09 重塑 P1,用户拍板):卡片之上再浮一级的卡片底——
    /// 一页纸 sectionCard、键帽这类「坐在 card 上的卡」。浅色沿用 pane 的纸感不变;
    /// 深色按 macOS elevated 惯例**比 card 亮一档**(原 pane 深色 242427 比 card 暗,
    /// 卡片读成凹槽,走查实拍背书)。下嵌小件(徽章底/可视化部件底)用 cardWash。
    static let surface2 = SwiftUI.Color(light: 0xfafb_fc, dark: 0x363639)
    /// surface2 的描边:深色同步亮一档,让浮起读得出边缘。
    static let surface2Line = SwiftUI.Color(light: 0xe7ea_ef, dark: 0x454549)

    // 墨青（强调，V1）
    static let ac = SwiftUI.Color(light: 0x0f76_6e, dark: 0x5fd0c4)
    static let acHi = SwiftUI.Color(light: 0x1486_7d, dark: 0x77ddd2)
    static let acSoft = SwiftUI.Color(light: 0xf0fd_fa, dark: 0x173532)
    static let acLine = SwiftUI.Color(light: 0xa7f3_e4, dark: 0x356b66)
    static let acDeep = SwiftUI.Color(light: 0x0b5d_57, dark: 0xa1eee6)
    /// 高饱和强调实底。与 `acDeep` 的前景语义分离，保证两种外观下白字都有稳定对比度。
    static let accentFill = SwiftUI.Color(light: 0x0b5d_57, dark: 0x0f766e)

    // 语义（V9）
    static let me = SwiftUI.Color(light: 0x2563_eb, dark: 0x72a7ff)
    static let others = SwiftUI.Color(light: 0x5b64_72, dark: 0xb9b9c0)

    /// 录制态红：录制指示灯、计时器、录音异常常驻条、会议库「录制中」状态点共用一个语义色。
    static let rec = SwiftUI.Color(light: 0xdc26_26, dark: 0xff7a70)

    // 以下八色原先散落在视图层的行内 hex（0xdc2626/0x5c6472/…），数值原样收编，
    // 只把「出处」统一到这里，守住「改色一处改」的纪律。
    /// 长正文（转写正文、溯源引文）：比 ink2 更冷一档，长段落读起来不压眼。
    static let inkBody = SwiftUI.Color(light: 0x5c64_72, dark: 0xc7c7ce)
    /// 当前专区正文：比 inkBody 更黑，因为它是全屏最该被瞥见的一段字。
    static let nowBody = SwiftUI.Color(light: 0x2025_2e, dark: 0xf2f2f4)
    /// 当前专区径向渐变的中段薄荷白。深色 2026-08-09 P2 压饱和(荧光感,拍板口径)。
    static let washMint = SwiftUI.Color(light: 0xf8ff_fd, dark: 0x22292b)
    /// 「标记」按钮渐变的下端薄荷白。深色同上压饱和。
    static let washMark = SwiftUI.Color(light: 0xe6fb_f7, dark: 0x1e2f2e)
    /// 可视化部件底/徽章底:浅色比 card 略灰一丝让部件浮出来;
    /// 深色按 elevated 惯例在 card 与 surface2 之间亮一档(2026-08-09 P1 同批扶正)。
    static let cardWash = SwiftUI.Color(light: 0xfcfd_fe, dark: 0x343437)
    /// 顶部工具栏渐变上端。
    static let toolbarTop = SwiftUI.Color(light: 0xfdfd_fe, dark: 0x2d2d31)
    /// 顶部工具栏渐变下端。
    static let toolbarBottom = SwiftUI.Color(light: 0xf8f9_fb, dark: 0x252529)

    /// 驾驶舱控制轨(2026-08-19 A+C 混搭):轨底两个外观档恒为墨色、不随深浅外观反转——
    /// 「左黑轨」是驾驶舱的固定锚点,暗色下反转成浅灰会让它失去「控制台」语义。
    static let rail = SwiftUI.Color(light: 0x191d_24, dark: 0x191d_24)
    /// 轨内图标/文字的固定浅墨(取 ink4 浅色档同值):同理不随外观反转,
    /// 否则暗色下墨轨配深灰字不可读。
    static let railInk = SwiftUI.Color(light: 0xb4bb_c7, dark: 0xb4bb_c7)
    /// 轨内派生态(2026-08-20 批1 命名,值不变):禁用前景/分隔线/进度轨道/开启态底。
    static let railInkDisabled = railInk.opacity(0.4)
    static let railInkDivider = railInk.opacity(0.28)
    static let railInkTrack = railInk.opacity(0.3)
    static let railInkOnState = railInk.opacity(0.16)
    /// 轨上按钮开启态前景:暗色不能复用 `amber`(暗色档是软底色),否则会与开启态底重叠。
    static let railInkActive = SwiftUI.Color(light: 0xfff9_e6, dark: 0xffc9_7a)
    /// 悬停描边(2026-08-20 批1 由 5 处 ink4.opacity(0.5) 散写收编)。
    static let hoverStroke = ink4.opacity(0.5)

    // 点名高亮（V10）。深色档 2026-08-09 P2 压饱和:底更灰、字更亮,语义靠文字色承担。
    static let amber = SwiftUI.Color(light: 0xfff9_e6, dark: 0x383427)
    static let amberLine = SwiftUI.Color(light: 0xfde6_8a, dark: 0x765622)
    static let warn = SwiftUI.Color(light: 0xb453_09, dark: 0xffc97a)
    /// 软判定底(批5 补档):核对台「存疑」等软性警示垫底,比 amber 高亮底再浅一档——
    /// 解除 amber 一色三职(点名高亮底/警示横幅底/软判定底)。
    static let warnSoft = SwiftUI.Color(light: 0xfffc_f2, dark: 0x2e2b21)
    /// 唤起橙(2026-08-09 R1''' 用户拍板):Claude 品牌橙 #D97757 系,比 warn 更黄更亮,
    /// 与警示语义解耦——「返回驾驶舱」专用(描边/文字/流动扫光同一个色)。
    static let cue = SwiftUI.Color(light: 0xd977_57, dark: 0xec_a48c)

    // 大布局标注体系：同一语义在浅/深色下都只从 Tokens 取色。
    // 深色软底 2026-08-09 P2 统一「暗灰+淡色味」配方(拍板数值),告别 3d1f1d 红幕。
    static let disagreement = SwiftUI.Color(light: 0xc62828, dark: 0xff9d94)
    static let disagreementSoft = SwiftUI.Color(light: 0xfdecec, dark: 0x383028)
    static let resolved = SwiftUI.Color(light: 0x1b7a3d, dark: 0x7fd89c)
    static let resolvedSoft = SwiftUI.Color(light: 0xe7f4ec, dark: 0x24352b)
    static let revision = SwiftUI.Color(light: 0x6d28d9, dark: 0xc4a8f8)
    static let revisionSoft = SwiftUI.Color(light: 0xf1eafe, dark: 0x322d40)

    /// 骨架屏微光扫过色:暗色下白光会是一道刺目亮带,取比 line2 亮两档的灰。
    static let shimmer = SwiftUI.Color(light: 0xffffff, dark: 0x4a4a4e)
    /// 压饱和底(强调钮/录制红条)的文字色:两态同为白,但出处收在 Tokens、不走裸 .white。
    static let onAccent = SwiftUI.Color(light: 0xffffff, dark: 0xffffff)

    /// 话题节点章节色循环（f59e0b / 0ea5e9 / 10b981），只出现在空心圆环上，不进卡片。
    static let chapterAccents: [SwiftUI.Color] = [
      SwiftUI.Color(light: 0xf59e_0b, dark: 0xffb54d),
      SwiftUI.Color(light: 0x0ea5_e9, dark: 0x67c5f5),
      SwiftUI.Color(light: 0x10b9_81, dark: 0x5fd08a),
    ]

    static func chapterAccent(_ index: Int) -> SwiftUI.Color {
      guard !chapterAccents.isEmpty else {
        return ac
      }
      return chapterAccents[index % chapterAccents.count]
    }

    /// 发言人色环(N4):照 `chapterAccents` 的调性再展开一档,只点缀在名字与圆点上。
    ///
    /// 选色约束:①与「我」的 me 蓝(2563eb)拉开距离,别让人把别人错认成自己;
    /// ②不并排放红/绿这对红绿色盲最难分的组合——环里唯一的绿(10b981)与唯一的红棕
    /// (e11d48)相隔三位,连着两个人撞上这一对的概率被压到最低;③都是中高饱和的深色,
    /// 落在白底上对比度够读。
    static let speakerAccents: [SwiftUI.Color] = [
      SwiftUI.Color(light: 0x0891_b2, dark: 0x67c5f5),
      SwiftUI.Color(light: 0xd977_06, dark: 0xffb54d),
      SwiftUI.Color(light: 0x7c3a_ed, dark: 0xb794f6),
      SwiftUI.Color(light: 0x10b9_81, dark: 0x5fd08a),
      SwiftUI.Color(light: 0xdb27_77, dark: 0xff83b5),
      SwiftUI.Color(light: 0x0284_c7, dark: 0x71bdf0),
      SwiftUI.Color(light: 0xe11d_48, dark: 0xff7a70),
      SwiftUI.Color(light: 0x6572_80, dark: 0xb9b9c0),
    ]
  }

  enum Shadow {
    /// 投影浓度按外观分档(2026-08-21 走查 P-2)。**浅色档一律保持原值,逐像素不变。**
    ///
    /// 深色档必须更浓:一页纸是 card-on-card(页底与区块同为 `card`),浅色下靠 sh1 投影
    /// 落到 243/255 还读得出边界,深色下同一投影实测只差 1–2/255 —— 页底 (37,37,40) 与
    /// 卡内 (37,37,40) 完全同色,「会议骨架」「替你记」「遗留的活」三张卡的边界整个消失。
    /// 批5 拍板的底色(白卡 `card` + `Shadow.sh1`)不翻案,能动的杠杆只有投影浓度。
    /// 深色下浮起层比底色亮一档的惯例由 `surface2` / `cardWash` 承担,这里补的是
    /// 「同色相邻面之间要有分界」。
    /// 卡片：几乎贴纸。
    static let sh1: (color: SwiftUI.Color, radius: CGFloat, y: CGFloat) = (
      SwiftUI.Color(shadowLight: 0.08, shadowDark: 0.55), 2.0, 1.0
    )
    /// 浮起元素（弹出按钮、跳到最新胶囊）。
    static let sh2: (color: SwiftUI.Color, radius: CGFloat, y: CGFloat) = (
      SwiftUI.Color(shadowLight: 0.06, shadowDark: 0.5), 4.0, 2.0
    )
    /// 弹层与窗。
    static let sh3: (color: SwiftUI.Color, radius: CGFloat, y: CGFloat) = (
      SwiftUI.Color(shadowLight: 0.14, shadowDark: 0.6), 18.0, 8.0
    )
  }

  enum Radius {
    static let card: CGFloat = 10
    /// 全机控件事实标准圆角(胶囊按钮/行悬停底/嵌板,2026-08-20 批1 由 46 处直写收编)。
    static let control: CGFloat = 7
    /// 小型芯片/轮廓小钮圆角(批2 定档;1.5/2/3/4 散写站点仍留白名单待后续组件路过收编)。
    static let chip: CGFloat = 5
    /// 略大的小圆角(话题卡内嵌板/转写行悬停底/顶栏内嵌小件,2026-08-21 走查 N-7
    /// 由 4 处直写按现值收编——**不就近并入 chip(5)或 control(7)**,
    /// 那是没人要的几何改动)。
    static let chipLarge: CGFloat = 6
    static let widget: CGFloat = 8
    static let window: CGFloat = 13
    static let compactPanel: CGFloat = 14
    static let pill: CGFloat = 20
  }

  /// 间距档（偶数阶梯）。2026-08-09 清账扩档：原五档（xxs/xs/sm/md/lg）之外补
  /// hairline/xsm/smd/xl/xxl，收编视图层既有字面量（7/8/9/11/13 等中间值原系缺档倒逼）。
  /// 取距一律走这里，不再出现字面量；奇数中间值一律就近取低一档。
  enum Spacing {
    /// 微距：徽标/胶囊内的 1–3pt 级微调。
    static let hairline: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let xsm: CGFloat = 8
    static let sm: CGFloat = 10
    static let smd: CGFloat = 12
    static let md: CGFloat = 14
    static let xl: CGFloat = 16
    static let lg: CGFloat = 20
    static let xxl: CGFloat = 24
  }

  /// 字号档(2026-08-09 清账 R9 立锚):语义字号体系是 Phase B(R10)的施工项,
  /// 这里先把 07-29 F3 遗留的亮线收进 Tokens——转写/纪要正文不得小于 bodyMinimum,
  /// 修正点一律经 textScale.size(Tokens.FontSize.bodyMinimum) 取字号,不再写裸数字。
  enum FontSize {
    /// 正文下限:转写正文、纪要正文、结论/行动/待核/提案等承载会议内容的句子。
    static let bodyMinimum: CGFloat = 12
    /// 实际正文基准:正文取 12.5,正文以下的辅助层(依据/时限/证据标记)才允许更小。
    static let body: CGFloat = 12.5

    // ——— 2026-08-20 整机统一批1(R10 Phase B 施工):按全 UI 字面量直方图保值入档。
    // 归位不调值;新增字号一律先扩档再使用,View 里不再写裸数字。———
    /// 装饰性微字形(徽章圆点内的极小字)。
    static let glyphMicro: CGFloat = 7
    /// 行内记号字(精/纪记号等 40pt 行内的字母记号)。
    static let glyphTiny: CGFloat = 8
    /// 微型等宽/记号字(小时间码、微型标记)。
    static let glyphSmall: CGFloat = 8.5
    /// 最小注记。
    static let micro: CGFloat = 9
    /// 徽章/时间码。
    static let badge: CGFloat = 9.5
    /// 说明/元信息。
    static let caption: CGFloat = 10
    /// 次要内容。
    static let secondary: CGFloat = 10.5
    /// 标准控件字。
    static let ui: CGFloat = 11
    /// 强调控件字/横幅正文。
    static let uiEmphasis: CGFloat = 11.5
    /// 小节标题。
    static let headingSmall: CGFloat = 13
    /// 紧凑小节标题(纪要小节)。
    static let headingCompact: CGFloat = 13.5
    /// 卡片标题。
    static let cardTitle: CGFloat = 14
    /// 编辑器/详情标题(轨图标同值借档,icon 语义分离留后)。
    static let headline: CGFloat = 15
    /// 数字大字。
    static let displaySmall: CGFloat = 17
    /// 此刻舞台标题。
    static let stageTitle: CGFloat = 19
    /// 页标题(词典页,批4 版式对齐时再议归并)。
    static let pageTitle: CGFloat = 20
  }

  /// 动效时长档(2026-08-21 走查 N-2 立档)。取色/取距/字号在 2026-08-20「整机统一」
  /// 5 批里都已收敛,动效时长是 R2「魔法数值收敛进 tokens」在本仓的最后一块空白。
  /// **按现值入档,一个数都没调**;新增时长一律先扩档再使用,View 里不再写裸数字。
  /// `FlowMetrics` 那类布局算法参数仍然不进 tokens(换档会改几何),这里只收时间。
  enum Motion {
    /// 指针反馈(悬停/按压):spec 的「120ms easeOut」模式,全机 20 个站点同值。
    static let hover: Double = 0.12
    /// 列表条目增删就位(整理区话题卡)。
    static let listShift: Double = 0.16
    /// 滚动定位与展开收起(话题跳转、转写抽屉、锚点回跳)。
    static let scroll: Double = 0.2
    /// 回执淡出(词典「已保存」)。
    static let flashOut: Double = 0.3
    /// 回执浮现(设置页保存回执)。
    static let revealIn: Double = 0.35
    /// BreathingDots 单点呼吸周期。
    static let breath: Double = 1.15
    /// BreathingDots 三点依次延迟。与 `listShift` 同值但语义不同(一个是时长、
    /// 一个是错峰步长),照 FontSize 的既有做法分开立档、不合并。
    static let breathStagger: Double = 0.16
    /// 录制胶囊流动扫光周期。
    static let sweep: Double = 1.4
    /// 骨架微光横扫周期。
    static let shimmer: Double = 1.5
    /// PulsingDot 呼吸周期。
    static let pulse: Double = 1.8
  }

  /// 驾驶舱整理区话题卡层级(2026-08-09 重塑 P3,用户拍板 08-驾驶舱卡片层级原型-v1):
  /// 最新话题 focus(墨青左缘 + acLine 描边 + sh2 微浮起),旧话题 calm(pane 底 +
  /// line2 描边 + 标题/正文降档)——会上余光扫屏,第一眼必须落在当前话题。
  /// standard = 既有 chrome,会议库留痕页沿用,视觉零变化。
  enum CardTier {
    case standard
    case focus
    case calm

    var background: SwiftUI.Color {
      self == .calm ? Tokens.Color.pane : Tokens.Color.card
    }

    /// isInProgress/isHighlighted 的强调描边优先级仍高于层级,调用方先判它。
    var stroke: SwiftUI.Color {
      switch self {
      case .standard: return Tokens.Color.line
      case .focus: return Tokens.Color.acLine
      case .calm: return Tokens.Color.line2
      }
    }

    var titleColor: SwiftUI.Color {
      self == .calm ? Tokens.Color.ink2 : Tokens.Color.ink
    }

    var bodyColor: SwiftUI.Color {
      self == .calm ? Tokens.Color.ink3 : Tokens.Color.ink2
    }

    /// focus 的整高墨青左缘;其余层级无左缘。
    var leadingEdge: SwiftUI.Color? {
      self == .focus ? Tokens.Color.ac : nil
    }

    var shadow: (color: SwiftUI.Color, radius: CGFloat, y: CGFloat)? {
      switch self {
      case .standard: return Tokens.Shadow.sh1
      case .focus: return Tokens.Shadow.sh2
      case .calm: return nil
      }
    }
  }

  enum Layout {
    static let windowMinWidth: CGFloat = 1_040
    static let windowMinHeight: CGFloat = 640
    /// 驾驶舱 A+C 混搭确定性布局(2026-08-19 契约,替代 07-31 左栏转写三栏):
    /// 定宽控制轨 56 + 定高此刻舞台 168 + 弹性整理区(≥520) + 定宽右栏 332 +
    /// 定高转写细条 28;转写抽屉(240)是 overlay、不参与 flex,窗口最小宽因此
    /// 收成单一档 920,不再随转写展开两档跳变。
    /// 禁用 HSplitView 不变:它自记忆栏宽、不随窗口重排,三轮实测把右栏顶出窗外/
    /// 内容居中裁边;定宽+弹性在任何窗宽下总和恒等于容器宽,溢出在数学上不可能。
    static let commandRailWidth: CGFloat = 56
    /// 驾驶舱唯一的窗口最小宽(轨 56 + 整理区 ≥520 + 右栏 332 + 分隔线量级)。
    /// 旧的 920/1220 两档跳变随左栏转写一起撤销:抽屉是 overlay,展开不吃宽度。
    static let cockpitMinWidth: CGFloat = 920
    static let nowStageHeight: CGFloat = 168
    static let transcriptStripHeight: CGFloat = 28
    static let transcriptDrawerHeight: CGFloat = 240
    /// 控制轨悬停卡(闲聊/暂停)宽度。
    static let railHoverCardWidth: CGFloat = 240
    static let dashboardSidebarWidth: CGFloat = 332
    static let nowPaneMinFraction: CGFloat = 0.35
    static let nowPaneIdealFraction: CGFloat = 0.40
    static let nowPaneMaxFraction: CGFloat = 0.50

    /// 主窗工具栏高度。
    static let toolbarHeight: CGFloat = 42
    // 会议库两栏(2026-08-09 只收常量:三栏契约禁的是驾驶舱 HSplitView,
    // 库列表/详情保留系统分割器,替换属结构工作、不在清账范围)。
    static let libraryListMinWidth: CGFloat = 240
    static let libraryListIdealWidth: CGFloat = 286
    static let libraryListMaxWidth: CGFloat = 360
    /// 会议库列表行高(P4 密度 40pt;2026-08-21 批3 双行仍用此档):
    /// 上行标题+日期时长,下行徽章。
    static let libraryRowHeight: CGFloat = 40
    /// 行内 A 词汇 chip 高(2026-08-21 批3):状态点之外的精纪/完备度/部分录音/客户。
    static let libraryRowChipHeight: CGFloat = 16
    static let libraryDetailMinWidth: CGFloat = 460
    /// 库行日期时长列下限宽(批3-C;2026-08-21 批3 改到上行右对齐,不再跟徽章抢宽)。
    static let libraryRowDateWidth: CGFloat = 118
    /// 客户 chip 上限宽(原行内 88 直写收编,2026-08-21 批3)。
    static let libraryRowClientChipMaxWidth: CGFloat = 88
    /// 文档区内容限宽:阅读舒适行长,超过后回扫成本陡增。
    static let typedSummaryContentWidth: CGFloat = 780
    /// 阅读面正文限宽(2026-08-20 批1 收编五处 760 直写后与 typedSummaryContentWidth
    /// 并档到 780——详情页各页签行长自此同宽;对行长敏感可单独 revert 本行回 760)。
    static let readingContentWidth: CGFloat = typedSummaryContentWidth
    /// 核对工作台内容限宽/摘录列宽(批1 收编)。
    static let workbenchContentWidth: CGFloat = 860
    static let workbenchExcerptWidth: CGFloat = 280
    /// 结论带主角左缘(2026-08-21 批5,与列表选中左缘同宽 3pt)。
    static let accentEdgeWidth: CGFloat = 3
    static let historyContentWidth: CGFloat = 720
    /// 空态文案限宽(会议库/类型化卡片/纪要文档三处共用)。
    static let emptyStateContentWidth: CGFloat = 420
    /// 浮窗与弹层宽度。
    static let compactOverlayWidth: CGFloat = 520
    /// 缩略置顶窗固定高度：动态总结只更新内部内容，不改变面板位置。
    static let compactOverlayHeight: CGFloat = 104
    static let sourcePopoverWidth: CGFloat = 322
    static let chapterDirectoryWidth: CGFloat = 300
    /// 库顶栏溢出控件面板;与章节目录 popover 同宽(08-21)。
    static let overflowPanelWidth: CGFloat = chapterDirectoryWidth
  }
}

extension SwiftUI.Color {
  /// 投影专用:两个外观档只差不透明度,色相恒为黑。走 `NSColor(name:)` 动态解析,
  /// 与 `init(light:dark:)` 同一机制——`Color.black.opacity(_:)` 是静态值,取不到外观。
  init(shadowLight: Double, shadowDark: Double) {
    self.init(
      nsColor: NSColor(name: nil) { appearance in
        let best = appearance.bestMatch(from: [.aqua, .darkAqua])
        return NSColor(
          srgbRed: 0,
          green: 0,
          blue: 0,
          alpha: best == .darkAqua ? shadowDark : shadowLight
        )
      })
  }

  init(light: UInt32, dark: UInt32) {
    self.init(
      nsColor: NSColor(name: nil) { appearance in
        let best = appearance.bestMatch(from: [.aqua, .darkAqua])
        return NSColor(hex: best == .darkAqua ? dark : light)
      })
  }
}

extension NSColor {
  fileprivate convenience init(hex: UInt32) {
    let red = CGFloat((hex & 0xff_0000) >> 16) / 255
    let green = CGFloat((hex & 0x00_ff00) >> 8) / 255
    let blue = CGFloat(hex & 0x00_00ff) / 255
    self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
  }
}

/// 会议内容阅读缩放：默认 100%，工具栏可在五档之间逐级或直接选择。
///
/// `standard` / `large` 是已经写进用户偏好的旧 raw value，分别继续解释为 100% / 120%；
/// 新增档位使用百分比本身作稳定值，不迁移也不重写旧偏好。
public enum TextScale: String, CaseIterable, Identifiable, Sendable {
  case standard
  case percent110 = "110"
  case large
  case percent130 = "130"
  case percent140 = "140"

  public static let defaultsKey = "justsaid.textScale"

  public var id: String { rawValue }

  public var percentage: Int {
    switch self {
    case .standard: return 100
    case .percent110: return 110
    case .large: return 120
    case .percent130: return 130
    case .percent140: return 140
    }
  }

  public var displayName: String { "\(percentage)%" }

  public var previous: TextScale? {
    guard let index = Self.allCases.firstIndex(of: self), index > Self.allCases.startIndex else {
      return nil
    }
    return Self.allCases[Self.allCases.index(before: index)]
  }

  public var next: TextScale? {
    guard
      let index = Self.allCases.firstIndex(of: self),
      index < Self.allCases.index(before: Self.allCases.endIndex)
    else {
      return nil
    }
    return Self.allCases[Self.allCases.index(after: index)]
  }

  public static func persisted(_ rawValue: String?) -> TextScale {
    rawValue.flatMap(Self.init(rawValue:)) ?? .standard
  }

  public func size(_ base: CGFloat) -> CGFloat {
    base * CGFloat(percentage) / 100
  }
}

private struct TextScaleKey: EnvironmentKey {
  static let defaultValue: TextScale = .standard
}

extension EnvironmentValues {
  public var textScale: TextScale {
    get { self[TextScaleKey.self] }
    set { self[TextScaleKey.self] = newValue }
  }
}

extension View {
  /// 三档阴影（ui-spec §3.6）：`level` 对应 sh-1/2/3。
  func tokenShadow(_ level: (color: SwiftUI.Color, radius: CGFloat, y: CGFloat)) -> some View {
    shadow(color: level.color, radius: level.radius, x: 0, y: level.y)
  }
}
