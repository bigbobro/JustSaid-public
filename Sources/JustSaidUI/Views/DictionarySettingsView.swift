import JustSaidCore
import SwiftUI

/// 设置页「词典」页签(F1)。
///
/// 一份全局词表、一处维护、两处生效(精转热词直传 + 纪要提示词专名锚定),读写都走
/// `DictionaryStore`,落地就是明文 `~/JustSaid/词典.txt`——用户直接改那个文件也算数,
/// 所以本页每次出现都重读磁盘,底部还留了一个 ↻ 让开着窗也能对齐文件。
///
/// 形态参照 Typeless:卡片栅格 + 搜索 + 悬停改删。2026-07-30 用户实测后的交互修订:
/// - **点空白即失焦提交**(原先编辑框永远占着焦点,"存没存"无从判断);Esc 取消;
/// - **保存回执**:刚保存的词卡片闪一下青色(与转写跳转定位的闪烁同一语言);
/// - **双击词条进入编辑**;悬停按钮加大加距、带悬浮提示,删除悬停变警示色;
/// - **搜索框回车即添加**(没有匹配时)——找词与加词是同一个动作;网格首格常驻「+ 新词」。
public struct DictionarySettingsView: View {
  @StateObject private var model: DictionaryPaneModel
  @FocusState private var editorFocus: EditorFocus?

  enum EditorFocus: Hashable {
    case newWord
    case edit(String)
  }

  public init(
    store: DictionaryStore = DictionaryStore(),
    meetingStore: MeetingStore = MeetingStore(),
    harvestIgnoreStore: HarvestIgnoreStore = HarvestIgnoreStore()
  ) {
    _model = StateObject(
      wrappedValue: DictionaryPaneModel(
        store: store,
        meetingStore: meetingStore,
        harvestIgnoreStore: harvestIgnoreStore
      )
    )
  }

  /// 收割箱「并入现有条目当称呼」的行改写(08-17 #4):把候选词面追加到既有行的
  /// 称呼列表尾部,保持 `主体=称呼1,称呼2` 语法。词面已是该行词面(主体或称呼)时
  /// 返回 nil = 不需要写盘。纯函数,验证程序直接断言行语法。
  public static func mergedLine(_ line: String, adding word: String) -> String? {
    guard let entry = DictionaryEntry.parse(line) else { return nil }
    guard word != entry.canonical, !entry.appellations.contains(word) else {
      return nil
    }
    return "\(entry.canonical)=\((entry.appellations + [word]).joined(separator: ","))"
  }

  /// 搜索匹配:主体名与称呼都算命中。
  ///
  /// 名册行存在之后,按称呼去找那个人才是最自然的动作(会上听到「老张」→ 搜「老张」
  /// 应当命中 `张三=三儿,老张` 这张卡片)。只比整行的话会一无所获,回车还会顺手
  /// 新增一个重复的纯词行。纯函数,验证程序直接断言它。
  public static func matches(_ line: String, keyword: String) -> Bool {
    guard let entry = DictionaryEntry.parse(line) else {
      return line.localizedCaseInsensitiveContains(keyword)
    }
    return entry.allSpokenForms.contains {
      $0.localizedCaseInsensitiveContains(keyword)
    }
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if let errorMessage = model.errorMessage {
        DegradedBanner(text: errorMessage)
          .overlay(alignment: .trailing) {
            if model.canDismissWriteError {
              Button("关闭") {
                model.dismissWriteError()
              }
              .buttonStyle(.textAction)
              .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
              .foregroundStyle(Tokens.Color.warn)
              .padding(.trailing, Tokens.Spacing.md)
              .accessibilityLabel("关闭写入失败提示")
              .runtimeAccessibilityIdentifier("settings.dictionary.error-dismiss")
            }
          }
      }
      content
      Divider()
      harvestSection
      Divider()
      footer
    }
    .background(Tokens.Color.bg)
    // 点页面任意空白 = 收走焦点;编辑卡以失焦为提交信号(见 DictionaryWordEditorCard)。
    .contentShape(Rectangle())
    .onTapGesture { editorFocus = nil }
  }

  /// 用户改搜索词才清提示;程序把 query 清空(已存在回执)不走这个 Binding。
  private var searchQuery: Binding<String> {
    Binding(
      get: { model.query },
      set: { newValue in
        if newValue != model.query {
          model.clearSearchHint()
        }
        model.query = newValue
      }
    )
  }

  // MARK: - 头部:说明 + 搜索(兼添加) + 新词

  private var header: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
      HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.smd) {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
          Text("词典")
            .font(.system(size: Tokens.FontSize.pageTitle, weight: .semibold))
            .foregroundStyle(Tokens.Color.ink)
          Text("这里的专名会在会后精转时直传给识别引擎，并要求纪要按这里的拼写落字。一处维护，两处生效。")
            .font(.system(size: Tokens.FontSize.bodyMinimum))
            .foregroundStyle(Tokens.Color.ink3)
            .fixedSize(horizontal: false, vertical: true)
          // 名册行是这一版的主力:同一个人在会上有好几种叫法,写出来才能都进热词、
          // 也才能让纪要统一署名。语法不写出来就等于没有。
          Text("同一个人有多种叫法的，写成「本名=称呼1，称呼2」——例如 张三=三儿，老张。这些叫法都会发给识别引擎，纪要一律用本名署名。")
            .font(.system(size: Tokens.FontSize.uiEmphasis))
            .foregroundStyle(Tokens.Color.ink4)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: Tokens.Spacing.xsm)
      }

      HStack(spacing: Tokens.Spacing.xs) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.ink4)
        TextField("搜索词条；没有匹配时，回车直接添加", text: searchQuery)
          .textFieldStyle(.plain)
          .font(.system(size: Tokens.FontSize.body))
          .onSubmit { model.addFromSearch() }
          .accessibilityLabel("搜索词条，没有匹配时回车直接添加")
        if !model.query.isEmpty {
          Button {
            model.query = ""
            model.clearSearchHint()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: Tokens.FontSize.ui))
          }
          .buttonStyle(IconHoverButtonStyle(base: Tokens.Color.ink4, hover: Tokens.Color.ink2))
          .accessibilityLabel("清空搜索")
        }
      }
      .padding(.horizontal, Tokens.Spacing.xsm)
      .padding(.vertical, Tokens.Spacing.xs)
      // 设置页输入井统一 surface2(批4 皮层统一):此前用 pane 底自成一派。
      .insetPanel()
      if let searchHint = model.searchHint {
        Text(searchHint)
          .font(.system(size: Tokens.FontSize.ui))
          .foregroundStyle(Tokens.Color.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .runtimeAccessibilityIdentifier("settings.dictionary.search-hint")
      }
    }
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.xl)
  }

  // MARK: - 正文:卡片栅格 / 两种空态

  @ViewBuilder
  private var content: some View {
    if model.words.isEmpty && !model.isAddingWord {
      VStack(spacing: Tokens.Spacing.smd) {
        emptyState(
          title: "词表还是空的",
          detail: "把客户名、产品名、同事英文名这类容易被听错的专名加进来。"
            + "文件就是 \(model.fileLabel)，直接编辑那个文件同样算数。"
        )
        GhostAddCard {
          model.beginAdding()
          editorFocus = .newWord
        }
        .frame(width: 168)
        .padding(.bottom, Tokens.Spacing.lg)
      }
    } else if model.visibleWords.isEmpty && !model.isAddingWord && !model.query.isEmpty {
      emptyState(
        title: "没有匹配「\(model.query)」的词条",
        detail: "回车把它加进词典，或换个关键词、清空搜索看全部 \(model.words.count) 个词。"
      )
    } else {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 168, maximum: 260), spacing: Tokens.Spacing.sm)],
          alignment: .leading,
          spacing: Tokens.Spacing.sm
        ) {
          if model.isAddingWord {
            DictionaryWordEditorCard(
              initialText: "",
              placeholder: "新词",
              focusValue: .newWord,
              focus: $editorFocus,
              onCommit: { model.commitNewWord($0) },
              onCancel: { model.cancelAdding() }
            )
            .id(model.addingSessionID)
            .runtimeAccessibilityIdentifier("settings.dictionary.new-editor")
          } else if model.query.isEmpty {
            // 常驻「+ 新词」占首格:加词不必去右上角找按钮(2026-07-30 用户实测反馈)。
            GhostAddCard {
              model.beginAdding()
              editorFocus = .newWord
            }
          }
          ForEach(model.visibleWords, id: \.self) { word in
            if model.editingWord == word {
              DictionaryWordEditorCard(
                initialText: word,
                placeholder: word,
                focusValue: .edit(word),
                focus: $editorFocus,
                onCommit: { model.commitEdit(of: word, to: $0) },
                onCancel: { model.cancelEditing() }
              )
            } else {
              DictionaryWordCard(
                word: word,
                isRecentlySaved: model.recentlySaved == word,
                isArmedForDeletion: model.armedDeletionWord == word,
                onEdit: {
                  model.disarmDeletion()
                  model.beginEditing(word)
                  editorFocus = .edit(word)
                },
                onArmDelete: { model.armDeletion(word) },
                onConfirmDelete: { model.confirmRemove(word) },
                onDisarmDelete: { model.disarmDeletion() }
              )
            }
          }
        }
        .padding(.horizontal, Tokens.Spacing.lg)
        .padding(.vertical, Tokens.Spacing.xl)
      }
    }
  }

  private func emptyState(title: String, detail: String) -> some View {
    VStack(spacing: Tokens.Spacing.xs) {
      Text(title)
        .font(.system(size: Tokens.FontSize.headingSmall, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink2)
      Text(detail)
        .font(.system(size: Tokens.FontSize.uiEmphasis))
        .foregroundStyle(Tokens.Color.ink3)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: Tokens.Layout.emptyStateContentWidth)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Tokens.Spacing.lg)
  }

  // MARK: - 收割箱(08-17 #4):精转后未入册专名,入册永远由用户拍板

  private var harvestSection: some View {
    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
      HStack(spacing: Tokens.Spacing.xs) {
        Text("收割箱")
          .font(.system(size: Tokens.FontSize.headingSmall, weight: .semibold))
          .foregroundStyle(Tokens.Color.ink)
        if !model.harvestItems.isEmpty {
          Text("\(model.harvestItems.count) 个候选")
            .font(.system(size: Tokens.FontSize.ui))
            .foregroundStyle(Tokens.Color.ink4)
        }
        Spacer(minLength: Tokens.Spacing.xsm)
      }
      Text("纪要生成时顺带发现的未入册专名。并入现有条目当称呼、立为新主体，或忽略——绝不自动入册。")
        .font(.system(size: Tokens.FontSize.ui))
        .foregroundStyle(Tokens.Color.ink4)
        .fixedSize(horizontal: false, vertical: true)
      if model.harvestItems.isEmpty {
        Text("暂无待收割生词")
          .font(.system(size: Tokens.FontSize.uiEmphasis))
          .foregroundStyle(Tokens.Color.ink3)
          .padding(.vertical, Tokens.Spacing.xs)
          .runtimeAccessibilityIdentifier("settings.dictionary.harvest.empty")
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            ForEach(model.harvestItems) { item in
              harvestRow(item)
            }
          }
        }
        .frame(maxHeight: 168)
      }
    }
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.sm)
  }

  private func harvestRow(_ item: HarvestBoxItem) -> some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      Text(item.text)
        .font(.system(size: Tokens.FontSize.body))
        .foregroundStyle(Tokens.Color.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(item.text)
      Text("共 \(item.totalCount) 次 · \(item.meetingCount) 场")
        .font(.system(size: Tokens.FontSize.secondary))
        .foregroundStyle(Tokens.Color.ink4)
        .lineLimit(1)
      Spacer(minLength: Tokens.Spacing.xxs)
      Menu {
        ForEach(model.mergeTargets, id: \.self) { canonical in
          Button("并入「\(canonical)」当称呼") {
            model.harvestMerge(item.text, into: canonical)
          }
        }
      } label: {
        Text("并入…")
          .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
      }
      .menuStyle(.button)
      .buttonStyle(.textAction)
      .fixedSize()
      .disabled(model.mergeTargets.isEmpty)
      .help(
        model.mergeTargets.isEmpty
          ? "词典还没有可并入的主体条目"
          : "把「\(item.text)」追加为某个现有主体的称呼"
      )
      .accessibilityLabel("把「\(item.text)」并入现有条目当称呼")
      .runtimeAccessibilityIdentifier("settings.dictionary.harvest.merge")
      Button("新主体") {
        model.harvestAddNewSubject(item.text)
      }
      .buttonStyle(.textAction)
      .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
      .help("把「\(item.text)」作为新主体加进词典")
      .accessibilityLabel("把「\(item.text)」立为新主体")
      .runtimeAccessibilityIdentifier("settings.dictionary.harvest.new")
      Button("忽略") {
        model.harvestIgnore(item.text)
      }
      .buttonStyle(.textAction)
      .font(.system(size: Tokens.FontSize.ui))
      .foregroundStyle(Tokens.Color.ink3)
      .help("从收割箱移除「\(item.text)」，之后不再出现")
      .accessibilityLabel("忽略「\(item.text)」")
      .runtimeAccessibilityIdentifier("settings.dictionary.harvest.ignore")
    }
    .padding(.horizontal, Tokens.Spacing.sm)
    .padding(.vertical, Tokens.Spacing.xxs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Tokens.Radius.widget).fill(Tokens.Color.pane)
    )
    .runtimeAccessibilityIdentifier("settings.dictionary.harvest.row.\(item.text)")
  }

  // MARK: - 底部:词数 + 文件出处 + 重读

  private var footer: some View {
    HStack(spacing: Tokens.Spacing.xsm) {
      Text("\(model.words.count) 个词")
        .font(.system(size: Tokens.FontSize.ui, weight: .semibold))
        .foregroundStyle(Tokens.Color.ink3)
      Text(model.fileLabel)
        .font(.system(size: Tokens.FontSize.secondary, design: .monospaced))
        .foregroundStyle(Tokens.Color.ink4)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
      Spacer(minLength: Tokens.Spacing.xsm)
      Button {
        model.reload()
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: Tokens.FontSize.caption, weight: .semibold))
      }
      .buttonStyle(.iconHover)
      .help("重新读取词典文件(在别处直接改过文件时用)")
      .accessibilityLabel("重新读取词典文件")
    }
    .padding(.horizontal, Tokens.Spacing.lg)
    .padding(.vertical, Tokens.Spacing.sm)
  }
}

// MARK: - 词条卡片

private struct DictionaryWordCard: View {
  let word: String
  let isRecentlySaved: Bool
  let isArmedForDeletion: Bool
  let onEdit: () -> Void
  let onArmDelete: () -> Void
  let onConfirmDelete: () -> Void
  let onDisarmDelete: () -> Void

  @State private var isHovering = false
  @State private var isHoveringEdit = false
  @State private var isHoveringDelete = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 卡片主体永远显示本名;称呼只报个数——一张卡片上摊开五种叫法,读的人先看到的是一堆别称。
  private var entry: DictionaryEntry? { DictionaryEntry.parse(word) }

  var body: some View {
    HStack(spacing: Tokens.Spacing.xs) {
      VStack(alignment: .leading, spacing: Tokens.Spacing.hairline) {
        Text(entry?.canonical ?? word)
          .font(.system(size: Tokens.FontSize.body))
          .foregroundStyle(Tokens.Color.ink)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(entry?.canonical ?? word)
        if let count = entry?.appellations.count, count > 0 {
          Text("称呼 \(count) 个")
            .font(.system(size: Tokens.FontSize.caption))
            .foregroundStyle(Tokens.Color.ink4)
            .lineLimit(1)
        }
      }
      Spacer(minLength: Tokens.Spacing.xxs)
      // 用 opacity 而不是 if:悬停按钮始终在布局树里,鼠标移入不会把卡片撑变形。
      // 间距 8、字号 12(2026-07-30 用户实测:原 spacing 2 / 10.5 号太挤,分不清也易误触)。
      HStack(spacing: Tokens.Spacing.xsm) {
        Button(action: onEdit) {
          Image(systemName: "pencil")
            .foregroundStyle(isHoveringEdit ? Tokens.Color.ink : Tokens.Color.ink3)
        }
        .help("编辑")
        .onHover { isHoveringEdit = $0 }
        .accessibilityLabel("编辑「\(word)」")
        Button {
          if isArmedForDeletion {
            onConfirmDelete()
          } else {
            onArmDelete()
          }
        } label: {
          Image(systemName: isArmedForDeletion ? "trash.fill" : "trash")
            .foregroundStyle(
              isHoveringDelete || isArmedForDeletion ? Tokens.Color.warn : Tokens.Color.ink3
            )
        }
        .help(isArmedForDeletion ? "再点一次确认删除" : "删除")
        .onHover { isHoveringDelete = $0 }
        .accessibilityLabel(isArmedForDeletion ? "确认删除「\(word)」" : "删除「\(word)」")
      }
      .buttonStyle(.plain)
      .font(.system(size: Tokens.FontSize.bodyMinimum))
      .opacity(isHovering ? 1 : 0)
    }
    .padding(.horizontal, Tokens.Spacing.sm)
    .padding(.vertical, Tokens.Spacing.xsm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isRecentlySaved ? Tokens.Color.acSoft : Tokens.Color.card,
      in: RoundedRectangle(cornerRadius: Tokens.Radius.widget)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.Radius.widget)
        .stroke(
          isRecentlySaved || isHovering ? Tokens.Color.acLine : Tokens.Color.line,
          lineWidth: 1
        )
    )
    .tokenShadow(Tokens.Shadow.sh1)
    .animation(reduceMotion ? nil : .easeOut(duration: Tokens.Motion.flashOut), value: isRecentlySaved)
    .onHover { hovering in
      isHovering = hovering
      if !hovering {
        onDisarmDelete()
      }
    }
    // 双击直接进编辑:比找悬停里的铅笔更顺手;单击落到页面手势上只负责收焦点。
    .onTapGesture(count: 2, perform: onEdit)
    .help("双击编辑")
  }
}

/// 常驻的「+ 新词」占位卡片:虚线描边,点击就地变成输入框。
private struct GhostAddCard: View {
  let onTap: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: Tokens.Spacing.xxs) {
        Image(systemName: "plus")
          .font(.system(size: Tokens.FontSize.secondary, weight: .semibold))
        Text("新词")
          .font(.system(size: Tokens.FontSize.body))
      }
      .foregroundStyle(isHovering ? Tokens.Color.ac : Tokens.Color.ink4)
      .padding(.horizontal, Tokens.Spacing.sm)
      .padding(.vertical, Tokens.Spacing.xsm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.widget)
          .strokeBorder(
            isHovering ? Tokens.Color.acLine : Tokens.Color.line,
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .accessibilityLabel("新增一个词条")
    .runtimeAccessibilityIdentifier("settings.dictionary.add")
  }
}

/// 新增与改名共用的输入卡片:回车或失焦即提交,Esc 取消,内容为空视作取消。
private struct DictionaryWordEditorCard: View {
  let initialText: String
  let placeholder: String
  let focusValue: DictionarySettingsView.EditorFocus
  let focus: FocusState<DictionarySettingsView.EditorFocus?>.Binding
  let onCommit: (String) -> Void
  let onCancel: () -> Void

  @State private var draft: String
  /// 回车提交后视图随即消失,失焦回调会再来一次;没有这道闸就会提交两次。
  @State private var hasSettled = false

  init(
    initialText: String,
    placeholder: String,
    focusValue: DictionarySettingsView.EditorFocus,
    focus: FocusState<DictionarySettingsView.EditorFocus?>.Binding,
    onCommit: @escaping (String) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.initialText = initialText
    self.placeholder = placeholder
    self.focusValue = focusValue
    self.focus = focus
    self.onCommit = onCommit
    self.onCancel = onCancel
    _draft = State(initialValue: initialText)
  }

  var body: some View {
    TextField(placeholder, text: $draft)
      .textFieldStyle(.plain)
      .font(.system(size: Tokens.FontSize.body))
      .focused(focus, equals: focusValue)
      .onSubmit { settle() }
      // 焦点被收走(点空白/切到别处)= 提交:失焦不能不了了之,这是"存没存"焦虑的根源。
      .onChange(of: focus.wrappedValue) { _, current in
        if current != focusValue {
          settle()
        }
      }
      .onKeyPress(.escape) {
        cancel()
        return .handled
      }
      .onAppear { focus.wrappedValue = focusValue }
      .padding(.horizontal, Tokens.Spacing.sm)
      .padding(.vertical, Tokens.Spacing.xsm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Tokens.Color.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.widget))
      .overlay(
        RoundedRectangle(cornerRadius: Tokens.Radius.widget)
          .stroke(Tokens.Color.ac, lineWidth: 1.5)
      )
      .accessibilityLabel(initialText.isEmpty ? "新词" : "编辑「\(initialText)」")
  }

  private func settle() {
    guard !hasSettled else { return }
    hasSettled = true
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      onCancel()
    } else {
      onCommit(trimmed)
    }
  }

  private func cancel() {
    guard !hasSettled else { return }
    hasSettled = true
    onCancel()
  }
}

// MARK: - 状态

/// 词典页的状态与落盘。
///
/// 每次写入之后都从磁盘回读一遍:`DictionaryStore` 会做去空行、去重、保序,
/// 界面直接显示回读结果,才不会出现「界面上有两个示例产品、文件里只有一个」。
@MainActor
final class DictionaryPaneModel: ObservableObject {
  @Published private(set) var words: [String] = []
  @Published private(set) var editingWord: String?
  @Published private(set) var isAddingWord = false
  @Published private(set) var addingSessionID = 0
  @Published var query = ""
  @Published private(set) var writeErrorMessage: String?
  @Published private(set) var readErrorMessage: String?
  /// 写失败优先于读失败:reload 成功不得盖掉尚未关闭的写入提示。
  var errorMessage: String? { writeErrorMessage ?? readErrorMessage }
  var canDismissWriteError: Bool { writeErrorMessage != nil }
  /// 搜索回车或加词撞到已有词时的就地反馈,不是失败横幅。
  @Published private(set) var searchHint: String?
  /// 两段式删除的武装词:悬停离开或 5 秒后复位。
  @Published private(set) var armedDeletionWord: String?
  /// 刚保存成功的词:对应卡片闪一下青色作回执,时长与字段级「已保存」共用一个常量。
  @Published private(set) var recentlySaved: String?
  /// 收割箱(08-17 #4):全库 minutes.json 候选 − 名册词面 − 忽略表,聚合后的行。
  @Published private(set) var harvestItems: [HarvestBoxItem] = []

  private let store: DictionaryStore
  private let meetingStore: MeetingStore
  private let harvestIgnoreStore: HarvestIgnoreStore
  private var flashTask: Task<Void, Never>?
  private var deleteArmTask: Task<Void, Never>?

  init(
    store: DictionaryStore,
    meetingStore: MeetingStore = MeetingStore(),
    harvestIgnoreStore: HarvestIgnoreStore = HarvestIgnoreStore()
  ) {
    self.store = store
    self.meetingStore = meetingStore
    self.harvestIgnoreStore = harvestIgnoreStore
    // 在 init 里就读盘,而不是等 onAppear:页面第一帧就是真内容,不闪空态。
    reload()
  }

  var fileLabel: String {
    let path = store.fileURL.path
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  /// 搜索同时匹配本名与称呼:名册行存在之后,按称呼去找那个人才是最自然的动作
  /// (会上听到「老张」→ 搜「老张」应当命中 `张三=三儿,老张` 这张卡片)。
  /// 只比整行的话会一无所获,回车还会顺手新增一个重复的纯词行。
  var visibleWords: [String] {
    let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keyword.isEmpty else { return words }
    return words.filter { DictionarySettingsView.matches($0, keyword: keyword) }
  }

  func reload() {
    do {
      words = try store.load()
      readErrorMessage = nil
    } catch {
      readErrorMessage = "读取词典文件失败：\(error.localizedDescription)"
    }
    // 收割箱跟着词表一起刷新:入册后按当前名册现算,已入册的候选立刻退箱。
    reloadHarvest()
  }

  func dismissWriteError() {
    writeErrorMessage = nil
  }

  func clearSearchHint() {
    searchHint = nil
  }

  func armDeletion(_ word: String) {
    deleteArmTask?.cancel()
    armedDeletionWord = word
    deleteArmTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      if armedDeletionWord == word {
        armedDeletionWord = nil
      }
    }
  }

  func disarmDeletion() {
    deleteArmTask?.cancel()
    deleteArmTask = nil
    armedDeletionWord = nil
  }

  func beginAdding() {
    disarmDeletion()
    editingWord = nil
    addingSessionID += 1
    isAddingWord = true
  }

  func cancelAdding() {
    isAddingWord = false
  }

  func beginEditing(_ word: String) {
    disarmDeletion()
    isAddingWord = false
    editingWord = word
  }

  func cancelEditing() {
    editingWord = nil
  }

  /// 新词插在最前:刚加的词要立刻看得见,不用在几十个词里找。
  /// 已有同名主体时不写盘,与搜索回车共用「这个词已在词典里」口径。
  func commitNewWord(_ word: String) {
    isAddingWord = false
    if let existing = existingWord(matching: word) {
      searchHint = Self.existingWordHint
      flash(existing)
      return
    }
    persist([word] + words, flashing: word)
  }

  func commitEdit(of original: String, to newValue: String) {
    editingWord = nil
    guard newValue != original else { return }
    persist(words.map { $0 == original ? newValue : $0 }, flashing: newValue)
  }

  func confirmRemove(_ word: String) {
    disarmDeletion()
    persist(words.filter { $0 != word }, flashing: nil)
  }

  /// 搜索框回车:没有匹配 → 直接把搜索词加进词典;已有完全一致的词 → 闪那个词;
  /// 只有模糊命中时给「已有相似词」反馈,不再静默 return。
  func addFromSearch() {
    let candidate = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return }
    if let existing = existingWord(matching: candidate) {
      query = ""
      searchHint = Self.existingWordHint
      flash(existing)
      return
    }
    guard visibleWords.isEmpty else {
      searchHint = Self.similarWordHint
      return
    }
    query = ""
    persist([candidate] + words, flashing: candidate)
  }

  private static let existingWordHint = "这个词已在词典里"
  private static let similarWordHint = "已有相似词，可直接编辑"

  private func existingWord(matching candidate: String) -> String? {
    let candidateCanonical = DictionaryEntry.parse(candidate)?.canonical ?? candidate
    return words.first { line in
      let canonical = DictionaryEntry.parse(line)?.canonical ?? line
      return canonical.caseInsensitiveCompare(candidateCanonical) == .orderedSame
    }
  }

  private func persist(_ candidate: [String], flashing saved: String?) {
    do {
      try store.save(candidate)
      writeErrorMessage = nil
    } catch {
      writeErrorMessage = "写入词典文件失败：\(error.localizedDescription)"
    }
    // 成功要回读(拿到去重后的真身),失败更要回读(把界面拉回文件的真实状态)。
    // 读成功不得清写失败:否则横幅一闪即灭,用户以为存上了。
    reload()
    if writeErrorMessage == nil, let saved, words.contains(saved) {
      flash(saved)
    }
  }

  private func flash(_ word: String) {
    flashTask?.cancel()
    recentlySaved = word
    flashTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(SavedFlashLabel.flashDuration))
      guard !Task.isCancelled else { return }
      self?.recentlySaved = nil
    }
  }

  // MARK: - 收割箱(08-17 #4)

  /// 「并入…」菜单可选的主体清单(词表现有条目的主体名,保序)。
  var mergeTargets: [String] {
    words.compactMap { DictionaryEntry.parse($0)?.canonical }
  }

  /// 全库聚合:逐场读 minutes.json 的 unknownProperNouns(v1 旧档为 nil 自然跳过),
  /// 减名册词面、减忽略表。minutes.json 都是小文件,与 `reload()` 同步读盘一个口径;
  /// 单场坏文件跳过,不挡整箱。
  func reloadHarvest() {
    let roster = DictionaryEntry.parseAll(words).flatMap(\.allSpokenForms)
    let ignored = (try? harvestIgnoreStore.load()) ?? []
    let candidatesByMeeting = meetingStore.listMeetings().compactMap {
      record -> [HarvestCandidate]? in
      guard
        let data = try? Data(contentsOf: record.paths.minutesStructured),
        let document = try? StructuredArtifactCodec.decode(
          MeetingMinutesDocument.self,
          from: data
        )
      else {
        return nil
      }
      return document.unknownProperNouns
    }
    harvestItems = HarvestAggregator.aggregate(
      candidatesByMeeting: candidatesByMeeting,
      rosterForms: roster,
      ignored: ignored
    )
  }

  /// 把候选词面追加为某现有主体的称呼:走 DictionaryStore 既有行语法保存通道。
  func harvestMerge(_ word: String, into canonical: String) {
    guard
      let index = words.firstIndex(where: {
        DictionaryEntry.parse($0)?.canonical == canonical
      })
    else {
      return
    }
    guard let merged = DictionarySettingsView.mergedLine(words[index], adding: word) else {
      // 词面已是该条目的词面:不写盘,收割箱刷新后它自然退箱。
      reloadHarvest()
      return
    }
    var updated = words
    updated[index] = merged
    persist(updated, flashing: merged)
  }

  /// 把候选词面立为新主体(纯词行),插在最前与手动加词一致。
  func harvestAddNewSubject(_ word: String) {
    guard existingWord(matching: word) == nil else {
      reloadHarvest()
      return
    }
    persist([word] + words, flashing: word)
  }

  /// 忽略:进忽略表,不碰词典,也不回写任何会议的 minutes.json。
  func harvestIgnore(_ word: String) {
    do {
      try harvestIgnoreStore.ignore(word)
    } catch {
      writeErrorMessage = "写入收割忽略表失败：\(error.localizedDescription)"
    }
    reloadHarvest()
  }
}
