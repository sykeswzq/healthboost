#!/bin/bash
# build trigger marker: rebuild to refresh CI checkout (UCS rebrand + Alipay fix + single deb)
set -euo pipefail

# ============================================================================
# HealthBoost 构建脚本（roothide 范式 · 单一 deb 同时含 App + tweak）
# ----------------------------------------------------------------------------
# 关键约定（来自 roothide 官方 RootHideManagerApp / Developer 文档）：
#   1) App 装在【根相对】 ./Applications/UCS.app
#      —— roothide 的真实根就是 /var/roothide，dpkg 解包后落到
#         /var/roothide/Applications/UCS.app。绝不能用 ./var/jb/ 或
#         ./var/roothide/ 这种带前缀的路径（dpkg 会报 No such file）。
#   2) tweak 装在【根相对】 ./Library/MobileSubstrate/DynamicLibraries/
#      —— 解包后落到 /var/roothide/Library/MobileSubstrate/DynamicLibraries/。
#   3) 签名用 ldid -M -S<entitlements>（官方做法）。禁止在本机用 Python 手搓
#      Mach-O 签名——page-hash / superblob 极易写坏，坏签名会被 amfi 在
#      main() 前直接 SIGKILL（表现为点图标闪退、无 .ips、AppSync 也救不了）。
#   4) entitlements 必须含 roothide 4 项基础权限 + healthkit 私有权限
#      （见 HealthBoost.entitlements.plist）。
# ============================================================================

# 版本号：v2.1.1（修复 roothide 路径重映射导致微信读不到虚拟步数；必须 >2.1 否则 Sileo 当降级）
VER="2.1.1"
echo "版本号: $VER"
PKG="com.sykes.ucs"
OUT="${PKG}_${VER}_iphoneos-arm64e.deb"

echo "[1/5] 创建 staging 目录（roothide 根相对 ./Applications + ./Library）"
rm -rf staging tweak_staging pkg
mkdir -p staging/Applications/UCS.app
mkdir -p staging/Library/MobileSubstrate/DynamicLibraries
mkdir -p staging/DEBIAN
mkdir -p tweak_staging/Library/MobileSubstrate/DynamicLibraries

SDK=$(xcrun --sdk iphoneos --show-sdk-path)

echo "[2/5] 编译 iOS App (UCS.app) — arm64 + arm64e"
xcrun --sdk iphoneos clang \
  -framework UIKit \
  -framework Foundation \
  -framework HealthKit \
  -framework Security \
  -framework UserNotifications \
  -fobjc-arc \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.4 \
  -isysroot "$SDK" \
  -o staging/Applications/UCS.app/HealthBoostApp \
  HealthBoostApp/HealthBoostApp.m HealthBoostApp/AppDelegate.m
chmod 755 staging/Applications/UCS.app/HealthBoostApp
echo "  app: $(wc -c < staging/Applications/UCS.app/HealthBoostApp) bytes"

echo "[3/5] 拷贝 App 资源 + ldid 签名"
cp HealthBoostApp/HealthBoost/Info.plist  staging/Applications/UCS.app/
cp HealthBoostApp/HealthBoost/AppIcon60x60@2x.png staging/Applications/UCS.app/
cp HealthBoostApp/HealthBoost/PkgInfo    staging/Applications/UCS.app/
chmod 644 staging/Applications/UCS.app/Info.plist
chmod 644 staging/Applications/UCS.app/AppIcon60x60@2x.png
chmod 644 staging/Applications/UCS.app/PkgInfo

if ! command -v ldid >/dev/null 2>&1; then
  echo "ERROR: ldid 未安装，无法签名，终止构建"
  exit 1
fi
if [ ! -f HealthBoost.entitlements.plist ]; then
  echo "ERROR: HealthBoost.entitlements.plist 缺失，终止构建"
  exit 1
fi
# -M：先清除已有（可能坏的）签名；-S<file>：用官方 entitlements 重新 ad-hoc 签名
ldid -M -SHealthBoost.entitlements.plist staging/Applications/UCS.app/HealthBoostApp
echo "  已用 ldid 重签 App"

# 校验 1：签名必须含 healthkit 权限（否则无法写入健康数据）
if ! ldid -e staging/Applications/UCS.app/HealthBoostApp 2>/dev/null | grep -q "healthkit"; then
  echo "ERROR: 签名后未检测到 healthkit 权限，终止构建"
  exit 1
fi
# 校验 2：必须含 roothide 基础 no-sandbox 权限
if ! ldid -e staging/Applications/UCS.app/HealthBoostApp 2>/dev/null | grep -q "no-sandbox"; then
  echo "ERROR: 签名后未检测到 com.apple.private.security.no-sandbox，App 在 roothide 上会被沙盒限制，终止构建"
  exit 1
fi
# 校验 3：二进制仍是合法 Mach-O（magic 验证）
magic=$(xxd -p -l4 staging/Applications/UCS.app/HealthBoostApp 2>/dev/null || od -An -tx1 -N4 staging/Applications/UCS.app/HealthBoostApp | tr -d ' \n')
if [ "$magic" != "cafebabe" ]; then
  echo "ERROR: 签名后 Mach-O 头异常 (magic=$magic)，终止构建"
  exit 1
fi
echo "  签名校验通过: healthkit + no-sandbox 均存在，Mach-O 头正常"

echo "[4/5] 编译并签名 StepFaker tweak（并入同一 deb）"
xcrun --sdk iphoneos clang \
  -dynamiclib -fobjc-arc \
  -framework Foundation -framework CoreFoundation -framework CoreMotion -framework HealthKit \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib \
  tweak/StepFaker.m
chmod 755 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
echo "  tweak dylib: $(wc -c < tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib) bytes"

cp tweak/StepFaker.plist tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist
chmod 644 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist

if command -v ldid >/dev/null 2>&1; then
  ldid -M -S tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
  echo "  已用 ldid 签名 tweak dylib"
else
  echo "WARN: ldid 不可用，tweak dylib 未签名（roothide 下可能加载失败）"
fi

# 校验 dylib 仍是合法 Mach-O（胖二进制 magic=cafebabe）
smagic=$(xxd -p -l4 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib 2>/dev/null || od -An -tx1 -N4 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib | tr -d ' \n')
if [ "$smagic" != "cafebabe" ]; then
  echo "ERROR: tweak dylib Mach-O 头异常 (magic=$smagic)，终止构建"
  exit 1
fi
echo "  tweak 签名校验通过: Mach-O 头正常"

echo "  将 tweak 并入主 staging"
cp tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
cp tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist
chmod 755 staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
chmod 644 staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist

echo "[5/5] 生成 control / postinst 并打包（单一 deb）"
cat > staging/DEBIAN/control << EOF
Package: com.sykes.ucs
Name: UCS
Version: ${VER}
Architecture: iphoneos-arm64e
Installed-Size: 1152
Depends: firmware (>= 13.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: UCS - 运动数据注入工具，支持微信步数同步。
Section: utilities
Priority: optional
EOF

cat > staging/DEBIAN/postinst << 'EOF'
#!/bin/sh
# roothide 上 App 在 /Applications（= /var/roothide/Applications）。
# 刷新图标缓存，让 SpringBoard 注册这个新 App（uicache -a 全量，再显式补一次路径）。
if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -a 2>/dev/null || true
  /var/jb/usr/bin/uicache -p /Applications/UCS.app 2>/dev/null || true
elif [ -x /usr/bin/uicache ]; then
  /usr/bin/uicache -a 2>/dev/null || true
  /usr/bin/uicache -p /Applications/UCS.app 2>/dev/null || true
fi
# 装完强制杀掉微信，让 tweak 在下次启动时加载并读取最新步数。
for k in /var/jb/bin/killall /usr/bin/killall killall; do
  if [ -x "$k" ]; then
    "$k" -9 WeChat 2>/dev/null || true
    break
  fi
done
exit 0
EOF

chmod 755 staging/DEBIAN/postinst

dpkg-deb -b -Zgzip staging "$OUT"
echo "  -> $(ls -lh "$OUT" | awk '{print $5}') bytes"
echo "DONE: $OUT"
