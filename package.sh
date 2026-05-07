#!/bin/bash
set -euo pipefail

# 编译
make clean
make

# 创建临时目录结构
rm -rf package_temp
mkdir -p package_temp/DEBIAN
mkdir -p package_temp/var/jb/Library/MobileSubstrate/DynamicLibraries

# 创建 packages 目录
mkdir -p packages

# 复制 control 文件
cp control package_temp/DEBIAN/

# 复制 dylib 文件
cp .theos/obj/debug/arm64/lanxincrack.dylib package_temp/var/jb/Library/MobileSubstrate/DynamicLibraries/

# 复制 plist 文件（重命名为 lanxincrack.plist）
cp lanxincrack.plist package_temp/var/jb/Library/MobileSubstrate/DynamicLibraries/lanxincrack.plist

# 创建 lanxincrack.dylib.i64 文件（64位标识）
touch package_temp/var/jb/Library/MobileSubstrate/DynamicLibraries/lanxincrack.dylib.i64

# 设置权限
chmod 755 package_temp/DEBIAN
chmod 644 package_temp/DEBIAN/control
chmod 644 package_temp/var/jb/Library/MobileSubstrate/DynamicLibraries/lanxincrack.dylib
chmod 644 package_temp/var/jb/Library/MobileSubstrate/DynamicLibraries/lanxincrack.plist
chmod 644 package_temp/var/jb/Library/MobileSubstrate/DynamicLibraries/lanxincrack.dylib.i64

# 打包 deb
dpkg-deb -Zgzip -b package_temp packages/com.lanxin.crack_0.0.1-1_iphoneos-arm64.deb

# 清理临时目录
rm -rf package_temp

echo "Package created successfully: packages/com.lanxin.crack_0.0.1-1_iphoneos-arm64.deb"
