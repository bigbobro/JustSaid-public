import AppKit
import SwiftUI

extension Tokens {
  /// Design language v1. The maintained source is docs/design-system/tokens.json.
  /// Existing geometry remains in the unversioned families until each region is rebuilt.
  enum V1 {
    enum Color {
      static let paper = SwiftUI.Color(light: 0xf8fafc, dark: 0x121518)
      static let paper2 = SwiftUI.Color(light: 0xeff2f5, dark: 0x191c1f)
      static let paper3 = SwiftUI.Color(light: 0xe4e8ec, dark: 0x22262a)
      static let raised = SwiftUI.Color(light: 0xfcfdff, dark: 0x1c2023)
      static let rail = SwiftUI.Color(light: 0xeaedf1, dark: 0x0a0d10)
      static let rule = SwiftUI.Color(light: 0xd9dde0, dark: 0x282c2f)
      static let controlRule = SwiftUI.Color(light: 0x797e83, dark: 0x6d7277)
      static let ink = SwiftUI.Color(light: 0x13161c, dark: 0xdde1e5)
      static let ink2 = SwiftUI.Color(light: 0x3f4349, dark: 0xc1c4c8)
      static let ink3 = SwiftUI.Color(light: 0x575b62, dark: 0x9b9fa3)
      static let ink4 = SwiftUI.Color(light: 0x83868c, dark: 0x6e7276)
      static let accent = SwiftUI.Color(light: 0x00675e, dark: 0x5cc6b9)
      static let accentSoft = SwiftUI.Color(light: 0xd6f2ee, dark: 0x0d2f2b)
      static let accentInk = SwiftUI.Color(light: 0xf8fafc, dark: 0x0a0d10)
      static let focus = SwiftUI.Color(light: 0x00675e, dark: 0x5cc6b9)
      static let call = accent
      static let callSoft = accentSoft
      static let rec = SwiftUI.Color(light: 0xc22823, dark: 0xef675a)
      static let recSoft = SwiftUI.Color(light: 0xffe8e4, dark: 0x3a1d1a)
      static let warn = SwiftUI.Color(light: 0x8a5600, dark: 0xe3b667)
      static let warnSoft = SwiftUI.Color(light: 0xfdefd2, dark: 0x332710)
      static let danger = SwiftUI.Color(light: 0x934400, dark: 0xf0995b)
      static let ok = SwiftUI.Color(light: 0x307041, dark: 0x7cc58c)
      static let okSoft = SwiftUI.Color(light: 0xe0f5e3, dark: 0x152d1a)
      static let me = SwiftUI.Color(light: 0x2559bf, dark: 0x8bb1f7)
      /// 首页右卡「查找会议」两枚徽章里的字形色,和那张卡的浅蓝背景图同色相。
      static let find = SwiftUI.Color(light: 0x1f7ae0, dark: 0x7ab4f5)
      static let primary = SwiftUI.Color(light: 0x13161c, dark: 0xe8ebef)
      static let onPrimary = SwiftUI.Color(light: 0xf8fafc, dark: 0x0a0d10)
      static let onRec = onPrimary
      static let handle = SwiftUI.Color(lightRGBA: 0x1c1f_25f0, darkRGBA: 0x2629_2ef0)
      static let handleInk = SwiftUI.Color(light: 0xebeff2, dark: 0xebeff2)
      static let handleRule = SwiftUI.Color(lightRGBA: 0xf6f9_fb6b, darkRGBA: 0xf6f9_fb8c)
      static let handleRule2 = SwiftUI.Color(lightRGBA: 0xf6f9_fb29, darkRGBA: 0xf6f9_fb38)
      static let handleAccent = SwiftUI.Color(light: 0x6fcabf, dark: 0x6fcabf)
      static let handleRec = SwiftUI.Color(light: 0xf4514f, dark: 0xf75d59)
      static let glow = SwiftUI.Color(lightRGBA: 0x0067_5e38, darkRGBA: 0x5cc6_b942)
      static let scrim = SwiftUI.Color(lightRGBA: 0x1316_1c0f, darkRGBA: 0xe8eb_ef0f)
      static let knob = SwiftUI.Color(light: 0xfcfdff, dark: 0xe2e5e8)
      static let tip = SwiftUI.Color(lightRGBA: 0x1c1f_25f5, darkRGBA: 0x2a2e_33f7)
      static let tipInk = SwiftUI.Color(light: 0xebeff2, dark: 0xebeff2)
    }

    enum Space {
      static let s3xs: CGFloat = 2
      static let s2xs: CGFloat = 4
      static let xs: CGFloat = 8
      static let sm: CGFloat = 12
      static let md: CGFloat = 16
      static let lg: CGFloat = 24
      static let xl: CGFloat = 32
      static let s2xl: CGFloat = 48
    }

    enum Radius {
      static let xs: CGFloat = 4
      static let sm: CGFloat = 6
      static let md: CGFloat = 8
      static let lg: CGFloat = 10
      static let pill: CGFloat = 999
    }

    struct TextStyle {
      enum Family { case display, body, mono }
      let size: CGFloat
      let lineHeight: CGFloat
      let weight: Font.Weight
      let family: Family
      var tracking: CGFloat = 0

      var font: Font {
        switch family {
        case .display:
          // 原来是 .custom("SF Pro Display"):本机没有装这个字族,一直静默回落到系统字体,
          // 每次渲染还打一条「Unable to update Font Descriptor's weight」。系统字体本身在
          // 20pt 起自动换 Display 光学尺寸,所以直接用 .system,画面不变,令牌说的就是实际画出来的。
          return .system(size: size, weight: weight)
        case .body:
          return .system(size: size, weight: weight)
        case .mono:
          return .system(size: size, weight: weight, design: .monospaced)
        }
      }
    }

    enum Text {
      static let title = TextStyle(
        size: 17, lineHeight: 20, weight: .semibold, family: .display, tracking: -0.012 * 17)
      static let barTitle = TextStyle(
        size: 15, lineHeight: 20, weight: .semibold, family: .display, tracking: -0.012 * 15)
      /// H1,一屏一个(首页主入口、设置分区标题)。
      static let hero = TextStyle(
        size: 20, lineHeight: 24, weight: .semibold, family: .display, tracking: -0.012 * 20)
      /// H3 组标题。原来 13/600 兼作列表行标题,组头和它下面的行同一个样式,没有层级;
      /// 行内加重改用 `strong`,这里升到 15(2026-09-21)。
      static let heading = TextStyle(
        size: 15, lineHeight: 20, weight: .semibold, family: .display, tracking: -0.012 * 15)
      /// 行内加重(选中行、选中页签、「已选择 N 个词」),承接原 heading 的 13/600。
      static let strong = TextStyle(size: 13, lineHeight: 16, weight: .semibold, family: .body)
      static let body = TextStyle(size: 13, lineHeight: 20, weight: .regular, family: .body)
      static let stageBody = TextStyle(size: 14, lineHeight: 21, weight: .regular, family: .body)
      static let label = TextStyle(size: 13, lineHeight: 16, weight: .medium, family: .body)
      static let meta = TextStyle(size: 12, lineHeight: 18, weight: .regular, family: .body)
      static let micro = TextStyle(size: 11, lineHeight: 14, weight: .semibold, family: .body)
      static let timecode = TextStyle(size: 11, lineHeight: 14, weight: .regular, family: .mono)
    }

    enum Size {
      /// Dimensionless native Todo drag-preview scale; Reduce Motion uses identity.
      static let dragPreviewScale: CGFloat = 1.02
      static let meetingTitleMaxWidth: CGFloat = 520
      static let meetingAnchorWidth: CGFloat = 56
      static let libraryColClient: CGFloat = 48
      static let libraryColDuration: CGFloat = 60
      static let libraryColOutcome: CGFloat = 112
      static let libraryColProject: CGFloat = 64
      static let checkBox: CGFloat = 14
      static let chipsRowHeight: CGFloat = 40
      static let libraryRow: CGFloat = 42
      static let libraryColTime: CGFloat = 48
      static let libraryColStatus: CGFloat = 64
      /// 首页右卡「查找会议」(加导入录音)的宽:约占一行的三分之一,夹在这两个数之间。
      /// 左卡「开始一场会议」吃掉剩下的宽度——窄窗口里设备名要完整,右卡先让。
      static let homeFindMin: CGFloat = 300
      /// 首页左卡开会表单的输入框、下拉框与分段高(行距 8)。
      static let homeField: CGFloat = 32
      /// 首页内容区最宽:两张入口卡与「最近的会」同宽、在宽窗里居中。
      static let homeContentMax: CGFloat = 1120
      static let homeFindMax: CGFloat = 400
      /// 两张入口卡底部那一对大按钮(开始记录 / 导入录音)的高。
      static let homeEntryButton: CGFloat = 44
      /// 入口卡标题前的方块徽章:和「标题 + 副题」两行同高。
      static let homeEntryBadge: CGFloat = 44
      static let homeColTime: CGFloat = 116
      static let homeColState: CGFloat = 112
      static let homeColAction: CGFloat = 78
      static let rowHome: CGFloat = 44
      static let railIcon: CGFloat = 20
      /// 轨顶应用图标露出来的圆角方块边长,红绿灯正下方,明显大于导航字形。
      /// 系统应用图标自带透明边,画框要按 `AppRailView` 里的图标栅格比例放大。
      static let railBrand: CGFloat = 32

      static let controlSm: CGFloat = 24
      static let control: CGFloat = 28
      static let controlLg: CGFloat = 36
      static let barHeight: CGFloat = 52
      static let railWidth: CGFloat = 80
      static let railItem = CGSize(width: 48, height: 44)
      static let recordBlock = CGSize(width: 48, height: 60)
      static let panelWidth: CGFloat = 232
      static let meetingRailWidth: CGFloat = 300
      /// 阅读列宽。设计系统 `reading-w` 一直是 1040,但正文一直用遗留的
      /// `Tokens.Layout.readingContentWidth = 780` 断行,窗口再宽也在 780 折
      /// (owner 2026-09-20:「页面还有很大,文章文本却在中间一个地方开始换行」)。
      static let reading: CGFloat = 1040
      /// 词条优先占用剩余高度，收割箱独立滚动且封顶。
      static let dictionaryWordsMinHeight: CGFloat = 264
      static let dictionaryHarvestMinHeight: CGFloat = 240
      /// 设置页表单的标签列宽，控件从同一条线起跑。
      static let settingsLabel: CGFloat = 112
      /// 设置页表单列宽。表单行是「标签 + 控件」的窄结构,铺满 1280 会让标签与控件
      /// 隔着半屏,眼睛追不回来。
      static let settingsForm: CGFloat = 560
      static let settingsContent: CGFloat = 720
      static let settingsModelField: CGFloat = 220
      static let settingsRow: CGFloat = 32
      static let settingsSheetMinHeight: CGFloat = 420
      static let sideWidth: CGFloat = 332
      static let handleRimWidth: CGFloat = 0.75
      static let handleInnerRimWidth: CGFloat = 0.85
      static let handleAlertRimWidth: CGFloat = 1.35
      static let handleGlowRadius: CGFloat = 2.5
      static let handleGlintTailWidth: CGFloat = 1.6
      static let handleGlintHeadWidth: CGFloat = 1.8
      static let handleGlintGlowRadius: CGFloat = 3
      static let todoDetailWidth: CGFloat = 340
      static let todoPopoverWidth: CGFloat = 360
      static let todoListMinWidth: CGFloat = 440
      static let overlayWidth: CGFloat = 408
      static let overlayCloseZone: CGFloat = 44
      static let overlayGripHeight: CGFloat = 3
      static let overlaySummaryMinHeight: CGFloat = 64
      static let stripHeight: CGFloat = 28
      /// StatusGlyphs component contract (design.md).
      static let statusGlyphWidth: CGFloat = 40
      /// README accessibility contract: 2pt ring, 2pt outside the control.
      static let focusWidth: CGFloat = 2
      static let controlRuleWidth: CGFloat = 1
    }

    enum Feedback {
      static let primaryHoverOpacity: Double = 0.12
      static let pressedOpacity: Double = 0.72
      static let disabledOpacity: Double = 0.45
      /// 深色下首页入口卡的墨青淡洗浓度(浅色用背景图)。只给「主入口」这一处。
      static let entryWash: Double = 0.16
      /// 毛玻璃块的底(raised 的透明度):白纱一层,透出卡面背景图的色相。
      static let glassFill: Double = 0.55
      /// 毛玻璃块那一圈细边的浓度(raised 的透明度):玻璃的边缘比玻璃本身亮一点。
      static let glassEdge: Double = 0.9
    }

    /// Mirrors shadow-pop and shadow-float: two light layers; dark has no shadow.
    enum Shadow {
      static let control = (
        color: SwiftUI.Color(lightRGBA: 0x1316_1c1a, darkRGBA: 0x1316_1c00),
        radius: CGFloat(1), y: CGFloat(1)
      )
      static let popNear = (
        color: SwiftUI.Color(lightRGBA: 0x1316_1c1a, darkRGBA: 0x1316_1c00),
        radius: CGFloat(2), y: CGFloat(1)
      )
      static let popFar = (
        color: SwiftUI.Color(lightRGBA: 0x1316_1c29, darkRGBA: 0x1316_1c00),
        radius: CGFloat(24), y: CGFloat(8)
      )
      static let floatNear = (
        color: SwiftUI.Color(lightRGBA: 0x1316_1c14, darkRGBA: 0x1316_1c00),
        radius: CGFloat(2), y: CGFloat(1)
      )
      static let floatFar = (
        color: SwiftUI.Color(lightRGBA: 0x1316_1c2e, darkRGBA: 0x1316_1c00),
        radius: CGFloat(32), y: CGFloat(12)
      )
    }

    enum Motion {
      /// `dur-receipt`: transient undo receipt; replaced by the next action.
      static let receipt: TimeInterval = 5
      static let fast: Double = 0.12
      static let base: Double = 0.2
      static let slow: Double = 0.36
    }
  }
}

extension SwiftUI.Color {
  /// JSON uses #RRGGBBAA for translucent colors; keep alpha in the dynamic provider.
  fileprivate init(lightRGBA: UInt32, darkRGBA: UInt32) {
    self.init(
      nsColor: NSColor(name: nil) { appearance in
        let rgba =
          appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkRGBA : lightRGBA
        return NSColor(
          srgbRed: CGFloat((rgba >> 24) & 0xff) / 255,
          green: CGFloat((rgba >> 16) & 0xff) / 255,
          blue: CGFloat((rgba >> 8) & 0xff) / 255,
          alpha: CGFloat(rgba & 0xff) / 255
        )
      })
  }
}

extension SwiftUI.Color {
  /// Legacy surfaces select different V1 roles by appearance during the staged migration.
  init(light: SwiftUI.Color, dark: SwiftUI.Color) {
    self.init(
      nsColor: NSColor(name: nil) { appearance in
        var resolved = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
          let color = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
          resolved = NSColor(color).usingColorSpace(.sRGB) ?? .clear
        }
        return resolved
      })
  }
}
