import AppKit
import Darwin
import SwiftUI

enum ManagementError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

extension Provider {
    var applicationURL: URL? {
        let candidates: [String]
        switch self {
        case .splash: candidates = ["Splash 한국어", "Splash"]
        case .mlxServe: candidates = ["MLX-Serve"]
        case .lmStudio: candidates = ["LM Studio"]
        case .mlxStudio: candidates = ["MLX Studio", "MLX-Studio"]
        case .comfy: candidates = ["ComfyUI"]
        }
        return candidates.map { URL(fileURLWithPath: "/Applications/" + $0 + ".app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var supportsEmptyReset: Bool { self != .mlxStudio }

    var availableOnDisk: Bool {
        if self == .comfy { return FileManager.default.isExecutableFile(atPath: ServerTools.comfyRoot.appendingPathComponent(".venv/bin/python").path) }
        return applicationURL != nil
    }

    var fallbackSymbol: String { self == .comfy ? "photo.stack.fill" : "cpu.fill" }
    var identityColor: Color {
        switch self {
        case .splash: .cyan
        case .mlxServe: .purple
        case .lmStudio: .indigo
        case .mlxStudio: .teal
        case .comfy: .orange
        }
    }
}

@MainActor private enum ProviderImages {
    static var images: [Provider: NSImage] = [:]
    static func icon(_ provider: Provider) -> NSImage? {
        if let image = images[provider] { return image }
        var application = provider.applicationURL
        if application == nil, provider == .comfy {
            let desktop = URL(fileURLWithPath: "/Applications/Comfy Desktop.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: desktop.path) { application = desktop }
        }
        guard let url = application else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        images[provider] = image
        return image
    }
}

@MainActor struct ProviderIcon: View {
    let provider: Provider
    var size: CGFloat = 28
    var body: some View {
        Group {
            if let icon = ProviderImages.icon(provider) {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: provider.fallbackSymbol).resizable().scaledToFit().padding(size * 0.18)
                    .foregroundStyle(provider.identityColor)
                    .background(provider.identityColor.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.22))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct ServerProcess: Sendable {
    let pid: Int32
    let started: UInt64
    let microseconds: UInt64

    static func find(_ provider: Provider, port: Int) -> Self? {
        guard let pid = MacMemory.listeningProcess(port: port), let app = provider.applicationURL,
              let arguments = MacMemory.processArguments(pid), let path = arguments.first,
              path.hasPrefix(app.path + "/Contents/") else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return nil }
        return Self(pid: pid, started: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    func stop() -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid(),
              info.pbi_start_tvsec == started, info.pbi_start_tvusec == microseconds else { return false }
        return kill(pid, SIGTERM) == 0
    }
}

actor ServerTools {
    static let comfyRoot = ModelLibrary.home.appendingPathComponent("Documents/ComfyUI")
    static let lms = ModelLibrary.home.appendingPathComponent(".lmstudio/bin/lms")
    private var children: [Provider: Process] = [:]
    private let http = LocalHTTP()

    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 120, outputLimit: Int = 65_536) async throws -> String {
        try await Task.detached(priority: .utility) {
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("ram-command-" + UUID().uuidString)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: log) }
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline && !Task.isCancelled { try await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning {
                process.terminate()
                throw ManagementError.message("서버 응답을 기다리는 시간이 길어졌어요. 서버 상태와 로그를 확인해 주세요.")
            }
            let input = try FileHandle(forReadingFrom: log)
            defer { try? input.close() }
            let data = try input.read(upToCount: outputLimit) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else { throw ManagementError.message("서버 요청을 완료하지 못했어요. " + String(text.suffix(700))) }
            return text
        }.value
    }

    func start(_ provider: Provider) async throws {
        let port = provider.port
        if provider == .splash {
            if await http.json(port, "/gate") == nil {
                let label = "local.splash.hermes-session-gate"
                let file = ModelLibrary.home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist")
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw ManagementError.message("Splash 연결 설정을 찾지 못했어요.")
                }
                let domain = "gui/\(getuid())"
                let executable = URL(fileURLWithPath: "/bin/launchctl")
                _ = try? await Self.run(executable, ["bootstrap", domain, file.path], timeout: 10)
                _ = try await Self.run(executable, ["kickstart", domain + "/" + label], timeout: 10)
                let deadline = ContinuousClock.now + .seconds(8)
                while await http.json(port, "/gate") == nil {
                    guard ContinuousClock.now < deadline else {
                        throw ManagementError.message("Splash 연결 프로그램이 응답하지 않아요.")
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            _ = try await http.data(port, "/gate/splash/wake", body: [:], timeout: 150)
        } else if provider == .lmStudio {
            _ = try await Self.run(Self.lms, ["server", "start", "--port", String(port), "--bind", "127.0.0.1"])
        } else if provider == .mlxStudio {
            guard let app = provider.applicationURL else { throw ManagementError.message("MLX Studio 앱을 찾지 못했어요.") }
            _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/open"), [app.path])
        } else {
            if await Task.detached(operation: { MacMemory.listeningProcess(port: port) != nil }).value { return }
            if children[provider]?.isRunning == true { return }
            if provider == .comfy, try await startManagedComfy(port: port) {
                try await waitForServer(provider, port: port)
                return
            }
            let process = Process()
            if provider == .comfy {
                process.executableURL = Self.comfyRoot.appendingPathComponent(".venv/bin/python")
                process.arguments = ["main.py", "--listen", "127.0.0.1", "--port", String(port), "--offline", "--reserve-vram", "6", "--disable-auto-launch"]
                process.currentDirectoryURL = Self.comfyRoot
            } else {
                guard let app = provider.applicationURL else { throw ManagementError.message("MLX-Serve 앱을 찾지 못했어요.") }
                process.executableURL = app.appendingPathComponent("Contents/MacOS/mlx-serve")
                process.arguments = ["serve", "--host", "127.0.0.1", "--port", String(port)]
            }
            let folder = ModelLibrary.home.appendingPathComponent("Library/Logs/로컬 램 크루지_EX")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let log = folder.appendingPathComponent(provider.rawValue + ".log")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            try? handle.close()
            children[provider] = process
        }
        try await waitForServer(provider, port: port)
    }

    private func startManagedComfy(port: Int) async throws -> Bool {
        let label = "org.ramcruzy.comfy-engine"
        let agent = ModelLibrary.home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist")
        guard let data = try? Data(contentsOf: agent),
              let config = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              config["Label"] as? String == label,
              let args = config["ProgramArguments"] as? [String],
              args.first == Self.comfyRoot.appendingPathComponent(".venv/bin/python").path,
              let index = args.firstIndex(of: "--port"), args.indices.contains(index + 1), args[index + 1] == String(port) else {
            return false
        }
        let executable = URL(fileURLWithPath: "/bin/launchctl")
        let domain = "gui/\(getuid())"
        if (try? await Self.run(executable, ["print", domain + "/" + label], timeout: 10)) == nil {
            _ = try await Self.run(executable, ["bootstrap", domain, agent.path], timeout: 10)
        }
        _ = try await Self.run(executable, ["kickstart", domain + "/" + label], timeout: 10)
        return true
    }

    private func waitForServer(_ provider: Provider, port: Int) async throws {
        let providers = Providers()
        for _ in 0..<60 {
            guard provider.port == port else { throw LocalError.changed }
            let reading = await providers.read(provider, port: port)
            if reading.activity != .offline && !reading.paused && !reading.transitioning { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ManagementError.message("시작을 요청했어요. \(provider.title)에서 준비 상태를 확인해 주세요.")
    }

    func reset(_ provider: Provider) async throws {
        let port = provider.port
        let providers = Providers()
        let state = await providers.read(provider, port: port)
        guard provider.supportsEmptyReset, provider.port == port,
              ![.working, .queued, .loading, .stopping].contains(state.activity) else {
            throw ManagementError.message("서버 상태가 바뀌었어요. 진행·대기 작업이 끝난 뒤 다시 시도해 주세요.")
        }
        switch provider {
        case .splash:
            guard let gate = await http.json(port, "/gate"), (gate["controls_version"] as? Int ?? 0) >= 6 else {
                throw ManagementError.message("Splash 연결 프로그램에 응답이 없어요. 연결을 먼저 확인해 주세요.")
            }
            _ = try await http.data(port, "/gate/splash/reset", body: ["video_port": Provider.comfy.port], timeout: 25)
        case .mlxServe:
            guard state.activity == .idle || state.activity == .empty else { throw LocalError.changed }
            for model in state.models {
                _ = try await providers.perform(.release(.mlxServe, model.id, port), bulk: true, requireEffect: true)
            }
        case .lmStudio:
            if state.activity == .offline { try await start(provider) }
            _ = try await Self.run(Self.lms, ["unload", "--all"])
        case .comfy:
            guard state.comfyEntryPoint != nil, state.activity == .idle,
                  let engine = await Task.detached(operation: { () -> ComfyProcess? in
                      guard let pid = MacMemory.listeningProcess(port: port) else { return nil }
                      let entry = Self.comfyRoot.appendingPathComponent("main.py").path
                      return ComfyProcess.find(port: port, pid: pid, entryPoint: entry)
                  }).value,
                  await providers.comfyIsIdle(port: port), engine.ownsPort, engine.requestStop(SIGINT) else {
                throw ManagementError.message("이 Mac에서 관리하는 ComfyUI의 실행·대기 상태를 확인해 주세요.")
            }
            let deadline = ContinuousClock.now + .seconds(12)
            while engine.stillRunning && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(250))
            }
            guard !engine.stillRunning, provider.port == port else { throw LocalError.changed }
            try await start(provider)
            guard await providers.comfyIsIdle(port: port) else { throw LocalError.changed }
            return
        case .mlxStudio:
            throw LocalError.missing
        }
        guard provider.port == port, await providers.read(provider, port: port).activity == .empty else {
            throw ManagementError.message("서버에 올라간 모델이 없는지 확인하지 못했어요.")
        }
    }

    func stop(_ provider: Provider) async throws {
        let fresh = await Providers().read(provider)
        guard ![.working, .loading, .queued, .stopping].contains(fresh.activity) else {
            throw ManagementError.message("진행·대기 작업이 있어요. 작업이 끝나면 서버를 끌 수 있어요.")
        }
        switch provider {
        case .splash:
            _ = try await http.data(provider.port, "/gate/splash/stop", body: ["video_port": Provider.comfy.port])
        case .lmStudio:
            _ = try await Self.run(Self.lms, ["server", "stop"])
        case .comfy:
            guard let entry = fresh.comfyEntryPoint, let target = await Task.detached(operation: { () -> ComfyProcess? in
                guard let pid = MacMemory.listeningProcess(port: provider.port) else { return nil }
                return ComfyProcess.find(port: provider.port, pid: pid, entryPoint: entry)
            }).value, await Providers().comfyIsIdle(port: provider.port), target.requestStop(SIGINT) else {
                throw ManagementError.message("현재 ComfyUI 프로세스와 작업 상태를 다시 확인해 주세요.")
            }
        case .mlxServe, .mlxStudio:
            guard let target = await Task.detached(operation: { ServerProcess.find(provider, port: provider.port) }).value else {
                throw ManagementError.message("이 앱이 확인한 로컬 서버 프로세스를 찾지 못했어요.")
            }
            guard target.stop() else { throw ManagementError.message("서버 상태가 바뀌어 종료를 멈췄어요.") }
        }
        for _ in 0..<20 {
            let state = await Providers().read(provider)
            if state.activity == .offline || state.paused { children.removeValue(forKey: provider); return }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw ManagementError.message("종료를 요청했어요. 서버가 다시 시작되었거나 아직 닫히지 않았어요.")
    }

    static func lmModelKeys() async -> [String: String] {
        guard let listing = try? await run(lms, ["ls", "--json"]), let data = listing.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        return Dictionary(rows.compactMap { row -> (String, String)? in
            guard let path = row["path"] as? String, let key = row["modelKey"] as? String else { return nil }
            return (path, key)
        }, uniquingKeysWith: { first, _ in first })
    }

    func load(_ item: LocalModel) async throws {
        guard let asset = ModelFile.inspect(item.url), asset.compatibility(with: item.provider) == nil, !asset.isLoRA else {
            throw ManagementError.message("이 항목은 기본 모델과 함께 사용하거나 서버 앱에서 선택해 주세요.")
        }
        if item.provider == .comfy {
            throw ManagementError.message("ComfyUI는 워크플로를 실행할 때 모델과 로라를 올려요. 파일 연결 뒤 ComfyUI에서 해당 워크플로를 실행해 주세요.")
        }
        if item.provider == .splash {
            _ = try await http.data(item.provider.port, "/gate/splash/load", body: ["path": item.url.path, "video_port": Provider.comfy.port], timeout: 180)
        } else if item.provider == .mlxServe {
            _ = try await http.data(item.provider.port, "/v1/load-model", body: ["model": item.url.path], timeout: 180)
        } else if item.provider == .lmStudio {
            let listing = try await Self.run(Self.lms, ["ls", "--json"])
            guard let data = listing.data(using: .utf8), let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let found = rows.first(where: { ($0["path"] as? String) == item.key || ($0["path"] as? String)?.hasSuffix("/" + item.title) == true }),
                  let key = found["modelKey"] as? String ?? found["indexedModelIdentifier"] as? String else {
                throw ManagementError.message("LM Studio에서 이 모델을 아직 찾지 못했어요. 앱의 모델 목록을 새로 고침해 주세요.")
            }
            _ = try await Self.run(Self.lms, ["load", key, "--yes"], timeout: 180)
        } else { throw ManagementError.message("이 서버의 앱에서 모델을 선택해 주세요.") }
    }
}
