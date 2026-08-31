#!/bin/bash
set -euo pipefail

# 版本号绑定 GitHub Actions 的 run 编号，每次构建自动递增，永不重复。
# 原因：dpkg/Sileo 拒绝覆盖安装同版本号的包，版本号不变必然「装不上」。
# 本地构建（无 GITHUB_RUN_NUMBER）时退回时间戳，同样保证不重复。
if [ -n "${GITHUB_RUN_NUMBER:-}" ]; then
  VER="1.0.${GITHUB_RUN_NUMBER}-1"
else
  VER="1.0.$(date +%s)-1"
fi
echo "版本号: $VER"
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
  -framework Security \
  -fobjc-arc \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o staging/var/jb/Applications/HealthBoost.app/HealthBoostApp \
  HealthBoostApp/HealthBoostApp.m
chmod 755 staging/var/jb/Applications/HealthBoost.app/HealthBoostApp
echo "  app: $(wc -c < staging/var/jb/Applications/HealthBoost.app/HealthBoostApp) bytes"

echo "[2.5/5] 编译注入微信的 tweak dylib"
# 关键：写 HealthKit 只能改「健康」App；要让「微信运动」显示必须 hook 微信进程。
# 逆向 UCStep 6.0.6 确认目标为 WCDeviceStepObject 的
# stepCount / hkStepCount / m7StepCount（m7 = M7 协处理器，微信优先用这个）。
# 不链接 CydiaSubstrate，纯 Objective-C runtime 替换，由 MobileSubstrate 按 plist 注入。
mkdir -p staging/var/jb/Library/MobileSubstrate/DynamicLibraries
xcrun --sdk iphoneos clang \
  -dynamiclib \
  -framework Foundation \
  -fobjc-arc \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o staging/var/jb/Library/MobileSubstrate/DynamicLibraries/HealthBoost.dylib \
  HBTweak/HBTweak.m
chmod 755 staging/var/jb/Library/MobileSubstrate/DynamicLibraries/HealthBoost.dylib
echo "  dylib: $(wc -c < staging/var/jb/Library/MobileSubstrate/DynamicLibraries/HealthBoost.dylib) bytes"

# 注入 filter：微信（UGGD 为微信可执行文件/旧版标识，两个都写上以防万一）
cat > staging/var/jb/Library/MobileSubstrate/DynamicLibraries/HealthBoost.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Filter</key>
	<dict>
		<key>Bundles</key>
		<array>
			<string>com.tencent.xin</string>
			<string>UGGD</string>
		</array>
	</dict>
</dict>
</plist>
EOF
chmod 644 staging/var/jb/Library/MobileSubstrate/DynamicLibraries/HealthBoost.plist
echo "  已生成注入 filter (com.tencent.xin / UGGD)"

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
# 注意：这里用 << EOF（不带引号）让 ${VER} 能被展开；
# 若写成 << 'EOF' 则变量不展开，control 里的 Version 会永远是字面量。
cat > staging/DEBIAN/control << EOF
Package: com.sykes.healthboost
Name: HealthBoost
Version: ${VER}
Architecture: iphoneos-arm64e
Installed-Size: 1024
Depends: firmware (>= 13.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: Modifies Apple Health data (steps, distance, flights climbed). Desktop app.
Section: utilities
Priority: optional
EOF

cat > staging/DEBIAN/postinst << 'EOF'
#!/bin/sh
# 刷新图标缓存。只用 uicache（仅重建图标数据库，不杀 SpringBoard）。
# 绝不用 sbreload / killall backboardd / reboot ——
# 安装器 Sileo 跑在 SpringBoard 里，杀掉或重启会导致 dpkg 被中断，
# 包状态卡在 half-installed，之后再装就一直报「安装失败」。
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
