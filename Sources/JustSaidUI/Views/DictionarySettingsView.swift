import AppKit
import JustSaidCore
import SwiftUI

/// 独立词典页及其双区内容。
///
/// 一份全局词表、一处维护、两处生效(精转热词直传 + 纪要提示词专名锚定),读写都走
/// `DictionaryStore`,落地就是明文 `~/JustSaid/词典.txt`——用户直接改那个文件也算数,
/// 所以本页每次出现都重读磁盘。
///
/// 词典为常驻主栏，收割箱为次栏；保留搜索与悬停改删。既有交互约定:
/// - **点空白即失焦提交**(原先编辑框永远占着焦点,"存没存"无从判断);Esc 取消;
/// - **保存回执**:刚保存的词卡片闪一下青色(与转写跳转定位的闪烁同一语言);
/// - **双击词条进入编辑**;悬停按钮加大加距、带悬浮提示,删除悬停变警示色;
/// - **搜索框回车即添加**(没有匹配时)——找词与加词是同一个动作;标题行右端提供「新词」。
/// 图标轨上的独立词典页，保留词典与收割箱的双区内容。
public struct DictionaryPageView: View {
  private let store: DictionaryStore
  private let meetingStore: MeetingStore
  private let harvestIgnoreStore: HarvestIgnoreStore
  private let onHarvestCountChange: (() -> Void)?
  private let onDone: (() -> Void)?

  public init(
    store: DictionaryStore, meetingStore: MeetingStore,
    harvestIgnoreStore: HarvestIgnoreStore,
    onHarvestCountChange: (() -> Void)? = nil, onDone: (() -> Void)? = nil
  ) {
    self.store = store
    self.meetingStore = meetingStore
    self.harvestIgnoreStore = harvestIgnoreStore
    self.onHarvestCountChange = onHarvestCountChange
    self.onDone = onDone
  }

  public var body: some View {
    VStack(spacing: .zero) {
      WorkspaceTopBar("词典") { EmptyView() }
      DictionarySettingsView(
        store: store, meetingStore: meetingStore, harvestIgnoreStore: harvestIgnoreStore,
        onHarvestCountChange: onHarvestCountChange
      )
      .padding(.top, Tokens.V1.Space.md)
    }
    .background(Tokens.V1.Color.paper)
    .onExitCommand { onDone?() }
    .runtimeAccessibilityIdentifier("dictionary.page")
  }
}

public struct DictionarySettingsView: View {
  @StateObject private var model: DictionaryPaneModel
  private let onHarvestCountChange: (() -> Void)?
  @FocusState private var editorFocus: EditorFocus?

  enum EditorFocus: Hashable {
    case newWord
    case edit(String)
  }

  public init(
    store: DictionaryStore = DictionaryStore(),
    meetingStore: MeetingStore = MeetingStore(),
    harvestIgnoreStore: HarvestIgnoreStore = HarvestIgnoreStore(),
    onHarvestCountChange: (() -> Void)? = nil
  ) {
    self.onHarvestCountChange = onHarvestCountChange
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

  @State private var bulkAction: BulkAction?
  @State private var selectedWords: Set<String> = []
  @State private var deletionWords: [String]?

  private var selectedVisibleWords: [String] {
    model.visibleWords.filter { selectedWords.contains($0) }
  }

  @State private var selectedHarvestWords: Set<String> = []

  private var selectedCandidates: [String] {
    model.harvestItems.map(\.text).filter { selectedHarvestWords.contains($0) }
  }

  private struct BulkAction: Identifiable {
    let accepting: Bool
    let words: [String]
    var id: Bool { accepting }
  }

  public var body: some View {
    GeometryReader { geometry in
      SettingsPage(fullWidth: true, title: "词典与收割箱", subtitle: "维护常用专名，处理纪要里发现的新词。") {
        VStack(alignment: .leading, spacing: Tokens.V1.Space.lg) {
          if let errorMessage = model.errorMessage {
            DegradedBanner(text: errorMessage)
              .overlay(alignment: .trailing) {
                if model.canDismissWriteError {
                  Button("关闭") { model.dismissWriteError() }
                    .buttonStyle(.v1Outline)
                    .accessibilityLabel("关闭写入失败提示")
                    .runtimeAccessibilityIdentifier("settings.dictionary.error-dismiss")
                }
              }
          }
          HStack(alignment: .top, spacing: Tokens.V1.Space.lg) {
            wordsSection
              .frame(
                width: (geometry.size.width - Tokens.V1.Space.xl * 2 - Tokens.V1.Space.lg) * 3 / 5)
            harvestSection
              .frame(maxWidth: .infinity)
          }
          .frame(
            height: max(
              Tokens.V1.Size.settingsSheetMinHeight,
              geometry.size.height - Tokens.V1.Size.barHeight - Tokens.V1.Space.lg)
          )
          .runtimeAccessibilityIdentifier("settings.dictionary.regions")
          .disabled(model.isLoading)
        }
      }
    }
    .runtimeAccessibilityIdentifier(
      bulkAction == nil
        ? "settings.dictionary.harvest.confirmation.closed"
        : "settings.dictionary.harvest.confirmation.pending"
    )
    .runtimeAccessibilityIdentifier(
      model.isLoading ? "settings.dictionary.loading" : "settings.dictionary.ready"
    )
    // 点页面任意空白 = 收走焦点;编辑卡以失焦为提交信号(见 DictionaryWordEditorCard)。
    .contentShape(Rectangle())
    .onTapGesture { editorFocus = nil }
    .runtimeAccessibilityIdentifier(
      deletionWords == nil
        ? "settings.dictionary.deletion.closed" : "settings.dictionary.deletion.pending"
    )
    .onChange(of: model.harvestItems.count) { _, _ in onHarvestCountChange?() }
    .onChange(of: model.visibleWords) { _, words in
      selectedWords.formIntersection(words)
    }
    .confirmationDialog(
      "删除所选词条？",
      isPresented: Binding(get: { deletionWords != nil }, set: { if !$0 { deletionWords = nil } }),
      titleVisibility: .visible, presenting: deletionWords
    ) { words in
      Button("删除 \(words.count) 个词条", role: .destructive) {
        model.confirmRemove(words)
        deletionWords = nil
      }
      Button("取消", role: .cancel) { deletionWords = nil }
    } message: { words in
      Text("将删除这 \(words.count) 个词条及其称呼。此操作无法撤销。")
    }
    .onChange(of: model.harvestItems.map(\.text)) { _, words in
      selectedHarvestWords.formIntersection(words)
    }
    .confirmationDialog(
      bulkAction?.accepting == true ? "采纳所选候选？" : "忽略全部候选？",
      isPresented: Binding(get: { bulkAction != nil }, set: { if !$0 { bulkAction = nil } }),
      titleVisibility: .visible, presenting: bulkAction
    ) { action in
      Button(action.accepting ? "采纳所选 \(action.words.count) 个" : "全部忽略 \(action.words.count)") {
        if action.accepting {
          model.harvestAcceptAll(action.words)
        } else {
          model.harvestIgnoreAll(action.words)
        }
        bulkAction = nil
      }
      Button("取消", role: .cancel) { bulkAction = nil }
    } message: { action in
      Text(
        action.accepting
          ? "将这 \(action.words.count) 个候选作为新主体加入词典。"
          : "将这 \(action.words.count) 个候选加入忽略表，之后不再出现在收纳箱。词典和会议内容保持不变。")
    }
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

  // MARK: - 常驻词典主区

  private var wordsSection: some View {
    VStack(spacing: .zero) {
      HStack(spacing: Tokens.V1.Space.xs) {
        Text("词典").font(Tokens.V1.Text.heading.font).foregroundStyle(Tokens.V1.Color.ink)
        Text("\(model.words.count) 个词，用于精转与纪要。")
          .font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
        Spacer(minLength: .zero)
      }
      .padding(.horizontal, Tokens.V1.Space.md)
      .frame(height: Tokens.V1.Size.barHeight)
      .runtimeAccessibilityIdentifier("settings.group.词典.heading")
      regionDivider
      header
      regionDivider
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .runtimeAccessibilityIdentifier("settings.dictionary.words.viewport")
    }
    .modifier(DictionaryRegionSurface())
    .runtimeAccessibilityIdentifier("settings.dictionary.words.region")
  }

  private var regionDivider: some View {
    Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
  }

  /// 选择态只替换搜索工具行，卡头与词条区都保留。
  private var header: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
      HStack(spacing: Tokens.V1.Space.xs) {
        searchTools
        Button("新词") {
          model.beginAdding()
          editorFocus = .newWord
        }
        .buttonStyle(.v1Primary)
        .accessibilityLabel("新增一个词条")
        .runtimeAccessibilityIdentifier("settings.dictionary.add")
      }
    }
    .padding(.horizontal, Tokens.V1.Space.md)
    .padding(.vertical, Tokens.V1.Space.sm)
  }

  @ViewBuilder
  private var searchTools: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.sm) {
      if !selectedVisibleWords.isEmpty {
        HStack(spacing: Tokens.V1.Space.xs) {
          harvestCheckbox(
            "全选", isSelected: selectedVisibleWords.count == model.visibleWords.count,
            isMixed: selectedVisibleWords.count < model.visibleWords.count, showsTitle: false
          ) {
            selectedWords =
              selectedVisibleWords.count == model.visibleWords.count ? [] : Set(model.visibleWords)
          }
          .runtimeAccessibilityIdentifier("settings.dictionary.select-all")
          Text("已选择 \(selectedVisibleWords.count) 个词")
            .font(Tokens.V1.Text.strong.font)
            .runtimeAccessibilityIdentifier(
              "settings.dictionary.selection-count.\(selectedVisibleWords.count)")
          Spacer(minLength: Tokens.V1.Space.xs)
          Button("删除") { deletionWords = selectedVisibleWords }
            .buttonStyle(.v1Outline)
            .foregroundStyle(Tokens.V1.Color.danger)
            .runtimeAccessibilityIdentifier("settings.dictionary.delete-selected")
        }
        .frame(minHeight: Tokens.V1.Size.controlLg)
        .runtimeAccessibilityIdentifier("settings.dictionary.selection-header")
      } else {
        HStack(spacing: Tokens.V1.Space.xs) {
          V1TextField(
            placeholder: "搜索，或直接输入新词；一个人有多种叫法写成「张三=三儿，老张」",
            text: searchQuery, identifier: "settings.dictionary.search"
          )
          .onSubmit { model.addFromSearch() }
          .help(
            "回车把没有匹配的词直接加进词典。\n"
              + "同一个人有多种叫法的，写成「本名=称呼1，称呼2」——例如 张三=三儿，老张。\n"
              + "这些叫法都会发给识别引擎，纪要一律用本名署名。"
          )
          .accessibilityLabel("搜索词条，没有匹配时回车直接添加；可用「本名=称呼」登记别名")
          if !model.query.isEmpty {
            Button {
              model.query = ""
              model.clearSearchHint()
            } label: {
              Image(systemName: "xmark.circle.fill")
                .font(Tokens.V1.Text.meta.font)
            }
            .buttonStyle(
              IconHoverButtonStyle(base: Tokens.V1.Color.ink4, hover: Tokens.V1.Color.ink2)
            )
            .accessibilityLabel("清空搜索")
          }
        }
        if let searchHint = model.searchHint {
          Text(searchHint)
            .font(Tokens.V1.Text.meta.font)
            .foregroundStyle(Tokens.V1.Color.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .runtimeAccessibilityIdentifier("settings.dictionary.search-hint")
        }
      }
    }
  }

  // MARK: - 正文:词条列表 / 两种空态

  @ViewBuilder
  private var content: some View {
    if model.isLoading && model.words.isEmpty {
      ProgressView("正在读取词典…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.words.isEmpty && !model.isAddingWord {
      emptyState(
        title: "词表还是空的",
        detail: "把客户名、产品名、同事英文名这类容易被听错的专名加进来。"
          + "文件就是 \(model.fileLabel)，直接编辑那个文件同样算数。"
      )
    } else if model.visibleWords.isEmpty && !model.isAddingWord && !model.query.isEmpty {
      emptyState(
        title: "没有匹配「\(model.query)」的词条",
        detail: "回车把它加进词典，或换个关键词、清空搜索看全部 \(model.words.count) 个词。"
      )
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: .zero) {
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
                isSelected: selectedWords.contains(word),
                isSelecting: !selectedVisibleWords.isEmpty,
                onSelect: {
                  if !selectedWords.insert(word).inserted { selectedWords.remove(word) }
                },
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
      }
    }
  }

  private func emptyState(title: String, detail: String) -> some View {
    VStack(spacing: Tokens.V1.Space.xs) {
      Text(title)
        .font(Tokens.V1.Text.heading.font)
        .foregroundStyle(Tokens.V1.Color.ink2)
      Text(detail)
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Tokens.V1.Space.md)
  }

  // MARK: - 收割箱(08-17 #4):精转后未入册专名,入册永远由用户拍板

  private var harvestSection: some View {
    VStack(spacing: .zero) {
      HStack(spacing: Tokens.V1.Space.xs) {
        Text("收割箱").font(Tokens.V1.Text.heading.font).foregroundStyle(Tokens.V1.Color.ink)
          .runtimeAccessibilityIdentifier("settings.group.收割箱.heading")
        Text("\(model.harvestItems.count) 个候选")
          .font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
        Spacer(minLength: .zero)
        Button("全部忽略") {
          bulkAction = BulkAction(accepting: false, words: model.harvestItems.map(\.text))
        }
        .buttonStyle(.v1Outline)
        .disabled(model.harvestItems.isEmpty)
        .runtimeAccessibilityIdentifier("settings.dictionary.harvest.ignore-all")
      }
      .padding(.horizontal, Tokens.V1.Space.md)
      .frame(height: Tokens.V1.Size.barHeight)
      regionDivider
      if model.harvestItems.isEmpty {
        Text("暂无待收割生词")
          .font(Tokens.V1.Text.meta.font).foregroundStyle(Tokens.V1.Color.ink3)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(Tokens.V1.Space.md)
          .runtimeAccessibilityIdentifier("settings.dictionary.harvest.empty")
      } else {
        harvestTools
        regionDivider
        ScrollView {
          LazyVStack(alignment: .leading, spacing: .zero) {
            ForEach(model.harvestItems) { item in harvestRow(item) }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .runtimeAccessibilityIdentifier("settings.dictionary.harvest.viewport")
      }
    }
    .modifier(DictionaryRegionSurface())
    .runtimeAccessibilityIdentifier("settings.dictionary.harvest.region")
    .help("纪要生成时发现的未入库专名；由你决定并入、立为新主体或忽略。")
  }

  private var harvestTools: some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      harvestCheckbox(
        "全选", isSelected: selectedCandidates.count == model.harvestItems.count,
        isMixed: !selectedCandidates.isEmpty && selectedCandidates.count < model.harvestItems.count
      ) {
        selectedHarvestWords =
          selectedCandidates.count == model.harvestItems.count
          ? [] : Set(model.harvestItems.map(\.text))
      }
      .runtimeAccessibilityIdentifier("settings.dictionary.harvest.select-all")
      Spacer(minLength: .zero)
      if !selectedCandidates.isEmpty {
        Button {
          bulkAction = BulkAction(accepting: true, words: selectedCandidates)
        } label: {
          Text("采纳所选 \(selectedCandidates.count) 个")
            .runtimeAccessibilityIdentifier(
              "settings.dictionary.harvest.selection-count.\(selectedCandidates.count)")
        }
        .accessibilityValue("\(selectedCandidates.count)")
        .buttonStyle(.v1Outline)
        .runtimeAccessibilityIdentifier("settings.dictionary.harvest.accept-selected")
      }
    }
    .padding(.horizontal, Tokens.V1.Space.md)
    .padding(.vertical, Tokens.V1.Space.sm)
  }

  private func harvestRow(_ item: HarvestBoxItem) -> some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      harvestCheckbox(
        "选择「\(item.text)」", isSelected: selectedHarvestWords.contains(item.text),
        showsTitle: false
      ) {
        if !selectedHarvestWords.insert(item.text).inserted {
          selectedHarvestWords.remove(item.text)
        }
      }
      .runtimeAccessibilityIdentifier("settings.dictionary.harvest.select.\(item.text)")
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s2xs) {
        Text(item.text)
          .font(Tokens.V1.Text.body.font)
          .foregroundStyle(Tokens.V1.Color.ink)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(item.text)
        Text("共 \(item.totalCount) 次 · \(item.meetingCount) 场")
          .font(Tokens.V1.Text.meta.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
      }
      Spacer(minLength: .zero)
      HStack(spacing: Tokens.V1.Space.s2xs) {
        Menu {
          ForEach(model.mergeTargets, id: \.self) { canonical in
            Button("并入「\(canonical)」当称呼") {
              model.harvestMerge(item.text, into: canonical)
            }
          }
        } label: {
          Text("并入词条")
            .font(Tokens.V1.Text.micro.font)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(
          V1ButtonStyle.v1Outline.height(Tokens.V1.Size.controlSm).labelFont(
            Tokens.V1.Text.meta.font)
        )
        .fixedSize()
        .layoutPriority(1)
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
        .buttonStyle(
          V1ButtonStyle.v1Outline.height(Tokens.V1.Size.controlSm).labelFont(
            Tokens.V1.Text.meta.font)
        )
        .font(Tokens.V1.Text.strong.font)
        .fixedSize()
        .help("把「\(item.text)」作为新主体加进词典")
        .accessibilityLabel("把「\(item.text)」立为新主体")
        .runtimeAccessibilityIdentifier("settings.dictionary.harvest.new")
        Button("忽略") {
          model.harvestIgnore(item.text)
        }
        .buttonStyle(
          V1ButtonStyle.v1Outline.height(Tokens.V1.Size.controlSm).labelFont(
            Tokens.V1.Text.meta.font)
        )
        .font(Tokens.V1.Text.meta.font)
        .foregroundStyle(Tokens.V1.Color.ink3)
        .fixedSize()
        .help("从收割箱移除「\(item.text)」，之后不再出现")
        .accessibilityLabel("忽略「\(item.text)」")
        .runtimeAccessibilityIdentifier("settings.dictionary.harvest.ignore")
      }
    }
    .padding(.horizontal, Tokens.V1.Space.sm)
    .padding(.vertical, Tokens.V1.Space.sm)
    .frame(minHeight: Tokens.V1.Size.controlLg + Tokens.V1.Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }
    .runtimeAccessibilityIdentifier("settings.dictionary.harvest.row.\(item.text)")
  }

  private func harvestCheckbox(
    _ title: String, isSelected: Bool, isMixed: Bool = false,
    showsTitle: Bool = true, action: @escaping () -> Void
  ) -> some View {
    DictionarySelectionCheckbox(
      title: title, isSelected: isSelected, isMixed: isMixed,
      showsTitle: showsTitle, action: action)
  }

}

// MARK: - 词条卡片

private struct DictionaryWordCard: View {
  let word: String
  let isSelected: Bool
  let isSelecting: Bool
  let onSelect: () -> Void
  let isRecentlySaved: Bool
  let isArmedForDeletion: Bool
  let onEdit: () -> Void
  let onArmDelete: () -> Void
  let onConfirmDelete: () -> Void
  let onDisarmDelete: () -> Void

  @State private var isHovering = false
  @State private var isHoveringEdit = false
  @State private var isHoveringDelete = false

  /// 卡片主体永远显示本名;称呼只报个数——一张卡片上摊开五种叫法,读的人先看到的是一堆别称。
  private var entry: DictionaryEntry? { DictionaryEntry.parse(word) }

  var body: some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      Text(entry?.canonical ?? word)
        .font(Tokens.V1.Text.body.font)
        .foregroundStyle(Tokens.V1.Color.ink)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(entry?.canonical ?? word)
        .onTapGesture(count: 2, perform: onEdit)
      if let count = entry?.appellations.count, count > 0 {
        Text("\(count)")
          .font(Tokens.V1.Text.micro.font)
          .foregroundStyle(Tokens.V1.Color.ink3)
          .help("称呼 \(count) 个，双击编辑")
          .accessibilityLabel("称呼 \(count) 个")
      }
      Spacer(minLength: .zero)
      // 用 opacity 而不是 if:悬停按钮始终在布局树里,鼠标移入不会把卡片撑变形。
      // 间距 8、字号 12(2026-07-30 用户实测:原 spacing 2 / 10.5 号太挤,分不清也易误触)。
      HStack(spacing: Tokens.V1.Space.xs) {
        Button(action: onEdit) {
          Image(systemName: "pencil")
            .foregroundStyle(isHoveringEdit ? Tokens.V1.Color.ink : Tokens.V1.Color.ink3)
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
              isHoveringDelete || isArmedForDeletion ? Tokens.V1.Color.danger : Tokens.V1.Color.ink3
            )
        }
        .help(isArmedForDeletion ? "再点一次确认删除" : "删除")
        .onHover { isHoveringDelete = $0 }
        .accessibilityLabel(isArmedForDeletion ? "确认删除「\(word)」" : "删除「\(word)」")
      }
      .buttonStyle(.plain)
      .font(Tokens.V1.Text.meta.font)
      .opacity(isHovering && !isSelecting ? 1 : 0)
      .allowsHitTesting(isHovering && !isSelecting)
      .accessibilityHidden(!isHovering || isSelecting)
      DictionarySelectionCheckbox(
        title: "选择「\(word)」", isSelected: isSelected,
        showsTitle: false, action: onSelect
      )
      .runtimeAccessibilityIdentifier("settings.dictionary.select.\(word)")
      .opacity(isHovering || isSelecting ? 1 : 0)
      .allowsHitTesting(isHovering || isSelecting)
      .accessibilityHidden(!isHovering && !isSelecting)
      .runtimeAccessibilityIdentifier(
        isHovering || isSelecting
          ? "settings.dictionary.checkbox.visible.\(word)"
          : "settings.dictionary.checkbox.hidden.\(word)")
    }
    .padding(.horizontal, Tokens.V1.Space.md)
    .frame(maxWidth: .infinity)
    .frame(height: Tokens.V1.Size.railItem.height)
    .background(
      isRecentlySaved
        ? Tokens.V1.Color.accentSoft
        : isHovering || isSelected ? Tokens.V1.Color.paper3 : Tokens.V1.Color.raised
    )
    .overlay(alignment: .bottom) {
      Rectangle().fill(Tokens.V1.Color.rule).frame(height: Tokens.V1.Size.controlRuleWidth)
    }

    .onHover { hovering in
      isHovering = hovering
      if !hovering {
        onDisarmDelete()
      }
    }
    // 双击本名编辑；勾选框与行尾按钮不参与双击识别。
    .help("双击编辑")
    .accessibilityElement(children: .contain)
    .accessibilityLabel(entry?.canonical ?? word)
    // 勾选框随悬停显示，旁白用户仍能随时进入或退出选择态。
    .accessibilityAction(named: isSelected ? "取消选择" : "选择", onSelect)
    .runtimeAccessibilityIdentifier("settings.dictionary.word.\(word)")
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
      .font(Tokens.V1.Text.body.font)
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
      .padding(.horizontal, Tokens.V1.Space.sm)
      .frame(maxWidth: .infinity)
      .frame(height: Tokens.V1.Size.control)
      .modifier(V1FormSurface(focused: focus.wrappedValue == focusValue))
      .padding(.horizontal, Tokens.V1.Space.sm)
      .padding(.vertical, Tokens.V1.Space.xs)
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
  @Published private(set) var isLoading = false
  private var reloadTask: Task<Void, Never>?
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

  /// internal:壳里的设置页要把同一个 store 交给词典分区,不另开一个。
  let store: DictionaryStore
  private let meetingStore: MeetingStore
  let harvestIgnoreStore: HarvestIgnoreStore
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
    // 首帧只安排读取；会议枚举与纪要解码不占主线程。
    reload()
  }

  var fileURL: URL { store.fileURL }

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

  func reload(flashing saved: String? = nil) {
    reloadTask?.cancel()
    isLoading = true
    let previousWords = words
    let store = store
    let meetingStore = meetingStore
    let ignoreStore = harvestIgnoreStore
    reloadTask = Task { [weak self] in
      let snapshot = await Task.detached(priority: .userInitiated) {
        var loadedWords = previousWords
        var readFailure: String?
        do { loadedWords = try store.load() } catch {
          readFailure = "读取词典文件失败：\(error.localizedDescription)"
        }
        let roster = DictionaryEntry.parseAll(loadedWords).flatMap(\.allSpokenForms)
        let ignored = (try? ignoreStore.load()) ?? []
        let candidates = meetingStore.listMeetings().compactMap { record -> [HarvestCandidate]? in
          guard let data = try? Data(contentsOf: record.paths.minutesStructured),
            let document = try? StructuredArtifactCodec.decode(
              MeetingMinutesDocument.self, from: data)
          else { return nil }
          return document.unknownProperNouns
        }
        return (
          loadedWords, readFailure,
          HarvestAggregator.aggregate(
            candidatesByMeeting: candidates, rosterForms: roster, ignored: ignored)
        )
      }.value
      // A superseded read must never replace a newer edit/reload.
      guard !Task.isCancelled, let self else { return }
      words = snapshot.0
      readErrorMessage = snapshot.1
      harvestItems = snapshot.2
      isLoading = false
      if writeErrorMessage == nil, let saved, words.contains(saved) { flash(saved) }
    }
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
    confirmRemove([word])
  }

  func confirmRemove(_ selected: [String]) {
    disarmDeletion()
    let removing = Set(selected)
    persist(words.filter { !removing.contains($0) }, flashing: nil)
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
    guard !isLoading else { return }
    do {
      try store.save(candidate)
      writeErrorMessage = nil
    } catch {
      writeErrorMessage = "写入词典文件失败：\(error.localizedDescription)"
    }
    // 成功要回读(拿到去重后的真身),失败更要回读(把界面拉回文件的真实状态)。
    // 读成功不得清写失败:否则横幅一闪即灭,用户以为存上了。
    reload(flashing: saved)
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

  /// 刷新依然读取外部编辑，但在后台完成。
  func reloadHarvest() { reload() }

  func harvestAcceptAll(_ candidates: [String]) {
    let additions = candidates.filter { existingWord(matching: $0) == nil }
    guard !additions.isEmpty else { return }
    persist(additions + words, flashing: nil)
  }

  func harvestIgnoreAll(_ candidates: [String]) {
    guard !isLoading else { return }
    do {
      try harvestIgnoreStore.ignoreAll(candidates)
      writeErrorMessage = nil
    } catch {
      writeErrorMessage = "写入收割忽略表失败：\(error.localizedDescription)"
    }
    reloadHarvest()
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
    guard !isLoading else { return }
    do {
      try harvestIgnoreStore.ignore(word)
    } catch {
      writeErrorMessage = "写入收割忽略表失败：\(error.localizedDescription)"
    }
    reloadHarvest()
  }
}

private struct DictionarySelectionCheckbox: View {
  let title: String
  let isSelected: Bool
  var isMixed = false
  var showsTitle = true
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Tokens.V1.Space.xs) {
        ZStack {
          RoundedRectangle(cornerRadius: Tokens.V1.Radius.xs)
            .fill(isSelected || isMixed ? Tokens.V1.Color.accent : Tokens.V1.Color.raised)
            .overlay {
              RoundedRectangle(cornerRadius: Tokens.V1.Radius.xs)
                .strokeBorder(
                  Tokens.V1.Color.controlRule, lineWidth: Tokens.V1.Size.controlRuleWidth)
            }
          if isSelected || isMixed {
            Image(systemName: isMixed ? "minus" : "checkmark")
              .font(.system(size: Tokens.V1.Space.sm - Tokens.V1.Space.s3xs, weight: .bold))
              .foregroundStyle(Tokens.V1.Color.accentInk)
          }
        }
        .frame(width: Tokens.V1.Size.checkBox, height: Tokens.V1.Size.checkBox)
        if showsTitle { Text(title).font(Tokens.V1.Text.meta.font) }
      }
      .foregroundStyle(Tokens.V1.Color.ink2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .accessibilityLabel(title)
    .accessibilityValue(isMixed ? "部分选中" : isSelected ? "已选中" : "未选中")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

private struct DictionaryRegionSurface: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Tokens.V1.Color.raised)
      .clipShape(RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg))
      .overlay {
        RoundedRectangle(cornerRadius: Tokens.V1.Radius.lg)
          .strokeBorder(Tokens.V1.Color.rule, lineWidth: Tokens.V1.Size.controlRuleWidth)
      }
  }
}
