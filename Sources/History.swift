import Foundation
import SQLite3

struct ModelUse: Codable, Sendable, Identifiable {
    let provider: Provider
    let name: String
    var calls: Int = 0
    var observedSeconds: Double = 0
    var last: Date
    var dayOnly: Bool? = nil
    mutating func merge(_ other: ModelUse) {
        calls += other.calls
        observedSeconds += other.observedSeconds
        if other.last > last || (other.last == last && dayOnly == true && other.dayOnly != true) {
            last = other.last
            dayOnly = other.dayOnly
        }
    }
    var id: String { provider.rawValue + ":" + modelKey(name) }
}

struct SwapEvent: Codable, Identifiable {
    var id = UUID()
    let start: Date
    let end: Date
    let written: UInt64
    let read: UInt64
    let before: UInt64
    let occupied: UInt64
    let pressure: Int32?
    let work: [String]
    let processes: [String]
    var growing: [String]? = nil
    var gap: Bool { end.timeIntervalSince(start) > 24 }
}

struct SwapDay: Codable {
    var written: UInt64 = 0
    var read: UInt64 = 0
    var peak: UInt64 = 0
}

struct History: Codable {
    var started: Date = .now
    var days: [String: SwapDay] = [:]
    var events: [SwapEvent] = []
    var observed: [String: [String: ModelUse]] = [:]
    var usageStatistics: UsageHistory?
    var macValue: MacValue?
    var actualPurchasePrice: Int?

    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func cutoff(now: Date = .now) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
    }

    mutating func append(_ sample: TelemetrySample, after previous: TelemetrySample?) {
        let day = Self.day(sample.date)
        let cutoff = Self.cutoff(now: sample.date)
        let earliest = Self.day(cutoff)
        var total = days[day] ?? SwapDay()
        total.peak = max(total.peak, sample.memory.swap)
        days[day] = total
        days = days.filter { $0.key >= earliest }
        observed = observed.filter { $0.key >= earliest }
        events.removeAll { $0.end < cutoff }
        guard let previous else { return }
        let elapsed = sample.date.timeIntervalSince(previous.date)
        guard elapsed > 0 else { return }
        if elapsed <= 24 {
            let active = Set(previous.active.map(\.id))
            for var row in sample.active where active.contains(row.id) {
                let old = observed[day]?[row.id]
                row.observedSeconds = (old?.observedSeconds ?? 0) + elapsed
                observed[day, default: [:]][row.id] = row
            }
        }
        guard sample.memory.swapOut >= previous.memory.swapOut, sample.memory.swapIn >= previous.memory.swapIn else { return }
        let written = sample.memory.swapOut - previous.memory.swapOut
        let read = sample.memory.swapIn - previous.memory.swapIn
        total.written += written
        total.read += read
        days[day] = total
        // Preserve episodes with at least 1 MB I/O or a change in occupied swap.
        guard written >= 1_048_576 || read >= 1_048_576 || absDifference(sample.memory.swap, previous.memory.swap) >= 1_048_576 else { return }
        let gap = elapsed > 24
        var context = [String]()
        for work in previous.work + sample.work where !context.contains(work) { context.append(work) }
        let earlier = Dictionary(previous.memory.processes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let largeChanges = sample.memory.processes.compactMap { process -> (String, UInt64)? in
            guard let old = earlier[process.id], old.title == process.title,
                  process.bytes > old.bytes, process.bytes - old.bytes >= 67_108_864 else { return nil }
            let name = sample.processNames[process.id] ?? process.title
            return (name, process.bytes - old.bytes)
        }.sorted { $0.1 > $1.1 }.prefix(3).map { "\($0.0) +\(ram($0.1))" }
        events.append(SwapEvent(start: previous.date, end: sample.date, written: written, read: read,
            before: previous.memory.swap, occupied: sample.memory.swap, pressure: sample.memory.pressure,
            work: gap ? [] : Array(context.prefix(10)), processes: gap ? [] : sample.processes,
            growing: gap ? [] : largeChanges))
        if events.count > 700 { events.removeFirst(events.count - 700) }
    }

    var usage: [ModelUse] {
        var rows = [String: ModelUse]()
        let earliest = Self.day(Self.cutoff())
        for day in observed where day.key >= earliest {
            for (key, var row) in day.value {
                if let old = rows[key] {
                    row.merge(old)
                }
                rows[key] = row
            }
        }
        return Array(rows.values)
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI 램 관리/history-v1.json")
    }

    static func load(_ url: URL) -> History {
        guard let data = try? Data(contentsOf: url), data.count < 8_000_000,
              let history = try? JSONDecoder().decode(History.self, from: data) else { return History() }
        return history
    }

    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct TelemetrySample {
    let date: Date
    let memory: MemoryReading
    var active: [ModelUse] = []
    var work: [String] = []
    var processes: [String] = []
    var processNames: [Int32: String] = [:]
}

enum AutoRecovery {
    static let minimumInterval: TimeInterval = 120

    static func shouldRun(enabled: Bool, previous: TelemetrySample?, current: TelemetrySample,
                          lastAttempt: Date?, hasTargets: Bool, busy: Bool) -> Bool {
        guard enabled, hasTargets, !busy, let previous else { return false }
        let elapsed = current.date.timeIntervalSince(previous.date)
        guard elapsed > 0, elapsed <= 24, current.memory.swapOut > previous.memory.swapOut else { return false }
        if let lastAttempt, current.date.timeIntervalSince(lastAttempt) < minimumInterval { return false }
        return true
    }
}

func absDifference(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    max(lhs, rhs) - min(lhs, rhs)
}

enum ProviderHistory {
    static func importUsage(home: URL = ModelLibrary.home, now: Date = .now) -> [ModelUse] {
        let cutoff = History.cutoff(now: now)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        var rows: [String: ModelUse] = [:]
        func save(_ row: ModelUse) {
            if var old = rows[row.id] {
                old.merge(row)
                rows[row.id] = old
            } else { rows[row.id] = row }
        }
        let mlx = home.appendingPathComponent(".mlx-serve/usage.db")
        query(mlx, """
            SELECT model, SUM(requests), MAX(day) FROM usage_daily
            WHERE day >= '\(History.day(cutoff))' AND requests > 0 GROUP BY model LIMIT 4096
            """) { statement in
                guard let model = string(statement, 0), let day = string(statement, 2),
                      let date = dateFormatter.date(from: day) else { return }
                save(ModelUse(provider: .mlxServe, name: model, calls: Int(sqlite3_column_int64(statement, 1)), last: date, dayOnly: true))
            }
        let hermes = home.appendingPathComponent(".hermes")
        let profiles = (try? FileManager.default.contentsOfDirectory(at: hermes.appendingPathComponent("profiles"),
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var seen = Set<String>()
        for folder in [hermes] + profiles.prefix(100) {
            let db = folder.appendingPathComponent("state.db").resolvingSymlinksInPath()
            guard seen.insert(db.path).inserted else { continue }
            let timestamp = Int(cutoff.timeIntervalSince1970)
            query(db, """
                SELECT model, SUM(CASE WHEN first_seen >= \(timestamp) THEN api_call_count ELSE 0 END), MAX(last_seen)
                FROM session_model_usage
                WHERE last_seen >= \(timestamp) AND api_call_count > 0
                    AND (billing_provider = 'splash' OR billing_base_url LIKE 'http://127.0.0.1:8002/%'
                        OR billing_base_url LIKE 'http://localhost:8002/%'
                        OR billing_base_url LIKE 'http://127.0.0.1:8000/%')
                GROUP BY model LIMIT 4096
                """) { statement in
                    guard let model = string(statement, 0), !model.isEmpty else { return }
                    save(ModelUse(provider: .splash, name: model, calls: Int(sqlite3_column_int64(statement, 1)),
                        last: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))))
                }
        }
        return Array(rows.values)
    }

    private static func query(_ path: URL, _ sql: String, each: (OpaquePointer?) -> Void) {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else { return }
        sqlite3_busy_timeout(db, 60)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { each(statement) }
    }

    private static func string(_ statement: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_text(statement, i).map { String(cString: $0) }
    }
}
