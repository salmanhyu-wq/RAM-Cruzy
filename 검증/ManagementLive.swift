import AppKit

@main enum ManagementLive {
    static func main() async throws {
        let tools = ServerTools()
        let providers = Providers()
        if CommandLine.arguments.contains("--scan") {
            let output = URL(fileURLWithPath: CommandLine.arguments.last!)
            let logger = ScanLogger(output: output)
            let known = (try? Data(contentsOf: output)).flatMap { try? JSONDecoder().decode(ModelScanProgress.self, from: $0) }?.files ?? []
            let result = await ModelDriveScanner.scan(ModelDriveScanner.roots(), knownFiles: known) { report in
                await logger.update(report)
            }
            try JSONEncoder().encode(result).write(to: output, options: .atomic)
            print("전체 검사 완료", result.visited, "파일 중", result.files.count, "모델·로라", result.files.filter(\.isLoRA).count, "로라", "접근 제한", result.unreadable)
            return
        }
        let library = await Task.detached(priority: .utility) { ModelLibrary.scan() }.value
        guard let embedding = library.first(where: { $0.provider == .lmStudio && $0.purpose == .embedding && $0.bytes < 200_000_000 }) else {
            fatalError("LM Studio의 작은 검증용 모델이 없음")
        }
        let initial = await providers.read(.lmStudio)
        guard initial.models.isEmpty else { fatalError("LM Studio가 이미 모델을 사용 중이므로 실제 모델 시험 건너뜀") }
        print("LM Studio 서버 시작 확인"); fflush(stdout)
        try await tools.start(.lmStudio)
        do {
            try await tools.load(embedding)
            let loaded = await providers.read(.lmStudio)
            guard let row = loaded.models.first, let release = row.control else { fatalError("실제 모델 올리기 확인 실패") }
            print("LM Studio 모델 올라옴", embedding.title); fflush(stdout)
            _ = try await providers.perform(release)
            let released = await providers.read(.lmStudio)
            precondition(released.models.isEmpty)
            try await tools.stop(.lmStudio)
            print("LM Studio 실제 모델 올리기·내리기 및 서버 끄기 통과"); fflush(stdout)
        } catch {
            try? await tools.stop(.lmStudio)
            throw error
        }
        for provider in [Provider.mlxServe, Provider.comfy] {
            let baseline = await providers.read(provider)
            if baseline.activity != .offline { print(provider.title, "기존 서버가 켜져 있어 유지"); continue }
            print(provider.title, "시작 시험"); fflush(stdout)
            do {
                try await tools.start(provider)
                let running = await providers.read(provider)
                precondition(running.activity != .offline)
                try await tools.stop(provider)
                let stopped = await providers.read(provider)
                precondition(stopped.activity == .offline)
                print(provider.title, "실제 서버 켜기·끄기 통과"); fflush(stdout)
            } catch {
                try? await tools.stop(provider)
                throw error
            }
        }
    }
}

actor ScanLogger {
    let output: URL
    var previous = Date.distantPast
    init(output: URL) { self.output = output }
    func update(_ report: ModelScanProgress) {
        guard Date().timeIntervalSince(previous) >= 10 else { return }
        previous = Date()
        var checkpoint = report
        checkpoint.completed = false
        if let data = try? JSONEncoder().encode(checkpoint) { try? data.write(to: output, options: .atomic) }
        print("검사", report.visited, "찾음", report.files.count, "읽기 제한", report.unreadable)
        fflush(stdout)
    }
}
