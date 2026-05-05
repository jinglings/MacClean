//
//  CoolSidebarView.swift
//  MacClean
//
//  Sidebar matching the supplied MacAura reference.
//

import SwiftUI

struct CoolSidebarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedTab: AppTab
    
    private struct NavEntry: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let tab: AppTab?
        let badge: Int?
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            trafficLights
                .padding(.top, 18)
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
            
            VStack(spacing: 14) {
                ForEach(primaryEntries) { entry in
                    sidebarRow(entry)
                }
            }
            .padding(.horizontal, 18)
            
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
                .padding(.horizontal, 26)
                .padding(.vertical, 28)
            
            sidebarRow(NavEntry(title: "Assistant", icon: "cpu", tab: nil, badge: nil))
                .padding(.horizontal, 18)
            
            Spacer()
            
            deviceCard
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
        }
        .frame(width: CosmicSizes.sidebarWidth)
        .background(CosmicTheme.sidebarGradient)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1)
        }
    }
    
    private var primaryEntries: [NavEntry] {
        [
            NavEntry(title: "空间透镜", icon: "magnifyingglass.circle.fill", tab: .diskAnalysis, badge: nil),
            NavEntry(title: "Cleanup", icon: "externaldrive", tab: .cacheCleanup, badge: badgeCount(for: .cacheCleanup)),
            NavEntry(title: "Protection", icon: "shield", tab: nil, badge: nil),
            NavEntry(title: "Performance", icon: "bolt", tab: .developerTools, badge: badgeCount(for: .developerTools)),
            NavEntry(title: "Applications", icon: "square.grid.2x2", tab: .appUninstaller, badge: nil),
            NavEntry(title: "Duplicates", icon: "doc.on.doc", tab: nil, badge: nil)
        ]
    }
    
    private var trafficLights: some View {
        HStack(spacing: 9) {
            Circle().fill(Color(hex: 0xFF605C)).frame(width: 14, height: 14)
            Circle().fill(Color(hex: 0xFFBD44)).frame(width: 14, height: 14)
            Circle().fill(Color(hex: 0x00CA4E)).frame(width: 14, height: 14)
        }
    }
    
    private func sidebarRow(_ entry: NavEntry) -> some View {
        let isSelected = entry.tab == selectedTab
        
        return Button {
            guard let tab = entry.tab else { return }
            withAnimation(CosmicAnimations.springy) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isSelected ? CosmicTheme.accentGradient : LinearGradient(colors: [Color.clear], startPoint: .top, endPoint: .bottom))
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 42, height: 42)
                    
                    Image(systemName: entry.icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(isSelected ? .white : Color.white.opacity(entry.tab == nil ? 0.54 : 0.86))
                }
                
                Text(entry.title)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .white : Color.white.opacity(entry.tab == nil ? 0.56 : 0.88))
                
                Spacer()
                
                if let badge = entry.badge {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(CosmicTheme.accentPink))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.white.opacity(0.13) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isSelected ? Color.white.opacity(0.24) : Color.clear, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
    
    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 26))
                    .foregroundColor(Color.white.opacity(0.86))
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacBook Air")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text("M2, 8-Core CPU")
                        .font(.system(size: 13))
                        .foregroundColor(CosmicTheme.textMuted)
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(diskUsageText)
                        .font(.system(size: 12))
                        .foregroundColor(CosmicTheme.textMuted)
                    Spacer()
                    Text("\(diskPercent)%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(CosmicTheme.textSecondary)
                }
                
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.13))
                        Capsule()
                            .fill(LinearGradient(colors: [CosmicTheme.accentPink, CosmicTheme.accentPurple], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, proxy.size.width * CGFloat(Double(diskPercent) / 100.0)))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }
    
    private var diskPercent: Int {
        guard let diskInfo = appState.diskInfo else { return 89 }
        return Int(diskInfo.usedPercentage * 100)
    }
    
    private var diskUsageText: String {
        guard let diskInfo = appState.diskInfo else { return "228 GB of 256 GB used" }
        let used = ByteCountFormatter.string(fromByteCount: diskInfo.usedSpace, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: diskInfo.totalSpace, countStyle: .file)
        return "\(used) of \(total) used"
    }
    
    private func badgeCount(for tab: AppTab) -> Int? {
        switch tab {
        case .cacheCleanup:
            let count = appState.cleanableItems.filter {
                $0.category == .userCache || $0.category == .browserCache
            }.count
            return count > 0 ? count : nil
        case .developerTools:
            let count = appState.cleanableItems.filter {
                $0.category == .developerTools
            }.count
            return count > 0 ? count : nil
        default:
            return nil
        }
    }
}
