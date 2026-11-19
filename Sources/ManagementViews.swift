import AppKit
import SwiftUI

struct HubTraffic: Equatable {
    let active: Int
    let holding: Int
    let received: Int
    let retried: Int
    let recovered: Int

    init(_ values: [String: Int]) {
        active = values["active", default: 0]
        holding = values["holding", default: 0]
        received = values["received", default: 0]
        retried = values["retried", default: 0]
        recovered = values["recovered", default: 0]
    }
}

@MainActor struct HubScreen: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(model.hubReady ? tr("비집고 넣기 작동 중") : model.fitConnected ? tr("비집고 넣기 꺼짐") : tr("중계기 연결 확인 중"),
                      systemImage: model.hubReady ? "checkmark.circle.fill" : "circle")
                    .font(.headline)
                    .foregroundStyle(model.hubReady ? Color.green : Color.secondary)
                Spacer()
                Button(tr("연결 설정"), systemImage: "gearshape") { model.screen = .settings }
            }
            if !model.fitStatus.isEmpty {
                Label(model.fitStatus, systemImage: "hourglass").foregroundStyle(.orange)
            }
            ForEach(Provider.allCases) { provider in row(provider) }
        }
    }

    private func row(_ provider: Provider) -> some View {
        let state = model.servers.first { $0.id == provider }
        let counts = model.hubTraffic[provider]
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                ProviderIcon(provider: provider, size: 28)
                Text(provider.title).font(.system(size: 15, weight: .semibold))
                Text(state?.paused == true ? tr("서버 꺼짐") : state?.activity.friendlyLabel ?? tr("서버 확인 중"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if provider == .comfy, state?.activity != .offline, model.fitComfyPort != nil {
                    Button(tr("작업 화면 열기"), systemImage: "arrow.up.right.square") { model.openServerApp(provider) }
                }
                if model.fitConnected && model.fitAddress(provider) != nil {
                    Button(tr("연결 주소 복사"), systemImage: "doc.on.doc") { model.copyFitAddress(provider) }
                }
            }
            if let counts {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { counters(counts) }
                    VStack(alignment: .leading, spacing: 4) { counters(counts) }
                }.font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Text(tr("중계기를 연결하면 이 경로로 들어온 작업 수를 표시해요."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(MonitorSurface())
    }

    @ViewBuilder private func counters(_ counts: HubTraffic) -> some View {
        Text(tr("접수 \(counts.received)개"))
        Text(tr("중계 중 \(counts.active)개"))
        Text(tr("램 대기 \(counts.holding)개"))
        Text(tr("재시도 \(counts.retried)개 · 성공 \(counts.recovered)개"))
    }
}

@MainActor private final class DropHover: ObservableObject {
    @Published var active = false
}

@MainActor struct ServerResetButton: View {
    let provider: Provider
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            if reduceMotion {
                label
            } else {
                TimelineView(.periodic(from: .now, by: 0.85)) { context in
                    let bright = Int(context.date.timeIntervalSinceReferenceDate / 0.85).isMultiple(of: 2)
                    label.opacity(bright ? 1 : 0.58)
                }
            }
        }
        .buttonStyle(MonitorButtonStyle())
        .fixedSize()
        .accessibilityLabel(provider.title + tr(" 서버 초기화"))
        .help(tr("서버를 켜 두고 램의 모델을 모두 내려요."))
    }

    private var label: some View {
        Label(tr("서버 초기화"), systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
    }
}

@MainActor struct ServerControlRow: View {
    @ObservedObject var model: DashboardModel
    let provider: Provider
    var compact = false
    var confirm: ((Confirmation?) -> Void)?
    var openLibrary: (() -> Void)?
    @StateObject private var hover = DropHover()

    var body: some View {
        let reading = model.servers.first { $0.id == provider }
        let off = reading == nil || reading?.activity == .offline || reading?.paused == true
        let powerLabel = off ? tr("\(provider.title) 서버 켜기") : tr("\(provider.title) 서버 끄기")
        let busy = reading.map { [.working, .queued, .loading, .stopping].contains($0.activity) } ?? false
        let saved = model.library.filter { $0.provider == provider && $0.purpose != .lora && $0.purpose != .support }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProviderIcon(provider: provider, size: compact ? 27 : 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.title).font(.system(size: 15, weight: .semibold))
                    Text(!provider.availableOnDisk ? tr("설치 위치 확인 필요") : off ? tr("꺼짐") : busy ? reading?.activity.friendlyLabel ?? tr("확인 중") : tr("켜짐"))
                        .font(.system(size: 12)).foregroundStyle(off ? MonitorPalette.secondary : busy ? MonitorPalette.accent : MonitorPalette.good)
                }
                Spacer(minLength: 4)
                if model.serverProblems[provider] != nil {
                    ServerResetButton(provider: provider) { show(model.serverResetPrompt(provider)) }
                        .disabled(model.runningAction || busy)
                }
                Button(off ? tr("켜기") : tr("끄기"), systemImage: "power") {
                    if off { model.toggleServer(provider) }
                    else { show(model.serverStopPrompt(provider)) }
                }
                .disabled(model.runningAction || !provider.availableOnDisk || (!off && busy))
                .help(busy ? tr("진행·대기 작업이 끝나면 끌 수 있어요.") : powerLabel)
                .accessibilityLabel(powerLabel)
                Button {
                    model.modelPickerProvider = model.modelPickerProvider == provider ? nil : provider
                } label: {
                    Label(tr("모델"), systemImage: model.modelPickerProvider == provider ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                }.disabled(model.runningAction).accessibilityLabel(provider.title + tr(" 모델 관리"))
            }
            .buttonStyle(MonitorButtonStyle())
            if let reading, provider == .splash {
                let active = reading.jobs.filter { $0.activity != .empty }
                let current = active.first ?? reading.recentJobs.first
                if let current {
                    VStack(alignment: .leading, spacing: 3) {
                        Text((active.isEmpty ? tr("마지막 사용 · ") : tr("사용 중 · ")) + current.title)
                            .font(.system(size: 12, weight: .medium)).lineLimit(2).help(current.title)
                        Text(current.conversationTitle ?? tr("대화방 제목 미확인"))
                            .font(.system(size: 14, weight: .medium)).lineLimit(2)
                        if active.count > 1 { Text(tr("함께 쓰는 대화 \(active.count - 1)개 더 있음")).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                }
            }
            if model.modelPickerProvider == provider {
                let controls = reading?.models.filter { $0.control != nil } ?? []
                let unloaded = saved.filter { !model.modelIsLoaded($0) }
                let options = VStack(alignment: .leading, spacing: 7) {
                    ForEach(controls) { row in
                        HStack(spacing: 7) {
                            Text(row.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 3)
                            Button(row.actionLabel) {
                                if row.canReleaseWhenIdle { model.releaseIdle(row) }
                                else { show(model.actionPrompt(for: row)) }
                            }.buttonStyle(MonitorButtonStyle())
                        }
                    }
                    ForEach(unloaded) { item in
                        HStack(spacing: 7) {
                            Text(item.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 3)
                            Button(provider == .comfy ? tr("워크플로") : tr("올리기")) {
                                if provider == .comfy { model.openServerApp(provider) }
                                else { show(model.loadPrompt(item)) }
                            }.buttonStyle(MonitorButtonStyle()).disabled(busy)
                        }
                    }
                    HStack {
                        Button(tr("모델 보관함…")) {
                            if let openLibrary { openLibrary() } else { model.screen = .library }
                        }
                        Spacer()
                        Button(tr("앱 열기")) { model.openServerApp(provider) }
                    }.font(.system(size: 12)).buttonStyle(.link)
                }.disabled(model.runningAction)
                if compact {
                    options
                } else {
                    ScrollView { options }
                        .frame(height: min(CGFloat(controls.count + unloaded.count) * 30 + 27, 132))
                }
            }
            if !compact {
                Text(hover.active ? tr("놓으면 모델을 추가해요") : tr("포트 \(String(provider.port)) · 모델을 여기로 끌어 추가"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, compact ? 8 : 12)
        .padding(.horizontal, compact ? 0 : 12)
        .background { if !compact { MonitorSurface() } }
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(hover.active ? MonitorPalette.accent : .clear, lineWidth: 2) }
        .dropDestination(for: URL.self) { urls, _ in
            model.receiveModels(urls.map(\.absoluteString), provider: provider)
        } isTargeted: { hover.active = $0 }
    }

    private func show(_ prompt: Confirmation?) {
        if let confirm { confirm(prompt) }
        else { model.confirmation = prompt }
    }
}

@MainActor struct ServerControlGrid: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("서버 관리")).font(.system(size: 17, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 10)], spacing: 10) {
                ForEach(Provider.allCases) { provider in ServerControlRow(model: model, provider: provider) }
            }
        }.task { if !model.libraryLoaded { await model.refreshLibrary() } }
    }
}

@MainActor struct QuickServerControls: View {
    @ObservedObject var model: DashboardModel
    let confirm: (Confirmation?) -> Void
    let openLibrary: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("서버 관리"))
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 7)
            ForEach(Provider.allCases) { provider in
                Rectangle().fill(MonitorPalette.line).frame(height: 1)
                ServerControlRow(model: model, provider: provider, compact: true, confirm: confirm, openLibrary: openLibrary)
            }
            if !model.notice.isEmpty {
                Text(model.notice).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                    .padding(.top, 7)
            }
        }.task { await model.refreshLibrary() }
    }
}

@MainActor struct ModelServerDropTargets: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("모델을 서버 아이콘으로 끌어 추가할 수 있어요")).font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 9) {
                    ForEach(Provider.allCases.filter { $0 != .mlxStudio }) { provider in
                        ModelDropTarget(model: model, provider: provider)
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }
}

@MainActor private struct ModelDropTarget: View {
    @ObservedObject var model: DashboardModel
    let provider: Provider
    @StateObject private var hover = DropHover()
    var body: some View {
        VStack(spacing: 5) {
            ProviderIcon(provider: provider, size: 33)
            Text(provider.title).font(.system(size: 13, weight: .medium))
        }
        .frame(width: 108, height: 74)
        .background(provider.identityColor.opacity(hover.active ? 0.2 : 0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(provider.identityColor.opacity(hover.active ? 1 : 0.18)) }
        .dropDestination(for: URL.self) { urls, _ in model.receiveModels(urls.map(\.absoluteString), provider: provider) }
            isTargeted: { hover.active = $0 }
        .accessibilityLabel(provider.title + tr(" 모델 추가 영역"))
    }
}

@MainActor private final class DriveSearchOptions: ObservableObject {
    @Published var query = ""
    @Published var loraOnly = false
    @Published var limit = 100
}

@MainActor struct DriveModelSearch: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var discovery: ModelDiscovery
    @StateObject private var options = DriveSearchOptions()
    var body: some View {
        let filtered = discovery.progress.files.filter {
            (!options.loraOnly || $0.isLoRA) && (options.query.isEmpty || $0.url.path.localizedCaseInsensitiveContains(options.query))
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(tr("드라이브의 모델·로라 찾기"), systemImage: "externaldrive.badge.magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if discovery.running {
                    Button(tr("검사 중지"), systemImage: "stop.circle") { discovery.cancel() }
                } else {
                    Button(tr("전체 드라이브 검사"), systemImage: "magnifyingglass") { discovery.start() }
                        .buttonStyle(.borderedProminent)
                }
                Button(tr("폴더 선택…"), systemImage: "folder") { selectFolder() }.disabled(discovery.running)
            }
            if discovery.running || discovery.finished {
                HStack(spacing: 8) {
                    if discovery.running { ProgressView().controlSize(.small) }
                    Text(discovery.running ? tr("\(discovery.progress.visited.formatted())개 확인 · \(discovery.progress.files.count)개 찾음") :
                         tr("\(discovery.cancelled ? tr("검사 중지") : tr("검사 결과")) · 모델·로라 \(discovery.progress.files.count)개"))
                    Spacer()
                    if discovery.progress.unreadable > 0 { Text(tr("읽지 못한 위치 \(discovery.progress.unreadable)곳")).foregroundStyle(.secondary) }
                }.font(.system(size: 13))
                if discovery.progress.cloudIndexUsed == true {
                    Text(tr("클라우드 폴더는 맥의 파일 검색 결과를 함께 보여줘요.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if discovery.running { Text(discovery.progress.location).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                HStack {
                    TextField(tr("찾은 파일 이름·위치 검색"), text: $options.query).textFieldStyle(.roundedBorder)
                    Toggle(tr("로라만"), isOn: $options.loraOnly).toggleStyle(.checkbox).fixedSize()
                }
                if filtered.isEmpty && !discovery.running { Text(tr("조건에 맞는 파일이 없어요.")).foregroundStyle(.secondary) }
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.prefix(options.limit))) { item in fileRow(item) }
                }
                if filtered.count > options.limit {
                    Button(tr("더 보기 · 남은 \(filtered.count - options.limit)개")) { options.limit += 100 }
                }
            } else {
                Text(tr("내장·연결된 외장 드라이브에서 모델 폴더, GGUF, 가중치와 로라를 찾아요."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }.padding(14).background(MonitorSurface())
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = tr("모델과 로라를 찾을 폴더를 선택해 주세요.")
        if panel.runModal() == .OK { discovery.start(roots: panel.urls) }
    }

    private func fileRow(_ item: ModelFile) -> some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 9) {
                Image(systemName: item.isLoRA ? "slider.horizontal.3" : item.isDirectory ? "shippingbox" : "doc")
                    .foregroundStyle(item.isLoRA ? Color.pink : Color.accentColor).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1).help(item.title)
                    Text((item.isLoRA ? tr("로라 · ") : "") + item.displayFormat + " · " + item.url.deletingLastPathComponent().path)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(ram(item.bytes)).font(.system(size: 13)).monospacedDigit()
                Menu(tr("서버에 추가")) {
                    ForEach(Provider.allCases) { target in
                        Button(target.title) { _ = model.receiveModels([item.url.absoluteString], provider: target) }
                            .disabled(item.compatibility(with: target) != nil)
                    }
                }.fixedSize()
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }
                    .help(tr("Finder에서 보기"))
            }.padding(.vertical, 8)
        }.draggable(item.url)
    }
}

@MainActor private final class TransferOptions: ObservableObject {
    @Published var mode: ModelTransferMode = .link
    @Published var category: ComfyModelFolder = .automatic
}

@MainActor struct ModelTransferSheet: View {
    @ObservedObject var model: DashboardModel
    let request: ModelTransferRequest
    @StateObject private var options = TransferOptions()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProviderIcon(provider: request.provider, size: 42)
                Text(tr("\(request.provider.title)에 모델 추가")).font(.system(size: 21, weight: .semibold))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(request.files) { file in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.title).font(.system(size: 14, weight: .medium))
                            Text(ModelFileTransfer.destination(for: file, to: request.provider, category: options.category).path)
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(CGFloat(request.files.count) * 64, 180))
            if request.provider == .comfy && request.files.contains(where: { !$0.isLoRA }) {
                Picker(tr("모델 종류"), selection: $options.category) {
                    ForEach(ComfyModelFolder.allCases) { Text($0.title).tag($0) }
                }
            }
            Picker(tr("추가 방식"), selection: $options.mode) {
                ForEach(ModelTransferMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(options.mode == .link ? tr("한 파일을 여러 서버가 함께 사용해요. 원본 파일의 위치가 바뀌면 다시 연결해 주세요.") :
                    tr("대상 서버 폴더에 파일을 복사해요. 약 \(ram(request.files.reduce(0) { $0 + $1.bytes }))의 공간을 사용해요."))
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(tr("취소")) { model.transferRequest = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(options.mode.title) { Task { await model.addModels(request, mode: options.mode, category: options.category) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 510)
    }
}
