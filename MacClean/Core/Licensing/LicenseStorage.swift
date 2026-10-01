//
//  LicenseStorage.swift
//  MacClean
//
//  授权数据的持久化。试用起始日和许可证信息存钥匙串（删偏好设置不会重置试用），
//  测试用内存实现。
//

import Foundation
import Security

protocol LicenseStorage: AnyObject {
    func data(for account: String) -> Data?
    func set(_ data: Data?, for account: String)
}

final class KeychainLicenseStorage: LicenseStorage {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.hr.MacClean") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func data(for account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func set(_ data: Data?, for account: String) {
        let query = baseQuery(account)
        guard let data else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "MacClean License"
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
}

final class InMemoryLicenseStorage: LicenseStorage {
    private(set) var items: [String: Data] = [:]

    func data(for account: String) -> Data? { items[account] }
    func set(_ data: Data?, for account: String) { items[account] = data }
}
