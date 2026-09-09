# JustSaid 公开导出范围

> 日期:2026-09-04
> 状态:已确定的发布策略（执行前仍须通过候选树扫描）
> 用途:说明 private canonical repository 到独立 sanitized public repository 的可重复导出边界
> Policy revision:2026-09-04.2

这不是当前仓库的可见性声明，也不是对历史提交的清洗。当前仓库继续作为 private
canonical repository；公开仓库只接受导出脚本生成、扫描通过并由作者另行批准的候选树。
真实场景验证材料和研发上下文保留在 private repository，不因本策略删除。

## 四类分类

### `PUBLIC_COPY`

作者有权公开、无需改写即可复制的产品表面：

- `Sources/**`；
- `Package.resolved`、公开 Package manifest 模板；
- `Support/` 中的通用配置、第三方和模型许可说明；
- 经过审查的通用脚本、公开低权限 GitHub Actions；
- `.gitignore`、`.gitattributes`、`LICENSE` 和本文件。

当前 exporter 的精确复制清单由 `Scripts/verify-public-tree.py` 中的 allowlist 固定，
不由 `.git/info/exclude` 或忽略规则推断。

### `PUBLIC_REWRITE`

可以公开但需要去除内部语境或机器依赖后再复制的内容：

- `README.md` 和 `CHANGELOG.md`：使用公开模板，不复制 private 内测叙述；
- `Package.swift`：从公开 manifest 模板生成，模板必须恰好是 canonical target graph
  去掉全部 `Verification/` 目标后的图。校验分两层：包级校验包名、依赖地址、依赖
  revision、产品列表和 Swift language mode；target 级对每一个存活 target 逐个比对
  target kind、`path`，以及该声明里除 `name`/`path` 之外的**全部**具名参数
  （`dependencies`、`linkerSettings`、`swiftSettings`、`cSettings`、`resources`
  等等，不是一份固定清单，manifest 新增什么参数就一并比对）。比对前统一归一化字符串
  外的空白和末尾逗号，因此纯重排版不会变红，任何语义改动都会变红。「target」按
  PackageDescription 的全部声明写法识别——`.target`、`.executableTarget`、
  `.testTarget`、`.binaryTarget`、`.systemLibrary`、`.macro`、`.plugin`——不只是
  当前 manifest 恰好用到的两种；出现在已识别声明内部的同名写法（`dependencies:`
  里的 `.target(name:)`、`plugins:` 里的 `.plugin(name:package:)`）是引用不是声明，
  不参与比对；
- 面向公开读者的构建说明和技术说明：只保留可公开的产品事实。

改写必须是确定性的；候选 manifest 或文档不能通过临时手工编辑产生。

### `PRIVATE_ONLY`

仅供作者 private development 使用的上下文，继续保留在 canonical repository 或私有
归档中，不进入候选树：

- `PRIVATE_DOGFOOD_DATA`：真实会议、real-world evaluation、dogfooding transcript、
  summary、PDF、音频及其评估结果；
- `PRIVATE_RESEARCH`：个人研发日志、失败实验、profiling、diagnostics、内部 beta
  操作记录及未整理的研究材料；
- `.trellis/workspace/**`、私人 journal、内部路线讨论和本机调试记录；
- 需要真实账户、钥匙串、云端或分发凭据的手工验收工具。

保留这些资料是数据保护要求，不代表它们适合公开。

### `PUBLIC_EXCLUDE`

即使被 Git 跟踪，也明确不复制到 public candidate 的路径或内容：

- `research/acceptance/**`、`example/**`、raw recordings、会议导出物和诊断归档；
- private Trellis workspace/journal、内部 beta/distribution 操作资料；
- credential tooling、access-bearing URL、密钥/证书/配置文件；
- `.github/task-artifacts/**`、`.github/task1-trigger` 以及 `uihierarchy-*` 临时 workflow；
- Task 1 source-export、materializer、payload、connector test artifact；
- `Verification/**` 全树：验证夹具是测试资料，不是发布表面，因此整棵树不进入候选树；
- 未完成许可审查的二进制、截图、录音、视频、压缩包、数据库和 crash/profiling 输出。

## 顶层导出表

| 顶层路径 | 导出分类 | 当前处理 |
| --- | --- | --- |
| `Sources/` | `PUBLIC_COPY` | 复制并扫描，不改产品代码 |
| `Verification/` | `PUBLIC_EXCLUDE` | 整树不复制，公开 manifest 也不声明 verification target |
| `Package.swift` | `PUBLIC_REWRITE` | 使用 `docs/publication/Package.public.swift` 模板 |
| `Package.resolved` | `PUBLIC_COPY` | 保留锁定依赖版本 |
| `Scripts/` | `PUBLIC_COPY` | 只复制 exporter、scanner 和低风险通用策略脚本 |
| `Support/` | `PUBLIC_COPY` | 只复制审查过的文本、JSON 和必要 plist |
| `.github/workflows/` | `PUBLIC_COPY` | 只复制低权限 public workflow |
| `README.md` / `CHANGELOG.md` | `PUBLIC_REWRITE` | 由公开模板生成 |
| `research/` / `example/` | `PRIVATE_ONLY` / `PUBLIC_EXCLUDE` | 不复制真实场景资料 |
| `.trellis/` | `PRIVATE_ONLY` / `PUBLIC_EXCLUDE` | 不复制 workspace、journal 或任务上下文 |
| `Distribution/` | `PUBLIC_EXCLUDE` | 当前内部分发资料不进入候选树 |

## 导出与验收规则

`Scripts/export-public-repo.sh` 是唯一导出入口。它从明确 allowlist 读取 canonical
working tree，输出到仓库外的绝对路径，不覆盖已有非空目录，不复制 `.git`，并生成包含
source SHA、dirty/clean 状态、source mode、policy revision、排序文件列表和 SHA-256
的 manifest。

Exporter 必须显式识别两种合法输入，其他状态一律失败：

- `private_canonical`：根 `Package.swift` 含 `Verification/` 目标，公开模板恰好是
  去掉全部这类目标后的图；
- `sanitized_public`：根 `Package.swift` 已与公开模板完全一致，且两者都不含任何
  `Verification/` 目标。

不得根据仓库名称判断模式。判据是路径而不是手工维护的 target 名单：公开模板只要还声明
任何 `Verification/` 目标就直接拒绝；两份 manifest 过滤后在上述任何一层不一致同样
拒绝。合法的 sanitized public 树必须能再次作为 exporter 输入。

同一条模式判据也约束导出到公开仓库、由公开 `pr-validation.yml` 运行的
`Scripts/verify-concurrency-policy.py`：它的扫描范围同样不看仓库名，而看该检出自己的
`Package.swift`。`Sources/` 在两种模式下都是必需的；`Verification/` 仅在该 manifest
声明了 `Verification/` 目标时才是必需的。因此 private canonical 检出丢失
`Verification/` 树会 fail closed，而 sanitized public 检出没有这棵树是设计内的正常
状态。`Package.swift` 读不到时一律失败，不退化成公开模式。

候选树必须通过 `Scripts/verify-public-tree.py`。扫描器只报告路径、行号、finding code
和脱敏摘要；不会把任何凭据值写入日志。发布前还必须由作者人工检查 GitHub 的 issue、PR、
Actions log/artifact、release、讨论区、wiki、secrets 和环境历史。

## 真实数据溯源内容规则

凭据类规则之外，扫描器还检查“这段内容是从真实用户数据里拷进来的”这类痕迹。判据是**形状**
与**同现**，不是词表：

- 单场会话目录名的形状（日期 + 主题词 + 序号）本身就是证据，单独成立；
- 指向本产品 home 相对数据目录**内层**条目的路径同样单独成立。它是
  `MACHINE_ABSOLUTE_PATH` 的姊妹规则——后者只认展开后的家目录，波浪号写法此前直接绕过。
  数据目录自身的顶层名字是公开的产品事实，不算命中；只有走进其中某个目录的具体条目才算；
- 表示“把内容搬过来”的**动词**，中英文写法都覆盖。英文一律是完整搭配，不是单词：搬运动词
  必须带上“逐字”或它的来源介词；“逐字节”一类说法只在紧跟一个表示拷贝的名词时才算。英文
  匹配不区分大小写；
- 表示“这段内容取自线上／真实存量”的**来源声明**，中英文写法同样都覆盖。英文有三种成立方式：
  “取出”类动词接来源介词、后面再跟线上／真实一类限定词；限定词直接修饰一个表示成体量产品
  数据的名词；所有格的“用户的”直接修饰会议／录音／转写一类名词。单写限定词本身不构成声明；
- 这两侧共三种同现组合才成立：动词 + **被搬的是什么**（会议记录文件名，或会议／转写一类主题
  词）；动词 + 来源声明（用来指认被搬的是一整批使用记录，而不是某一条）；来源声明 + 会议记录
  文件名。任何一半单独出现都不报。

同现在**同一行或同一段连续注释块**内评估：溯源说明常常拆成两行写——一行点名记录，下一行
才说它是拷来的。

工程注记不因用词被误伤：树内既有的“真机实测”“真实会议”“真实漂移”一类批注描述的是观察到
的行为，不主张任何数据被拷入，因此不构成标记。其中的漂移批注仍会被捕获，但原因是它所在的
那一行同时写着一个具体的会话目录名。英文一侧同理：要求模型逐字引用的提示语、产品自身的
实时／线上用语、断言往返逐字节一致的测试，都只写了搭配中的某一个词，都不构成标记。
