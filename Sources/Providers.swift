import Darwin
import Foundation
import SQLite3

enum Provider: String, CaseIterable, Identifiable, Codable, Sendable {
    case splash, mlxServe, lmStudio, mlxStudio, comfy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .splash: "Splash"
        case .mlxServe: "MLX-Serve"
        case .lmStudio: "LM Studio"
        case .mlxStudio: "MLX Studio"
        case .comfy: "ComfyUI"
        }
    }
    var defaultPort: Int {
        switch self {
        case .splash: 8002
        case .mlxServe: 11234
        case .lmStudio: 1234
        case .mlxStudio: 8080
        case .comfy: 8188
        }
    }
    var port: Int {
        let saved = UserDefaults.standard.integer(forKey: "port." + rawValue)
        if 1...65535 ~= saved { return saved }
        if self == .mlxServe, let options = UserDefaults(suiteName: "com.dalcu.mlx-core")?.data(forKey: "serverOptions"),
           let settings = (try? JSONSerialization.jsonObject(with: options)) as? [String: Any],
           let configured = settings["port"] as? Int, 1...65535 ~= configured {
            return configured
        }
        return defaultPort
    }
}

enum Activity: String {
    case working = "작업 중", queued = "대기 중", idle = "유휴"
    case unloaded = "내려감", unknown = "상태 미확인", empty = "비어 있음"
    case stopping = "중단 중", offline = "연결 안 됨", loading = "불러오는 중"
}

enum Control: Hashable {
    case release(Provider, String, Int)
    case sleepSplash(String, Int)
    case cancelSplash(String, Int)
    case cancelComfy(String, Bool, Int)
}

struct WorkRow: Identifiable {
    let id: String
    let title: String
    var detail = ""
    var activity: Activity
    var bytes: UInt64?
    var control: Control?
    var bulk = false
    var observedModels: [String] = []
    var conversationTitle: String? = nil
    var sessionIdentifier: String? = nil
    var attributionNote: String? = nil
    var workKind: AIWorkKind? = nil
}

struct GPUModelReading {
    let id: String
    let title: String
    let resident: Bool
}

struct ServerReading: Identifiable {
    let id: Provider
    var detail: String
    var activity: Activity
    var bytes: UInt64?
    var models: [WorkRow] = []
    var jobs: [WorkRow] = []
    var recentJobs: [WorkRow] = []
    var paused = false
    var comfyEntryPoint: String?
    var comfyProcess: ComfyProcess?
    var gpuModels: [GPUModelReading]?
    var problem: String?
    var transitioning = false
    var upstreamUnavailable = false
    var generationObserved = false
    var confirmedGenerationIDs: [String]?
}

enum LocalError: LocalizedError {
    case status(Int), invalid, changed, missing
    var errorDescription: String? {
        switch self {
        case .status(401), .status(403): tr("서버 접근 권한을 확인해 주세요.")
        case .status(404), .missing: tr("서버에서 이 기능을 제공하지 않거나 작업이 이미 끝났어요.")
        case .status(409), .changed: tr("작업이나 연결 상태가 달라졌어요. 새 상태를 확인해 주세요.")
        case .status(let code): tr("서버가 요청을 완료하지 못했어요. (\(code))")
        case .invalid: tr("서버 응답을 확인할 수 없어요.")
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class LocalHTTP: Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2.8
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }

    func data(_ port: Int, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 16) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(port)" + path) else { throw LocalError.invalid }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if path == "/gate" { request.setValue("1", forHTTPHeaderField: "X-AIRAM-Control") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "X-AIRAM-Control")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.connectionProxyDictionary = [:]
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            let control = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
            defer { control.finishTasksAndInvalidate() }
            return try await send(request, on: control)
        }
        return try await send(request, on: session)
    }

    private func send(_ request: URLRequest, on session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw LocalError.invalid }
        guard 200..<300 ~= status else { throw LocalError.status(status) }
        return data
    }

    func json(_ port: Int, _ path: String) async -> [String: Any]? {
        guard let data = try? await data(port, path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private extension Dictionary where Key == String, Value == Any {
    func object(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
    func objects(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
    func text(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? { self[key] as? Int }
    func countValues(_ key: String) -> Int? {
        (self[key] as? [String: Int])?.values.reduce(0, +)
    }
}

enum HermesConversation {
    private static let stateHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func preview(profile: String?, session: String?, scope: String = "profiles", home: URL? = nil) -> String? {
        guard let profile, valid(profile), let session, valid(session) else { return nil }
        guard ["profiles", "office"].contains(scope) else { return nil }
        let home = home ?? stateHome
        let folder = scope == "office" ? home.appendingPathComponent("office-runtime/profiles").appendingPathComponent(profile) :
            profile == "default" ? home : home.appendingPathComponent("profiles").appendingPathComponent(profile)
        guard let physical = realpath(folder.path, nil) else { return nil }
        defer { free(physical) }
        let path = String(cString: physical) + "/state.db"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 35)
        // Exact ID within the reported profile. Recover a title from a compressed predecessor
        // only along Hermes's compression edge; a branch or new chat is a separate title.
        let sql = """
            WITH RECURSIVE chain(id, parent, title, depth) AS (
                SELECT id, parent_session_id, title, 0 FROM sessions
                  WHERE id = ?1 AND (profile_name = ?2 OR profile_name IS NULL OR (?3 = 'office' AND profile_name = 'custom'))
                UNION ALL
                SELECT p.id, p.parent_session_id, p.title, c.depth + 1
                FROM chain c JOIN sessions p ON c.parent = p.id
                WHERE c.depth < 8 AND p.end_reason = 'compression'
                  AND (p.profile_name = ?2 OR p.profile_name IS NULL OR (?3 = 'office' AND p.profile_name = 'custom'))
            )
            SELECT title FROM chain WHERE title IS NOT NULL ORDER BY depth;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, session, -1, transient)
        sqlite3_bind_text(statement, 2, profile, -1, transient)
        sqlite3_bind_text(statement, 3, scope, -1, transient)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            if let label = shorten(String(cString: text)) { return label }
        }
        return nil
    }

    static func profileName(_ slug: String, home: URL? = nil) -> String {
        guard valid(slug) else { return tr("이름 미확인") }
        let home = home ?? stateHome
        let file = (slug == "default" ? home : home.appendingPathComponent("profiles").appendingPathComponent(slug))
            .appendingPathComponent("profile.yaml")
        guard let data = try? Data(contentsOf: file), data.count <= 65_536,
              let manifest = String(data: data, encoding: .utf8) else { return slug == "default" ? tr("기본 대화") : slug }
        let lines = manifest.split(separator: "\n")
        let line = lines.first { $0.hasPrefix("    title: ") } ?? lines.first { $0.hasPrefix("display_name: ") }
            ?? lines.first { $0.hasPrefix("description: ") }
        guard var raw = line?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) else { return slug }
        if raw.hasPrefix("\""), let data = raw.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String { raw = decoded }
        else if raw.hasPrefix("'"), raw.hasSuffix("'") { raw = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return shorten(raw) ?? slug
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 120 &&
            value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    private static func shorten(_ title: String) -> String? {
        let clean = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let blocked = CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\u{200C}\u{200D}")).union(
            CharacterSet(charactersIn: "\u{200B}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
        let safe = String(clean.unicodeScalars.filter { !blocked.contains($0) })
        guard !safe.isEmpty else { return nil }
        if safe == "Bot Chat" { return tr("봇 대화") }
        return safe.count > 42 ? String(safe.prefix(42)) + "…" : safe
    }
}

struct Providers: Sendable {
    let http = LocalHTTP()

    func readings() async -> [ServerReading] {
        await withTaskGroup(of: ServerReading.self) { group in
            for provider in Provider.allCases { group.addTask { await read(provider) } }
            var readings: [ServerReading] = []
            for await item in group { readings.append(item) }
            if readings.contains(where: { $0.id == .comfy && [.working, .queued].contains($0.activity) }),
               let splash = readings.firstIndex(where: { $0.id == .splash }) {
                for index in readings[splash].models.indices {
                    if case .sleepSplash = readings[splash].models[index].control {
                        readings[splash].models[index].control = nil
                        readings[splash].models[index].detail = tr("이미지·영상 작업이 끝나면 캐시를 내릴 수 있어요.")
                    }
                }
            }
            return Provider.allCases.compactMap { provider in readings.first { $0.id == provider } }
        }
    }

    func read(_ provider: Provider, port: Int? = nil) async -> ServerReading {
        let port = port ?? provider.port
        let offline = ServerReading(id: provider, detail: tr("이 Mac의 포트 \(port)"), activity: .offline)
        switch provider {
        case .splash: return await splash(port) ?? offline
        case .mlxServe: return await mlxServe(port) ?? offline
        case .lmStudio: return await lmStudio(port) ?? offline
        case .mlxStudio: return await mlxStudio(port) ?? offline
        case .comfy: return await comfy(port) ?? offline
        }
    }

    private func splash(_ port: Int) async -> ServerReading? {
        async let statusData = http.json(port, "/status")
        async let gateData = http.json(port, "/gate")
        let gate = await gateData ?? [:]
        let transitioning = gate["splash_transition"] as? Bool == true
        let problem = gate.text("splash_problem").map { _ in tr("모델 전환에 실패했어요.") }
        if transitioning {
            return ServerReading(id: .splash, detail: tr("서버를 전환하고 있어요."), activity: .loading, transitioning: true)
        }
        guard let status = await statusData else {
            guard gate["cache_sleep"] as? Bool == true else { return nil }
            return ServerReading(id: .splash, detail: tr("모델 서버에 연결할 수 없어요."), activity: .offline, problem: problem, upstreamUnavailable: true)
        }
        if status["empty"] as? Bool == true {
            return ServerReading(id: .splash, detail: tr("켜짐 · 올라간 모델 없음"), activity: .empty, bytes: 0, gpuModels: [])
        }
        guard let model = status.object("instance").text("model"),
              let instance = status.object("instance").text("id") else { return nil }
        let weights = status.object("weights")
        let active = gate.countValues("active")
        let queued = gate.countValues("waiting")
        let native = status.objects("active_requests")
        let scheduler = status.object("scheduler")
        let nativeBusy = !native.isEmpty || (status.object("frontend").int("active") ?? 0) > 0 ||
            (status.object("frontend").int("waiting") ?? 0) > 0 ||
            (status.object("admission").int("waiting") ?? 0) > 0 ||
            ["queued", "prefilling", "decoding", "waiting_resources", "waiting_prefix", "waiting_mask"]
                .contains { (scheduler.int($0) ?? 0) > 0 }
        let activity: Activity
        if weights["restoring"] as? Bool == true { activity = .loading }
        else if (active ?? 0) > 0 || nativeBusy { activity = .working }
        else if (queued ?? 0) > 0 { activity = .queued }
        else if weights["released"] as? Bool == true { activity = .unloaded }
        else if weights["released"] as? Bool == false && status["ready"] as? Bool == true &&
            status["active_requests"] is [[String: Any]] && (active != nil || port != Provider.splash.defaultPort) {
            activity = .idle
        } else { activity = .unknown }
        let bytes = status.object("memory_actual").int("current_bytes").flatMap { UInt64(exactly: $0) }
        let kv = status.object("kv")
        let kvBytes = kv.int("active_bytes").flatMap { UInt64(exactly: $0) }
        let idleTime = weights.int("idle_release_seconds")
        let note: String
        let hasCache = (kv.int("pages_cache") ?? 0) > 0
        let sleeping = status["sleeping"] as? Bool == true
        if status["paused"] as? Bool == true {
            note = tr("서버를 껐어요. 서버 관리에서 다시 켤 수 있어요.")
        } else if sleeping {
            note = tr("캐시를 비웠어요. 다음 요청에서 다시 준비해요.")
        } else if activity == .unloaded {
            note = hasCache ? tr("모델은 내려갔어요. 대화 캐시가 램에 남아 있어요.") :
                tr("모델은 내려갔어요. 서버는 다음 요청을 기다려요.")
        } else {
            note = idleTime.map { tr("유휴 \($0)초 후 자동으로 내려감") } ?? tr("공유 모델")
        }
        let canSleep = activity == .unloaded && hasCache && active == 0 && queued == 0 &&
            gate["cache_sleep"] as? Bool == true && status.object("transport")["status_stale"] as? Bool == false
        let modelRow = WorkRow(id: instance, title: model, detail: note, activity: activity,
            control: canSleep ? .sleepSplash(instance, port) : activity == .idle ? .release(.splash, instance, port) : nil,
            bulk: activity == .idle)
        let slots = gate.object("limit")
        let detail = active.flatMap { a in queued.map { tr("슬롯 \(a)/\(slots.values.compactMap { $0 as? Int }.reduce(0,+)) 사용 · \($0)개 대기") } }
            ?? tr("엔진 상태")
        var jobs: [WorkRow] = []
        let uploaded = gate.objects("jobs")
        for role in ["user", "bot"] {
            let label = role == "user" ? tr("개인") : tr("봇")
            let roleJobs = uploaded.filter { $0.text("role") == role }
            if gate["management"] as? Int == 1, let count = slots.int(role) {
                for slot in 1...max(1, min(count, 20)) {
                    if let job = roleJobs.first(where: { $0.int("slot") == slot }) {
                        jobs.append(splashJob(job, label: "\(label) \(slot)", port: port))
                    } else if count > 0 {
                        jobs.append(WorkRow(id: "\(role)-\(slot)", title: "\(label) \(slot)", activity: .empty))
                    }
                }
                jobs += roleJobs.filter { $0.int("slot") == nil }.map { splashJob($0, label: tr("\(label) 대기"), port: port) }
            } else if let count = slots.int(role) {
                let a = gate.object("active").int(role) ?? 0
                let q = gate.object("waiting").int(role) ?? 0
                jobs.append(WorkRow(id: role, title: tr("\(label) \(a)/\(count)칸"), detail: tr("대기 \(q)개 · 요청별 연결 필요"),
                    activity: a > 0 ? .working : q > 0 ? .queued : .empty))
            }
        }
        if !native.isEmpty && (uploaded.isEmpty || native.count > uploaded.filter({ $0.int("slot") != nil }).count) {
            jobs.append(WorkRow(id: "splash-engine", title: tr("엔진 작업 \(native.count)개"), detail: tr("사용 중인 대화 캐시"), activity: .working, bytes: kvBytes))
        }
        let recent = gate.objects("recent_jobs").filter {
            $0.text("model")?.replacingOccurrences(of: "local/", with: "") == model.replacingOccurrences(of: "local/", with: "")
        }.prefix(3).map { splashJob($0, label: "", port: port) }
        var visibleModel = modelRow
        if !jobs.contains(where: { $0.activity != .empty }), let last = recent.first {
            visibleModel.detail += tr(" · 마지막 사용: ") + last.title
            if let title = last.conversationTitle { visibleModel.detail += " · " + title }
        }
        let resident = weights["released"] as? Bool
        let stale = status.object("transport")["status_stale"] as? Bool == true
        let gpuModels = stale ? nil : resident.map { [GPUModelReading(id: model, title: model, resident: !$0)] }
        let generationObserved = !stale &&
            ["prefilling", "decoding"].contains { (scheduler.int($0) ?? 0) > 0 }
        let confirmations = (gate["recent_jobs"] as? [[String: Any]])?.compactMap {
            $0.text("state") == "finished" ? $0.text("id") : nil
        }
        return ServerReading(id: .splash, detail: status["paused"] as? Bool == true ? tr("서버 꺼짐 · 수동으로 다시 켜기") : sleeping ? tr("캐시 비움 · 다음 요청에서 준비") : detail,
                             activity: activity, bytes: bytes, models: [visibleModel], jobs: jobs, recentJobs: Array(recent),
                             paused: status["paused"] as? Bool == true, gpuModels: gpuModels, problem: problem,
                             generationObserved: generationObserved, confirmedGenerationIDs: confirmations)
    }

    func splashJob(_ item: [String: Any], label: String, port: Int) -> WorkRow {
        let id = item.text("id") ?? UUID().uuidString
        let session = item.text("session").flatMap { $0.isEmpty ? nil : $0 }
        let profile = item.text("profile").flatMap { $0.isEmpty ? nil : $0 }
        let scope = item.text("scope") ?? "profiles"
        let linked = profile != nil && session != nil
        let client = item.text("client").flatMap { $0.isEmpty || $0 == "로컬 요청" ? nil : $0 } ?? (linked ? "Hermes" : tr("요청한 앱 미확인"))
        let owner = profile.map { HermesConversation.profileName($0) }
        let seconds = item.int("seconds").map { tr("\($0)초") }
        let recent = item.text("state") == "finished"
        let state: Activity = recent ? .idle : item.text("state") == "stopping" ? .stopping :
            item.int("slot") == nil ? .queued : .working
        var note: String? = nil
        if !linked { note = tr("앱·대화방 연결 정보가 없어요. 중단 전에 확인해 주세요.") }
        else if item.text("attribution") == "message_match" { note = tr("최근 대화 기록과 일치해 연결했어요.") }
        let origin = [client, owner, item.text("source") == "cron" ? tr("자동 작업") : nil, recent ? nil : label]
            .compactMap { $0 }.joined(separator: " · ")
        return WorkRow(id: id, title: origin,
            detail: [item.text("model"), session.map { tr("세션 \(String($0.prefix(24)))") }, seconds].compactMap { $0 }.joined(separator: "  ·  "),
            activity: state, control: recent || state == .stopping ? nil : .cancelSplash(id, port),
            observedModels: [item.text("model")].compactMap { $0 },
            conversationTitle: HermesConversation.preview(profile: profile, session: session, scope: scope),
            sessionIdentifier: session, attributionNote: note)
    }

    private func mlxServe(_ port: Int) async -> ServerReading? {
        async let loadedData = http.json(port, "/api/ps")
        async let metricsData = http.json(port, "/metrics.json")
        async let loadingData = http.json(port, "/v1/load-progress")
        async let catalogData = http.json(port, "/v1/models")
        guard let loaded = await loadedData, loaded["models"] is [[String: Any]] else { return nil }
        let gauges = await metricsData?.object("gauges") ?? [:]
        let active = gauges.int("requests_running")
        let queued = gauges.int("requests_waiting")
        let loading = await loadingData?["loading"] as? [[String: Any]]
        let catalog = await catalogData?.objects("data") ?? []
        let state: Activity = (active ?? 0) > 0 ? .working : (queued ?? 0) > 0 ? .queued :
            loading?.isEmpty == false ? .loading : (active == 0 && queued == 0 && loading?.isEmpty == true) ? .idle : .unknown
        let total = (gauges["memory_mb"] as? Double).flatMap { UInt64(exactly: ($0 * 1_048_576).rounded()) }
        let models: [WorkRow] = loaded.objects("models").compactMap { row in
            guard let id = row.text("model") ?? row.text("name") else { return nil }
            let bytes = row.int("size_vram").flatMap { UInt64(exactly: $0) }.flatMap { $0 > 0 ? $0 : nil }
            let capabilities = catalog.first { $0.text("id") == id }?["capabilities"] as? [String] ?? []
            let labels = ["chat": tr("대화"), "image": tr("이미지"), "video": tr("영상"), "music": tr("음악"), "audio": tr("음성"), "3d": "3D"]
            let kinds: [(String, AIWorkKind)] = [("video", .video), ("image", .image), ("music", .audio), ("audio", .audio), ("chat", .chat)]
            let kind = kinds.first { capabilities.contains($0.0) }?.1
            let types = capabilities.compactMap { labels[$0] }.joined(separator: " · ")
            let detail = types.isEmpty ? tr("서버에 올라온 모델") : types + tr(" 모델")
            let modelState: Activity = modelsShareActivity(loaded.objects("models").count, state: state)
            return WorkRow(id: id, title: id, detail: detail, activity: modelState, bytes: bytes,
                control: [.idle, .unknown].contains(state) ? .release(.mlxServe, id, port) : nil, bulk: state == .idle, workKind: kind)
        }
        var jobs: [WorkRow] = []
        if let active, active > 0 {
            jobs.append(WorkRow(id: "mlx-run", title: tr("MLX-Serve 작업 \(active)개"), detail: models.count == 1 ? models[0].title : tr("서버가 제공하는 전체 작업 수"), activity: .working))
        }
        if let queued, queued > 0 {
            jobs.append(WorkRow(id: "mlx-queue", title: tr("MLX-Serve 대기 \(queued)개"), activity: .queued))
        }
        let loadedIDs = Set(models.map(\.id))
        let availableIDs = Set(catalog.compactMap { row -> String? in
            guard row.text("state") != "remote", row.text("provider") == nil else { return nil }
            return row.text("id")
        })
        let gpuModels = loadedIDs.union(availableIDs).sorted().map {
            GPUModelReading(id: $0, title: $0, resident: loadedIDs.contains($0))
        }
        return ServerReading(id: .mlxServe, detail: tr("모델 \(models.count)개 · 포트 \(port)"),
            activity: models.isEmpty && jobs.isEmpty && state == .idle ? .empty : state, bytes: total, models: models, jobs: jobs,
            gpuModels: loaded.objects("models").count == models.count ? gpuModels : nil)
    }

    private func modelsShareActivity(_ count: Int, state: Activity) -> Activity {
        if count > 1 && [.working, .queued, .loading].contains(state) { return .unknown }
        return state
    }

    private func lmStudio(_ port: Int) async -> ServerReading? {
        guard let data = await http.json(port, "/api/v1/models"), data["models"] is [[String: Any]] else { return nil }
        let models: [WorkRow] = data.objects("models").flatMap { model in
            model.objects("loaded_instances").compactMap { instance in
                guard let id = instance.text("id") else { return nil }
                return WorkRow(id: id, title: model.text("display_name") ?? id,
                    detail: tr("RAM에 올라 있음 · 작업 여부 확인 필요"), activity: .unknown, control: .release(.lmStudio, id, port),
                    observedModels: [model.text("key")].compactMap { $0 })
            }
        }
        let gpuModels = data.objects("models").compactMap { row -> GPUModelReading? in
            guard let key = row.text("key"), let instances = row["loaded_instances"] as? [[String: Any]] else { return nil }
            return GPUModelReading(id: key, title: row.text("display_name") ?? key, resident: !instances.isEmpty)
        }
        return ServerReading(id: .lmStudio, detail: tr("모델 \(models.count)개 · 포트 \(port)"),
            activity: models.isEmpty ? .empty : .unknown, models: models,
            gpuModels: gpuModels.count == data.objects("models").count ? gpuModels : nil)
    }

    private func mlxStudio(_ port: Int) async -> ServerReading? {
        guard let data = await http.json(port, "/v1/models"), data["data"] is [[String: Any]] else { return nil }
        let models = data.objects("data").compactMap { model -> WorkRow? in
            guard let id = model.text("id") else { return nil }
            return WorkRow(id: id, title: id, detail: tr("게이트웨이에 표시된 모델 · 앱에서 내릴 수 있어요."), activity: .unknown)
        }
        return ServerReading(id: .mlxStudio, detail: tr("모델 \(models.count)개 · 포트 \(port)"),
            activity: models.isEmpty ? .empty : .unknown, models: models)
    }

    private func comfy(_ port: Int) async -> ServerReading? {
        async let versionData = http.json(port, "/system_stats")
        guard let data = await http.json(port, "/queue"), let running = data["queue_running"] as? [[Any]],
              let pending = data["queue_pending"] as? [[Any]] else { return nil }
        let system = await versionData?.object("system") ?? [:]
        let version = system.text("comfyui_version") ?? ""
        let parts = version.split(separator: ".").prefix(3).compactMap { Int($0.prefix(while: { $0.isNumber })) }
        let canInterrupt = parts.count == 3 && !parts.lexicographicallyPrecedes([0, 3, 60]) && running.count == 1
        let jobs = running.compactMap { comfyJob($0, running: true, stoppable: canInterrupt, port: port) } +
            pending.prefix(50).compactMap { comfyJob($0, running: false, stoppable: true, port: port) }
        let state: Activity = !running.isEmpty ? .working : !pending.isEmpty ? .queued : .idle
        let cacheID = "comfy-cache"
        let control = WorkRow(id: cacheID, title: tr("ComfyUI 모델과 캐시"),
            detail: tr("공식 API는 캐시에 남은 모델을 한꺼번에 내려요."), activity: state,
            control: state == .idle ? .release(.comfy, cacheID, port) : nil, bulk: state == .idle)
        let entryPoint = version.isEmpty ? nil : (system["argv"] as? [String])?.first
        return ServerReading(id: .comfy, detail: tr("작업 \(running.count)개 · 대기 \(pending.count)개"),
            activity: state, models: [control], jobs: jobs, comfyEntryPoint: entryPoint)
    }

    func comfyIsIdle(port: Int) async -> Bool {
        guard let queue = await http.json(port, "/queue"),
              let running = queue["queue_running"] as? [[Any]],
              let pending = queue["queue_pending"] as? [[Any]] else { return false }
        return running.isEmpty && pending.isEmpty
    }

    private func comfyJob(_ item: [Any], running: Bool, stoppable: Bool, port: Int) -> WorkRow? {
        guard item.count >= 3, let id = item[1] as? String else { return nil }
        let nodes = (item[2] as? [String: [String: Any]] ?? [:]).values
        let classes = nodes.compactMap { $0.text("class_type")?.lowercased() }
        let kind: AIWorkKind? = classes.contains { $0.contains("video") || $0.contains("animate") } ? .video :
            classes.contains { $0.contains("image") } ? .image : nil
        let media = kind == .video ? tr("영상 작업") : kind == .image ? tr("이미지 작업") : tr("워크플로")
        let modelKeys: Set<String> = ["ckpt_name", "unet_name", "vae_name", "lora_name", "clip_name", "clip_name1",
            "clip_name2", "model_name", "control_net_name", "style_model_name", "upscale_model"]
        let names = Set(nodes.flatMap { note in
            note.object("inputs").compactMap { key, value -> String? in
                guard modelKeys.contains(key), let name = value as? String else { return nil }
                return URL(fileURLWithPath: name).lastPathComponent
            }
        }).sorted().prefix(6)
        let number = item[0] as? Int
        let extras = item.count > 3 ? item[3] as? [String: Any] ?? [:] : [:]
        let workflow = extras.text("workflow_name") ?? extras.object("extra_pnginfo").object("workflow").text("title")
        let title = workflow.map { "\(media) · \(String($0.prefix(80)))" } ?? number.map { "\(media) #\($0)" } ?? media
        return WorkRow(id: id, title: title,
            detail: names.isEmpty ? tr("작업 \(id.prefix(8))") : names.joined(separator: " · "),
            activity: running ? .working : .queued, control: stoppable ? .cancelComfy(id, running, port) : nil,
            observedModels: Array(names), workKind: kind)
    }

    func perform(_ action: Control, bulk: Bool = false, requireEffect: Bool = false,
                 maySubmit: @Sendable () async -> Bool = { true }) async throws -> String {
        switch action {
        case .sleepSplash(let id, let port):
            let fresh = await read(.splash, port: port)
            guard Provider.splash.port == port, fresh.problem == nil,
                  fresh.models.contains(where: { $0.id == id && $0.control == action }),
                  await maySubmit() else { throw LocalError.changed }
            _ = try await http.data(port, "/gate/splash/sleep", body: ["video_port": Provider.comfy.port])
            return tr("Splash 대화 캐시를 내렸어요. 다음 요청에서 다시 준비해요.")
        case .release(let provider, let id, let port):
            let fresh = await read(provider, port: port)
            guard provider.port == port, let row = fresh.models.first(where: { $0.id == id && $0.control == action }),
                  !bulk || (row.bulk && fresh.problem == nil && !fresh.transitioning) else { throw LocalError.changed }
            let path: String
            let body: [String: Any]
            switch provider {
            case .splash: path = "/v1/memory/release"; body = [:]
            case .mlxServe: path = "/v1/unload-model"; body = ["model": id]
            case .lmStudio: path = "/api/v1/models/unload"; body = ["instance_id": id]
            case .comfy: path = "/free"; body = ["unload_models": true, "free_memory": true]
            case .mlxStudio: throw LocalError.missing
            }
            guard await maySubmit() else { throw LocalError.changed }
            _ = try await http.data(port, path, body: body)
            if provider == .comfy { return tr("캐시 회수 요청을 보냈어요.") }
            let verified = await read(provider, port: port)
            if verified.activity == .offline {
                if requireEffect { throw LocalError.changed }
                return tr("서버가 요청을 받았어요. 결과 확인을 기다리는 중이에요.")
            }
            let remaining = verified.models.first(where: { $0.id == id })
            let released = remaining == nil || remaining?.activity == .unloaded
            if requireEffect && !released { throw LocalError.changed }
            return released ? tr("모델을 내렸어요.") :
                tr("서버가 요청을 받았어요. 목록에 모델이 아직 표시돼요.")
        case .cancelSplash(let id, let port):
            guard Provider.splash.port == port else { throw LocalError.changed }
            _ = try await http.data(port, "/gate/cancel", body: ["id": id])
            return tr("이 요청의 중단을 보냈어요.")
        case .cancelComfy(let id, let running, let port):
            let reading = await read(.comfy, port: port)
            guard Provider.comfy.port == port, reading.jobs.contains(where: { $0.control == action }) else { throw LocalError.changed }
            let body: [String: Any] = running ? ["prompt_id": id] : ["delete": [id]]
            _ = try await http.data(port, running ? "/interrupt" : "/queue", body: body)
            return running ? tr("이 작업의 중단을 보냈어요.") : tr("이 대기 작업의 취소를 보냈어요.")
        }
    }
}
