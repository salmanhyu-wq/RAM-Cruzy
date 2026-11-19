import AppKit
import Darwin
import Foundation
import Metal

struct GPUBoostTarget: Hashable, Identifiable {
    let provider: Provider
    let port: Int
    let modelID: String
    let title: String

    var id: Self { self }
    var label: String { provider.title + " · " + title }
}

struct GPUBoostTracking {
    let target: GPUBoostTarget
    private(set) var sawResident: Bool
    private var missingSamples = 0
    private var lastConfirmed: TimeInterval
    private let started: TimeInterval

    init(target: GPUBoostTarget, resident: Bool, now: TimeInterval) {
        self.target = target
        sawResident = resident
        lastConfirmed = now
        started = now
    }

    mutating func update(_ models: [GPUModelReading]?, at now: TimeInterval) -> String? {
        guard now >= started else { return nil }
        if let models {
            lastConfirmed = now
            if models.contains(where: { $0.id == target.modelID && $0.resident }) {
                sawResident = true
                missingSamples = 0
            } else if sawResident {
                missingSamples += 1
                if missingSamples >= 2 { return tr("선택한 모델이 램에서 내려갔어요.") }
            }
        } else {
            missingSamples = 0
            if now - lastConfirmed >= 45 { return tr("서버에서 모델 상태를 확인할 수 없어요.") }
        }
        if !sawResident && now - started >= 300 { return tr("5분 동안 모델이 램에 올라오지 않았어요.") }
        return nil
    }
}

struct GPUBoostBudget {
    static let mib: UInt64 = 1_048_576
    static var totalMiB: Int { Int(ProcessInfo.processInfo.physicalMemory / mib) }
    static var minReserveGiB: Int { max(4, (totalMiB / 8 + 1023) / 1024) }
    static var reserveChoices: [Int] {
        let minimum = minReserveGiB
        return Array(Set([minimum, 8, 12, 16, 24, 32, 48, 64].filter { $0 >= minimum && $0 * 1024 < totalMiB })).sorted()
    }

    static func currentLimit() -> Int? {
        var limit: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("iogpu.wired_limit_mb", &limit, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size, limit >= 0 else { return nil }
        return Int(limit)
    }

    static func targetLimit(reserveGiB: Int) -> Int { totalMiB - reserveGiB * 1024 }

    static func enabledLimit(reserveGiB: Int) throws -> Int {
        guard #available(macOS 15, *), let previous = currentLimit(),
              let device = MTLCreateSystemDefaultDevice() else {
            throw ManagementError.message(tr("이 Mac에서 GPU 메모리 상한을 바꿀 수 있는지 확인하지 못했어요."))
        }
        let target = targetLimit(reserveGiB: reserveGiB)
        let live = previous == 0 ? Int(device.recommendedMaxWorkingSetSize / mib) : previous
        guard reserveChoices.contains(reserveGiB), target > live, target > 0 else {
            throw ManagementError.message(tr("지금 GPU 메모리 상한이 이미 이 값 이상이에요. 설정을 바꾸지 않았어요."))
        }
        return target
    }
}

struct IdleProgram: Identifiable {
    struct ID: Hashable {
        let pid: pid_t
        let launched: Date
    }
    let id: ID
    let bundle: String
    let title: String
    let bytes: UInt64
    let lastUsed: TimeInterval

    var idleMinutes: Int { max(0, Int((ProcessInfo.processInfo.systemUptime - lastUsed) / 60)) }

    static func newestFirst(_ left: Self, _ right: Self) -> Bool {
        if left.lastUsed != right.lastUsed { return left.lastUsed > right.lastUsed }
        let titles = left.title.localizedStandardCompare(right.title)
        if titles != .orderedSame { return titles == .orderedAscending }
        return left.id.pid < right.id.pid
    }
}

@MainActor final class IdleProgramHistory {
    private let workspace = NSWorkspace.shared
    private var lastUsed: [IdleProgram.ID: TimeInterval] = [:]
    private var observers: [NSObjectProtocol] = []
    private static let protectedBundles: Set<String> = [
        "ai.inco.splash", "com.dalcu.mlx-core", "ai.elementlabs.lmstudio",
        "com.nousresearch.hermes-bundled", "com.openai.codex", "com.openai.chat",
        "com.anthropic.claudefordesktop",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.google.Chrome", "com.citrolabs.ego.lite", "org.mozilla.firefox", "com.microsoft.edgemac",
        "com.docker.docker", "com.google.drivefs", "com.microsoft.OneDrive"
    ]

    init() {
        let names = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification]
        for name in names {
            observers.append(workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] event in
                guard let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.markUsed(app) }
            })
        }
        observe()
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func identity(_ app: NSRunningApplication) -> IdleProgram.ID? {
        app.launchDate.map { .init(pid: app.processIdentifier, launched: $0) }
    }

    private func markUsed(_ app: NSRunningApplication) {
        if let id = identity(app) { lastUsed[id] = ProcessInfo.processInfo.systemUptime }
    }

    func observe() {
        let ids = Set(workspace.runningApplications.compactMap(identity))
        let now = ProcessInfo.processInfo.systemUptime
        lastUsed = lastUsed.filter { ids.contains($0.key) }
        for id in ids where lastUsed[id] == nil { lastUsed[id] = now }
        if let app = workspace.frontmostApplication { markUsed(app) }
    }

    private func candidateLastUse(_ app: NSRunningApplication, minutes: Int, protectedPIDs: Set<pid_t>,
                                  excludedBundles: Set<String>) -> TimeInterval? {
        guard app.processIdentifier != getpid(), !app.isActive, !app.isTerminated,
              !protectedPIDs.contains(app.processIdentifier), app.activationPolicy == .regular,
              let url = app.bundleURL, !url.standardizedFileURL.path.hasPrefix("/System/"),
              let bundle = app.bundleIdentifier, !Self.protectedBundles.contains(bundle),
              !bundle.lowercased().hasSuffix(".studio-remote"), !excludedBundles.contains(bundle),
              let id = identity(app), let last = lastUsed[id],
              ProcessInfo.processInfo.systemUptime - last >= Double(minutes * 60) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let protectedProvider = Provider.allCases.contains { provider in
            name == provider.title || name == (provider.title + " 한국어") ||
                provider.applicationURL?.standardizedFileURL.path == url.standardizedFileURL.path
        }
        return protectedProvider ? nil : last
    }

    func candidates(minutes: Int, protectedPIDs: Set<pid_t>, excludedBundles: Set<String>,
                    memory: MemoryReading?) -> [IdleProgram] {
        observe()
        let footprints = Dictionary(uniqueKeysWithValues: (memory?.processes ?? []).map { ($0.id, $0.bytes) })
        return workspace.runningApplications.compactMap { app -> IdleProgram? in
            guard let last = candidateLastUse(app, minutes: minutes, protectedPIDs: protectedPIDs, excludedBundles: excludedBundles),
                  let id = identity(app), let bundle = app.bundleIdentifier else { return nil }
            return IdleProgram(id: id, bundle: bundle, title: app.localizedName ?? bundle,
                               bytes: footprints[id.pid] ?? 0, lastUsed: last)
        }.sorted(by: IdleProgram.newestFirst)
    }

    func requestQuit(_ programs: [IdleProgram], minutes: Int, protectedPIDs: Set<pid_t>,
                     excludedBundles: Set<String>) -> [NSRunningApplication] {
        observe()
        return programs.compactMap { program in
            guard let app = NSRunningApplication(processIdentifier: program.id.pid),
                  identity(app) == program.id, app.bundleIdentifier == program.bundle,
                  candidateLastUse(app, minutes: minutes, protectedPIDs: protectedPIDs, excludedBundles: excludedBundles) != nil,
                  app.terminate() else { return nil }
            return app
        }
    }
}

/// The root helper can change only the wired limit. It restores the captured value when
/// this connection closes, including after a crash, or when the keepalive stops.
@MainActor final class GPUBoostConnection {
    private var listener: Int32 = -1
    private var peer: Int32 = -1
    private var directory: String?
    private var connected = false
    private let clock = ContinuousClock()

    deinit {
        if peer >= 0 { Darwin.close(peer) }
        if listener >= 0 { Darwin.close(listener) }
        if let directory {
            unlink(directory + "/s")
            rmdir(directory)
        }
    }

    func prepare(limit: Int) async throws {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "GPUWiredLimit"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ManagementError.message(tr("GPU 메모리 설정 도구를 찾을 수 없어요."))
        }
        let socketPath = try openListener()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", """
            on run argv
                set cmd to quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv)
                with timeout of 86400 seconds
                    do shell script cmd with administrator privileges
                end timeout
            end run
            """, helper.path, socketPath, String(getuid()), String(limit)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = clock.now + .seconds(120)
        while clock.now < deadline, process.isRunning {
            let fd = Darwin.accept(listener, nil, nil)
            if fd >= 0 {
                var uid: uid_t = 1
                var gid: gid_t = 1
                if getpeereid(fd, &uid, &gid) == 0, uid == 0, configure(fd) {
                    peer = fd
                    Darwin.close(listener)
                    listener = -1
                    switch await waitForStatus(seconds: 4) {
                    case UInt8(ascii: "P"): return
                    case let status: throw Self.failure(status)
                    }
                }
                Darwin.close(fd)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { process.terminate() }
        throw ManagementError.message(tr("관리자 권한을 받지 못했어요. 다시 시도할 때 macOS 승인 창을 확인해 주세요."))
    }

    func activate() async throws {
        guard sendByte(UInt8(ascii: "A")) else { throw Self.failure(nil) }
        let status = await waitForStatus(seconds: 4)
        guard status == UInt8(ascii: "A") else { throw Self.failure(status) }
        connected = true
    }

    func keepPrepared() -> Bool { !connected && sendByte(UInt8(ascii: "K")) }

    func keepAlive() -> Bool { connected && sendByte(UInt8(ascii: "K")) }

    func restore() async -> String {
        guard peer >= 0 else { return tr("GPU 메모리 상한 상태를 확인해 주세요.") }
        connected = false
        shutdown(peer, SHUT_WR)
        switch await waitForStatus(seconds: 70) {
        case UInt8(ascii: "R"): return tr("GPU 메모리 상한을 실행 전 값으로 돌렸어요.")
        case UInt8(ascii: "X"): return tr("다른 곳에서 바꾼 GPU 메모리 상한을 그대로 뒀어요.")
        default: return tr("GPU 메모리 상한을 원복했는지 확인하지 못했어요.")
        }
    }

    private func openListener() throws -> String {
        var pattern = Array("/tmp/airam-gpu.XXXXXX".utf8CString)
        guard let path = mkdtemp(&pattern) else { throw Self.failure(nil) }
        let folder = String(cString: path)
        directory = folder
        let socketPath = folder + "/s"
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let chars = socketPath.utf8CString
        guard chars.count <= capacity else { throw Self.failure(nil) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size - capacity + chars.count - 1)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: chars.map(UInt8.init(bitPattern:))) }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0, configure(listener) else { throw Self.failure(nil) }
        let length = socklen_t(address.sun_len)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw Self.failure(nil) }
        return socketPath
    }

    private func configure(_ fd: Int32) -> Bool {
        var noPipe: Int32 = 1
        return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private func sendByte(_ byte: UInt8) -> Bool {
        var byte = byte
        return Darwin.send(peer, &byte, 1, 0) == 1
    }

    private func waitForStatus(seconds: Int) async -> UInt8? {
        let deadline = clock.now + .seconds(seconds)
        while clock.now < deadline, !Task.isCancelled {
            var byte: UInt8 = 0
            let count = Darwin.recv(peer, &byte, 1, 0)
            if count == 1 { return byte }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func failure(_ status: UInt8?) -> ManagementError {
        switch status {
        case UInt8(ascii: "B"): return .message(tr("다른 램 쥐어짜기가 이미 켜져 있어요."))
        case UInt8(ascii: "N"): return .message(tr("지금 GPU 메모리 상한이 이미 이 값 이상이에요."))
        case UInt8(ascii: "F"): return .message(tr("변경을 마치지 못했고 GPU 메모리 상한의 원복도 확인하지 못했어요."))
        default: return .message(tr("GPU 메모리 상한을 적용할 수 없어요."))
        }
    }
}
