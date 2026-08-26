#!/bin/bash
set -euo pipefail

VER="1.0.0-1"
PKG="com.sykes.healthboost"
OUT="${PKG}_${VER}_iphoneos-arm64e.deb"

echo "[1/5] 创建 staging 目录"
rm -rf staging pkg
mkdir -p staging/usr/bin
mkdir -p staging/Library/LaunchDaemons
mkdir -p staging/Library/HealthBoost
mkdir -p staging/var/jb/usr/bin
mkdir -p staging/var/jb/Library/LaunchDaemons
mkdir -p staging/var/jb/Library/HealthBoost
mkdir -p staging/var/jb/var/mobile/Library/Preferences
mkdir -p staging/var/jb/Applications/HealthBoost.app
mkdir -p staging/DEBIAN

echo "[2/5] 创建 control 文件"
cat > staging/DEBIAN/control << 'EOF'
Package: com.sykes.healthboost
Name: HealthBoost
Version: 1.0.0-1
Architecture: iphoneos-arm64e
Installed-Size: 200
Depends: firmware (>= 13.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: Modifies Apple Health data (steps, distance, flights climbed)
Section: utilities
Priority: optional
EOF

echo "[3/5] 创建 postinst/prerm 脚本"
cat > staging/DEBIAN/postinst << 'EOF'
#!/var/jb/usr/bin/bash
PLIST=/var/jb/Library/LaunchDaemons/com.sykes.healthboost.plist
LABEL=com.sykes.healthboost

# roothide 检测
if [ -L /var/jb ]; then
  ROOTHIDE=1
else
  ROOTHIDE=0
fi

stop_daemon() {
  if [ "$ROOTHIDE" = "1" ]; then
    launchctl disable "system/$LABEL" 2>/dev/null || true
    launchctl bootout "system/$LABEL" 2>/dev/null || true
  fi
  launchctl unload "$PLIST" 2>/dev/null || true
}

start_daemon() {
  if [ "$ROOTHIDE" = "1" ]; then
    launchctl enable "system/$LABEL" 2>/dev/null || true
    launchctl bootstrap system "$PLIST" 2>/dev/null || true
    launchctl kickstart -k "system/$LABEL" 2>/dev/null || true
  else
    launchctl load "$PLIST" 2>/dev/null || true
  fi
}

# 创建默认配置
mkdir -p /var/jb/Library/HealthBoost
if [ ! -f /var/jb/Library/HealthBoost/config.plist ]; then
  cat > /var/jb/Library/HealthBoost/config.plist << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>enabled</key>
    <false/>
    <key>steps</key>
    <integer>0</integer>
    <key>distance</key>
    <real>0.0</real>
    <key>flights</key>
    <integer>0</integer>
</dict>
</plist>
PLISTEOF
fi

start_daemon
exit 0
EOF

cat > staging/DEBIAN/prerm << 'EOF'
#!/var/jb/usr/bin/bash
launchctl unload /var/jb/Library/LaunchDaemons/com.sykes.healthboost.plist 2>/dev/null || true
exit 0
EOF

chmod 755 staging/DEBIAN/postinst staging/DEBIAN/prerm

echo "[4/5] 复制文件到 staging"
cp com.sykes.healthboost.plist staging/var/jb/Library/LaunchDaemons/

# 使用已编译的二进制（由 workflow 编译）
if [ -f "./HealthBoost" ]; then
  cp ./HealthBoost staging/var/jb/usr/bin/
  chmod 755 staging/var/jb/usr/bin/HealthBoost
  echo "  使用已编译的 daemon 二进制"
else
  echo "[!] 警告：未找到 daemon 二进制，使用占位文件"
  dd if=/dev/zero of=staging/var/jb/usr/bin/HealthBoost bs=1024 count=164 2>/dev/null
  chmod 755 staging/var/jb/usr/bin/HealthBoost
fi

# 复制 App（如果存在）
if [ -d "./HealthBoost.app" ]; then
  cp -r HealthBoost.app staging/var/jb/Applications/
  echo "  包含 HealthBoost.app"
else
  echo "[!] 警告：未找到 HealthBoost.app"
fi

chmod 644 staging/var/jb/Library/LaunchDaemons/com.sykes.healthboost.plist

echo "[5/5] 打包 deb (dpkg-deb -b -Zgzip)"
dpkg-deb -b -Zgzip staging "$OUT"
echo "  -> $(ls -lh "$OUT" | awk '{print $5}') bytes"
echo "  Architecture: $(dpkg-deb -f "$OUT" Architecture)"
echo "DONE: $OUT"
