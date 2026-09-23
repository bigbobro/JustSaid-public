import AppKit

/// 首页两张入口卡的背景图(设计系统「主入口」档,全应用只有首页这两处用图)。
///
/// 图随包放在 `Contents/Resources/HomeEntryBackground.png`,由打包脚本从 `Support/Assets/` 拷入,
/// 缺图直接让打包失败。只在浅色下用:这是一张浅色图,深色下入口卡退回纯 `raised` 底。
///
/// 截图装置跑在 `.build/` 下,没有 app 包,`Bundle.main` 里找不到这张图,由装置自己注入——
/// 和它注入应用图标是同一个做法。找不到图时入口卡照样画纯色底,不会空白。
@MainActor
public enum HomeEntryArtwork {
  public static var image: NSImage? = Bundle.main.image(forResource: "HomeEntryBackground")
  /// 右卡「查找会议」的浅蓝波纹图(`HomeFindBackground.png`),同样只在浅色下用。
  public static var findImage: NSImage? = Bundle.main.image(forResource: "HomeFindBackground")
}
