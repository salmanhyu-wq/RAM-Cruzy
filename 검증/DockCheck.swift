import AppKit

@main enum DockCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "org.ramcruzy.memory-monitor.test." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(historyURL: nil, preferences: preferences)
        let delegate = MenuDelegate(model: model)
        guard let first = delegate.applicationDockMenu(app) else { fatalError("Dock 메뉴 없음") }
        precondition(first.items.map(\.title) == ["빠른 관리 열기", "쉬는 AI 메모리 비우기", "램 쥐어짜기", "자동 비우기", "관제탑 열기", "자세히 보기"])
        precondition(!first.items[1].isEnabled && first.items[3].state == .off && !model.autoRecoveryEnabled)
        let automatic = first.items[3]
        precondition(automatic.action.map { app.sendAction($0, to: automatic.target, from: automatic) } == true)
        precondition(model.autoRecoveryEnabled)
        let reread = DashboardModel(historyURL: nil, preferences: preferences)
        precondition(reread.autoRecoveryEnabled && delegate.applicationDockMenu(app)?.items[3].state == .on)
        _ = automatic.action.map { app.sendAction($0, to: automatic.target, from: automatic) }
        precondition(!model.autoRecoveryEnabled)

        let active = WorkRow(id: "running", title: "봇 1", activity: .working, control: .cancelSplash("running", 8002),
            conversationTitle: "긴 한국어 제목 앞부분", sessionIdentifier: "unique-session-a")
        let idle = WorkRow(id: "idle", title: "쉬는 모델", activity: .idle,
            control: .release(.mlxServe, "idle", 11234), bulk: true)
        model.servers = [ServerReading(id: .splash, detail: "", activity: .working, jobs: [active]),
                         ServerReading(id: .mlxServe, detail: "", activity: .idle, models: [idle])]
        precondition(delegate.applicationDockMenu(app)?.items[1].isEnabled == true)
        let prompt = model.actionPrompt(for: active)
        precondition(prompt?.title.contains("긴 한국어 제목 앞부분") == true && prompt?.button.contains("중단") == true)
        model.runningAction = true
        precondition(delegate.applicationDockMenu(app)?.items[1].isEnabled == false && model.actionPrompt(for: active) == nil)
        model.runningAction = false
        precondition(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false) == false)
        guard let panel = app.windows.first(where: { $0.title == AppIdentity.quickTitle }) else { fatalError("빠른 관리 패널 없음") }
        precondition(panel.isVisible)
        panel.close()
        precondition(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false) == false && panel.isVisible)
        precondition(model.keepInMenuBar)
        precondition(delegate.applicationShouldTerminate(app) == .terminateCancel)
        precondition(!panel.isVisible && app.activationPolicy() == .accessory)
        precondition(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false) == false)
        precondition(panel.isVisible && app.activationPolicy() == .regular)
        model.keepInMenuBar = false
        precondition(delegate.applicationShouldTerminate(app) == .terminateNow)
        precondition(!DashboardModel(historyURL: nil, preferences: preferences).keepInMenuBar)
        panel.close()
        print("Dock 종료 시 메뉴 막대 유지 기본값, 다시 열기, 끄기 및 설정 저장 검증 완료")
    }
}
