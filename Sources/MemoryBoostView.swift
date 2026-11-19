import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct MemoryFitSettings: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        Section(tr("비집고 넣기")) {
            Toggle(tr("램이 모자라면 자리 만든 뒤 다시 넣기"), isOn: $model.memoryFitEnabled)
                .toggleStyle(.switch)
            if model.memoryFitEnabled {
                Text(model.fitConnected ? tr("쉬는 모델과 캐시를 비운 뒤, 시작하지 않은 요청을 한 번 더 보내요.") :
                        tr("램크루지 중계기를 연결한 뒤 이 기능을 사용할 수 있어요."))
                    .font(.callout).foregroundStyle(.secondary)
                if let message = model.fitStatus.isEmpty ? nil : model.fitStatus {
                    Label(message, systemImage: "hourglass")
                }
                if model.fitConnected {
                    ForEach(Provider.allCases) { provider in
                        if let address = model.fitAddress(provider) {
                            LabeledContent(provider.title) {
                                Button(tr("주소 복사"), systemImage: "doc.on.doc") {
                                    model.copyFitAddress(provider)
                                }
                                .help(address)
                            }
                        }
                    }
                }
                Button(tr("자동으로 닫아도 되는 앱 추가"), systemImage: "plus", action: model.addFitApp)
                Text(tr("추가한 앱이 설정한 시간 동안 쉬고 있을 때만 정상 종료를 요청해요."))
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(model.fitApps.keys.sorted(), id: \.self) { bundle in
                    LabeledContent(model.fitApps[bundle] ?? bundle) {
                        Button(tr("목록에서 빼기"), systemImage: "minus.circle") { model.removeFitApp(bundle) }
                    }
                }
                if model.fitBoostArmed {
                    Button(tr("GPU 상한 사용 준비 취소"), action: model.cancelFitBoost)
                } else {
                    Button(model.fitBoostPreparing ? tr("관리자 승인 기다리는 중…") : tr("GPU 상한 한 번 사용 준비")) {
                        Task { await model.armFitBoost() }
                    }.disabled(model.fitBoostPreparing || model.boostRunning || model.runningAction)
                }
                Text(tr("관리자 승인 후 30분 동안 준비해요. GPU 메모리 부족이 확인되면 가능한 모델에 한 번 사용해요."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor private final class GPUBoostPlan: ObservableObject {
    @Published var target: GPUBoostTarget?
    @Published var programs: [IdleProgram] = []
    @Published var selected = Set<IdleProgram.ID>()
    @Published var lastExcluded: IdleProgram?
}

@MainActor struct GPUBoostSheet: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var plan = GPUBoostPlan()

    var body: some View {
        let targets = model.gpuBoostTargets
        let target = plan.target
        let programs = plan.programs.filter { model.boostExcludedApps[$0.bundle] == nil }
        let closing = programs.filter { plan.selected.contains($0.id) }
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("램 쥐어짜기")).font(.title2.weight(.semibold))
            Text(tr("전체 메모리에서 \(model.boostReserveGiB)GB를 뺀 \(GPUBoostBudget.targetLimit(reserveGiB: model.boostReserveGiB) / 1024)GB로 GPU 상한을 올려요."))
                .fixedSize(horizontal: false, vertical: true)
            Picker(tr("원복을 기다릴 모델"), selection: $plan.target) {
                Text(tr("모델 선택")).tag(nil as GPUBoostTarget?)
                ForEach(targets) { item in Text(item.label).tag(Optional(item)) }
            }
            if targets.isEmpty {
                Text(tr("Splash, MLX-Serve 또는 LM Studio 서버를 켜면 모델을 고를 수 있어요."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(tr("선택한 모델이 램에서 내려가면 GPU 상한을 실행 전 값으로 돌려요."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text(tr("\(model.boostIdleMinutes)분 이상 쉬는 앱")).font(.headline)
                Spacer()
                Button(tr("제외 목록 관리")) {
                    dismiss()
                    model.screen = .settings
                }.buttonStyle(.link)
            }
            if programs.isEmpty {
                Text(tr("닫을 앱이 없어요. 최근에 썼거나 사용 시간이 확인되지 않은 앱은 보호해요."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(tr("최근에 쓴 앱부터 표시해요. 이번에 켜 둘 앱은 체크를 풀어요."))
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(programs) { program in
                            programRow(program)
                        }
                    }
                }.frame(maxHeight: 192)
            }
            if let excluded = plan.lastExcluded {
                HStack {
                    Text(tr("\(excluded.title) · 항상 제외")).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("되돌리기")) {
                        model.removeBoostExclusion(bundle: excluded.bundle)
                        plan.lastExcluded = nil
                    }.buttonStyle(.link)
                }.font(.callout)
            }
            Text(tr("앱에 정상 종료를 요청해요. 저장을 묻는 창이 뜨면 확인해 주세요. GPU 상한을 바꾸려면 관리자 승인이 필요해요."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(closing.isEmpty ? tr("GPU 상한 올리기") : tr("앱 닫고 GPU 상한 올리기")) {
                    guard let target else { return }
                    dismiss()
                    Task { await model.startGPUBoost(target: target, programs: closing) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.runningAction || (target.map { !targets.contains($0) } ?? true))
            }
        }
        .padding(22)
        .frame(width: 495)
        .onAppear {
            plan.programs = model.idleProgramsForBoost()
            plan.selected = Set(plan.programs.map(\.id))
            if targets.count == 1 { plan.target = targets.first }
        }
    }

    private func programRow(_ program: IdleProgram) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { plan.selected.contains(program.id) },
                set: { if $0 { plan.selected.insert(program.id) } else { plan.selected.remove(program.id) } }
            )) {
                HStack(spacing: 7) {
                    BoostAppIcon(bundle: program.bundle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(program.title)
                        Text(tr("\(program.idleMinutes)분 이상 미사용"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.toggleStyle(.checkbox)
            Spacer(minLength: 3)
            if program.bytes > 0 {
                Text(ram(program.bytes)).monospacedDigit().foregroundStyle(.secondary)
            }
            Button(tr("항상 제외")) {
                model.excludeFromBoost(bundle: program.bundle, title: program.title)
                plan.lastExcluded = program
            }
            .accessibilityLabel(tr("\(program.title) 항상 제외"))
        }
    }
}

@MainActor struct BoostExclusionsSettings: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        Section(tr("항상 제외할 앱")) {
            if model.boostExcludedApps.isEmpty {
                Text(tr("추가한 앱은 램 쥐어짜기로 닫지 않아요."))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.boostExcludedApps.keys.sorted(by: compareApps), id: \.self) { bundle in
                HStack(spacing: 8) {
                    BoostAppIcon(bundle: bundle)
                    Text(model.boostExcludedApps[bundle] ?? bundle)
                    Spacer()
                    Button(tr("제외 해제")) { model.removeBoostExclusion(bundle: bundle) }
                        .accessibilityLabel(tr("\(model.boostExcludedApps[bundle] ?? bundle) 제외 해제"))
                }
            }
            Button(tr("앱 추가…"), systemImage: "plus") { chooseApp() }
        }
    }

    private func compareApps(_ left: String, _ right: String) -> Bool {
        let result = (model.boostExcludedApps[left] ?? left)
            .localizedStandardCompare(model.boostExcludedApps[right] ?? right)
        return result == .orderedSame ? left < right : result == .orderedAscending
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = tr("항상 제외할 앱 선택")
        panel.prompt = tr("항상 제외")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let saveChoice: (NSApplication.ModalResponse) -> Void = { result in
            guard result == .OK, let url = panel.url else { return }
            guard let app = Bundle(url: url), let identifier = app.bundleIdentifier else {
                model.notice = tr("선택한 항목에서 앱 정보를 찾지 못했어요.")
                return
            }
            let title = app.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                app.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
            model.excludeFromBoost(bundle: identifier, title: title)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: saveChoice) }
        else { panel.begin(completionHandler: saveChoice) }
    }
}

@MainActor private struct BoostAppIcon: View {
    let bundle: String

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().scaledToFit()
            } else {
                Image(systemName: "app")
            }
        }.frame(width: 20, height: 20).accessibilityHidden(true)
    }
}
