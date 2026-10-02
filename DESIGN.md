# Design

视觉主题：**原生工具（Native Utility）**。2026-10 按用户确认的蓝色版设计稿统一应用：白色工作区、浅蓝灰侧栏、系统蓝交互、少量彩色功能符号。支持系统浅色和深色，不使用背景光晕、渐变按钮或彩色图标底块。

所有 token 在 `MacClean/Core/Theme/ThemeConstants.swift`。用 `Color(light:dark:)` 或 `AppTheme.ink(x)` 适配外观，不硬编码浅色页面专用的白色透明层。

## Color

| Token | 浅色 / 深色 | 用途 |
|---|---|---|
| primaryGradient（兼容名称） | #FFFFFF / #1E1E20，两个端点相同 | 纯色工作区 |
| sidebar | 浅蓝灰 #EAF0F7 着色 + 系统 sidebar 材质 | 导航背景 |
| accent | #007AFF / #0A84FF | 选中、勾选、进度、主按钮 |
| accentSoft | 系统蓝低透明度 | 内容行选中态 |
| surface / surfaceHover | 白色 / 淡蓝灰；深色下低透明白 | 分组、悬停 |
| surfaceBorder / divider | 中性细线 | 区域边界、行分隔 |
| mint / teal / sky / amber / violet | 动态绿、青、蓝、橙、紫 | 小型功能符号与分类，不能替代统一的交互蓝色 |
| warning / danger | 动态橙 / 红 | 警告与危险操作 |

## Typography

SF Pro / 系统中文字体。页标题 19 semibold，引导标题 20 semibold，区块 15–17，正文 13，辅助 11–12。容量数字使用 monospacedDigit，不使用巨型数字英雄区。

## Layout

- 侧栏 216pt，28pt 导航行。选中项系统蓝底白字；普通项彩色线性符号与深色文字。
- 侧栏底部显示磁盘名称、细用量条和可用/总容量，不使用圆环卡片。
- 页头带底部分隔线，内容水平间距 24pt。
- 分组圆角 8pt、按钮 6pt。分组使用细描边，不加浮起阴影。
- 文件与会话使用连续列表，避免一行一个大卡片。聊天会话信息按钮打开详情栏；详情浏览独立于删除勾选。
- 扫描前显示简洁符号、说明、功能要点和一个扫描按钮，取消光晕与多层英雄卡。

## Components

保留旧类型名以兼容现有页面，其视觉已经更新：

- `NeonButtonStyle`：实色系统蓝（危险操作保留语义色），30/36pt 高，无光晕。
- `NeonOutlineButtonStyle`：中性填充、细描边，30/32pt 级别尺寸。
- `GradientIconTile`：彩色 SF Symbol，无底块、无阴影；旧 gradient 参数仅保留接口兼容。
- `themeCard()`：8pt 分组边框，无投影。
- `PageHeader`：小型功能符号、紧凑标题和操作按钮。
- `ScanIntroView`：简洁扫描说明，不做营销式卡片墙。

## Motion & Safety

短时 hover/状态过渡，不做常驻动画。保留确认、风险提示、运行中保护、权限提示、清理记录与撤销。普通文件移入废纸篓；不把 Docker prune 或删除本地快照描述成可撤销。

## Naming

保留现有功能名：一键体检、存储地图、释放空间、聊天清理、开发缓存、应用管家等。视觉重构不改扫描与清理规则。
