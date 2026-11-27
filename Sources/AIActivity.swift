import AppKit
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

enum RAMCategory: String, CaseIterable, Identifiable {
    case system, apps, models
    var id: Self { self }

    var title: String {
        switch self {
        case .system: "macOS"
        case .apps: tr("기타 앱")
        case .models: tr("로컬 모델")
        }
    }

    var symbol: String {
        switch self {
        case .system: "apple.logo"
        case .apps: "square.grid.2x2"
        case .models: "cpu"
        }
    }

    var color: Color {
        switch self {
        case .system: Color(red: 0.58, green: 0.49, blue: 0.82)
        case .apps: Color(red: 0.30, green: 0.61, blue: 0.91)
        case .models: Color(red: 0.21, green: 0.79, blue: 0.67)
        }
    }

    func bytes(in ram: RAMBreakdown?) -> UInt64? {
        switch self {
        case .system: ram?.system
        case .apps: ram?.apps
        case .models: ram?.models
        }
    }
}

struct RAMProcessRow: Identifiable {
    let id: String
    let title: String
    let iconPath: String?
    var bytes: UInt64

    static func rows(_ processes: [ProcessMemory]) -> [Self] {
        var grouped: [String: Self] = [:]
        for process in processes {
            let app = process.ramAppPath
            let key = process.ramListKey
            let title = process.isVirtualMachine ? tr("가상 머신") :
                app.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? process.title
            if grouped[key] == nil {
                grouped[key] = Self(id: key, title: title, iconPath: app, bytes: 0)
            }
            grouped[key]?.bytes += process.bytes
        }
        return grouped.values.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.id < $1.id
        }
    }
}

extension ProcessMemory {
    var ramListKey: String { ramAppPath ?? appID ?? "pid-\(id)" }

    var ramAppPath: String? {
        guard let path = executablePath, let boundary = path.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return String(path[..<boundary.upperBound].dropLast())
    }

    var isSplashProcess: Bool {
        if appID == "ai.inco.splash" { return true }
        guard let app = ramAppPath?.lowercased() else { return false }
        return app.hasSuffix("/splash.app") || app.hasSuffix("/splash 한국어.app")
    }

    var isVirtualMachine: Bool {
        executablePath?.hasSuffix("/com.apple.Virtualization.VirtualMachine") == true
    }

    var isMacSystemProcess: Bool {
        guard let path = executablePath, !isVirtualMachine else { return false }
        return (path.hasPrefix("/System/") && !path.hasPrefix("/System/Applications/")) ||
            path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/sbin/")
    }
}

struct RAMBreakdown {
    let total: UInt64
    let system: UInt64
    let apps: UInt64
    let models: UInt64

    var used: UInt64 { system + apps + models }
    var available: UInt64 { total - used }

    init(_ memory: MemoryReading, modelBytes: UInt64, observedAppBytes: UInt64,
         activeSplashBytes: UInt64 = 0, idleWiredBaseline: UInt64? = nil) {
        total = memory.total
        let used = min(memory.used, total)
        let wired = min(memory.wired, used)
        // Splash allocations can already be represented in wired memory, including during loading.
        let remainingWired = wired - min(wired, activeSplashBytes)
        let startupBaseline = remainingWired == 0 ? wired : 0
        let minimumSystem = min(wired, idleWiredBaseline ?? startupBaseline)
        system = max(remainingWired, minimumSystem)
        let budget = used - system
        let modelEstimate = min(modelBytes, budget)
        // Process footprints can overlap the system counters, for example when
        // unified memory is wired. Keep both observed categories in the budget.
        if observedAppBytes > budget - modelEstimate {
            let combined = Double(modelEstimate) + Double(observedAppBytes)
            models = min(modelEstimate, UInt64(Double(budget) * Double(modelEstimate) / combined))
        } else {
            models = modelEstimate
        }
        apps = budget - models
    }
}

struct AIActivitySample {
    let date: Date
    let servers: [ServerReading]
    let work: [AIActivityWork]
    let measured: [ServerReading]
    let appRows: [RAMProcessRow]
    let systemRows: [RAMProcessRow]
    let ram: RAMBreakdown?
    let bytes: UInt64?

    init(date: Date, servers: [ServerReading], work: [AIActivityWork], memory: MemoryReading?,
         listenerPIDs: [Provider: Int32], additionalModelPIDs: Set<Int32>,
         activeSplashBytes: UInt64, idleWiredBaseline: UInt64?) {
        self.date = date
        self.servers = servers
        self.work = work

        let processes = memory?.processes ?? []
        let splashProcesses = processes.filter(\.isSplashProcess)
        let splashBytes = splashProcesses.reduce(0) { $0 + $1.bytes }
        let sawSplashEngine = splashProcesses.contains { $0.executablePath?.hasSuffix("/splash") == true }
        var readings: [ServerReading] = []
        for var reading in servers {
            if reading.id == .splash, splashBytes > 0 {
                reading.bytes = sawSplashEngine ? splashBytes : max(splashBytes, reading.bytes ?? 0)
            } else if reading.activity == .offline || (reading.id != .splash &&
                      (reading.activity == .empty || reading.activity == .unloaded)) {
                continue
            }
            if reading.hasObservedRAM, let size = reading.bytes, size > 0 { readings.append(reading) }
        }
        readings.sort {
            if $0.bytes != $1.bytes { return ($0.bytes ?? 0) > ($1.bytes ?? 0) }
            return $0.id.rawValue < $1.id.rawValue
        }
        var providers = Set<Provider>()
        var modelPIDs = additionalModelPIDs.union(splashProcesses.map(\.id))
        measured = readings.filter { reading in
            guard providers.insert(reading.id).inserted else { return false }
            guard let pid = listenerPIDs[reading.id] else { return true }
            return modelPIDs.insert(pid).inserted
        }

        let models = measured.reduce(UInt64(0)) { sum, reading in
            let (total, overflow) = sum.addingReportingOverflow(reading.bytes ?? 0)
            return overflow ? UInt64.max : total
        }
        let otherProcesses = processes.filter { !modelPIDs.contains($0.id) }
        let appProcesses = otherProcesses.filter { !$0.isMacSystemProcess }
        appRows = RAMProcessRow.rows(appProcesses)
        systemRows = RAMProcessRow.rows(otherProcesses.filter(\.isMacSystemProcess))
        let appBytes = appProcesses.reduce(0) { $0 + $1.bytes }
        bytes = measured.isEmpty ? nil : models
        ram = memory.map {
            RAMBreakdown($0, modelBytes: models, observedAppBytes: appBytes,
                         activeSplashBytes: activeSplashBytes, idleWiredBaseline: idleWiredBaseline)
        }
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
    private var idleWiredBaseline: UInt64?

    mutating func append(_ servers: [ServerReading], memory: MemoryReading? = nil,
                         listenerPIDs: [Provider: Int32] = [:], additionalModelPIDs: Set<Int32> = [], at date: Date = .now) {
        let states: Set<Activity> = [.working, .queued, .loading, .stopping]
        let work = servers.filter { $0.activity != .offline }.flatMap { server -> [AIActivityWork] in
            let jobs = server.jobs.filter { states.contains($0.activity) }
            var rows = jobs.isEmpty ? server.models.filter { states.contains($0.activity) } : jobs
            // A server can report activity before the detailed jobs become visible.
            // An active job also explains a server-level loading/stopping state.
            if states.contains(server.activity),
               !rows.contains(where: { $0.activity == server.activity || $0.activity == .working }) {
                let model = server.models.count == 1 ? server.models[0] : nil
                rows.append(WorkRow(id: "server-activity", title: tr("서버 작업"),
                                    detail: model?.detail ?? "", activity: server.activity,
                                    observedModels: model.map { [$0.title] } ?? []))
            }
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
        let splash = servers.first { $0.id == .splash }
        let splashResident = splash?.gpuModels?.contains { $0.resident } == true
        let splashActive = splashResident || [.loading, .working, .stopping].contains(splash?.activity ?? .offline)
        if let memory, !splashActive,
           [.offline, .empty, .unloaded].contains(splash?.activity ?? .offline) {
            idleWiredBaseline = min(idleWiredBaseline ?? memory.wired, memory.wired)
        }
        samples.append(AIActivitySample(date: date, servers: servers, work: work, memory: memory,
                                        listenerPIDs: listenerPIDs, additionalModelPIDs: additionalModelPIDs,
                                        activeSplashBytes: splashActive ? splash?.bytes ?? 0 : 0,
                                        idleWiredBaseline: idleWiredBaseline))
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

    func currentActivity(_ kind: AIWorkKind) -> Activity? {
        guard let latest = samples.last else { return nil }
        let work = latest.work.filter { $0.kind == kind }
        if let active = [Activity.working, .loading, .stopping, .queued].first(where: { state in
            work.contains { $0.activity == state }
        }) { return active }
        let resident = latest.servers.contains { server in
            guard !server.paused, [.idle, .unknown].contains(server.activity) else { return false }
            return server.models.contains { model in
                guard model.id != "comfy-cache", AIWorkKind.classify(model, provider: server.id) == kind else { return false }
                if let gpuModels = server.gpuModels {
                    return gpuModels.contains { $0.resident && ($0.id == model.id || $0.title == model.title) }
                }
                return model.activity == .idle
            }
        }
        return resident ? .idle : nil
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
    @Published var expandedCategory: RAMCategory?
}

@MainActor struct AIActivityChart: View {
    let history: AIActivityHistory
    var compact = false
    var openStatistics: (() -> Void)?
    var appQuitPrompt: ((RAMProcessRow) -> Confirmation?)?
    var modelReleasePrompt: ((ServerReading) -> Confirmation?)?
    var confirm: ((Confirmation) -> Void)?
    @StateObject private var cursor = AIActivityCursor()
    private let gutter: CGFloat = 31
    private let plotTrailing: CGFloat = 4
    private var plotHeight: CGFloat { compact ? 99 : 112 }
    private var laneHeight: CGFloat { compact ? 14 : 17 }
    private var graphHeight: CGFloat { plotHeight + 17 }
    private var latest: AIActivitySample? { history.samples.last }
    private let systemHelp = tr("macOS는 고정 메모리에서 로컬 모델과 겹치는 부분을 조정해 추정해요. 로컬 모델에는 모델 서버와 대화 캐시도 포함해요.")

    private var start: Date { (latest?.date ?? .now).addingTimeInterval(-AIActivityHistory.duration) }
    private var selected: AIActivitySample? {
        guard let fraction = cursor.fraction else { return latest }
        return history.sample(near: start.addingTimeInterval(fraction * AIActivityHistory.duration))
    }
    private var lanes: [AIWorkKind] {
        let kinds = Set(history.samples.flatMap(\.work).map(\.kind))
        return AIWorkKind.allCases.filter { [.chat, .image, .video].contains($0) || kinds.contains($0) }
    }
    private func laneColor(_ activity: Activity?) -> Color {
        switch activity {
        case .working: MonitorPalette.accent
        case .loading, .queued, .stopping: MonitorPalette.availableRAM
        case .idle: Color.cyan
        default: MonitorPalette.secondary
        }
    }

    private func laneStatus(_ activity: Activity, kind: AIWorkKind) -> String {
        if activity == .working && kind == .chat { return tr("응답 생성 중") }
        if activity == .idle { return tr("모델이 램에서 대기 중") }
        return activity.friendlyLabel
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
        let totals = [tr("RAM 사용량") + " " + ram(sample.ram?.used),
                      tr("남은 램") + " " + ram(sample.ram?.available)]
        let categories = RAMCategory.allCases.map { $0.title + " " + ram($0.bytes(in: sample.ram)) }
        let memory = totals + categories + sample.measured.map { $0.id.title + " " + ram($0.bytes) }
        let live = lanes.compactMap { kind -> String? in
            history.currentActivity(kind).map { kind.title + " · " + laneStatus($0, kind: kind) }
        }
        return ([sample.date.formatted(date: .omitted, time: .standard)] + memory + live +
                sample.work.map { $0.title + " · " + $0.activity.friendlyLabel }).joined(separator: "\n")
    }

    private func categoryButton(_ category: RAMCategory) -> some View {
        let expanded = cursor.expandedCategory == category
        return Button {
            cursor.fraction = nil
            cursor.expandedCategory = expanded ? nil : category
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: category.symbol)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(category.color)
                    Text(category.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .semibold)).foregroundStyle(MonitorPalette.secondary)
                }
                Text(ram(category.bytes(in: selected?.ram)))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(category.color)
            }
            .foregroundStyle(MonitorPalette.text)
            .lineLimit(1).minimumScaleFactor(0.78)
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MonitorPalette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(expanded ? category.color : MonitorPalette.line) }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
        .accessibilityValue(ram(category.bytes(in: selected?.ram)))
        .accessibilityHint(expanded ? tr("세부 목록 접기") : tr("세부 목록 펼치기"))
    }

    private func categoryDetails(_ category: RAMCategory) -> some View {
        let sample = selected
        let rows = category == .system ? sample?.systemRows ?? [] : sample?.appRows ?? []
        let servers = sample?.measured ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(category.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                xButton(tr("세부 목록 닫기")) { cursor.expandedCategory = nil }
            }
            Text(category == .system ? tr("고정 메모리 기준 · 주요 시스템 프로세스") :
                 tr("측정한 항목별 사용량 · 그래프 합계와 다를 수 있어요"))
                .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if category == .models ? servers.isEmpty : rows.isEmpty {
                Text(tr("확인된 항목이 없어요."))
                    .font(.callout).foregroundStyle(MonitorPalette.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if category == .models {
                            ForEach(servers) { server in
                                detailRow(title: server.id.title,
                                          detail: server.id == .splash ? tr("LLM · 대화 캐시와 서버 포함") :
                                              server.models.first?.readableTitle,
                                          bytes: server.bytes, actionTitle: tr("램에서 내리기"),
                                          prompt: cursor.fraction == nil ? modelReleasePrompt?(server) : nil) {
                                    ProviderIcon(provider: server.id, size: 16)
                                }
                            }
                        } else {
                            ForEach(rows) { row in
                                detailRow(title: row.title, detail: nil, bytes: row.bytes,
                                          actionTitle: tr("\(row.title) 종료"),
                                          prompt: category == .apps && cursor.fraction == nil ? appQuitPrompt?(row) : nil) {
                                    if let path = row.iconPath {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                            .resizable().scaledToFit()
                                    } else {
                                        Image(systemName: category == .system ? "gearshape" : "app")
                                            .font(.system(size: 12)).foregroundStyle(category.color)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(height: min(154, CGFloat(category == .models ? servers.count : rows.count) * 34))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorPalette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(MonitorPalette.line) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(category.title)
    }

    private func xButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MonitorPalette.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).help(title)
    }

    private func detailRow<Icon: View>(title: String, detail: String?, bytes: UInt64?,
                                       actionTitle: String, prompt: Confirmation?,
                                       @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 7) {
            icon().frame(width: 16, height: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MonitorPalette.text)
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(MonitorPalette.secondary)
                }
            }
            .lineLimit(1).help(title)
            Spacer(minLength: 2)
            Text(ram(bytes)).font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(MonitorPalette.secondary)
            if let prompt, let confirm {
                xButton(actionTitle) { confirm(prompt) }
            }
        }
        .frame(height: 33)
        .accessibilityElement(children: .contain)
        .overlay(alignment: .bottom) { Rectangle().fill(MonitorPalette.line.opacity(0.6)).frame(height: 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(tr("RAM 사용량")).font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .foregroundStyle(MonitorPalette.text)
                Spacer(minLength: 0)
                if let openStatistics {
                    Button(action: openStatistics) {
                        Image(systemName: "chart.bar.xaxis").foregroundStyle(MonitorPalette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("사용 기록 열기"))
                    .help(tr("일간·주간·월간 사용 기록 열기"))
                }
                Text(cursor.fraction == nil ? tr("최근 5분") : selected?.date.formatted(.dateTime.hour().minute().second().locale(AppLanguage.active.locale)) ?? tr("기록 없음"))
                    .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ram(selected?.ram?.used))
                    .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(MonitorPalette.accent)
                Text(tr("남은 램") + " " + ram(selected?.ram?.available))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(MonitorPalette.availableRAM)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 5) {
                ForEach(RAMCategory.allCases) { category in
                    categoryButton(category)
                }
            }
            GeometryReader { geometry in
                let width = max(geometry.size.width - gutter - plotTrailing, 1)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(context: &context, size: size, width: width)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(String(history.totalRAM / 1_073_741_824)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text("0")
                        }
                        .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary).monospacedDigit()
                        .frame(width: gutter - 4, height: plotHeight, alignment: .leading)
                        Color.clear.frame(height: graphHeight - plotHeight)
                        ForEach(lanes) { kind in
                            let activity = history.currentActivity(kind)
                            Text(kind.title)
                                .font(.system(size: 11, weight: activity == .working ? .semibold : .regular))
                                .foregroundStyle(laneColor(activity))
                                .frame(width: gutter - 2, height: laneHeight, alignment: .leading)
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                    }.allowsHitTesting(false)
                    HStack {
                        Text(tr("5분 전"))
                        Spacer()
                        Text(tr("지금"))
                    }
                    .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary)
                    .padding(.leading, gutter).padding(.trailing, plotTrailing).padding(.top, plotHeight)
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
                            .gesture(DragGesture(minimumDistance: 5)
                                .onChanged { value in
                                    cursor.fraction = min(1, max(0, value.location.x / width))
                                }
                                .onEnded { _ in cursor.fraction = nil })
                            .onTapGesture {
                                cursor.fraction = nil
                                openStatistics?()
                            }
                        Color.clear.frame(width: plotTrailing).allowsHitTesting(false)
                    }
                }
            }
            .frame(height: graphHeight + CGFloat(lanes.count) * laneHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("최근 5분 RAM 사용량과 로컬 AI 작업 기록"))
            .accessibilityValue(inspection)
            .accessibilityHint(openStatistics == nil ? systemHelp : tr("눌러서 사용 기록 열기"))
            .accessibilityAction(named: Text(tr("사용 기록 열기"))) { openStatistics?() }
            if let expanded = cursor.expandedCategory {
                categoryDetails(expanded)
            }
            HStack(spacing: 5) {
                Image(systemName: selected?.work.first?.kind.symbol ?? "moon.zzz")
                Text(detail).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(inspection)
        }
        .accessibilityElement(children: .contain)
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
            for (index, category) in RAMCategory.allCases.enumerated() {
                let upper = readings.map(edges[index + 1])
                let lower = readings.map(edges[index])
                let upperPoints = zip(xPositions, upper).map { CGPoint(x: $0, y: y($1)) }
                let lowerPoints = zip(xPositions, lower).map { CGPoint(x: $0, y: y($1)) }
                let area = Path { path in
                    path.addLines(upperPoints + Array(lowerPoints.reversed()))
                    path.closeSubpath()
                }
                context.fill(area, with: .color(category.color.opacity(0.80)))
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
                let color = laneColor(interval.work.activity)
                if interval.work.activity == .queued {
                    context.stroke(path, with: .color(color.opacity(0.75)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                } else {
                    context.fill(path, with: .color(color.opacity(0.85)))
                }
            }
            if let current = history.currentActivity(kind) {
                let marker = Path(ellipseIn: CGRect(x: rail.maxX - 6, y: rail.midY - 3, width: 6, height: 6))
                if current == .idle {
                    context.stroke(marker, with: .color(laneColor(current)), lineWidth: 1.25)
                } else {
                    context.fill(marker, with: .color(laneColor(current)))
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
