#!/bin/bash
set -euo pipefail

BUILD_ID="$(date +%Y%m%d%H%M%S)"
PKG_VERSION="0.0.3+${BUILD_ID}"
DEB_PATH="packages/com.lanxin.crack_${PKG_VERSION}_iphoneos-arm64.deb"

echo "BUILD_ID=${BUILD_ID}"
echo "PKG_VERSION=${PKG_VERSION}"

# 编译
make clean
make ADDITIONAL_CFLAGS="-DLX_BUILD_ID=@\\\"${BUILD_ID}\\\""

# 创建临时目录结构
rm -rf package_temp
mkdir -p package_temp/DEBIAN
mkdir -p package_temp/var/jb/Library/MobileSubstrate/DynamicLibraries

# 创建 packages 目录
mkdir -p packages

# 复制 control 文件
awk -v v="${PKG_VERSION}" '
BEGIN { done = 0 }
/^Version:[[:space:]]*/ { print "Version: " v; done = 1; next }
{ print }
END { if (!done) print "Version: " v }
' control > package_temp/DEBIAN/control

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
dpkg-deb -Zgzip -b package_temp "${DEB_PATH}"

# 清理临时目录
rm -rf package_temp

echo "Package created successfully: ${DEB_PATH}"
