//
//  AIModelCatalog.swift
//  MacClean
//
//  本地 AI 模型扫描：Ollama、Hugging Face、LM Studio 等下载到本机的模型，每个模型一项。
//  Ollama 的数据块按内容寻址、可被多个模型共用：只统计/删除没有其他模型引用的部分。
//  全部为无状态 nonisolated 静态方法，可在后台线程调用（工程默认 MainActor 隔离）。
//

import AppKit
import Foundation

// MARK: - 来源

nonisolated enum AIModelSource: String, CaseIterable, Sendable {
    case ollama
    case huggingFace
    case lmStudio
    case jan
    case gpt4all
    case diffusionBee
    case comfyUI
    case whisper
    case torchHub
    case llamaCpp
    case mlx

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .huggingFace: return "Hugging Face"
        case .lmStudio: return "LM Studio"
        case .jan: return "Jan"
        case .gpt4all: return "GPT4All"
        case .diffusionBee: return "DiffusionBee"
        case .comfyUI: return "ComfyUI"
        case .whisper: return "Whisper"
        case .torchHub: return "PyTorch Hub"
        case .llamaCpp: return "llama.cpp"
        case .mlx: return "MLX"
        }
    }
}

// MARK: - 位置

/// 各工具的模型目录。默认路径 + 环境变量（OLLAMA_MODELS、HF_HOME、HF_HUB_CACHE / HUGGINGFACE_HUB_CACHE）指定的路径。
nonisolated struct AIModelLocations: Sendable, Equatable {
    var ollamaModels: [String]
    var huggingFaceHomes: [String]
    var huggingFaceHubs: [String]

    /// 环境变量里关心的键。
    static let environmentKeys = ["OLLAMA_MODELS", "HF_HOME", "HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE"]

    static func resolve(home: URL, environment: [String: String]) -> AIModelLocations {
        let homePath = home.standardizedFileURL.path
        func expand(_ key: String) -> String? {
            guard var value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            if value == "~" { value = homePath } else if value.hasPrefix("~/") { value = homePath + value.dropFirst(1) }
            guard value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value).standardizedFileURL.path
        }

        var ollama = [homePath + "/.ollama/models"]
        if let custom = expand("OLLAMA_MODELS") { ollama.append(custom) }

        var hfHomes = [homePath + "/.cache/huggingface"]
        if let custom = expand("HF_HOME") { hfHomes.append(custom) }
        var hubs = hfHomes.map { $0 + "/hub" }
        if let custom = expand("HF_HUB_CACHE") { hubs.append(custom) }
        if let custom = expand("HUGGINGFACE_HUB_CACHE") { hubs.append(custom) }

        return AIModelLocations(
            ollamaModels: ollama.uniquedPaths(),
            huggingFaceHomes: hfHomes.uniquedPaths(),
            huggingFaceHubs: hubs.uniquedPaths()
        )
    }

    /// 本进程环境 + launchd 环境（`launchctl getenv`，非空时优先）。只取一次，后续复用。
    static let currentEnvironment: [String: String] = {
        var result: [String: String] = [:]
        let processEnvironment = ProcessInfo.processInfo.environment
        for key in environmentKeys {
            let output = MaintenanceRunner.runProcess("/bin/launchctl", ["getenv", key])
            let launchdValue = output.status == 0 ? output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !launchdValue.isEmpty {
                result[key] = launchdValue
            } else if let value = processEnvironment[key], !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }()
}

private extension Array where Element == String {
    nonisolated func uniquedPaths() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Ollama 索引

/// 一个 Ollama 模型清单（manifests/<registry>/<namespace>/<model>/<tag>）。
nonisolated struct OllamaManifest: Sendable, Equatable {
    let path: String
    /// 形如 qwen2.5:7b；非官方命名空间带前缀（user/model:tag）。
    let name: String
    /// 引用的数据块摘要（sha256:<hex>）。
    let digests: Set<String>
    /// JSON 能正常解析；解析失败的清单仍按其中出现的摘要保护数据块，但不单独列出。
    let isValid: Bool
    let fileSize: Int64
    let modified: Date?
}

nonisolated struct OllamaIndex: Sendable {
    let modelsRoot: String
    let manifests: [OllamaManifest]
    /// 摘要 → 数据块文件路径与实际占用（只含磁盘上存在的）。
    let blobs: [String: (path: String, size: Int64)]

    var manifestsRoot: String { modelsRoot + "/manifests" }

    /// 删除这些清单后不再被任何剩余清单引用的数据块摘要。
    func unreferencedDigests(removing manifestPaths: Set<String>) -> Set<String> {
        var removed: Set<String> = []
        var kept: Set<String> = []
        for manifest in manifests {
            if manifestPaths.contains(manifest.path) {
                removed.formUnion(manifest.digests)
            } else {
                kept.formUnion(manifest.digests)
            }
        }
        return removed.subtracting(kept).filter { blobs[$0] != nil }
    }

    /// 同时删除这些模型能释放的空间：清单文件 + 不再被引用的数据块（共用数据块只算一次）。
    func reclaimableSize(removing manifestPaths: Set<String>) -> Int64 {
        let manifestBytes = manifests.filter { manifestPaths.contains($0.path) }.reduce(Int64(0)) { $0 + $1.fileSize }
        let blobBytes = unreferencedDigests(removing: manifestPaths).reduce(Int64(0)) { $0 + (blobs[$1]?.size ?? 0) }
        return manifestBytes + blobBytes
    }

    /// 模型完整大小（含共用数据块），即删除后重新下载的量。
    func totalSize(of manifest: OllamaManifest) -> Int64 {
        manifest.digests.reduce(Int64(0)) { $0 + (blobs[$1]?.size ?? 0) }
    }
}

// MARK: - 目录

nonisolated enum AIModelCatalog {

    static let minSize: Int64 = 1024 * 1024

    /// PathGuard 对 aiModels 分类放行的根目录（只做前缀匹配，根目录本身不可删）。
    static func allowedRoots(home: String, environment: [String: String] = AIModelLocations.currentEnvironment) -> [String] {
        var roots = [
            ".ollama/models",
            ".cache/huggingface",
            ".cache/lm-studio",
            ".lmstudio/models",
            "jan",
            "Library/Application Support/Jan",
            "Library/Application Support/nomic.ai/GPT4All",
            ".diffusionbee",
            "ComfyUI/models",
            ".cache/whisper",
            ".cache/torch",
            ".cache/llama.cpp",
            ".cache/mlx",
        ].map { home + "/" + $0 }
        roots += mlxCacheDirectories(home: home)

        // 环境变量指定的目录：只放行确实是该工具布局的目录，避免误设成主目录等宽泛位置时放开整片范围。
        let locations = AIModelLocations.resolve(home: URL(fileURLWithPath: home), environment: environment)
        for root in locations.ollamaModels {
            roots += [root + "/manifests", root + "/blobs"]
        }
        for hub in locations.huggingFaceHubs where looksLikeHuggingFaceHub(hub) {
            roots.append(hub)
        }
        for hfHome in locations.huggingFaceHomes {
            roots += huggingFaceCacheNames.map { hfHome + "/" + $0 }
        }
        return roots.uniquedPaths()
    }

    // MARK: 扫描

    /// 扫描全部来源，按大小降序；全部默认不勾选（模型是用户主动下载的）。
    static func scan(home: URL, environment: [String: String] = AIModelLocations.currentEnvironment) -> [CleanableItem] {
        let homePath = home.standardizedFileURL.path
        let locations = AIModelLocations.resolve(home: home, environment: environment)

        var items: [CleanableItem] = []
        for root in locations.ollamaModels {
            items += scanOllama(modelsRoot: root)
        }
        for hub in locations.huggingFaceHubs {
            items += scanHuggingFaceHub(hub)
        }
        for hfHome in locations.huggingFaceHomes {
            items += scanHuggingFaceCaches(hfHome)
        }
        items += scanLMStudio(home: homePath)
        items += scanMiscellaneous(home: homePath)

        // 同一路径可能被默认路径与环境变量重复指向
        var seen: Set<String> = []
        return items
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.size > $1.size }
    }

    // MARK: Ollama

    static func ollamaIndex(modelsRoot: String) -> OllamaIndex {
        let fileManager = FileManager.default
        let manifestsRoot = modelsRoot + "/manifests"
        let blobsRoot = modelsRoot + "/blobs"
        var manifests: [OllamaManifest] = []

        if let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: manifestsRoot),
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(manifestsRoot + "/") else { continue }
                let relative = String(path.dropFirst(manifestsRoot.count + 1))
                let data = (try? Data(contentsOf: url)) ?? Data()
                let parsed = parseManifest(data)
                manifests.append(OllamaManifest(
                    path: path,
                    name: ollamaModelName(relativePath: relative),
                    digests: parsed.digests,
                    isValid: parsed.isValid,
                    fileSize: CleanupManager.allocatedSize(atPath: path),
                    modified: DevCacheCatalog.modificationDate(of: url)
                ))
            }
        }

        var blobs: [String: (path: String, size: Int64)] = [:]
        for digest in manifests.reduce(into: Set<String>(), { $0.formUnion($1.digests) }) {
            let hex = digest.dropFirst("sha256:".count)
            // 新版文件名 sha256-<hex>，旧版 sha256:<hex>
            for name in ["sha256-\(hex)", "sha256:\(hex)"] {
                let path = blobsRoot + "/" + name
                if fileManager.fileExists(atPath: path) {
                    blobs[digest] = (path, CleanupManager.allocatedSize(atPath: path))
                    break
                }
            }
        }

        return OllamaIndex(modelsRoot: modelsRoot, manifests: manifests, blobs: blobs)
    }

    /// 解析清单 JSON 的 config.digest 与 layers[].digest。解析失败时退而在原文里找所有摘要，宁可多保护。
    static func parseManifest(_ data: Data) -> (digests: Set<String>, isValid: Bool) {
        struct Layer: Decodable { let digest: String? }
        struct Manifest: Decodable { let config: Layer?; let layers: [Layer]? }

        if let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.config != nil || manifest.layers != nil {
            let all = ([manifest.config] + (manifest.layers ?? []).map(Optional.some)).compactMap { $0?.digest }
            return (Set(all.filter(isValidDigest)), true)
        }
        let text = String(decoding: data, as: UTF8.self)
        var digests: Set<String> = []
        if let regex = try? NSRegularExpression(pattern: "sha256[:-]([0-9a-f]{64})") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) {
                    digests.insert("sha256:" + text[range])
                }
            }
        }
        return (digests, false)
    }

    /// 只接受 sha256:<64 位小写十六进制>，防止清单内容拼出 ../ 之类的路径。
    static func isValidDigest(_ digest: String) -> Bool {
        guard digest.hasPrefix("sha256:") else { return false }
        let hex = digest.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// registry.ollama.ai/library/qwen2.5/7b → qwen2.5:7b；registry.ollama.ai/user/m/latest → user/m:latest。
    static func ollamaModelName(relativePath: String) -> String {
        var parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return relativePath }
        let tag = parts.removeLast()
        if parts.first == "registry.ollama.ai" {
            parts.removeFirst()
            if parts.first == "library", parts.count > 1 { parts.removeFirst() }
        }
        return parts.joined(separator: "/") + ":" + tag
    }

    static func scanOllama(modelsRoot: String) -> [CleanableItem] {
        let index = ollamaIndex(modelsRoot: modelsRoot)
        return index.manifests.compactMap { manifest in
            guard manifest.isValid else { return nil }
            let total = index.totalSize(of: manifest)
            // 云端模型（xxx:cloud）只有几百字节的配置，不值得列出
            guard total >= minSize else { return nil }
            let reclaimable = index.reclaimableSize(removing: [manifest.path])
            let shared = max(0, total + manifest.fileSize - reclaimable)

            var description = redownloadNote(total)
            if shared >= minSize {
                description += String(localized: "；其中 \(format(shared)) 与其他模型共用，一起删除时才会释放")
            }
            var item = CleanableItem(
                name: "\(manifest.name) · Ollama",
                path: manifest.path,
                size: reclaimable,
                category: .aiModels,
                isSelected: false,
                description: description,
                lastModified: manifest.modified
            )
            item.removesContainer = true
            return item
        }
    }

    /// 清理前把选中的 Ollama 模型展开为「清单文件 + 不再被任何剩余模型引用的数据块」；其他条目原样返回。
    /// 每次都重新读取磁盘上的全部清单，选中多个共用数据块的模型时共用部分也一并删除。
    static func prepareForCleaning(_ items: [CleanableItem], environment: [String: String] = AIModelLocations.currentEnvironment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CleanableItem] {
        let roots = AIModelLocations.resolve(home: home, environment: environment).ollamaModels
        var passthrough: [CleanableItem] = []
        var byRoot: [String: [CleanableItem]] = [:]
        for item in items {
            if let root = roots.first(where: { item.path.hasPrefix($0 + "/manifests/") }) {
                byRoot[root, default: []].append(item)
            } else {
                passthrough.append(item)
            }
        }

        var result: [CleanableItem] = []
        for (root, selected) in byRoot {
            result += ollamaCleanupItems(selected, index: ollamaIndex(modelsRoot: root), homeDirectory: home)
        }
        return result + passthrough
    }

    static func ollamaCleanupItems(_ selected: [CleanableItem], index: OllamaIndex, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CleanableItem] {
        let known = Dictionary(index.manifests.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        // 只有能通过路径校验的清单才删它的数据块：清单删不掉时数据块也必须留着，否则模型会损坏。
        let removable = selected.filter { item in
            known[item.path] != nil
                && (try? PathGuard.validate(path: item.path, category: .aiModels, removesContainer: true, homeDirectory: homeDirectory)) != nil
        }
        let removingPaths = Set(removable.map(\.path))

        var result: [CleanableItem] = removable.map { item in
            var manifestItem = item
            manifestItem.size = known[item.path]?.fileSize ?? 0
            return manifestItem
        }
        for digest in index.unreferencedDigests(removing: removingPaths).sorted() {
            guard let blob = index.blobs[digest] else { continue }
            let owner = index.manifests.first { removingPaths.contains($0.path) && $0.digests.contains(digest) }
            var blobItem = CleanableItem(
                name: String(localized: "\(owner?.name ?? "Ollama") · 模型数据"),
                path: blob.path,
                size: blob.size,
                category: .aiModels,
                isSelected: true,
                description: nil
            )
            blobItem.removesContainer = true
            result.append(blobItem)
        }
        return result
    }

    // MARK: Hugging Face

    /// HF_HOME 下可整体删除的缓存目录（hub 单独按模型列出；token 等配置文件不碰）。
    static let huggingFaceCacheNames = ["xet", "modules", "datasets", "assets"]

    static func looksLikeHuggingFaceHub(_ path: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return names.contains("version.txt") || names.contains { huggingFaceKind(of: $0) != nil }
    }

    /// models--org--name → 模型；datasets-- → 数据集；spaces-- → Space。
    static func huggingFaceKind(of folderName: String) -> (prefix: String, label: String)? {
        if folderName.hasPrefix("models--") { return ("models--", "Hugging Face") }
        if folderName.hasPrefix("datasets--") { return ("datasets--", String(localized: "Hugging Face 数据集")) }
        if folderName.hasPrefix("spaces--") { return ("spaces--", "Hugging Face Space") }
        return nil
    }

    static func scanHuggingFaceHub(_ hub: String) -> [CleanableItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: hub) else { return [] }
        return names.compactMap { name in
            guard let kind = huggingFaceKind(of: name) else { return nil }
            let path = hub + "/" + name
            guard isDirectory(path) else { return nil }
            // snapshots/ 下是指向 blobs/ 的符号链接，按 lstat 统计不会重复计入
            let size = CleanupManager.allocatedSize(atPath: path)
            guard size >= minSize else { return nil }
            let repo = name.dropFirst(kind.prefix.count).replacingOccurrences(of: "--", with: "/")
            let modified = ["", "/blobs", "/snapshots", "/refs"]
                .compactMap { DevCacheCatalog.modificationDate(of: URL(fileURLWithPath: path + $0)) }
                .max()
            return modelItem(name: "\(repo) · \(kind.label)", path: path, size: size, modified: modified)
        }
    }

    static func scanHuggingFaceCaches(_ hfHome: String) -> [CleanableItem] {
        huggingFaceCacheNames.compactMap { name in
            let path = hfHome + "/" + name
            guard isDirectory(path) else { return nil }
            let size = CleanupManager.allocatedSize(atPath: path)
            guard size >= minSize else { return nil }
            var item = CleanableItem(
                name: String(localized: "Hugging Face 缓存 · \(name)"),
                path: path,
                size: size,
                category: .aiModels,
                isSelected: false,
                description: String(localized: "下载与加载时的缓存，删除后按需重建"),
                lastModified: DevCacheCatalog.modificationDate(of: URL(fileURLWithPath: path))
            )
            item.removesContainer = true
            return item
        }
    }

    // MARK: LM Studio 与其他工具

    /// <models>/<publisher>/<model>：每个模型目录一项。
    static func scanLMStudio(home: String) -> [CleanableItem] {
        [home + "/.lmstudio/models", home + "/.cache/lm-studio/models"].flatMap { root in
            children(of: root).flatMap { publisher -> [CleanableItem] in
                let publisherPath = root + "/" + publisher
                guard isDirectory(publisherPath) else {
                    return childItem(path: publisherPath, name: "\(publisher) · LM Studio").map { [$0] } ?? []
                }
                return children(of: publisherPath).compactMap { model in
                    childItem(path: publisherPath + "/" + model, name: "\(publisher)/\(model) · LM Studio")
                }
            }
        }
    }

    static func scanMiscellaneous(home: String) -> [CleanableItem] {
        var items: [CleanableItem] = []

        func eachChild(_ relativeRoot: String, source: AIModelSource, prefix: String = "", filter: (String) -> Bool = { _ in true }) {
            let root = home + "/" + relativeRoot
            for name in children(of: root) where filter(name) {
                if let item = childItem(path: root + "/" + name, name: "\(prefix)\(name) · \(source.displayName)") {
                    items.append(item)
                }
            }
        }

        eachChild("jan/models", source: .jan)
        eachChild("Library/Application Support/Jan/data/models", source: .jan)
        // GPT4All 目录里还有设置与本地文档索引，只列模型文件
        eachChild("Library/Application Support/nomic.ai/GPT4All", source: .gpt4all) { name in
            ["gguf", "bin"].contains((name as NSString).pathExtension.lowercased())
        }
        // DiffusionBee 目录里还有生成的图片，只列模型下载目录
        eachChild(".diffusionbee/downloads", source: .diffusionBee)
        eachChild(".diffusionbee/custom_models", source: .diffusionBee)
        for type in children(of: home + "/ComfyUI/models") where isDirectory(home + "/ComfyUI/models/" + type) {
            eachChild("ComfyUI/models/" + type, source: .comfyUI, prefix: type + "/")
        }
        eachChild(".cache/whisper", source: .whisper)
        eachChild(".cache/torch/hub", source: .torchHub) { $0 != "checkpoints" }
        eachChild(".cache/torch/hub/checkpoints", source: .torchHub)
        eachChild(".cache/llama.cpp", source: .llamaCpp)
        for directory in mlxCacheDirectories(home: home) {
            eachChild(String(directory.dropFirst(home.count + 1)), source: .mlx)
        }
        return items
    }

    /// ~/.cache 下以 mlx 开头的目录（mlx、mlx_lm 等）。
    static func mlxCacheDirectories(home: String) -> [String] {
        children(of: home + "/.cache")
            .filter { $0.lowercased().hasPrefix("mlx") }
            .map { home + "/.cache/" + $0 }
            .filter(isDirectory)
    }

    // MARK: 工具

    static func redownloadNote(_ size: Int64) -> String {
        String(localized: "删除后再次使用需要重新下载，约 \(format(size))")
    }

    static func format(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private static func modelItem(name: String, path: String, size: Int64, modified: Date?) -> CleanableItem {
        var item = CleanableItem(
            name: name,
            path: path,
            size: size,
            category: .aiModels,
            isSelected: false,
            description: redownloadNote(size),
            lastModified: modified
        )
        item.removesContainer = true
        return item
    }

    private static func childItem(path: String, name: String) -> CleanableItem? {
        let size = CleanupManager.allocatedSize(atPath: path)
        guard size >= minSize else { return nil }
        return modelItem(name: name, path: path, size: size, modified: DevCacheCatalog.modificationDate(of: URL(fileURLWithPath: path)))
    }

    private static func children(of path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

// MARK: - 运行中的 Ollama

nonisolated enum OllamaProcess {
    static let bundleIdentifier = "com.electron.ollama"

    /// Ollama 应用或 `ollama serve` 进程是否在运行。运行时删除模型文件可能让它读到一半的数据。
    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty || !serverPIDs().isEmpty
    }

    /// 退出 Ollama 应用，并结束当前用户的 ollama 进程（如 brew services 启动的服务）。
    static func quit() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            app.terminate()
        }
        for pid in serverPIDs() {
            kill(pid, SIGTERM)
        }
    }

    /// 当前用户名为 ollama 的进程。
    static func serverPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        let uid = getuid()
        var result: [pid_t] = []
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { continue }
            let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard name.lowercased() == "ollama" else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            result.append(pid)
        }
        return result
    }
}
