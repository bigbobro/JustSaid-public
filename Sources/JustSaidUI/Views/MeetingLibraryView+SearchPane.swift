import AppKit
import JustSaidCore
import SwiftUI
import UniformTypeIdentifiers

// 2026-08-20 批3 拆分:自 MeetingLibraryView.swift 按 MARK 边界机械迁出,零行为变更。
extension MeetingLibraryView {
  // MARK: - 全库搜索(08-17 #1「谁说过 X」)

  /// 单场命中折叠阈值:超过先给前 50 条 + 「还有 N 条」,防极端词一次挂上千行。
  private static let searchGroupFoldLimit = 50

  var normalizedLibrarySearchQuery: String {
    model.librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 全库搜索行:放大镜聚焦钮(⌘⇧F)+ 输入框 + 「N 场 · M 条」计数 + 扫描中指示。
  /// Esc 在框内按下即清空并失焦,列表回满库。检索只读,零写入任何会议包文件。
  var librarySearchRow: some View {
    HStack(spacing: Tokens.V1.Space.xs) {
      Button {
        isLibrarySearchFocused = true
      } label: {
        Image(systemName: "magnifyingglass")
          .font(.system(size: Tokens.V1.Text.meta.size, weight: .semibold))
      }
      .buttonStyle(.iconHover)
      .keyboardShortcut("f", modifiers: [.command, .shift])
      .help("全库搜索(⌘⇧F)：搜全部会议转写里的原话")
      .accessibilityLabel("聚焦全库搜索")
      .runtimeAccessibilityIdentifier("library.search.focus")
      TextField("搜全部会议的原话", text: $model.librarySearchQuery)
        .textFieldStyle(.plain)
        .font(.system(size: Tokens.V1.Text.label.size))
        .focused($isLibrarySearchFocused)
        .onKeyPress(.escape) {
          clearLibrarySearch()
          return .handled
        }
        .runtimeAccessibilityIdentifier("library.search.field")
      if model.isLibrarySearching {
        BreathingDots()
          .runtimeAccessibilityIdentifier("library.search.scanning")
      }
      if !normalizedLibrarySearchQuery.isEmpty {
        Text("\(filteredSearchResults.count) 场 · \(filteredSearchResults.reduce(0) { $0 + visibleSearchHits($1).count }) 条")
          .font(.system(size: Tokens.V1.Text.meta.size, weight: .semibold))
          .foregroundStyle(Tokens.V1.Color.ink3)
          .fixedSize(horizontal: true, vertical: false)
          .runtimeAccessibilityIdentifier("library.search.count")
        Button {
          clearLibrarySearch()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: Tokens.V1.Text.micro.size, weight: .bold))
        }
        .buttonStyle(.iconHover)
        .accessibilityLabel("清空全库搜索")
        .runtimeAccessibilityIdentifier("library.search.clear")
      }
    }
    .padding(.horizontal, Tokens.V1.Space.sm)
    .padding(.vertical, Tokens.V1.Space.xs)
    .background(
      Tokens.V1.Color.paper2,
      in: RoundedRectangle(cornerRadius: Tokens.V1.Radius.md)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Tokens.V1.Radius.md)
        .stroke(
          isLibrarySearchFocused ? Tokens.V1.Color.accent : Tokens.V1.Color.rule,
          lineWidth: Tokens.V1.Size.controlRuleWidth
        )
    )
    .padding(.horizontal, Tokens.V1.Space.md)
    .padding(.vertical, Tokens.V1.Space.sm)
  }

  private func clearLibrarySearch() {
    isLibrarySearchFocused = false
    model.librarySearchQuery = ""
  }

  /// 结果区:说话人 chip(R4)+ 按会议分组的命中。lazy 容器不加容器级
  /// `.textSelection`(长文档纪律);滚动位置不记忆、不逐帧写回。
  var librarySearchResultsList: some View {
    VStack(alignment: .leading, spacing: .zero) {
      librarySearchSpeakerChips
      ScrollView {
        LazyVStack(alignment: .leading, spacing: .zero) {
          if model.librarySearchResults.isEmpty, !model.isLibrarySearching {
            Text("全部会议的转写里都没有「\(normalizedLibrarySearchQuery)」。")
              .font(.system(size: textScale.size(Tokens.V1.Text.body.size)))
              .foregroundStyle(Tokens.V1.Color.ink3)
              .fixedSize(horizontal: false, vertical: true)
              .padding(Tokens.V1.Space.md)
              .runtimeAccessibilityIdentifier("library.search.empty")
          }
          ForEach(filteredSearchResults, id: \.meetingID) { result in
            librarySearchGroup(result)
          }
        }
      }
    }
  }

  private var filteredSearchResults: [LibrarySearchResult] {
    let ids = Set(model.queueFilteredMeetings.map(\.id))
    return model.librarySearchResults.filter { ids.contains($0.meetingID)
      && (searchMeetingFilter == nil || searchMeetingFilter == $0.meetingID) }
  }

  /// 当前结果里出现过的显示名,按首次出现顺序——与转写页看到的名字同一结算口径。
  private var librarySearchSpeakers: [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for result in model.librarySearchResults {
      for hit in result.hits where seen.insert(hit.speaker).inserted {
        ordered.append(hit.speaker)
      }
    }
    return ordered
  }

  /// 说话人 chip 过滤(R4,纯呈现):选中 = 只显示该人命中;单说话人时不占版面。
  @ViewBuilder
  private var librarySearchSpeakerChips: some View {
    let speakers = librarySearchSpeakers
    if speakers.count > 1 {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Tokens.V1.Space.xs) {
          ForEach(speakers, id: \.self) { speaker in
            let isActive = librarySearchSpeakerFilter == speaker
            Button {
              librarySearchSpeakerFilter = isActive ? nil : speaker
            } label: {
              Text(speaker)
                .font(.system(size: Tokens.V1.Text.meta.size, weight: .semibold))
                .foregroundStyle(isActive ? Tokens.V1.Color.accent : Tokens.V1.Color.ink2)
                .lineLimit(1)
                .padding(.horizontal, Tokens.V1.Space.xs)
                .padding(.vertical, Tokens.V1.Space.s2xs)
                .background(
                  Capsule().fill(isActive ? Tokens.V1.Color.accentSoft : Tokens.V1.Color.paper2)
                )
                .overlay(
                  Capsule().stroke(
                    isActive ? Tokens.V1.Color.controlRule : Tokens.V1.Color.rule,
                    lineWidth: Tokens.V1.Size.controlRuleWidth
                  )
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .hoverStrokeOutline(cornerRadius: Tokens.V1.Radius.pill)
            .help(isActive ? "取消只看「\(speaker)」的命中" : "只看「\(speaker)」的命中")
            .runtimeAccessibilityIdentifier(
              isActive ? "library.search.speaker-chip.active" : "library.search.speaker-chip"
            )
          }
        }
        .padding(.horizontal, Tokens.V1.Space.md)
      }
      .padding(.bottom, Tokens.V1.Space.xs)
    }
  }

  /// chip 过滤后该场仍可见的命中;未开 chip 即全量。
  private func visibleSearchHits(_ result: LibrarySearchResult) -> [LibrarySearchHit] {
    guard let filter = librarySearchSpeakerFilter else { return result.hits }
    return result.hits.filter { $0.speaker == filter }
  }

  /// 一场会议的结果组:标题 + 日期 + 该场命中数,组内命中行按行序;
  /// 超过折叠阈值给「还有 N 条」点开全量。
  @ViewBuilder
  private func librarySearchGroup(_ result: LibrarySearchResult) -> some View {
    let hits = visibleSearchHits(result)
    if !hits.isEmpty,
      let item = model.meetings.first(where: { $0.id == result.meetingID })
    {
      VStack(alignment: .leading, spacing: .zero) {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.V1.Space.xs) {
          Text(item.title)
            .font(.system(size: Tokens.V1.Text.label.size, weight: .semibold))
            .foregroundStyle(Tokens.V1.Color.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(item.title)
          Spacer(minLength: Tokens.V1.Space.s2xs)
          Button("只看这场") { searchMeetingFilter = result.meetingID }
            .buttonStyle(.v1Quiet)
            .runtimeAccessibilityIdentifier("library.search.only-meeting")
          Text("\(item.compactStartedLabel) · \(hits.count) 条")
            .font(.system(size: Tokens.V1.Text.meta.size))
            .foregroundStyle(Tokens.V1.Color.ink4)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, Tokens.V1.Space.md)
        .padding(.top, Tokens.V1.Space.sm)
        .padding(.bottom, Tokens.V1.Space.s2xs)
        .runtimeAccessibilityIdentifier("library.search.group")
        let isExpanded = expandedSearchGroups.contains(result.meetingID)
        let shownHits = isExpanded ? hits : Array(hits.prefix(Self.searchGroupFoldLimit))
        ForEach(shownHits, id: \.lineIndex) { hit in
          librarySearchHitRow(hit, in: result)
        }
        if !isExpanded, hits.count > Self.searchGroupFoldLimit {
          Button("还有 \(hits.count - Self.searchGroupFoldLimit) 条") {
            expandedSearchGroups.insert(result.meetingID)
          }
          .buttonStyle(.textAction)
          .font(.system(size: Tokens.V1.Text.meta.size, weight: .semibold))
          .foregroundStyle(Tokens.V1.Color.accent)
          .padding(.horizontal, Tokens.V1.Space.md)
          .padding(.vertical, Tokens.V1.Space.s2xs)
          .runtimeAccessibilityIdentifier("library.search.more")
        }
        Divider()
          .padding(.top, Tokens.V1.Space.s2xs)
      }
    }
  }

  /// 一条命中行:时间戳 · 说话人 · 片段(命中词加亮)。点击直落该会议转写对应位置
  /// (走既有 select + 切页签 + TranscriptJumpRequest 通道,B4 面包屑自然生效)。
  private func librarySearchHitRow(
    _ hit: LibrarySearchHit,
    in result: LibrarySearchResult
  ) -> some View {
    Button {
      focusedMeetingTitleID = nil
      focusedPane = .detail
      model.openLibrarySearchHit(meetingID: result.meetingID, hit: hit)
      if let item = model.selectedItem { openMeetingPage(item, resetTab: false) }
    } label: {
      VStack(alignment: .leading, spacing: Tokens.V1.Space.s3xs) {
        HStack(spacing: Tokens.V1.Space.xs) {
          Text(hit.timestamp)
            .font(.system(size: Tokens.V1.Text.micro.size, design: .monospaced))
            .foregroundStyle(Tokens.V1.Color.ink4)
          Text(hit.speaker)
            .font(.system(size: Tokens.V1.Text.meta.size, weight: .semibold))
            .foregroundStyle(Tokens.V1.Color.ink3)
            .lineLimit(1)
        }
        librarySearchSnippet(hit.text)
          .font(.system(size: textScale.size(Tokens.V1.Text.body.size)))
          .foregroundStyle(Tokens.V1.Color.ink2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, Tokens.V1.Space.md)
      .padding(.vertical, Tokens.V1.Space.s2xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverRowBackground(cornerRadius: Tokens.V1.Radius.sm)
    .help("跳到这场会议的转写对应位置")
    .accessibilityLabel("\(hit.timestamp) \(hit.speaker) 的发言，点击定位到转写")
    .runtimeAccessibilityIdentifier("library.search.hit")
  }

  /// 命中片段:关键词前后各约 30 字符,行首行尾截断加 …;命中词 acDeep 加亮。
  /// 纯呈现截断,原文一字不改;整行匹配不到(理论不可达)时原样显示全行。
  private func librarySearchSnippet(_ text: String) -> Text {
    let query = normalizedLibrarySearchQuery
    guard
      !query.isEmpty,
      let match = text.range(of: query, options: [.caseInsensitive])
    else {
      return Text(text)
    }
    let radius = 30
    let start =
      text.index(match.lowerBound, offsetBy: -radius, limitedBy: text.startIndex)
      ?? text.startIndex
    let end =
      text.index(match.upperBound, offsetBy: radius, limitedBy: text.endIndex)
      ?? text.endIndex
    let leading = (start > text.startIndex ? "…" : "") + text[start..<match.lowerBound]
    let trailing = String(text[match.upperBound..<end]) + (end < text.endIndex ? "…" : "")
    return Text(leading)
      + Text(String(text[match]))
      .foregroundStyle(Tokens.V1.Color.accent)
      .fontWeight(.semibold)
      + Text(trailing)
  }
}
