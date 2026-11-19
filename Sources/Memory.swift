import AppKit
import Darwin
import Foundation

struct ProcessMemory: Identifiable, Sendable {
    let id: Int32
    let title: String
    let bytes: UInt64
    let appID: String?
}

struct MemoryReading: Sendable {
    let total: UInt64
    let used: UInt64
    let wired: UInt64
    let compressed: UInt64
    let swap: UInt64
    let swapIn: UInt64
    let swapOut: UInt64
    let pressure: Int32?
    let processes: [ProcessMemory]
}

struct AppProcess: Sendable {
    let name: String
    let id: String?
}

struct ComfyProcess: Equatable, Sendable {
    let port: Int
    let pid: Int32
    private let startedAt: UInt64
    private let startMicroseconds: UInt64

    static func find(port: Int, pid: Int32, entryPoint: String) -> Self? {
        guard let process = ownedProcess(pid), let directory = MacMemory.workingDirectory(pid),
              let arguments = MacMemory.processArguments(pid), let executable = arguments.first,
              URL(fileURLWithPath: executable).lastPathComponent.lowercased().hasPrefix("python") else { return nil }
        let script = URL(fileURLWithPath: entryPoint, relativeTo: directory).standardizedFileURL
        guard script.lastPathComponent == "main.py",
              let launchScript = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }),
              URL(fileURLWithPath: launchScript, relativeTo: directory).standardizedFileURL == script else { return nil }
        let root = script.deletingLastPathComponent()
        let files = FileManager.default
        guard files.fileExists(atPath: script.path),
              files.fileExists(atPath: root.appendingPathComponent("server.py").path),
              files.fileExists(atPath: root.appendingPathComponent("comfy").path) else { return nil }
        return Self(port: port, pid: pid, startedAt: process.pbi_start_tvsec, startMicroseconds: process.pbi_start_tvusec)
    }

    var stillRunning: Bool {
        guard let process = Self.ownedProcess(pid) else { return false }
        return process.pbi_start_tvsec == startedAt && process.pbi_start_tvusec == startMicroseconds
    }

    var ownsPort: Bool { MacMemory.listeningProcess(port: port) == pid && stillRunning }

    func requestStop(_ signal: Int32) -> Bool {
        stillRunning && kill(pid, signal) == 0
    }

    private static func ownedProcess(_ pid: Int32) -> proc_bsdinfo? {
        guard pid > 1, pid != getpid() else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), info.pbi_ruid == getuid() else { return nil }
        return info
    }
}

enum MacMemory {
    static func currentPressure() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return result == 0 && [1, 2, 4].contains(level) ? level : nil
    }

    static func snapshot(apps: [Int32: AppProcess]) -> MemoryReading? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var vm = vm_statistics64()
        let capacity = MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(getpagesize())
        let wired = UInt64(vm.wire_count) * pageSize
        let compressed = UInt64(vm.compressor_page_count) * pageSize
        let used = (UInt64(vm.internal_page_count) - min(UInt64(vm.internal_page_count),
                    UInt64(vm.purgeable_count))) * pageSize + wired + compressed
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        _ = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return MemoryReading(total: ProcessInfo.processInfo.physicalMemory, used: used, wired: wired,
            compressed: compressed, swap: swap.xsu_used, swapIn: vm.swapins * pageSize,
            swapOut: vm.swapouts * pageSize, pressure: currentPressure(), processes: processes(apps: apps))
    }

    static func listeningProcess(port: Int) -> Int32? {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-t", "-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN"]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let pids = Set(String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) })
        return pids.count == 1 ? pids.first : nil
    }

    fileprivate static func workingDirectory(_ pid: Int32) -> URL? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
    }

    static func processArguments(_ pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, (5...1_048_576).contains(size) else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0, size > MemoryLayout<Int32>.size, size <= bytes.count,
              let endOfPath = bytes[MemoryLayout<Int32>.size..<size].firstIndex(of: 0) else { return nil }
        let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard (2...4096).contains(count) else { return nil }
        var start = endOfPath + 1
        while start < size && bytes[start] == 0 { start += 1 }
        var arguments: [String] = []
        while start < size && arguments.count < count {
            guard let end = bytes[start..<size].firstIndex(of: 0) else { break }
            arguments.append(String(decoding: bytes[start..<end], as: UTF8.self))
            start = end + 1
        }
        return arguments.count == count ? arguments : nil
    }

    private static func processes(apps: [Int32: AppProcess]) -> [ProcessMemory] {
        let capacity = max(512, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(max(0, min(capacity, Int(count)))).compactMap { pid in
            guard pid > 0 else { return nil }
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0, usage.ri_phys_footprint > 0 else { return nil }
            if let app = apps[pid] {
                return ProcessMemory(id: pid, title: app.name, bytes: usage.ri_phys_footprint, appID: app.id)
            }
            let length = path.withUnsafeMutableBytes {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
            }
            let executable = length > 0
                ? URL(fileURLWithPath: String(decoding: path.prefix(Int(length)).prefix(while: { $0 != 0 }), as: UTF8.self)).lastPathComponent
                : tr("프로세스 \(pid)")
            return ProcessMemory(id: pid, title: executable, bytes: usage.ri_phys_footprint, appID: nil)
        }.sorted { $0.bytes > $1.bytes }
    }
}

func ram(_ bytes: UInt64?) -> String {
    guard let bytes else { return "—" }
    if bytes == 0 { return "0 MB" }
    if bytes < 1 << 30 { return "\(max(1, Int(Double(bytes) / 1_048_576))) MB" }
    return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
}
