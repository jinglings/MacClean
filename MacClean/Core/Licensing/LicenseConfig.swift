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

    // TODO(发布前): 换成真实的购买页（LemonSqueezy checkout / 面包多商品页）
    static let purchaseURL = URL(string: "https://macclean.app/buy")!

    // TODO(发布前): 填入 LemonSqueezy store/product id（Dashboard → Settings → Stores / Products）。
    // 为 0 时跳过校验；填入后会拒绝其它店铺/商品签发的许可证。
    static let lemonSqueezyStoreID = 0
    static let lemonSqueezyProductID = 0

    // TODO(发布前): 定价文案，与购买页保持一致
    static let pricingHeadline = String(localized: "一次购买，终身使用")
    static let pricingDetail = String(localized: "也可选择年度订阅 · 含后续版本更新")
}
