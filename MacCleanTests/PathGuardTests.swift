//
//  PathGuardTests.swift
//  MacCleanTests
//
//  路径保护栏单元测试
//

import Foundation
import Testing
@testable import MacClean

struct PathGuardTests {

    // MARK: - 测试环境搭建

    /// 在系统临时目录下创建一个隔离的伪 home 目录，测试结束后自动清理。
    private final class TestHome {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PathGuardTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        func path(_ components: String) -> String {
            url.appendingPathComponent(components).path
        }

        func makeDirectory(_ components: String) {
            try? FileManager.default.createDirectory(
                at: url.appendingPathComponent(components),
                withIntermediateDirectories: true
            )
        }

        func makeFile(_ components: String, contents: String = "x") {
            let fileURL = url.appendingPathComponent(components)
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        func makeSymlink(_ components: String, pointingTo target: String) {
            let linkURL = url.appendingPathComponent(components)
            try? FileManager.default.createDirectory(
                at: linkURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target)
        }
    }

    // MARK: - 拒绝场景

    @Test func rejectsHomeDirectoryItself() {
        let home = TestHome()
        #expect(throws: (any Error).self) {
            try PathGuard.validate(path: home.url.path, category: .largeFiles, homeDirectory: home.url)
        }
    }

    @Test func rejectsDocumentsDirectory() {
        let home = TestHome()
        home.makeDirectory("Documents")
        #expect(throws: (any Error).self) {
            try PathGuard.validate(path: home.path("Documents"), category: .largeFiles, homeDirectory: home.url)
        }
    }

    @Test func rejectsShallowPath() {
        let home = TestHome()
        #expect(throws: PathGuardError.self) {
            try PathGuard.validate(path: "/Users", category: .largeFiles, homeDirectory: home.url)
        }
    }

    @Test func rejectsICloudDriveSubpath() {
        let home = TestHome()
        home.makeDirectory("Library/Mobile Documents/com~apple~CloudDocs")
        #expect(throws: (any Error).self) {
            try PathGuard.validate(
                path: home.path("Library/Mobile Documents/com~apple~CloudDocs"),
                category: .largeFiles,
                homeDirectory: home.url
            )
        }
    }

    @Test func rejectsUserCacheDeletingDocumentsSubpath() {
        let home = TestHome()
        home.makeFile("Documents/important.txt")
        #expect(throws: (any Error).self) {
            try PathGuard.validate(
                path: home.path("Documents/important.txt"),
                category: .userCache,
                homeDirectory: home.url
            )
        }
    }

    // MARK: - 允许场景

    @Test func allowsUserCacheSubdirectory() throws {
        let home = TestHome()
        home.makeDirectory("Library/Caches/SomeApp")
        try PathGuard.validate(
            path: home.path("Library/Caches/SomeApp"),
            category: .userCache,
            homeDirectory: home.url
        )
    }

    @Test func allowsDeveloperToolsDerivedData() throws {
        let home = TestHome()
        home.makeDirectory("Library/Developer/Xcode/DerivedData/Foo")
        try PathGuard.validate(
            path: home.path("Library/Developer/Xcode/DerivedData/Foo"),
            category: .developerTools,
            homeDirectory: home.url
        )
    }

    @Test func allowsDeveloperToolsNpmCache() throws {
        let home = TestHome()
        home.makeDirectory(".npm/_cacache")
        try PathGuard.validate(
            path: home.path(".npm/_cacache"),
            category: .developerTools,
            homeDirectory: home.url
        )
    }

    @Test func allowsSavedApplicationStateSubdirectory() throws {
        let home = TestHome()
        home.makeDirectory("Library/Saved Application State/com.example.app.savedState")
        try PathGuard.validate(
            path: home.path("Library/Saved Application State/com.example.app.savedState"),
            category: .userCache,
            homeDirectory: home.url
        )
    }

    @Test func allowsDeveloperToolsSwiftPMCache() throws {
        let home = TestHome()
        home.makeDirectory("Library/org.swift.swiftpm/repositories")
        try PathGuard.validate(
            path: home.path("Library/org.swift.swiftpm/repositories"),
            category: .developerTools,
            homeDirectory: home.url
        )
    }

    @Test func allowsSystemLogsFile() throws {
        let home = TestHome()
        home.makeFile("Library/Logs/foo.log")
        try PathGuard.validate(
            path: home.path("Library/Logs/foo.log"),
            category: .systemLogs,
            homeDirectory: home.url
        )
    }

    @Test func allowsBrokenLoginItemInLaunchAgents() throws {
        let home = TestHome()
        home.makeFile("Library/LaunchAgents/com.foo.plist")
        try PathGuard.validate(
            path: home.path("Library/LaunchAgents/com.foo.plist"),
            category: .brokenLoginItems,
            homeDirectory: home.url
        )
    }

    @Test func rejectsBrokenLoginItemOutsideLaunchAgents() {
        let home = TestHome()
        home.makeFile("Library/Preferences/xxx.plist")
        #expect(throws: (any Error).self) {
            try PathGuard.validate(
                path: home.path("Library/Preferences/xxx.plist"),
                category: .brokenLoginItems,
                homeDirectory: home.url
            )
        }
    }

    @Test func allowsLargeFileUnderDownloads() throws {
        let home = TestHome()
        home.makeFile("Downloads/big.zip")
        try PathGuard.validate(
            path: home.path("Downloads/big.zip"),
            category: .largeFiles,
            homeDirectory: home.url
        )
    }

    // MARK: - 符号链接逃逸

    @Test func rejectsSymlinkEscapingToDocuments() {
        let home = TestHome()
        home.makeDirectory("Documents")
        home.makeDirectory("Library/Caches")
        home.makeSymlink("Library/Caches/escape", pointingTo: home.path("Documents"))

        #expect(throws: (any Error).self) {
            try PathGuard.validate(
                path: home.path("Library/Caches/escape"),
                category: .userCache,
                homeDirectory: home.url
            )
        }
    }

    // MARK: - 空间透镜专用校验（validateForSpaceLens）

    @Test func spaceLensRejectsSystemLibrarySubpath() {
        let home = TestHome()
        #expect(throws: (any Error).self) {
            try PathGuard.validateForSpaceLens(path: "/System/Library/CoreServices/SomeDaemon", homeDirectory: home.url)
        }
    }

    @Test func spaceLensRejectsUsrLocalBinSubpath() {
        let home = TestHome()
        #expect(throws: (any Error).self) {
            try PathGuard.validateForSpaceLens(path: "/usr/local/bin/somebinary", homeDirectory: home.url)
        }
    }

    @Test func spaceLensRejectsDocumentsDirectoryItself() {
        let home = TestHome()
        home.makeDirectory("Documents")
        #expect(throws: (any Error).self) {
            try PathGuard.validateForSpaceLens(path: home.path("Documents"), homeDirectory: home.url)
        }
    }

    @Test func spaceLensRejectsShallowPath() {
        let home = TestHome()
        #expect(throws: PathGuardError.self) {
            try PathGuard.validateForSpaceLens(path: "/Users", homeDirectory: home.url)
        }
    }

    @Test func spaceLensAllowsOldZipUnderDocuments() throws {
        let home = TestHome()
        home.makeFile("Documents/old.zip")
        try PathGuard.validateForSpaceLens(path: home.path("Documents/old.zip"), homeDirectory: home.url)
    }

    @Test func spaceLensAllowsBigLogUnderWorkspace() throws {
        let home = TestHome()
        home.makeFile("workspace/big.log")
        try PathGuard.validateForSpaceLens(path: home.path("workspace/big.log"), homeDirectory: home.url)
    }

    // MARK: - 本地 AI 模型

    static let aiModelRoots = [
        ".ollama/models", ".cache/huggingface", ".cache/lm-studio", ".lmstudio/models", "jan",
        "Library/Application Support/Jan", "Library/Application Support/nomic.ai/GPT4All", ".diffusionbee",
        "ComfyUI/models", ".cache/whisper", ".cache/torch", ".cache/llama.cpp", ".cache/mlx",
    ]

    @Test(arguments: aiModelRoots)
    func aiModelsAllowsPathsInsideEachRoot(root: String) throws {
        let home = TestHome()
        home.makeFile(root + "/some-model/weights.bin")
        try PathGuard.validate(path: home.path(root + "/some-model"), category: .aiModels, removesContainer: true, homeDirectory: home.url)
        try PathGuard.validate(path: home.path(root + "/some-model/weights.bin"), category: .aiModels, removesContainer: true, homeDirectory: home.url)
    }

    @Test(arguments: aiModelRoots)
    func aiModelsRejectsEachRootItself(root: String) {
        let home = TestHome()
        home.makeDirectory(root)
        #expect(throws: PathGuardError.self) {
            try PathGuard.validate(path: home.path(root), category: .aiModels, removesContainer: true, homeDirectory: home.url)
        }
        #expect(throws: PathGuardError.self) {
            try PathGuard.validate(path: home.path(root), category: .aiModels, removesContainer: false, homeDirectory: home.url)
        }
    }

    @Test(arguments: [
        ".ollama/config.json", ".ollama/id_ed25519", ".cache/other/file", ".cache", "Documents/model.gguf",
        "ComfyUI/output/image.png", "Library/Application Support/Other/model.bin", ".lmstudio/settings.json",
        ".cache/not-mlx/file", "Library/Caches/model",
    ])
    func aiModelsRejectsOutsideRoots(relative: String) {
        let home = TestHome()
        home.makeFile(relative)
        #expect(throws: PathGuardError.self) {
            try PathGuard.validate(path: home.path(relative), category: .aiModels, removesContainer: true, homeDirectory: home.url)
        }
    }

    @Test func aiModelsRejectsSymlinkEscape() {
        let home = TestHome()
        home.makeFile("Documents/thesis.pdf")
        home.makeSymlink(".ollama/models/blobs/sha256-evil", pointingTo: home.path("Documents/thesis.pdf"))
        #expect(throws: PathGuardError.self) {
            try PathGuard.validate(path: home.path(".ollama/models/blobs/sha256-evil"), category: .aiModels, removesContainer: true, homeDirectory: home.url)
        }
    }

    @Test func aiModelsRejectsHomeAndSystemPaths() {
        let home = TestHome()
        for path in [home.url.path, "/System/Library", "/Users", home.path("Library")] {
            #expect(throws: (any Error).self) {
                try PathGuard.validate(path: path, category: .aiModels, removesContainer: true, homeDirectory: home.url)
            }
        }
    }
}
