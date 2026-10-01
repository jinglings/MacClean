//
//  DevCacheCatalog.swift
//  MacClean
//
//  开发缓存规则表 + 长期未动项目的依赖/构建目录扫描。
//  全部为无状态 nonisolated 静态方法，可在后台线程调用（工程默认 MainActor 隔离）。
//

import Foundation

// MARK: - 生态分组

enum DevEcosystem: String, CaseIterable, Identifiable, Sendable {
    case xcode
    case javascript
    case python
    case jvm
    case rustGo
    case packageManagers
    case editors

    nonisolated var id: String { rawValue }

    var title: String {
        switch self {
        case .xcode: return String(localized: "Xcode 与模拟器")
        case .javascript: return "JavaScript"
        case .python: return "Python"
        case .jvm: return "Java / Android"
        case .rustGo: return "Rust / Go"
        case .packageManagers: return "Homebrew / CocoaPods / Carthage"
        case .editors: return String(localized: "编辑器与 IDE")
        }
    }

    var subtitle: String {
        switch self {
        case .xcode: return String(localized: "DerivedData、旧设备符号文件、预览与模拟器缓存")
        case .javascript: return String(localized: "npm、Yarn、Bun、node-gyp 与 Electron 下载缓存")
        case .python: return String(localized: "pip、uv、Poetry 下载缓存")
        case .jvm: return String(localized: "Gradle 缓存与包装器、Maven 本地仓库")
        case .rustGo: return String(localized: "Cargo 注册表缓存、Go 构建缓存")
        case .packageManagers: return String(localized: "安装包下载缓存，需要时会重新下载")
        case .editors: return String(localized: "VS Code、Cursor、JetBrains 的缓存目录")
        }
    }

    var icon: String {
        switch self {
        case .xcode: return "hammer"
        case .javascript: return "curlybraces"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .jvm: return "cup.and.saucer"
        case .rustGo: return "gearshape.2"
        case .packageManagers: return "shippingbox"
        case .editors: return "text.cursor"
        }
    }
}

// MARK: - 规则

struct DevCacheRule: Sendable {
    enum Layout: Sendable {
        /// 整个目录作为一项，清理时清空其内容、保留目录本身。
        case whole
        /// 每个子目录单独成项（如每个项目的 DerivedData、每个系统版本的设备符号），清理时整项移入废纸篓。
        case perChild
        /// 同 perChild，但默认不勾选最近修改的一个（最新的设备符号通常还在用）。
        case perChildKeepNewest
    }

    let ecosystem: DevEcosystem
    let name: String
    /// 相对 home 的路径。
    let relativePath: String
    let layout: Layout
    let defaultSelected: Bool
    let note: String
}

enum DevCacheCatalog {

    nonisolated static let rules: [DevCacheRule] = [
        // Xcode
        .init(ecosystem: .xcode, name: "DerivedData", relativePath: "Library/Developer/Xcode/DerivedData", layout: .perChild, defaultSelected: true, note: String(localized: "构建中间产物，下次构建自动生成")),
        .init(ecosystem: .xcode, name: String(localized: "iOS 设备符号"), relativePath: "Library/Developer/Xcode/iOS DeviceSupport", layout: .perChildKeepNewest, defaultSelected: true, note: String(localized: "旧系统版本的调试符号")),
        .init(ecosystem: .xcode, name: String(localized: "watchOS 设备符号"), relativePath: "Library/Developer/Xcode/watchOS DeviceSupport", layout: .perChildKeepNewest, defaultSelected: true, note: String(localized: "旧系统版本的调试符号")),
        .init(ecosystem: .xcode, name: String(localized: "tvOS 设备符号"), relativePath: "Library/Developer/Xcode/tvOS DeviceSupport", layout: .perChildKeepNewest, defaultSelected: true, note: String(localized: "旧系统版本的调试符号")),
        .init(ecosystem: .xcode, name: String(localized: "visionOS 设备符号"), relativePath: "Library/Developer/Xcode/visionOS DeviceSupport", layout: .perChildKeepNewest, defaultSelected: true, note: String(localized: "旧系统版本的调试符号")),
        .init(ecosystem: .xcode, name: "Archives", relativePath: "Library/Developer/Xcode/Archives", layout: .perChild, defaultSelected: false, note: String(localized: "归档包含可提交的构建与 dSYM，请确认后再删")),
        .init(ecosystem: .xcode, name: String(localized: "SwiftUI 预览"), relativePath: "Library/Developer/Xcode/UserData/Previews", layout: .whole, defaultSelected: true, note: String(localized: "预览模拟器数据")),
        .init(ecosystem: .xcode, name: String(localized: "文档缓存"), relativePath: "Library/Developer/Xcode/DocumentationCache", layout: .whole, defaultSelected: true, note: String(localized: "离线文档索引缓存")),
        .init(ecosystem: .xcode, name: String(localized: "Xcode 缓存"), relativePath: "Library/Caches/com.apple.dt.Xcode", layout: .whole, defaultSelected: true, note: String(localized: "Xcode 自身缓存")),
        .init(ecosystem: .xcode, name: String(localized: "模拟器缓存"), relativePath: "Library/Developer/CoreSimulator/Caches", layout: .whole, defaultSelected: true, note: String(localized: "模拟器运行时缓存")),
        .init(ecosystem: .xcode, name: String(localized: "SwiftPM 缓存"), relativePath: "Library/Caches/org.swift.swiftpm", layout: .whole, defaultSelected: true, note: String(localized: "Swift 包下载缓存")),

        // JavaScript
        .init(ecosystem: .javascript, name: String(localized: "npm 缓存"), relativePath: ".npm/_cacache", layout: .whole, defaultSelected: true, note: String(localized: "npm 包下载缓存")),
        .init(ecosystem: .javascript, name: String(localized: "Yarn 缓存"), relativePath: "Library/Caches/Yarn", layout: .whole, defaultSelected: true, note: String(localized: "Yarn 包下载缓存")),
        .init(ecosystem: .javascript, name: String(localized: "Bun 缓存"), relativePath: ".bun/install/cache", layout: .whole, defaultSelected: true, note: String(localized: "Bun 包下载缓存")),
        .init(ecosystem: .javascript, name: "node-gyp", relativePath: "Library/Caches/node-gyp", layout: .whole, defaultSelected: true, note: String(localized: "原生模块编译用的 Node 头文件")),
        .init(ecosystem: .javascript, name: String(localized: "Electron 下载"), relativePath: "Library/Caches/electron", layout: .whole, defaultSelected: true, note: String(localized: "Electron 二进制下载缓存")),
        .init(ecosystem: .javascript, name: String(localized: "Playwright 浏览器"), relativePath: "Library/Caches/ms-playwright", layout: .perChild, defaultSelected: false, note: String(localized: "测试用浏览器，删除后需重新安装")),

        // Python
        .init(ecosystem: .python, name: String(localized: "pip 缓存"), relativePath: "Library/Caches/pip", layout: .whole, defaultSelected: true, note: String(localized: "pip 包下载缓存")),
        .init(ecosystem: .python, name: String(localized: "uv 缓存"), relativePath: ".cache/uv", layout: .whole, defaultSelected: true, note: String(localized: "uv 包缓存")),
        .init(ecosystem: .python, name: String(localized: "Poetry 缓存"), relativePath: "Library/Caches/pypoetry", layout: .whole, defaultSelected: true, note: String(localized: "Poetry 包缓存")),

        // JVM
        .init(ecosystem: .jvm, name: String(localized: "Gradle 缓存"), relativePath: ".gradle/caches", layout: .whole, defaultSelected: true, note: String(localized: "依赖与构建缓存，下次构建重新下载")),
        .init(ecosystem: .jvm, name: String(localized: "Gradle 包装器"), relativePath: ".gradle/wrapper/dists", layout: .perChildKeepNewest, defaultSelected: true, note: String(localized: "旧版本 Gradle 发行包")),
        .init(ecosystem: .jvm, name: String(localized: "Maven 本地仓库"), relativePath: ".m2/repository", layout: .whole, defaultSelected: false, note: String(localized: "离线构建依赖它，请确认后再删")),
        .init(ecosystem: .jvm, name: String(localized: "Android 缓存"), relativePath: ".android/cache", layout: .whole, defaultSelected: true, note: String(localized: "Android SDK 工具缓存")),

        // Rust / Go
        .init(ecosystem: .rustGo, name: String(localized: "Cargo 注册表缓存"), relativePath: ".cargo/registry/cache", layout: .whole, defaultSelected: true, note: String(localized: "crate 压缩包缓存")),
        .init(ecosystem: .rustGo, name: String(localized: "Cargo 源码缓存"), relativePath: ".cargo/registry/src", layout: .whole, defaultSelected: true, note: String(localized: "解压后的 crate 源码")),
        .init(ecosystem: .rustGo, name: String(localized: "Cargo Git 检出"), relativePath: ".cargo/git/checkouts", layout: .whole, defaultSelected: true, note: String(localized: "Git 依赖检出副本")),
        .init(ecosystem: .rustGo, name: String(localized: "Go 构建缓存"), relativePath: "Library/Caches/go-build", layout: .whole, defaultSelected: true, note: String(localized: "go build 编译缓存")),

        // 包管理器
        .init(ecosystem: .packageManagers, name: String(localized: "Homebrew 下载"), relativePath: "Library/Caches/Homebrew", layout: .whole, defaultSelected: true, note: String(localized: "安装包下载缓存")),
        .init(ecosystem: .packageManagers, name: String(localized: "CocoaPods 缓存"), relativePath: "Library/Caches/CocoaPods", layout: .whole, defaultSelected: true, note: String(localized: "Pod 下载缓存")),
        .init(ecosystem: .packageManagers, name: String(localized: "Carthage 缓存"), relativePath: "Library/Caches/org.carthage.CarthageKit", layout: .whole, defaultSelected: true, note: String(localized: "Carthage 依赖缓存")),

        // 编辑器
        .init(ecosystem: .editors, name: String(localized: "VS Code 缓存"), relativePath: "Library/Application Support/Code/Cache", layout: .whole, defaultSelected: true, note: String(localized: "界面资源缓存")),
        .init(ecosystem: .editors, name: String(localized: "VS Code 数据缓存"), relativePath: "Library/Application Support/Code/CachedData", layout: .whole, defaultSelected: true, note: String(localized: "旧版本编译缓存")),
        .init(ecosystem: .editors, name: String(localized: "VS Code 扩展安装包"), relativePath: "Library/Application Support/Code/CachedExtensionVSIXs", layout: .whole, defaultSelected: true, note: String(localized: "已安装扩展的安装包副本")),
        .init(ecosystem: .editors, name: String(localized: "Cursor 缓存"), relativePath: "Library/Application Support/Cursor/Cache", layout: .whole, defaultSelected: true, note: String(localized: "界面资源缓存")),
        .init(ecosystem: .editors, name: String(localized: "Cursor 数据缓存"), relativePath: "Library/Application Support/Cursor/CachedData", layout: .whole, defaultSelected: true, note: String(localized: "旧版本编译缓存")),
        .init(ecosystem: .editors, name: String(localized: "JetBrains 缓存"), relativePath: "Library/Caches/JetBrains", layout: .perChild, defaultSelected: true, note: String(localized: "索引与本地历史缓存，重启 IDE 后重建")),
    ]

    /// ~/Library/Caches 下归属开发工具的一级目录名。「释放空间」的应用缓存组会排除它们，避免两处重复计入。
    nonisolated static var libraryCacheNames: Set<String> {
        var names: Set<String> = []
        for rule in rules where rule.relativePath.hasPrefix("Library/Caches/") {
            let rest = rule.relativePath.dropFirst("Library/Caches/".count)
            if let first = rest.split(separator: "/").first {
                names.insert(String(first))
            }
        }
        return names
    }

    /// PathGuard 对 developerTools 分类放行的根目录：规则表中的每个路径 + 历史兼容根。
    nonisolated static func allowedRoots(home: String) -> [String] {
        var roots = rules.map { home + "/" + $0.relativePath }
        roots += [
            home + "/Library/Caches",
            home + "/Library/Developer",
            home + "/.npm",
            home + "/Library/org.swift.swiftpm",
        ]
        return roots
    }

    // MARK: - 扫描

    /// 扫描某个生态下的全部规则。
    nonisolated static func scan(_ ecosystem: DevEcosystem, home: URL, minSize: Int64 = 1024 * 1024) -> [CleanableItem] {
        rules
            .filter { $0.ecosystem == ecosystem }
            .flatMap { scan(rule: $0, home: home, minSize: minSize) }
            .sorted { $0.size > $1.size }
    }

    /// 扫描全部规则中默认勾选的部分（一键体检用）。
    nonisolated static func scanDefaultSelected(home: URL) -> [CleanableItem] {
        DevEcosystem.allCases
            .flatMap { scan($0, home: home) }
            .filter { $0.isSelected }
    }

    nonisolated static func scan(rule: DevCacheRule, home: URL, minSize: Int64 = 1024 * 1024) -> [CleanableItem] {
        let fileManager = FileManager.default
        let rootURL = home.appendingPathComponent(rule.relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        switch rule.layout {
        case .whole:
            let size = CleanupManager.allocatedSize(atPath: rootURL.path)
            guard size > minSize else { return [] }
            return [CleanableItem(
                name: rule.name,
                path: rootURL.path,
                size: size,
                category: .developerTools,
                isSelected: rule.defaultSelected,
                description: rule.note,
                lastModified: modificationDate(of: rootURL)
            )]

        case .perChild, .perChildKeepNewest:
            guard let children = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var items: [CleanableItem] = children.compactMap { child in
                let size = CleanupManager.allocatedSize(atPath: child.path)
                guard size > minSize else { return nil }
                var item = CleanableItem(
                    name: "\(rule.name) · \(displayName(forChild: child, of: rule))",
                    path: child.path,
                    size: size,
                    category: .developerTools,
                    isSelected: rule.defaultSelected,
                    description: rule.note,
                    lastModified: modificationDate(of: child)
                )
                item.removesContainer = true
                return item
            }

            if case .perChildKeepNewest = rule.layout, items.count > 0,
               let newestIndex = items.indices.max(by: {
                   (items[$0].lastModified ?? .distantPast) < (items[$1].lastModified ?? .distantPast)
               }) {
                items[newestIndex].isSelected = false
                items[newestIndex].description = String(localized: "最近使用的版本，默认保留")
            }
            return items
        }
    }

    /// DerivedData 目录名形如 "MacClean-abcdefghijk"，去掉哈希后缀更易读。
    nonisolated private static func displayName(forChild child: URL, of rule: DevCacheRule) -> String {
        let name = child.lastPathComponent
        if rule.relativePath.hasSuffix("DerivedData"),
           let dash = name.lastIndex(of: "-"),
           name.distance(from: dash, to: name.endIndex) > 20 {
            return String(name[..<dash])
        }
        return name
    }

    nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }
}

// MARK: - 长期未动项目的依赖/构建目录

enum ProjectArtifactFinder {

    /// 可重建的产物目录名 → 认定其所属项目的标志文件（父目录中存在任一即可）。
    nonisolated static let artifactMarkers: [String: [String]] = [
        "node_modules": ["package.json"],
        "Pods": ["Podfile"],
        ".build": ["Package.swift"],
        "target": ["Cargo.toml", "pom.xml"],
        "build": ["build.gradle", "build.gradle.kts"],
        ".gradle": ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"],
        ".venv": ["pyproject.toml", "requirements.txt", "setup.py"],
        "venv": ["pyproject.toml", "requirements.txt", "setup.py"],
        ".next": ["package.json"],
        ".nuxt": ["package.json"],
        ".dart_tool": ["pubspec.yaml"],
    ]

    /// 遍历时直接跳过的目录（系统/媒体库/云盘/隐藏目录等）。
    nonisolated private static let skippedTopLevel: Set<String> = [
        "Library", "Applications", "Movies", "Music", "Pictures", "Public",
    ]

    nonisolated private static let bundleExtensions: Set<String> = [
        "app", "bundle", "framework", "xcarchive", "photoslibrary", "musiclibrary", "xcodeproj", "xcworkspace",
    ]

    /// 在 home 下查找「项目超过 staleDays 天未修改」的产物目录。
    /// - 超过 selectAfterDays 天未动的默认勾选，其余列出但不勾选。
    nonisolated static func find(
        home: URL,
        staleDays: Int = 30,
        selectAfterDays: Int = 90,
        maxDepth: Int = 6,
        now: Date = Date(),
        minSize: Int64 = 1024 * 1024
    ) -> [CleanableItem] {
        let fileManager = FileManager.default
        let homePath = home.standardizedFileURL.path
        let staleCutoff = now.addingTimeInterval(-Double(staleDays) * 86_400)
        let selectCutoff = now.addingTimeInterval(-Double(selectAfterDays) * 86_400)

        // 第一步只遍历目录结构、收集候选；大小统计放到第二步并行做（这是最耗时的部分）。
        var candidates: [(path: String, projectPath: String, name: String, projectDate: Date)] = []
        var stack: [(path: String, depth: Int)] = [(homePath, 0)]

        while let (dirPath, depth) = stack.popLast() {
            if Task.isCancelled { break }
            guard let names = try? fileManager.contentsOfDirectory(atPath: dirPath) else { continue }
            let nameSet = Set(names)

            for name in names {
                let childPath = dirPath + "/" + name
                var info = stat()
                guard lstat(childPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }

                if let markers = artifactMarkers[name], markers.contains(where: nameSet.contains) {
                    // .venv / venv 必须真的是虚拟环境
                    if name.hasSuffix("venv"), !fileManager.fileExists(atPath: childPath + "/pyvenv.cfg") { continue }

                    let projectDate = projectModificationDate(projectPath: dirPath, names: names)
                    guard projectDate < staleCutoff else { continue }
                    candidates.append((childPath, dirPath, name, projectDate))
                    continue
                }

                // 不深入：隐藏目录、依赖目录、包、顶层系统/媒体目录
                if name.hasPrefix(".") { continue }
                if name == "node_modules" || name == "Pods" { continue }
                if depth == 0, skippedTopLevel.contains(name) { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                if !ext.isEmpty, bundleExtensions.contains(ext) { continue }
                if depth + 1 < maxDepth {
                    stack.append((childPath, depth + 1))
                }
            }
        }

        var sizes = [Int64](repeating: 0, count: candidates.count)
        sizes.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
                base[index] = CleanupManager.allocatedSize(atPath: candidates[index].path)
            }
        }

        var results: [CleanableItem] = []
        for (index, candidate) in candidates.enumerated() where sizes[index] > minSize {
            let days = Int(now.timeIntervalSince(candidate.projectDate) / 86_400)
            let projectName = (candidate.projectPath as NSString).lastPathComponent
            let location = candidate.projectPath.hasPrefix(homePath)
                ? "~" + candidate.projectPath.dropFirst(homePath.count)
                : candidate.projectPath
            var item = CleanableItem(
                name: "\(projectName) / \(candidate.name)",
                path: candidate.path,
                size: sizes[index],
                category: .projectArtifacts,
                isSelected: candidate.projectDate < selectCutoff,
                description: String(localized: "\(location) · \(days) 天未修改"),
                lastModified: candidate.projectDate
            )
            item.removesContainer = true
            results.append(item)
        }

        return results.sorted { $0.size > $1.size }
    }

    /// 项目最近修改时间：项目目录下一级条目（排除产物目录本身）的最大修改时间。
    nonisolated static func projectModificationDate(projectPath: String, names: [String]) -> Date {
        var latest = Date.distantPast
        for name in names where artifactMarkers[name] == nil && name != ".DS_Store" {
            var info = stat()
            guard lstat(projectPath + "/" + name, &info) == 0 else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if date > latest { latest = date }
        }
        return latest
    }
}
