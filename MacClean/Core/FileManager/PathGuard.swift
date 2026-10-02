//
//  PathGuard.swift
//  MacClean
//
//  删除路径安全校验
//

import Foundation

// MARK: - 路径校验错误

enum PathGuardError: LocalizedError {
    case protectedPath(String)       // 命中黑名单或系统关键路径
    case outsideAllowedRoots(String) // 不在该分类允许的根目录内
    case pathTooShallow(String)      // 路径层级过浅
    case symlinkEscape(String)       // 符号链接解析后逃出允许范围

    var errorDescription: String? {
        switch self {
        case .protectedPath(let path):
            return String(localized: "路径受保护，禁止删除: \(path)")
        case .outsideAllowedRoots(let path):
            return String(localized: "路径不在该分类允许的目录范围内: \(path)")
        case .pathTooShallow(let path):
            return String(localized: "路径层级过浅，禁止删除: \(path)")
        case .symlinkEscape(let path):
            return String(localized: "符号链接指向受保护区域之外的范围，禁止删除: \(path)")
        }
    }
}

// MARK: - 路径保护栏

/// 在真正执行删除/移入废纸篓之前，对目标路径做安全校验，防止误删用户重要数据或系统关键目录。
enum PathGuard {

    /// 校验某个路径对于给定分类是否允许删除；不允许则抛出 PathGuardError。
    /// - removesContainer: 为 true 表示要把 path 本身移走；为 false 表示只清空其内容，
    ///   此时允许 path 恰好等于少数「可整体清空」的根目录（废纸篓、邮件附件、开发缓存规则目录）。
    nonisolated static func validate(
        path: String,
        category: CleanableCategory,
        removesContainer: Bool = false,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        // 1. standardize 并解析符号链接，后续所有判断基于解析后的真实路径。
        let originalURL = URL(fileURLWithPath: path).standardizedFileURL
        let resolvedURL = originalURL.resolvingSymlinksInPath()
        let resolvedPath = resolvedURL.path

        do {
            try validateRules(path: resolvedPath, category: category, removesContainer: removesContainer, homeDirectory: homeDirectory)
        } catch {
            // 若真实路径未通过校验，但原始路径本身是符号链接（即两者不同），
            // 说明是符号链接逃逸出了允许的范围。
            if resolvedPath != originalURL.path {
                throw PathGuardError.symlinkEscape(path)
            }
            throw error
        }
    }

    /// 空间透镜专用校验：允许删除 /Users 下任意深度的普通文件/目录（进废纸篓可恢复），
    /// 但拒绝系统关键路径、主目录顶级重要文件夹本身，以及层级过浅的路径。
    nonisolated static func validateForSpaceLens(
        path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let originalURL = URL(fileURLWithPath: SpaceLensItem.cleanPath(path)).standardizedFileURL
        let resolvedURL = originalURL.resolvingSymlinksInPath()
        let resolvedPath = resolvedURL.path

        do {
            try validateSpaceLensRules(path: resolvedPath, homeDirectory: homeDirectory)
        } catch {
            if resolvedPath != originalURL.path {
                throw PathGuardError.symlinkEscape(path)
            }
            throw error
        }
    }

    // MARK: - 规则校验（基于已解析的真实路径）

    nonisolated private static func validateRules(
        path: String,
        category: CleanableCategory,
        removesContainer: Bool,
        homeDirectory: URL
    ) throws {
        let home = homeDirectory.standardizedFileURL.path

        switch category {
        case .applications:
            // 只允许 /Applications 或 ~/Applications 下直接的 .app 包整体移走
            let parent = (path as NSString).deletingLastPathComponent
            guard removesContainer, path.hasSuffix(".app"),
                  parent == "/Applications" || parent == home + "/Applications" else {
                throw PathGuardError.outsideAllowedRoots(path)
            }
            return
        case .spaceLens:
            try validateSpaceLensRules(path: path, homeDirectory: homeDirectory)
            return
        default:
            break
        }

        try validateShallowPathAndBlacklist(path: path, home: home)

        if !removesContainer, clearableRoots(for: category, home: home).contains(path) {
            return
        }

        // 按分类校验允许的根目录
        let allowedRoots = allowedRoots(for: category, home: home)
        let isAllowed = allowedRoots.contains { root in
            path.hasPrefix(root + "/")
        }
        guard isAllowed else {
            throw PathGuardError.outsideAllowedRoots(path)
        }
    }

    nonisolated private static func validateSpaceLensRules(path: String, homeDirectory: URL) throws {
        let home = homeDirectory.standardizedFileURL.path

        try validateShallowPathAndBlacklist(path: path, home: home)

        // 系统关键路径一律拒绝，其余 /Users 下的普通文件/目录允许删除。
        let systemPrefixes = ["/System", "/usr", "/bin", "/sbin", "/etc", "/opt", "/private", "/Library", "/Applications"]
        for prefix in systemPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") {
                throw PathGuardError.protectedPath(path)
            }
        }
    }

    /// 两个入口共用的规则：路径层级过浅拒绝 + 主目录顶级重要文件夹/iCloud Drive 子树拒绝。
    nonisolated private static func validateShallowPathAndBlacklist(path: String, home: String) throws {
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count >= 4 else {
            throw PathGuardError.pathTooShallow(path)
        }

        let icloudDrive = home + "/Library/Mobile Documents"
        let blacklist: Set<String> = [
            home,
            home + "/Documents",
            home + "/Desktop",
            home + "/Downloads",
            home + "/Pictures",
            home + "/Movies",
            home + "/Music",
            home + "/Library",
        ]
        if blacklist.contains(path) {
            throw PathGuardError.protectedPath(path)
        }
        if path == icloudDrive || path.hasPrefix(icloudDrive + "/") {
            throw PathGuardError.protectedPath(path)
        }
    }

    /// 只清空内容时允许作为目标本身的根目录。
    nonisolated private static func clearableRoots(for category: CleanableCategory, home: String) -> [String] {
        switch category {
        case .trash, .mailAttachments:
            return allowedRoots(for: category, home: home)
        case .developerTools:
            return DevCacheCatalog.rules.map { home + "/" + $0.relativePath }
        case .userCache:
            return [home + "/Library/Saved Application State"]
        default:
            return []
        }
    }

    nonisolated private static func allowedRoots(for category: CleanableCategory, home: String) -> [String] {
        switch category {
        case .userCache, .browserCache:
            return [
                home + "/Library/Caches",
                home + "/Library/Saved Application State",
            ]
        case .developerTools:
            return DevCacheCatalog.allowedRoots(home: home)
        case .systemLogs:
            return [home + "/Library/Logs"]
        case .largeFiles, .oldFiles, .duplicates, .projectArtifacts, .similarPhotos:
            return [home]
        case .brokenLoginItems:
            return [home + "/Library/LaunchAgents"]
        case .trash:
            return [home + "/.Trash"]
        case .appData:
            // 只允许应用自己的数据目录；~/Library 这些根目录本身由 blacklist / 严格子路径规则挡住
            return [
                home + "/Library/Containers",
                home + "/Library/Group Containers",
                home + "/Library/Application Support",
                home + "/Library/Caches",
                home + "/Library/Logs",
            ]
        case .appLeftovers:
            return [
                home + "/Library/Containers",
                home + "/Library/Group Containers",
                home + "/Library/Application Support",
                home + "/Library/Application Scripts",
                home + "/Library/Caches",
                home + "/Library/Logs",
                home + "/Library/Preferences",
                home + "/Library/Saved Application State",
                home + "/Library/HTTPStorages",
                home + "/Library/WebKit",
                home + "/Library/LaunchAgents",
                home + "/Library/Cookies",
            ]
        case .privacyData:
            return [
                home + "/Library/Safari",
                home + "/Library/Cookies",
                home + "/Library/HTTPStorages",
                home + "/Library/WebKit",
                home + "/Library/Containers/com.apple.Safari",
                home + "/Library/Application Support/Google/Chrome",
                home + "/Library/Application Support/Microsoft Edge",
                home + "/Library/Application Support/BraveSoftware",
                home + "/Library/Application Support/Firefox/Profiles",
                home + "/Library/Application Support/com.apple.sharedfilelist",
            ]
        case .aiModels:
            return AIModelCatalog.allowedRoots(home: home)
        case .applications, .spaceLens:
            return []
        case .installers:
            return [home + "/Downloads", home + "/Desktop"]
        case .mailAttachments:
            return [home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"]
        case .iosBackups:
            return [home + "/Library/Application Support/MobileSync/Backup"]
        case .iosUpdates:
            return [
                home + "/Library/iTunes/iPhone Software Updates",
                home + "/Library/iTunes/iPad Software Updates",
                home + "/Library/iTunes/iPod Software Updates",
            ]
        }
    }
}
