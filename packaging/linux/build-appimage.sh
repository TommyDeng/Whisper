#!/bin/bash
# 耳语 Whisper Linux AppImage 构建脚本
set -e

VERSION=1.0.0
ARCH=x86_64
PKG_NAME=whisper
BUILD_DIR=packaging/linux/build

echo "=== Building whisper AppImage ==="

# 清理旧构建
rm -rf $BUILD_DIR
mkdir -p $BUILD_DIR/$PKG_NAME.AppDir/usr/bin
mkdir -p $BUILD_DIR/$PKG_NAME.AppDir/usr/share/applications
mkdir -p $BUILD_DIR/$PKG_NAME.AppDir/usr/share/icons/hicolor/256x256/apps

# 复制 Flutter 构建产物
if [ -d "build/linux/x64/release/bundle" ]; then
    cp -r build/linux/x64/release/bundle/* $BUILD_DIR/$PKG_NAME.AppDir/usr/bin/
    chmod +x $BUILD_DIR/$PKG_NAME.AppDir/usr/bin/*
else
    echo "ERROR: No Flutter build output found. Run 'flutter build linux --release' first."
    exit 1
fi

# 创建 AppRun 入口脚本
cat > $BUILD_DIR/$PKG_NAME.AppDir/AppRun << 'APPRUN'
#!/bin/bash
cd "$(dirname "$0")"
exec ./usr/bin/whisper "$@"
APPRUN
chmod +x $BUILD_DIR/$PKG_NAME.AppDir/AppRun

# 创建桌面入口
cat > $BUILD_DIR/$PKG_NAME.AppDir/usr/share/applications/whisper.desktop << EOF
[Desktop Entry]
Name=耳语 Whisper
Comment=端到端加密聊天与语音客户端
Exec=whisper
Icon=whisper
Terminal=false
Type=Application
Categories=Network;InstantMessaging;
EOF

# 下载 appimagetool (如果不存在)
if [ ! -f "appimagetool-x86_64.AppImage" ]; then
    echo "Downloading appimagetool..."
    wget -c "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x appimagetool-x86_64.AppImage
fi

# 构建 AppImage
./appimagetool-x86_64.AppImage $BUILD_DIR/$PKG_NAME.AppDir whisper-${VERSION}-x86_64.AppImage

echo "=== AppImage built: whisper-${VERSION}-x86_64.AppImage ==="
