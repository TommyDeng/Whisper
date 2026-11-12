#!/bin/bash
# 耳语 Whisper Linux AppImage。须先运行：flutter build linux --release
# appimagetool 按校验和固定在 1.9.1；首次运行会下载到 packaging/linux/tools/。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
VERSION="$(./packaging/version.sh)"
ARCH=x86_64
PKG_NAME=whisper
APPDIR="$ROOT/packaging/linux/build/${PKG_NAME}.AppDir"
BUNDLE="$ROOT/build/linux/x64/release/bundle"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT}"
OUT="$OUTPUT_DIR/whisper-${VERSION}-${ARCH}.AppImage"

APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage"
APPIMAGETOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
TOOL_DIR="$ROOT/packaging/linux/tools"
TOOL="$TOOL_DIR/appimagetool-x86_64.AppImage"

echo "=== Building whisper ${VERSION} AppImage ==="

if [ ! -x "$BUNDLE/whisper" ]; then
  echo "ERROR: 找不到 $BUNDLE/whisper。请先运行：flutter build linux --release" >&2
  exit 1
fi

mkdir -p "$TOOL_DIR"
if [ ! -f "$TOOL" ]; then
  echo "Downloading appimagetool 1.9.1..."
  curl -L --fail --retry 3 -o "$TOOL.partial" "$APPIMAGETOOL_URL"
  mv "$TOOL.partial" "$TOOL"
fi
actual="$(sha256sum "$TOOL" | awk '{print $1}')"
if [ "$actual" != "$APPIMAGETOOL_SHA256" ]; then
  echo "ERROR: appimagetool 校验和不匹配" >&2
  rm -f "$TOOL"
  exit 1
fi
chmod +x "$TOOL"

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/share/applications"
mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps"

cp -a "$BUNDLE/." "$APPDIR/usr/bin/"
chmod +x "$APPDIR/usr/bin/whisper"
cp "$ROOT/packaging/linux/icons/whisper.png" "$APPDIR/whisper.png"
cp "$ROOT/packaging/linux/icons/whisper.png" \
  "$APPDIR/usr/share/icons/hicolor/256x256/apps/whisper.png"

cat > "$APPDIR/usr/share/applications/whisper.desktop" << 'DESKTOP'
[Desktop Entry]
Name=耳语 Whisper
Comment=端到端加密聊天与语音客户端
Exec=whisper
Icon=whisper
Terminal=false
Type=Application
Categories=Network;InstantMessaging;
DESKTOP
cp "$APPDIR/usr/share/applications/whisper.desktop" "$APPDIR/whisper.desktop"

cat > "$APPDIR/AppRun" << 'APPRUN'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/whisper" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

mkdir -p "$OUTPUT_DIR"
rm -f "$OUT"
# CI / 无 FUSE 的环境用 --appimage-extract-and-run
ARCH=x86_64 "$TOOL" --appimage-extract-and-run "$APPDIR" "$OUT"

echo "=== AppImage built: $OUT ==="
