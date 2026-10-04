<div align="center">

<img src="https://github.com/user-attachments/assets/b8b5f33c-ca2e-4f9e-9200-c3114b83d1db" width="96" height="96" alt="JustSaid 图标">

# JustSaid

**刚说的，在这儿。**

开源的 macOS 会议记录工具：本机实时转写，边开会边把讨论整理成表格、时间线和要点，会后用你自己的模型出纪要。

[下载最新版](https://github.com/bigbobro/JustSaid-public/releases/latest) · [更新日志](https://github.com/bigbobro/JustSaid-public/blob/main/CHANGELOG.md) · [反馈问题](https://github.com/bigbobro/JustSaid-public/issues) · [English](https://github.com/bigbobro/JustSaid-public/blob/main/README.en.md)

[![最新版本](https://img.shields.io/github/v/release/bigbobro/JustSaid-public?label=%E7%89%88%E6%9C%AC)](https://github.com/bigbobro/JustSaid-public/releases/latest)
![平台](https://img.shields.io/badge/macOS-15%2B%20%C2%B7%20Apple%20Silicon-lightgrey)
[![许可](https://img.shields.io/badge/%E8%AE%B8%E5%8F%AF-MIT-blue)](https://github.com/bigbobro/JustSaid-public/blob/main/LICENSE)

</div>

<div align="center">

https://github.com/user-attachments/assets/727ede23-8b84-4038-97d8-15843f28d2a2

</div>

## 它能做什么

- **本机实时转写。** 麦克风和系统声音两路同时转写，用本机运行的 Qwen3-ASR，会中转写不上传音频。
- **边开会边整理。** 讨论按话题沉淀成一份活文档；内容适合时，自动画成表格、时间线、关键数字或层级图。
- **被点名时接得住。** 有人叫到你的名字，悬浮小窗提醒你，并告诉你刚才在聊什么。
- **答应的事有人记。** 会上说到的承诺和待办单独记下，标出归属和时限；会后进「我的待办」，可以在四象限里排轻重缓急。
- **开会就提醒。** 会议软件开始通话时，顶部弹出提醒，点一下开始记录；由提醒开始的记录默认只录这个会议软件的声音。
- **会后一页看完。** 整场录音交给你自己的识别服务精转，再生成纪要和行动清单。模型用你自己的 API Key，也可以直接用你的 ChatGPT 订阅。

<table>
  <tr>
    <td width="50%"><img src="https://github.com/user-attachments/assets/d57cbb16-f876-46bc-9fac-be88fc745f57" alt="会中整理：讨论还没结束，表格和时间线已经整理出来"><br><sub>会还没开完，表先出来了</sub></td>
    <td width="50%"><img src="https://github.com/user-attachments/assets/bd9b1e70-db98-4448-bff5-a5cd729cdd58" alt="点名提醒：悬浮小窗提示有人叫你，并显示当前正在聊的话题"><br><sub>走神时被点名，小窗告诉你在聊什么</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="https://github.com/user-attachments/assets/60573a32-3b91-4a55-8390-4879e33f73b1" alt="不同会议整理成表格、时间线、数字和层级"><br><sub>每场会按讨论的样子整理</sub></td>
    <td width="50%"><img src="https://github.com/user-attachments/assets/cc1e3034-e482-4b18-a1da-ebf3cece8715" alt="我的待办：会上答应的事排进四象限"><br><sub>答应的事排进四象限</sub></td>
  </tr>
</table>

## 下载与安装

需要 Apple Silicon 的 Mac，macOS 15 或更高版本。

1. 到 [Releases](https://github.com/bigbobro/JustSaid-public/releases/latest) 下载最新的 `JustSaid-<版本>-b<构建号>-arm64.dmg`。
2. 打开 DMG，把 `JustSaid.app` 拖到旁边的「Applications」。
3. JustSaid 由作者自签名，没有经过 Apple 公证，第一次打开会被 macOS 拦下：在「应用程序」里双击一次 JustSaid，在提示框点「完成」，再到「系统设置 → 隐私与安全性」的「安全性」一栏点「仍要打开」。不需要关闭 Gatekeeper，也不需要执行命令。
4. 第一次录制时，按系统提示允许麦克风和「屏幕与系统音频录制」。首次启动会提示下载本地识别模型（Qwen3-ASR 与 Silero VAD），点了「下载并安装」才会联网。

<details>
<summary>核对安装包（可选）</summary>

在 DMG 所在目录打开「终端」：

```sh
shasum -a 256 JustSaid-*.dmg
```

输出应与同一个 Release 页上 `.dmg.sha256` 文件里的值完全一致。DMG 根目录的 `VERSION.txt` 写着这个包对应的源码提交；到本仓库对应版本 tag 下的 `PUBLIC_EXPORT_MANIFEST.json` 里，`source_sha` 应与它相同。三处都对上，说明安装包出自这里公开的源码。

</details>

## 首次配置

应用不预置任何云端账号或密钥。会中实时转写只用本地模型，装好就能用。会后精转、会中总结和会后纪要用你自己的服务，在「设置」（`⌘,`）的「模型与服务」里按角色配置：

| 角色 | 需要准备什么 |
| --- | --- |
| 会中速记 | 不用准备，默认使用本地 Qwen3-ASR |
| 会后精转 | 火山引擎「豆包录音文件识别」的凭证，加一个你自己的 Cloudflare R2 存储桶，用来临时中转音频 |
| 会中快总结、会中慢总结 | OpenAI 兼容的对话模型服务（Base URL、模型名、API Key），或用你的 ChatGPT 订阅登录 |
| 会后纪要 | 同上；三处可以用同一个渠道，也可以分别选择渠道、模型和推理档位 |

**用 ChatGPT 订阅：** 在「模型与服务」点「新建渠道」，供应商选「ChatGPT 计划用量」，创建后点「Continue with ChatGPT」在浏览器里登录，再为各个角色选模型。总结和纪要计入你的 ChatGPT 计划用量；会后精转仍用上面单独配置的识别服务。

豆包录音文件识别与 Cloudflare R2 的申请步骤随包附在 DMG 根目录的 `docs/` 文件夹里。密钥只保存在这台 Mac 的钥匙串里；建议给凭证只授予本应用需要的最小权限。

## 数据在哪里处理

| 环节 | 在哪里 | 说明 |
| --- | --- | --- |
| 录音与会中实时转写 | 本机 | Qwen3-ASR 在本机运行，会中音频不上传 |
| 回声消除 | 本机 | 会中和会后各做一次，原始录音保留 |
| 会议资料 | 本机 `~/JustSaid/meetings` | 录音、转写、纪要和笔记按会议分文件夹保存，可以直接备份或删除 |
| 会中总结、会后纪要 | 你配置的模型服务或 ChatGPT | 发送的是转写文本 |
| 会后精转 | 你的 R2 存储桶和识别服务 | 录音临时上传，识别完成后删除中转对象；删除失败会在会后处理里提示 |
| API Key 与 ChatGPT 登录 | 本机钥匙串 | 两者分开存放 |
| 检查更新 | 本仓库的公开更新清单 | 不发送会议内容或系统信息 |

由提醒开始的记录默认只采集该会议软件的系统声音（浏览器里的会议采集整个浏览器）；按 App 采集失败时改为采集全部系统声音并提示。手动开始的记录采集全部系统声音。各服务对数据的保留规则以你所选服务商和账号设置为准。

<details>
<summary>更多功能</summary>

- **点名提醒。** 在「设置 → 点名提醒」添加名字或昵称，只在录制中生效；复用本机实时转写，有几秒延迟，也可能漏认。悬浮显示可选侧边吸附、悬浮小窗或关闭；强提醒会单独显示名字与「知道了」，关闭悬浮显示时也能用。会中左侧栏的「点名」按钮可以暂停或恢复提醒。
- **补充记录与标记重点。** 转写之外可以随手补一句，或用快捷键给当前时刻打标记。
- **闲聊不进纪要。** 录制中点工具栏的「闲聊」或按 `⌥⌘X` 开始，再按一次结束；这段照常录音和转写，只是不进纪要。会后也可以在「完整转写」里把某几段设为不进纪要。
- **认名。** 精转完成后，从对话里找出谁是谁（自我介绍、被人叫到名字），附上原话作证据；你点「采纳」才会改名。
- **会议页三个页签。** 「这场会」在结构和正式纪要之间切换；「完整转写」用来核对发言人；「会中记录」保留整理区的留痕和你的补充记录。
- **会议库。** 按时间排列，支持全文搜索、按客户和项目归类、导出会议包。
- **导入录音。** 已有的音频或视频文件（mp3、m4a、wav 等）拖到首页「导入录音」框，直接走会后精转并生成纪要。
- **我的待办。** 手工新增，或从会议页的「待办候选」核对后加入；按今天、逾期、待补全等智能视图或客户、项目查看，列表和四象限之间切换。
- **词典与收割箱。** 维护常用专名和它们的不同叫法，用于精转与纪要；生成纪要时发现的新专名先进「收割箱」，由你决定是否并入。

</details>

## 应用更新

在 JustSaid 菜单里选「检查更新…」，或在「设置 → 通用 → 应用更新」打开自动检查。发现新版后由你决定安装：选「立即安装并重启」会马上换成新版，选「稍后」会在下次主动退出 App 时安装（关闭主窗口只是转到后台，不算退出）。录制、会后处理、导入或模型准备进行中时，更新会提示等它们完成后再试。1.0.3 及更早版本需要先从 Releases 手动安装一次带更新功能的版本。

## 已知限制

- **每次更新后会再要一次钥匙串授权。** 更新后，macOS 可能再次请求访问已保存的 API Key 或 ChatGPT 登录，并要求输入登录钥匙串密码。请在系统弹窗里允许；即使之前选过「始终允许」，下次更新仍可能再问。如果误点了「拒绝」，重新保存一次或重启 JustSaid 后再允许即可，已保存的密钥不会丢。
- **没有经过 Apple 公证。** 第一次打开需要按上面的步骤在「隐私与安全性」里允许。
- **只支持 Apple Silicon、macOS 15 及以上。**
- **点名提醒有延迟。** 依赖实时转写，通常晚几秒，也可能漏认名字。

## 从源码构建

本仓库使用 Swift Package Manager。在 Apple Silicon、macOS 15 及以上、装有 Xcode 命令行工具的机器上：

```sh
swift package resolve
swift build --build-system native --product JustSaid
```

构建产物是未打包的可执行文件；Releases 上的 DMG 才是打包并签名后的版本。

<details>
<summary>依赖与本仓库的范围</summary>

依赖固定版本的 sherpa-onnx、Sparkle 与 WebRTC Audio Processing。SwiftPM 会从独立的 `deps-webrtc-apm-2.1` Release 下载约 1.25 MB 的 arm64 静态 XCFramework，并校验锁定的 SHA-256；下载 App 时仍选 App 版本的 DMG。

这里是作者从开发仓库中选定并导出的产品源码：应用本体与它的两个库。功能验证夹具、内部研发记录和真实会议材料不在其中。每次导出都会生成 `PUBLIC_EXPORT_MANIFEST.json`，记录对应的源码提交与文件清单；导出边界见 `docs/publication/PUBLIC_SCOPE.md`。请不要向本仓库提交录音、凭证、签名材料或任何会议数据。

</details>

## 反馈

使用问题和建议请到 [Issues](https://github.com/bigbobro/JustSaid-public/issues) 提交，附上「设置」页底部显示的版本与构建号；不要附带 API Key、Access Key 或完整录音。

## 致谢

感谢 [Linux.do](https://linux.do) 社区的交流、反馈与支持。

也感谢 JustSaid 所依赖的开源项目，包括 Qwen3-ASR、sherpa-onnx、Silero VAD、Sparkle 与 WebRTC Audio Processing。

## 许可

源码以 MIT 许可发布，见 [LICENSE](https://github.com/bigbobro/JustSaid-public/blob/main/LICENSE)。第三方组件与本地模型的许可见 `Support/ThirdPartyNotices.txt` 与 `Support/ThirdPartyLicenses/`。
