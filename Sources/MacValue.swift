import Foundation

struct MacValue: Codable {
    let name: String
    let identifier: String
    let chip: String
    let cpu: Int
    let gpu: Int?
    let memoryGB: Int
    let storageGB: Int?
    var officialPrice: Int?
    var priceURL: URL?
    var priceCheckedAt: Date?

    var purchasePage: URL? {
        let slug: String
        switch name {
        case "Mac Studio": slug = "mac-studio"
        case "Mac mini": slug = "mac-mini"
        case "iMac": slug = "imac"
        case "MacBook Air": slug = "macbook-air"
        case "MacBook Pro": slug = "macbook-pro"
        case "MacBook Neo": slug = "macbook-neo"
        default: return nil
        }
        return URL(string: "https://www.apple.com/kr/shop/buy-mac/" + slug)
    }

    var storageLabel: String? {
        storageGB.map { $0 >= 1000 ? "\($0 / 1000) TB" : "\($0) GB" }
    }

    static func detect() -> Self? {
        let report = output("/usr/sbin/system_profiler", ["SPHardwareDataType", "SPDisplaysDataType", "-detailLevel", "mini", "-json"])
        guard let report, let root = (try? JSONSerialization.jsonObject(with: report)) as? [String: Any],
              let hardware = (root["SPHardwareDataType"] as? [[String: Any]])?.first,
              let name = hardware["machine_name"] as? String, let model = hardware["machine_model"] as? String else { return nil }
        let gpu = (root["SPDisplaysDataType"] as? [[String: Any]])?.compactMap {
            ($0["sppci_cores"] as? String).flatMap(Int.init) ?? ($0["sppci_cores"] as? Int)
        }.first
        let storage = output("/usr/sbin/diskutil", ["info", "-plist", "/"]).flatMap { data -> Int? in
            guard let disk = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  disk["Internal"] as? Bool == true,
                  let bytes = (disk["APFSContainerSize"] ?? disk["TotalSize"]) as? NSNumber else { return nil }
            let gb = bytes.doubleValue / 1_000_000_000
            return [128, 256, 512, 1000, 2000, 4000, 8000, 16000].first { abs(Double($0) - gb) < Double($0) * 0.035 }
        }
        let chip = ((hardware["chip_type"] ?? hardware["processor_name"]) as? String) ?? ""
        return Self(name: name, identifier: model, chip: chip, cpu: ProcessInfo.processInfo.processorCount,
                    gpu: gpu, memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824), storageGB: storage)
    }

    private static func output(_ path: String, _ arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    mutating func fetchPrice() async {
        priceCheckedAt = .now
        guard let page = purchasePage, let specifications else { return }
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false
        settings.timeoutIntervalForRequest = 8
        settings.timeoutIntervalForResource = 12
        let session = URLSession(configuration: settings)
        defer { session.finishTasksAndInvalidate() }
        func read(_ url: URL) async -> String? {
            guard let (body, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.host == "www.apple.com", http.url?.scheme == "https",
                  http.url?.path.hasPrefix("/kr/shop/buy-mac/") == true,
                  body.count < 4_000_000 else { return nil }
            return String(data: body, encoding: .utf8)
        }

        let compactPath = specifications.chip.lowercased().replacingOccurrences(of: " ", with: "-")
        var pages: [URL] = []
        if let listing = await read(page) {
            let paths = Self.matches(#"href\s*=\s*"([^"]+)""#, in: listing)
            for path in paths {
                guard let url = URL(string: path.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: page)?.absoluteURL,
                      url.host == page.host, url.scheme == "https", url.path.hasPrefix(page.path + "/") else { continue }
                let decoded = url.path.lowercased()
                if decoded.contains(compactPath), decoded.contains("-\(memoryGB)gb-"),
                   decoded.contains("-\(specifications.storageToken)-"), !pages.contains(url) {
                    pages.append(url)
                }
            }
        }
        if name == "Mac Studio" {
            let path = "\(compactPath)-칩-\(cpu)코어-cpu-\(specifications.gpu)코어-gpu-\(memoryGB)gb-메모리-\(specifications.storageToken)-저장-장치"
            let exact = page.appendingPathComponent(path)
            if !pages.contains(exact) { pages.append(exact) }
        }
        for url in pages.prefix(3) {
            if let html = await read(url), let quote = officialQuote(html: html) {
                officialPrice = quote
                priceURL = url
                return
            }
        }
    }

    private var specifications: (chip: String, gpu: Int, storageToken: String)? {
        guard ["Mac Studio", "Mac mini"].contains(name), let gpu, let storageGB, !chip.isEmpty else { return nil }
        let raw = chip.hasPrefix("Apple ") ? String(chip.dropFirst(6)) : chip
        return (raw, gpu, storageGB >= 1000 ? "\(storageGB / 1000)tb" : "\(storageGB)gb")
    }

    func officialQuote(html: String) -> Int? {
        guard let specifications else { return nil }
        for payload in Self.matches(#"(?is)<script\b[^>]*type\s*=\s*"application/ld\+json"[^>]*>(.*?)</script>"#, in: html) {
            guard let data = payload.data(using: .utf8),
                  let product = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  product["@type"] as? String == "Product", let title = product["name"] as? String,
                  let rawURL = product["url"] as? String, let link = URL(string: rawURL),
                  link.host == "www.apple.com", link.scheme == "https", link.path.hasPrefix("/kr/shop/buy-mac/") else { continue }
            let clean = title.lowercased().filter { !$0.isWhitespace }
            let expected = [name, specifications.chip, ",\(cpu)코어CPU", ",\(specifications.gpu)코어GPU",
                            ",\(memoryGB)GB메모리", ",\(specifications.storageToken)저장장치"]
            guard expected.allSatisfy({ clean.contains($0.lowercased().filter { !$0.isWhitespace }) }) else { continue }
            let offers = product["offers"] as? [[String: Any]] ?? (product["offers"] as? [String: Any]).map { [$0] } ?? []
            let amounts = Set(offers.compactMap { offer -> Int? in
                guard offer["@type"] as? String == "Offer", offer["priceCurrency"] as? String == "KRW" else { return nil }
                let value = (offer["price"] as? NSNumber)?.intValue ?? (offer["price"] as? String).flatMap(Int.init)
                return value.flatMap { (100_000...100_000_000).contains($0) ? $0 : nil }
            })
            if amounts.count == 1 { return amounts.first }
        }
        return nil
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
