#!/bin/bash
set -euo pipefail

VER="1.0.0-1"
PKG="com.sykes.healthboost"
OUT="${PKG}_${VER}_iphoneos-arm64e.deb"

echo "[1/5] 创建 staging 目录"
rm -rf staging pkg
mkdir -p staging/var/jb/Library/HealthBoost
mkdir -p staging/var/jb/Applications/HealthBoost.app
mkdir -p staging/DEBIAN

SDK=$(xcrun --sdk iphoneos --show-sdk-path)

echo "[2/5] 编译 iOS App (HealthBoost.app)"
xcrun --sdk iphoneos clang \
  -framework UIKit \
  -framework Foundation \
  -framework HealthKit \
  -fobjc-arc \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o staging/var/jb/Applications/HealthBoost.app/HealthBoostApp \
  HealthBoostApp/HealthBoostApp.m
chmod 755 staging/var/jb/Applications/HealthBoost.app/HealthBoostApp
echo "  app: $(wc -c < staging/var/jb/Applications/HealthBoost.app/HealthBoostApp) bytes"

echo "[3/5] 拷贝 App 资源"
cp HealthBoostApp/HealthBoost/Info.plist  staging/var/jb/Applications/HealthBoost.app/
cp HealthBoostApp/HealthBoost/AppIcon60x60@2x.png staging/var/jb/Applications/HealthBoost.app/
cp HealthBoostApp/HealthBoost/PkgInfo    staging/var/jb/Applications/HealthBoost.app/
chmod 644 staging/var/jb/Applications/HealthBoost.app/Info.plist
chmod 644 staging/var/jb/Applications/HealthBoost.app/AppIcon60x60@2x.png
chmod 644 staging/var/jb/Applications/HealthBoost.app/PkgInfo

echo "[4/5] 签名 (ldid 必须带 healthkit 权限，否则 App 无法写入 Apple Health)"
if ! command -v ldid >/dev/null 2>&1; then
  echo "ERROR: ldid 未安装，App 无法签名 healthkit 权限，终止构建"
  exit 1
fi
if [ ! -f HealthBoost.entitlements.plist ]; then
  echo "ERROR: HealthBoost.entitlements.plist 缺失，终止构建"
  exit 1
fi
ldid -SHealthBoost.entitlements.plist staging/var/jb/Applications/HealthBoost.app/HealthBoostApp
echo "  已用 ldid 签名 App (含 healthkit)"
# 验证签名确实带 healthkit 权限
if ldid -e staging/var/jb/Applications/HealthBoost.app/HealthBoostApp 2>/dev/null | grep -q "healthkit"; then
  echo "  验证通过: entitlements 含 healthkit"
else
  echo "ERROR: 签名后未检测到 healthkit，App 无法写入健康数据"
  exit 1
fi

echo "[5/5] 创建 control / postinst / prerm / postrm 并打包"
cat > staging/DEBIAN/control << 'EOF'
Package: com.sykes.healthboost
Name: HealthBoost
Version: 1.0.0-1
Architecture: iphoneos-arm64e
Installed-Size: 400
Depends: firmware (>= 13.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: Modifies Apple Health data (steps, distance, flights climbed). Desktop app.
Section: utilities
Priority: optional
EOF

cat > staging/DEBIAN/postinst << 'EOF'
#!/bin/sh
# 刷新图标缓存。只用 uicache（仅重建图标数据库，不杀 SpringBoard），
# 绝不用 sbreload / killall backboardd —— 安装器 Sileo 跑在 SpringBoard 里，
# 杀掉它会导致 dpkg 被中断。
if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -p /var/jb/Applications/HealthBoost.app 2>/dev/null || true
  /var/jb/usr/bin/uicache -a 2>/dev/null || true
elif [ -x /usr/bin/uicache ]; then
  /usr/bin/uicache -p /var/jb/Applications/HealthBoost.app 2>/dev/null || true
  /usr/bin/uicache -a 2>/dev/null || true
fi
exit 0
EOF

cat > staging/DEBIAN/prerm << 'EOF'
#!/bin/sh
# 卸载旧版可能遗留的守护进程（新版本已无 daemon）
launchctl unload /var/jb/Library/LaunchDaemons/com.sykes.healthboost.plist 2>/dev/null || true
launchctl unload /Library/LaunchDaemons/com.sykes.healthboost.plist 2>/dev/null || true
exit 0
EOF

cat > staging/DEBIAN/postrm << 'EOF'
#!/bin/sh
# 卸载后刷新图标缓存，让桌面图标消失。仅用 uicache，不杀 SpringBoard。
if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -a 2>/dev/null || true
elif [ -x /usr/bin/uicache ]; then
  /usr/bin/uicache -a 2>/dev/null || true
fi
exit 0
EOF

chmod 755 staging/DEBIAN/postinst staging/DEBIAN/prerm staging/DEBIAN/postrm

dpkg-deb -b -Zgzip staging "$OUT"
echo "  -> $(ls -lh "$OUT" | awk '{print $5}') bytes"
echo "DONE: $OUT"
