//
//  SettingsView.swift
//  MacClean
//
//  设置视图
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("general", systemImage: "gear")
                }
            
            AppearanceSettingsView()
                .tabItem {
                    Label("appearance", systemImage: "paintbrush")
                }
            
            LicenseSettingsView()
                .tabItem {
                    Label("license_trial", systemImage: "key")
                }
            
            AboutSettingsView()
                .tabItem {
                    Label("about", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 350)
    }
}

// MARK: - 通用设置
struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    
    var body: some View {
        Form {
            Section {
                Toggle("launch_at_login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                
                Toggle("show_in_menu_bar", isOn: $showInMenuBar)
                
                Toggle("check_for_updates", isOn: $autoCheckUpdates)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("设置登录项失败: \(error)")
        }
    }
}

// MARK: - 外观设置
struct AppearanceSettingsView: View {
    @AppStorage("selectedTheme") private var selectedTheme = 0
    @AppStorage("selectedLanguage") private var selectedLanguage = "system"
    
    let themes = ["System", "Light", "Dark"]
    let languages = [
        ("system", "System"),
        ("en", "English"),
        ("zh-Hans", "简体中文")
    ]
    
    var body: some View {
        Form {
            Section {
                Picker("appearance", selection: $selectedTheme) {
                    ForEach(0..<themes.count, id: \.self) { index in
                        Text(themes[index]).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                
                Picker("language", selection: $selectedLanguage) {
                    ForEach(languages, id: \.0) { language in
                        Text(language.1).tag(language.0)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 许可证设置
struct LicenseSettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var licenseManager = LicenseManager.shared
    
    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text(licenseManager.licenseType.localizedName)
                            .font(.headline)
                        
                        if licenseManager.licenseType == .trial {
                            Text(String(format: NSLocalizedString("trial_days_remaining", comment: ""), licenseManager.trialDaysRemaining))
                                .font(.subheadline)
                                .foregroundColor(.orange)
                        } else if let expDate = licenseManager.expirationDate {
                            Text("Expires: \(expDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    if licenseManager.isLicensed && licenseManager.licenseType != .trial {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title)
                            .foregroundColor(.green)
                    }
                }
                
                if !licenseManager.isLicensed || licenseManager.licenseType == .trial {
                    Button("activate_license") {
                        appState.showLicenseActivation = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Button("restore_purchases") {
                    Task {
                        try? await licenseManager.restorePurchases()
                    }
                }
                .disabled(licenseManager.isLoading)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 关于设置
struct AboutSettingsView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            
            Text("MacClean")
                .font(.title.bold())
            
            Text("Mac 磁盘清理工具")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack(spacing: 20) {
                VStack {
                    Text("version")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(appVersion)
                        .font(.headline)
                }
                
                VStack {
                    Text("build")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(buildNumber)
                        .font(.headline)
                }
            }
            
            Divider()
            
            Text("© 2026 MacClean. All rights reserved.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                Link("Website", destination: URL(string: "https://macclean.app")!)
                Text("•")
                Link("Privacy Policy", destination: URL(string: "https://macclean.app/privacy")!)
                Text("•")
                Link("Support", destination: URL(string: "https://macclean.app/support")!)
            }
            .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
}
