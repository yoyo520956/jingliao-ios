import SwiftUI

final class AppState: ObservableObject {
    @Published var tab = 0
    @Published var openConversationID: String?
}

@main
struct JLApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var accounts = DSAccountStore.shared
    @StateObject private var chats = ChatStore.shared
    @StateObject private var server = LocalAPIServer.shared
    @StateObject private var logs = EngineLog.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState)
                .environmentObject(accounts)
                .environmentObject(chats)
                .environmentObject(server)
                .environmentObject(logs)
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView(selection: $appState.tab) {
            ChatView()
                .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }
                .tag(0)
            ConversationsView()
                .tabItem { Label("会话", systemImage: "list.bullet") }
                .tag(1)
            AccountsView()
                .tabItem { Label("账号", systemImage: "person.2") }
                .tag(2)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
    }
}
