//
//  DiskAnalyzer.swift
//  MacClean
//
//  磁盘分析器
//

import Foundation

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

actor DiskAnalyzer {
    static let shared = DiskAnalyzer()
    
    private init() {}
    private var spaceLensScannedItems = 0
    private let spaceLensVisibleFolderLimit = 10
    private var spaceLensDirectoryCache: [String: SpaceLensDirectoryCacheEntry] = [:]
    
    private struct SpaceLensDirectoryCacheEntry {
        let signature: String
        let item: SpaceLensItem
    }
    
    // MARK: - 磁盘分析
    
    func analyzeDisk() async throws -> ScanResult {
        let startTime = Date()
        
        print("=== 开始磁盘分析 ===")
        
        // 获取磁盘信息
        let diskInfo = try getDiskInfo()
        print("磁盘信息: \(diskInfo.volumeName), 总空间: \(diskInfo.totalSpace), 可用: \(diskInfo.freeSpace)")
        
        // 扫描可清理项目
        var cleanableItems: [CleanableItem] = []
        
        // 扫描用户缓存
        print("正在扫描用户缓存...")
        let userCaches = await scanUserCaches()
        print("用户缓存: 发现 \(userCaches.count) 个项目")
        cleanableItems.append(contentsOf: userCaches)
        
        // 扫描浏览器缓存
        print("正在扫描浏览器缓存...")
        let browserCaches = await scanBrowserCaches()
        print("浏览器缓存: 发现 \(browserCaches.count) 个项目")
        cleanableItems.append(contentsOf: browserCaches)
        
        // 扫描开发者工具缓存
        print("正在扫描开发者工具缓存...")
        let devCaches = await scanDeveloperCaches()
        print("开发者缓存: 发现 \(devCaches.count) 个项目")
        cleanableItems.append(contentsOf: devCaches)
        
        // 扫描用户日志
        print("正在扫描用户日志...")
        let logs = await scanUserLogs()
        print("用户日志: 发现 \(logs.count) 个项目")
        cleanableItems.append(contentsOf: logs)
        
        let duration = Date().timeIntervalSince(startTime)
        print("=== 扫描完成，共发现 \(cleanableItems.count) 个项目，耗时 \(duration) 秒 ===")
        
        return ScanResult(
            diskInfo: diskInfo,
            cleanableItems: cleanableItems,
            scanDuration: duration
        )
    }
    
    // macOS Catalina+: user data lives on the APFS data volume.
    // Firmlinks at / (e.g., /Users, /Applications) lack APFS cached sizes;
    // directories under /System/Volumes/Data have correct O(1) totalFileAllocatedSize.
    static let dataVolumeRoot = "/System/Volumes/Data"

    // MARK: - 空间透镜扫描

    func scanSpaceLens(
        rootURL: URL = URL(fileURLWithPath: "/"),
        progress: (@Sendable (SpaceLensScanProgress) -> Void)? = nil
    ) async throws -> SpaceLensScanResult {
        let startTime = Date()
        spaceLensScannedItems = 0

        let diskInfo = try getDiskInfo()

        // If caller requests root (/), redirect to the APFS data volume so that
        // totalFileAllocatedSizeKey returns correct recursive sizes for all directories.
        let effectiveRoot: URL
        if rootURL.path == "/" {
            let dataVol = URL(fileURLWithPath: Self.dataVolumeRoot)
            effectiveRoot = FileManager.default.fileExists(atPath: dataVol.path) ? dataVol : rootURL
        } else {
            effectiveRoot = rootURL
        }

        let root = try await scanSpaceLensDirectory(at: effectiveRoot.standardizedFileURL, progress: progress)
        let duration = Date().timeIntervalSince(startTime)

        return SpaceLensScanResult(
            root: root,
            diskInfo: diskInfo,
            scanDuration: duration
        )
    }

    func scanSpaceLensDirectory(
        at url: URL,
        progress: (@Sendable (SpaceLensScanProgress) -> Void)? = nil,
        partialResult: (@Sendable (SpaceLensItem) -> Void)? = nil
    ) async throws -> SpaceLensItem {
        try await scanSpaceLensDirectoryLevel(
            at: url.standardizedFileURL,
            progress: progress,
            partialResult: partialResult
        )
    }
    
    // MARK: - 获取磁盘信息
    
    private func getDiskInfo() throws -> DiskInfo {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        
        let values = try homeURL.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        
        return DiskInfo(
            volumeName: values.volumeName ?? "Macintosh HD",
            totalSpace: Int64(values.volumeTotalCapacity ?? 0),
            freeSpace: Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        )
    }
    
    private func scanSpaceLensDirectoryLevel(
        at url: URL,
        progress: (@Sendable (SpaceLensScanProgress) -> Void)?,
        partialResult: (@Sendable (SpaceLensItem) -> Void)?
    ) async throws -> SpaceLensItem {
        try Task.checkCancellation()

        let fileManager = FileManager.default
        let path = url.path
        let metaKeys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .localizedNameKey, .totalFileSizeKey
        ]
        let values = try? url.resourceValues(forKeys: metaKeys)
        let name = displayName(for: url, fallback: values?.localizedName)
        let lastModified = values?.contentModificationDate
        let signature = directorySignature(values: values)

        if let cached = spaceLensDirectoryCache[path], cached.signature == signature {
            return cached.item
        }

        spaceLensScannedItems += 1
        let progressPath = cleanProgressPath(path)
        progress?(SpaceLensScanProgress(
            scannedPath: progressPath,
            scannedItems: spaceLensScannedItems,
            progress: scanProgressEstimate(for: spaceLensScannedItems)
        ))

        if shouldSkipSpaceLensDirectory(path) {
            return SpaceLensItem(name: name, path: path, size: 0, isDirectory: true,
                                 children: [], itemCount: 0, isReadable: false,
                                 isVirtual: false, lastModified: lastModified)
        }

        let childURLs: [URL]
        do {
            childURLs = try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(metaKeys),
                options: [.skipsPackageDescendants])
        } catch {
            return SpaceLensItem(name: name, path: path, size: 0, isDirectory: true,
                                 children: [], itemCount: 0, isReadable: false,
                                 isVirtual: false, lastModified: lastModified)
        }

        // Partition children into directories and files
        var dirEntries: [(url: URL, values: URLResourceValues?)] = []
        var directFilesSize: Int64 = 0
        var directFilesCount = 0

        for childURL in childURLs {
            try Task.checkCancellation()
            let cv = try? childURL.resourceValues(forKeys: metaKeys)
            if cv?.isDirectory == true && cv?.isSymbolicLink != true && cv?.isPackage != true {
                let cp = childURL.standardizedFileURL.path
                if !shouldSkipSpaceLensDirectory(cp) {
                    dirEntries.append((childURL.standardizedFileURL, cv))
                }
            } else {
                directFilesSize += Int64(cv?.fileAllocatedSize ?? 0)
                directFilesCount += 1
            }
        }

        // ── Parallel size computation ──────────────────────────────────────────
        // Each child directory is scanned concurrently via a task group.
        // Self.recursiveSize is a *static* function — not actor-isolated — so
        // child tasks run on the cooperative thread pool in true parallel.
        // Within each task, subdirectories are scanned sequentially to avoid
        // spawning an unbounded number of nested tasks.
        var completedFolderChildren: [SpaceLensItem] = []
        let metadataByPath = Dictionary(uniqueKeysWithValues: dirEntries.map { ($0.url.path, $0) })
        try await withThrowingTaskGroup(of: (String, Int64).self) { group in
            for entry in dirEntries {
                let childPath = entry.url.path
                let childURL  = entry.url
                spaceLensScannedItems += 1
                progress?(SpaceLensScanProgress(
                    scannedPath: cleanProgressPath(childPath),
                    scannedItems: spaceLensScannedItems,
                    progress: scanProgressEstimate(for: spaceLensScannedItems)
                ))
                group.addTask {
                    let size = try await Self.recursiveSize(at: childURL)
                    return (childPath, size)
                }
            }
            for try await (cp, sz) in group {
                guard let entry = metadataByPath[cp] else { continue }
                completedFolderChildren.append(SpaceLensItem(
                    name: displayName(for: entry.url, fallback: entry.values?.localizedName),
                    path: cp,
                    size: sz,
                    isDirectory: true,
                    children: [],
                    itemCount: 0,
                    isReadable: FileManager.default.isReadableFile(atPath: cp),
                    isVirtual: false,
                    lastModified: entry.values?.contentModificationDate
                ))
                
                if let partialResult {
                    let partialChildren = summarizedChildren(
                        folderChildren: completedFolderChildren,
                        directFilesSize: directFilesSize,
                        directFilesCount: directFilesCount,
                        parentPath: path
                    )
                    partialResult(SpaceLensItem(
                        name: name,
                        path: path,
                        size: max(Int64(values?.fileAllocatedSize ?? 0), partialChildren.reduce(0) { $0 + $1.size }),
                        isDirectory: true,
                        children: partialChildren,
                        itemCount: childURLs.count,
                        isReadable: true,
                        isVirtual: false,
                        lastModified: lastModified
                    ))
                }
            }
        }

        let visibleChildren = summarizedChildren(
            folderChildren: completedFolderChildren,
            directFilesSize: directFilesSize,
            directFilesCount: directFilesCount,
            parentPath: path
        )

        let childrenTotalSize = visibleChildren.reduce(0) { $0 + $1.size }
        let totalSize = max(Int64(values?.fileAllocatedSize ?? 0), childrenTotalSize)

        let item = SpaceLensItem(
            name: name, path: path, size: totalSize, isDirectory: true,
            children: visibleChildren.sorted { $0.size > $1.size },
            itemCount: childURLs.count, isReadable: true, isVirtual: false,
            lastModified: lastModified
        )
        spaceLensDirectoryCache[path] = SpaceLensDirectoryCacheEntry(signature: signature, item: item)
        return item
    }

    // ── Static recursive size scanner ──────────────────────────────────────────
    // Static (not actor-isolated) so multiple task-group children run in TRUE
    // parallel on Swift's cooperative thread pool — not serialised through the actor.
    // Subdirectories within one task are traversed sequentially to bound concurrency.
    private static func recursiveSize(at url: URL) async throws -> Int64 {
        try Task.checkCancellation()

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileAllocatedSizeKey
        ]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return 0 }

        var total: Int64 = 0
        for child in children {
            try Task.checkCancellation()
            let cv = try? child.resourceValues(forKeys: keys)
            if cv?.isDirectory == true && cv?.isSymbolicLink != true && cv?.isPackage != true {
                let cp = child.standardizedFileURL.path
                // Skip virtual/loop paths even inside recursive traversal
                if cp.hasPrefix("/System/Volumes/") && !cp.hasPrefix("/System/Volumes/Data/") { continue }
                if cp == "/dev" || cp == "/proc" || cp.hasPrefix("/private/var/vm") { continue }
                total += try await recursiveSize(at: child.standardizedFileURL)
            } else {
                total += Int64(cv?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
    
    private func summarizedChildren(
        folderChildren: [SpaceLensItem],
        directFilesSize: Int64,
        directFilesCount: Int,
        parentPath: String
    ) -> [SpaceLensItem] {
        let sortedFolders = folderChildren.sorted { $0.size > $1.size }
        var visibleChildren = Array(sortedFolders.prefix(spaceLensVisibleFolderLimit))
        let hiddenFolders = Array(sortedFolders.dropFirst(spaceLensVisibleFolderLimit))
        let otherSize = directFilesSize + hiddenFolders.reduce(0) { $0 + $1.size }
        let otherCount = directFilesCount + hiddenFolders.reduce(0) { $0 + 1 + $1.itemCount }
        
        if otherSize > 0 || otherCount > 0 {
            visibleChildren.append(SpaceLensItem(
                name: "其他",
                path: parentPath + "/.space-lens-other",
                size: otherSize,
                isDirectory: true,
                children: [],
                itemCount: otherCount,
                isReadable: false,
                isVirtual: true,
                lastModified: nil
            ))
        }
        
        return visibleChildren.sorted { $0.size > $1.size }
    }

    private func cleanProgressPath(_ path: String) -> String {
        path.hasPrefix(Self.dataVolumeRoot)
            ? String(path.dropFirst(Self.dataVolumeRoot.count)).ifEmpty("/")
            : path
    }

    private func shouldSkipSpaceLensDirectory(_ path: String) -> Bool {
        // Exact paths to skip (virtual fs, loop-causing mounts, inaccessible)
        let exactSkip: Set<String> = [
            "/dev", "/Volumes", "/Network", "/net", "/proc", "/private/var/vm",
            "/System/Volumes/Data/dev",
            "/System/Volumes/Data/Volumes",
            "/System/Volumes/Data/private/var/vm",
        ]
        if exactSkip.contains(path) { return true }

        // Skip non-data system volumes (Preboot, Recovery, VM, etc.)
        // but NOT the data volume itself or paths under it.
        let systemVolumeSkipPrefixes = [
            "/System/Volumes/Preboot",
            "/System/Volumes/Recovery",
            "/System/Volumes/VM",
            "/System/Volumes/xarts",
            "/System/Volumes/iSCPreboot",
            "/System/Volumes/Hardware",
        ]
        for prefix in systemVolumeSkipPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") { return true }
        }

        // Prevent recursion back into volumes from within the data volume
        if path == "/System/Volumes/Data/System/Volumes" ||
            path.hasPrefix("/System/Volumes/Data/System/Volumes/") { return true }

        return false
    }
    
    private func scanProgressEstimate(for scannedFolders: Int) -> Double {
        1.0 - (1.0 / sqrt(Double(max(scannedFolders, 1)) + 1.0))
    }
    
    private func allocatedSize(from values: URLResourceValues?, fallback: Int64 = 0) -> Int64 {
        if let totalFileAllocatedSize = values?.totalFileAllocatedSize, totalFileAllocatedSize > 0 {
            return Int64(totalFileAllocatedSize)
        }
        if let fileAllocatedSize = values?.fileAllocatedSize, fileAllocatedSize > 0 {
            return Int64(fileAllocatedSize)
        }
        if let totalFileSize = values?.totalFileSize, totalFileSize > 0 {
            return Int64(totalFileSize)
        }
        if let fileSize = values?.fileSize, fileSize > 0 {
            return Int64(fileSize)
        }
        return fallback
    }
    
    
    private func directorySignature(values: URLResourceValues?) -> String {
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let allocated = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
        let size = values?.totalFileSize ?? values?.fileSize ?? 0
        return "\(modified)-\(allocated)-\(size)"
    }
    
    private func displayName(for url: URL, fallback: String?) -> String {
        let path = url.path
        if path == "/" || path == Self.dataVolumeRoot {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return (try? home.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        }
        if let fallback, !fallback.isEmpty { return fallback }
        return url.lastPathComponent.isEmpty ? path : url.lastPathComponent
    }
    
    // MARK: - 扫描用户缓存
    
    private func scanUserCaches() async -> [CleanableItem] {
        var items: [CleanableItem] = []
        let cachesPath = NSHomeDirectory() + "/Library/Caches"
        
        print("  扫描路径: \(cachesPath)")
        
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: cachesPath) else {
            print("  ❌ 无法读取缓存目录")
            return items
        }
        
        print("  找到 \(contents.count) 个子目录")
        
        for folder in contents {
            let folderPath = cachesPath + "/" + folder
            let size = calculateDirectorySize(at: folderPath)
            
            // 降低阈值到 1MB 以便测试
            if size > 1_000_000 {
                print("  ✓ \(folder): \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                items.append(CleanableItem(
                    name: folder,
                    path: folderPath,
                    size: size,
                    category: .userCache,
                    isSelected: true,
                    description: NSLocalizedString("cache_safe_to_delete", comment: "")
                ))
            }
        }
        
        return items.sorted { $0.size > $1.size }
    }
    
    // MARK: - 扫描浏览器缓存
    
    private func scanBrowserCaches() async -> [CleanableItem] {
        var items: [CleanableItem] = []
        let homeDir = NSHomeDirectory()
        
        // Chrome
        let chromeCachePath = homeDir + "/Library/Caches/Google/Chrome"
        if FileManager.default.fileExists(atPath: chromeCachePath) {
            let size = calculateDirectorySize(at: chromeCachePath)
            if size > 0 {
                items.append(CleanableItem(
                    name: "Google Chrome",
                    path: chromeCachePath,
                    size: size,
                    category: .browserCache,
                    isSelected: true,
                    description: NSLocalizedString("browser_cache_description", comment: "")
                ))
            }
        }
        
        // Firefox
        let firefoxCachePath = homeDir + "/Library/Caches/Firefox"
        if FileManager.default.fileExists(atPath: firefoxCachePath) {
            let size = calculateDirectorySize(at: firefoxCachePath)
            if size > 0 {
                items.append(CleanableItem(
                    name: "Firefox",
                    path: firefoxCachePath,
                    size: size,
                    category: .browserCache,
                    isSelected: true,
                    description: NSLocalizedString("browser_cache_description", comment: "")
                ))
            }
        }
        
        // Edge
        let edgeCachePath = homeDir + "/Library/Caches/Microsoft Edge"
        if FileManager.default.fileExists(atPath: edgeCachePath) {
            let size = calculateDirectorySize(at: edgeCachePath)
            if size > 0 {
                items.append(CleanableItem(
                    name: "Microsoft Edge",
                    path: edgeCachePath,
                    size: size,
                    category: .browserCache,
                    isSelected: true,
                    description: NSLocalizedString("browser_cache_description", comment: "")
                ))
            }
        }
        
        return items
    }
    
    // MARK: - 扫描开发者缓存
    
    private func scanDeveloperCaches() async -> [CleanableItem] {
        var items: [CleanableItem] = []
        let homeDir = NSHomeDirectory()
        
        // Xcode DerivedData
        let derivedDataPath = homeDir + "/Library/Developer/Xcode/DerivedData"
        if FileManager.default.fileExists(atPath: derivedDataPath) {
            let size = calculateDirectorySize(at: derivedDataPath)
            if size > 0 {
                items.append(CleanableItem(
                    name: "Xcode DerivedData",
                    path: derivedDataPath,
                    size: size,
                    category: .developerTools,
                    isSelected: true,
                    description: NSLocalizedString("xcode_derived_data_description", comment: "")
                ))
            }
        }
        
        // Xcode Archives
        let archivesPath = homeDir + "/Library/Developer/Xcode/Archives"
        if FileManager.default.fileExists(atPath: archivesPath) {
            let size = calculateDirectorySize(at: archivesPath)
            if size > 0 {
                items.append(CleanableItem(
                    name: "Xcode Archives",
                    path: archivesPath,
                    size: size,
                    category: .developerTools,
                    isSelected: false, // 默认不选中，可能包含重要归档
                    description: NSLocalizedString("xcode_archives_description", comment: "")
                ))
            }
        }
        
        // Homebrew
        let homebrewCachePath = homeDir + "/Library/Caches/Homebrew"
        if FileManager.default.fileExists(atPath: homebrewCachePath) {
            let size = calculateDirectorySize(at: homebrewCachePath)
            if size > 0 {
                items.append(CleanableItem(
                    name: "Homebrew Cache",
                    path: homebrewCachePath,
                    size: size,
                    category: .developerTools,
                    isSelected: true,
                    description: NSLocalizedString("homebrew_cache_description", comment: "")
                ))
            }
        }
        
        // npm
        let npmCachePath = homeDir + "/.npm/_cacache"
        if FileManager.default.fileExists(atPath: npmCachePath) {
            let size = calculateDirectorySize(at: npmCachePath)
            if size > 0 {
                items.append(CleanableItem(
                    name: "npm Cache",
                    path: npmCachePath,
                    size: size,
                    category: .developerTools,
                    isSelected: true,
                    description: NSLocalizedString("npm_cache_description", comment: "")
                ))
            }
        }
        
        // CocoaPods
        let podsCachePath = homeDir + "/Library/Caches/CocoaPods"
        if FileManager.default.fileExists(atPath: podsCachePath) {
            let size = calculateDirectorySize(at: podsCachePath)
            if size > 0 {
                items.append(CleanableItem(
                    name: "CocoaPods Cache",
                    path: podsCachePath,
                    size: size,
                    category: .developerTools,
                    isSelected: true,
                    description: NSLocalizedString("cocoapods_cache_description", comment: "")
                ))
            }
        }
        
        return items
    }
    
    // MARK: - 扫描用户日志
    
    private func scanUserLogs() async -> [CleanableItem] {
        var items: [CleanableItem] = []
        let logsPath = NSHomeDirectory() + "/Library/Logs"
        
        let size = calculateDirectorySize(at: logsPath)
        if size > 10_000_000 { // 大于 10MB
            items.append(CleanableItem(
                name: "User Logs",
                path: logsPath,
                size: size,
                category: .systemLogs,
                isSelected: true,
                description: NSLocalizedString("user_logs_description", comment: "")
            ))
        }
        
        return items
    }
    
    // MARK: - 计算目录大小（优化版本，限制遍历深度和数量）
    
    private func calculateDirectorySize(at path: String, maxDepth: Int = 5, maxFiles: Int = 5000) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        var fileCount = 0
        
        // 使用 URL 方式获取，更高效
        let url = URL(fileURLWithPath: path)
        
        // 尝试使用系统 API 快速获取大小
        if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey]) {
            if let size = values.totalFileAllocatedSize {
                return Int64(size)
            }
        }
        
        // 降级到手动遍历，但限制深度和数量
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }
        
        while let fileURL = enumerator.nextObject() as? URL {
            // 限制文件数量，避免过长遍历
            fileCount += 1
            if fileCount > maxFiles {
                // 估算剩余大小
                let avgSize = totalSize / Int64(fileCount)
                // 假设剩余文件大小与当前平均值相同
                totalSize += avgSize * 100  // 粗略估算
                break
            }
            
            // 限制深度
            let depth = fileURL.pathComponents.count - url.pathComponents.count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true,
               let size = values.fileSize {
                totalSize += Int64(size)
            }
        }
        
        return totalSize
    }
}
