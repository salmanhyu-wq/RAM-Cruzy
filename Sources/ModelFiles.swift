import Foundation
import Combine
import Darwin

struct ModelFile: Identifiable, Sendable, Codable {
    let url: URL
    let bytes: UInt64
    let isDirectory: Bool
    let isLoRA: Bool
    let format: String
    let purpose: ModelPurpose
    var id: String { url.resolvingSymlinksInPath().path }
    var title: String { url.lastPathComponent }

    static let extensions: Set<String> = ["gguf", "safetensors", "ckpt", "pth", "pt", "onnx", "bin"]

    static func inspect(_ url: URL) -> Self? {
        let file = url.standardizedFileURL
        let physical = file.resolvingSymlinksInPath()
        guard file.isFileURL, let type = try? physical.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else { return nil }
        if type.isDirectory == true {
            let contents = (try? FileManager.default.contentsOfDirectory(at: physical, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let names = Set(contents.map(\.lastPathComponent))
            guard names.contains("config.json") || names.contains("model_index.json") || names.contains("adapter_config.json"),
                  contents.contains(where: { extensions.contains($0.pathExtension.lowercased()) }) else { return nil }
            let lora = names.contains("adapter_config.json")
            let gguf = contents.contains { $0.pathExtension.lowercased() == "gguf" }
            var bytes: UInt64 = 0
            var cloudOnly = false
            var seen = Set<String>()
            if let files = FileManager.default.enumerator(at: physical, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsPackageDescendants]) {
                for case let entry as URL in files {
                    let target = entry.resolvingSymlinksInPath()
                    guard seen.insert(target.path).inserted,
                          let value = try? target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), value.isRegularFile == true else { continue }
                    bytes += UInt64(max(0, value.fileSize ?? 0))
                    var flags = stat()
                    if lstat(target.path, &flags) == 0, flags.st_flags & UInt32(SF_DATALESS) != 0 { cloudOnly = true }
                }
            }
            return Self(url: file, bytes: bytes, isDirectory: true, isLoRA: lora, format: (gguf ? "GGUF 묶음" : "모델 폴더") + (cloudOnly ? " · 다운로드 필요" : ""),
                        purpose: lora ? .lora : ModelPurpose.guess(file.lastPathComponent))
        }
        guard type.isRegularFile == true, extensions.contains(file.pathExtension.lowercased()) else { return nil }
        let ext = file.pathExtension.lowercased()
        let bytes = UInt64(max(0, type.fileSize ?? 0))
        var lora = file.pathComponents.contains { $0.lowercased().contains("lora") } || file.lastPathComponent.lowercased().contains("adapter")
        var diskInfo = stat()
        if lstat(physical.path, &diskInfo) == 0, diskInfo.st_flags & UInt32(SF_DATALESS) != 0 {
            return Self(url: file, bytes: bytes, isDirectory: false, isLoRA: lora, format: ext.uppercased() + " · 다운로드 필요",
                        purpose: lora ? .lora : ModelPurpose.guess(file.lastPathComponent))
        }
        if ext == "gguf" || ext == "safetensors" {
            guard let handle = try? FileHandle(forReadingFrom: physical) else { return nil }
            defer { try? handle.close() }
            guard let prefix = try? handle.read(upToCount: 8), prefix.count == 8 else { return nil }
            if ext == "gguf" {
                guard prefix.prefix(4) == Data("GGUF".utf8) else { return nil }
            } else {
                let count = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
                guard count > 1, count <= min(bytes - min(bytes, 8), 16_777_216),
                      let header = try? handle.read(upToCount: Int(count)), header.count == Int(count),
                      let json = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
                      json.keys.contains(where: { $0 != "__metadata__" }) else { return nil }
                let keys = json.keys.joined(separator: " ").lowercased()
                let metadata = String(describing: json["__metadata__"] ?? "").lowercased()
                lora = lora || keys.contains("lora_") || keys.contains(".lora") || metadata.contains("lora") || metadata.contains("lycoris")
            }
        } else {
            if bytes < 1_048_576 { return nil }
            if ext == "bin", !file.lastPathComponent.lowercased().contains("model") { return nil }
        }
        let purpose = lora ? ModelPurpose.lora : ModelPurpose.guess(file.lastPathComponent, folder: file.deletingLastPathComponent().lastPathComponent)
        return Self(url: file, bytes: bytes, isDirectory: false, isLoRA: lora, format: ext.uppercased(), purpose: purpose)
    }

    func compatibility(with provider: Provider) -> String? {
        if format.contains("다운로드 필요") { return "클라우드 파일이에요. Finder에서 다운로드한 뒤 추가해 주세요." }
        if provider == .mlxStudio { return "이 서버는 모델 가져오기 기능을 공개하지 않아요. 앱에서 저장 위치를 확인해 주세요." }
        if isLoRA {
            return provider == .comfy || provider == .mlxServe ? nil : "로라는 기본 모델과 함께 쓰는 추가 파일이에요. ComfyUI 또는 MLX-Serve에 연결할 수 있어요."
        }
        if provider == .comfy {
            if isDirectory { return "ComfyUI에는 이미지·영상용 가중치 파일이나 로라를 연결해 주세요." }
            if [.chat, .embedding].contains(purpose) { return "대화용 모델이에요. 대화 모델을 지원하는 서버를 골라 주세요." }
            return nil
        }
        if provider == .splash && [.image, .video, .music, .voice, .embedding, .support].contains(purpose) {
            return "Splash에는 지원하는 대화 모델을 추가해 주세요. 생성용 모델과 보조 파일은 해당 작업 서버에서 사용해요."
        }
        if !isDirectory && url.pathExtension.lowercased() != "gguf" {
            return "이 서버에는 GGUF 파일 또는 설정과 가중치가 함께 있는 모델 폴더를 연결해 주세요."
        }
        if provider == .lmStudio && [.image, .video, .music, .voice, .support].contains(purpose) {
            return "LM Studio에서 지원하는 대화·임베딩 모델을 골라 주세요."
        }
        return nil
    }
}

struct ModelScanProgress: Sendable, Codable {
    var visited = 0
    var unreadable = 0
    var location = ""
    var files: [ModelFile] = []
    var completed: Bool? = nil
    var cloudIndexUsed: Bool? = nil
}

enum ModelDriveScanner {
    static func roots() -> [URL] {
        let files = FileManager.default
        let volumes = (try? files.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: [.volumeIsLocalKey])) ?? []
        let known = ModelLibrary.roots().map(\.1).filter { files.fileExists(atPath: $0.path) }
        let attached = volumes.filter {
            $0.resolvingSymlinksInPath().path != "/" && (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
        }
        return known + attached + [URL(fileURLWithPath: "/")]
    }

    static func scan(_ roots: [URL], knownFiles: [ModelFile] = [], update: @escaping @Sendable (ModelScanProgress) async -> Void) async -> ModelScanProgress {
        var progress = ModelScanProgress()
        var seen = Set<String>()
        var packages = Set<String>()
        var finishedRoots = Set<String>()
        var last = Date.distantPast
        var excluded: Set<String> = ["/System", "/dev", "/Volumes", "/proc", "/private/var/vm", "/.vol", "/net", "/home", "/Network"]
        let cloud = ModelLibrary.home.appendingPathComponent("Library/CloudStorage")
        var candidates = knownFiles.map(\.url).filter { file in roots.contains { $0.path == "/" || file.path.hasPrefix($0.path + "/") } }
        if roots.contains(where: { $0.path == "/" }), FileManager.default.fileExists(atPath: cloud.path) {
            let query = ModelFile.extensions.sorted().map { "kMDItemFSName == \"*.\($0)\"cd" }.joined(separator: " || ")
            if let output = try? await ServerTools.run(URL(fileURLWithPath: "/usr/bin/mdfind"),
                ["-0", "-onlyin", cloud.path, query], timeout: 30, outputLimit: 16_777_216) {
                candidates += output.split(separator: "\0").compactMap { part in
                    guard let range = part.range(of: cloud.path + "/") else { return nil }
                    return URL(fileURLWithPath: String(part[range.lowerBound...]))
                }
                progress.cloudIndexUsed = true
                excluded.insert(cloud.path)
            }
        }
        let markers = ["config.json", "model_index.json", "adapter_config.json"]
        for file in candidates {
            if Task.isCancelled { break }
            progress.visited += 1
            let parent = file.deletingLastPathComponent()
            if packages.contains(parent.path) { continue }
            let grouped = markers.contains { FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path) }
            let model = grouped ? ModelFile.inspect(parent) ?? ModelFile.inspect(file) : ModelFile.inspect(file)
            if let model, seen.insert(model.id).inserted {
                progress.files.append(model)
                if model.isDirectory { packages.insert(model.url.path) }
            }
            if Date().timeIntervalSince(last) >= 0.6 {
                progress.location = parent.path
                await update(progress)
                last = Date()
            }
        }
        for root in roots {
            if Task.isCancelled { break }
            if finishedRoots.contains(root.standardizedFileURL.path) { continue }
            guard let iterator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [], options: [.skipsPackageDescendants],
                errorHandler: { _, _ in progress.unreadable += 1; return true }) else {
                progress.unreadable += 1
                continue
            }
            while let file = iterator.nextObject() as? URL {
                if Task.isCancelled { break }
                progress.visited += 1
                if excluded.contains(file.path) || finishedRoots.contains(file.standardizedFileURL.path) ||
                    [".Trashes", ".Spotlight-V100", ".fseventsd"].contains(file.lastPathComponent) {
                    iterator.skipDescendants()
                    continue
                }
                if ModelFile.extensions.contains(file.pathExtension.lowercased()) {
                    let parent = file.deletingLastPathComponent()
                    if !packages.contains(parent.path) {
                        let grouped = markers.contains { FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path) }
                        let model = grouped ? ModelFile.inspect(parent) ?? ModelFile.inspect(file) : ModelFile.inspect(file)
                        if let model, seen.insert(model.id).inserted {
                            progress.files.append(model)
                            if model.isDirectory { packages.insert(model.url.path) }
                        }
                    }
                }
                if Date().timeIntervalSince(last) >= 0.6 {
                    progress.location = file.deletingLastPathComponent().path
                    await update(progress)
                    last = Date()
                }
            }
            finishedRoots.insert(root.standardizedFileURL.path)
        }
        progress.completed = !Task.isCancelled
        return progress
    }

}

@MainActor final class ModelDiscovery: ObservableObject {
    @Published private(set) var progress = ModelScanProgress()
    @Published private(set) var running = false
    @Published private(set) var finished = false
    @Published private(set) var cancelled = false
    private static var inventory: URL {
        ModelLibrary.home.appendingPathComponent("Library/Application Support/AI 램 관리/model-inventory-v1.json")
    }
    init() {
        if let data = try? Data(contentsOf: Self.inventory), data.count < 25_000_000,
           let saved = try? JSONDecoder().decode(ModelScanProgress.self, from: data) {
            progress = saved
            finished = true
            cancelled = saved.completed == false
        }
    }
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start(roots: [URL] = ModelDriveScanner.roots()) {
        guard !running else { return }
        running = true
        finished = false
        cancelled = false
        let known = progress.files
        progress = ModelScanProgress()
        let id = UUID()
        generation = id
        task = Task.detached(priority: .utility) { [weak self] in
            let result = await ModelDriveScanner.scan(roots, knownFiles: known) { [weak self] report in
                await self?.receive(report, generation: id)
            }
            await self?.complete(result, generation: id)
        }
    }

    private func receive(_ report: ModelScanProgress, generation: UUID) {
        guard self.generation == generation else { return }
        progress = report
    }

    private func complete(_ result: ModelScanProgress, generation: UUID) {
        guard self.generation == generation else { return }
        progress = result
        running = false
        finished = true
        task = nil
        if let data = try? JSONEncoder().encode(result) {
            try? FileManager.default.createDirectory(at: Self.inventory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.inventory, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.inventory.path)
        }
    }

    func cancel() { cancelled = true; task?.cancel() }
    deinit { task?.cancel() }
}

struct ModelTransferRequest: Identifiable {
    let id = UUID()
    let files: [ModelFile]
    let provider: Provider
}

enum ModelTransferMode: String, CaseIterable, Identifiable {
    case link = "공유 연결", copy = "복사해서 추가"
    var id: Self { self }
}

enum ComfyModelFolder: String, CaseIterable, Identifiable {
    case automatic = "자동 분류", checkpoints = "이미지 전체 모델", diffusion_models = "이미지·영상 가중치"
    case loras = "로라", vae = "이미지 변환 모델", text_encoders = "글 이해 모델"
    case controlnet = "구도·자세 보조", upscale_models = "화질 확대 모델", audio_encoders = "소리 이해 모델"
    var id: Self { self }
    var folder: String? {
        switch self {
        case .automatic: nil
        case .checkpoints: "checkpoints"
        case .diffusion_models: "diffusion_models"
        case .loras: "loras"
        case .vae: "vae"
        case .text_encoders: "text_encoders"
        case .controlnet: "controlnet"
        case .upscale_models: "upscale_models"
        case .audio_encoders: "audio_encoders"
        }
    }
}

enum ModelFileTransfer {
    static func destination(for file: ModelFile, to provider: Provider, root override: URL? = nil, category: ComfyModelFolder = .automatic) -> URL {
        let root = override ?? ModelLibrary.roots().first { $0.0 == provider }!.1
        if provider == .comfy {
            let name = file.title.lowercased()
            let knownFolders: Set<String> = ["checkpoints", "diffusion_models", "unet", "vae", "text_encoders", "clip", "controlnet", "upscale_models", "audio_encoders"]
            let original = file.url.deletingLastPathComponent().lastPathComponent
            let folder: String
            if file.isLoRA { folder = "loras" }
            else if let selected = category.folder { folder = selected }
            else if knownFolders.contains(original) { folder = original }
            else if name.contains("vae") { folder = "vae" }
            else if name.contains("clip") || name.contains("t5") { folder = "text_encoders" }
            else if name.contains("controlnet") { folder = "controlnet" }
            else if name.contains("sdxl") || file.url.pathExtension.lowercased() == "ckpt" { folder = "checkpoints" }
            else if file.url.pathExtension.lowercased() == "pth" { folder = "upscale_models" }
            else { folder = "diffusion_models" }
            return root.appendingPathComponent(folder).appendingPathComponent(file.title)
        }
        if provider == .splash { return root.appendingPathComponent(file.title) }
        let group = root.appendingPathComponent("RamCruji")
        if provider == .lmStudio, !file.isDirectory {
            return group.appendingPathComponent(file.url.deletingPathExtension().lastPathComponent).appendingPathComponent(file.title)
        }
        if file.isLoRA { return root.appendingPathComponent("loras").appendingPathComponent(file.title) }
        return group.appendingPathComponent(file.title)
    }

    private static func copyContents(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let type = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if type.isSymbolicLink == true {
            let physical = source.resolvingSymlinksInPath()
            if (try physical.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                throw ManagementError.message("모델 안에 공유 폴더가 있어요. 이 항목은 공유 연결로 추가해 주세요.")
            }
            try manager.copyItem(at: physical, to: destination)
        } else if type.isDirectory == true {
            try manager.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                if Task.isCancelled { throw CancellationError() }
                try copyContents(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            try manager.copyItem(at: source, to: destination)
        }
    }

    static func add(_ files: [ModelFile], to provider: Provider, mode: ModelTransferMode, root: URL? = nil, category: ComfyModelFolder = .automatic) throws -> [URL] {
        let manager = FileManager.default
        let plans = try files.map { file -> (ModelFile, URL) in
            if let reason = file.compatibility(with: provider) { throw ManagementError.message(reason) }
            guard let fresh = ModelFile.inspect(file.url), fresh.id == file.id, fresh.bytes == file.bytes else { throw ManagementError.message("파일 상태가 바뀌었어요. 다시 찾아 주세요.") }
            let destination = destination(for: file, to: provider, root: root, category: category)
            guard !manager.fileExists(atPath: destination.path), (try? manager.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
                throw ManagementError.message("‘\(file.title)’과 같은 이름이 대상 서버에 있어요.")
            }
            guard !destination.standardizedFileURL.path.hasPrefix(file.url.standardizedFileURL.path + "/") else {
                throw ManagementError.message("모델 폴더 안으로 같은 모델을 추가할 수 없어요.")
            }
            return (file, destination)
        }
        guard Set(plans.map { $0.1.path }).count == plans.count else { throw ManagementError.message("같은 이름의 파일이 여러 개예요. 하나씩 추가해 주세요.") }
        var completed: [URL] = []
        do {
            for (file, destination) in plans {
                if Task.isCancelled { throw CancellationError() }
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(".ram-import-" + UUID().uuidString)
                defer { try? manager.removeItem(at: temporary) }
                if mode == .link { try manager.createSymbolicLink(at: temporary, withDestinationURL: file.url.resolvingSymlinksInPath()) }
                else { try copyContents(file.url.resolvingSymlinksInPath(), to: temporary) }
                try manager.moveItem(at: temporary, to: destination)
                completed.append(destination)
            }
            return completed
        } catch {
            for path in completed { try? manager.removeItem(at: path) }
            throw error
        }
    }
}
