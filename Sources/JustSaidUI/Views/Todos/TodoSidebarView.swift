import SwiftUI

struct TodoSidebarView: View {
  @ObservedObject var model: TodoPageModel

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.V1.Space.md) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          V1SecondaryPanelHeader(title: "智能视图", titleIdentifier: "todos.sidebar.heading") {
            Button {
              model.sidebarVisible = false
            } label: {
              Image(systemName: "sidebar.left")
            }
            .buttonStyle(.v1Icon.height(Tokens.V1.Size.controlSm))
            .help("收起侧栏").accessibilityLabel("收起侧栏")
            .runtimeAccessibilityIdentifier("todos.sidebar.toggle")
          }
          ForEach(TodoScope.allCases) { scope in
            navigation(
              scope.title, symbol: symbol(scope), count: model.count(in: scope),
              selected: !model.isSearching && !model.isShowingRecycleBin && model.selectedClient == nil && model.scope == scope
            ) {
              model.chooseScope(scope)
            }
            .runtimeAccessibilityIdentifier("todos.scope.\(scope.rawValue)")
          }
          HStack {
            Text("客户").font(Tokens.V1.Text.micro.font).foregroundStyle(Tokens.V1.Color.ink3)
            Spacer()
            if model.selectedClient != nil {
              Button("全部") { model.chooseClient(nil) }
                .buttonStyle(.v1Quiet.height(Tokens.V1.Size.controlSm))
                .runtimeAccessibilityIdentifier("todos.client.clear")
            }
          }
          .padding(.horizontal, Tokens.V1.Space.sm)
          .padding(.top, Tokens.V1.Space.md)
          .padding(.bottom, Tokens.V1.Space.s2xs)
          ForEach(model.clients, id: \.self) { client in
            VStack(alignment: .leading, spacing: 0) {
              HStack(spacing: 0) {
                Button {
                  if !model.expandedClients.insert(client).inserted {
                    model.expandedClients.remove(client)
                  }
                } label: {
                  Image(
                    systemName: model.expandedClients.contains(client)
                      ? "chevron.down" : "chevron.right"
                  )
                  .font(Tokens.V1.Text.micro.font)
                }
                .buttonStyle(.v1Icon.height(Tokens.V1.Size.controlSm))
                .accessibilityLabel("展开或收起\(client)")
                .runtimeAccessibilityIdentifier("todos.client.expand.\(client)")
                navigation(
                  client, symbol: nil, count: model.clientCount(client),
                  selected: !model.isSearching && model.selectedClient == client
                    && model.selectedProject == nil
                ) {
                  model.chooseClient(client)
                }
                .runtimeAccessibilityIdentifier("todos.client.\(client)")
              }
              .modifier(
                V1SecondaryPanelRowSurface(
                  selected: !model.isSearching && model.selectedClient == client
                    && model.selectedProject == nil))
              if model.expandedClients.contains(client) {
                ForEach(model.projects(for: client), id: \.self) { project in
                  navigation(
                    project, symbol: nil, count: model.clientCount(client, project: project),
                    selected: !model.isSearching && model.selectedClient == client
                      && model.selectedProject == project
                  ) {
                    model.chooseClient(client, project: project)
                  }
                  .padding(.leading, Tokens.V1.Size.control)
                  .runtimeAccessibilityIdentifier("todos.project.\(client).\(project)")
                }
              }
            }
          }
        }
      }
      Spacer(minLength: 0)
      if !model.removedItems.isEmpty {
        navigation(
          "回收箱", symbol: "trash", count: model.removedItems.count,
          selected: model.isShowingRecycleBin
        ) { model.showRemoved() }
        .runtimeAccessibilityIdentifier("todos.trash")
      }
    }
    .padding(.horizontal, Tokens.V1.Space.sm)
    .padding(.bottom, Tokens.V1.Space.md)
    .modifier(V1SecondaryPanelSurface())
    .runtimeAccessibilityIdentifier("todos.sidebar")
  }

  private func navigation(
    _ title: String, symbol: String?, count: Int, selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: Tokens.V1.Space.xs) {
        if let symbol { Image(systemName: symbol).frame(width: Tokens.V1.Size.railIcon) }
        Text(title).lineLimit(1)
        Spacer(minLength: Tokens.V1.Space.s2xs)
        Text("\(count)").monospacedDigit().font(Tokens.V1.Text.micro.font)
      }
    }
    .buttonStyle(V1SecondaryPanelRowStyle(selected: selected))
    .accessibilityLabel("\(title)，\(count) 条")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  private func symbol(_ scope: TodoScope) -> String {
    switch scope {
    case .open: "line.3.horizontal"
    case .pending: "questionmark.circle"
    case .today: "clock"
    case .overdue: "exclamationmark.circle"
    case .pinned: "pin"
    case .done: "checkmark.circle"
    }
  }
}
