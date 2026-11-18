import SwiftUI

// Activity and memory are sampled together after each server refresh.
enum AIWorkKind: String, CaseIterable, Identifiable {
    case chat = "대화", image = "그림", video = "영상", audio = "소리", other = "기타"
    var id: Self { self }
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

struct AIActivitySample {
    let date: Date
    let servers: [ServerReading]
    let work: [AIActivityWork]
    var measured: [ServerReading] { servers.filter { $0.activity != .offline && $0.hasObservedRAM && $0.bytes != nil } }
    var bytes: UInt64? { measured.isEmpty ? nil : measured.reduce(0) { $0 + ($1.bytes ?? 0) } }
    var sources: Set<Provider> { Set(measured.map(\.id)) }
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

    mutating func append(_ servers: [ServerReading], at date: Date = .now) {
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
        samples.append(AIActivitySample(date: date, servers: servers, work: work))
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

    var ceiling: Double {
        let peak = Double(samples.compactMap(\.bytes).max() ?? 0)
        let gigabyte = Double(UInt64(1) << 30)
        return max(gigabyte, pow(2, ceil(log2(max(peak * 1.15 / gigabyte, 1)))) * gigabyte)
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
    private var gutter: CGFloat { compact ? 43 : 48 }
    private var plotHeight: CGFloat { compact ? 73 : 86 }
    private var laneHeight: CGFloat { compact ? 14 : 17 }
    private var graphHeight: CGFloat { plotHeight + 17 }
    private var latest: AIActivitySample? { history.samples.last }
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
        guard let sample = selected else { return latest == nil ? "AI 서버의 첫 기록을 기다려요" : "이 구간은 기록을 모으는 중이에요" }
        if let work = sample.work.first {
            return work.title + (sample.work.count > 1 ? " 외 \(sample.work.count - 1)개" : "")
        }
        return sample.servers.contains { $0.activity != .offline } ? "생성 작업이 쉬고 있어요" : "연결된 AI 서버가 없어요"
    }
    private var inspection: String {
        guard let sample = selected else { return detail }
        let memory = sample.measured.map { $0.id.title + " " + ram($0.bytes) }
        return ([sample.date.formatted(date: .omitted, time: .standard)] + memory +
                sample.work.map { $0.title + " · " + $0.activity.friendlyLabel }).joined(separator: "\n")
    }

    var body: some View {
        let titleLayout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 1)) :
            AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 7))
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 7) {
                titleLayout {
                    Text("로컬 AI 램").font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .foregroundStyle(MonitorPalette.text)
                    Text(ram(selected?.bytes)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(MonitorPalette.accent)
                }
                Spacer(minLength: 0)
                Text(cursor.fraction == nil ? "최근 5분" : selected?.date.formatted(date: .omitted, time: .standard) ?? "기록 없음")
                    .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary).monospacedDigit()
            }
            .help("연결된 AI 서버가 보고한 램과 확인된 서버 프로세스의 램을 합쳐요. 마우스를 올리면 서버별 수치와 작업을 볼 수 있어요.")
            GeometryReader { geometry in
                let width = max(geometry.size.width - gutter - 8, 1)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(context: &context, size: size, width: width)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(ram(UInt64(history.ceiling))).lineLimit(1).minimumScaleFactor(0.75)
                            Spacer(minLength: 0)
                            Text("0")
                        }
                        .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary).monospacedDigit()
                        .frame(width: gutter - 4, height: plotHeight, alignment: .leading)
                        Color.clear.frame(height: graphHeight - plotHeight)
                        ForEach(lanes) { kind in
                            Text(kind.rawValue)
                                .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary)
                                .frame(height: laneHeight)
                        }
                    }.allowsHitTesting(false)
                    HStack {
                        Text("5분 전")
                        Spacer()
                        Text("지금")
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
        .accessibilityLabel("최근 5분 로컬 AI 램과 대화·그림·영상 작업 기록")
        .accessibilityValue(ram(selected?.bytes) + ". " + detail)
    }

    private func draw(context: inout GraphicsContext, size: CGSize, width: CGFloat) {
        let bottom = plotHeight - 5
        func x(_ date: Date) -> CGFloat {
            gutter + width * min(1, max(0, date.timeIntervalSince(start) / AIActivityHistory.duration))
        }
        func y(_ bytes: UInt64) -> CGFloat { bottom - (bottom - 8) * min(1, Double(bytes) / history.ceiling) }
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
        context.stroke(grid, with: .color(MonitorPalette.line.opacity(0.85)), lineWidth: 0.75)
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
        var segment: [CGPoint] = []
        var previous: AIActivitySample?
        func drawSegment() {
            guard let first = segment.first, let last = segment.last else { return }
            var line = Path()
            line.addLines(segment)
            var area = line
            area.addLine(to: CGPoint(x: last.x, y: bottom))
            area.addLine(to: CGPoint(x: first.x, y: bottom))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [MonitorPalette.accent.opacity(0.17), MonitorPalette.accent.opacity(0.015)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: bottom)))
            context.stroke(line, with: .color(MonitorPalette.accent), style: StrokeStyle(lineWidth: 1.85, lineCap: .round, lineJoin: .round))
        }
        for sample in history.samples {
            if let previous, sample.date.timeIntervalSince(previous.date) > AIActivityHistory.maximumGap || sample.sources != previous.sources {
                drawSegment()
                segment.removeAll(keepingCapacity: true)
            }
            if let bytes = sample.bytes { segment.append(CGPoint(x: x(sample.date), y: y(bytes))) }
            previous = sample
        }
        drawSegment()
        if let sample = selected, let bytes = sample.bytes {
            let point = CGPoint(x: x(sample.date), y: y(bytes))
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
