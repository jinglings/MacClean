//
//  BrowserExtensions.swift
//  MacClean
//
//  安全中心 · 浏览器扩展：列出 Chrome / Edge / Brave（各配置文件）、Firefox 与 Safari 的扩展。
//  能读取所有网站并拦截 / 代理网络请求的扩展标为「权限较大」，只作提示。
//  只读取 manifest 与配置，不改动浏览器。
//

import Foundation

nonisolated struct BrowserExtension: Identifiable, Equatable, Sendable {
    let browser: String
    /// 浏览器的配置文件名（Chrome「个人」等）；Safari 为 nil
    let profile: String?
    let identifier: String
    let name: String
    let version: String?
    /// 访问所有网站 + 可拦截或代理请求
    let hasBroadPermissions: Bool
    /// Firefox 中被停用；其他浏览器无法可靠读取，按启用处理
    var isActive = true
    /// 扩展所在目录（在 Finder 中显示）
    let path: String?

    var id: String { "\(browser)|\(profile ?? "")|\(identifier)" }
}

enum BrowserExtensionParser {

    nonisolated static let broadHosts: Set<String> = [
        "<all_urls>", "*://*/*", "http://*/*", "https://*/*", "*://*/", "http://*/", "https://*/",
    ]
    nonisolated static let powerfulPermissions: Set<String> = [
        "webRequest", "webRequestBlocking", "proxy", "nativeMessaging", "debugger",
    ]

    /// manifest 中声明的全部权限字符串（含 host 权限与内容脚本的匹配规则）
    nonisolated static func permissions(manifest: [String: Any]) -> [String] {
        var result: [String] = []
        for key in ["permissions", "host_permissions", "optional_host_permissions"] {
            result += (manifest[key] as? [Any] ?? []).compactMap { $0 as? String }
        }
        for script in manifest["content_scripts"] as? [[String: Any]] ?? [] {
            result += script["matches"] as? [String] ?? []
        }
        return result
    }

    nonisolated static func hasBroadPermissions(_ permissions: [String]) -> Bool {
        let broad = permissions.contains { broadHosts.contains($0) }
        let powerful = permissions.contains { powerfulPermissions.contains($0) }
        return broad && powerful
    }

    /// "__MSG_appName__" → messages.json 中 appName（键不区分大小写）的 message；找不到返回 nil。
    nonisolated static func resolveMessage(_ value: String, messages: [String: Any]) -> String? {
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__"), value.count > 8 else { return value }
        let key = String(value.dropFirst(6).dropLast(2)).lowercased()
        for (name, entry) in messages where name.lowercased() == key {
            if let message = (entry as? [String: Any])?["message"] as? String, !message.isEmpty { return message }
        }
        return nil
    }

    /// 从扩展版本目录读取名称：优先 default_locale，再试 en；仍解析不出时用 short_name 或 id。
    nonisolated static func extensionName(manifest: [String: Any], directory: String, fallback: String) -> String {
        let raw = (manifest["name"] as? String) ?? fallback
        guard raw.hasPrefix("__MSG_") else { return raw }
        var locales: [String] = []
        if let locale = manifest["default_locale"] as? String { locales.append(locale) }
        locales += ["en", "en_US"]
        for locale in locales {
            let file = directory + "/_locales/" + locale + "/messages.json"
            guard let data = FileManager.default.contents(atPath: file),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resolved = resolveMessage(raw, messages: messages) else { continue }
            return resolved
        }
        if let short = manifest["short_name"] as? String, !short.hasPrefix("__MSG_") { return short }
        return fallback
    }

    /// Chromium 的「Local State」→ 配置文件目录名 → 显示名
    nonisolated static func chromiumProfileNames(localState: Data) -> [String: String] {
        guard let json = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (directory, value) in cache {
            if let name = (value as? [String: Any])?["name"] as? String { names[directory] = name }
        }
        return names
    }

    /// Chromium 扩展 id：32 位 a–p 字母
    nonisolated static func isChromiumExtensionID(_ name: String) -> Bool {
        name.count == 32 && name.allSatisfy { ("a"..."p").contains($0) }
    }

    /// Firefox profile 中的 extensions.json
    nonisolated static func firefoxExtensions(_ data: Data, profile: String) -> [BrowserExtension] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addons = json["addons"] as? [[String: Any]] else { return [] }
        return addons.compactMap { addon in
            guard (addon["type"] as? String) == "extension",
                  let id = addon["id"] as? String else { return nil }
            // 浏览器自带的系统扩展不列出
            let location = addon["location"] as? String ?? ""
            if location == "app-builtin" || location.hasPrefix("app-system") { return nil }
            let locale = addon["defaultLocale"] as? [String: Any]
            let name = (locale?["name"] as? String) ?? (addon["name"] as? String) ?? id
            let permissions = ((addon["userPermissions"] as? [String: Any])?["permissions"] as? [String] ?? [])
                + ((addon["userPermissions"] as? [String: Any])?["origins"] as? [String] ?? [])
            return BrowserExtension(
                browser: "Firefox",
                profile: profile,
                identifier: id,
                name: name,
                version: addon["version"] as? String,
                hasBroadPermissions: hasBroadPermissions(permissions),
                isActive: addon["active"] as? Bool ?? true,
                path: addon["path"] as? String
            )
        }
    }

    /// `pluginkit -mAvvv -p com.apple.Safari.web-extension`。没有时输出 "(no matches)"。
    /// 每个扩展以一行 "     com.example.ext(1.0)" 开头，后面是 "Key = Value" 详情行。
    nonisolated static func safariExtensions(pluginkitOutput: String) -> [BrowserExtension] {
        var result: [BrowserExtension] = []
        var identifier: String?
        var version: String?
        var fields: [String: String] = [:]

        func flush() {
            guard let id = identifier else { return }
            let name = fields["Display Name"] ?? fields["Short Name"] ?? fields["Parent Name"] ?? id
            result.append(BrowserExtension(
                browser: "Safari",
                profile: nil,
                identifier: id,
                name: name,
                version: version,
                hasBroadPermissions: false,
                path: fields["Parent Bundle"] ?? fields["Path"]
            ))
            identifier = nil
            version = nil
            fields = [:]
        }

        for raw in pluginkitOutput.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "(no matches)" { continue }
            if let equals = line.range(of: " = ") {
                fields[String(line[..<equals.lowerBound]).trimmingCharacters(in: .whitespaces)] =
                    String(line[equals.upperBound...]).trimmingCharacters(in: .whitespaces)
                continue
            }
            // 新条目：前面可能带 +/-/! 等启用状态标记
            var header = line
            if let first = header.first, "+-!=?".contains(first) {
                header = String(header.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard let open = header.lastIndex(of: "("), header.hasSuffix(")") else { continue }
            flush()
            identifier = String(header[..<open])
            version = String(header[header.index(after: open)..<header.index(before: header.endIndex)])
        }
        flush()
        return result
    }
}

enum BrowserExtensionScanner {

    nonisolated static func chromiumBrowsers(home: String) -> [(name: String, root: String)] {
        let support = home + "/Library/Application Support/"
        return [
            ("Chrome", support + "Google/Chrome"),
            ("Edge", support + "Microsoft Edge"),
            ("Brave", support + "BraveSoftware/Brave-Browser"),
        ]
    }

    nonisolated static func scan(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [BrowserExtension] {
        var result: [BrowserExtension] = []
        for (browser, root) in chromiumBrowsers(home: home) {
            result += chromiumExtensions(browser: browser, root: root)
        }
        result += firefoxExtensions(home: home)
        let safari = SystemProtectionScanner.run("/usr/bin/pluginkit", ["-mAvvv", "-p", "com.apple.Safari.web-extension"])
        result += BrowserExtensionParser.safariExtensions(pluginkitOutput: safari)
        return result
    }

    nonisolated static func chromiumExtensions(browser: String, root: String) -> [BrowserExtension] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        let profileNames = fileManager.contents(atPath: root + "/Local State").map(BrowserExtensionParser.chromiumProfileNames(localState:)) ?? [:]
        let profiles = entries.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()

        var result: [BrowserExtension] = []
        for profile in profiles {
            let extensionsDir = root + "/" + profile + "/Extensions"
            guard let ids = try? fileManager.contentsOfDirectory(atPath: extensionsDir) else { continue }
            for id in ids.sorted() where BrowserExtensionParser.isChromiumExtensionID(id) {
                let idDir = extensionsDir + "/" + id
                // 可能残留多个版本目录，取版本号最大的
                guard let versionDir = (try? fileManager.contentsOfDirectory(atPath: idDir))?
                        .filter({ !$0.hasPrefix(".") })
                        .max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else { continue }
                let directory = idDir + "/" + versionDir
                guard let data = fileManager.contents(atPath: directory + "/manifest.json"),
                      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                result.append(BrowserExtension(
                    browser: browser,
                    profile: profileNames[profile] ?? profile,
                    identifier: id,
                    name: BrowserExtensionParser.extensionName(manifest: manifest, directory: directory, fallback: id),
                    version: manifest["version"] as? String,
                    hasBroadPermissions: BrowserExtensionParser.hasBroadPermissions(BrowserExtensionParser.permissions(manifest: manifest)),
                    path: idDir
                ))
            }
        }
        return result
    }

    nonisolated static func firefoxExtensions(home: String) -> [BrowserExtension] {
        let fileManager = FileManager.default
        let root = home + "/Library/Application Support/Firefox/Profiles"
        guard let profiles = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        var result: [BrowserExtension] = []
        for profile in profiles.sorted() {
            guard let data = fileManager.contents(atPath: root + "/" + profile + "/extensions.json") else { continue }
            // 目录名形如 "abcd1234.default-release"，点后面是用户起的名字
            let display = profile.split(separator: ".", maxSplits: 1).last.map(String.init) ?? profile
            result += BrowserExtensionParser.firefoxExtensions(data, profile: display)
        }
        return result
    }
}
