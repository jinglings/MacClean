//
//  LicenseTests.swift
//  MacCleanTests
//
//  许可证：试用天数、离线宽限、LemonSqueezy 响应解析与错误映射、密钥脱敏、管理器流程。
//  不联网、不碰真实钥匙串（内存存储 + 模拟后端）。
//

import Foundation
import Testing
@testable import MacClean

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

// MARK: - 试用期

struct LicenseTrialTests {
    @Test func fullTrialOnFirstDay() {
        #expect(LicensePolicy.trialDaysRemaining(trialStart: t0, now: t0) == 7)
        #expect(LicensePolicy.trialDaysRemaining(trialStart: t0, now: t0 + day - 1) == 7)
    }

    @Test func countsDownByWholeDays() {
        #expect(LicensePolicy.trialDaysRemaining(trialStart: t0, now: t0 + day) == 6)
        #expect(LicensePolicy.trialDaysRemaining(trialStart: t0, now: t0 + 6.5 * day) == 1)
    }

    @Test func endsAfterSevenDays() {
        #expect(LicensePolicy.trialDaysRemaining(trialStart: t0, now: t0 + 7 * day) == 0)
        #expect(LicensePolicy.trialDaysRemaining(trialStart: t0, now: t0 + 100 * day) == 0)
        #expect(LicensePolicy.resolveState(trialStart: t0, license: nil, now: t0 + 7 * day) == .expired)
        #expect(LicensePolicy.resolveState(trialStart: t0, license: nil, now: t0 + 3 * day) == .trial)
    }

    @Test func clockRollbackNeverExceedsTrialLength() {
        #expect(LicensePolicy.trialDaysRemaining(trialStart: t0, now: t0 - 10 * day) == 7)
    }

    @Test func trialEndDate() {
        #expect(LicensePolicy.trialEndDate(trialStart: t0) == t0 + 7 * day)
    }
}

// MARK: - 离线宽限

struct LicenseGraceTests {
    private func license(validatedAt date: Date) -> StoredLicense {
        StoredLicense(key: "k", instanceID: "i", planName: nil, activatedAt: date, lastValidated: date)
    }

    @Test func revalidatesWeekly() {
        #expect(!LicensePolicy.needsRevalidation(lastValidated: t0, now: t0 + 6 * day))
        #expect(LicensePolicy.needsRevalidation(lastValidated: t0, now: t0 + 7 * day))
        #expect(LicensePolicy.needsRevalidation(lastValidated: t0, now: t0 - day))
    }

    @Test func licensedWithinThirtyDaysOffline() {
        let trialStart = t0 - 365 * day
        #expect(LicensePolicy.resolveState(trialStart: trialStart, license: license(validatedAt: t0), now: t0 + 30 * day) == .licensed)
        #expect(LicensePolicy.resolveState(trialStart: trialStart, license: license(validatedAt: t0), now: t0 + 31 * day) == .expired)
    }

    @Test func graceLapseFallsBackToRemainingTrial() {
        #expect(LicensePolicy.resolveState(trialStart: t0 + 30 * day, license: license(validatedAt: t0), now: t0 + 31 * day) == .trial)
    }
}

// MARK: - 密钥脱敏

struct LicenseMaskTests {
    @Test func masksMiddle() {
        #expect(LicensePolicy.maskedKey("38b1460a-5104-4067-a91d-77b872934d51") == "38B1••••••••4D51")
        #expect(LicensePolicy.maskedKey("  abcd-efgh-ijkl \n") == "ABCD••••••••IJKL")
    }

    @Test func shortKeysRevealLittle() {
        #expect(LicensePolicy.maskedKey("abcdefgh") == "••••EFGH")
        #expect(LicensePolicy.maskedKey("abc") == "••••")
    }
}

// MARK: - LemonSqueezy 解析

struct LemonSqueezyParsingTests {
    typealias LS = LemonSqueezyLicenseBackend

    private func response(_ json: String, status: Int = 200) throws -> LS.Response {
        try LS.decode(Data(json.utf8), statusCode: status)
    }

    @Test func parsesSuccessfulActivation() throws {
        let json = """
        {"activated":true,"error":null,
         "license_key":{"id":1,"status":"active","key":"38b1460a-5104-4067-a91d-77b872934d51","activation_limit":3,"activation_usage":1,"expires_at":null},
         "instance":{"id":"47596ad9-a811-4ebf-ac8a-03fc7b6d2a17","name":"Mac14,2 · Test"},
         "meta":{"store_id":11,"order_id":2,"product_id":22,"product_name":"MacClean","variant_id":3,"variant_name":"终身版","customer_email":"a@b.c"}}
        """
        let activation = try LS.parseActivation(try response(json), statusCode: 200)
        #expect(activation == LicenseActivation(instanceID: "47596ad9-a811-4ebf-ac8a-03fc7b6d2a17", planName: "终身版", activationLimit: 3, activationUsage: 1))
    }

    @Test func defaultVariantFallsBackToProductName() throws {
        let json = """
        {"activated":true,"error":null,"license_key":{"status":"active"},"instance":{"id":"x"},
         "meta":{"store_id":1,"product_id":2,"product_name":"MacClean Pro","variant_name":"Default"}}
        """
        #expect(try LS.parseActivation(try response(json), statusCode: 200).planName == "MacClean Pro")
    }

    @Test func activationLimitReached() throws {
        let json = """
        {"activated":false,"error":"This license key has reached the activation limit.","license_key":{"status":"active","activation_limit":1,"activation_usage":1},"meta":{"store_id":1}}
        """
        #expect(throws: LicenseError.activationLimitReached) {
            try LS.parseActivation(try response(json, status: 400), statusCode: 400)
        }
    }

    @Test func unknownKeyIsInvalid() throws {
        let json = #"{"activated":false,"error":"license_key not found."}"#
        #expect(throws: LicenseError.invalidKey) {
            try LS.parseActivation(try response(json, status: 404), statusCode: 404)
        }
    }

    @Test func disabledAndExpiredKeys() throws {
        let disabled = #"{"activated":false,"error":"This license key is disabled.","license_key":{"status":"disabled"}}"#
        #expect(throws: LicenseError.licenseDisabled) {
            try LS.parseActivation(try response(disabled, status: 400), statusCode: 400)
        }
        let expired = #"{"activated":false,"error":"This license key has expired.","license_key":{"status":"expired"}}"#
        #expect(throws: LicenseError.licenseExpired) {
            try LS.parseActivation(try response(expired, status: 400), statusCode: 400)
        }
    }

    @Test func nonJSONResponses() {
        #expect(throws: LicenseError.server("HTTP 502")) { try LS.decode(Data("<html>".utf8), statusCode: 502) }
        #expect(throws: LicenseError.invalidResponse) { try LS.decode(Data("oops".utf8), statusCode: 200) }
    }

    @Test func productVerification() throws {
        let meta = LS.Response.Meta(storeId: 11, productId: 22, productName: nil, variantName: nil)
        try LS.verifyProduct(meta, storeID: 0, productID: 0)
        try LS.verifyProduct(meta, storeID: 11, productID: 22)
        #expect(throws: LicenseError.productMismatch) { try LS.verifyProduct(meta, storeID: 99, productID: 0) }
        #expect(throws: LicenseError.productMismatch) { try LS.verifyProduct(meta, storeID: 11, productID: 99) }
    }

    @Test func validationResults() throws {
        let valid = #"{"valid":true,"error":null,"license_key":{"status":"active"},"instance":{"id":"i"},"meta":{"store_id":11,"product_id":22,"variant_name":"年度订阅"}}"#
        #expect(try LS.parseValidation(try response(valid), statusCode: 200, storeID: 11, productID: 22) == .active(planName: "年度订阅"))
        #expect(try LS.parseValidation(try response(valid), statusCode: 200, storeID: 12, productID: 0) == .revoked(reason: "product_mismatch"))

        let refunded = #"{"valid":true,"error":null,"license_key":{"status":"disabled"},"meta":{}}"#
        #expect(try LS.parseValidation(try response(refunded), statusCode: 200, storeID: 0, productID: 0) == .revoked(reason: "disabled"))

        let missing = #"{"valid":false,"error":"instance_id not found."}"#
        #expect(try LS.parseValidation(try response(missing, status: 404), statusCode: 404, storeID: 0, productID: 0) == .revoked(reason: "instance_id not found."))

        let outage = #"{"valid":false,"error":"Server Error"}"#
        #expect(throws: LicenseError.server("Server Error")) {
            try LS.parseValidation(try response(outage, status: 500), statusCode: 500, storeID: 0, productID: 0)
        }
    }

    @Test func deactivation() throws {
        try LS.parseDeactivation(try response(#"{"deactivated":true,"error":null}"#), statusCode: 200)
        // 服务端已没有这个实例，视为成功。
        try LS.parseDeactivation(try response(#"{"deactivated":false,"error":"instance_id not found."}"#, status: 404), statusCode: 404)
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(LS.formEncode(["instance_name": "Mac14,2 · 小王", "license_key": "a+b&c"])
                == "instance_name=Mac14%2C2%20%C2%B7%20%E5%B0%8F%E7%8E%8B&license_key=a%2Bb%26c")
    }
}

// MARK: - 管理器流程

final class LicenseMockBackend: LicenseBackend, @unchecked Sendable {
    var activateResult: Result<LicenseActivation, LicenseError> = .success(LicenseActivation(instanceID: "inst-1", planName: "终身版", activationLimit: 2, activationUsage: 1))
    var validateResult: Result<RemoteLicenseStatus, LicenseError> = .success(.active(planName: nil))
    var deactivateError: LicenseError?
    var validateCalls = 0
    var deactivated: [(String, String)] = []

    func activate(key: String, instanceName: String) async throws -> LicenseActivation { try activateResult.get() }
    func validate(key: String, instanceID: String) async throws -> RemoteLicenseStatus {
        validateCalls += 1
        return try validateResult.get()
    }
    func deactivate(key: String, instanceID: String) async throws {
        if let deactivateError { throw deactivateError }
        deactivated.append((key, instanceID))
    }
}

@MainActor
struct LicenseManagerTests {
    final class Clock { var now = t0 }

    let backend = LicenseMockBackend()
    let storage = InMemoryLicenseStorage()
    let clock = Clock()
    let defaults: UserDefaults

    init() {
        let suite = "LicenseTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeManager() -> LicenseManager {
        let clock = clock
        return LicenseManager(backend: backend, storage: storage, defaults: defaults, now: { clock.now })
    }

    @Test func firstLaunchStartsTrialAndPersistsIt() {
        let manager = makeManager()
        manager.start()
        #expect(manager.status == .trial)
        #expect(manager.trialDaysRemaining == 7)
        #expect(manager.allowsProActions)
        #expect(storage.items["trial-start"] != nil)
        #expect(defaults.object(forKey: "LicenseHint.trialStart") as? Date == t0)
    }

    @Test func deletingPreferencesDoesNotResetTrial() {
        makeManager().start()
        clock.now = t0 + 8 * day
        defaults.removeObject(forKey: "LicenseHint.trialStart")
        let manager = makeManager()
        manager.start()
        #expect(manager.status == .expired)
        #expect(!manager.allowsProActions)
    }

    @Test func earlierHintWinsOverKeychain() {
        defaults.set(t0 - 10 * day, forKey: "LicenseHint.trialStart")
        let manager = makeManager()
        manager.start()
        #expect(manager.status == .expired)
    }

    @Test func activateThenDeactivate() async throws {
        let manager = makeManager()
        manager.start()
        try await manager.activate(key: "  38b1460a-5104-4067-a91d-77b872934d51 ")
        #expect(manager.status == .licensed)
        #expect(manager.maskedKey == "38B1••••••••4D51")
        #expect(manager.planName == "终身版")
        #expect(manager.licenseType == .lifetime)

        // 重启后从存储恢复
        let restarted = makeManager()
        restarted.start()
        #expect(restarted.status == .licensed)

        try await restarted.deactivate()
        #expect(backend.deactivated.first?.1 == "inst-1")
        #expect(restarted.status == .trial)
        #expect(storage.items["license"] == nil)
    }

    @Test func activationErrorsPropagate() async {
        backend.activateResult = .failure(.activationLimitReached)
        let manager = makeManager()
        manager.start()
        await #expect(throws: LicenseError.activationLimitReached) { try await manager.activate(key: "abc") }
        await #expect(throws: LicenseError.emptyKey) { try await manager.activate(key: "   ") }
        #expect(manager.status == .trial)
    }

    @Test func networkFailureKeepsLicenseDuringGrace() async throws {
        let manager = makeManager()
        manager.start()
        try await manager.activate(key: "key-123456789")
        clock.now = t0 + 20 * day
        backend.validateResult = .failure(.network("offline"))
        await manager.revalidate()
        #expect(manager.status == .licensed)
        #expect(manager.lastValidated == t0)

        clock.now = t0 + 31 * day
        await manager.revalidate()
        #expect(manager.status == .expired)
        #expect(manager.needsOnlineValidation)

        backend.validateResult = .success(.active(planName: "年度订阅"))
        await manager.revalidate()
        #expect(manager.status == .licensed)
        #expect(manager.lastValidated == t0 + 31 * day)
        #expect(manager.licenseType == .annual)
    }

    @Test func serverRevocationDropsLicense() async throws {
        let manager = makeManager()
        manager.start()
        try await manager.activate(key: "key-123456789")
        clock.now = t0 + 10 * day
        backend.validateResult = .success(.revoked(reason: "disabled"))
        await manager.revalidate()
        #expect(manager.status == .expired)
        #expect(manager.maskedKey == nil)
        #expect(manager.notice != nil)
        #expect(storage.items["license"] == nil)
    }

    @Test func deactivateFailureKeepsLicense() async throws {
        let manager = makeManager()
        manager.start()
        try await manager.activate(key: "key-123456789")
        backend.deactivateError = .network("offline")
        await #expect(throws: LicenseError.network("offline")) { try await manager.deactivate() }
        #expect(manager.status == .licensed)
    }
}
