import AppKit
import Carbon
import Combine
import SwiftUI

enum AppIdentity {
    static let name = tr("로컬 램 크루지_EX")
    static let quickTitle = name + tr(" · 빠른 관리")
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.5.0"
}

@MainActor private final class MenuPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

@MainActor final class MenuDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: DashboardModel
    private var status: NSStatusItem?
    private var menuPanel: MenuPanel?
    private var menuAnchor: NSRect?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var quickWindow: NSPanel?
    private var window: NSWindow?
    private var polling: Task<Void, Never>?
    private var panelUpdates: AnyCancellable?
    private var interfaceUpdateScheduled = false
    private var displayedPressure: Int32?
    private var alertPulse: Task<Void, Never>?
    private var alertVisible = false
    private var allowQuit = false

    init(model: DashboardModel) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installAppMenu()
        if model.keepInMenuBar, CommandLine.arguments.contains("--background") {
            NSApp.setActivationPolicy(.accessory)
        }
        let item = NSStatusBar.system.statusItem(withLength: MenuPressureIcon.size.width + 8)
        item.autosaveName = "memory.monitor"
        status = item
        if let button = item.button {
            button.target = self
            button.action = #selector(toggleMenuPanel)
            if #available(macOS 27.0, *) {
                item.expandedInterfaceDelegate = self
            }
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            updateStatusItem(force: true)
        }

        panelUpdates = model.objectWillChange.sink { [weak self] _ in self?.scheduleInterfaceUpdate() }
        polling = Task { await model.poll() }
        if CommandLine.arguments.contains("--hub") {
            showHub()
        } else if CommandLine.arguments.contains("--window") {
            showDetails()
        } else if !CommandLine.arguments.contains("--background") {
            showQuickWindow()
        }
    }

    private func scheduleInterfaceUpdate() {
        guard !interfaceUpdateScheduled else { return }
        interfaceUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.interfaceUpdateScheduled = false
            self.updateStatusItem()
            if self.menuPanel?.isVisible == true { self.sizeMenuPanel() }
            if let quickWindow = self.quickWindow, quickWindow.isVisible { self.sizeQuickWindow(quickWindow) }
        }
    }

    private func updateStatusItem(force: Bool = false) {
        guard let status, let button = status.button else { return }
        let hasAlert = !model.serverProblems.isEmpty
        let wasAlerting = alertPulse != nil
        if hasAlert && !wasAlerting {
            alertVisible = true
            alertPulse = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(850))
                    guard !Task.isCancelled, let self else { return }
                    self.alertVisible = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !self.alertVisible
                    self.updateStatusItem(force: true)
                }
            }
        } else if !hasAlert && wasAlerting {
            alertPulse?.cancel()
            alertPulse = nil
            alertVisible = false
        }
        let pressure = model.displayPressure
        guard force || pressure != displayedPressure || hasAlert != wasAlerting else { return }
        displayedPressure = pressure
        let label = AppIdentity.name + " · " + memoryStatusText(pressure) +
            (hasAlert ? tr(" · 확인할 서버 있음") : "")
        button.image = MenuPressureIcon.image(pressure, alert: alertVisible)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showQuickWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        let systemQuit = reason.map { [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut].contains($0) } ?? false
        guard model.keepInMenuBar, !allowQuit, !systemQuit else { return .terminateNow }
        closeMenuPanel()
        hideQuickWindow()
        window?.orderOut(nil)
        sender.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    @objc private func quitCompletely() {
        allowQuit = true
        NSApp.terminate(nil)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(tr("빠른 관리 열기"), action: #selector(showQuickWindow)))
        let release = item(tr("쉬는 AI 메모리 비우기"), action: #selector(releaseFromDock))
        release.isEnabled = !model.bulkTargets.isEmpty && !model.runningAction
        menu.addItem(release)
        let boost = item(model.boostRunning ? tr("GPU 상한 원복") : tr("램 쥐어짜기"), action: #selector(showBoost))
        boost.isEnabled = model.boostRunning || !model.runningAction
        menu.addItem(boost)
        let automatic = item(tr("자동 비우기"), action: #selector(toggleAutomaticRecovery))
        automatic.state = model.autoRecoveryEnabled ? .on : .off
        menu.addItem(automatic)
        menu.addItem(item(tr("관제탑 열기"), action: #selector(showHub)))
        menu.addItem(item(tr("자세히 보기"), action: #selector(showDetails)))
        return menu
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === quickWindow || closing === window else { return }
        if closing === quickWindow { resetPrompt(in: closing.contentViewController) }
        if model.keepInMenuBar, [quickWindow, window].compactMap({ $0 }).allSatisfy({ $0 === closing || !$0.isVisible }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? MenuPanel, panel === menuPanel else { return }
        Task { @MainActor [weak self, weak panel] in
            guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
            self?.closeMenuPanel()
        }
    }

    private func resetPrompt(in controller: NSViewController?) {
        (controller as? NSHostingController<CompactPanel>)?.rootView.resetPrompt()
    }

    private func closeMenuPanel() {
        if #available(macOS 27.0, *) {
            status?.expandedInterfaceSession?.cancel()
        }
        dismissMenuPanel()
    }

    private func dismissMenuPanel() {
        for monitor in [outsideClickMonitor, localClickMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitor = nil
        localClickMonitor = nil
        let notifications = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { notifications.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let panel = menuPanel, panel.isVisible {
            resetPrompt(in: panel.contentViewController)
            panel.orderOut(nil)
        }
        menuAnchor = nil
    }

    private func hideQuickWindow() {
        resetPrompt(in: quickWindow?.contentViewController)
        quickWindow?.orderOut(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        polling?.cancel()
        alertPulse?.cancel()
        model.flushHistory()
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    private func installAppMenu() {
        let main = NSMenu()
        let app = NSMenuItem()
        let commands = NSMenu(title: AppIdentity.name)
        commands.addItem(item(tr("\(AppIdentity.name) 정보"), action: #selector(showAbout)))
        commands.addItem(.separator())
        commands.addItem(item(tr("빠른 관리 열기"), action: #selector(showQuickWindow)))
        commands.addItem(item(tr("관제탑 열기"), action: #selector(showHub)))
        commands.addItem(item(tr("자세히 보기"), action: #selector(showDetails)))
        let settings = item(tr("설정…"), action: #selector(showSettings))
        settings.keyEquivalent = ","
        commands.addItem(settings)
        commands.addItem(.separator())
        commands.addItem(withTitle: tr("\(AppIdentity.name) 닫기"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        commands.addItem(item(tr("완전히 종료"), action: #selector(quitCompletely)))
        app.title = AppIdentity.name
        app.submenu = commands
        main.addItem(app)
        let windows = NSMenu(title: tr("창"))
        windows.addItem(withTitle: tr("창 닫기"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowMenu = NSMenuItem()
        windowMenu.submenu = windows
        main.addItem(windowMenu)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }

    private func makeQuickContent(close: @escaping () -> Void, resize: @escaping () -> Void) -> NSHostingController<CompactPanel> {
        let compact = NSHostingController(rootView: CompactPanel(model: model, close: close, resize: resize,
            openSettings: { [weak self] in self?.showSettings() },
            openBoost: { [weak self] in self?.showBoost() }, open: { [weak self] in self?.showOverview() }))
        compact.sizingOptions = [.preferredContentSize]
        return compact
    }

    @objc private func toggleMenuPanel() {
        if #available(macOS 27.0, *), status?.expandedInterfaceSession != nil { return }
        if menuPanel?.isVisible == true {
            closeMenuPanel()
        } else if let button = status?.button {
            showMenuPanel(for: button)
        }
    }

    private func showMenuPanel(for button: NSStatusBarButton) {
        guard menuPanel?.isVisible != true else { return }
        hideQuickWindow()
        let panel = menuPanel ?? MenuPanel(contentRect: .init(x: 0, y: 0, width: CompactPanel.width, height: 320),
                                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        menuPanel = panel
        panel.delegate = self
        panel.title = AppIdentity.quickTitle
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.dismiss = { [weak self] in self?.closeMenuPanel() }
        let content = makeQuickContent(close: { [weak self] in self?.closeMenuPanel() },
                                       resize: { [weak self] in self?.sizeMenuPanel() })
        panel.contentViewController = content
        content.view.wantsLayer = true
        content.view.layer?.cornerRadius = 16
        content.view.layer?.masksToBounds = true
        menuAnchor = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        sizeMenuPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
        monitorMenuDismissal()
        Task { await model.refresh() }
    }

    private func sizeMenuPanel() {
        guard let panel = menuPanel, let content = panel.contentViewController as? NSHostingController<CompactPanel>,
              let screen = NSScreen.screens.first(where: { screen in
                  menuAnchor.map { screen.frame.intersects($0) } ?? false
              }) ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 6)
        let top = min(bounds.maxY, (menuAnchor?.minY ?? bounds.maxY) - 4)
        let maximumHeight = top - bounds.minY
        content.rootView.setMaximumHeight(maximumHeight)
        content.view.layoutSubtreeIfNeeded()
        let width = min(CompactPanel.width, bounds.width)
        let height = min(content.view.fittingSize.height, maximumHeight)
        guard height > 0 else { return }
        let left = min(max(bounds.minX, (menuAnchor?.midX ?? bounds.midX) - width / 2), bounds.maxX - width)
        let frame = NSRect(x: left, y: top - height, width: width, height: height)
        if panel.frame.integral != frame.integral { panel.setFrame(frame, display: true) }
    }

    private func monitorMenuDismissal() {
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] _ in
            Task { @MainActor in self?.menuClickedOutside() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            if let self, event.window !== self.menuPanel { self.menuClickedOutside() }
            return event
        }
        let notifications = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification]
            .map { name in
                notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closeMenuPanel() }
                }
            }
    }

    private func menuClickedOutside() {
        let point = NSEvent.mouseLocation
        guard menuAnchor?.contains(point) != true, menuPanel?.frame.contains(point) != true else { return }
        closeMenuPanel()
    }

    @objc private func showQuickWindow() {
        closeMenuPanel()
        NSApp.setActivationPolicy(.regular)
        let panel: NSPanel
        if let quickWindow {
            panel = quickWindow
        } else {
            panel = NSPanel()
            panel.delegate = self
            panel.title = AppIdentity.quickTitle
            panel.styleMask = [.titled, .closable]
            styleWindow(panel)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            quickWindow = panel
        }
        if !panel.isVisible {
            resetPrompt(in: panel.contentViewController)
            panel.contentViewController = makeQuickContent(close: { [weak self] in
                self?.quickWindow?.close()
            }, resize: { [weak self] in
                guard let self, let quickWindow = self.quickWindow else { return }
                self.sizeQuickWindow(quickWindow)
            })
        }
        sizeQuickWindow(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        Task { await model.refresh() }
    }

    private func sizeQuickWindow(_ window: NSPanel) {
        guard let content = window.contentViewController as? NSHostingController<CompactPanel> else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame
        let maximumHeight = screen.map { window.contentRect(forFrameRect: $0.insetBy(dx: 0, dy: 6)).height } ?? 720
        content.rootView.setMaximumHeight(maximumHeight)
        content.view.layoutSubtreeIfNeeded()
        let height = min(content.view.fittingSize.height, maximumHeight)
        guard height > 0 else { return }
        let size = NSSize(width: CompactPanel.width, height: height)
        let nextFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let current = window.frame
        let point: NSPoint
        if window.isVisible, let screen {
            point = NSPoint(x: min(max(current.minX, screen.minX), max(screen.minX, screen.maxX - nextFrame.width)),
                            y: min(max(current.maxY - nextFrame.height, screen.minY), max(screen.minY, screen.maxY - nextFrame.height)))
        } else if let screen {
            let y = max(screen.minY, min(screen.minY + 22, screen.maxY - nextFrame.height))
            point = NSPoint(x: screen.midX - nextFrame.width / 2, y: y)
        } else {
            point = current.origin
        }
        let frame = NSRect(origin: point, size: nextFrame.size)
        if window.frame.integral != frame.integral { window.setFrame(frame, display: true) }
    }

    @objc private func toggleAutomaticRecovery() {
        model.autoRecoveryEnabled.toggle()
    }

    @objc private func releaseFromDock() {
        showQuickWindow()
        model.releaseIdle()
    }

    @objc private func showBoost() {
        if model.boostRunning { model.stopGPUBoost(); return }
        guard !model.runningAction else { return }
        showOverview()
        model.boostPlanShown = true
    }

    private func showOverview() {
        model.screen = .models
        showDetails()
    }

    @objc private func showHub() {
        model.screen = .hub
        showDetails()
    }

    @objc private func showSettings() {
        model.screen = .settings
        showDetails()
    }

    @objc private func showAbout() {
        model.screen = .about
        showDetails()
    }

    @objc private func showDetails() {
        closeMenuPanel()
        hideQuickWindow()
        NSApp.setActivationPolicy(.regular)
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: Dashboard(model: model))
        let window = NSWindow(contentViewController: host)
        self.window = window
        window.delegate = self
        window.title = AppIdentity.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        styleWindow(window)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.setContentSize(NSSize(width: 960, height: 700))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func styleWindow(_ window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = MonitorPalette.windowBackground
        window.titlebarAppearsTransparent = true
    }
}

@available(macOS 27.0, *)
extension MenuDelegate: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        if let button = statusItem.button {
            showMenuPanel(for: button)
        } else {
            session.cancel()
        }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        dismissMenuPanel()
    }
}

enum MenuPressureIcon {
    static let size = NSSize(width: 24, height: 24)
    private static let mark = Bundle.main.url(forResource: "MenuChip", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:)) ?? NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)

    static func tint(_ pressure: Int32?) -> NSColor {
        switch pressure {
        case 1: .systemGreen
        case 2: .systemOrange
        case 4: .systemRed
        default: .systemGray
        }
    }

    static func image(_ pressure: Int32?, alert: Bool = false) -> NSImage {
        let drawing = NSImage(size: size, flipped: false) { bounds in
            let disk = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            let base = tint(pressure).usingColorSpace(.sRGB) ?? tint(pressure)
            let background = base.blended(withFraction: 0.39, of: .black) ?? base
            background.setFill()
            disk.fill()
            NSColor.white.withAlphaComponent(0.34).setStroke()
            disk.lineWidth = 0.65
            disk.stroke()

            if let mark, mark.size.width > 0 {
                let width: CGFloat = 18
                let height = width * mark.size.height / mark.size.width
                mark.draw(in: NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                     width: width, height: height))
            }
            if alert {
                let dot = NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 9, y: bounds.maxY - 9, width: 8, height: 8))
                NSColor.systemOrange.setFill()
                dot.fill()
                NSColor.white.setStroke()
                dot.lineWidth = 0.8
                dot.stroke()
            }
            return true
        }
        var bounds = NSRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)
        guard let pixels = drawing.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else { return drawing }
        return NSImage(cgImage: pixels, size: size)
    }
}

extension ServerReading {
    var hasObservedRAM: Bool {
        // MLX Studio's model endpoint lists gateway entries, which need not be loaded.
        id != .mlxStudio || (bytes ?? 0) > 0
    }

    var statusModelNames: [String] {
        guard id != .mlxStudio else { return [] }
        let using = jobs.filter { [.working, .loading, .stopping].contains($0.activity) }
        let loaded = models.filter { [.working, .idle, .unknown, .loading, .queued].contains($0.activity) && $0.id != "comfy-cache" }
        let queued = jobs.filter { $0.activity == .queued }
        let names = using.flatMap(\.observedModels) + loaded.map(\.title) + queued.flatMap(\.observedModels)
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

#if !AIRAM_TESTING
@main enum MemoryMenu {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = MenuDelegate(model: DashboardModel())
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
