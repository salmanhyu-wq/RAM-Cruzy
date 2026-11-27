import SwiftUI

private enum UsagePeriod: String, CaseIterable, Identifiable {
    case day, week, month
    var id: Self { self }

    var title: String {
        switch self {
        case .day: tr("일간")
        case .week: tr("주간")
        case .month: tr("월간")
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    var step: Calendar.Component { self == .day ? .hour : .day }
}

private struct UsageColumn: Identifiable {
    let interval: DateInterval
    let summary: UsageHour
    var id: Date { interval.start }
    var stackedSeconds: Double { summary.kinds.values.reduce(0, +) }
}

@MainActor private final class UsageViewState: ObservableObject {
    @Published var period = UsagePeriod.day
    @Published var anchor = Date()
    @Published var selectedColumn: Date?
    @Published var editingPrice = false
    @Published var priceInput = ""
}

struct UsageStatisticsView: View {
    @ObservedObject var model: DashboardModel
    @StateObject private var controls = UsageViewState()

    private var calendar: Calendar {
        var result = Calendar.current
        result.firstWeekday = 2
        return result
    }

    private var range: DateInterval {
        calendar.dateInterval(of: controls.period.component, for: controls.anchor)
            ?? DateInterval(start: calendar.startOfDay(for: controls.anchor), duration: 86_400)
    }

    private var columns: [UsageColumn] {
        var date = range.start
        var rows: [UsageColumn] = []
        while date < range.end {
            guard let next = calendar.date(byAdding: controls.period.step, value: 1, to: date), next > date else { break }
            let interval = DateInterval(start: date, end: min(next, range.end))
            rows.append(UsageColumn(interval: interval, summary: model.history.usageStatistics?.summarize(interval) ?? UsageHour()))
            date = next
        }
        return rows
    }

    var body: some View {
        let history = model.history.usageStatistics
        let summary = history?.summarize(range) ?? UsageHour()
        VStack(alignment: .leading, spacing: 16) {
            timeframe
            HStack(spacing: 9) {
                metric(tr("관측 활동 시간"), duration(summary.coveredSeconds > 0 ? summary.activeSeconds : nil),
                       "waveform.path", MonitorPalette.accent)
                metric(tr("확인된 완료"), summary.completionCoverage > 0 || summary.completed > 0
                    ? tr("\(summary.completed)건") : "—", "checkmark.circle", .mint)
                metric(tr("최고 RAM"), ram(summary.peakRAM > 0 ? summary.peakRAM : nil), "memorychip", RAMCategory.apps.color)
                metric(tr("스왑 쓰기"), swapAmount, "internaldrive", RAMCategory.system.color)
            }
            usageChart(columns)
            if let selected = columns.first(where: { $0.id == controls.selectedColumn }) {
                columnDetails(selected)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    indexCard(history)
                    deviceCard(history)
                }
                VStack(alignment: .leading, spacing: 12) {
                    indexCard(history)
                    deviceCard(history)
                }
            }
            if let began = history?.began {
                Text(tr("\(began.formatted(date: .abbreviated, time: .omitted))부터 이 Mac에서 관측한 기록이에요."))
                    .font(.caption).foregroundStyle(MonitorPalette.secondary)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(MonitorPalette.text)
        .onChange(of: controls.period) { _, _ in controls.selectedColumn = nil }
        .sheet(isPresented: $controls.editingPrice) { priceEditor }
    }

    private var timeframe: some View {
        HStack {
            Picker(tr("기간"), selection: $controls.period) {
                ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 204)
            Spacer(minLength: 4)
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(tr("이전 기간"))
            Text(rangeLabel(range)).font(.system(size: 13, weight: .semibold)).monospacedDigit().lineLimit(1)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel(tr("다음 기간")).disabled(range.end > .now)
            if !range.contains(.now) {
                Button(tr("오늘")) { controls.anchor = .now; controls.selectedColumn = nil }
            }
        }
        .buttonStyle(.borderless)
    }

    private func shift(_ offset: Int) {
        guard let next = calendar.date(byAdding: controls.period.component, value: offset, to: range.start) else { return }
        controls.anchor = next
        controls.selectedColumn = nil
    }

    private func rangeLabel(_ interval: DateInterval) -> String {
        let start = interval.start.formatted(.dateTime.year().month().day())
        if controls.period == .day { return start }
        return start + " – " + interval.end.addingTimeInterval(-1).formatted(.dateTime.month().day())
    }

    private func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let rounded = Int(seconds.rounded(.down))
        let hours = rounded / 3600
        let minutes = rounded % 3600 / 60
        if hours > 0 { return tr("\(hours)시간 \(minutes)분") }
        if minutes > 0 { return tr("\(minutes)분") }
        return tr("\(rounded)초")
    }

    private var swapAmount: String {
        let days = model.history.days.filter { key, _ in
            key >= History.day(range.start) && key <= History.day(range.end.addingTimeInterval(-1))
        }
        return ram(days.isEmpty ? nil : days.values.reduce(0) { $0 + $1.written })
    }

    private func metric(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(MonitorPalette.secondary)
            Text(value).font(.system(size: 23, weight: .semibold)).monospacedDigit().foregroundStyle(color)
        }
        .lineLimit(1).minimumScaleFactor(0.65)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(MonitorSurface())
    }

    private func kindColor(_ kind: AIWorkKind) -> Color {
        switch kind {
        case .chat: MonitorPalette.accent
        case .image: RAMCategory.apps.color
        case .video: RAMCategory.system.color
        case .audio: MonitorPalette.availableRAM
        case .other: MonitorPalette.secondary
        }
    }

    private func kindTitle(_ kind: AIWorkKind) -> String { kind.title }

    private func binLabel(_ date: Date) -> String {
        if controls.period == .day { return date.formatted(.dateTime.hour()) }
        return date.formatted(.dateTime.month().day())
    }

    private func usageChart(_ columns: [UsageColumn]) -> some View {
        let maximum = max(columns.map(\.stackedSeconds).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("로컬 작업 활동")).font(.system(size: 17, weight: .semibold))
                Spacer()
                ForEach(AIWorkKind.allCases) { kind in
                    Label(kindTitle(kind), systemImage: kind.symbol)
                        .font(.system(size: 10)).foregroundStyle(kindColor(kind))
                }
            }
            if !columns.contains(where: { $0.summary.activeSeconds > 0 }) {
                Text(tr("이 기간에 확인된 생성 활동이 없어요."))
                    .font(.callout).foregroundStyle(MonitorPalette.secondary)
            }
            HStack(alignment: .bottom, spacing: controls.period == .week ? 9 : 4) {
                ForEach(columns) { bin in
                    Button {
                        controls.selectedColumn = controls.selectedColumn == bin.id ? nil : bin.id
                    } label: {
                        VStack(spacing: 1) {
                            Spacer(minLength: 0)
                            ForEach(Array(AIWorkKind.allCases.reversed())) { kind in
                                let seconds = bin.summary.kinds[kind.rawValue] ?? 0
                                if seconds > 0 {
                                    Rectangle().fill(kindColor(kind))
                                        .frame(height: CGFloat(max(2, 110 * seconds / maximum)))
                                }
                            }
                            if bin.stackedSeconds == 0 {
                                Capsule().fill(bin.summary.coveredSeconds > 0 ? MonitorPalette.secondary.opacity(0.6) : MonitorPalette.track)
                                    .frame(height: 3)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 2).padding(.vertical, 4)
                        .background(controls.selectedColumn == bin.id ? MonitorPalette.track : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(binLabel(bin.id))
                    .accessibilityValue(duration(bin.summary.coveredSeconds > 0 ? bin.summary.activeSeconds : nil))
                    .help(binLabel(bin.id) + " · " + duration(bin.summary.coveredSeconds > 0 ? bin.summary.activeSeconds : nil))
                }
            }
            .frame(height: 126)
            HStack {
                Text(controls.period == .day ? tr("00시") : columns.first.map { binLabel($0.id) } ?? "")
                Spacer()
                Text(controls.period == .day ? tr("23시") : columns.last.map { binLabel($0.id) } ?? "")
            }
            .font(.caption).foregroundStyle(MonitorPalette.secondary)
        }
        .padding(14)
        .background(MonitorSurface())
    }

    private func columnDetails(_ bin: UsageColumn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(binLabel(bin.id)).font(.headline)
                Spacer()
                Text(tr("최고 RAM") + " " + ram(bin.summary.peakRAM > 0 ? bin.summary.peakRAM : nil))
                    .foregroundStyle(MonitorPalette.secondary)
            }
            if bin.summary.completionCoverage > 0 || bin.summary.completed > 0 {
                HStack {
                    Text(tr("이 구간의 확인된 완료"))
                    Spacer()
                    Text(tr("\(bin.summary.completed)건")).monospacedDigit()
                }
            }
            ForEach(AIWorkKind.allCases) { kind in
                if let seconds = bin.summary.kinds[kind.rawValue], seconds > 0 {
                    HStack {
                        Label(kindTitle(kind), systemImage: kind.symbol).foregroundStyle(kindColor(kind))
                        Spacer()
                        Text(duration(seconds)).monospacedDigit()
                    }
                }
            }
            if bin.summary.coveredSeconds == 0 {
                Text(tr("관측 기록이 없어요.")).foregroundStyle(MonitorPalette.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorSurface())
    }

    private func indexCard(_ history: UsageHistory?) -> some View {
        let score = history?.score(in: range)
        return VStack(alignment: .leading, spacing: 9) {
            Label(tr("샘 알트먼 지표"), systemImage: "gauge.with.dots.needle.50percent")
                .font(.system(size: 16, weight: .semibold))
            HStack {
                Text(tr("탐욕")).foregroundStyle(MonitorPalette.availableRAM)
                Spacer()
                Text(score.map { "\($0) / 100" } ?? "—").bold().monospacedDigit()
                Spacer()
                Text(tr("부끄러움")).foregroundStyle(MonitorPalette.accent)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [MonitorPalette.availableRAM, RAMCategory.system.color,
                                                            MonitorPalette.accent], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 7)
                    if let score {
                        Circle().fill(MonitorPalette.text).frame(width: 13, height: 13)
                            .offset(x: max(0, geometry.size.width - 13) * CGFloat(score) / 100)
                    }
                }.frame(height: 13)
            }.frame(height: 13)
            Text(score == nil ? tr("기록이 충분해지면 판정해요.") :
                 tr("하루 30분을 기준으로 잰 재미용 지표예요."))
                .font(.caption).foregroundStyle(MonitorPalette.secondary)
            Text(tr("완료와 돈값은 성공을 확인한 Splash 대화부터 집계해요."))
                .font(.caption).foregroundStyle(MonitorPalette.secondary)
        }
        .padding(14)
        .frame(minWidth: 230, maxWidth: .infinity, alignment: .leading)
        .background(MonitorSurface())
    }

    private func deviceCard(_ history: UsageHistory?) -> some View {
        let device = model.history.macValue
        let price = model.history.actualPurchasePrice ?? device?.officialPrice
        let seconds = history?.lifetimeConfirmedSeconds ?? 0
        let perHour = price.flatMap { price -> Int? in
            let rate = Double(price) / max(seconds / 3600, 1.0 / 60)
            return seconds >= 60 && rate.isFinite ? Int(rate.rounded()) : nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            Label(tr("내 Mac, 얼마나 돈값했나"), systemImage: "desktopcomputer")
                .font(.system(size: 16, weight: .semibold))
            if let device {
                Text([device.name, device.chip, "\(device.memoryGB) GB", device.storageLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(MonitorPalette.secondary)
                HStack(spacing: 4) {
                    Text(tr("공식 신품가") + " " + won(device.officialPrice))
                        .font(.system(size: 12, weight: .medium))
                    if let source = device.priceURL {
                        Link(destination: source) { Image(systemName: "arrow.up.right") }
                            .accessibilityLabel(tr("Apple 공식 가격 출처"))
                    }
                    Spacer()
                    Button(tr("구매가 입력")) {
                        controls.priceInput = model.history.actualPurchasePrice.map(String.init) ?? ""
                        controls.editingPrice = true
                    }.buttonStyle(.borderless)
                }
                if device.officialPrice == nil && device.priceCheckedAt != nil {
                    Text(tr("같은 구성의 공식 가격을 확인할 수 없어요."))
                        .font(.caption).foregroundStyle(MonitorPalette.secondary)
                }
                if let actual = model.history.actualPurchasePrice {
                    Text(tr("실제 구매가") + " " + won(actual)).font(.caption).monospacedDigit()
                }
                HStack(spacing: 4) {
                    Text(tr("누적 확인 작업") + " " + duration(seconds))
                    Spacer(minLength: 3)
                    Text(tr("누적 완료") + " " + tr("\(history?.lifetimeCompleted ?? 0)건"))
                }.font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                Text(tr("작업 1시간당 기기값") + " " + won(perHour))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(MonitorPalette.accent)
            } else {
                Text(tr("기기 정보를 확인하고 있어요.")).font(.caption).foregroundStyle(MonitorPalette.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)
        .background(MonitorSurface())
    }

    private func won(_ value: Int?) -> String {
        value.map { $0.formatted(.currency(code: "KRW").locale(Locale(identifier: "ko_KR"))) } ?? "—"
    }

    private var priceEditor: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(tr("실제 구매가")).font(.title3.bold())
            TextField(tr("본체 가격 · 원"), text: $controls.priceInput).textFieldStyle(.roundedBorder)
            HStack {
                Button(tr("공식 신품가 사용")) { model.saveActualPurchasePrice(nil); controls.editingPrice = false }
                Spacer()
                Button(tr("취소")) { controls.editingPrice = false }.keyboardShortcut(.cancelAction)
                Button(tr("저장")) {
                    guard let price = Int(controls.priceInput.filter(\.isNumber)), (1...100_000_000).contains(price) else { return }
                    model.saveActualPurchasePrice(price)
                    controls.editingPrice = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Int(controls.priceInput.filter(\.isNumber)).map { !(1...100_000_000).contains($0) } ?? true)
            }
        }
        .padding(18).frame(width: 390)
    }
}
