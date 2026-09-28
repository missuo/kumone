import SwiftUI

/// Debug-only switch lets UI tests exercise the iOS 15 navigation on newer runtimes.
enum NavigationCompatibility {
    static var usesLegacyNavigation: Bool {
        #if DEBUG && os(iOS)
        ProcessInfo.processInfo.arguments.contains("--test-legacy-navigation")
        #else
        false
        #endif
    }
}

/// Keeps the same destination array for modern navigation and iOS 15 push/pop.
struct AppNavigationStack<Content: View>: View {
    private let externalPath: Binding<[Destination]>?
    private let content: Content
    @State private var localPath: [Destination] = []

    init(path: Binding<[Destination]>? = nil, @ViewBuilder content: () -> Content) {
        externalPath = path
        self.content = content()
    }

    private var path: Binding<[Destination]> { externalPath ?? $localPath }

    var body: some View {
        if #available(iOS 16.0, *), !NavigationCompatibility.usesLegacyNavigation {
            NavigationStack(path: path) { content }
        } else {
            NavigationView {
                content.background(LegacyDestinationPush(path: path, depth: 0))
            }
            #if os(iOS)
            .navigationViewStyle(.stack)
            #endif
            .environment(\.openDestination, { destination in
                var next = path.wrappedValue
                next.appendIfNotCurrent(destination)
                path.wrappedValue = next
            })
        }
    }
}

/// Each visible page owns the link to the next page. System back/swipe truncates
/// the shared path, so tab reselection and programmatic routes stay in sync.
private struct LegacyDestinationPush: View {
    @Binding var path: [Destination]
    let depth: Int

    private var isActive: Binding<Bool> {
        Binding(get: { path.count > depth }, set: { active in
            if !active, path.count > depth { path.removeSubrange(depth...) }
        })
    }

    var body: some View {
        NavigationLink(isActive: isActive) {
            if path.indices.contains(depth) {
                // Type erasure bounds the recursive SwiftUI generic type.
                AnyView(DestinationPage(destination: path[depth])
                    .background(LegacyDestinationPush(path: $path, depth: depth + 1)))
            }
        } label: {
            EmptyView()
        }
        .hidden()
        .accessibilityHidden(true)
    }
}

struct AppDestinationLink<Label: View>: View {
    let value: Destination
    let label: Label
    @Environment(\.openDestination) private var openDestination

    init(value: Destination, @ViewBuilder label: () -> Label) {
        self.value = value
        self.label = label()
    }

    var body: some View {
        if #available(iOS 16.0, *), !NavigationCompatibility.usesLegacyNavigation {
            NavigationLink(value: value) { label }
                .accessibilityIdentifier("destination.\(String(describing: value))")
        } else {
            Button { openDestination(value) } label: { label }
                .accessibilityIdentifier("destination.\(String(describing: value))")
        }
    }
}

struct MainColumnFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct AppWindowColumns<Sidebar: View, Detail: View>: View {
    let sidebar: Sidebar
    let detail: Detail
    @State private var showsSidebar = false

    init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        if #available(iOS 16.0, *), !NavigationCompatibility.usesLegacyNavigation {
            ModernWindowColumns(sidebar: sidebar, detail: detail)
        } else {
            // Keep the detail navigation stack alive through rotation and Split View.
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    if proxy.size.width >= 700 {
                        sidebar.frame(width: 220)
                        Divider()
                    }
                    detail
                        .toolbar {
                            if proxy.size.width < 700 {
                                ToolbarItem(placement: .navigation) {
                                    Button { showsSidebar = true } label: {
                                        Image(systemName: "sidebar.left")
                                    }
                                    .accessibilityLabel("侧边栏")
                                }
                            }
                        }
                        .sheet(isPresented: $showsSidebar) {
                            NavigationView {
                                sidebar.toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("完成") { showsSidebar = false }
                                    }
                                }
                            }
                            #if os(iOS)
                            .navigationViewStyle(.stack)
                            #endif
                        }
                }
            }
        }
    }
}

@available(iOS 16.0, *)
private struct ModernWindowColumns<Sidebar: View, Detail: View>: View {
    let sidebar: Sidebar
    let detail: Detail
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar.navigationSplitViewColumnWidth(min: 200, ideal: Theme.Layout.sidebarWidth, max: 280)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
    }
}


extension View {
    @ViewBuilder
    func observeMainColumnFrame(_ update: @escaping (CGRect) -> Void) -> some View {
        if #available(iOS 16.0, *) {
            onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("mainWindow"))
            } action: { frame in
                update(frame)
            }
        } else {
            background(GeometryReader { proxy in
                Color.clear.preference(
                    key: MainColumnFrameKey.self,
                    value: proxy.frame(in: .named("mainWindow"))
                )
            })
            .onPreferenceChange(MainColumnFrameKey.self, perform: update)
        }
    }
}
