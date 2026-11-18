import AppKit
import SwiftUI

@main enum AIActivityCheck {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let gb: UInt64 = 1 << 30

    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var history = AIActivityHistory()
        for step in 0...100 {
            history.append(readings(step), at: now.addingTimeInterval(Double(step - 100) * 3))
        }
        precondition(history.samples.count == 101)
        precondition(history.samples.last?.bytes == 2 * gb)
        precondition(history.intervals.contains { $0.work.kind == .image })
        precondition(history.intervals.contains { $0.work.kind == .video })
        precondition(history.intervals.contains { $0.work.kind == .chat })
        precondition(history.ceiling > Double(40 * gb))
        precondition(history.sample(near: now.addingTimeInterval(-150)) != nil)
        let firstImage = history.intervals.first { $0.work.kind == .image }!
        precondition(firstImage.start == now.addingTimeInterval(-225) && firstImage.end == now.addingTimeInterval(-135))
        precondition(history.intervals.first { $0.work.kind == .video }?.work.title.contains("Wan2.2") == true)
        precondition(AIWorkKind.classify(WorkRow(id: "q", title: "영상을 주제로 이야기", activity: .working), provider: .splash) == .chat)
        precondition(AIWorkKind.classify(WorkRow(id: "x", title: "MLX 작업", activity: .working), provider: .mlxServe) == .other)
        precondition(AIWorkKind.classify(WorkRow(id: "x", title: "flux", detail: "이미지 모델", activity: .working), provider: .mlxServe) == .image)

        var gaps = AIActivityHistory()
        gaps.append(readings(25), at: now.addingTimeInterval(-60))
        gaps.append(readings(26), at: now)
        precondition(gaps.intervals.filter { $0.work.kind == .image }.count == 2)
        precondition(gaps.sample(near: now.addingTimeInterval(-30)) == nil)
        gaps.append(readings(100), at: now.addingTimeInterval(360))
        precondition(gaps.samples.count == 1)
        var unknown = AIActivityHistory()
        unknown.append([ServerReading(id: .splash, detail: "", activity: .offline)], at: now)
        precondition(unknown.samples[0].bytes == nil && unknown.intervals.isEmpty)
        var quiet = AIActivityHistory()
        for step in 0...100 {
            quiet.append(readings(100), at: now.addingTimeInterval(Double(step - 100) * 3))
        }
        precondition(quiet.intervals.isEmpty && Set(quiet.samples.compactMap(\.bytes)).count == 1)

        try draw(AIActivityChart(history: history), name: "activity-dark", dark: true, width: 370, directory: directory)
        try draw(AIActivityChart(history: history), name: "activity-light", dark: false, width: 370, directory: directory)
        try draw(AIActivityChart(history: quiet), name: "activity-idle", dark: true, width: 370, directory: directory)
        try draw(AIActivityChart(history: unknown), name: "activity-offline", dark: true, width: 370, directory: directory)
        let model = DashboardModel(historyURL: nil, preferences: nil)
        model.memory = memory()
        for step in 0...100 { model.sampleAIActivity(readings(step), at: now.addingTimeInterval(Double(step - 100) * 3)) }
        model.servers = readings(100)
        try draw(CompactPanel(model: model) {}, name: "popup", dark: true, width: CompactPanel.width, directory: directory)
        model.servers = readings(70)
        model.sampleAIActivity(readings(70), at: now.addingTimeInterval(3))
        try draw(CompactPanel(model: model) {}, name: "popup-busy", dark: true, width: CompactPanel.width, directory: directory)
        try draw(Dashboard(model: model), name: "full", dark: true, width: 1000, height: 760, directory: directory)
        print("AI 램 합계, 용도 분류, 실제 구간 경계, 관측 공백, 유휴·연결 끊김, 5분 보존, 밝음·어두움 화면 검증 통과")
    }

    static func readings(_ step: Int) -> [ServerReading] {
        let chatting = (5..<39).contains(step) || (55..<74).contains(step)
        let imaging = (25..<55).contains(step)
        let video = (62..<90).contains(step)
        let splash = ServerReading(id: .splash, detail: "개인 1 · 봇 3", activity: chatting ? .working : .unloaded,
            bytes: (chatting ? 22 : 2) * gb,
            models: [WorkRow(id: "model", title: "Qwen3.8-27B", activity: chatting ? .working : .unloaded)],
            jobs: chatting ? [WorkRow(id: "chat", title: "봇 1 · 예시 봇", activity: .working,
                                     observedModels: ["Qwen3.8-27B"], conversationTitle: "노래 제목과 장면 구상하기")] : [])
        var jobs: [WorkRow] = []
        if imaging { jobs.append(WorkRow(id: "image", title: "이미지 작업 · 앨범 표지", activity: .working, observedModels: ["FLUX.1-dev"])) }
        if video { jobs.append(WorkRow(id: "video", title: "영상 작업 · 뮤직비디오", activity: .working, observedModels: ["Wan2.2-S2V"])) }
        let bytes: UInt64 = video ? 18 * gb + UInt64(step % 5) * gb / 2 : imaging ? 10 * gb + UInt64(step % 7) * gb / 4 : 0
        return [splash, ServerReading(id: .comfy, detail: "이미지·영상 생성", activity: jobs.isEmpty ? .idle : .working, bytes: bytes, jobs: jobs)]
    }

    static func memory() -> MemoryReading {
        MemoryReading(total: 64 * gb, used: 41 * gb, wired: 5 * gb, compressed: 3 * gb,
                      swap: 2 * gb, swapIn: gb, swapOut: 2 * gb, pressure: 1, processes: [])
    }

    @MainActor static func draw<V: View>(_ content: V, name: String, dark: Bool, width: CGFloat,
                                         height: CGFloat? = nil, directory: URL) throws {
        let view = NSHostingView(rootView: content.padding(name.hasPrefix("activity") ? 14 : 0).background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
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
        print(name, frame.width, frame.height)
    }
}
