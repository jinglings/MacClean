# Design

视觉主题：**「原生通透」(Native Clarity)** —— 跟随系统浅色/深色自动切换；侧栏 macOS 毛玻璃，内容区柔和渐变底；薄荷绿→青色品牌渐变；每个功能一枚彩色渐变图标块。2026-10 取代「石墨 + 薄荷」纯深色主题。

所有 token 在 `MacClean/Core/Theme/ThemeConstants.swift`。颜色一律用 `Color(light:dark:)` 动态色，**禁止直接写 `Color.white.opacity(...)`**——用 `AppTheme.ink(x)`（深色下为白、浅色下为黑）。

## Color

| Token | 浅色 / 深色 | 用途 |
|---|---|---|
| primaryGradient | #F7F8FA→#EEF1F4 / #1A1D23→#111317 | 内容区底（`AppBackdrop` 叠加右上角极淡品牌光晕） |
| sidebar | 毛玻璃 `.sidebar` + 55% 着色 | 侧栏 |
| surface / surfaceHover | 白 82%/100% / 白 5.5%/8.5% | 卡片 |
| surfaceBorder | 黑 7% / 白 9% | 卡片描边 |
| textPrimary / Secondary / Muted | #161A21, 68%, 50% / #F2F4F7, 72%, 50% | 文本 |
| accent | #0EA372 / #3DDC97 | 实色强调：选中、进度、数字高亮 |
| brandGradient | #10B981 → #0891B2 | 主按钮、Logo、勾选框、角标 |
| warning / danger | #D48A0C / #F0B654 ，#E04E3B / #F07A68 | 语义 |
| 功能图标渐变 | `AppTab.tileGradient` | 侧栏、页头、引导页的图标块 |

## Typography

SF Pro。页标题 22 bold（左侧配 40pt 功能图标块）/ 引导标题 22 bold / 区块 15–17 semibold / 正文 13–13.5 / 标注 11–12。数字 `.rounded` + monospacedDigit。

## Layout

- 侧栏 236pt：Logo + 分组导航（概览 / 清理 / 管理）+ 解锁按钮 + 磁盘环形卡片。
- 内容区 padding 32；卡片圆角 14（continuous），控件 9，主按钮大号 11。
- 未扫描页面：统一 `ScanIntroView` 英雄卡（大图标块 + 特性网格 + 主按钮 + 只读安全提示）；上方已有配置卡时用 `compact: true`。页头的「开始扫描」在未扫描时隐藏，避免重复按钮。

## Components

- `NeonButtonStyle`：品牌渐变 + 白字 + 顶部高光 + 同色柔和投影；hover 提亮、按下 0.98 缩放。
- `NeonOutlineButtonStyle`：surface 填充 + 描边 + 轻投影。
- `GradientIconTile`：圆角方块渐变图标（侧栏 24 / 页头 40 / 结果卡 40–42 / 英雄 84）。
- `themeCard()`：surface + 描边 + 阴影（浅色 7% / 深色 28%）。
- 勾选框：未选为 surface + 描边，选中为品牌渐变 + 白色对勾。

## Motion

150–250ms easeOut；hover 微提亮/上浮 1pt；完成态 spring(0.4, 0.8) 一次性弹入。不做常驻循环动画、粒子、星空。注意：离屏截图不渲染 `.blur`，光晕一律用 RadialGradient。

## Naming(菜单/功能命名,刻意避开 CleanMyMac 词表)

| Tab | 中文 | English |
|---|---|---|
| smart_care | 一键体检 | Checkup |
| disk_analysis | 存储地图 | Storage Map |
| cache_cleanup | 释放空间 | Reclaim |
| developer_tools | 开发缓存 | Dev Caches |
| app_uninstaller | 应用管家 | App Manager |

内部分组:系统缓存 / 二进制冗余 / Xcode 构建产物。
