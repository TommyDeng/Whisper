#!/bin/bash
# 耳语 Whisper Linux deb 安装包构建脚本
set -e

VERSION=1.0.0
ARCH=amd64
PKG_NAME=whisper
BUILD_DIR=packaging/linux/build

echo "=== Building whisper deb package ==="

# 清理旧构建
rm -rf $BUILD_DIR
mkdir -p $BUILD_DIR/$PKG_NAME-$VERSION/usr/bin
mkdir -p $BUILD_DIR/$PKG_NAME-$VERSION/usr/share/applications
mkdir -p $BUILD_DIR/$PKG_NAME-$VERSION/DEBIAN

# 复制 Flutter 构建产物
echo "Copying Flutter build artifacts..."
if [ -d "build/linux/x64/release/bundle" ]; then
    cp -r build/linux/x64/release/bundle/* $BUILD_DIR/$PKG_NAME-$VERSION/usr/bin/
    chmod +x $BUILD_DIR/$PKG_NAME-$VERSION/usr/bin/*
else
    echo "ERROR: No Flutter build output found. Run 'flutter build linux --release' first."
    exit 1
fi

# 创建桌面入口
cat > $BUILD_DIR/$PKG_NAME-$VERSION/usr/share/applications/whisper.desktop << EOF
[Desktop Entry]
Name=耳语 Whisper
Comment=端到端加密聊天与语音客户端
Exec=whisper
Icon=whisper
Terminal=false
Type=Application
Categories=Network;InstantMessaging;
EOF

# 复制 DEBIAN 控制文件
cp packaging/linux/debian/DEBIAN/control $BUILD_DIR/$PKG_NAME-$VERSION/DEBIAN/control

# 构建 deb 包
dpkg-deb --build $BUILD_DIR/$PKG_NAME-$VERSION whisper_${VERSION}_${ARCH}.deb

echo "=== Deb package built: whisper_${VERSION}_${ARCH}.deb ==="
