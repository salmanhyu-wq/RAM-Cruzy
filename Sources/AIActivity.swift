import SwiftUI

// Activity and memory are sampled together after each server refresh.
enum AIWorkKind: String, CaseIterable, Identifiable {
    case chat = "대화", image = "그림", video = "영상", audio = "소리", other = "기타"
    var id: Self { self }
    var title: String { AppLanguage.active.string(rawValue) }
    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right.fill"
        case .image: "photo.fill"
        case .video: "film.fill"
        case .audio: "waveform"
        case .other: "cpu"
        }
    }
    static func classify(_ row: WorkRow, provider: Provider) -> Self {
        if provider == .splash { return .chat }
        if let workKind = row.workKind { return workKind }
        let description = provider == .comfy ? String(row.title.prefix(6)) : row.detail
        if description.contains("영상") { return .video }
        if description.contains("이미지") { return .image }
        if description.contains("음악") || description.contains("음성") { return .audio }
        if description.contains("대화") { return .chat }
        let names = row.observedModels.isEmpty ? row.title : row.observedModels.joined(separator: " ")
        switch ModelPurpose.guess(names) {
        case .chat: return .chat
        case .image: return .image
        case .video: return .video
        case .music, .voice: return .audio
        default: return .other
        }
    }
}

struct AIActivityWork: Identifiable {
    let id: String
    let kind: AIWorkKind
    let title: String
    let activity: Activity
}

struct RAMBreakdown {
    let total: UInt64
    let system: UInt64
    let apps: UInt64
    let models: UInt64

    var used: UInt64 { system + apps + models }
    var available: UInt64 { total - used }

    init(_ memory: MemoryReading, modelBytes: UInt64) {
        total = memory.total
        let used = min(memory.used, total)
        models = min(modelBytes, used)
        // Wired memory is the system baseline estimate. Count detected model RAM first.
        system = min(memory.wired, used - models)
        apps = used - models - system
    }
}

struct AIActivitySample {
    let date: Date
    let servers: [ServerReading]
    let work: [AIActivityWork]
    let measured: [ServerReading]
    let ram: RAMBreakdown?
    let bytes: UInt64?

    init(date: Date, servers: [ServerReading], work: [AIActivityWork], memory: MemoryReading?,
         listenerPIDs: [Provider: Int32]) {
        self.date = date
        self.servers = servers
        self.work = work
        // Two provider adapters can observe the same listener. Count its RAM once.
        let readings = servers.filter { $0.activity != .offline && $0.activity != .empty && $0.activity != .unloaded &&
            $0.hasObservedRAM && $0.bytes != nil }.sorted {
            if $0.bytes != $1.bytes { return ($0.bytes ?? 0) > ($1.bytes ?? 0) }
            return $0.id.rawValue < $1.id.rawValue
        }
        var providers = Set<Provider>()
        var listeners = Set<Int32>()
        measured = readings.filter { reading in
            guard providers.insert(reading.id).inserted else { return false }
            guard let pid = listenerPIDs[reading.id] else { return true }
            return listeners.insert(pid).inserted
        }
        let modelBytes = measured.reduce(UInt64(0)) { sum, reading in
            let (total, overflow) = sum.addingReportingOverflow(reading.bytes ?? 0)
            return overflow ? UInt64.max : total
        }
        bytes = measured.isEmpty ? nil : modelBytes
        ram = memory.map { RAMBreakdown($0, modelBytes: modelBytes) }
    }
}

struct AIActivityInterval {
    let work: AIActivityWork
    var start: Date
    var end: Date
}

struct AIActivityHistory {
    static let duration: TimeInterval = 300
    static let maximumGap: TimeInterval = 18
    private(set) var samples: [AIActivitySample] = []

    mutating func append(_ servers: [ServerReading], memory: MemoryReading? = nil,
                         listenerPIDs: [Provider: Int32] = [:], at date: Date = .now) {
        let states: Set<Activity> = [.working, .queued, .loading, .stopping]
        let work = servers.filter { $0.activity != .offline }.flatMap { server -> [AIActivityWork] in
            let jobs = server.jobs.filter { states.contains($0.activity) }
            let rows = jobs.isEmpty ? server.models.filter { states.contains($0.activity) } : jobs
            return rows.map { row in
                let model = server.models.count == 1 && row.activity != .queued ? server.models[0] : nil
                var classified = row
                if !jobs.isEmpty, row.observedModels.isEmpty, server.id != .comfy, let model { classified = model }
                let kind = AIWorkKind.classify(classified, provider: server.id)
                var models = row.observedModels
                if models.isEmpty, let model { models = [model.title] }
                let names = models.isEmpty ? "" : " · " + models.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                return AIActivityWork(id: server.id.rawValue + ":" + row.id, kind: kind,
                                      title: server.id.title + " · " + row.readableTitle + names, activity: row.activity)
            }
        }
        let cutoff = date.addingTimeInterval(-Self.duration)
        samples = Array(samples.filter { $0.date >= cutoff && $0.date < date }.suffix(149))
        samples.append(AIActivitySample(date: date, servers: servers, work: work, memory: memory, listenerPIDs: listenerPIDs))
    }

    var intervals: [AIActivityInterval] {
        var completed: [AIActivityInterval] = []
        var open: [String: AIActivityInterval] = [:]
        var previous: Date?
        for sample in samples {
            if let previous, sample.date.timeIntervalSince(previous) > Self.maximumGap {
                completed += open.values
                open.removeAll()
            }
            let keys = Set(sample.work.map { $0.id + $0.kind.rawValue + $0.activity.rawValue })
            for key in Array(open.keys) where !keys.contains(key) {
                if var interval = open.removeValue(forKey: key) {
                    interval.end = sample.date
                    completed.append(interval)
                }
            }
            for work in sample.work {
                let key = work.id + work.kind.rawValue + work.activity.rawValue
                if var interval = open[key] {
                    interval.end = sample.date
                    open[key] = interval
                } else {
                    open[key] = AIActivityInterval(work: work, start: sample.date, end: sample.date)
                }
            }
            previous = sample.date
        }
        return (completed + open.values).sorted { $0.start < $1.start }
    }

    var totalRAM: UInt64 {
        samples.lazy.reversed().compactMap { $0.ram?.total }.first ?? ProcessInfo.processInfo.physicalMemory
    }

    func sample(near date: Date) -> AIActivitySample? {
        guard let closest = samples.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
              abs(closest.date.timeIntervalSince(date)) <= Self.maximumGap else { return nil }
        return closest
    }
}

@MainActor private final class AIActivityCursor: ObservableObject {
    @Published var fraction: Double?
}

@MainActor struct AIActivityChart: View {
    let history: AIActivityHistory
    var compact = false
    @StateObject private var cursor = AIActivityCursor()
    private var gutter: CGFloat { compact ? 49 : 53 }
    private var plotHeight: CGFloat { compact ? 73 : 86 }
    private var laneHeight: CGFloat { compact ? 14 : 17 }
    private var graphHeight: CGFloat { plotHeight + 17 }
    private var latest: AIActivitySample? { history.samples.last }
    private let systemColor = Color(red: 0.47, green: 0.40, blue: 0.67)
    private let appsColor = Color(red: 0.21, green: 0.51, blue: 0.79)
    private let modelsColor = Color(red: 0.12, green: 0.67, blue: 0.56)
    private let systemHelp = tr("macOS 기본 램은 고정 메모리를 바탕으로 추정해요. 로컬 모델 램은 서버가 보고한 값이나 프로세스 사용량을 바탕으로 추정해요.")

    private var start: Date { (latest?.date ?? .now).addingTimeInterval(-AIActivityHistory.duration) }
    private var selected: AIActivitySample? {
        guard let fraction = cursor.fraction else { return latest }
        return history.sample(near: start.addingTimeInterval(fraction * AIActivityHistory.duration))
    }
    private var lanes: [AIWorkKind] {
        let kinds = Set(history.samples.flatMap(\.work).map(\.kind))
        return AIWorkKind.allCases.filter { [.chat, .image, .video].contains($0) || kinds.contains($0) }
    }
    private var detail: String {
        guard let sample = selected else { return latest == nil ? tr("AI 서버의 첫 기록을 기다려요") : tr("이 구간은 기록을 모으는 중이에요") }
        if let work = sample.work.first {
            return work.title + (sample.work.count > 1 ? tr(" 외 \(sample.work.count - 1)개") : "")
        }
        return sample.servers.contains { $0.activity != .offline } ? tr("생성 작업이 쉬고 있어요") : tr("연결된 AI 서버가 없어요")
    }
    private var inspection: String {
        guard let sample = selected else { return detail }
        let memory = ramLabels(sample.ram).map(\.0) + sample.measured.map { $0.id.title + " " + ram($0.bytes) }
        return ([sample.date.formatted(date: .omitted, time: .standard)] + memory +
                sample.work.map { $0.title + " · " + $0.activity.friendlyLabel }).joined(separator: "\n")
    }

    private func ramLabels(_ reading: RAMBreakdown?) -> [(String, Color)] {
        [
            ("macOS " + ram(reading?.system), systemColor),
            (tr("기타 앱") + " " + ram(reading?.apps), appsColor),
            (tr("로컬 모델") + " " + ram(reading?.models), modelsColor)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(tr("RAM 사용량")).font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .foregroundStyle(MonitorPalette.text)
                Text(tr("남은 램") + " " + ram(selected?.ram?.available))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(MonitorPalette.secondary)
                Spacer(minLength: 0)
                Text(cursor.fraction == nil ? tr("최근 5분") : selected?.date.formatted(.dateTime.hour().minute().second().locale(AppLanguage.active.locale)) ?? tr("기록 없음"))
                    .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary).monospacedDigit()
            }
            HStack(spacing: 10) {
                ForEach(ramLabels(selected?.ram), id: \.0) { label, color in
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(label)
                    }
                }
            }
            .font(.system(size: 11)).foregroundStyle(MonitorPalette.text).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.8)
            .help(systemHelp)
            GeometryReader { geometry in
                let width = max(geometry.size.width - gutter - 8, 1)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(context: &context, size: size, width: width)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(ram(history.totalRAM)).lineLimit(1).minimumScaleFactor(0.75)
                            Spacer(minLength: 0)
                            Text("0")
                        }
                        .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary).monospacedDigit()
                        .frame(width: gutter - 4, height: plotHeight, alignment: .leading)
                        Color.clear.frame(height: graphHeight - plotHeight)
                        ForEach(lanes) { kind in
                            Text(kind.title)
                                .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary)
                                .frame(height: laneHeight)
                        }
                    }.allowsHitTesting(false)
                    HStack {
                        Text(tr("5분 전"))
                        Spacer()
                        Text(tr("지금"))
                    }
                    .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary)
                    .padding(.leading, gutter).padding(.trailing, 8).padding(.top, plotHeight)
                    .allowsHitTesting(false)
                    HStack(spacing: 0) {
                        Color.clear.frame(width: gutter).allowsHitTesting(false)
                        Color.clear.contentShape(Rectangle())
                            .frame(width: width, height: geometry.size.height)
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let point): cursor.fraction = min(1, max(0, point.x / width))
                                case .ended: cursor.fraction = nil
                                }
                            }
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                cursor.fraction = min(1, max(0, value.location.x / width))
                            })
                        Color.clear.frame(width: 8).allowsHitTesting(false)
                    }
                }
            }
            .frame(height: graphHeight + CGFloat(lanes.count) * laneHeight)
            HStack(spacing: 5) {
                Image(systemName: selected?.work.first?.kind.symbol ?? "moon.zzz")
                Text(detail).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(inspection)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("최근 5분 RAM 사용량과 로컬 AI 작업 기록"))
        .accessibilityValue(inspection)
        .accessibilityHint(systemHelp)
    }

    private func draw(context: inout GraphicsContext, size: CGSize, width: CGFloat) {
        let bottom = plotHeight - 5
        func x(_ date: Date) -> CGFloat {
            gutter + width * min(1, max(0, date.timeIntervalSince(start) / AIActivityHistory.duration))
        }
        let total = Double(max(history.totalRAM, 1))
        func y(_ bytes: UInt64) -> CGFloat { bottom - (bottom - 8) * min(1, Double(bytes) / total) }
        let grid = Path { path in
            for fraction in [0.0, 1.0 / 3, 2.0 / 3, 1.0] {
                let height = 8 + (bottom - 8) * fraction
                path.move(to: CGPoint(x: gutter, y: height))
                path.addLine(to: CGPoint(x: gutter + width, y: height))
            }
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let timeX = gutter + width * fraction
                path.move(to: CGPoint(x: timeX, y: 8))
                path.addLine(to: CGPoint(x: timeX, y: bottom))
            }
        }
        var segment: [(date: Date, ram: RAMBreakdown)] = []
        func drawSegment() {
            guard let first = segment.first else { return }
            let xPositions = segment.count == 1
                ? [max(gutter, x(first.date) - 1), min(gutter + width, x(first.date) + 1)]
                : segment.map { x($0.date) }
            let readings = segment.count == 1 ? [first.ram, first.ram] : segment.map(\.ram)
            let edges: [(RAMBreakdown) -> UInt64] = [{ _ in 0 }, { $0.system }, { $0.system + $0.apps }, { $0.used }]
            for (index, color) in [systemColor, appsColor, modelsColor].enumerated() {
                let upper = readings.map(edges[index + 1])
                let lower = readings.map(edges[index])
                let upperPoints = zip(xPositions, upper).map { CGPoint(x: $0, y: y($1)) }
                let lowerPoints = zip(xPositions, lower).map { CGPoint(x: $0, y: y($1)) }
                let area = Path { path in
                    path.addLines(upperPoints + Array(lowerPoints.reversed()))
                    path.closeSubpath()
                }
                context.fill(area, with: .color(color.opacity(0.88)))
            }
        }
        for sample in history.samples {
            if sample.ram == nil || segment.last.map({ sample.date.timeIntervalSince($0.date) > AIActivityHistory.maximumGap }) == true {
                drawSegment()
                segment.removeAll(keepingCapacity: true)
            }
            if let reading = sample.ram { segment.append((sample.date, reading)) }
        }
        drawSegment()
        context.stroke(grid, with: .color(MonitorPalette.line.opacity(0.65)), lineWidth: 0.75)
        let intervals = history.intervals
        for (index, kind) in lanes.enumerated() {
            let top = graphHeight + CGFloat(index) * laneHeight + (laneHeight - 3) / 2
            let rail = CGRect(x: gutter, y: top, width: width, height: 3)
            context.fill(Path(roundedRect: rail, cornerRadius: 1.5), with: .color(MonitorPalette.track))
            for interval in intervals where interval.work.kind == kind {
                let left = min(x(interval.start), gutter + width - 4)
                let length = max(4, x(interval.end) - left)
                let rect = CGRect(x: left, y: top, width: length, height: rail.height)
                let path = Path(roundedRect: rect, cornerRadius: 1.5)
                if interval.work.activity == .queued {
                    context.stroke(path, with: .color(MonitorPalette.accent.opacity(0.75)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                } else {
                    context.fill(path, with: .color(MonitorPalette.accent.opacity(0.85)))
                }
            }
        }
        if let sample = selected, let reading = sample.ram {
            let point = CGPoint(x: x(sample.date), y: y(reading.used))
            if cursor.fraction != nil {
                let cursor = Path { path in
                    path.move(to: CGPoint(x: point.x, y: 5))
                    path.addLine(to: CGPoint(x: point.x, y: size.height))
                }
                context.stroke(cursor, with: .color(MonitorPalette.secondary.opacity(0.65)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)),
                         with: .color(MonitorPalette.accent.opacity(0.24)))
            context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(MonitorPalette.accent))
        }
    }
}
