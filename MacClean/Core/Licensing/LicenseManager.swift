//
//  LicenseManager.swift
//  MacClean
//
//  许可证管理器
//

import Foundation
import StoreKit
import Combine

@MainActor
class LicenseManager: ObservableObject {
    static let shared = LicenseManager()
    
    // MARK: - Published Properties
    
    @Published var isLicensed: Bool = false
    @Published var licenseType: LicenseType = .trial
    @Published var trialDaysRemaining: Int = 7
    @Published var expirationDate: Date?
    @Published var isLoading: Bool = false
    
    // MARK: - Private Properties
    
    private let trialStartDateKey = "TrialStartDate"
    private let licenseTypeKey = "LicenseType"
    private let trialDuration: Int = 7 // 7天试用期
    
    // App Store 产品 ID
    private let annualSubscriptionID = "com.macclean.subscription.annual"
    private let lifetimePurchaseID = "com.macclean.purchase.lifetime"
    
    private init() {}
    
    // MARK: - 检查许可证状态
    
    func checkLicenseStatus() {
        // 检查是否有有效的许可证
        if let storedType = UserDefaults.standard.string(forKey: licenseTypeKey),
           let type = LicenseType(rawValue: storedType) {
            
            switch type {
            case .trial:
                checkTrialStatus()
            case .annual:
                // 检查订阅状态
                checkSubscriptionStatus()
            case .lifetime:
                isLicensed = true
                licenseType = .lifetime
            }
        } else {
            // 首次运行，开始试用
            startTrial()
        }
    }
    
    // MARK: - 试用期管理
    
    private func startTrial() {
        let now = Date()
        UserDefaults.standard.set(now, forKey: trialStartDateKey)
        UserDefaults.standard.set(LicenseType.trial.rawValue, forKey: licenseTypeKey)
        
        licenseType = .trial
        trialDaysRemaining = trialDuration
        isLicensed = false
        
        expirationDate = Calendar.current.date(byAdding: .day, value: trialDuration, to: now)
    }
    
    private func checkTrialStatus() {
        guard let trialStart = UserDefaults.standard.object(forKey: trialStartDateKey) as? Date else {
            startTrial()
            return
        }
        
        let now = Date()
        let daysSinceStart = Calendar.current.dateComponents([.day], from: trialStart, to: now).day ?? 0
        
        trialDaysRemaining = max(0, trialDuration - daysSinceStart)
        isLicensed = trialDaysRemaining > 0
        licenseType = .trial
        
        expirationDate = Calendar.current.date(byAdding: .day, value: trialDuration, to: trialStart)
    }
    
    // MARK: - App Store 订阅管理
    
    private func checkSubscriptionStatus() {
        Task {
            isLoading = true
            defer { isLoading = false }
            
            // 使用 StoreKit 2 检查订阅状态
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result else { continue }
                
                if transaction.productID == annualSubscriptionID {
                    if transaction.expirationDate ?? Date() > Date() {
                        isLicensed = true
                        licenseType = .annual
                        expirationDate = transaction.expirationDate
                        return
                    }
                } else if transaction.productID == lifetimePurchaseID {
                    isLicensed = true
                    licenseType = .lifetime
                    expirationDate = nil
                    return
                }
            }
            
            // 没有有效订阅，回退到试用
            checkTrialStatus()
        }
    }
    
    // MARK: - 购买产品
    
    func purchase(_ productID: String) async throws {
        isLoading = true
        defer { isLoading = false }
        
        // 获取产品
        let products = try await Product.products(for: [productID])
        guard let product = products.first else {
            throw LicenseError.productNotFound
        }
        
        // 发起购买
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                // 购买成功
                await transaction.finish()
                
                if productID == lifetimePurchaseID {
                    licenseType = .lifetime
                    isLicensed = true
                    UserDefaults.standard.set(LicenseType.lifetime.rawValue, forKey: licenseTypeKey)
                } else if productID == annualSubscriptionID {
                    licenseType = .annual
                    isLicensed = true
                    expirationDate = transaction.expirationDate
                    UserDefaults.standard.set(LicenseType.annual.rawValue, forKey: licenseTypeKey)
                }
                
            case .unverified:
                throw LicenseError.verificationFailed
            }
            
        case .userCancelled:
            throw LicenseError.userCancelled
            
        case .pending:
            throw LicenseError.purchasePending
            
        @unknown default:
            throw LicenseError.unknown
        }
    }
    
    // MARK: - 恢复购买
    
    func restorePurchases() async throws {
        isLoading = true
        defer { isLoading = false }
        
        try await AppStore.sync()
        checkSubscriptionStatus()
    }
    
    // MARK: - 获取产品信息
    
    func getProducts() async throws -> [Product] {
        try await Product.products(for: [annualSubscriptionID, lifetimePurchaseID])
    }
}

// MARK: - 许可证错误

enum LicenseError: LocalizedError {
    case productNotFound
    case verificationFailed
    case userCancelled
    case purchasePending
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return NSLocalizedString("license_error_product_not_found", comment: "")
        case .verificationFailed:
            return NSLocalizedString("license_error_verification_failed", comment: "")
        case .userCancelled:
            return NSLocalizedString("license_error_user_cancelled", comment: "")
        case .purchasePending:
            return NSLocalizedString("license_error_purchase_pending", comment: "")
        case .unknown:
            return NSLocalizedString("license_error_unknown", comment: "")
        }
    }
}
