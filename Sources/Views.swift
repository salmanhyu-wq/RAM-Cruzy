import AppKit
import SwiftUI

enum MonitorPalette {
    static let windowBackground = NSColor(srgbRed: 16 / 255.0, green: 25 / 255.0, blue: 39 / 255.0, alpha: 1)
    static let background = Color(nsColor: windowBackground)
    static let sidebar = rgb(0x0C1522)
    static let surface = rgb(0x172537)
    static let track = rgb(0x233447)
    static let line = rgb(0x2D4155)
    static let text = rgb(0xE9F6FA)
    static let secondary = rgb(0xAABDD0)
    static let accent = rgb(0x64F4D5)
    static let onAccent = rgb(0x102826)
    static let switchTint = rgb(0x2B786B)
    static let good = rgb(0xC2EA8C)

    private static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double(hex >> 16) / 255, green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
}

struct MonitorButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 13 : 12, weight: .semibold))
            .foregroundStyle(prominent ? MonitorPalette.onAccent : MonitorPalette.text)
            .padding(.horizontal, prominent ? 11 : 8)
            .padding(.vertical, 4)
            .frame(minHeight: prominent ? 29 : 25)
            .background(prominent ? MonitorPalette.accent : MonitorPalette.track, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if !prominent { RoundedRectangle(cornerRadius: 6).strokeBorder(MonitorPalette.line) }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.74 : 1) : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct MemoryReadout: View {
    let memory: MemoryReading?
    let pressure: Int32?

    var body: some View {
        let fraction = memory?.usedFraction ?? 0
        let percent = Int((fraction * 100).rounded())
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text("램 사용률").font(.system(size: 11, weight: .medium)).foregroundStyle(MonitorPalette.accent)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(memory == nil ? "—" : String(percent))
                        .font(.system(size: 37, weight: .semibold)).tracking(-1.5)
                    if memory != nil { Text("%").font(.system(size: 17, weight: .semibold)) }
                }
                .foregroundStyle(MonitorPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("램 사용률")
            .accessibilityValue(memory == nil ? "확인 중" : "\(percent)%")
            .help(memory.map { "프로그램 등 \(ram($0.applicationBytes)) · 시스템 고정 \(ram($0.wired)) · 압축 \(ram($0.compressed))" } ?? "램 사용량을 확인하는 중")

            HStack(spacing: 5) {
                Circle().frame(width: 5, height: 5).accessibilityHidden(true)
                Text(pressure == 1 ? "여유 있음" : pressureText(pressure))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(pressure == 1 ? MonitorPalette.good : pressureColor(pressure))
            .accessibilityLabel(memoryStatusText(pressure))
            .help(memoryStatusText(pressure))

            VStack(alignment: .leading, spacing: 2) {
                Text("램 사용량").font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary)
                Text(ram(memory?.used)).font(.system(size: 14, weight: .semibold))
                if let memory {
                    Text("/ " + ram(memory.total)).font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 2) {
                Text("스왑").font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary)
                Text(ram(memory?.swap)).font(.system(size: 14, weight: .semibold))
            }
            .accessibilityElement(children: .combine)
            .help("맥이 디스크에 임시로 저장한 메모리 양")
        }
        .foregroundStyle(MonitorPalette.text)
        .monospacedDigit()
    }
}

extension Activity {
    var friendlyLabel: String {
        switch self {
        case .working: "사용 중"
        case .queued: "기다리는 중"
        case .idle: "쉬는 중"
        case .unloaded: "램에서 내려감"
        case .unknown: "사용 여부 모름"
        case .empty: "비어 있음"
        case .stopping: "멈추는 중"
        case .offline: "연결 안 됨"
        case .loading: "불러오는 중"
        }
    }
}

func memoryStatusText(_ value: Int32?) -> String {
    switch value {
    case 1: "메모리 여유가 있어요"
    case 2: "메모리 여유가 적어요"
    case 4: "메모리가 많이 부족해요"
    default: "메모리 상태를 확인하고 있어요"
    }
}

@MainActor struct AutomaticRecoveryToggle: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        Toggle(isOn: $model.autoRecoveryEnabled) {
            HStack(spacing: 4) {
                Text("자동 비우기").font(.callout.weight(.medium))
                Text(model.autoRecoveryEnabled ? "켬" : "끔").font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(MonitorPalette.switchTint)
        .fixedSize()
        .accessibilityLabel("쉬는 AI 메모리 자동 비우기")
        .help("맥이 디스크에 임시 메모리를 쓰면, 쉬는 AI 항목만 램에서 내려요.")
    }
}

@MainActor private final class QuickPanelState: ObservableObject {
    @Published var pending: Confirmation?
    @Published var servers = false
    @Published var maximumHeight: CGFloat = 720
    @Published var contentHeight: CGFloat?
}

@MainActor struct CompactPanel: View {
    static let width: CGFloat = 420
    private static let headerHeight: CGFloat = 44

    @ObservedObject var model: DashboardModel
    let close: () -> Void
    let resize: () -> Void
    let openSettings: (() -> Void)?
    let openBoost: (() -> Void)?
    let open: () -> Void
    @ObservedObject private var panelState: QuickPanelState
    private var pending: Confirmation? { panelState.pending }

    init(model: DashboardModel, close: @escaping () -> Void = {}, resize: @escaping () -> Void = {},
         openSettings: (() -> Void)? = nil, openBoost: (() -> Void)? = nil, open: @escaping () -> Void) {
        self.model = model
        self.close = close
        self.resize = resize
        self.openSettings = openSettings
        self.openBoost = openBoost
        self.open = open
        panelState = QuickPanelState()
    }

    private var jobs: [QuickEntry] {
        let entries = model.servers.flatMap { server in
            server.jobs.filter { [.working, .queued, .loading, .stopping].contains($0.activity) }
                .map { QuickEntry(provider: server.id, row: $0, serverBytes: server.bytes) }
        }
        return entries.filter { $0.row.activity != .queued } + entries.filter { $0.row.activity == .queued }
    }

    private var idle: [QuickEntry] {
        model.servers.flatMap { server in
            server.models.filter(\.canReleaseWhenIdle)
                .map { QuickEntry(provider: server.id, row: $0, serverBytes: server.bytes) }
        }
    }

    private var modelsToCheck: [QuickEntry] {
        model.servers.flatMap { server in
            server.models.filter {
                if case .sleepSplash = $0.control { return true }
                return $0.activity == .unknown && !$0.bulk && $0.control?.isRelease == true
            }
                .map { QuickEntry(provider: server.id, row: $0, serverBytes: server.bytes) }
        }
    }

    var body: some View {
        let jobs = jobs
        let idle = idle
        let firstRows = Array(idle.prefix(1)) + Array(jobs.prefix(1))
        let ordered = firstRows + idle.dropFirst() + jobs.dropFirst() + modelsToCheck
        let represented = Set(ordered.map(\.provider))
        let other = model.occupied.filter { $0.hasObservedRAM && !represented.contains($0.id) }
        let maximumBodyHeight = max(0, panelState.maximumHeight - Self.headerHeight)
        VStack(spacing: 0) {
            header
            ScrollView {
                panelContent(idleCount: idle.count, entries: ordered, other: other, activeCount: jobs.count)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded(.up) }) {
                        if panelState.contentHeight != $0 { panelState.contentHeight = $0 }
                    }
            }
            .scrollIndicators(.never, axes: .vertical)
            .id(pending?.id)
            .id(panelState.servers)
            .frame(height: min(panelState.contentHeight ?? maximumBodyHeight, maximumBodyHeight))
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: true, vertical: true)
        .background(MonitorPalette.background)
        .tint(MonitorPalette.accent)
        .onChange(of: panelState.contentHeight) { _, _ in resize() }
        .onChange(of: panelState.maximumHeight) { _, _ in resize() }
        .onChange(of: model.runningAction) { _, running in
            if running { setPending(nil) }
        }
        .onDisappear { setPending(nil) }
        .onExitCommand {
            if pending != nil { setPending(nil) } else { close() }
        }
    }

    private func panelContent(idleCount: Int, entries: [QuickEntry], other: [ServerReading], activeCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let pending {
                promptBox(pending)
            } else if panelState.servers {
                QuickServerControls(model: model, confirm: setPending, openLibrary: { open(); model.screen = .library })
            } else {
                if !model.serverProblems.isEmpty {
                    ForEach(Provider.allCases.filter { model.serverProblems[$0] != nil }) { provider in
                        HStack(spacing: 8) {
                            ProviderIcon(provider: provider, size: 20)
                            Text(provider.title).font(.callout.weight(.semibold))
                            ServerResetButton(provider: provider) { setPending(model.serverResetPrompt(provider)) }
                                .disabled(model.runningAction)
                            Spacer(minLength: 0)
                        }
                        .help(model.serverProblems[provider] ?? "")
                    }
                }
                HStack(alignment: .top, spacing: 0) {
                    MemoryReadout(memory: model.memory, pressure: model.displayPressure)
                        .frame(width: 94, alignment: .leading)
                    AIActivityChart(history: model.aiActivity, compact: true)
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(MonitorPalette.line).frame(width: 1).accessibilityHidden(true)
                        }
                }
                quickAction(idleCount: idleCount)
                if model.memoryFitEnabled && !model.fitStatus.isEmpty {
                    Label(model.fitStatus, systemImage: "hourglass").font(.callout)
                }
                if !model.notice.isEmpty {
                    Label(model.notice, systemImage: model.runningAction ? "hourglass" : "info.circle")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .help(model.notice)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(MonitorPalette.surface, in: RoundedRectangle(cornerRadius: 7))
                }
                if !entries.isEmpty || !other.isEmpty {
                    occupiedList(entries: entries, other: other, activeCount: activeCount)
                }
            }
        }
    }

    private var header: some View {
        ZStack {
            Text(AppIdentity.name).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MonitorPalette.text)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 4) {
                headerButton("전체 창 열기", symbol: "memorychip", action: open)
                headerButton(panelState.servers ? "램 관리로 돌아가기" : "서버 관리",
                             symbol: "server.rack", selected: panelState.servers) {
                    panelState.servers.toggle()
                }
                .disabled(pending != nil)
                Spacer()
                if let openSettings {
                    headerButton("설정 열기", symbol: "gearshape", action: openSettings)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: Self.headerHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(MonitorPalette.line).frame(height: 1) }
    }

    private func headerButton(_ title: String, symbol: String, selected: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(selected ? MonitorPalette.accent : MonitorPalette.secondary)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .help(title)
    }

    private func quickAction(idleCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 11) {
                if model.runningAction || idleCount > 0 {
                    Button {
                        model.releaseIdle()
                    } label: {
                        Label(model.runningAction ? "처리 중…" : "쉬는 AI \(idleCount)개 비우기",
                              systemImage: model.runningAction ? "hourglass" : "arrow.down.to.line")
                    }
                    .buttonStyle(MonitorButtonStyle(prominent: true))
                    .disabled(model.runningAction)
                    .accessibilityHint("쉬는 항목만 램에서 내려요. 필요하면 다시 불러와요.")
                } else {
                    Label(recoveryUnavailable, systemImage: "info.circle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(MonitorPalette.secondary)
                        .frame(minHeight: 26, alignment: .leading)
                }
                Spacer(minLength: 0)
                AutomaticRecoveryToggle(model: model)
            }
            HStack(alignment: .center, spacing: 12) {
                if let openBoost {
                    Button(model.boostRunning ? "GPU 상한 원복" : "램 쥐어짜기", systemImage: "gauge.with.needle") {
                        if model.boostRunning { model.stopGPUBoost() }
                        else { openBoost() }
                    }
                    .buttonStyle(MonitorButtonStyle())
                    .fixedSize()
                    .disabled(model.runningAction && !model.boostRunning)
                }
                Text("자동 비우기는 맥이 디스크에 임시 메모리를 쓸 때 작동해요.")
                    .font(.caption)
                    .foregroundStyle(MonitorPalette.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if openBoost != nil, model.boostRunning {
                Text(model.boostStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(model.boostStatus)
            }
        }
        .padding(9)
        .background(MonitorPalette.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var recoveryUnavailable: String {
        if model.servers.isEmpty { return "AI 프로그램 확인 중" }
        if model.servers.allSatisfy({ $0.activity == .offline }) { return "연결된 AI 프로그램이 없어요" }
        return "지금 비울 쉬는 AI가 없어요"
    }

    private func occupiedList(entries: [QuickEntry], other: [ServerReading], activeCount: Int) -> some View {
        let firstByProvider = Dictionary(entries.map { ($0.provider, $0.id) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("램을 쓰는 AI").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MonitorPalette.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if activeCount > 0 {
                    Text("진행·대기 \(activeCount)개").font(.caption).foregroundStyle(MonitorPalette.accent)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    Text("앱 · 작업").frame(maxWidth: .infinity, alignment: .leading)
                    Text("상태").gridColumnAlignment(.trailing)
                    Text("사용량").gridColumnAlignment(.trailing)
                    Text("관리").gridColumnAlignment(.trailing)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MonitorPalette.secondary)
                .padding(.bottom, 6)

                ForEach(entries) { entry in
                    listDivider
                    entryRow(entry, firstForProvider: entry.id == firstByProvider[entry.provider])
                }
                ForEach(other) { server in
                    listDivider
                    usageRow(server)
                }
            }
        }
    }

    private var listDivider: some View {
        Rectangle().fill(MonitorPalette.line).frame(height: 1)
            .gridCellUnsizedAxes(.horizontal)
            .accessibilityHidden(true)
    }

    private func entryRow(_ entry: QuickEntry, firstForProvider: Bool) -> some View {
        let row = entry.row
        let server = model.servers.first { $0.id == entry.provider }
        let last = entry.provider == .splash && server?.models.contains(where: { $0.id == row.id }) == true &&
            server?.jobs.contains(where: { $0.activity != .empty }) == false ? server?.recentJobs.first : nil
        let title = row.id == "comfy-cache" ? "임시 데이터" : last?.conversationTitle ?? row.readableTitle
        let parts = quickContext(entry)
        let owner: String?
        if let last {
            owner = "마지막 사용 · " + last.title
        } else if row.conversationTitle != nil {
            owner = row.title
        } else if entry.provider == .splash && row.sessionIdentifier != nil {
            owner = "대화 제목 미확인"
        } else {
            owner = nil
        }
        let detail = [title, last?.title ?? owner].compactMap { $0 }.joined(separator: " · ")
        let help = [title, parts, owner].compactMap { $0 }.joined(separator: "\n")
        return GridRow(alignment: .center) {
            serverLabel(entry.provider, detail: detail, help: help,
                        note: row.sessionIdentifier == nil ? row.attributionNote : nil)
            activityStatus(row.activity)
            usageValue(firstForProvider ? entry.serverBytes : nil)
            VStack(alignment: .trailing, spacing: 4) {
                if row.control != nil {
                    Button(row.actionLabel) {
                        if row.canReleaseWhenIdle { model.releaseIdle(row) }
                        else { setPending(model.actionPrompt(for: row)) }
                    }
                    .accessibilityLabel("\(row.actionLabel), \(title), \(row.title), \(parts)")
                }
                if entry.provider == .comfy, row.id == "comfy-cache", model.comfyStopTarget != nil {
                    Button("서버 종료…") { setPending(model.comfyStopPrompt()) }
                        .accessibilityLabel("ComfyUI 서버 종료")
                }
            }
            .buttonStyle(MonitorButtonStyle())
            .disabled(model.runningAction)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 7)
    }

    private func quickContext(_ entry: QuickEntry) -> String {
        let row = entry.row
        var parts = [entry.provider.title]
        if let name = row.observedModels.first {
            parts.append(URL(fileURLWithPath: name).lastPathComponent)
        } else if entry.provider == .splash && row.sessionIdentifier == nil {
            parts.append(URL(fileURLWithPath: row.title).lastPathComponent)
        } else if entry.provider == .comfy {
            parts.append("이미지·영상 생성")
        }
        return parts.joined(separator: " · ")
    }

    private func usageRow(_ server: ServerReading) -> some View {
        let names = server.statusModelNames
        let detail = names.isEmpty ? "앱과 임시 데이터" : names.prefix(2).joined(separator: " · ")
        return GridRow(alignment: .center) {
            serverLabel(server.id, detail: detail)
            activityStatus(server.activity)
            usageValue(server.bytes)
            Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .padding(.vertical, 7)
    }

    private func serverLabel(_ provider: Provider, detail: String, help: String? = nil, note: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 6) {
            ProviderIcon(provider: provider, size: 19)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MonitorPalette.text)
                    .lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(MonitorPalette.secondary).lineLimit(1)
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .help(help ?? detail)
    }

    private func activityStatus(_ activity: Activity) -> some View {
        Text(activity.friendlyLabel)
            .font(.system(size: 11))
            .foregroundStyle(activity == .working ? MonitorPalette.accent : MonitorPalette.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func usageValue(_ bytes: UInt64?) -> some View {
        Text(ram(bytes))
            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            .foregroundStyle(bytes == nil ? MonitorPalette.secondary : MonitorPalette.text)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("앱 전체 램 사용량 " + ram(bytes))
            .help("앱 전체 램 사용량")
    }

    func resetPrompt() { setPending(nil) }

    func setMaximumHeight(_ height: CGFloat) {
        if panelState.maximumHeight != height { panelState.maximumHeight = height }
    }

    private func setPending(_ prompt: Confirmation?) {
        model.setQuickPrompt(old: pending?.id, new: prompt?.id)
        panelState.pending = prompt
    }

    private func promptBox(_ prompt: Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(prompt.title)
                .font(.system(size: 15, weight: .semibold)).lineLimit(3)
                .help(prompt.title)
            Text(prompt.detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("돌아가기") { setPending(nil) }
                    .buttonStyle(MonitorButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(prompt.button, role: .destructive) {
                    setPending(nil)
                    Task { await prompt.run() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorSurface())
    }
}

struct GachaBanner: View {
    private static let website = URL(string: "https://mymusicgacha.com")!
    private static let mark = Bundle.main.url(forResource: "MyMusicGacha", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        Link(destination: Self.website) {
            HStack(spacing: 7) {
                if let mark = Self.mark {
                    Image(nsImage: mark).resizable().scaledToFit()
                        .frame(width: 32, height: 32).clipShape(Circle())
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("마이뮤직 가챠").font(.system(size: 12, weight: .bold))
                    Text("노래 만들기").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MonitorPalette.secondary)
                }.lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(MonitorPalette.text)
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(MonitorSurface())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("마이뮤직 가챠 웹사이트 열기")
        .help("마이뮤직 가챠 웹사이트 열기")
    }
}

struct AboutScreen: View {
    private static let transcript = URL(string: "https://cheekypint.transistor.fm/39/transcript")!

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppIdentity.name).font(.system(size: 23, weight: .semibold))
                    Text("버전 " + AppIdentity.version).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 11) {
                Label("오늘의 명언", systemImage: "quote.opening")
                    .foregroundStyle(.secondary).font(.system(size: 13, weight: .semibold))
                Text("“전 세계 자원을 어떻게 나눠 쓸지 생각하면, 한정된 램을 각자 컴퓨터에 넣어 두고 고작 5%의 시간만 쓰는 건 꽤 끔찍한 일이죠.”")
                    .font(.system(size: 19, weight: .medium)).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                Text("샘 알트만 · 2026년 10월 29일, 한국어 번역")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Link(destination: Self.transcript) {
                    Label("팟캐스트 원문", systemImage: "arrow.up.right")
                }.font(.system(size: 13))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(17).background(MonitorSurface())
        }
    }
}

private struct QuickEntry: Identifiable {
    let provider: Provider
    let row: WorkRow
    let serverBytes: UInt64?
    var id: String { provider.rawValue + "/" + row.id }
}

struct LibraryScreen: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        let filtered = model.library.filter { item in
            (model.libraryProvider == nil || model.libraryProvider == item.provider) &&
            (model.libraryPurpose == nil || model.libraryPurpose == item.purpose) &&
            (model.libraryQuery.isEmpty || item.key.localizedCaseInsensitiveContains(model.libraryQuery))
        }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("모델 이름 검색", text: $model.libraryQuery)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                Picker("서버", selection: $model.libraryProvider) {
                    Text("모든 서버").tag(nil as Provider?)
                    ForEach(Provider.allCases) { Text($0.title).tag(Optional($0)) }
                }.labelsHidden().frame(maxWidth: 170).accessibilityLabel("서버 선택")
                Picker("용도", selection: $model.libraryPurpose) {
                    Text("모든 용도").tag(nil as ModelPurpose?)
                    ForEach(ModelPurpose.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }.labelsHidden().frame(maxWidth: 140).accessibilityLabel("모델 용도 선택")
            }
            if !model.libraryLoaded {
                ProgressView("저장된 모델 확인 중…")
            } else {
                HStack {
                    Text("\(filtered.count)개 모델").fontWeight(.semibold)
                    Text("· 파일 크기 \(ram(filtered.reduce(UInt64(0)) { $0 + $1.bytes }))").foregroundStyle(.secondary)
                    Spacer()
                    Button("목록 새로 고침", systemImage: "arrow.clockwise") {
                        Task { await model.refreshLibrary() }
                    }
                }
                if filtered.isEmpty {
                    if model.library.isEmpty {
                        ContentUnavailableView("저장한 모델이 없어요", systemImage: "shippingbox")
                    } else {
                        ContentUnavailableView("조건에 맞는 모델이 없어요", systemImage: "shippingbox",
                                               description: Text("서버, 용도 또는 검색어를 바꿔 보세요."))
                    }
                }
            }
            DriveModelSearch(model: model, discovery: model.discovery)
            ForEach(Provider.allCases) { provider in
                let models = filtered.filter { $0.provider == provider }
                if !models.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            ProviderIcon(provider: provider, size: 30)
                            Text(provider.title).font(.system(size: 19, weight: .bold))
                            Text("\(models.count)개").foregroundStyle(.secondary)
                        }.padding(.bottom, 7).padding(.top, 3)
                        ForEach(ModelPurpose.allCases) { purpose in
                            let group = models.filter { $0.purpose == purpose }
                            if !group.isEmpty {
                                Text(purpose.rawValue).font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary).padding(.top, 9).padding(.bottom, 4)
                                ForEach(group) { libraryRow($0) }
                            }
                        }
                    }.padding(13).background(MonitorSurface())
                }
            }
        }
    }

    private func libraryRow(_ item: LocalModel) -> some View {
        let used = model.use(for: item)
        let block = model.trashReason(item)
        return VStack(spacing: 0) {
            Divider().opacity(0.65)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 15, weight: .semibold))
                        .lineLimit(2).help(item.key)
                    if let used {
                        Text("최근 " + used.displayLast + (used.calls > 0 ? " · 확인 호출 \(used.calls)회" : ""))
                            .foregroundStyle(.secondary).font(.system(size: 14))
                    } else if model.libraryLoaded {
                        Text("최근 사용 확인 안 됨").foregroundStyle(.secondary).font(.system(size: 14))
                    }
                    if let block {
                        Text(block).foregroundStyle(.secondary).font(.system(size: 12))
                    }
                }
                Spacer(minLength: 6)
                if model.modelIsLoaded(item) {
                    Button("램에서 내리기") { model.releaseModel(item) }.disabled(model.runningAction)
                } else if item.purpose != .lora && item.purpose != .support && item.provider != .mlxStudio {
                    Button(item.provider == .comfy ? "워크플로 열기" : "램에 올리기") { model.selectLoad(item) }
                        .disabled(model.runningAction)
                }
                Menu {
                    ForEach(Provider.allCases.filter { $0 != item.provider }) { target in
                        Button(target.title + "에 추가…") { _ = model.receiveModels([item.url.absoluteString], provider: target) }
                    }
                } label: { Image(systemName: "arrow.up.right.square") }
                .menuStyle(.borderlessButton).frame(width: 24).help("다른 서버에 추가")
                Text(item.isLinked ? "링크" : ram(item.bytes))
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
                if model.isDirectLink(item) {
                    Button("연결 해제") { model.selectUnlink(item) }.disabled(model.runningAction || model.modelIsLoaded(item))
                }
                if let block {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    } label: {
                        Label("Finder", systemImage: "folder").labelStyle(.iconOnly)
                    }.help(block).accessibilityLabel("Finder에서 \(item.title) 보기. \(block)")
                } else {
                    Button {
                        model.selectTrash(item)
                    } label: {
                        Label("휴지통으로", systemImage: "trash").font(.system(size: 13, weight: .medium))
                    }.disabled(model.runningAction).help("‘\(item.title)’을 휴지통으로 이동")
                        .accessibilityLabel("\(item.title)을 휴지통으로 이동")
                }
            }.padding(.vertical, 8)
        }
        .draggable(item.url)
        .help("이 모델을 위의 서버 아이콘으로 끌어 추가할 수 있어요.")
    }
}

struct UsageScreen: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        let rows = model.usage.sorted {
            if $0.calls != $1.calls { return $0.calls > $1.calls }
            if $0.observedSeconds != $1.observedSeconds { return $0.observedSeconds > $1.observedSeconds }
            return $0.last > $1.last
        }
        let unused = model.library.filter { model.use(for: $0) == nil }
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("최근 30일").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("기록 불러오기", systemImage: "arrow.clockwise") { Task { await model.refreshLibrary() } }
            }
            Text("MLX-Serve와 Hermes가 기록한 호출 수, 이 앱이 켜져 있을 때 확인한 모델 활동을 표시해요.")
                .foregroundStyle(.secondary).font(.system(size: 14))
            if rows.isEmpty {
                Text("아직 확인된 사용 기록이 없어요.").foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 0) {
              ForEach(rows) { row in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: row.name).lastPathComponent).fontWeight(.semibold)
                            .lineLimit(2).help(row.name)
                        Text(row.provider.title + " · " + row.displayLast).foregroundStyle(.secondary).font(.system(size: 14))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        if row.calls > 0 { Text("\(row.calls)회 호출").monospacedDigit().fontWeight(.semibold) }
                        if row.observedSeconds >= 1 {
                            Text("활동 관찰 \(shortDuration(row.observedSeconds))")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        if row.calls == 0 && row.observedSeconds < 1 { Text("최근 사용 확인").foregroundStyle(.secondary) }
                    }.font(.system(size: 14))
                }.padding(11)
                if row.id != rows.last?.id { Divider().padding(.horizontal, 11) }
              }
            }.background {
                if !rows.isEmpty { MonitorSurface() }
            }
            if model.libraryLoaded {
                Divider().padding(.vertical, 2)
                Text("사용 기록이 없는 모델 \(unused.count)개").font(.system(size: 18, weight: .semibold))
                if !unused.isEmpty {
                    Text("서버가 사용 기록을 제공하지 않거나 앱을 끈 동안 사용한 모델도 여기에 나올 수 있어요.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                ForEach(unused) { item in
                    HStack {
                        Text(item.title).lineLimit(2).help(item.key)
                        Spacer()
                        Text(item.provider.title + " · " + ram(item.bytes)).foregroundStyle(.secondary)
                    }.font(.system(size: 14)).padding(.vertical, 3)
                }
            }
        }
    }
}

struct SwapScreen: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        let values = model.history.days
        let today = values[History.day(.now)]
        let sevenDates = (0..<7).compactMap {
            Calendar.current.date(byAdding: .day, value: $0 - 6, to: Calendar.current.startOfDay(for: .now))
        }
        let highest = max(1, sevenDates.map { values[History.day($0)]?.written ?? 0 }.max() ?? 1)
        VStack(alignment: .leading, spacing: 15) {
            Text("램이 부족할 때 맥이 디스크를 임시로 사용한 기록이에요.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                stat("지금 디스크 사용", ram(model.memory?.swap))
                stat("오늘 디스크로 보냄", ram(today?.written))
                stat("오늘 램으로 돌려옴", ram(today?.read))
            }.padding(4).background(MonitorSurface())
            VStack(alignment: .leading, spacing: 10) {
                Text("최근 7일 스왑으로 보낸 양").font(.system(size: 18, weight: .semibold))
                HStack(alignment: .bottom, spacing: 12) {
                    ForEach(sevenDates, id: \.self) { date in
                        let bytes = values[History.day(date)]?.written ?? 0
                        VStack(spacing: 5) {
                            Text(values[History.day(date)] == nil ? "—" : ram(bytes)).font(.system(size: 13)).monospacedDigit()
                            RoundedRectangle(cornerRadius: 4)
                                .fill(bytes > 0 ? Color.accentColor : Color.primary.opacity(0.12))
                                .frame(height: max(3, 54 * Double(bytes) / Double(highest)))
                            Text(date.formatted(.dateTime.month(.defaultDigits).day().locale(Locale(identifier: "ko_KR"))))
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
                    }
                }
                Text("\(dayTime(model.history.started))부터 기록")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(13).background(MonitorSurface())
            Text("스왑이 움직인 시점").font(.system(size: 19, weight: .bold))
            Text("이때 함께 실행 중이던 작업과 프로그램을 표시해요.")
                .foregroundStyle(.secondary).font(.system(size: 14))
            if model.history.events.isEmpty {
                Text("아직 1MB 이상 움직인 구간이 기록되지 않았어요.").foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(model.history.events.reversed().prefix(100)) { event in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(dayTime(event.end)).fontWeight(.semibold)
                        Spacer()
                        HStack(spacing: 5) {
                            if event.written > 0 {
                                Circle().fill(.orange).frame(width: 6, height: 6).accessibilityHidden(true)
                            }
                            Text("쓰기 \(ram(event.written)) · 읽기 \(ram(event.read))")
                                .foregroundStyle(event.written > 0 ? .primary : .secondary).monospacedDigit()
                        }
                    }
                    Text("스왑 \(ram(event.before)) → \(ram(event.occupied)) · 압력 \(pressureText(event.pressure))")
                        .foregroundStyle(.secondary)
                    if event.gap {
                        Text("기록이 끊긴 구간 \(shortDuration(event.end.timeIntervalSince(event.start))) · 작업 정보 없음")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(event.work, id: \.self) { Text($0).lineLimit(2) }
                        if event.work.isEmpty { Text("함께 관찰된 AI 작업 없음").foregroundStyle(.secondary) }
                        if let grew = event.growing, !grew.isEmpty {
                            Text("램 증가 · " + grew.joined(separator: " · ")).lineLimit(2)
                        }
                        if !event.processes.isEmpty {
                            Text("램 사용량 상위 · " + event.processes.joined(separator: " · "))
                                .foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }.font(.system(size: 14)).padding(11)
                Divider().padding(.horizontal, 11)
              }
            }.background {
                if !model.history.events.isEmpty { MonitorSurface() }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 14)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }
}

func pressureText(_ value: Int32?) -> String {
    switch value {
    case 1: "정상"
    case 2: "주의"
    case 4: "위험"
    default: "측정 중"
    }
}

func pressureColor(_ value: Int32?) -> Color {
    switch value {
    case 1: .green
    case 2: .orange
    case 4: .red
    default: .secondary
    }
}

private extension ModelUse {
    var displayLast: String {
        if dayOnly == true {
            return last.formatted(.dateTime.month(.defaultDigits).day().locale(Locale(identifier: "ko_KR")))
        }
        return dayTime(last)
    }
}

func dayTime(_ value: Date) -> String {
    value.formatted(.dateTime.month(.defaultDigits).day().hour().minute().locale(Locale(identifier: "ko_KR")))
}

func shortDuration(_ seconds: Double) -> String {
    let duration = max(0, Int(seconds))
    if duration < 60 { return "\(duration)초" }
    if duration < 3600 { return "\(duration / 60)분" }
    return "\(duration / 3600)시간 \((duration % 3600) / 60)분"
}
