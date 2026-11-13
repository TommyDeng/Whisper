#!/bin/bash
# 耳语 Whisper Linux deb 安装包。须先运行：flutter build linux --release
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
VERSION="$(./packaging/version.sh)"
ARCH=amd64
PKG_NAME=whisper
STAGING="$ROOT/packaging/linux/build/${PKG_NAME}-${VERSION}"
BUNDLE="$ROOT/build/linux/x64/release/bundle"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT}"
OUT="$OUTPUT_DIR/whisper_${VERSION}_${ARCH}.deb"

echo "=== Building whisper ${VERSION} deb package ==="

if [ ! -x "$BUNDLE/whisper" ]; then
  echo "ERROR: 找不到 $BUNDLE/whisper。请先运行：flutter build linux --release" >&2
  exit 1
fi

rm -rf "$STAGING"
mkdir -p "$STAGING/opt/whisper"
mkdir -p "$STAGING/usr/bin"
mkdir -p "$STAGING/usr/share/applications"
mkdir -p "$STAGING/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$STAGING/DEBIAN"

cp -a "$BUNDLE/." "$STAGING/opt/whisper/"
chmod +x "$STAGING/opt/whisper/whisper"

cat > "$STAGING/usr/bin/whisper" << 'WRAP'
#!/bin/sh
exec /opt/whisper/whisper "$@"
WRAP
chmod +x "$STAGING/usr/bin/whisper"

# 只装一个启动器，文件名必须等于 application-id（linux/CMakeLists.txt 的
# APPLICATION_ID）：桌面环境靠它把窗口和 Dock 右键动作对上。装两个同名启动器
# 会在应用列表里出现两个图标；旧包留下的 whisper.desktop 升级时由 dpkg 删除。
cp "$ROOT/packaging/linux/whisper.desktop" \
  "$STAGING/usr/share/applications/org.tommydeng.whisper.desktop"

cp "$ROOT/packaging/linux/icons/whisper.png" \
  "$STAGING/usr/share/icons/hicolor/256x256/apps/whisper.png"

sed "s/@VERSION@/${VERSION}/" "$ROOT/packaging/linux/debian/DEBIAN/control" \
  > "$STAGING/DEBIAN/control"

mkdir -p "$OUTPUT_DIR"
rm -f "$OUT"
dpkg-deb --root-owner-group --build "$STAGING" "$OUT"

echo "=== Deb package built: $OUT ==="
