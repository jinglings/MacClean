//
//  AIModelCatalogTests.swift
//  MacCleanTests
//
//  本地 AI 模型扫描：Ollama 共用数据块、Hugging Face 符号链接、LM Studio 布局、环境变量覆盖。
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacClean

struct AIModelCatalogTests {

    // MARK: - 伪 home

    final class FakeHome {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("AIModelCatalogTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        var path: String { url.standardizedFileURL.path }

        /// 写一个指定大小的文件（稀疏文件，不真正占盘；allocatedSize 对 0 块的文件回退到逻辑大小）。
        func makeFile(_ relative: String, size: Int64 = 0, contents: Data? = nil) {
            let fileURL = url.appendingPathComponent(relative)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fileURL.path, contents: contents ?? Data())
            if size > 0, let handle = try? FileHandle(forWritingTo: fileURL) {
                try? handle.truncate(atOffset: UInt64(size))
                try? handle.close()
            }
        }

        func makeSymlink(_ relative: String, to destination: String) {
            let linkURL = url.appendingPathComponent(relative)
            try? FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: destination)
        }

        /// Ollama 数据块 + 清单。digests 是 64 位十六进制。
        func makeOllamaModel(root: String = ".ollama/models", name: String, tag: String, layers: [String], config: String) {
            let json: [String: Any] = [
                "schemaVersion": 2,
                "config": ["digest": "sha256:" + config, "size": 400],
                "layers": layers.map { ["digest": "sha256:" + $0, "size": 1] },
            ]
            let data = try! JSONSerialization.data(withJSONObject: json)
            makeFile("\(root)/manifests/registry.ollama.ai/library/\(name)/\(tag)", contents: data)
        }
    }

    static let mb: Int64 = 1024 * 1024
    static func hex(_ c: Character) -> String { String(repeating: c, count: 64) }

    /// 两个模型共用一个 600 MB 的数据块，各自另有独占数据块。
    static func makeSharedOllamaTree(_ home: FakeHome, root: String = ".ollama/models") {
        let shared = hex("a"), onlyA = hex("b"), onlyB = hex("c"), configA = hex("d"), configB = hex("e")
        home.makeFile("\(root)/blobs/sha256-\(shared)", size: 600 * mb)
        home.makeFile("\(root)/blobs/sha256-\(onlyA)", size: 300 * mb)
        home.makeFile("\(root)/blobs/sha256-\(onlyB)", size: 200 * mb)
        home.makeFile("\(root)/blobs/sha256-\(configA)", size: 4096)
        home.makeFile("\(root)/blobs/sha256-\(configB)", size: 4096)
        home.makeOllamaModel(root: root, name: "qwen2.5", tag: "7b", layers: [shared, onlyA], config: configA)
        home.makeOllamaModel(root: root, name: "qwen2.5", tag: "7b-instruct", layers: [shared, onlyB], config: configB)
    }

    // MARK: - Ollama

    @Test func ollamaSharedBlobsExcludedFromEachModel() {
        let home = FakeHome()
        Self.makeSharedOllamaTree(home)

        let items = AIModelCatalog.scan(home: home.url, environment: [:])
        #expect(items.count == 2)
        let a = try! #require(items.first { $0.name == "qwen2.5:7b · Ollama" })
        let b = try! #require(items.first { $0.name == "qwen2.5:7b-instruct · Ollama" })
        // 只算独占数据块（+ 配置与清单的零头），不含共用的 600 MB
        #expect(a.size >= 300 * Self.mb && a.size < 301 * Self.mb)
        #expect(b.size >= 200 * Self.mb && b.size < 201 * Self.mb)
        #expect(a.description?.contains(AIModelCatalog.format(600 * Self.mb + 4096)) == true || a.description?.contains(AIModelCatalog.format(600 * Self.mb)) == true)
        #expect(a.category == .aiModels)
        #expect(a.removesContainer)
        #expect(a.path.hasSuffix("manifests/registry.ollama.ai/library/qwen2.5/7b"))
    }

    @Test func ollamaSelectingBothCountsSharedBlobOnce() {
        let home = FakeHome()
        Self.makeSharedOllamaTree(home)
        let index = AIModelCatalog.ollamaIndex(modelsRoot: home.path + "/.ollama/models")
        let paths = Set(index.manifests.map(\.path))
        #expect(paths.count == 2)

        let both = index.reclaimableSize(removing: paths)
        #expect(both >= 1100 * Self.mb && both < 1101 * Self.mb)
        #expect(index.unreferencedDigests(removing: paths).count == 5)
    }

    @Test func ollamaCleanupPlanRemovesManifestAndUnsharedBlobsOnly() {
        let home = FakeHome()
        Self.makeSharedOllamaTree(home)
        let items = AIModelCatalog.scan(home: home.url, environment: [:])
        let a = items.first { $0.name.hasPrefix("qwen2.5:7b ·") }!

        let plan = AIModelCatalog.prepareForCleaning([a], environment: [:], home: home.url)
        let names = Set(plan.map { ($0.path as NSString).lastPathComponent })
        #expect(names == ["7b", "sha256-" + Self.hex("b"), "sha256-" + Self.hex("d")])
        #expect(plan.allSatisfy { $0.removesContainer && $0.category == .aiModels })
        for item in plan {
            #expect(throws: Never.self) {
                try PathGuard.validate(path: item.path, category: .aiModels, removesContainer: true, homeDirectory: home.url)
            }
        }

        // 两个一起选：共用数据块也一并删除
        let together = AIModelCatalog.prepareForCleaning(items, environment: [:], home: home.url)
        #expect(together.contains { $0.path.hasSuffix("sha256-" + Self.hex("a")) })
        #expect(together.count == 7)
    }

    @Test func ollamaCleanupKeepsBlobsOfOtherItemsUntouched() {
        // 非 Ollama 条目原样透传
        let home = FakeHome()
        let other = CleanableItem(name: "x", path: home.path + "/.cache/huggingface/hub/models--a--b", size: 1, category: .aiModels, isSelected: true)
        let plan = AIModelCatalog.prepareForCleaning([other], environment: [:], home: home.url)
        #expect(plan.map(\.path) == [other.path])
    }

    @Test func ollamaCorruptManifestStillProtectsItsBlobs() {
        let home = FakeHome()
        Self.makeSharedOllamaTree(home)
        // 损坏的清单引用了 qwen2.5:7b 的独占数据块：不列出它，但那个数据块不能算可释放
        home.makeFile(".ollama/models/manifests/registry.ollama.ai/library/broken/latest",
                      contents: Data("{\"layers\": [{\"digest\": \"sha256:\(Self.hex("b"))\"".utf8))
        // 空清单与缺失数据块的清单也不应导致崩溃
        home.makeFile(".ollama/models/manifests/registry.ollama.ai/library/empty/latest")
        home.makeOllamaModel(name: "missing", tag: "latest", layers: [Self.hex("f")], config: Self.hex("0"))

        let items = AIModelCatalog.scan(home: home.url, environment: [:])
        #expect(items.map(\.name).sorted() == ["qwen2.5:7b · Ollama", "qwen2.5:7b-instruct · Ollama"])
        let a = items.first { $0.name == "qwen2.5:7b · Ollama" }!
        #expect(a.size < Self.mb)
    }

    @Test func ollamaMissingDirectoryYieldsNothing() {
        let home = FakeHome()
        home.makeFile(".ollama/models/blobs/sha256-\(Self.hex("a"))", size: 10 * Self.mb)
        #expect(AIModelCatalog.scan(home: home.url, environment: [:]).isEmpty)
    }

    @Test func ollamaModelNames() {
        #expect(AIModelCatalog.ollamaModelName(relativePath: "registry.ollama.ai/library/qwen2.5/7b") == "qwen2.5:7b")
        #expect(AIModelCatalog.ollamaModelName(relativePath: "registry.ollama.ai/user/model/latest") == "user/model:latest")
        #expect(AIModelCatalog.ollamaModelName(relativePath: "hf.co/org/repo/Q4") == "hf.co/org/repo:Q4")
    }

    @Test func rejectsPathTraversalDigests() {
        let data = Data("{\"config\":{\"digest\":\"sha256:../../etc\"},\"layers\":[{\"digest\":\"sha256:\(Self.hex("a"))\"}]}".utf8)
        let parsed = AIModelCatalog.parseManifest(data)
        #expect(parsed.isValid)
        #expect(parsed.digests == ["sha256:" + Self.hex("a")])
    }

    @Test func environmentOverrideForOllamaAndHuggingFace() {
        let home = FakeHome()
        let custom = FakeHome()
        Self.makeSharedOllamaTree(custom, root: "ollama")
        custom.makeFile("hf/hub/models--org--tiny/blobs/abc", size: 5 * Self.mb)

        let env = ["OLLAMA_MODELS": custom.path + "/ollama", "HF_HOME": custom.path + "/hf"]
        let locations = AIModelLocations.resolve(home: home.url, environment: env)
        #expect(locations.ollamaModels == [home.path + "/.ollama/models", custom.path + "/ollama"])
        #expect(locations.huggingFaceHubs.contains(custom.path + "/hf/hub"))

        let items = AIModelCatalog.scan(home: home.url, environment: env)
        #expect(items.count == 3)
        #expect(items.contains { $0.name == "org/tiny · Hugging Face" })
        #expect(AIModelCatalog.scan(home: home.url, environment: [:]).isEmpty)

        let roots = AIModelCatalog.allowedRoots(home: home.path, environment: env)
        #expect(roots.contains(custom.path + "/ollama/manifests"))
        #expect(roots.contains(custom.path + "/hf/hub"))
        // 空值与 ~ 展开
        let tilde = AIModelLocations.resolve(home: home.url, environment: ["OLLAMA_MODELS": "~/models", "HF_HUB_CACHE": " "])
        #expect(tilde.ollamaModels.last == home.path + "/models")
        #expect(tilde.huggingFaceHubs == [home.path + "/.cache/huggingface/hub"])
    }

    // MARK: - Hugging Face

    @Test func huggingFaceSnapshotsCountedOnce() {
        let home = FakeHome()
        let repo = ".cache/huggingface/hub/models--mlx-community--Qwen3-4B"
        home.makeFile("\(repo)/blobs/aaa", size: 40 * Self.mb)
        home.makeFile("\(repo)/blobs/bbb", size: 4096)
        home.makeFile("\(repo)/refs/main", contents: Data("123".utf8))
        home.makeSymlink("\(repo)/snapshots/123/model.safetensors", to: "../../blobs/aaa")
        home.makeSymlink("\(repo)/snapshots/123/config.json", to: "../../blobs/bbb")
        home.makeFile(".cache/huggingface/hub/datasets--org--set/blobs/x", size: 3 * Self.mb)
        home.makeFile(".cache/huggingface/hub/version.txt", contents: Data("1".utf8))
        home.makeFile(".cache/huggingface/xet/chunk", size: 2 * Self.mb)
        home.makeFile(".cache/huggingface/token", contents: Data("secret".utf8))

        let items = AIModelCatalog.scan(home: home.url, environment: [:])
        let model = try! #require(items.first { $0.name == "mlx-community/Qwen3-4B · Hugging Face" })
        #expect(model.size >= 40 * Self.mb && model.size < 41 * Self.mb)
        #expect(model.path == home.path + "/" + repo)
        #expect(items.contains { $0.name.hasPrefix("org/set ·") })
        #expect(items.contains { $0.path.hasSuffix("/.cache/huggingface/xet") })
        #expect(!items.contains { $0.path.hasSuffix("token") || $0.path.hasSuffix("version.txt") })
        #expect(items.map(\.size) == items.map(\.size).sorted(by: >))
    }

    // MARK: - LM Studio 与其他

    @Test func lmStudioOneItemPerModelFolder() {
        let home = FakeHome()
        home.makeFile(".lmstudio/models/lmstudio-community/Qwen3-8B-GGUF/q4.gguf", size: 5 * Self.mb)
        home.makeFile(".lmstudio/models/lmstudio-community/gemma-3/q8.gguf", size: 8 * Self.mb)
        home.makeFile(".cache/lm-studio/models/TheBloke/llama/q.gguf", size: 2 * Self.mb)
        home.makeFile(".lmstudio/models/tiny/small/a.gguf", size: 1000)

        let names = AIModelCatalog.scan(home: home.url, environment: [:]).map(\.name)
        #expect(names == [
            "lmstudio-community/gemma-3 · LM Studio",
            "lmstudio-community/Qwen3-8B-GGUF · LM Studio",
            "TheBloke/llama · LM Studio",
        ])
    }

    @Test func otherToolsOnlyListModelFiles() {
        let home = FakeHome()
        home.makeFile("Library/Application Support/nomic.ai/GPT4All/model.gguf", size: 3 * Self.mb)
        home.makeFile("Library/Application Support/nomic.ai/GPT4All/localdocs_v2.db", size: 3 * Self.mb)
        home.makeFile(".diffusionbee/images/art.png", size: 3 * Self.mb)
        home.makeFile(".diffusionbee/downloads/sd15/model.ckpt", size: 3 * Self.mb)
        home.makeFile("ComfyUI/models/checkpoints/sdxl.safetensors", size: 3 * Self.mb)
        home.makeFile(".cache/whisper/large-v3.pt", size: 3 * Self.mb)
        home.makeFile(".cache/torch/hub/checkpoints/resnet.pth", size: 3 * Self.mb)
        home.makeFile(".cache/llama.cpp/model.gguf", size: 3 * Self.mb)
        home.makeFile(".cache/mlx_lm/thing/w.bin", size: 3 * Self.mb)
        home.makeFile("jan/models/llama3/model.gguf", size: 3 * Self.mb)

        let items = AIModelCatalog.scan(home: home.url, environment: [:])
        let names = Set(items.map(\.name))
        #expect(names == [
            "model.gguf · GPT4All",
            "sd15 · DiffusionBee",
            "checkpoints/sdxl.safetensors · ComfyUI",
            "large-v3.pt · Whisper",
            "resnet.pth · PyTorch Hub",
            "model.gguf · llama.cpp",
            "thing · MLX",
            "llama3 · Jan",
        ])
        for item in items {
            #expect(throws: Never.self) {
                try PathGuard.validate(path: item.path, category: .aiModels, removesContainer: true, homeDirectory: home.url)
            }
        }
    }

    @MainActor
    @Test func nothingPreselectedAndDescriptorConfigured() {
        let home = FakeHome()
        Self.makeSharedOllamaTree(home)
        home.makeFile(".lmstudio/models/p/m/q.gguf", size: 5 * Self.mb)
        let items = AIModelCatalog.scan(home: home.url, environment: [:])
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { !$0.isSelected })
        #expect(items.allSatisfy { $0.description?.isEmpty == false && $0.lastModified != nil })

        let descriptor = CleanGroupDescriptor.devGroups.first { $0.id == "aiModels" }
        #expect(descriptor?.riskNote != nil)
        #expect(descriptor?.prepareForCleaning != nil)
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        #expect(descriptor?.runningApp?.locks(realHome + "/.ollama/models/manifests/x") == true)
        #expect(descriptor?.runningApp?.locks(realHome + "/.cache/huggingface/hub/x") == false)
    }

    // MARK: - 界面截图（仅在设置 MACCLEAN_SNAPSHOT_DIR 时运行）

    @MainActor
    @Test func renderDevCachesWithFakeModels() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MACCLEAN_SNAPSHOT_DIR"] else { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let home = FakeHome()
        Self.makeSharedOllamaTree(home)
        home.makeFile(".cache/huggingface/hub/models--mlx-community--Qwen3.5-27B-OptiQ-4bit/blobs/a", size: 15 * 1024 * Self.mb)
        home.makeFile(".cache/huggingface/hub/models--mlx-community--Qwen3-4B-Instruct-2507-4bit/blobs/a", size: 2100 * Self.mb)
        home.makeFile(".lmstudio/models/lmstudio-community/gemma-3-12b-it-GGUF/q4.gguf", size: 7300 * Self.mb)

        let viewModel = CleanGroupsViewModel(descriptors: CleanGroupDescriptor.devGroups, home: home.url)
        viewModel.scanAll()
        for _ in 0..<120 where !viewModel.hasScanned || viewModel.isScanning {
            try await Task.sleep(for: .milliseconds(250))
        }
        let groupIndex = try #require(viewModel.groups.firstIndex { $0.id == "aiModels" })
        if let first = viewModel.groups[groupIndex].items.indices.first {
            viewModel.groups[groupIndex].items[first].isSelected = true
        }

        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let page = CleanGroupsPage(title: "开发缓存", subtitle: "", viewModel: viewModel)
                .frame(width: 940, height: 760)
                .background(AppTheme.primaryGradient)
            try await snapshot(page, size: CGSize(width: 940, height: 760), appearance: appearance, to: outDir.appendingPathComponent("\(mode)-aimodels-page.png"))

            var running = viewModel.groups[groupIndex]
            running.isAppRunning = true
            let cards = VStack(spacing: 12) {
                CleanGroupCard(group: .constant(viewModel.groups[groupIndex]), isExpanded: true, onToggleExpanded: {}, onSelectAll: { _ in }, onIgnore: { _ in })
                CleanGroupCard(group: .constant(running), isExpanded: false, onToggleExpanded: {}, onSelectAll: { _ in }, onIgnore: { _ in })
            }
            .padding(24)
            .frame(width: 940, height: 640, alignment: .top)
            .background(AppTheme.primaryGradient)
            try await snapshot(cards, size: CGSize(width: 940, height: 640), appearance: appearance, to: outDir.appendingPathComponent("\(mode)-aimodels-card.png"))
        }
    }

    /// 官网用整窗截图（仅在设置 MACCLEAN_AI_SCREENS_DIR 时运行）：合成的伪 home，不含任何真实用户数据。
    @MainActor
    @Test func renderWebsiteScreens() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MACCLEAN_AI_SCREENS_DIR"] else { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let lang = (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh") ? "zh" : "en"

        let home = FakeHome()
        let gb = 1024 * Self.mb
        // Ollama：llava 两个规格共用视觉投影层
        let projector = Self.hex("1"), llava13 = Self.hex("2"), llava7 = Self.hex("3")
        home.makeFile(".ollama/models/blobs/sha256-\(projector)", size: 624 * Self.mb)
        home.makeFile(".ollama/models/blobs/sha256-\(llava13)", size: 7_400 * Self.mb)
        home.makeFile(".ollama/models/blobs/sha256-\(llava7)", size: 4_100 * Self.mb)
        home.makeFile(".ollama/models/blobs/sha256-\(Self.hex("4"))", size: 4096)
        home.makeFile(".ollama/models/blobs/sha256-\(Self.hex("5"))", size: 4096)
        home.makeOllamaModel(name: "llava", tag: "13b", layers: [llava13, projector], config: Self.hex("4"))
        home.makeOllamaModel(name: "llava", tag: "7b", layers: [llava7, projector], config: Self.hex("5"))
        // Hugging Face：snapshots 指向 blobs
        let hf = ".cache/huggingface/hub/models--mlx-community--gemma-3-27b-it-4bit"
        home.makeFile("\(hf)/blobs/w1", size: 16 * gb)
        home.makeSymlink("\(hf)/snapshots/main/model.safetensors", to: "../../blobs/w1")
        let hfSmall = ".cache/huggingface/hub/models--sentence-transformers--all-MiniLM-L6-v2"
        home.makeFile("\(hfSmall)/blobs/w1", size: 91 * Self.mb)
        // LM Studio
        home.makeFile(".lmstudio/models/lmstudio-community/gemma-3-12b-it-GGUF/gemma-3-12b-it-Q4_K_M.gguf", size: 7_600 * Self.mb)
        home.makeFile(".cache/whisper/large-v3.pt", size: 2_900 * Self.mb)
        // 一些开发缓存，让页面汇总更真实
        home.makeFile("Library/Developer/Xcode/DerivedData/WeatherApp-abcdefghijklmnopqrstuvwxyz/Build/x", size: 3 * gb)
        home.makeFile(".npm/_cacache/content-v2/x", size: 1_200 * Self.mb)

        func age(_ relative: String, days: Double) {
            let date = Date().addingTimeInterval(-days * 86_400)
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: home.path + "/" + relative)
        }
        age(".ollama/models/manifests/registry.ollama.ai/library/llava/13b", days: 140)
        age(".ollama/models/manifests/registry.ollama.ai/library/llava/7b", days: 21)
        for sub in ["/blobs", "/snapshots", "/refs", ""] {
            age(hf + sub, days: 95)
            age(hfSmall + sub, days: 3)
        }
        age(".lmstudio/models/lmstudio-community/gemma-3-12b-it-GGUF", days: 46)
        age(".cache/whisper/large-v3.pt", days: 230)

        // Ollama 视为未运行，避免受本机进程影响
        let descriptors = CleanGroupDescriptor.devGroups.map { descriptor -> CleanGroupDescriptor in
            var copy = descriptor
            copy.runningApp = nil
            return copy
        }
        let viewModel = CleanGroupsViewModel(descriptors: descriptors, home: home.url)
        viewModel.scanAll()
        for _ in 0..<240 where !viewModel.hasScanned || viewModel.isScanning {
            try await Task.sleep(for: .milliseconds(250))
        }
        for group in viewModel.groups { viewModel.setSelection(groupID: group.id, selected: false) }
        viewModel.expandedGroupIDs = ["aiModels"]
        PageModelStore.shared.devCaches = viewModel
        AppState.shared.currentTab = .developerTools

        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let root = ContentView()
                .environmentObject(AppState.shared)
                .frame(width: 1180, height: 760)
            try await snapshot(root, size: CGSize(width: 1180, height: 760), appearance: appearance,
                               to: outDir.appendingPathComponent("\(mode)-\(lang)-ai_models.png"))
        }
    }

    @MainActor
    private func snapshot<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        // 与 UISnapshotTests 相同：layer.render 到 sRGB 位图，颜色比 cacheDisplay 准确
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let ctx = try #require(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let layer = try #require(host.layer)
        ctx.scaleBy(x: scale, y: scale)
        if host.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        let image = try #require(ctx.makeImage())
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    // MARK: - 真机只读扫描（仅在设置 MACCLEAN_AI_REAL_SCAN 时运行）

    /// MACCLEAN_AI_REAL_SCAN 为输出文件路径；只扫描、不删除。
    @Test func printRealScan() throws {
        guard let output = ProcessInfo.processInfo.environment["MACCLEAN_AI_REAL_SCAN"] else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var lines = AIModelCatalog.scan(home: home).map { item in
            "\(item.name)\t\(AIModelCatalog.format(item.size))\t\(item.description ?? "")\t\(item.lastModified.map { "\($0)" } ?? "-")"
        }
        lines.append("ollamaRunning=\(OllamaProcess.isRunning()) env=\(AIModelLocations.currentEnvironment)")
        try lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }
}
