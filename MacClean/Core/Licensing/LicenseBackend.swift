//
//  LicenseBackend.swift
//  MacClean
//
//  许可证服务端抽象。目前实现 LemonSqueezy License API；
//  国内渠道（面包多 / 爱发电 webhook 签发的 key）将来再实现一个 LicenseBackend 即可。
//

import Foundation

// MARK: - 数据类型

/// 激活成功后服务端返回的信息。
nonisolated struct LicenseActivation: Equatable, Sendable {
    let instanceID: String
    /// 套餐名（LemonSqueezy 的 variant_name，例如「终身版」「年度订阅」）。
    let planName: String?
    let activationLimit: Int?
    let activationUsage: Int?
}

/// 联网校验的结果。网络失败不在这里表达，而是抛 `LicenseError.network`。
nonisolated enum RemoteLicenseStatus: Equatable, Sendable {
    case active(planName: String?)
    /// 服务端明确表示不可用：已停用（含退款）、已过期、key/实例不存在、商品不匹配。
    case revoked(reason: String)
}

nonisolated enum LicenseError: LocalizedError, Equatable, Sendable {
    case emptyKey
    case invalidKey
    case activationLimitReached
    case licenseDisabled
    case licenseExpired
    case productMismatch
    case notActivated
    case network(String)
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .emptyKey: return String(localized: "请输入许可证密钥")
        case .invalidKey: return String(localized: "许可证密钥无效，请检查是否完整复制")
        case .activationLimitReached: return String(localized: "该许可证的激活设备数已达上限，请先在其它 Mac 上停用")
        case .licenseDisabled: return String(localized: "该许可证已被停用")
        case .licenseExpired: return String(localized: "该许可证已过期")
        case .productMismatch: return String(localized: "该许可证不属于 MacClean")
        case .notActivated: return String(localized: "此 Mac 尚未激活许可证")
        case .network(let detail): return String(localized: "无法连接授权服务器：\(detail)")
        case .server(let detail): return String(localized: "授权服务器返回错误：\(detail)")
        case .invalidResponse: return String(localized: "授权服务器响应异常，请稍后再试")
        }
    }

    /// 服务端明确拒绝（而非网络问题）的错误；校验时遇到这些要撤销本地授权。
    var isDefinitiveRejection: Bool {
        switch self {
        case .invalidKey, .licenseDisabled, .licenseExpired, .productMismatch: return true
        default: return false
        }
    }
}

// MARK: - 协议

nonisolated protocol LicenseBackend: Sendable {
    func activate(key: String, instanceName: String) async throws -> LicenseActivation
    func validate(key: String, instanceID: String) async throws -> RemoteLicenseStatus
    func deactivate(key: String, instanceID: String) async throws
}

// MARK: - LemonSqueezy

/// https://docs.lemonsqueezy.com/api/license-api
nonisolated struct LemonSqueezyLicenseBackend: LicenseBackend {
    var baseURL = URL(string: "https://api.lemonsqueezy.com/v1/licenses/")!
    var session: URLSession = .shared
    var expectedStoreID = LicenseConfig.lemonSqueezyStoreID
    var expectedProductID = LicenseConfig.lemonSqueezyProductID

    func activate(key: String, instanceName: String) async throws -> LicenseActivation {
        let (data, code) = try await post("activate", ["license_key": key, "instance_name": instanceName])
        let response = try Self.decode(data, statusCode: code)
        let activation = try Self.parseActivation(response, statusCode: code)
        do {
            try Self.verifyProduct(response.meta, storeID: expectedStoreID, productID: expectedProductID)
        } catch {
            // 别的商品的 key 也占用了一个激活名额，尽量退回去。
            try? await deactivate(key: key, instanceID: activation.instanceID)
            throw error
        }
        return activation
    }

    func validate(key: String, instanceID: String) async throws -> RemoteLicenseStatus {
        let (data, code) = try await post("validate", ["license_key": key, "instance_id": instanceID])
        let response = try Self.decode(data, statusCode: code)
        return try Self.parseValidation(response, statusCode: code, storeID: expectedStoreID, productID: expectedProductID)
    }

    func deactivate(key: String, instanceID: String) async throws {
        let (data, code) = try await post("deactivate", ["license_key": key, "instance_id": instanceID])
        let response = try Self.decode(data, statusCode: code)
        try Self.parseDeactivation(response, statusCode: code)
    }

    private func post(_ endpoint: String, _ params: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(params).data(using: .utf8)
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError {
            throw LicenseError.network(error.localizedDescription)
        }
    }

    // MARK: 纯解析（便于单元测试）

    struct Response: Decodable {
        struct Key: Decodable {
            let status: String?
            let activationLimit: Int?
            let activationUsage: Int?
        }
        struct Instance: Decodable {
            let id: String
        }
        struct Meta: Decodable {
            let storeId: Int?
            let productId: Int?
            let productName: String?
            let variantName: String?
        }
        let activated: Bool?
        let valid: Bool?
        let deactivated: Bool?
        let error: String?
        let licenseKey: Key?
        let instance: Instance?
        let meta: Meta?
    }

    static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    static func decode(_ data: Data, statusCode: Int) throws -> Response {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            if statusCode >= 500 { throw LicenseError.server("HTTP \(statusCode)") }
            throw LicenseError.invalidResponse
        }
    }

    static func parseActivation(_ response: Response, statusCode: Int) throws -> LicenseActivation {
        guard response.activated == true, let instance = response.instance else {
            throw mapError(message: response.error, statusCode: statusCode, keyStatus: response.licenseKey?.status)
        }
        return LicenseActivation(
            instanceID: instance.id,
            planName: planName(response.meta),
            activationLimit: response.licenseKey?.activationLimit,
            activationUsage: response.licenseKey?.activationUsage
        )
    }

    static func parseValidation(_ response: Response, statusCode: Int, storeID: Int, productID: Int) throws -> RemoteLicenseStatus {
        if statusCode >= 500 { throw LicenseError.server(response.error ?? "HTTP \(statusCode)") }
        guard response.valid == true else {
            return .revoked(reason: response.error ?? response.licenseKey?.status ?? "invalid")
        }
        if let status = response.licenseKey?.status, status == "disabled" || status == "expired" {
            return .revoked(reason: status)
        }
        do {
            try verifyProduct(response.meta, storeID: storeID, productID: productID)
        } catch {
            return .revoked(reason: "product_mismatch")
        }
        return .active(planName: planName(response.meta))
    }

    static func parseDeactivation(_ response: Response, statusCode: Int) throws {
        if response.deactivated == true { return }
        let error = mapError(message: response.error, statusCode: statusCode, keyStatus: response.licenseKey?.status)
        // 服务端已经没有这个实例/key 了，对本机来说等同于停用成功。
        if error == .invalidKey { return }
        throw error
    }

    static func verifyProduct(_ meta: Response.Meta?, storeID: Int, productID: Int) throws {
        if storeID != 0, meta?.storeId != storeID { throw LicenseError.productMismatch }
        if productID != 0, meta?.productId != productID { throw LicenseError.productMismatch }
    }

    static func mapError(message: String?, statusCode: Int, keyStatus: String?) -> LicenseError {
        let lowered = (message ?? "").lowercased()
        if lowered.contains("activation limit") { return .activationLimitReached }
        if keyStatus == "disabled" || lowered.contains("disabled") { return .licenseDisabled }
        if keyStatus == "expired" || lowered.contains("expired") { return .licenseExpired }
        if statusCode == 404 || lowered.contains("not found") { return .invalidKey }
        if statusCode >= 500 { return .server(message ?? "HTTP \(statusCode)") }
        if let message, !message.isEmpty { return .server(message) }
        return .invalidResponse
    }

    private static func planName(_ meta: Response.Meta?) -> String? {
        let name = meta?.variantName?.trimmingCharacters(in: .whitespaces)
        // LemonSqueezy 单规格商品的 variant_name 是 "Default"，此时用商品名更有意义。
        if let name, !name.isEmpty, name.lowercased() != "default" { return name }
        return meta?.productName
    }
}
