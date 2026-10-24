#!/bin/bash

# MacClean 项目设置脚本
# 用法: 
# 1. 先用 Xcode 创建一个新的 macOS SwiftUI App 项目，命名为 MacClean
# 2. 运行此脚本：bash setup_project.sh <新项目路径>

NEW_PROJECT_PATH="$1"
SOURCE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/MacClean"

if [ -z "$NEW_PROJECT_PATH" ]; then
    echo "用法: bash setup_project.sh <Xcode项目路径>"
    echo "示例: bash setup_project.sh ~/Desktop/MacClean"
    exit 1
fi

if [ ! -d "$NEW_PROJECT_PATH" ]; then
    echo "错误: 项目路径不存在: $NEW_PROJECT_PATH"
    exit 1
fi

TARGET_PATH="$NEW_PROJECT_PATH/MacClean"

echo "📦 开始设置 MacClean 项目..."

# 备份原始文件
echo "📁 备份原始文件..."
if [ -d "$TARGET_PATH" ]; then
    mv "$TARGET_PATH" "${TARGET_PATH}_backup_$(date +%Y%m%d_%H%M%S)"
fi

# 复制源代码
echo "📋 复制源代码..."
cp -r "$SOURCE_PATH" "$TARGET_PATH"

# 复制配置文件
echo "⚙️ 复制配置文件..."
# Info.plist 和 entitlements 已经在 MacClean 目录中

echo ""
echo "✅ 设置完成！"
echo ""
echo "下一步操作："
echo "1. 在 Xcode 中打开: $NEW_PROJECT_PATH/MacClean.xcodeproj"
echo "2. 删除旧的文件引用，添加新的 MacClean 目录"
echo "3. 在 Build Settings 中配置:"
echo "   - INFOPLIST_FILE = MacClean/Info.plist"
echo "   - CODE_SIGN_ENTITLEMENTS = MacClean/MacClean.entitlements"
echo "4. 按 ⌘R 运行项目"
