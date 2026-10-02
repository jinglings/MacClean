//
//  CodeSignature.swift
//  MacClean
//
//  代码签名检查（SecStaticCode）。校验可能读整个可执行文件、吊销检查还会联网，
//  所以全部是 nonisolated，只在后台线程调用。
//

import Foundation
import Security

nonisolated struct SignatureInfo: Equatable, Sendable {
    enum Validity: Equatable, Sendable {
        /// 签名完整有效
        case valid
        /// 完全没有签名
        case unsigned
        /// 有签名但校验失败（文件被改动、证书问题等）
        case invalid(OSStatus)
        /// 证书或公证已被吊销
        case revoked
        /// 文件不存在或无法读取
        case unreadable
    }

    var validity: Validity
    /// 临时签名（没有开发者身份）
    var isAdhoc = false
    var teamID: String?
    /// Apple 自己签名的系统组件
    var isApple = false
    /// Mac App Store 分发
    var isAppStore = false
    /// 满足 "notarized" 要求（经过 Apple 公证）
    var isNotarized = false

    var isValid: Bool { validity == .valid }
    /// 由已登记的开发者（Developer ID / App Store）正常签名
    var hasDeveloperIdentity: Bool { isValid && !isAdhoc && (teamID != nil || isApple) }
}

enum CodeSignatureInspector {

    /// CSCommon.h 中未导入 Swift 的常量：kSecCodeSignatureAdhoc、kSecCSEnforceRevocationChecks
    nonisolated static let adhocFlag: UInt32 = 0x0002
    nonisolated static let enforceRevocationChecks: UInt32 = 1 << 30

    /// 证书或公证被吊销时 Security 框架返回的错误码
    nonisolated static let revokedStatuses: Set<OSStatus> = [
        -66992,        // errSecCSRevokedNotarization
        -67820,        // errSecCertificateRevoked
        -2147409652,   // CSSMERR_TP_CERT_REVOKED
    ]

    /// 检查签名。`validateResources` 为 false 时不逐个校验包内资源文件（大应用逐个校验要几十秒），
    /// 只校验签名本身和主可执行文件。
    nonisolated static func inspect(path: String, validateResources: Bool = true) -> SignatureInfo {
        guard FileManager.default.fileExists(atPath: path) else { return SignatureInfo(validity: .unreadable) }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return SignatureInfo(validity: .unreadable)
        }

        let flags: SecCSFlags = validateResources ? [] : SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        if status == errSecCSUnsigned { return SignatureInfo(validity: .unsigned) }

        var info = SignatureInfo(validity: .valid)
        var signing: CFDictionary?
        if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
           let dict = signing as? [String: Any] {
            let codeFlags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            info.isAdhoc = codeFlags & adhocFlag != 0
            info.teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
            // 没有证书链也视为临时签名（链接器自动签名的二进制没有 adhoc 标记之外的身份）
            if dict[kSecCodeInfoCertificates as String] == nil, info.teamID == nil { info.isAdhoc = true }
        }

        if status != errSecSuccess {
            info.validity = revokedStatuses.contains(status) ? .revoked : .invalid(status)
            return info
        }
        guard !info.isAdhoc else { return info }

        info.isApple = satisfies(code, "anchor apple", flags: flags)
        if !info.isApple {
            info.isAppStore = satisfies(code, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists", flags: flags)
            info.isNotarized = info.isAppStore || satisfies(code, "notarized", flags: flags)
        }
        return info
    }

    nonisolated static func satisfies(_ code: SecStaticCode, _ requirementText: String, flags: SecCSFlags) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// 联网检查证书与公证是否被吊销。true = 已吊销，false = 未吊销，nil = 没有结论（离线、超时等）。
    nonisolated static func isRevoked(path: String) -> Bool? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        let flags = SecCSFlags(rawValue: enforceRevocationChecks | kSecCSDoNotValidateResources)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        if status == errSecSuccess { return false }
        return revokedStatuses.contains(status) ? true : nil
    }

    /// 批量吊销检查：并发执行，整体超过 `timeout` 秒就放弃剩余结果（离线时 OCSP 可能长时间挂起）。
    /// 返回已得出结论的路径 → 是否吊销；`completed` 为 false 表示有检查没在时限内完成。
    nonisolated static func revocationStatuses(paths: [String], timeout: TimeInterval = 25) -> (results: [String: Bool], completed: Bool) {
        guard !paths.isEmpty else { return ([:], true) }
        let lock = NSLock()
        var results: [String: Bool] = [:]
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "macclean.security.revocation", qos: .utility, attributes: .concurrent)
        let limiter = DispatchSemaphore(value: 4)
        for path in paths {
            group.enter()
            queue.async {
                limiter.wait()
                defer { limiter.signal(); group.leave() }
                guard let revoked = isRevoked(path: path) else { return }
                lock.lock()
                results[path] = revoked
                lock.unlock()
            }
        }
        let completed = group.wait(timeout: .now() + timeout) == .success
        lock.lock()
        defer { lock.unlock() }
        return (results, completed)
    }
}
