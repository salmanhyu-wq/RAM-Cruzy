import AppKit
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case hub = "관제탑"
    case models = "지금 쓰는 램", library = "저장한 모델", usage = "최근 사용", swap = "스왑 기록"
    case processes = "프로그램별 램", settings = "설정", about = "앱 정보"
    var title: String { AppLanguage.active.string(rawValue) }

    var icon: String {
        switch self {
        case .hub: "point.3.connected.trianglepath.dotted"
        case .models: "waveform.path.ecg"
        case .library: "shippingbox"
        case .usage: "chart.bar.xaxis"
        case .swap: "arrow.left.arrow.right"
        case .processes: "square.grid.2x2"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
    var id: Self { self }
}

struct MemoryTrendPoint {
    let date: Date
    let fraction: Double
}

struct MemoryTrend: View {
    static let duration: TimeInterval = 60
    let samples: [MemoryTrendPoint]
    let color: Color
    var showGrid = false
    var fillArea = false

    var body: some View {
        Canvas { context, size in
            if showGrid {
                for level in [0.2, 0.5, 0.8] {
                    let y = (size.height - 2) * level + 1
                    let line = Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(line, with: .color(.primary.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
            guard let latest = samples.last else { return }
            let start = latest.date.addingTimeInterval(-Self.duration)
            var line = Path()
            var area = Path()
            var segment: [CGPoint] = []
            var previous: Date?
            var endpoint = CGPoint.zero
            func closeSegment() {
                guard let first = segment.first, let last = segment.last, segment.count > 1 else { return }
                area.move(to: CGPoint(x: first.x, y: size.height))
                for point in segment { area.addLine(to: point) }
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.closeSubpath()
            }
            for sample in samples where sample.date >= start {
                let x = (size.width - 4) * min(1, sample.date.timeIntervalSince(start) / Self.duration) + 2
                let y = (size.height - 4) * (1 - sample.fraction) + 2
                endpoint = CGPoint(x: x, y: y)
                if let previous, sample.date.timeIntervalSince(previous) <= 18 {
                    line.addLine(to: endpoint)
                } else {
                    line.move(to: endpoint)
                    if fillArea { closeSegment() }
                    segment.removeAll(keepingCapacity: true)
                }
                if fillArea { segment.append(endpoint) }
                previous = sample.date
            }
            if fillArea {
                closeSegment()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.38), color.opacity(0.05)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
                ))
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: endpoint.x - 2, y: endpoint.y - 2, width: 4, height: 4)), with: .color(color))
        }
        .accessibilityLabel(samples.isEmpty ? tr("램 사용 추이 측정 중") : tr("최근 1분 램 사용 추이"))
        .accessibilityValue(samples.last.map { tr("\(Int($0.fraction * 100))퍼센트") } ?? "")
    }
}

extension MemoryReading {
    var usedFraction: Double {
        total > 0 ? min(1, Double(used) / Double(total)) : 0
    }
    var applicationBytes: UInt64 { used - min(used, wired + compressed) }
}

@MainActor final class DashboardModel: ObservableObject {
    @Published var memory: MemoryReading?
    @Published var servers: [ServerReading] = []
    @Published var pressure: Int32?
    @Published var runningAction = false
    @Published var notice = ""
    @Published var confirmation: Confirmation?
    @Published var boostPlanShown = false
    @Published private(set) var boostStatus = ""
    @Published private(set) var boostRunning = false
    @Published var boostIdleMinutes: Int {
        didSet { preferences?.set(boostIdleMinutes, forKey: "boostIdleMinutes") }
    }
    @Published var boostReserveGiB: Int {
        didSet { preferences?.set(boostReserveGiB, forKey: "boostReserveGiB") }
    }
    @Published private(set) var boostExcludedApps: [String: String] {
        didSet { preferences?.set(boostExcludedApps, forKey: "boostExcludedApps") }
    }
    private let idlePrograms = IdleProgramHistory()
    private var boostConnection: GPUBoostConnection?
    private var boostTracking: GPUBoostTracking?
    private var boostRestoring = false
    @Published var memoryFitEnabled: Bool {
        didSet { preferences?.set(memoryFitEnabled, forKey: "memoryFitEnabled") }
    }
    @Published private(set) var fitApps: [String: String] {
        didSet { preferences?.set(fitApps, forKey: "memoryFitApps") }
    }
    @Published private(set) var fitConnected = false
    @Published private(set) var fitComfyPort: Int?
    @Published private(set) var fitStatus = ""
    @Published private(set) var hubTraffic = [Provider: HubTraffic]()
    @Published private(set) var hubReady = false
    @Published private(set) var fitBoostArmed = false
    @Published private(set) var fitBoostPreparing = false
    private let fitHTTP = LocalHTTP()
    private var fitHandling = false
    private var fitPreparedBoost: (connection: GPUBoostConnection, limit: Int, expires: Date)?
    @Published var languagePreference: AppLanguagePreference {
        didSet { preferences?.set(languagePreference.rawValue, forKey: AppLanguagePreference.key) }
    }
    @Published var keepInMenuBar: Bool {
        didSet { preferences?.set(keepInMenuBar, forKey: "keepInMenuBar") }
    }
    @Published private(set) var serverProblems: [Provider: String] = [:]
    private var controlProblems: [Provider: (port: Int, message: String)] = [:]
    private var healthFailures: [Provider: (port: Int, since: ContinuousClock.Instant)] = [:]

    @Published var autoRecoveryEnabled: Bool {
        didSet {
            preferences?.set(autoRecoveryEnabled, forKey: "autoRecoveryEnabled")
            if autoRecoveryEnabled && !oldValue { automaticRecoveryEnabledSince = .now }
        }
    }
    @Published private(set) var memoryTrend: [MemoryTrendPoint] = []
    @Published private(set) var aiActivity = AIActivityHistory()
    @Published var screen: Screen = .models
    @Published var search = ""
    @Published var expanded = Set(Provider.allCases)
    @Published var portText = [Provider: String]()
    @Published var libraryProvider: Provider?
    @Published var libraryPurpose: ModelPurpose?
    @Published var libraryQuery = ""
    @Published private(set) var library = [LocalModel]()
    @Published private(set) var importedUsage = [ModelUse]()
    @Published private(set) var history: History
    @Published private(set) var libraryLoaded = false
    private let historyURL: URL?
    private let preferences: UserDefaults?
    private var lastAutomaticAttempt: Date?
    private var automaticRecoveryEnabledSince: Date?
    private var quickConfirmations = Set<UUID>()
    private var previousSample: TelemetrySample?
    private var refreshing = false
    private var scanning = false
    private var previousWrite = Date.distantPast
    private var polling = false
    private var listenerCache: [Provider: (port: Int, pid: Int32?, checked: Date)] = [:]
    @Published private(set) var listenerNames: [Int32: String] = [:]
    private let providers = Providers()
    private let serverTools = ServerTools()
    let discovery = ModelDiscovery()
    @Published var transferRequest: ModelTransferRequest?
    @Published var modelPickerProvider: Provider?
    private var lmModelKeys: [String: String] = [:]
    private let pressureWatcher = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)

    init(historyURL: URL? = History.defaultURL, preferences: UserDefaults? = .standard) {
        self.historyURL = historyURL
        self.preferences = preferences
        languagePreference = AppLanguagePreference(saved: preferences?.string(forKey: AppLanguagePreference.key))
        boostExcludedApps = preferences?.dictionary(forKey: "boostExcludedApps") as? [String: String] ?? [:]
        let minutes = preferences?.integer(forKey: "boostIdleMinutes") ?? 0
        boostIdleMinutes = (1...180).contains(minutes) ? minutes : 30
        let reserve = preferences?.integer(forKey: "boostReserveGiB") ?? 0
        let choices = GPUBoostBudget.reserveChoices
        boostReserveGiB = choices.contains(reserve) ? reserve : choices.first(where: { $0 >= 8 }) ?? choices.first ?? 8
        memoryFitEnabled = preferences?.bool(forKey: "memoryFitEnabled") ?? false
        fitApps = preferences?.dictionary(forKey: "memoryFitApps") as? [String: String] ?? [:]
        autoRecoveryEnabled = preferences?.bool(forKey: "autoRecoveryEnabled") ?? false
        keepInMenuBar = preferences?.object(forKey: "keepInMenuBar") as? Bool ?? true
        history = historyURL.map(History.load) ?? History()
        pressureWatcher.setEventHandler { [weak self] in
            guard let self else { return }
            let data = self.pressureWatcher.data
            self.pressure = data.contains(.critical) ? 4 : data.contains(.warning) ? 2 : data.contains(.normal) ? 1 : nil
        }
        pressureWatcher.resume()
    }

    var bulkTargets: [WorkRow] { servers.flatMap(\.models).filter(\.canReleaseWhenIdle) }
    var displayPressure: Int32? { pressure ?? memory?.pressure }

    var occupied: [ServerReading] {
        servers.filter { $0.activity != .offline && (($0.bytes ?? 0) > 0 ||
            $0.models.contains { [.working, .idle, .unknown, .loading].contains($0.activity) && $0.id != "comfy-cache" }) }
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func refreshMemory() async {
        let apps = Dictionary(NSWorkspace.shared.runningApplications.map {
            ($0.processIdentifier, AppProcess(name: $0.localizedName ?? tr("프로그램"), id: $0.bundleIdentifier))
        }, uniquingKeysWith: { first, _ in first })
        memory = await Task.detached(priority: .utility) { MacMemory.snapshot(apps: apps) }.value
        if let memory {
            if let level = memory.pressure, pressure != level { pressure = level }
            sampleMemoryTrend(memory)
        }
    }

    func sampleMemoryTrend(_ reading: MemoryReading, at date: Date = .now) {
        let cutoff = date.addingTimeInterval(-MemoryTrend.duration)
        var points = memoryTrend.filter { $0.date >= cutoff && $0.date < date }
        points.append(MemoryTrendPoint(date: date, fraction: reading.usedFraction))
        memoryTrend = Array(points.suffix(20))
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let started = ProcessInfo.processInfo.systemUptime
        idlePrograms.observe()
        async let results = providers.readings()
        await refreshMemory()
        var current = await results
        var names: [Int32: String] = [:]
        let memoryByPID = Dictionary(uniqueKeysWithValues: (memory?.processes ?? []).map { ($0.id, $0) })
        for index in current.indices where current[index].activity != .offline && current[index].id != .splash {
            let provider = current[index].id
            let port = provider.port
            let now = Date()
            let cached = listenerCache[provider]
            if cached?.port != port || cached.map({ now.timeIntervalSince($0.checked) > 20 }) == true {
                let pid = await Task.detached(priority: .utility) { MacMemory.listeningProcess(port: port) }.value
                listenerCache[provider] = (port, pid, now)
            }
            if let pid = listenerCache[provider]?.pid, let process = memoryByPID[pid] {
                names[pid] = provider.title
                if current[index].bytes == nil { current[index].bytes = process.bytes }
            }
            if provider == .comfy, current[index].activity == .idle,
               let pid = listenerCache[provider]?.pid, let entry = current[index].comfyEntryPoint {
                current[index].comfyProcess = await Task.detached(priority: .utility) {
                    ComfyProcess.find(port: port, pid: pid, entryPoint: entry)
                }.value
            }
        }
        listenerNames = names
        updateServerProblems(current)
        servers = current
        monitorGPUBoost(current, started: started)
        await syncMemoryFit()
        sampleAIActivity(current)
        if let memory { record(memory: memory, servers: current) }
    }

    private func updateServerProblems(_ readings: [ServerReading]) {
        var problems: [Provider: String] = [:]
        let now = ContinuousClock.now
        for reading in readings where reading.id.supportsEmptyReset {
            let provider = reading.id
            let port = provider.port
            if reading.transitioning { continue }
            if let problem = reading.problem { problems[provider] = problem }
            if let failure = controlProblems[provider], failure.port == port { problems[provider] = failure.message }
            if reading.activity != .offline {
                healthFailures.removeValue(forKey: provider)
            } else if reading.upstreamUnavailable && !runningAction {
                if let failure = healthFailures[provider], failure.port == port {
                    if failure.since.duration(to: now) >= .seconds(10) {
                        problems[provider] = tr("공용 모델 서버가 응답하지 않아요.")
                    }
                } else {
                    healthFailures[provider] = (port, now)
                }
            }
        }
        if serverProblems != problems { serverProblems = problems }
    }

    func serverResetPrompt(_ provider: Provider) -> Confirmation? {
        guard let problem = serverProblems[provider], !runningAction else { return nil }
        let port = provider.port
        let detail = problem + tr(" 서버를 켠 상태로 두고, 램에 올라간 모델을 모두 내려요.") +
            (provider == .lmStudio ? tr(" LM Studio에서 진행 중인 작업이 있는지 먼저 확인해 주세요.") :
             tr(" 확인된 실행·대기 작업이 있으면 초기화를 멈춰요."))
        return Confirmation(title: provider.title + tr(" 서버 초기화"), detail: detail,
                            button: tr("서버 초기화"), destructive: false) { [weak self] in
            await self?.resetServer(provider, port: port)
        }
    }

    private func resetServer(_ provider: Provider, port: Int) async {
        guard !runningAction, serverProblems[provider] != nil, provider.port == port else { return }
        runningAction = true
        notice = provider.title + tr(" 서버를 초기화하고 있어요…")
        defer { runningAction = false }
        do {
            try await serverTools.reset(provider)
            controlProblems.removeValue(forKey: provider)
            healthFailures.removeValue(forKey: provider)
            serverProblems.removeValue(forKey: provider)
            notice = provider.title + tr(" 서버가 켜졌어요. 램에 올라간 모델은 없어요.")
        } catch {
            notice = error.localizedDescription
        }
        listenerCache.removeValue(forKey: provider)
        await refresh()
    }

    private func recordServerControlFailure(_ provider: Provider, error: Error) {
        guard provider.supportsEmptyReset else { return }
        if case LocalError.status(let code) = error, code < 500 { return }
        if case LocalError.changed = error { return }
        if provider == .splash { return } // The gateway distinguishes contention from an actual switch failure.
        controlProblems[provider] = (provider.port, tr("서버 제어 요청을 완료하지 못했어요."))
    }

    func sampleAIActivity(_ readings: [ServerReading], at date: Date = .now) {
        aiActivity.append(readings, at: date)
    }

    func refreshLibrary() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let result = await Task.detached(priority: .utility) {
            (ModelLibrary.scan(), ProviderHistory.importUsage())
        }.value
        let lm = await providers.read(.lmStudio)
        if lm.activity != .offline { lmModelKeys = await ServerTools.lmModelKeys() }
        library = result.0
        importedUsage = result.1
        libraryLoaded = true
    }

    func toggleServer(_ provider: Provider) {
        guard !runningAction else { return }
        let reading = servers.first { $0.id == provider }
        let starting = reading == nil || reading?.activity == .offline || reading?.paused == true
        if starting {
            Task { await manageServer(provider, starting: true) }
        } else {
            confirmation = serverStopPrompt(provider)
        }
    }

    func serverStopPrompt(_ provider: Provider) -> Confirmation? {
        guard !runningAction else { return nil }
        return Confirmation(title: tr("\(provider.title) 서버를 끌까요?"),
            detail: tr("연결된 도구는 서버를 다시 켜면 사용할 수 있어요. 진행·대기 작업이 확인되면 종료를 기다려요."),
            button: tr("서버 끄기")) { [weak self] in await self?.manageServer(provider, starting: false) }
    }

    private func manageServer(_ provider: Provider, starting: Bool) async {
        guard !runningAction else { return }
        runningAction = true
        notice = provider.title + (starting ? tr(" 서버를 켜고 있어요…") : tr(" 서버를 끄고 있어요…"))
        defer { runningAction = false }
        do {
            if starting { try await serverTools.start(provider) }
            else { try await serverTools.stop(provider) }
            controlProblems.removeValue(forKey: provider)
            notice = provider.title + (starting ? tr(" 서버를 켰어요.") : tr(" 서버를 껐어요."))
        } catch {
            notice = error.localizedDescription
            recordServerControlFailure(provider, error: error)
        }
        listenerCache.removeValue(forKey: provider)
        await refresh()
    }

    func selectLoad(_ item: LocalModel) {
        guard !runningAction else { return }
        if item.provider == .comfy {
            notice = tr("ComfyUI는 워크플로를 실행할 때 모델과 로라를 올려요. ComfyUI에서 이 모델을 선택해 주세요.")
            openServerApp(item.provider)
            return
        }
        confirmation = loadPrompt(item)
    }

    func loadPrompt(_ item: LocalModel) -> Confirmation? {
        guard !runningAction else { return nil }
        return Confirmation(title: tr("‘\(item.title)’을 램에 올릴까요?"),
            detail: tr("파일 크기는 \(ram(item.bytes))예요. 서버가 꺼져 있으면 함께 켜요.") +
                (item.provider == .splash ? tr(" Splash는 현재 선택한 모델을 교체해요.") : ""),
            button: tr("램에 올리기"), destructive: false) { [weak self] in await self?.loadModel(item) }
    }

    private func loadModel(_ item: LocalModel) async {
        guard !runningAction else { return }
        runningAction = true
        defer { runningAction = false }
        notice = tr("‘\(item.title)’을 준비하고 있어요…")
        do {
            let state = await providers.read(item.provider)
            if state.activity == .offline { try await serverTools.start(item.provider) }
            try await serverTools.load(item)
            controlProblems.removeValue(forKey: item.provider)
            notice = tr("‘\(item.title)’을 램에 올렸어요.")
        } catch {
            notice = error.localizedDescription
            recordServerControlFailure(item.provider, error: error)
        }
        await refresh()
        await refreshLibrary()
    }

    func releaseModel(_ item: LocalModel) {
        let aliases = modelAliases(item)
        guard let row = servers.first(where: { $0.id == item.provider })?.models.first(where: {
            aliases.contains(modelKey($0.title)) || aliases.contains(modelKey($0.id)) ||
                !aliases.isDisjoint(with: $0.observedModels.map(modelKey)) ||
                aliases.contains(modelKey(URL(fileURLWithPath: $0.title).lastPathComponent))
        }), row.control != nil else { notice = tr("지금 내릴 수 있는지 서버의 작업 상태를 확인해 주세요."); return }
        select(row)
    }

    func openServerApp(_ provider: Provider) {
        if provider == .comfy, servers.contains(where: { $0.id == .comfy && $0.activity != .offline }),
           let address = URL(string: "http://127.0.0.1:\(memoryFitEnabled ? (fitComfyPort ?? provider.port) : provider.port)") {
            NSWorkspace.shared.open(address)
        } else if let app = provider.applicationURL {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            notice = provider.title + tr(" 앱의 설치 위치를 찾지 못했어요.")
        }
    }

    func receiveModels(_ strings: [String], provider: Provider) -> Bool {
        let urls = strings.compactMap { URL(string: $0) }.filter(\.isFileURL)
        guard !urls.isEmpty, urls.count == strings.count, !runningAction, transferRequest == nil else { return false }
        Task {
            let files = await Task.detached(priority: .utility) { urls.compactMap(ModelFile.inspect) }.value
            guard files.count == urls.count else { notice = tr("모델 파일이나 모델 폴더를 확인하지 못했어요."); return }
            if let reason = files.compactMap({ $0.compatibility(with: provider) }).first { notice = reason; return }
            transferRequest = ModelTransferRequest(files: files, provider: provider)
        }
        return true
    }

    func addModels(_ request: ModelTransferRequest, mode: ModelTransferMode, category: ComfyModelFolder = .automatic) async {
        guard !runningAction else { return }
        transferRequest = nil
        runningAction = true
        defer { runningAction = false }
        notice = tr("\(request.provider.title)에 모델을 추가하고 있어요…")
        do {
            let added = try await Task.detached(priority: .utility) {
                try ModelFileTransfer.add(request.files, to: request.provider, mode: mode, category: category)
            }.value
            if request.provider == .mlxServe {
                _ = try? await LocalHTTP().data(request.provider.port, "/v1/models/rescan", body: [:])
            }
            await refreshLibrary()
            notice = tr("\(request.provider.title)에 \(added.count)개를 \(mode == .link ? tr("공유 연결했어요") : tr("복사했어요")).")
        } catch { notice = tr("모델을 추가하지 못했어요. ") + error.localizedDescription }
    }

    var usage: [ModelUse] {
        let rows = importedUsage + history.usage
        var results = [String: ModelUse]()
        for var row in rows {
            if let old = results[row.id] {
                row.merge(old)
            }
            results[row.id] = row
        }
        return Array(results.values)
    }

    func use(for item: LocalModel) -> ModelUse? {
        let matches = usage.filter { $0.provider == item.provider &&
            ($0.name == item.key || item.aliases.contains(modelKey($0.name)) ||
             (item.aliases.contains(modelKey(URL(fileURLWithPath: $0.name).lastPathComponent))
              && library.filter { $0.provider == item.provider && $0.title == item.title }.count == 1)) }
        guard var result = matches.first else { return nil }
        for row in matches.dropFirst() {
            result.merge(row)
        }
        return result
    }

    private func modelAliases(_ item: LocalModel) -> Set<String> {
        var aliases = item.aliases
        if item.provider == .lmStudio, let key = lmModelKeys[item.key] { aliases.insert(modelKey(key)) }
        return aliases
    }

    func modelIsLoaded(_ item: LocalModel, in reading: ServerReading? = nil) -> Bool {
        let aliases = modelAliases(item)
        let server = reading ?? servers.first { $0.id == item.provider }
        return server?.models.contains { row in
            [.working, .idle, .unknown, .loading, .queued].contains(row.activity) &&
            (aliases.contains(modelKey(row.title)) || aliases.contains(modelKey(row.id)) ||
             !aliases.isDisjoint(with: row.observedModels.map(modelKey)) ||
             aliases.contains(modelKey(URL(fileURLWithPath: row.title).lastPathComponent)))
        } ?? false
    }

    func trashReason(_ item: LocalModel) -> String? {
        if !item.canTrash { return item.isLinked ? tr("공유 파일 또는 링크예요.") : tr("Finder에서 파일을 확인할 수 있어요.") }
        let physical = item.url.resolvingSymlinksInPath().path
        if library.contains(where: { other in
            let target = other.url.resolvingSymlinksInPath().path
            return other.id != item.id && other.isLinked && (target == physical || target.hasPrefix(physical + "/"))
        }) { return tr("다른 서버와 공유하는 원본이에요. 연결을 해제한 뒤 정리할 수 있어요.") }
        if item.provider == .splash {
            guard let startup = ModelLibrary.splashStartupModels() else { return tr("시작 설정을 확인해 주세요.") }
            if !startup.isDisjoint(with: item.aliases) { return tr("자동 시작에 쓰는 모델이에요.") }
            if servers.first(where: { $0.id == .splash })?.models.contains(where: {
                item.aliases.contains(modelKey($0.title))
            }) == true { return tr("Splash에서 선택한 모델이에요.") }
        } else if servers.contains(where: { $0.id == item.provider && $0.activity != .offline }) {
            return tr("서버를 닫으면 옮길 수 있어요.")
        }
        let signatures: [Provider: [String]] = [
            .splash: ["splash"], .mlxServe: ["mlx-serve", "mlxcore"], .lmStudio: ["lm studio", "llmster", "lmstudio"],
            .mlxStudio: ["mlx studio", "mlx harness", "vmlx"], .comfy: ["comfyui"]
        ]
        if item.provider != .splash, let signatures = signatures[item.provider],
           memory?.processes.contains(where: { process in
               signatures.contains { process.title.lowercased().contains($0) }
           }) == true { return tr("프로그램을 닫으면 옮길 수 있어요.") }
        return nil
    }

    func isDirectLink(_ item: LocalModel) -> Bool {
        (try? item.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    func selectUnlink(_ item: LocalModel) {
        guard isDirectLink(item), !runningAction else { return }
        confirmation = Confirmation(title: tr("‘\(item.title)’ 공유 연결 해제"),
            detail: tr("이 서버 폴더의 연결을 휴지통으로 옮겨요. 휴지통에서 연결을 복원할 수 있어요."), button: tr("연결 해제")) { [weak self] in
            guard let self, !self.runningAction else { return }
            self.runningAction = true
            defer { self.runningAction = false }
            let state = await self.providers.read(item.provider)
            guard ![.working, .loading, .queued, .stopping].contains(state.activity),
                  self.isDirectLink(item), !self.modelIsLoaded(item, in: state) else {
                self.notice = tr("모델을 램에서 내리고 진행·대기 작업이 끝나면 연결을 해제할 수 있어요.")
                return
            }
            do {
                var trash: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &trash)
                await self.refreshLibrary()
                self.notice = tr("공유 연결을 해제했어요.")
            } catch { self.notice = tr("연결을 해제하지 못했어요. ") + error.localizedDescription }
        }
    }

    func selectTrash(_ item: LocalModel) {
        guard trashReason(item) == nil else { return }
        confirmation = Confirmation(title: tr("‘\(item.title)’ 휴지통으로 이동"),
            detail: tr("디스크에 저장된 모델 \(ram(item.bytes))을 옮겨요. 필요하면 macOS 휴지통에서 복원할 수 있어요."),
            button: tr("휴지통으로 이동")) { [weak self] in await self?.trash(item) }
    }

    private func trash(_ item: LocalModel) async {
        guard !runningAction else { return }
        runningAction = true
        defer { runningAction = false }
        let fresh = await Task.detached(priority: .utility) { ModelLibrary.scan().first { $0.id == item.id } }.value
        let state = await providers.read(item.provider)
        let hasListener = item.provider == .splash ? false : await Task.detached(priority: .utility) {
            MacMemory.listeningProcess(port: item.provider.port) != nil
        }.value
        let protected = item.provider == .splash && state.models.contains { item.aliases.contains(modelKey($0.title)) }
        guard let fresh, trashReason(fresh) == nil, !protected, !hasListener,
              item.provider == .splash || state.activity == .offline,
              ModelLibrary.contained(fresh.url, root: fresh.root),
              fresh.canTrash, fresh.bytes == item.bytes else {
            notice = tr("모델이나 서버 상태가 달라졌어요. 목록을 다시 확인해 주세요.")
            return
        }
        do {
            var result: NSURL?
            try FileManager.default.trashItem(at: fresh.url, resultingItemURL: &result)
            notice = tr("‘\(item.title)’을 휴지통으로 옮겼어요.")
            await refreshLibrary()
        } catch { notice = tr("휴지통으로 옮기지 못했어요. \(error.localizedDescription)") }
    }

    private func record(memory: MemoryReading, servers: [ServerReading]) {
        let now = Date()
        var sample = TelemetrySample(date: now, memory: memory)
        var seen = Set<String>()
        for server in servers where server.activity == .working || server.activity == .loading {
            let jobs = server.jobs.filter { $0.activity == .working || $0.activity == .loading }
            let candidates = jobs.flatMap(\.observedModels)
            let inferred = server.models.count == 1 && server.id != .comfy ? server.models.map(\.title) : []
            let names = candidates.isEmpty ? inferred : candidates
            for name in names {
                let use = ModelUse(provider: server.id, name: name, last: now)
                if server.activity == .working, seen.insert(use.id).inserted { sample.active.append(use) }
            }
            if jobs.isEmpty {
                sample.work += ["\(server.id.title) · " + (names.isEmpty ? server.activity.rawValue : names.joined(separator: " · "))]
            } else {
                sample.work += jobs.prefix(6).map { row in
                    let models = row.observedModels.isEmpty ? inferred : row.observedModels
                    return "\(server.id.title) · \(row.title)" + (models.isEmpty ? "" : " · " + models.joined(separator: " · "))
                }
            }
        }
        sample.processNames = listenerNames
        sample.processes = memory.processes.prefix(3).map { "\(listenerNames[$0.id] ?? $0.title) \(ram($0.bytes))" }
        let count = history.events.count
        let priorSample = previousSample
        history.append(sample, after: priorSample)
        previousSample = sample
        if count != history.events.count || now.timeIntervalSince(previousWrite) > 60 { flushHistory() }
        scheduleAutomaticRecovery(previous: priorSample, current: sample)
    }

    func flushHistory() {
        guard let historyURL else { return }
        do {
            try history.save(historyURL)
            previousWrite = .now
        } catch { notice = tr("사용 기록을 저장할 수 없어요.") }
    }

    func setQuickPrompt(old: UUID?, new: UUID?) {
        if let old { quickConfirmations.remove(old) }
        if let new { quickConfirmations.insert(new) }
    }

    private var fitCanClaim: Bool {
        memoryFitEnabled && !fitHandling && !runningAction && confirmation == nil &&
            quickConfirmations.isEmpty && !boostPlanShown
    }

    func fitAddress(_ provider: Provider) -> String? {
        switch provider {
        case .splash: "http://127.0.0.1:\(Provider.splash.port)"
        case .comfy: fitComfyPort.map { "http://127.0.0.1:\($0)" }
        default: "http://127.0.0.1:\(Provider.splash.port)/fit/\(provider.rawValue)"
        }
    }

    func addFitApp() {
        let picker = NSOpenPanel()
        picker.message = tr("램이 부족할 때 자동으로 닫아도 되는 앱을 고르세요.")
        picker.prompt = tr("앱 추가")
        picker.allowedContentTypes = [.application]
        picker.allowsMultipleSelection = true
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        picker.begin { [weak self] response in
            guard response == .OK, let self else { return }
            for url in picker.urls {
                guard let bundle = Bundle(url: url)?.bundleIdentifier else { continue }
                self.fitApps[bundle] = FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: "")
            }
        }
    }

    func removeFitApp(_ bundle: String) { fitApps.removeValue(forKey: bundle) }

    private func fitCall(_ path: String = "/gate/fit", _ body: [String: Any]) async -> [String: Any]? {
        guard let data = try? await fitHTTP.data(Provider.splash.port, path, body: body, timeout: 1.5) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func copyFitAddress(_ provider: Provider) {
        guard let base = fitAddress(provider) else { return }
        let address = provider == .comfy ? base : base + (provider == .splash ? "/user/v1" : "/v1")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        notice = tr("\(provider.title) 연결 주소를 복사했어요.")
    }

    private func syncMemoryFit(result: [String: Any]? = nil) async {
        if let ready = fitPreparedBoost,
           !memoryFitEnabled || ready.expires <= .now || !ready.connection.keepPrepared() {
            cancelFitBoost()
        }
        var body: [String: Any] = [
            "enabled": memoryFitEnabled, "critical": displayPressure == 4, "warning": displayPressure == 2,
            "ready": fitCanClaim,
            "ports": Dictionary(uniqueKeysWithValues: Provider.allCases.filter { $0 != .splash }.map { ($0.rawValue, $0.port) })
        ]
        body["result"] = result
        guard let state = await fitCall("/gate/fit", body), let held = state["held"] as? [[String: Any]] else {
            if fitConnected { fitConnected = false }
            if hubReady { hubReady = false }
            if fitComfyPort != nil { fitComfyPort = nil }
            return
        }
        if !fitConnected { fitConnected = true }
        let ready = state["enabled"] as? Bool == true
        if hubReady != ready { hubReady = ready }
        let routes = state["routes"] as? [String: [String: Int]] ?? [:]
        let traffic = Dictionary(uniqueKeysWithValues: Provider.allCases.compactMap { provider in
            routes[provider.rawValue].map { (provider, HubTraffic($0)) }
        })
        if traffic != hubTraffic { hubTraffic = traffic }
        let comfyPort = state["comfy_port"] as? Int
        if fitComfyPort != comfyPort { fitComfyPort = comfyPort }
        if let claim = state["claim"] as? [String: Any], let id = claim["id"] as? String,
           let name = claim["provider"] as? String, let provider = Provider(rawValue: name),
           let port = claim["port"] as? Int, fitCanClaim {
            fitHandling = true
            runningAction = true
            let reason = claim["reason"] as? String ?? ""
            let model = claim["model"] as? String ?? ""
            fitStatus = tr("\(provider.title) · 램 확보 중")
            Task { await makeRoom(id: id, provider: provider, port: port, model: model, reason: reason) }
        } else if !fitHandling {
            let status = held.isEmpty ? "" : tr("비집고 넣기 · \(held.count)개 기다리는 중")
            if fitStatus != status { fitStatus = status }
        }
    }

    private func fitReservation(_ id: String, from: Provider? = nil) async -> Bool {
        guard memoryFitEnabled else { return false }
        var payload: [String: Any] = ["id": id]
        if let from {
            payload["provider"] = from.rawValue
            payload["port"] = from.port
        }
        return await fitCall("/gate/fit/reserve", payload)?["ok"] as? Bool == true && memoryFitEnabled
    }

    private func makeRoom(id: String, provider: Provider, port: Int, model: String, reason: String) async {
        let deadline = ContinuousClock.now + .seconds(22)
        let candidates = servers.filter { $0.id != provider && !$0.transitioning && serverProblems[$0.id] == nil }.flatMap { server in
            server.models.compactMap { row -> (Provider, Control, UInt64)? in
                guard let control = row.control else { return nil }
                let canSleep: Bool
                if case .sleepSplash = control { canSleep = true } else { canSleep = false }
                guard row.canReleaseWhenIdle || canSleep else { return nil }
                if let protected = boostTracking?.target, server.id == protected.provider { return nil }
                return (server.id, control, row.bytes ?? server.bytes ?? 0)
            }
        }.sorted { $0.2 > $1.2 }
        var reclaimed = 0
        for (source, action, _) in candidates.prefix(4) {
            guard ContinuousClock.now < deadline, provider.port == port, memoryFitEnabled else { break }
            guard await fitReservation(id, from: source) else { continue }
            let result = try? await providers.perform(action, bulk: true, requireEffect: true) { [weak self] in
                await self?.fitReservation(id, from: source) == true
            }
            if result != nil { reclaimed += 1 }
        }
        if reclaimed > 0 {
            try? await Task.sleep(for: .milliseconds(350))
            await refreshMemory()
        }
        var closed = 0
        if ContinuousClock.now < deadline, provider.port == port,
           (reclaimed == 0 || displayPressure == 4), !fitApps.isEmpty, await fitReservation(id) {
            let candidates = idleProgramsForBoost().filter { fitApps[$0.bundle] != nil && $0.bytes > 0 }
                .sorted { $0.bytes > $1.bytes }
            if !candidates.isEmpty {
                let requested = idlePrograms.requestQuit(Array(candidates.prefix(2)), minutes: boostIdleMinutes,
                    protectedPIDs: serverAppPIDs, excludedBundles: Set(boostExcludedApps.keys))
                let quitDeadline = min(deadline, .now + .seconds(4))
                while requested.contains(where: { !$0.isTerminated }), ContinuousClock.now < quitDeadline {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                closed = requested.filter(\.isTerminated).count
                if !requested.isEmpty { await refreshMemory() }
            }
        }
        var raised = false
        if reclaimed == 0, closed == 0, reason == "gpu", ContinuousClock.now < deadline,
           displayPressure == 1, provider.port == port, await fitReservation(id) {
            raised = await activateFitBoost(for: provider, model: model)
        }
        if reason == "pressure" && displayPressure == 4 { await refreshMemory() }
        let changed = reclaimed + closed > 0 || raised
        let canRetry = reason == "pressure" ? displayPressure != 4 : changed
        fitStatus = canRetry ? tr("\(provider.title) · 다시 시도 중") : ""
        var details = [String]()
        if reclaimed > 0 { details.append(tr("쉬는 모델·캐시 \(reclaimed)개 정리")) }
        if closed > 0 { details.append(tr("허용한 앱 \(closed)개 닫음")) }
        if raised { details.append(tr("GPU 상한 올림")) }
        notice = tr("비집고 넣기 · ") + (changed ? details.joined(separator: " · ") :
            canRetry ? tr("서버에 작업을 보내요.") : tr("추가로 확보할 램을 찾지 못했어요."))
        await syncMemoryFit(result: ["id": id, "changed": changed])
        runningAction = false
        fitHandling = false
    }

    func armFitBoost() async {
        guard memoryFitEnabled, !boostRunning, !fitBoostArmed, !fitBoostPreparing, !runningAction else { return }
        fitBoostPreparing = true
        defer { fitBoostPreparing = false }
        do {
            let limit = try GPUBoostBudget.enabledLimit(reserveGiB: boostReserveGiB)
            let connection = GPUBoostConnection()
            try await connection.prepare(limit: limit)
            guard memoryFitEnabled, !boostRunning else { return }
            fitPreparedBoost = (connection, limit, .now.addingTimeInterval(30 * 60))
            fitBoostArmed = true
        } catch { notice = error.localizedDescription }
    }

    func cancelFitBoost() {
        fitPreparedBoost = nil
        fitBoostArmed = false
    }

    private func activateFitBoost(for provider: Provider, model: String) async -> Bool {
        guard let ready = fitPreparedBoost, ready.expires > .now, !boostRunning,
              let models = servers.first(where: { $0.id == provider })?.gpuModels,
              let target = models.first(where: { $0.id == model || (provider == .splash && models.count == 1) }) else {
            return false
        }
        cancelFitBoost()
        do {
            try await ready.connection.activate()
            boostConnection = ready.connection
            let selected = GPUBoostTarget(provider: provider, port: provider.port, modelID: target.id, title: target.title)
            boostTracking = GPUBoostTracking(target: selected, resident: target.resident, now: ProcessInfo.processInfo.systemUptime)
            boostStatus = tr("\(selected.label) · GPU 상한 \(ready.limit / 1024)GB")
            boostRunning = true
            return true
        } catch { return false }
    }

    private var automaticSubmissionAllowed: Bool {
        autoRecoveryEnabled && confirmation == nil && quickConfirmations.isEmpty && !boostPlanShown
    }

    private var automaticBulkTargets: [WorkRow] {
        bulkTargets.filter { row in
            guard case let .release(provider, _, _) = row.control, serverProblems[provider] == nil else { return false }
            guard let target = boostTracking?.target, provider == target.provider else { return true }
            if provider == .splash { return row.title != target.modelID }
            return row.id != target.modelID
        }
    }

    private func scheduleAutomaticRecovery(previous: TelemetrySample?, current: TelemetrySample) {
        if let enabledAt = automaticRecoveryEnabledSince,
           let previous, previous.date < enabledAt { return }
        guard AutoRecovery.shouldRun(enabled: autoRecoveryEnabled, previous: previous, current: current,
                                     lastAttempt: lastAutomaticAttempt, hasTargets: !automaticBulkTargets.isEmpty,
                                     busy: runningAction || confirmation != nil || !quickConfirmations.isEmpty) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.automaticSubmissionAllowed, !self.runningAction else { return }
            let actions = self.automaticBulkTargets.compactMap(\.control)
            guard !actions.isEmpty else { return }
            self.lastAutomaticAttempt = .now
            await self.perform(actions, bulk: true, automatically: true)
        }
    }

    func releaseIdle() {
        let actions = bulkTargets.compactMap(\.control)
        guard !actions.isEmpty, !runningAction else { return }
        Task { await perform(actions, bulk: true) }
    }

    func releaseIdle(_ row: WorkRow) {
        guard row.bulk, !runningAction, let control = row.control, bulkTargets.contains(where: { $0.control == control }) else { return }
        Task { await perform([control], bulk: true) }
    }

    func select(_ row: WorkRow) {
        if row.bulk, row.control?.isRelease == true {
            releaseIdle(row)
        } else {
            confirmation = actionPrompt(for: row)
        }
    }

    func actionPrompt(for row: WorkRow) -> Confirmation? {
        guard !runningAction, let action = row.control else { return nil }
        let title: String
        let detail: String
        let button: String
        switch action {
        case .sleepSplash:
            title = tr("Splash 대화 캐시를 내릴까요?")
            detail = tr("저장된 대화는 그대로예요. Splash는 잠시 쉬고, 다음 요청의 첫 답변은 늦어질 수 있어요. 대화나 영상 작업이 진행 중이면 기다려요.")
            button = tr("대화 캐시 내리기")
        case .release:
            title = tr("‘\(row.title)’ 램에서 내리기")
            detail = row.activity == .unknown ?
                tr("이 모델이 사용 중인지 확인할 수 없어요. 진행 중인 작업이 없는지 확인한 뒤 내리세요.") :
                tr("다음에 필요하면 다시 불러와요. 디스크에 저장한 모델은 그대로 있어요.")
            button = tr("램에서 내리기")
        case .cancelSplash, .cancelComfy:
            let focus = row.conversationTitle ?? row.title
            title = row.activity == .queued ? tr("‘\(focus)’ 대기 취소") : tr("‘\(focus)’ 작업을 중단할까요?")
            let owner = row.conversationTitle == nil ? "" : row.title + " · "
            let reference = row.sessionIdentifier.map { tr("세션 ") + String($0.prefix(8)) + " · " } ?? ""
            if row.activity == .queued {
                if case .cancelSplash = action {
                    detail = owner + reference + tr("이 요청을 취소해요. 답변이 시작됐다면 진행 중인 생성도 멈춰요.")
                } else {
                    detail = owner + reference + tr("이 작업을 대기 목록에서 빼요.")
                }
                button = tr("대기 취소")
            } else {
                detail = owner + reference + tr("이 작업의 답변이나 생성이 여기서 멈춰요. 모델은 램에 남을 수 있어요.")
                button = tr("이 작업 중단")
            }
        }
        return Confirmation(title: title, detail: detail, button: button) { [weak self] in
            await self?.perform([action])
        }
    }

    private func perform(_ actions: [Control], bulk: Bool = false, automatically: Bool = false) async {
        guard !runningAction else { return }
        runningAction = true
        let prefix = automatically ? tr("자동 비우기 · ") : ""
        let previousNotice = notice
        let checkingNotice = prefix + tr("지금 상태를 확인하고 있어요…")
        notice = checkingNotice
        var successes: [String] = []
        var skipped = 0
        var stopped = false
        for action in actions {
            if automatically && !automaticSubmissionAllowed {
                stopped = true
                break
            }
            do {
                let message = try await providers.perform(action, bulk: bulk) { [weak self] in
                    guard automatically else { return true }
                    guard let self else { return false }
                    return await self.automaticSubmissionAllowed
                }
                successes.append(message)
            } catch {
                if automatically && !automaticSubmissionAllowed {
                    stopped = true
                    break
                }
                skipped += 1
                if !bulk {
                    notice = (error as? LocalError)?.errorDescription ??
                        tr("AI 프로그램에 연결하지 못했어요. 연결 상태를 확인해 주세요.")
                }
            }
        }
        await refresh()
        if stopped {
            notice = tr("자동 비우기 · \(successes.count)개에 요청했어요. 나머지는 건너뛰었어요.")
        } else if bulk && successes.isEmpty {
            if !automatically {
                notice = tr("쉬는 항목을 비울 수 없었어요. 지금 상태를 확인해 주세요.")
            } else if notice == checkingNotice {
                notice = previousNotice
            }
        } else if bulk {
            if actions.count == 1, let first = successes.first {
                notice = prefix + first
            } else {
                let messages = Array(Set(successes)).sorted().joined(separator: " ")
                notice = prefix + tr("\(successes.count)개에 정리를 요청했어요. \(messages)")
                if skipped > 0 { notice += tr(" \(skipped)개는 상태가 바뀌어 건너뛰었어요.") }
            }
        } else if let first = successes.first { notice = first }
        runningAction = false
    }

    var gpuBoostTargets: [GPUBoostTarget] {
        servers.flatMap { reading in
            (reading.gpuModels ?? []).map {
                GPUBoostTarget(provider: reading.id, port: reading.id.port, modelID: $0.id, title: $0.title)
            }
        }
    }

    private var serverAppPIDs: Set<pid_t> {
        var protected = Set<pid_t>()
        for entry in listenerCache.values {
            guard var pid = entry.pid else { continue }
            while pid > 1, protected.insert(pid).inserted {
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
                pid = pid_t(info.pbi_ppid)
            }
        }
        return protected
    }

    func idleProgramsForBoost() -> [IdleProgram] {
        idlePrograms.candidates(minutes: boostIdleMinutes, protectedPIDs: serverAppPIDs,
                                excludedBundles: Set(boostExcludedApps.keys), memory: memory)
    }

    func excludeFromBoost(bundle: String, title: String) {
        boostExcludedApps[bundle] = title
    }

    func removeBoostExclusion(bundle: String) {
        boostExcludedApps.removeValue(forKey: bundle)
    }

    func startGPUBoost(target: GPUBoostTarget, programs: [IdleProgram]) async {
        guard !runningAction, !boostRunning, !fitBoostPreparing else { return }
        cancelFitBoost()
        boostPlanShown = false
        runningAction = true
        defer { runningAction = false }
        let connection = GPUBoostConnection()
        var quitSummary = ""
        do {
            let limit = try GPUBoostBudget.enabledLimit(reserveGiB: boostReserveGiB)
            notice = tr("관리자 승인 후 선택한 앱에 종료를 요청해요…")
            try await connection.prepare(limit: limit)
            let initial = await providers.read(target.provider, port: target.port)
            guard target.port == target.provider.port,
                  let model = initial.gpuModels?.first(where: { $0.id == target.modelID }) else {
                throw ManagementError.message(tr("선택한 모델을 서버에서 확인하지 못했어요. 다시 선택해 주세요."))
            }
            let requested = idlePrograms.requestQuit(programs, minutes: boostIdleMinutes, protectedPIDs: serverAppPIDs,
                                                     excludedBundles: Set(boostExcludedApps.keys))
            let deadline = ContinuousClock.now + .seconds(5)
            while requested.contains(where: { !$0.isTerminated }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            let closed = requested.filter(\.isTerminated).count
            quitSummary = tr("앱 \(closed)개를 닫았어요.") +
                (programs.count > closed ? tr(" \(programs.count - closed)개는 아직 열려 있어요.") : "")
            notice = quitSummary + tr(" GPU 메모리 상한을 적용하고 있어요…")
            try await connection.activate()
            boostConnection = connection
            boostTracking = GPUBoostTracking(target: target, resident: model.resident, now: ProcessInfo.processInfo.systemUptime)
            boostStatus = tr("\(target.label) · GPU 상한 \(limit / 1024)GB")
            boostRunning = true
            notice = quitSummary + (model.resident ? tr(" 선택한 모델이 내려가면 원복해요.") : tr(" 5분 안에 선택한 모델을 올려 주세요."))
            await refresh()
        } catch {
            notice = quitSummary.isEmpty ? error.localizedDescription : quitSummary + " " + error.localizedDescription
        }
    }

    private func monitorGPUBoost(_ readings: [ServerReading], started: TimeInterval) {
        guard !boostRestoring, let connection = boostConnection, var tracking = boostTracking else { return }
        let target = tracking.target
        let reason: String?
        if !connection.keepAlive() {
            reason = tr("GPU 메모리 관리 연결이 끝났어요.")
        } else if target.port != target.provider.port {
            reason = tr("서버 연결 포트가 바뀌었어요.")
        } else {
            let reading = readings.first { $0.id == target.provider }
            reason = tracking.update(reading?.gpuModels, at: started)
            boostTracking = tracking
        }
        if let reason { stopGPUBoost(reason: reason) }
    }

    func stopGPUBoost(reason: String = "") {
        guard !boostRestoring, let connection = boostConnection else { return }
        boostRestoring = true
        boostStatus = tr("GPU 메모리 상한 원복 중…")
        Task {
            let result = await connection.restore()
            boostConnection = nil
            boostTracking = nil
            boostStatus = ""
            boostRunning = false
            boostRestoring = false
            notice = reason.isEmpty ? result : reason + " " + result
        }
    }

    var comfyStopTarget: ComfyProcess? {
        servers.first(where: { $0.id == .comfy && $0.activity == .idle })?.comfyProcess
    }

    func comfyStopPrompt() -> Confirmation? {
        guard !runningAction, let target = comfyStopTarget else { return nil }
        return Confirmation(title: tr("ComfyUI 서버를 종료할까요?"),
                            detail: tr("브라우저에서 편집한 작업이 있다면 먼저 저장해 주세요. 서버를 다시 켜야 이미지와 영상 작업을 할 수 있어요."),
                            button: tr("서버 종료")) { [weak self] in
            await self?.stopComfy(target)
        }
    }

    private func stopComfy(_ target: ComfyProcess) async {
        guard !runningAction else { return }
        runningAction = true
        defer { runningAction = false }
        notice = tr("ComfyUI에 진행 중이거나 대기 중인 작업이 없는지 확인하고 있어요…")
        guard await canStopComfy(target) else {
            notice = tr("ComfyUI 상태가 달라졌어요. 진행 중이거나 대기 중인 작업이 없는지 확인해 주세요.")
            await refresh()
            return
        }
        guard target.requestStop(SIGINT) else {
            notice = tr("ComfyUI에 종료를 요청할 수 없어요.")
            await refresh()
            return
        }
        if !(await waitForComfyExit(target)), await canStopComfy(target), target.requestStop(SIGTERM) {
            _ = await waitForComfyExit(target)
        }

        let listener = await Task.detached(priority: .utility) { MacMemory.listeningProcess(port: target.port) }.value
        listenerCache.removeValue(forKey: .comfy)
        await refresh()
        if target.stillRunning {
            notice = tr("ComfyUI 종료를 요청했어요. 프로세스가 아직 닫히지 않았어요.")
        } else if listener != nil {
            notice = tr("ComfyUI가 종료된 뒤 같은 포트에서 새 서버가 열렸어요.")
        } else {
            notice = tr("ComfyUI 서버를 종료했어요.")
        }
    }

    private func canStopComfy(_ target: ComfyProcess) async -> Bool {
        guard target.port == Provider.comfy.port,
              await Task.detached(priority: .utility, operation: { target.ownsPort }).value else { return false }
        return await providers.comfyIsIdle(port: target.port) && target.port == Provider.comfy.port
    }

    private func waitForComfyExit(_ target: ComfyProcess) async -> Bool {
        for _ in 0..<12 where target.stillRunning {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return !target.stillRunning
    }

    func canQuit(_ process: ProcessMemory) -> Bool {
        if listenerNames[process.id] == Provider.comfy.title || comfyStopTarget?.pid == process.id {
            return comfyStopTarget?.pid == process.id
        }
        guard process.id != ProcessInfo.processInfo.processIdentifier, let bundle = process.appID,
              let app = NSRunningApplication(processIdentifier: process.id), app.bundleIdentifier == bundle,
              app.activationPolicy == .regular, let path = app.bundleURL?.path else { return false }
        return !path.hasPrefix("/System/")
    }

    func quitApp(_ process: ProcessMemory) {
        if comfyStopTarget?.pid == process.id {
            confirmation = comfyStopPrompt()
            return
        }
        guard canQuit(process), let app = NSRunningApplication(processIdentifier: process.id) else { return }
        confirmation = Confirmation(title: tr("‘\(process.title)’ 종료"),
            detail: tr("프로그램에 정상 종료를 요청해요. 열어 둔 작업이 있다면 먼저 저장해 주세요."), button: tr("종료 요청")) { [weak self] in
            guard self?.canQuit(process) == true, !app.isTerminated else { return }
            self?.notice = app.terminate() ? tr("프로그램에 종료를 요청했어요.") : tr("프로그램에 종료를 요청할 수 없어요.")
        }
    }
}

extension Control {
    var isRelease: Bool {
        if case .release = self { return true }
        return false
    }
}

extension WorkRow {
    var readableTitle: String { conversationTitle ?? title }
    var canReleaseWhenIdle: Bool { bulk && control?.isRelease == true }

    var actionLabel: String {
        if case .sleepSplash = control { return tr("대화 캐시 내리기") }
        if control?.isRelease == true { return id == "comfy-cache" ? tr("캐시 비우기") : tr("램에서 내리기") }
        return activity == .queued ? tr("대기 취소") : tr("작업 중단")
    }
}

struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let button: String
    var destructive = true
    let run: @MainActor () async -> Void
}

extension Activity {
    var tint: Color {
        switch self {
        case .working: .cyan
        case .queued, .loading, .stopping: .orange
        case .idle: .mint
        case .unloaded, .unknown, .offline, .empty: .secondary
        }
    }
}

private final class DashboardNavigation: ObservableObject {
    @Published var onlyIdle = false
}

struct Dashboard: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject private var navigation = DashboardNavigation()
    private var onlyIdle: Bool { navigation.onlyIdle }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(MonitorPalette.line).frame(width: 1).accessibilityHidden(true)
            VStack(spacing: 0) {
                header
                Rectangle().fill(MonitorPalette.line).frame(height: 1)
                if model.screen == .settings {
                    settings
                } else {
                    if model.screen == .library {
                        ModelServerDropTargets(model: model).padding(.horizontal, 20).padding(.vertical, 10)
                        Divider()
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            switch model.screen {
                            case .hub: HubScreen(model: model)
                            case .models: overview
                            case .library: LibraryScreen(model: model)
                            case .usage: UsageScreen(model: model)
                            case .swap: SwapScreen(model: model)
                            case .processes: processList
                            case .about: AboutScreen()
                            case .settings: EmptyView()
                            }
                        }
                        .frame(maxWidth: 1080, alignment: .leading)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                    }.id(model.screen)
                }
                if !model.notice.isEmpty {
                    Divider()
                    HStack(spacing: 10) {
                        if model.runningAction { ProgressView().controlSize(.small) }
                        Text(model.notice).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(tr("닫기"), systemImage: "xmark") { model.notice = "" }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }.font(.system(size: 13)).padding(.horizontal, 20).padding(.vertical, 10)
                        .background(MonitorPalette.surface)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MonitorPalette.background)
        }
        .frame(minWidth: 760, minHeight: 560)
        .font(.system(size: 14))
        .tint(MonitorPalette.accent)
        .environment(\.locale, AppLanguage.active.locale)
        .task(id: model.screen) {
            if model.screen == .library || model.screen == .usage { await model.refreshLibrary() }
        }
        .sheet(item: $model.transferRequest) { request in ModelTransferSheet(model: model, request: request) }
        .sheet(isPresented: $model.boostPlanShown) { GPUBoostSheet(model: model) }
        .alert(item: $model.confirmation) { item in
            Alert(title: Text(item.title), message: Text(item.detail),
                  primaryButton: item.destructive ? .destructive(Text(item.button)) { Task { await item.run() } } :
                    .default(Text(item.button)) { Task { await item.run() } },
                  secondaryButton: .cancel(Text(tr("취소"))))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            sidebarTitle(tr("모니터링"))
            nav(.hub)
            nav(.models)
            nav(.processes)
            nav(.swap)
            sidebarTitle(tr("모델")).padding(.top, 13)
            nav(.library)
            nav(.usage)
            Divider().padding(.horizontal, 8).padding(.vertical, 9)
            nav(.settings)
            nav(.about)
            Spacer()
            GachaBanner()
        }
        .padding(10).padding(.top, 4)
        .frame(width: 184)
        .background(MonitorPalette.sidebar)
        .accessibilityIdentifier("dashboard-navigation")
    }

    private func sidebarTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(MonitorPalette.secondary)
            .padding(.horizontal, 9).padding(.bottom, 3)
    }

    private func nav(_ screen: Screen) -> some View {
        let selected = model.screen == screen
        return Button {
            model.screen = screen
        } label: {
            HStack(spacing: 8) {
                Image(systemName: screen.icon)
                    .frame(width: 19)
                    .foregroundStyle(selected ? MonitorPalette.accent : MonitorPalette.secondary)
                Text(screen.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(MonitorPalette.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .frame(minHeight: 33)
            .background(selected ? MonitorPalette.surface : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.screen.title).font(.system(size: 23, weight: .semibold)).foregroundStyle(MonitorPalette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if model.screen == .models {
                Button {
                    model.releaseIdle()
                } label: {
                    Label(model.bulkTargets.isEmpty ? tr("쉬는 항목 비우기") : tr("쉬는 항목 \(model.bulkTargets.count)개 비우기"),
                          systemImage: "arrow.down.to.line")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(MonitorButtonStyle(prominent: true))
                .disabled(model.bulkTargets.isEmpty || model.runningAction)
                .help(tr("지금 작업에 쓰지 않는 모델과 임시 데이터만 내려요."))
                Button(model.boostRunning ? tr("GPU 상한 원복") : tr("램 쥐어짜기"), systemImage: "gauge.with.needle") {
                    if model.boostRunning { model.stopGPUBoost() }
                    else { model.boostPlanShown = true }
                }
                .buttonStyle(MonitorButtonStyle())
                .disabled(model.runningAction && !model.boostRunning)
                AutomaticRecoveryToggle(model: model)
            }
            Button(tr("새로 고침"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .labelStyle(.iconOnly).buttonStyle(MonitorButtonStyle())
                .help(tr("서버와 램 상태 새로 고침"))
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 62)
    }

    private var overview: some View {
        let servers = onlyIdle ? model.servers.filter { $0.models.contains(where: \.canReleaseWhenIdle) } :
            model.occupied.filter(\.hasObservedRAM)
        return Group {
            memorySummary
            if model.boostRunning {
                Label(model.boostStatus, systemImage: "gauge.with.needle")
                    .font(.callout.weight(.medium))
            }
            ServerControlGrid(model: model)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(onlyIdle ? tr("비울 수 있는 항목") : tr("램을 쓰는 AI 서버"))
                    .font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if !servers.isEmpty {
                    Text(tr("\(onlyIdle ? model.bulkTargets.count : servers.count)개")).foregroundStyle(.secondary)
                }
                Spacer()
                if onlyIdle || !model.bulkTargets.isEmpty {
                    Button(onlyIdle ? tr("모든 서버 보기") : tr("비울 수 있는 항목 \(model.bulkTargets.count)개 보기")) {
                        navigation.onlyIdle.toggle()
                    }.buttonStyle(.link)
                } else if !servers.isEmpty {
                    Text(tr("비울 수 있는 항목이 없어요")).foregroundStyle(.secondary)
                }
            }
            if servers.isEmpty {
                if onlyIdle {
                    ContentUnavailableView(tr("비울 수 있는 항목이 없어요"), systemImage: "checkmark.circle")
                        .frame(minHeight: 140)
                } else if model.servers.isEmpty {
                    ProgressView(tr("AI 서버를 확인 중이에요.")).controlSize(.small).padding(.vertical, 10)
                } else if model.servers.allSatisfy({ $0.activity == .offline }) {
                    ContentUnavailableView {
                        Label(tr("연결된 AI 서버가 없어요"), systemImage: "network.slash")
                    } actions: {
                        Button(tr("연결 설정")) { model.screen = .settings }
                    }.frame(minHeight: 140)
                } else {
                    ContentUnavailableView(tr("램을 쓰는 AI 서버가 없어요"), systemImage: "memorychip",
                                           description: Text(tr("모델이나 AI 작업을 시작하면 여기에 표시돼요.")))
                        .frame(minHeight: 140)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(servers) { server in
                        if server.id != servers.first?.id { Divider() }
                        providerGroup(server)
                    }
                }.background(MonitorSurface())
            }
        }
    }

    private var memorySummary: some View {
        let reading = model.memory
        let pressure = model.displayPressure
        let swaps = model.history.days[History.day(.now)]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                MemoryReadout(memory: reading, pressure: pressure).frame(width: 142, alignment: .leading)
                AIActivityChart(history: model.aiActivity)
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(MonitorPalette.line).frame(width: 1).accessibilityHidden(true)
                    }
            }
            if let reading {
                composition(reading)
            } else {
                Divider()
            }
            HStack(spacing: 12) {
                summaryValue(tr("프로그램 등에 사용"), reading.map { ram($0.applicationBytes) }, swatch: .blue)
                summaryValue(tr("시스템 고정"), reading.map { ram($0.wired) }, swatch: .orange)
                summaryValue(tr("압축"), reading.map { ram($0.compressed) }, swatch: .purple)
                Button {
                    model.screen = .swap
                } label: {
                    summaryValue(tr("스왑"), reading.map { ram($0.swap) }, image: "chevron.right")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(tr("디스크를 임시로 사용한 기록 보기"))
                .accessibilityHint(swaps.map { tr("오늘 스왑 쓰기 ") + ram($0.written) } ?? tr("스왑 기록 열기"))
            }
        }
        .padding(15)
        .background(MonitorSurface())
    }

    private func composition(_ reading: MemoryReading) -> some View {
        let values: [(UInt64, Color)] = [(reading.applicationBytes, .blue), (reading.wired, .orange), (reading.compressed, .purple)]
        let scale = Double(max(1, max(reading.used, reading.total)))
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(values.indices, id: \.self) { index in
                    let value = values[index]
                    value.1.frame(width: geometry.size.width * Double(value.0) / scale)
                }
                Spacer(minLength: 0)
            }.background(.primary.opacity(0.09)).clipShape(Capsule())
        }.frame(height: 6).accessibilityHidden(true)
    }

    private func summaryValue(_ title: String, _ value: String?, image: String? = nil, swatch: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let swatch { Circle().fill(swatch).frame(width: 6, height: 6).accessibilityHidden(true) }
                Text(title)
                if let image { Image(systemName: image).font(.system(size: 9, weight: .semibold)) }
            }.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Text(value ?? "—").font(.system(size: 15, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerGroup(_ server: ServerReading) -> some View {
        let expanded = onlyIdle || model.expanded.contains(server.id)
        let jobs = onlyIdle ? [] : server.jobs.filter { $0.activity != .empty }
        let runningModels = onlyIdle ? server.models.filter(\.canReleaseWhenIdle) :
            server.models.filter { ![.unloaded, .empty].contains($0.activity) }
        let otherModels = onlyIdle ? [] : server.models.filter { [.unloaded, .empty].contains($0.activity) }
        let showsRows = !jobs.isEmpty || !runningModels.isEmpty || !otherModels.isEmpty
        let canExpand = showsRows && !onlyIdle
        let summary = providerHeader(server, disclosure: canExpand ? (expanded ? "chevron.down" : "chevron.right") : nil)
        return VStack(alignment: .leading, spacing: 0) {
            if canExpand {
                Button {
                    if expanded { model.expanded.remove(server.id) } else { model.expanded.insert(server.id) }
                } label: {
                    summary.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityHint(expanded ? tr("작업과 모델 접기") : tr("작업과 모델 펼치기"))
            } else {
                summary
            }
            if expanded && showsRows {
                Divider().padding(.leading, 13)
                if !jobs.isEmpty {
                    sectionTitle(server.id == .splash ? tr("대화와 슬롯") : tr("진행·대기 작업"))
                    ForEach(jobs) { workRow($0, isJob: true) }
                }
                if jobs.isEmpty && !server.recentJobs.isEmpty && !onlyIdle {
                    sectionTitle(tr("최근 사용한 대화 · 지금은 응답 중 아님"))
                    ForEach(server.recentJobs) { workRow($0, isJob: true) }
                }
                if !runningModels.isEmpty {
                    sectionTitle(server.id == .mlxStudio ? tr("서버에서 보이는 모델") : tr("메모리에 있는 모델"))
                    ForEach(runningModels) { workRow($0, isJob: false) }
                }
                if !otherModels.isEmpty {
                    sectionTitle(tr("내려간 모델"))
                    ForEach(otherModels) { workRow($0, isJob: false) }
                }
                if !onlyIdle && server.jobs.contains(where: { $0.activity == .empty }) {
                    let count = server.jobs.filter { $0.activity == .empty }.count
                    Text(tr("빈 작업 자리 \(count)개"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.leading, 44).padding(.vertical, 7)
                }
            }
        }
    }

    private func providerHeader(_ server: ServerReading, disclosure: String?) -> some View {
        HStack(spacing: 10) {
            Group {
                if let disclosure {
                    Image(systemName: disclosure)
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(height: 1)
                }
            }.frame(width: 11).accessibilityHidden(true)
            ProviderIcon(provider: server.id, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.id.title).font(.system(size: 16, weight: .semibold))
                if !server.detail.isEmpty {
                    Text(server.detail).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                        .help(server.detail)
                }
            }
            Spacer(minLength: 4)
            badge(server.activity)
            if let bytes = server.bytes {
                Text(ram(bytes)).monospacedDigit().fontWeight(.semibold)
                    .frame(minWidth: 64, alignment: .trailing)
                    .accessibilityLabel(tr("서버 전체 램 \(ram(bytes))"))
            }
        }.padding(.horizontal, 13).padding(.vertical, 10)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .padding(.leading, 44).padding(.top, 8).padding(.bottom, 2)
    }

    private func workRow(_ row: WorkRow, isJob: Bool) -> some View {
        let context = [row.conversationTitle == nil ? "" : row.title, row.detail,
                       row.detail.isEmpty ? row.observedModels.joined(separator: " · ") : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: isJob ? "bubble.left" : "square.stack.3d.up")
                    .foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.readableTitle).font(.system(size: 14, weight: .medium)).lineLimit(2).help(row.readableTitle)
                    if let note = row.attributionNote {
                        Text(note).font(.system(size: 13)).foregroundStyle(row.sessionIdentifier == nil ? Color.orange : .secondary)
                    }
                    if isJob && row.sessionIdentifier != nil && row.conversationTitle == nil {
                        Text(tr("대화방 제목 미확인 · 위의 봇과 세션 번호로 확인해 주세요")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !context.isEmpty {
                        Text(context).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).help(context)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                badge(row.activity)
                if let bytes = row.bytes {
                    Text(ram(bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                if row.control != nil {
                    Button(row.actionLabel) { model.select(row) }
                        .controlSize(.regular)
                        .disabled(model.runningAction)
                        .accessibilityLabel("\(row.actionLabel): \(row.readableTitle)")
                }
                if row.id == "comfy-cache", model.comfyStopTarget != nil {
                    Button(tr("서버 종료…")) { model.confirmation = model.comfyStopPrompt() }
                        .disabled(model.runningAction)
                        .accessibilityLabel(tr("ComfyUI 서버 종료"))
                }
            }.padding(.leading, 43).padding(.trailing, 13).padding(.vertical, 7)
            Divider().padding(.leading, 69)
        }
    }

    private func badge(_ activity: Activity) -> some View {
        HStack(spacing: 5) {
            Circle().fill(activity.tint).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(activity.friendlyLabel).foregroundStyle(.secondary)
        }.font(.system(size: 12, weight: .medium)).fixedSize()
            .accessibilityElement(children: .combine)
    }

    private var processList: some View {
        let rows = (model.memory?.processes ?? []).filter {
            model.search.isEmpty || (model.listenerNames[$0.id] ?? $0.title)
                .localizedCaseInsensitiveContains(model.search) || String($0.id) == model.search
        }
        return VStack(alignment: .leading, spacing: 11) {
            TextField(tr("프로그램 이름으로 찾기"), text: $model.search).textFieldStyle(.roundedBorder).controlSize(.large)
            if model.memory == nil {
                ProgressView(tr("프로그램을 확인 중이에요.")).controlSize(.small).padding(.vertical, 10)
            } else if rows.isEmpty {
                ContentUnavailableView(
                    model.search.isEmpty ? tr("표시할 프로그램이 없어요") : tr("그 이름의 프로그램을 찾지 못했어요"),
                    systemImage: "magnifyingglass")
            } else {
                HStack {
                    Text(tr("프로그램"))
                    Spacer()
                    Label(tr("램 사용량"), systemImage: "arrow.down")
                        .frame(minWidth: 94, alignment: .trailing)
                    Color.clear.frame(width: 66, height: 1).accessibilityHidden(true)
                }.font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
                LazyVStack(spacing: 0) {
                    ForEach(rows.prefix(model.search.isEmpty ? 150 : 500)) { row in
                        HStack(spacing: 10) {
                            if let app = NSRunningApplication(processIdentifier: row.id), let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 21, height: 21)
                            } else {
                                Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 21)
                            }
                            Text(model.listenerNames[row.id] ?? row.title).lineLimit(1)
                            Spacer()
                            Text(ram(row.bytes)).monospacedDigit()
                            Group {
                                if model.canQuit(row) { Button(tr("종료")) { model.quitApp(row) } }
                                else { Color.clear.frame(height: 1).accessibilityHidden(true) }
                            }.frame(width: 56, alignment: .trailing)
                        }.padding(.vertical, 8)
                        Divider().padding(.leading, 31)
                    }
                }.padding(.horizontal, 12).background(MonitorSurface())
            }
        }
    }

    private var settings: some View {
        VStack(spacing: 0) {
            settingsForm
            if !model.portText.isEmpty {
                Divider()
                HStack {
                    Button(tr("변경 취소")) { model.portText.removeAll() }
                        .buttonStyle(MonitorButtonStyle())
                    Spacer()
                    if invalidPort {
                        Text(tr("포트는 1~65535 사이로 입력하세요.")).foregroundStyle(.secondary)
                    }
                    Button(tr("연결 저장"), action: savePorts)
                        .buttonStyle(MonitorButtonStyle(prominent: true))
                        .disabled(invalidPort)
                }.padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
    }

    private var invalidPort: Bool {
        model.portText.values.contains { !(1...65535 ~= (Int($0) ?? 0)) }
    }

    private func savePorts() {
        guard !model.portText.isEmpty, !invalidPort else { return }
        for (provider, value) in model.portText {
            if let port = Int(value) { UserDefaults.standard.set(port, forKey: "port." + provider.rawValue) }
        }
        model.portText.removeAll()
        model.notice = tr("연결 설정을 저장했어요.")
        Task { await model.refresh() }
    }

    private var settingsForm: some View {
        Form {
            Section(tr("앱 언어")) {
                Picker(tr("언어"), selection: $model.languagePreference) {
                    ForEach(AppLanguagePreference.allCases) { Text($0.title).tag($0) }
                }
                Text(tr("메뉴에서 ‘완전히 종료’를 누른 뒤 앱을 다시 열면 적용돼요."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Section(tr("메뉴 막대")) {
                Toggle(tr("Dock에서 종료해도 메뉴 막대에 남기기"), isOn: $model.keepInMenuBar)
                    .toggleStyle(.switch).tint(MonitorPalette.switchTint)
                LabeledContent(tr("램 상태 표시")) {
                    HStack(spacing: 14) {
                        pressureLegend(tr("여유"), pressure: 1)
                        pressureLegend(tr("주의"), pressure: 2)
                        pressureLegend(tr("부족"), pressure: 4)
                    }
                }
            }
            Section(tr("자동 비우기")) {
                Toggle(isOn: $model.autoRecoveryEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("스왑이 발생하면 쉬는 항목 비우기"))
                        Text(tr("맥이 디스크에 램 내용을 옮기기 시작하면 쉬는 모델만 내립니다."))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).tint(MonitorPalette.switchTint)
            }
            MemoryFitSettings(model: model)
            Section(tr("램 쥐어짜기")) {
                Stepper(tr("앱을 닫기 전 미사용 시간 \(model.boostIdleMinutes)분"),
                        value: $model.boostIdleMinutes, in: 1...180)
                Picker(tr("GPU 상한에서 남길 메모리"), selection: $model.boostReserveGiB) {
                    ForEach(GPUBoostBudget.reserveChoices, id: \.self) { Text("\($0)GB").tag($0) }
                }
                Text(tr("앱을 마지막으로 화면에서 사용한 때부터 계산해요. 바뀐 설정은 다음 실행부터 적용돼요."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            BoostExclusionsSettings(model: model)
            Section(tr("로컬 서버 연결")) {
                ForEach(Provider.allCases) { provider in
                    LabeledContent {
                        TextField(tr("포트"), text: Binding(
                            get: { model.portText[provider] ?? String(provider.port) },
                            set: { model.portText[provider] = String($0.filter { $0.isASCII && $0.isNumber }.prefix(5)) }
                        ))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 78)
                        .textFieldStyle(.roundedBorder).accessibilityLabel(tr("\(provider.title) 포트"))
                    } label: {
                        let reading = model.servers.first { $0.id == provider }
                        let hasEdit = model.portText[provider].map { $0 != String(provider.port) } ?? false
                        HStack(spacing: 9) {
                            Circle().fill(hasEdit ? Color.orange :
                                (reading.map { $0.activity == .offline ? Color.secondary : Color.green } ?? .secondary))
                                .frame(width: 6, height: 6).accessibilityHidden(true)
                            ProviderIcon(provider: provider, size: 23)
                            Text(provider.title)
                            Text(hasEdit ? tr("저장 전") : (reading.map { $0.activity == .offline ? tr("연결 안 됨") : tr("연결됨") } ?? tr("확인 중")))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(tr("기본 포트 불러오기")) {
                    for provider in Provider.allCases { model.portText[provider] = String(provider.defaultPort) }
                }
            }
            if let source = Bundle.main.object(forInfoDictionaryKey: "AIRAMSourceFolder") as? String {
                Section(tr("Hermes 대화와 슬롯")) {
                    LabeledContent {
                        Button(tr("코딩 폴더 열기"), systemImage: "folder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: source, isDirectory: true))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("Splash 봇·대화 이름 연결"))
                            Text(tr("코딩 폴더에서 ‘연결 켜기.command’를 열어 두 앱을 연결합니다."))
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }

    private func pressureLegend(_ text: String, pressure: Int32) -> some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuPressureIcon.image(pressure)).accessibilityHidden(true)
            Text(text)
        }
    }
}

struct MonitorSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(MonitorPalette.surface)
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(MonitorPalette.line) }
    }
}
