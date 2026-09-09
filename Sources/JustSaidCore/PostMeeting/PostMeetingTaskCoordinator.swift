import Combine
import Foundation

/// 会后长任务的操作类型。identity 已经保证「同一场会议同一时刻至多一个任务」,
/// kind 只用来把快照路由到正确的界面槽位(精转横幅 / 纪要横幅 / 英文重试横幅)。
public enum PostMeetingOperationKind: String, Hashable, Sendable {
  /// `pipeline.run(input)`:会中结束自动流程与会议库「重新精转」。
  case fullPostMeeting
  /// `pipeline.resume(candidate)`:启动续查已有 request_id。
  case recovery
  /// `regenerateMinutes`:用户点「生成纪要」(中文主产物,可含英文)。
  case minutes
  /// `regenerateMinutes([.english])`:英文版局部失败重试。
  case englishMinutes
  /// 外部录音导入(落盘后链式启动精转)。
  case importRecording
}

/// 每场会议当前(或最近一次)会后任务的短状态快照。
///
/// 刻意**不**存 `PostMeetingProgress` 本身:`.minutesWriting` 每帧都带全量纪要正文,
/// app 生命周期对象里存"最新进度"会让整篇纪要常驻内存。这里只留派生出的短文案。
public struct PostMeetingTaskSnapshot: Equatable, Sendable {
  public let kind: PostMeetingOperationKind
  public let stage: PostMeetingStage
  public let runID: UInt64

  public init(kind: PostMeetingOperationKind, stage: PostMeetingStage, runID: UInt64) {
    self.kind = kind
    self.stage = stage
    self.runID = runID
  }
}

/// 正在生成的纪要正文实时副本。与盘上 `.md.partial` 由同一个节流回调喂出,
/// 所以二者逐字节一致(08-08 R6/AC7)。成功即清(真产物落盘让位),
/// 失败保留作取证,新一轮生成开始时清掉。
public struct PostMeetingLiveMinutesDraft: Equatable, Sendable {
  public let language: MeetingLanguage
  public let content: String

  public init(language: MeetingLanguage, content: String) {
    self.language = language
    self.content = content
  }
}

/// 协调者的**变更后**通知。刻意不用 `ObservableObject.objectWillChange`:
/// 那是变更前信号,订阅方读到的还是旧值。
public enum PostMeetingTaskEvent: Sendable {
  /// 阶段文案或实时纪要草稿变了,界面重画即可。
  case stateChanged(identity: String)
  /// 终态已写盘,磁盘产物可能变了,会议库应 `reload()`。
  case artifactsChanged(identity: String)
  /// 外部录音已落地。导航由**发起导入的那个 view 侧对象**自己决定要不要做——
  /// 协调者完成时不得改动用户当前选中的会议。
  case imported(directory: URL)
}

/// 会后长任务的唯一所有者(app 生命周期)。
///
/// 背景(08-10):九个生产启动入口里四个完全没有 owner,而会议库 model 挂在
/// `.id(libraryRefreshGeneration)` 上,⌘L 就会重建它、清空阶段字典,同一场会议因此
/// 能被启动第二次(两份 LLM 账单、两个 writer 写同一批文件)。View / 窗口级 ViewModel
/// 从此只观察这里的快照,不再自己持有任务。
///
/// 红线:
/// - **移除 handle 时绝不 `cancel()`**。窗口与 View 销毁只释放呈现,不触碰任务。
/// - 终态写盘先于任何身份/世代卫,孤立的失败运行也要留下诊断。
/// - `PostMeetingProgressChannel` 是单消费者、无重放,所以进度只在这里消费一次,
///   界面读快照,不得自己 `for await`。
@MainActor
public final class PostMeetingTaskCoordinator {
  public typealias PipelineResolver = () throws -> PostMeetingPipeline

  /// 变更后通知。发布顺序:先改内部状态,再 send。
  public let changes = PassthroughSubject<PostMeetingTaskEvent, Never>()

  private let meetingStore: MeetingStore
  private let pipelineResolver: PipelineResolver?

  /// identity -> 运行中的任务句柄。移除只代表"不再是当前任务",不代表取消。
  private var tasks: [String: Task<Void, Never>] = [:]
  private var snapshots: [String: PostMeetingTaskSnapshot] = [:]
  private var liveMinutes: [String: PostMeetingLiveMinutesDraft] = [:]
  /// 运行中任务占用的会议目录,供 `reconcileInterruptedMeetings` 排除集使用。
  private var runningDirectories: [String: URL] = [:]
  /// 散会那一刻的内存态组装出的 `PostMeetingInput`,别处不存在;
  /// stop 与 `startPendingInput` 之间关窗不能把它丢掉。
  private var pendingInputs: [String: PostMeetingInput] = [:]
  private var nextRunID: UInt64 = 0
  private var lastImportError: String?
  /// 成功提示的展示门(约 5 秒)。计时器本体住在 `PostMeetingNoticeDismissal.swift`:
  /// 本文件有一条「不出现任何取消调用」的结构断言(守的是"窗口销毁不得触碰任务"),
  /// 计时器的取消与那条红线无关,混进来却会让它失去判别力。
  private let noticeDismissal: PostMeetingNoticeDismissalScheduler

  public init(
    meetingStore: MeetingStore = MeetingStore(),
    pipelineResolver: PipelineResolver? = nil,
    successNoticeDelay: PostMeetingNoticeDismissalScheduler.Delay? = nil
  ) {
    self.meetingStore = meetingStore
    self.pipelineResolver = pipelineResolver
    self.noticeDismissal = PostMeetingNoticeDismissalScheduler(delay: successNoticeDelay)
  }

  // MARK: - 身份

  /// 会议身份 = 标准化目录 path。与 `AppCoordinator` 旧的 recovery key 和
  /// 会议库列表行 id 逐字节相同。
  public nonisolated static func identity(for directory: URL) -> String {
    directory.standardizedFileURL.path
  }

  private static func importIdentity(for sourceFileURL: URL) -> String {
    "import:" + sourceFileURL.standardizedFileURL.path
  }

  // MARK: - 查询

  public var hasPipelineResolver: Bool { pipelineResolver != nil }

  /// 运行中任务占用的会议目录。`reconcileInterruptedMeetings` 必须把它排除:
  /// `PostMeetingPipeline.run` 先清 requestID 再置 `.processing`,这段窗口里会议对
  /// 恢复扫描不可见,不排除就会被改写成 `.interrupted`。
  public var activeDirectories: Set<URL> {
    Set(runningDirectories.values)
  }

  /// 该会议是否有任何会后任务在跑。三个分裂的启动守卫统一查这一个入口——
  /// 否则同一个 model 实例内就能一边流式写纪要一边启动全量重精转。
  public func isRunning(directory: URL) -> Bool {
    tasks[Self.identity(for: directory)] != nil
  }

  public func snapshot(forIdentity identity: String) -> PostMeetingTaskSnapshot? {
    snapshots[identity]
  }

  public func snapshot(for directory: URL) -> PostMeetingTaskSnapshot? {
    snapshots[Self.identity(for: directory)]
  }

  /// 指定槽位的阶段;当前快照属于别的操作类型时返回 nil,由调用方走磁盘兜底。
  public func stage(
    for directory: URL,
    kinds: Set<PostMeetingOperationKind>
  ) -> PostMeetingStage? {
    guard let snapshot = snapshots[Self.identity(for: directory)] else { return nil }
    return kinds.contains(snapshot.kind) ? snapshot.stage : nil
  }

  public func liveMinutesDraft(for directory: URL) -> PostMeetingLiveMinutesDraft? {
    liveMinutes[Self.identity(for: directory)]
  }

  public var isImporting: Bool {
    snapshots.contains { key, snapshot in
      snapshot.kind == .importRecording && tasks[key] != nil
    }
  }

  public var importError: String? { lastImportError }

  public func clearImportError() {
    guard lastImportError != nil else { return }
    lastImportError = nil
    changes.send(.stateChanged(identity: "import"))
  }

  /// 进会议库时把**已经结算完的呈现态**收掉:终态快照、失败保留的纪要草稿、导入错误。
  ///
  /// 迁移前这三样都住在窗口级 `MeetingLibraryModel` 上,⌘L 一次就随 remount 清空;
  /// 搬到 app 生命周期对象后必须自己补回这个边界,否则终态横幅会粘死一整个会话
  /// (`postMeetingStage(for:)` 是快照优先于磁盘,粘死的快照会遮住磁盘真相),
  /// 失败保留的整篇纪要正文也会永久驻留内存并盖住盘上完好的 `minutes.md`。
  ///
  /// 只碰呈现:运行中的身份一律不动;`tasks` / `runningDirectories` 不动;
  /// `pendingInputs` **绝不触碰**——那是散会那一刻的唯一内存副本,散会流程正好会在
  /// `startPostMeetingProcessing` 前后穿插一次 `openLibrary()`。
  public func dismissSettledFeedback() {
    let importing = isImporting
    var dismissed = snapshots.keys.filter { tasks[$0] == nil }
    for identity in dismissed {
      snapshots.removeValue(forKey: identity)
      liveMinutes.removeValue(forKey: identity)
      noticeDismissal.cancel(identity: identity)
    }
    if lastImportError != nil, !importing {
      lastImportError = nil
      dismissed.append("import")
    }
    for identity in dismissed {
      changes.send(.stateChanged(identity: identity))
    }
  }

  // MARK: - 成功提示的展示门(08-10)

  /// 会中横幅与会议库详情共用的那一条会后状态。纪要类横幅另有各自的契约
  /// (`MinutesGenerationStatusBanner` 的 F1:三种终态都必须渲染;英文局部失败条的
  /// `.none` 是"未生成"而不是"没状态"),所以**不**进这个门。
  private static let transientSuccessNoticeKinds: Set<PostMeetingOperationKind> = [
    .fullPostMeeting, .recovery,
  ]

  /// 「成功提示只活约 5 秒」与 `dismissSettledFeedback()` 是**同一个动作、两个触发点**:
  /// 都只是把已经结算完的呈现态快照丢掉,谁先到都行,不会互相打架
  /// (先到的那一方把快照收掉,后到的一方在守卫处空转)。分工:
  /// - 本门只自动收**成功终态**,且只收会中横幅那一路(见 `transientSuccessNoticeKinds`);
  /// - `dismissSettledFeedback()` 是 ⌘L 进库的边界,连失败终态、失败保留的纪要草稿、
  ///   导入错误一起收——那些**不**自动消失,得由用户的一次导航来结算。
  ///
  /// 只改呈现:磁盘状态、运行中的任务与 `pendingInputs` 一律不碰。收掉之后会议库回落
  /// 磁盘事实(成功即 `.completed` → `.none`),所以"隐藏了但快照还在、切个页面又冒出来"
  /// 在结构上不成立。
  private func scheduleSuccessNoticeDismissal(identity: String, runID: UInt64) {
    noticeDismissal.schedule(identity: identity) { [weak self] in
      self?.dismissSuccessNotice(identity: identity, expectedRunID: runID)
    }
  }

  /// 用户点「查看本场会议」:当场收掉这条成功提示,不等那 5 秒。
  /// 运行中与失败态一律不动——那两种要一直看得见。
  public func dismissSuccessNotice(for directory: URL) {
    dismissSuccessNotice(identity: Self.identity(for: directory), expectedRunID: nil)
  }

  /// 一条规则的三种写法:**当前这条快照必须正是当初排门的那条已结算成功提示**。
  /// ① `tasks[identity] == nil`:只收已结算的,运行中的进行中横幅不碰;
  /// ② `runID` 相同:同一场会进了新世代时,旧计时必须空转;
  /// ③ 当前仍是 `.finished`:失败态永不自动消失。
  /// identity 本身就是标准化会议目录,所以"另一场会议"在结构上够不着。
  ///
  /// 三条在今天的可达状态里**大面积互相遮蔽**,别把它当三条独立断言看。
  /// 08-10 逐条跑过的变异表(`swift run UIHierarchyVerification` 真实退出码):
  ///
  /// | 拿掉 | 结果 |
  /// |---|---|
  /// | ① / ② / ③ 任意**单条** | 绿(剩下的照样拦得住) |
  /// | {①,②} / {①,③} | 绿 |
  /// | **{②,③}(runID + 仍是 `.finished`)** | **红**——用例 ⑤:上一轮的旧计时把新一轮的失败提示收掉 |
  ///
  /// 即:最小的有牙变异是 **{②,③} 这一对**,严格小于"整段比对拿掉";用例 ④(新世代
  /// 运行中)被 ⑤ 严格包含——④ 那一刻三条守卫全在挡,只有三条全删才会红。
  /// ① 在计时器路径上没有任何用例看着(它承重的是点击路径 `dismissSuccessNotice(for:)`,
  /// 那一支 `expectedRunID` 为 nil、②空转),改这里之前先看一眼这张表,别以为逐条都被测过。
  private func dismissSuccessNotice(identity: String, expectedRunID: UInt64?) {
    guard
      let snapshot = snapshots[identity],
      tasks[identity] == nil,
      expectedRunID == nil || snapshot.runID == expectedRunID,
      case .finished = snapshot.stage
    else {
      return
    }
    snapshots.removeValue(forKey: identity)
    liveMinutes.removeValue(forKey: identity)
    noticeDismissal.cancel(identity: identity)
    // 盘上什么都没变,只是这条提示不再显示:会议库据此回落磁盘事实。
    changes.send(.stateChanged(identity: identity))
  }

  // MARK: - 散会握手(原 LiveSummaryFeed.pendingPostMeetingInputs)

  public func stashPendingInput(_ input: PostMeetingInput) {
    pendingInputs[Self.identity(for: input.paths.directory)] = input
  }

  public func discardPendingInput(for directory: URL?) {
    guard let directory else { return }
    pendingInputs.removeValue(forKey: Self.identity(for: directory))
  }

  /// 先窥后取:`PostMeetingInput` 由散会那一刻的内存态组装,别处不存在
  /// (`rebuild(from:)` 从历史快照重建 topics,有损)。启动被拒时必须原样留在手上,
  /// 否则一次"已有任务在跑"就把它永久吞掉了。
  @discardableResult
  public func startPendingInput(for directory: URL?) -> Bool {
    guard
      let directory,
      let input = pendingInputs[Self.identity(for: directory)],
      startFullPostMeeting(input)
    else {
      return false
    }
    pendingInputs.removeValue(forKey: Self.identity(for: directory))
    return true
  }

  // MARK: - 启动入口

  /// 会中结束后的自动流程。失败写 `failPostMeetingProcessing`,不发恢复广播
  /// (与迁移前一致:自动路径的横幅由 `LiveSummaryFeed` 自己观察快照渲染)。
  @discardableResult
  public func startFullPostMeeting(_ input: PostMeetingInput) -> Bool {
    let paths = input.paths
    return launch(
      identity: Self.identity(for: paths.directory),
      directory: paths.directory,
      kind: .fullPostMeeting,
      broadcastsRecovery: false,
      onFailureWriteDisk: { [meetingStore] reason in
        _ = try? meetingStore.failPostMeetingProcessing(reason: reason, at: paths)
      },
      body: { pipeline in
        try await pipeline.run(input).notice
      }
    )
  }

  /// 会议库重试入口。有仍可恢复的 request_id 时继续 query 原任务；只有没有 pending
  /// 远端任务(含已有终态失败 attempt)时，用户的显式确认才进入全量重新精转。
  @discardableResult
  public func startRetranscription(at paths: MeetingPaths) -> Bool {
    let identity = Self.identity(for: paths.directory)
    guard tasks[identity] == nil, pipelineResolver != nil else { return false }
    if let candidate = meetingStore.pendingPostMeetingRecoveries().first(where: {
      Self.identity(for: $0.paths.directory) == identity
    }) {
      return startRecovery(candidate)
    }
    return startFullRerun(at: paths, identity: identity)
  }

  /// 全量重跑:清诊断(任务身份从零) → run()(重新上传+提交,新 request_id 生成即落盘)。
  /// 会议库「重新精转」与 D3 未提交窗口的启动自愈共用这一条路径。
  private func startFullRerun(at paths: MeetingPaths, identity: String) -> Bool {
    do {
      _ = try meetingStore.clearPostMeetingDiagnostics(at: paths)
    } catch {
      publishTerminalStage(
        identity: identity,
        kind: .fullPostMeeting,
        stage: .failed(reason: error.localizedDescription)
      )
      return false
    }
    let store = meetingStore
    return launch(
      identity: identity,
      directory: paths.directory,
      kind: .fullPostMeeting,
      broadcastsRecovery: true,
      onFailureWriteDisk: { reason in
        _ = try? store.failPostMeetingProcessing(reason: reason, at: paths)
      },
      body: { pipeline in
        let input = try PostMeetingInput.rebuild(from: paths, meetingStore: store)
        return try await pipeline.run(input).notice
      }
    )
  }

  /// 启动续查。`beginPostMeetingRecovery` 的抢占语义留在这里:
  /// 用户已手动发起新精转时静默退出,不覆盖也不把新任务标失败。
  ///
  /// D3(08-13 可观测单):「已开始处理但从未提交成功」的早期窗口死亡不再困死——
  /// `hasNeverSubmittedPostMeetingJob`(判据见 `MeetingMetadata`)命中的候选改走全量
  /// 重跑(重新上传+提交)。**不复用旧 request_id,重新生成并覆盖落盘**:submit 成功到
  /// submittedAt 写盘之间存在毫秒级窗口,无法排除「其实已提交」;火山对已消费
  /// request_id 的复用行为无实测(契约文档未覆盖),保守起见不臆测。未提交的任务
  /// 火山侧从未计费(下载完成进队列才计费),全量重跑不产生重复账单。
  /// 其余候选(旧档、或阶段史含供应商侧阶段)一律当作已提交,只许 query。
  @discardableResult
  public func startRecovery(_ candidate: PostMeetingRecoveryCandidate) -> Bool {
    let paths = candidate.paths
    let identity = Self.identity(for: paths.directory)
    guard tasks[identity] == nil, pipelineResolver != nil else { return false }
    let store = meetingStore
    if let metadata = try? store.read(from: paths),
      metadata.hasNeverSubmittedPostMeetingJob
    {
      return startFullRerun(at: paths, identity: identity)
    }
    do {
      _ = try store.beginPostMeetingRecovery(candidate)
    } catch PostMeetingRecoveryError.superseded {
      return false
    } catch {
      _ = try? store.failPostMeetingProcessing(
        reason: error.localizedDescription,
        at: paths,
        ifCurrentRecoveryJobs: candidate.jobs
      )
      return false
    }
    return launch(
      identity: identity,
      directory: paths.directory,
      kind: .recovery,
      broadcastsRecovery: true,
      onFailureWriteDisk: { reason in
        do {
          _ = try store.failPostMeetingProcessing(
            reason: reason,
            at: paths,
            ifCurrentRecoveryJobs: candidate.jobs
          )
        } catch {
          // superseded:新任务身份已接管;写盘本身失败时没有更安全的状态可写。
        }
      },
      body: { pipeline in
        try await pipeline.resume(candidate).notice
      }
    )
  }

  /// 独立生成纪要:只读盘上的 `transcript.md` + `notes.md`,不上传、不 submit、
  /// 不追加 batchASR 用量。失败**不写** `failed` 状态——附加/独立产物的局部失败
  /// 不得把整场会议标成失败(08-07 代价实证)。
  @discardableResult
  public func startMinutes(
    at paths: MeetingPaths,
    languages: [MeetingLanguage],
    kind: PostMeetingOperationKind,
    successNotice: String? = nil
  ) -> Bool {
    launch(
      identity: Self.identity(for: paths.directory),
      directory: paths.directory,
      kind: kind,
      broadcastsRecovery: false,
      onFailureWriteDisk: nil,
      body: { pipeline in
        let result = try await pipeline.regenerateMinutes(at: paths, languages: languages)
        return successNotice ?? result.notice
      }
    )
  }

  /// 外部录音导入。落地后**由协调者自己**链式启动精转——迁移前这一步挂在
  /// 会议库 model 的弱引用上,model 在导入期间被 remount 就静默丢掉了。
  @discardableResult
  public func startImport(
    _ request: ExternalRecordingImport.Request,
    providers: [RoleProviderBinding]
  ) -> Bool {
    let identity = Self.importIdentity(for: request.sourceFileURL)
    guard tasks[identity] == nil else { return false }
    guard let runID = beginRun(identity: identity, directory: nil, kind: .importRecording) else {
      return false
    }
    lastImportError = nil
    let store = meetingStore
    tasks[identity] = Task { @MainActor in
      do {
        let record = try await ExternalRecordingImport.importRecording(
          request,
          providers: providers,
          meetingStore: store
        )
        self.completeRun(
          identity: identity,
          runID: runID,
          directory: nil,
          stage: .finished(notice: "录音已导入"),
          clearsDraft: true
        )
        // 先接上精转(丢不得),再广播落地事件。
        self.startRetranscription(at: record.paths)
        self.changes.send(.imported(directory: record.paths.directory))
      } catch {
        self.lastImportError = error.localizedDescription
        self.completeRun(
          identity: identity,
          runID: runID,
          directory: nil,
          stage: .failed(reason: error.localizedDescription),
          clearsDraft: true
        )
      }
    }
    changes.send(.stateChanged(identity: identity))
    return true
  }

  // MARK: - 运行

  private func launch(
    identity: String,
    directory: URL?,
    kind: PostMeetingOperationKind,
    broadcastsRecovery: Bool,
    onFailureWriteDisk: (@MainActor (String) -> Void)?,
    body: @escaping @Sendable (PostMeetingPipeline) async throws -> String
  ) -> Bool {
    guard let pipelineResolver else { return false }
    guard let runID = beginRun(identity: identity, directory: directory, kind: kind) else {
      return false
    }
    tasks[identity] = Task { @MainActor in
      let channel = PostMeetingProgressChannel()
      // 单消费者有序循环:进度事件只在这里消费一次,界面读快照。
      let progressTask = Task { @MainActor in
        for await progress in channel.events {
          self.apply(progress, identity: identity, runID: runID)
        }
      }
      do {
        let pipeline = try pipelineResolver().reportingProgress { channel.yield($0) }
        let notice = try await body(pipeline)
        channel.finish()
        await progressTask.value
        self.completeRun(
          identity: identity,
          runID: runID,
          directory: directory,
          stage: .finished(notice: notice),
          clearsDraft: true
        )
        if broadcastsRecovery, let directory {
          NotificationCenter.default.post(
            name: .justSaidPostMeetingRecovered,
            object: nil,
            userInfo: ["directory": directory, "notice": notice]
          )
        }
      } catch PostMeetingRecoveryError.superseded {
        channel.finish()
        await progressTask.value
        // 抢占是**正常竞态**,不是失败(`MeetingStore.swift` 的类型注释白纸黑字写着
        // 「不应把新任务改成失败态,也不应向用户弹一条旧错误」)。迁移前 AppCoordinator
        // 对 `pipeline.resume` 抛出的这一支有独立 catch:只摘句柄、不写盘、不发失败态。
        // 走通用 catch 会把 "这次自动续查已被更新的精转任务取代" 画成琥珀色横幅,
        // 旁边「重新精转」还是活的——用户信了就再付一次全时长 batch ASR。
        self.abandonRun(identity: identity, runID: runID, directory: directory)
      } catch {
        channel.finish()
        await progressTask.value
        // 终态写盘先于任何身份/世代卫:孤立的失败运行不得只留下无诊断的 `.processing`。
        onFailureWriteDisk?(error.localizedDescription)
        self.completeRun(
          identity: identity,
          runID: runID,
          directory: directory,
          // 失败保留实时副本作取证(与盘上 `.md.partial` 同一份字节)。
          stage: .failed(reason: error.localizedDescription),
          clearsDraft: false
        )
      }
    }
    changes.send(.stateChanged(identity: identity))
    return true
  }

  private func beginRun(
    identity: String,
    directory: URL?,
    kind: PostMeetingOperationKind
  ) -> UInt64? {
    guard tasks[identity] == nil else { return nil }
    nextRunID &+= 1
    let runID = nextRunID
    // 刻意**不**在这里 cancel 上一条成功提示的计时器:新世代把它作废靠的是
    // `dismissSuccessNotice` 的 runID 守卫。多加一道 cancel 会把那道守卫遮起来
    // ——遮住之后它就再也测不出来了(拿掉守卫也不变红),而它才是竞态下的唯一防线。
    snapshots[identity] = PostMeetingTaskSnapshot(kind: kind, stage: .running, runID: runID)
    // 新一轮开跑:上一轮失败保留的取证副本到此为止,别让旧半成品盖住新产物。
    liveMinutes[identity] = nil
    if let directory {
      runningDirectories[identity] = directory.standardizedFileURL
    }
    return runID
  }

  private func apply(
    _ progress: PostMeetingProgress,
    identity: String,
    runID: UInt64
  ) {
    guard
      let current = snapshots[identity],
      current.runID == runID,
      current.stage.isRunning
    else {
      return
    }
    var stage = current.stage
    let stageChanged = stage.updateRunningDetail(from: progress)
    var draftChanged = false
    if let content = progress.minutesLiveContent, let language = progress.minutesLanguage {
      let draft = PostMeetingLiveMinutesDraft(language: language, content: content)
      if liveMinutes[identity] != draft {
        liveMinutes[identity] = draft
        draftChanged = true
      }
    }
    if stageChanged {
      snapshots[identity] = PostMeetingTaskSnapshot(
        kind: current.kind,
        stage: stage,
        runID: runID
      )
    }
    if stageChanged || draftChanged {
      changes.send(.stateChanged(identity: identity))
    }
  }

  private func completeRun(
    identity: String,
    runID: UInt64,
    directory: URL?,
    stage: PostMeetingStage,
    clearsDraft: Bool
  ) {
    guard snapshots[identity]?.runID == runID else { return }
    let kind = snapshots[identity]?.kind ?? .fullPostMeeting
    snapshots[identity] = PostMeetingTaskSnapshot(kind: kind, stage: stage, runID: runID)
    if clearsDraft {
      liveMinutes[identity] = nil
    }
    // 只摘句柄,**不 cancel**:窗口与 View 销毁只释放呈现。
    tasks[identity] = nil
    if directory != nil {
      runningDirectories.removeValue(forKey: identity)
    }
    // 成功提示是瞬时的,失败提示不是:排展示门必须在摘句柄之后(守卫要看到"已结算")。
    if case .finished = stage, Self.transientSuccessNoticeKinds.contains(kind) {
      scheduleSuccessNoticeDismissal(identity: identity, runID: runID)
    }
    changes.send(.artifactsChanged(identity: identity))
  }

  /// 抢占退出:快照**整条摘掉**,由调用方回落磁盘事实;不写盘、不发恢复广播,
  /// 与迁移前那条静默分支一致。
  ///
  /// 刻意不发 `.none` 快照:`stage(for:kinds:)` 返回的是 `Optional`,`.some(.none)`
  /// 会让调用方的 `if let` 命中并**跳过磁盘兜底**——盘上真是 `.failed` 时横幅就没了。
  private func abandonRun(identity: String, runID: UInt64, directory: URL?) {
    guard snapshots[identity]?.runID == runID else { return }
    snapshots.removeValue(forKey: identity)
    liveMinutes.removeValue(forKey: identity)
    noticeDismissal.cancel(identity: identity)
    // 只摘句柄,**不 cancel**;句柄留着会永久挡住这场会议后续所有启动。
    tasks[identity] = nil
    if directory != nil {
      runningDirectories.removeValue(forKey: identity)
    }
    changes.send(.artifactsChanged(identity: identity))
  }

  /// 尚未起任务就失败(如清诊断写盘失败)时,直接发布终态快照。
  private func publishTerminalStage(
    identity: String,
    kind: PostMeetingOperationKind,
    stage: PostMeetingStage
  ) {
    nextRunID &+= 1
    snapshots[identity] = PostMeetingTaskSnapshot(kind: kind, stage: stage, runID: nextRunID)
    changes.send(.artifactsChanged(identity: identity))
  }
}

extension Notification.Name {
  /// 会后精转/续查成功;userInfo: directory(URL) + notice(String)。
  public static let justSaidPostMeetingRecovered = Notification.Name(
    "justsaid.postmeeting.recovered"
  )
}
