import SwiftUI

final class AppState: ObservableObject {
    @Published var tab = 0
    @Published var openConversationID: String?
}

@main
struct JLApp: App {
    init() {
        // 札记体：全局导航栏标题改衬线（Songti SC），返回按钮用浓墨
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont(name: "Songti SC", size: 19)
                ?? UIFont.systemFont(ofSize: 19, weight: .medium),
            .foregroundColor: UIColor(red: 0x2C/255, green: 0x26/255, blue: 0x18/255, alpha: 1),
        ]
        UINavigationBar.appearance().titleTextAttributes = attrs
        let large: [NSAttributedString.Key: Any] = [
            .font: UIFont(name: "Songti SC", size: 30)
                ?? UIFont.systemFont(ofSize: 30, weight: .bold),
            .foregroundColor: UIColor(red: 0x2C/255, green: 0x26/255, blue: 0x18/255, alpha: 1),
        ]
        UINavigationBar.appearance().largeTitleTextAttributes = large
    }
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

/// 微信 8.0.79 风格根 Tab：自定义 PNG 模板图标（生成态），选中绿/未选灰
struct RootTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView(selection: $appState.tab) {
            ChatView()
                .tabItem { WXTabIcon(name: "ic_tab_chat", title: "聊天", selected: appState.tab == 0) }
                .tag(0)
            ConversationsView()
                .tabItem { WXTabIcon(name: "ic_tab_conversations", title: "会话", selected: appState.tab == 1) }
                .tag(1)
            AccountsView()
                .tabItem { WXTabIcon(name: "ic_tab_accounts", title: "账号", selected: appState.tab == 2) }
                .tag(2)
            SettingsView()
                .tabItem { WXTabIcon(name: "ic_tab_settings", title: "设置", selected: appState.tab == 3) }
                .tag(3)
            WorkbenchView()
                .tabItem { WXTabIcon(name: "ic_tab_yaotai", title: "瑶台", selected: appState.tab == 4) }
                .tag(4)
        }
        .tint(WX.green)
    }
}
