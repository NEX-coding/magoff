#!/bin/bash
# Build a shareable zip (+ optional DMG) for 暗灯.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 1.0.0)"
DIST="$ROOT/dist"
STAGE="$DIST/stage"
APP_NAME="暗灯"
ZIP_NAME="AnDeng-MagOff-${VERSION}-macos-arm64.zip"
DMG_NAME="AnDeng-MagOff-${VERSION}.dmg"

"$ROOT/scripts/build.sh"

rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$DIST/${APP_NAME}.app" "$STAGE/${APP_NAME}.app"

# Drop a short readme next to the app for people who unzip.
cat > "$STAGE/使用说明.txt" <<'EOF'
暗灯（MagOff）
关掉 MagSafe 充电器上那颗夜里晃眼的灯。

系统要求
· Apple Silicon MacBook（MagSafe 3）
· 带指示灯的 MagSafe 充电线（纯 USB-C 头没有这颗灯）
· macOS 14 及以上

安装
1. 把「暗灯.app」拖到「应用程序」
2. 打开一次；菜单栏出现灯泡图标
3. 选「关闭指示灯」——第一次会要管理员密码（装后台小服务）

可选
· GPT/Codex 回复时闪烁：AI 回完消息，充电器灯绿橙交叉闪
· 所有系统通知都闪烁：需要辅助功能权限

不影响充电、电池、键盘灯。只改 MagSafe 指示灯显示。

卸载：菜单里「卸载后台服务…」，再把 App 拖进废纸篓。
EOF

# Clear quarantine so local zip recipients have fewer Gatekeeper surprises
# (downloaded copies will still get quarantine from the browser).
xattr -cr "$STAGE/${APP_NAME}.app" 2>/dev/null || true

rm -f "$DIST/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$DIST/$ZIP_NAME"

# Lightweight DMG (UDZO) if hdiutil is available
rm -f "$DIST/$DMG_NAME"
if command -v hdiutil >/dev/null; then
  TMP_DMG="$DIST/_tmp.dmg"
  rm -f "$TMP_DMG"
  hdiutil create -volname "暗灯 MagOff" -srcfolder "$STAGE" -ov -format UDRW "$TMP_DMG" >/dev/null
  hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DIST/$DMG_NAME" >/dev/null
  rm -f "$TMP_DMG"
fi

rm -rf "$STAGE"

echo
echo "Packaged:"
ls -lh "$DIST/$ZIP_NAME"
[[ -f "$DIST/$DMG_NAME" ]] && ls -lh "$DIST/$DMG_NAME"
echo
echo "Share tip: send the .zip; first open → right-click app → Open (ad-hoc signed)."
