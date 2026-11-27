import Foundation

struct UsageHour: Codable {
    var coveredSeconds: Double = 0
    var activeSeconds: Double = 0
    var confirmedSeconds: Double = 0
    var completionCoverage: Double = 0
    var completed: Int = 0
    var peakRAM: UInt64 = 0
    var kinds: [String: Double] = [:]

    mutating func merge(_ other: Self) {
        coveredSeconds += other.coveredSeconds
        activeSeconds += other.activeSeconds
        confirmedSeconds += other.confirmedSeconds
        completionCoverage += other.completionCoverage
        completed += other.completed
        peakRAM = max(peakRAM, other.peakRAM)
        for (key, seconds) in other.kinds { kinds[key, default: 0] += seconds }
    }
}

struct UsageHistory: Codable {
    var began: Date
    var hours: [Int64: UsageHour] = [:]
    var lifetimeConfirmedSeconds: Double = 0
    var lifetimeCompleted: Int = 0

    static func hour(_ date: Date, calendar: Calendar = .current) -> Int64 {
        let start = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return Int64(start.timeIntervalSince1970)
    }

    mutating func trim(now: Date) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -400, to: now) ?? now
        let boundary = Self.hour(cutoff)
        if let oldest = hours.keys.min(), oldest < boundary {
            hours = hours.filter { $0.key >= boundary }
        }
    }

    mutating func recordInterval(from origin: Date, to end: Date, kinds: Set<AIWorkKind>, confirmed: Bool = false, completionSource: Bool = false) {
        var start = origin
        let calendar = Calendar.current
        while start < end {
            guard let hour = calendar.dateInterval(of: .hour, for: start) else { return }
            let stop = min(hour.end, end)
            let seconds = stop.timeIntervalSince(start)
            guard seconds > 0 else { return }
            let key = Int64(hour.start.timeIntervalSince1970)
            if confirmed {
                hours[key, default: UsageHour()].confirmedSeconds += seconds
                lifetimeConfirmedSeconds += seconds
            } else {
                hours[key, default: UsageHour()].coveredSeconds += seconds
                if completionSource { hours[key, default: UsageHour()].completionCoverage += seconds }
                if !kinds.isEmpty { hours[key, default: UsageHour()].activeSeconds += seconds }
                for kind in kinds {
                    hours[key, default: UsageHour()].kinds[kind.rawValue, default: 0] += seconds
                }
            }
            start = stop
        }
    }

    func summarize(_ interval: DateInterval) -> UsageHour {
        var result = UsageHour()
        for (key, value) in hours {
            let date = Date(timeIntervalSince1970: Double(key))
            if date >= interval.start && date < interval.end { result.merge(value) }
        }
        return result
    }

    func score(in interval: DateInterval, now: Date = .now, minutesPerDay: Int = 30) -> Int? {
        let calendar = Calendar.current
        let end = min(interval.end, now)
        let start = max(interval.start, calendar.startOfDay(for: began))
        guard start < end else { return nil }
        var day = calendar.startOfDay(for: start)
        var includedDays = 0
        while day < end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let coverage = summarize(DateInterval(start: day, end: min(next, end))).completionCoverage
            // A missing day is not proof that the Mac sat idle.
            guard coverage >= 900 else { return nil }
            includedDays += 1
            day = next
        }
        let success = summarize(DateInterval(start: start, end: end)).confirmedSeconds
        let target = Double(max(minutesPerDay, 1)) * 60 * Double(includedDays)
        return Int(min(100, max(0, success / target * 100)).rounded())
    }
}

struct UsageRecorder {
    private struct Observation {
        let date: Date
        let kinds: Set<AIWorkKind>
        let generating: Set<String>
        let completionSource: Bool
    }

    private struct Pending {
        let start: Date
        let end: Date
        let owners: Set<String>
    }

    private var previous: Observation?
    private var pending: [Pending] = []
    private var trimmedDay: String?
    private var seenCompletions: [String: Date]? = nil

    mutating func observe(_ sample: AIActivitySample, in history: inout UsageHistory) {
        guard let memory = sample.ram else { return }
        let day = History.day(sample.date)
        if trimmedDay != day {
            history.trim(now: sample.date)
            trimmedDay = day
        }
        let key = UsageHistory.hour(sample.date)
        history.hours[key, default: UsageHour()].peakRAM = max(history.hours[key]?.peakRAM ?? 0, memory.used)

        let splash = sample.servers.first { $0.id == .splash }
        let completionSource = splash?.confirmedGenerationIDs != nil
        let generating = Set(splash?.generationObserved == true ?
            splash?.jobs.filter { $0.activity == .working && Self.requestID($0.id) }.map(\.id) ?? [] : [])
        let kinds = Set(sample.work.filter { row in
            guard row.activity == .working else { return false }
            return !row.id.hasPrefix("splash:") || splash?.generationObserved == true
        }.map(\.kind))
        if let previous {
            let elapsed = sample.date.timeIntervalSince(previous.date)
            if elapsed > 0 && elapsed <= AIActivityHistory.maximumGap {
                history.recordInterval(from: previous.date, to: sample.date, kinds: previous.kinds.intersection(kinds),
                                       completionSource: completionSource && previous.completionSource)
                let owners = previous.generating.intersection(generating)
                if !owners.isEmpty { pending.append(Pending(start: previous.date, end: sample.date, owners: owners)) }
            }
        }
        previous = Observation(date: sample.date, kinds: kinds, generating: generating, completionSource: completionSource)

        let cutoff = sample.date.addingTimeInterval(-3600)
        pending.removeAll { $0.end < cutoff }
        guard let completed = splash?.confirmedGenerationIDs else { return }
        let ids = completed.filter(Self.requestID)
        guard var seen = seenCompletions else {
            seenCompletions = Dictionary(ids.map { ($0, sample.date) }, uniquingKeysWith: { first, _ in first })
            return
        }
        seen = seen.filter { $0.value >= cutoff }
        var added = Set<String>()
        for id in ids where seen[id] == nil {
            seen[id] = sample.date
            added.insert(id)
        }
        seenCompletions = seen
        guard !added.isEmpty else { return }
        history.hours[key, default: UsageHour()].completed += added.count
        history.lifetimeCompleted += added.count
        pending.removeAll { interval in
            guard !interval.owners.isDisjoint(with: added) else { return false }
            history.recordInterval(from: interval.start, to: interval.end, kinds: [], confirmed: true)
            return true
        }
    }

    private static func requestID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
