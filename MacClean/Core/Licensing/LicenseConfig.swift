//
//  LicenseConfig.swift
//  MacClean
//
//  授权相关的可配置常量。发布前需要逐项确认带 TODO 的值。
//

import Foundation

nonisolated enum LicenseConfig {
    /// 试用天数（从首次启动算起）。
    static let trialDays = 7
    /// 距上次成功校验超过这个天数才在启动时重新联网校验。
    static let revalidateIntervalDays = 7
    /// 联网校验失败（断网等）时，距上次成功校验多少天内仍视为已授权。
    static let offlineGraceDays = 30

    /// 官网购买页（个人收款码下单，后台确认后发放许可证）。为 nil 时「购买许可证」按钮置灰。
    static let purchaseURL: URL? = URL(string: "https://thulem.com/buy.html")

    /// 自建授权服务器（thulem.com，接口与 LemonSqueezy License API 兼容）。
    static let licenseAPIBaseURL = URL(string: "https://thulem.com/api/licenses/")!

    /// 授权服务器签发的 store/product id；填入后会拒绝其它商品的许可证。
    static let lemonSqueezyStoreID = 1
    static let lemonSqueezyProductID = 1

    /// 定价文案，与官网购买页保持一致（价格以官网为准）
    static let pricingHeadline = String(localized: "一次购买，终身使用")
    static let pricingDetail = String(localized: "终身版 2 台 Mac · 家庭版 5 台 Mac · 含后续版本更新")
}
