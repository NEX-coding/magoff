#!/bin/bash
# Rebuild, reinstall helper (password prompt), then verify flash toggles ACLC.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./scripts/build.sh

HELPER="$ROOT/dist/暗灯.app/Contents/Helpers/magoff-helper"
SUPPORT="/Library/Application Support/MagOff"
DEST="$SUPPORT/magoff-helper"
PLIST="/Library/LaunchDaemons/com.nex.magoff.helper.plist"
INSTALL_SH="$ROOT/.build/repair-install.sh"

mkdir -p "$ROOT/.build"
cat > "$INSTALL_SH" <<EOF
#!/bin/bash
set -euo pipefail
mkdir -p "$SUPPORT"
/bin/cp -f "$HELPER" "$DEST"
/usr/sbin/chown root:wheel "$DEST"
/bin/chmod 755 "$DEST"
/usr/bin/codesign --force --sign - --identifier com.nex.magoff.helper "$DEST" >/dev/null
/usr/bin/printf 'off' > "$SUPPORT/mode"
/usr/sbin/chown root:wheel "$SUPPORT/mode"
/bin/chmod 644 "$SUPPORT/mode"
/usr/bin/touch "$SUPPORT/cmd"
/usr/sbin/chown root:wheel "$SUPPORT/cmd"
/bin/chmod 666 "$SUPPORT/cmd"
/bin/rm -f /Library/PrivilegedHelperTools/com.nex.magoff.helper
cat > "$PLIST" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.nex.magoff.helper</string>
  <key>ProgramArguments</key>
  <array><string>/Library/Application Support/MagOff/magoff-helper</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
PL
/usr/sbin/chown root:wheel "$PLIST"
/bin/chmod 644 "$PLIST"
/bin/launchctl bootout system/com.nex.magoff.helper >/dev/null 2>&1 || true
/bin/launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
/bin/sleep 0.5
if /bin/launchctl print system/com.nex.magoff.helper >/dev/null 2>&1; then
  /bin/launchctl kickstart -k system/com.nex.magoff.helper
else
  /bin/launchctl bootstrap system "$PLIST"
  /bin/launchctl enable system/com.nex.magoff.helper >/dev/null 2>&1 || true
  /bin/launchctl kickstart -k system/com.nex.magoff.helper >/dev/null 2>&1 || true
fi
EOF
chmod 700 "$INSTALL_SH"

echo "==> Installing helper (请在弹窗输入密码)"
osascript -e "do shell script \"/bin/bash '$INSTALL_SH'\" with administrator privileges"

echo "==> Daemon status"
sleep 1
launchctl print system/com.nex.magoff.helper 2>&1 | rg 'pid =|state = running|program =' | head -10
echo "probe:"; "$DEST" --probe

read_byte() {
  /tmp/read_aclc 2>/dev/null | sed -n 's/.*byte=\([0-9]*\).*/\1/p' | tail -1
}

echo "==> Baseline ACLC: $(read_byte)"
echo "==> Trigger flash"
python3 - <<'PY'
import os
path = "/Library/Application Support/MagOff/cmd"
fd = os.open(path, os.O_WRONLY | os.O_TRUNC)
os.write(fd, b"flash")
os.close(fd)
print("wrote flash ok")
PY

echo "ACLC samples during/after flash (3=绿 4=橙 1=关):"
seen=0
for i in $(seq 1 20); do
  b=$(read_byte)
  echo "  t=$(printf '%02d' $i) byte=$b"
  if [[ "$b" == "3" || "$b" == "4" ]]; then seen=1; fi
  sleep 0.15
done

echo "cmd after:"; xxd "$SUPPORT/cmd" || true
if [[ "$seen" == "1" ]]; then
  echo "PASS: saw green/amber during flash"
else
  echo "FAIL: never saw ACLC 3/4 — daemon may not be handling flash"
  exit 1
fi

pkill -f '暗灯.app/Contents/MacOS/MagOff' 2>/dev/null || true
open "$ROOT/dist/暗灯.app"
echo "App relaunched."
