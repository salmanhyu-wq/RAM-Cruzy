import AppKit
import SwiftUI

@main enum Probe {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let model = DashboardModel(historyURL: nil)
        await model.refresh()
        await model.refreshLibrary()
        guard let memory = model.memory, memory.used > 0, memory.total >= memory.used,
              !memory.processes.isEmpty else { fatalError("macOS 메모리 조회 실패") }
        let models = Dictionary(grouping: model.library, by: \.provider).mapValues(\.count)
        print("통합 메모리 \(ram(memory.used)) / \(ram(memory.total)) · 스왑 \(ram(memory.swap))")
        print("요약 서버", model.occupied.map { $0.id.title })
        print("보관함", models.map { "\($0.key.title) \($0.value)개" }.sorted())
        print("사용 기록", model.usage.sorted { $0.calls > $1.calls }.prefix(4).map { "\($0.provider.title) \($0.name) \($0.calls)회" })
        assert(model.occupied.allSatisfy { $0.activity != .offline })
        assert(!model.library.contains { $0.isLinked && $0.canTrash })
        try verifyCatalog()
        let before = sample(memory, writes: 120 * 1_048_576, reads: 10 * 1_048_576, occupied: 1_000 * 1_048_576, delta: -6)
        let after = sample(memory, writes: 160 * 1_048_576, reads: 20 * 1_048_576, occupied: 1_030 * 1_048_576, delta: 0)
        let cooldown = after.date.addingTimeInterval(-30)
        precondition(AutoRecovery.shouldRun(enabled: true, previous: before, current: after,
            lastAttempt: nil, hasTargets: true, busy: false))
        for options in [(false, true, false), (true, false, false), (true, true, true)] {
            precondition(!AutoRecovery.shouldRun(enabled: options.0, previous: before, current: after,
                lastAttempt: nil, hasTargets: options.1, busy: options.2))
        }
        precondition(!AutoRecovery.shouldRun(enabled: true, previous: nil, current: after,
            lastAttempt: nil, hasTargets: true, busy: false))
        precondition(!AutoRecovery.shouldRun(enabled: true, previous: before, current: after,
            lastAttempt: cooldown, hasTargets: true, busy: false))
        let far = sample(memory, writes: 190 * 1_048_576, reads: 20 * 1_048_576, occupied: 1_040 * 1_048_576, delta: 60)
        precondition(!AutoRecovery.shouldRun(enabled: true, previous: after, current: far,
            lastAttempt: nil, hasTargets: true, busy: false))
        let readOnly = sample(memory, writes: after.memory.swapOut, reads: 40 * 1_048_576,
            occupied: 1_030 * 1_048_576, delta: 6)
        precondition(!AutoRecovery.shouldRun(enabled: true, previous: after, current: readOnly,
            lastAttempt: nil, hasTargets: true, busy: false))
        print("자동 회수: 첫 측정, 읽기만, 꺼짐, 현재 진행, 관찰 공백, 반복 제한에서 차단 확인")
        var history = History()
        history.append(before, after: nil)
        history.append(after, after: before)
        assert(history.events.count == 1 && history.events[0].written == 40 * 1_048_576)
        assert(history.events[0].read == 10 * 1_048_576 && history.events[0].work == ["시험 · 영상 모델"])
        assert(history.usage.first?.observedSeconds == 6)
        history.append(sample(memory, writes: 180 * 1_048_576, reads: 20 * 1_048_576,
            occupied: 1_040 * 1_048_576, delta: 60), after: after)
        assert(history.events.count == 2 && history.events.last?.gap == true && history.events.last?.work == [])
        let data = try JSONEncoder().encode(history)
        let roundtrip = try JSONDecoder().decode(History.self, from: data)
        assert(roundtrip.events.count == 2)
        print("스왑 쓰기·읽기 증가량, 관찰 공백, 기록 보관 형식 검증")

        guard CommandLine.arguments.count == 2 else { return }
        let path = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try render(CompactPanel(model: model) {}, width: 456, height: nil, url: path.appendingPathComponent("compact.png"))
        for (screen, filename) in [(Screen.models, "tasks"), (.library, "models"), (.usage, "usage"), (.swap, "swap")] {
            model.screen = screen
            try render(Dashboard(model: model), width: 960, height: 700, url: path.appendingPathComponent(filename + ".png"))
        }
    }

    private static func verifyCatalog() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("airam-library-" + UUID().uuidString, isDirectory: true)
        let owner = root.appendingPathComponent(".mlx-serve/models/example", isDirectory: true)
        let checkpoint = owner.appendingPathComponent("Qwen-Test", isDirectory: true)
        try fm.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data([1]).write(to: owner.appendingPathComponent("standalone.safetensors"))
        let weights = checkpoint.appendingPathComponent("transformer", isDirectory: true)
        try fm.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data([1]).write(to: weights.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: checkpoint.appendingPathComponent("config.json"))
        let link = owner.appendingPathComponent("linked.gguf")
        try fm.createSymbolicLink(at: link, withDestinationURL: weights.appendingPathComponent("model.safetensors"))
        let models = ModelLibrary.scan(home: root)
        assert(models.count == 3 && !models.contains { $0.url == owner })
        assert(models.first(where: { $0.title == "Qwen-Test" })?.canTrash == true)
        assert(models.first(where: { $0.title == "linked.gguf" })?.canTrash == false)
        print("제작자 폴더·개별 모델 구분, 링크 보호 검증")
    }

    private static let start = Date.now

    private static func sample(_ live: MemoryReading, writes: UInt64, reads: UInt64, occupied: UInt64, delta: TimeInterval) -> TelemetrySample {
        let date = start.addingTimeInterval(delta)
        return TelemetrySample(date: date,
            memory: MemoryReading(total: live.total, used: live.used, wired: live.wired, compressed: live.compressed,
              swap: occupied, swapIn: reads, swapOut: writes, pressure: live.pressure, processes: live.processes),
            active: [ModelUse(provider: .mlxServe, name: "시험 모델", last: date)], work: ["시험 · 영상 모델"])
    }

    @MainActor private static func render<V: View>(_ content: V, width: Int, height: Int?, url: URL) throws {
        let view = NSHostingView(rootView: content)
        view.appearance = NSAppearance(named: .darkAqua)
        let frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height ?? Int(view.fittingSize.height.rounded(.up))))
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: frame) else { fatalError("화면 렌더링 실패") }
        view.cacheDisplay(in: frame, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("화면 PNG 변환 실패") }
        try png.write(to: url)
        print(url.lastPathComponent, bitmap.pixelsWide, "×", bitmap.pixelsHigh)
    }
}
