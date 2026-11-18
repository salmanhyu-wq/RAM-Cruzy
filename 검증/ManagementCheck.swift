import AppKit
import SwiftUI

@main enum ManagementCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ram-management-test-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var gguf = Data("GGUF".utf8)
        gguf.append(Data(repeating: 0, count: 32))
        let ggufURL = source.appendingPathComponent("test-chat.gguf")
        try gguf.write(to: ggufURL)
        let header = try JSONSerialization.data(withJSONObject: ["lora_A.weight": ["dtype": "F16", "shape": [2, 2], "data_offsets": [0, 8]]])
        var count = UInt64(header.count).littleEndian
        var lora = withUnsafeBytes(of: &count) { Data($0) }
        lora.append(header)
        lora.append(Data(repeating: 0, count: 8))
        let loraURL = source.appendingPathComponent("style.safetensors")
        try lora.write(to: loraURL)
        try Data("unrelated data".utf8).write(to: source.appendingPathComponent("broken.safetensors"))
        let package = source.appendingPathComponent("Qwen-model")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: package.appendingPathComponent("config.json"))
        try gguf.write(to: package.appendingPathComponent("weights.gguf"))
        let report = await ModelDriveScanner.scan([source]) { _ in }
        precondition(report.files.count == 3 && report.files.filter(\.isLoRA).count == 1)
        let newFile = source.appendingPathComponent("new-sibling.gguf")
        try gguf.write(to: newFile)
        let cachedPackage = report.files.filter(\.isDirectory)
        precondition(cachedPackage.count == 1)
        let rescanned = await ModelDriveScanner.scan([source], knownFiles: cachedPackage) { _ in }
        precondition(rescanned.files.count == 4 && rescanned.files.contains { $0.url.lastPathComponent == "new-sibling.gguf" })
        guard let weight = ModelFile.inspect(ggufURL), let adapter = ModelFile.inspect(loraURL) else { fatalError("모델 인식 실패") }
        precondition(adapter.compatibility(with: .lmStudio) != nil && adapter.compatibility(with: .comfy) == nil)
        let sharedRoot = root.appendingPathComponent("shared")
        let paths = try ModelFileTransfer.add([weight], to: .lmStudio, mode: .link, root: sharedRoot)
        precondition(paths[0].resolvingSymlinksInPath() == ggufURL)
        do { _ = try ModelFileTransfer.add([weight], to: .lmStudio, mode: .link, root: sharedRoot); fatalError("중복을 덮어씀") }
        catch { precondition(FileManager.default.fileExists(atPath: ggufURL.path)) }
        let copies = try ModelFileTransfer.add([adapter], to: .comfy, mode: .copy, root: root.appendingPathComponent("copy"))
        let copied = try Data(contentsOf: copies[0])
        precondition(copied == lora)
        precondition(copies[0].deletingLastPathComponent().lastPathComponent == "loras")
        let tokenizer = source.appendingPathComponent("tokenizer.txt")
        try Data("vocabulary".utf8).write(to: tokenizer)
        try FileManager.default.createSymbolicLink(atPath: package.appendingPathComponent("tokenizer.txt").path, withDestinationPath: "../tokenizer.txt")
        let bundle = ModelFile.inspect(package)!
        let bundleCopies = try ModelFileTransfer.add([bundle], to: .mlxServe, mode: .copy, root: root.appendingPathComponent("bundle-copy"))
        let materialized = bundleCopies[0].appendingPathComponent("tokenizer.txt")
        let copiedTokenizer = try Data(contentsOf: materialized)
        precondition(copiedTokenizer == Data("vocabulary".utf8))
        precondition((try? materialized.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false)
        let home = root.appendingPathComponent("home")
        let target = home.appendingPathComponent(".mlx-serve/models/RamCruji/Qwen-model")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: package)
        precondition(ModelLibrary.scan(home: home).contains { $0.url.resolvingSymlinksInPath() == package.resolvingSymlinksInPath() && $0.isLinked && !$0.canTrash })
        let model = DashboardModel(historyURL: nil, preferences: nil)
        model.servers = Provider.allCases.map { ServerReading(id: $0, detail: "", activity: .offline) }
        precondition(model.loadPrompt(LocalModel(provider: .lmStudio, url: ggufURL, root: source, key: "test", title: "test", purpose: .chat, bytes: 36, canTrash: false, isLinked: false))?.destructive == false)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try draw(ServerControlGrid(model: model), width: 670, name: "servers", directory: directory)
        try draw(QuickServerControls(model: model, confirm: { _ in }, openLibrary: {}), width: 392, name: "quick-servers", directory: directory)
        try draw(ModelTransferSheet(model: model, request: ModelTransferRequest(files: [adapter], provider: .comfy)), width: 554, name: "transfer", directory: directory)
        try draw(DriveModelSearch(model: model, discovery: model.discovery), width: 840, name: "drive-search", directory: directory)
        print("전체 탐색·로라 식별·묶음 중복 방지·공유 링크·복사·중복 보호·기존 보관함의 링크 인식 검증 통과")
    }

    @MainActor static func draw<V: View>(_ content: V, width: CGFloat, name: String, directory: URL) throws {
        let view = NSHostingView(rootView: content.padding(16).background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: .darkAqua)
        let frame = NSRect(x: 0, y: 0, width: width, height: view.fittingSize.height.rounded(.up))
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = view.appearance
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        let image = view.bitmapImageRepForCachingDisplay(in: frame)!
        view.cacheDisplay(in: frame, to: image)
        try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
