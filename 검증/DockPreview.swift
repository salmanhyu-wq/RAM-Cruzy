import AppKit
import SwiftUI

@main enum DockPreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = DashboardModel(historyURL: nil, preferences: nil)
        try draw(CompactPanel(model: model) {}, "01-loading", directory, width: CompactPanel.width)
        model.memory = memory(pressure: 1)
        model.servers = Provider.allCases.map { ServerReading(id: $0, detail: "", activity: .offline) }
        try draw(CompactPanel(model: model) {}, "02-empty", directory, width: CompactPanel.width)
        model.servers = fixtures()
        try draw(CompactPanel(model: model) {}, "03-working", directory, width: CompactPanel.width)
        model.autoRecoveryEnabled = true
        model.memory = memory(pressure: 4)
        try draw(CompactPanel(model: model) {}, "04-pressure-auto", directory, width: CompactPanel.width)
        model.runningAction = true
        model.notice = "자동 비우기 · 쉬는 AI 메모리를 확인하고 있어요…"
        try draw(CompactPanel(model: model) {}, "05-running", directory, width: CompactPanel.width)
        model.runningAction = false
        model.notice = "자동 비우기 · 1개 비움 · 1개 건너뜀"
        try draw(CompactPanel(model: model) {}, "06-done", directory, width: CompactPanel.width)
        model.notice = ""
        try draw(Dashboard(model: model), "07-detail-narrow", directory, width: 760, height: 560)
    }

    static func memory(pressure: Int32) -> MemoryReading {
        let gb: UInt64 = 1 << 30
        return MemoryReading(total: 64 * gb, used: 49 * gb, wired: 4 * gb, compressed: 5 * gb,
            swap: 3 * gb, swapIn: gb, swapOut: 2 * gb, pressure: pressure, processes: [])
    }

    static func fixtures() -> [ServerReading] {
        let name = "미리보기에서 긴 이름이 잘 보이는지 확인하는 예시 도우미"
        let llm = "local/Example-Chat-GGUF"
        let title = "예시 문서의 목차와 설명을 함께 검토하기 — 긴 대화 제목 앞부분…"
        return [
            ServerReading(id: .splash, detail: "요청 3개", activity: .working, bytes: 22 << 30,
                models: [WorkRow(id: "shared", title: llm, activity: .working)],
                jobs: [
                    WorkRow(id: "a", title: "봇 1 · " + name, detail: llm + " · 세션 test-splash-a",
                        activity: .working, control: .cancelSplash("a", 8002), observedModels: [llm], conversationTitle: title, sessionIdentifier: "test-splash-a"),
                    WorkRow(id: "b", title: "봇 2 · " + name, detail: llm + " · 세션 test-splash-b",
                        activity: .queued, control: .cancelSplash("b", 8002), observedModels: [llm],
                        conversationTitle: "제목이 다른 대화방 — 지역별 자료 모으기", sessionIdentifier: "test-splash-b"),
                    WorkRow(id: "c", title: "개인 1 · 예시 봇", detail: llm + " · 세션 test-splash-c",
                        activity: .working, control: .cancelSplash("c", 8002), observedModels: [llm], sessionIdentifier: "test-splash-c")
                ]),
            ServerReading(id: .comfy, detail: "작업 1개", activity: .working, bytes: 16 << 30, jobs: [
                WorkRow(id: "video", title: "강아지 영상 만들기", detail: "Wan2.2 영상 모델",
                    activity: .working, control: .cancelComfy("video", true, 8188), observedModels: ["Wan2.2"])
            ]),
            ServerReading(id: .mlxServe, detail: "쉬는 모델 2개", activity: .idle, bytes: 10 << 30, models: [
                WorkRow(id: "one", title: "LTX 영상 생성 모델", activity: .idle, bytes: 7 << 30,
                    control: .release(.mlxServe, "one", 11234), bulk: true),
                WorkRow(id: "two", title: "Qwen 대화 모델", activity: .idle, bytes: 3 << 30,
                    control: .release(.mlxServe, "two", 11234), bulk: true)
            ])
        ]
    }

    @MainActor private static func draw<V: View>(_ content: V, _ name: String, _ directory: URL,
                                                  width: CGFloat, height: CGFloat? = nil) throws {
        let view = NSHostingView(rootView: content)
        view.appearance = NSAppearance(named: .darkAqua)
        let frame = NSRect(x: 0, y: 0, width: width, height: height ?? view.fittingSize.height.rounded(.up))
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = view.appearance
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: frame) else { fatalError("렌더링 실패") }
        view.cacheDisplay(in: frame, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG 실패") }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        print(name, bitmap.pixelsWide, bitmap.pixelsHigh)
    }
}
