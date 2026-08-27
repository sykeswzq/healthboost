#!/bin/bash
set -euo pipefail

VER="1.0.0-1"
PKG="com.sykes.healthboost"
OUT="${PKG}_${VER}_iphoneos-arm64e.deb"

echo "[1/6] 创建 staging 目录"
rm -rf staging pkg
mkdir -p staging/var/jb/usr/bin
mkdir -p staging/var/jb/Library/LaunchDaemons
mkdir -p staging/var/jb/Library/HealthBoost
mkdir -p staging/var/jb/Applications/HealthBoost.app
mkdir -p staging/DEBIAN

SDK=$(xcrun --sdk iphoneos --show-sdk-path)

echo "[2/6] 编译 daemon 守护进程"
xcrun --sdk iphoneos clang \
  -framework HealthKit \
  -framework Foundation \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o staging/var/jb/usr/bin/HealthBoost \
  src/HealthBoostDaemon.m
chmod 755 staging/var/jb/usr/bin/HealthBoost
echo "  daemon: $(wc -c < staging/var/jb/usr/bin/HealthBoost) bytes"

echo "[3/6] 编译 iOS App (HealthBoost.app)"
xcrun --sdk iphoneos clang \
  -framework UIKit \
  -framework Foundation \
  -fobjc-arc \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o staging/var/jb/Applications/HealthBoost.app/HealthBoostApp \
  HealthBoostApp/HealthBoostApp.m
chmod 755 staging/var/jb/Applications/HealthBoost.app/HealthBoostApp
echo "  app: $(wc -c < staging/var/jb/Applications/HealthBoost.app/HealthBoostApp) bytes"

echo "[4/ 6] 拷贝 App 资源"
cp HealthBoostApp/HealthBoost/Info.plist  staging/var/jb/Applications/HealthBoost.app/
cp HealthBoostApp/HealthBoost/AppIcon60x60@2x.png staging/var/jb/Applications/HealthBoost.app/
cp HealthBoostApp/HealthBoost/PkgInfo    staging/var/jb/Applications/HealthBoost.app/
chmod 644 staging/var/jb/Applications/HealthBoost.app/Info.plist
chmod 644 staging/var/jb/Applications/HealthBoost.app/AppIcon60x60@2x.png
chmod 644 staging/var/jb/Applications/HealthBoost.app/PkgInfo

# 签名（ldid 可用时）
if command -v ldid >/dev/null 2>&1; then
  if [ -f HealthBoost.entitlements.plist ]; then
    ldid -SHealthBoost.entitlements.plist staging/var/jb/Applications/HealthBoost.app/HealthBoostApp 2>/dev/null || true
  else
    ldid -S staging/var/jb/Applications/HealthBoost.app/HealthBoostApp 2>/dev/null || true
  fi
  ldid -S staging/var/jb/usr/bin/HealthBoost 2>/dev/null || true
  echo "  已用 ldid 签名"
else
  echo "  [info] ldid 不可用，跳过签名（越狱环境可运行未签名二进制）"
fi

echo "[5/6] 创建 control / postinst / prerm"
cat > staging/DEBIAN/control << 'EOF'
Package: com.sykes.healthboost
Name: HealthBoost
Version: 1.0.0-1
Architecture: iphoneos-arm64e
Installed-Size: 400
Depends: firmware (>= 13.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: Modifies Apple Health data (steps, distance, flights climbed). Includes desktop app.
Section: utilities
Priority: optional
EOF

cat > staging/DEBIAN/postinst << 'EOF'
#!/var/jb/usr/bin/bash
PLIST=/var/jb/Library/LaunchDaemons/com.sykes.healthboost.plist
LABEL=com.sykes.healthboost

ROOTHIDE=0
[ -L /var/jb ] && ROOTHIDE=1

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

if [ "$ROOTHIDE" = "1" ]; then
  launchctl enable "system/$LABEL" 2>/dev/null || true
  launchctl bootstrap system "$PLIST" 2>/dev/null || true
  launchctl kickstart -k "system/$LABEL" 2>/dev/null || true
else
  launchctl load "$PLIST" 2>/dev/null || true
fi

# 刷新主屏幕，让 App 图标出现
# 先尝试带路径的 uicache，再回退到 sbreload / 全局 uicache / 重启 backboardd
if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -p /var/jb/Applications/HealthBoost.app 2>/dev/null || true
fi
if [ -x /usr/bin/uicache ]; then
  /usr/bin/uicache -p /var/jb/Applications/HealthBoost.app 2>/dev/null || true
fi
/var/jb/usr/bin/sbreload 2>/dev/null || sbreload 2>/dev/null || /var/jb/usr/bin/uicache -a 2>/dev/null || uicache -a 2>/dev/null || killall -9 backboardd 2>/dev/null || true
exit 0
EOF

cat > staging/DEBIAN/prerm << 'EOF'
#!/var/jb/usr/bin/bash
launchctl unload /var/jb/Library/LaunchDaemons/com.sykes.healthboost.plist 2>/dev/null || true
exit 0
EOF

chmod 755 staging/DEBIAN/postinst staging/DEBIAN/prerm

echo "[6/6] 拷贝 daemon plist 并打包"
cp com.sykes.healthboost.plist staging/var/jb/Library/LaunchDaemons/
chmod 644 staging/var/jb/Library/LaunchDaemons/com.sykes.healthboost.plist

dpkg-deb -b -Zgzip staging "$OUT"
echo "  -> $(ls -lh "$OUT" | awk '{print $5}') bytes"
echo "  Architecture: $(dpkg-deb -f "$OUT" Architecture)"
echo "DONE: $OUT"
