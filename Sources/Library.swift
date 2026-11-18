import Darwin
import Foundation

enum ModelPurpose: String, CaseIterable, Identifiable, Codable {
    case chat = "대화", image = "이미지", video = "영상", music = "음악", lora = "로라"
    case voice = "음성", embedding = "임베딩", support = "보조 모델", other = "기타"
    var id: Self { self }

    static func guess(_ name: String, folder: String = "", metadata: String = "", default fallback: Self = .other) -> Self {
        let n = (name + " " + metadata).lowercased()
        let has: ([String]) -> Bool = { needles in needles.contains { n.contains($0) } }
        if has(["mmproj"]) { return .support }
        if folder == "loras" || has(["lora", "lycoris", "adapter_model"]) { return .lora }
        if ["vae", "vae_approx", "text_encoders", "clip", "clip_vision", "controlnet",
            "model_patches", "embeddings", "upscale_models", "style_models", "latent_upscale_models"].contains(folder) {
            return .support
        }
        if has(["-tts", "whisper", "kokoro", "parakeet", "asr", "ttsmodel", "qwen3_tts"]) { return .voice }
        if has(["ace-step", "acestep", "minimax-music", "-music", "yue2", "stable-audio"]) { return .music }
        if has(["ltx-video", "ltx-2", "wan2", "wan-2", "wan_2", "hunyuanvideo", "minimax-h3", "hunyuan_video", "h3-fl2va", "video"]) {
            return .video
        }
        if has(["embedding", "rerank", "bge-", "nomic-embed"]) { return .embedding }
        if has(["qwen-image", "qwen_image", "flux", "z-image", "zimage", "krea", "stable-diffusion", "sdxl", "pixart", "mage-flow", "hidream"]) {
            return .image
        }
        if folder == "audio_encoders" { return .support }
        if folder == "frame_interpolation" { return .video }
        if has(["qwen", "llama", "gemma", "mistral", "deepseek", "gpt-", "bonsai", "ornith", "minimax", "lfm", "glm"]) { return .chat }
        return fallback
    }
}

struct LocalModel: Identifiable, Sendable {
    let provider: Provider
    let url: URL
    let root: URL
    let key: String
    let title: String
    let purpose: ModelPurpose
    let bytes: UInt64
    let canTrash: Bool
    let isLinked: Bool
    var id: String { provider.rawValue + ":" + url.path }
    var aliases: Set<String> { Set([key, title, url.lastPathComponent].map(modelKey)) }
}

func modelKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
}

enum ModelLibrary {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let weights: Set<String> = ["gguf", "safetensors", "ckpt", "pth", "pt", "onnx", "bin"]
    private static let comfyFolders = Set(["checkpoints", "clip", "clip_vision", "controlnet", "diffusers",
        "diffusion_models", "embeddings", "frame_interpolation", "loras", "model_patches", "unet",
        "style_models", "text_encoders", "audio_encoders", "upscale_models", "vae", "vae_approx", "latent_upscale_models"])
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]

    static func scan(home folder: URL = home) -> [LocalModel] {
        roots(home: folder).flatMap { provider, root in list(provider, root: root) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func roots(home folder: URL = home) -> [(Provider, URL)] {
        let splash = folder.appendingPathComponent("Library/Application Support/Splash")
        let lmRoot = readLMRoot(folder)
        let comfy = folder.appendingPathComponent("Documents/ComfyUI/models")
        var roots: [(Provider, URL)] = [
            (.splash, splash.appendingPathComponent("local-models")),
            (.mlxServe, folder.appendingPathComponent(".mlx-serve/models")),
            (.lmStudio, lmRoot.appendingPathComponent("models")),
            (.mlxStudio, folder.appendingPathComponent(".mlxstudio/models")),
            (.comfy, comfy)
        ]
        let bundled = lmRoot.appendingPathComponent(".internal/bundled-models")
        if FileManager.default.fileExists(atPath: bundled.path) { roots.append((.lmStudio, bundled)) }
        let cache = lmRoot.appendingPathComponent(".internal/model-index-cache.json")
        if let bytes = try? Data(contentsOf: cache), bytes.count < 16_000_000,
           let index = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let models = index["models"] as? [[String: Any]] {
            for model in models {
                guard let entry = model["entryPoint"] as? [String: Any], let path = entry["rootAbsolutePath"] as? String,
                      path.hasPrefix("/"), path != "/", !roots.contains(where: { $0.0 == .lmStudio && $0.1.path == path }) else { continue }
                roots.append((.lmStudio, URL(fileURLWithPath: path)))
            }
        }
        return roots
    }

    private static func readLMRoot(_ home: URL) -> URL {
        let fallback = home.appendingPathComponent(".lmstudio")
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".lmstudio-home-pointer")),
              data.count < 4096, let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("/") else { return fallback }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }

    private static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
    }

    private static func list(_ provider: Provider, root: URL) -> [LocalModel] {
        let first = children(root)
        switch provider {
        case .splash:
            return first.compactMap { model($0, root: root, provider: provider, scope: "local") }
        case .mlxServe, .lmStudio, .mlxStudio:
            return first.flatMap { owner -> [LocalModel] in
                if let direct = model(owner, root: root, provider: provider, scope: "") { return [direct] }
                guard safeDirectory(owner) else { return [] }
                return children(owner).flatMap { candidate -> [LocalModel] in
                    let scope = owner.lastPathComponent
                    if provider == .lmStudio, safeDirectory(candidate) {
                        let contained = children(candidate).filter { $0.pathExtension.lowercased() == "gguf" }
                        if !contained.isEmpty {
                            return contained.compactMap { model($0, root: root, provider: provider, scope: scope + "/" + candidate.lastPathComponent) }
                        }
                    }
                    return model(candidate, root: root, provider: provider, scope: scope).map { [$0] } ?? []
                }
            }
        case .comfy:
            return first.filter { comfyFolders.contains($0.lastPathComponent) && safeDirectory($0) }.flatMap { category -> [LocalModel] in
                guard let files = FileManager.default.enumerator(at: category, includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { return [] }
                var result: [LocalModel] = []
                for case let file as URL in files {
                    guard result.count < 1500 else { break }
                    let permitsPackage = category.lastPathComponent == "diffusers"
                    if let row = model(file, root: root, provider: provider, scope: category.lastPathComponent, permitDirectory: permitsPackage) {
                        if permitsPackage && safeDirectory(file) { files.skipDescendants() }
                        result.append(row)
                    }
                }
                return result
            }
        }
    }

    private static func safeDirectory(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: keys) else { return false }
        return type.isDirectory == true && type.isSymbolicLink != true
    }

    private static func model(_ url: URL, root: URL, provider: Provider, scope: String, permitDirectory: Bool = true) -> LocalModel? {
        guard let kind = try? url.resourceValues(forKeys: keys) else { return nil }
        let name = url.lastPathComponent
        let linked = kind.isSymbolicLink == true
        let physical = url.resolvingSymlinksInPath()
        let actual = (try? physical.resourceValues(forKeys: keys)) ?? kind
        var bytes: UInt64 = 0
        var nestedLink = false
        var knownLayout = false
        if actual.isDirectory == true, permitDirectory {
            let entries = children(physical)
            if provider != .splash {
                let markers: Set<String> = ["config.json", "model_index.json", "manifest.json", "split_model.json", "adapter_config.json"]
                guard entries.contains(where: { markers.contains($0.lastPathComponent.lowercased()) }) else { return nil }
            }
            if let traversal = FileManager.default.enumerator(at: physical, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) {
                for case let file as URL in traversal {
                    guard let value = try? file.resourceValues(forKeys: keys) else { continue }
                    nestedLink = nestedLink || value.isSymbolicLink == true
                    let isWeight = weights.contains(file.pathExtension.lowercased()) && !file.lastPathComponent.hasPrefix("mmproj")
                    knownLayout = knownLayout || (isWeight && (value.isRegularFile == true || value.isSymbolicLink == true))
                    if value.isRegularFile == true, value.isSymbolicLink != true { bytes += UInt64(max(0, value.fileSize ?? 0)) }
                }
            }
            guard knownLayout else { return nil }
        } else if kind.isRegularFile == true || linked {
            guard weights.contains(url.pathExtension.lowercased()), !name.hasPrefix("mmproj") else { return nil }
            knownLayout = true
            if !linked { bytes = UInt64(max(0, kind.fileSize ?? 0)) }
        } else {
            return nil
        }
        let relative = String(url.path.dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1)))
        let key = provider == .splash ? "local/" + name : relative
        let metadata: String
        if actual.isDirectory == true,
           let handle = try? FileHandle(forReadingFrom: url.appendingPathComponent("config.json")) {
            let data = (try? handle.read(upToCount: 65_536)) ?? Data()
            try? handle.close()
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            metadata = ([obj?["model_type"] as? String] + ((obj?["architectures"] as? [String] ?? []).map(Optional.some)))
                .compactMap { $0 }.joined(separator: " ")
        } else { metadata = "" }
        let purpose = ModelPurpose.guess(name, folder: provider == .comfy || scope == "loras" ? scope : "", metadata: metadata,
            default: provider == .mlxServe || provider == .comfy ? .other : .chat)
        let safe = knownLayout && !linked && !nestedLink && contained(url, root: root)
        return LocalModel(provider: provider, url: url, root: root, key: key, title: name, purpose: purpose,
            bytes: bytes, canTrash: safe && provider != .mlxStudio && root.lastPathComponent != "bundled-models", isLinked: linked || nestedLink)
    }

    static func contained(_ url: URL, root: URL) -> Bool {
        let expectedRoot = root.standardizedFileURL.path
        let physicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let expected = url.standardizedFileURL.path
        let physical = url.resolvingSymlinksInPath().standardizedFileURL.path
        return expectedRoot == physicalRoot && expected == physical && physical.hasPrefix(physicalRoot + "/")
    }

    static func splashStartupModels() -> Set<String>? {
        let file = home.appendingPathComponent("Library/LaunchAgents/local.splash.model-server.plist")
        guard let bytes = try? Data(contentsOf: file),
              let plist = (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return nil }
        return Set(args.indices.dropLast().compactMap { i -> String? in
            ["--model", "--model-dir", "--draft-model"].contains(args[i]) ? modelKey(URL(fileURLWithPath: args[i + 1]).lastPathComponent) : nil
        })
    }
}
