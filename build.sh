#!/bin/bash
# build trigger marker: rebuild to refresh CI checkout (UCS rebrand + Alipay APStepInfo hook + daily schedule)
set -euo pipefail

# ============================================================================
# HealthBoost 构建脚本（roothide 范式 · App-only）
# ----------------------------------------------------------------------------
# 关键约定（来自 roothide 官方 RootHideManagerApp / Developer 文档）：
#   1) App 装在【根相对】 ./Applications/HealthBoost.app
#      —— roothide 的真实根就是 /var/roothide，dpkg 解包后落到
#         /var/roothide/Applications/HealthBoost.app。绝不能用 ./var/jb/ 或
#         ./var/roothide/ 这种带前缀的路径（dpkg 会报 No such file）。
#   2) 签名用 ldid -M -S<entitlements>（官方做法）。禁止在本机用 Python 手搓
#      Mach-O 签名——page-hash / superblob 极易写坏，坏签名会被 amfi 在
#      main() 前直接 SIGKILL（表现为点图标闪退、无 .ips、AppSync 也救不了）。
#   3) entitlements 必须含 roothide 4 项基础权限 + healthkit 私有权限
#      （见 HealthBoost.entitlements.plist）。
# ============================================================================

# 版本号绑定 GitHub Actions 的 run 编号，每次构建自动递增，永不重复。
if [ -n "${GITHUB_RUN_NUMBER:-}" ]; then
  VER="1.0.${GITHUB_RUN_NUMBER}-1"
else
  VER="1.0.$(date +%s)-1"
fi
echo "版本号: $VER"
PKG="com.sykes.ucs"
OUT="${PKG}_${VER}_iphoneos-arm64e.deb"

echo "[1/4] 创建 staging 目录（roothide 根相对 ./Applications）"
rm -rf staging pkg
mkdir -p staging/Applications/UCS.app
mkdir -p staging/DEBIAN

SDK=$(xcrun --sdk iphoneos --show-sdk-path)

echo "[2/4] 编译 iOS App (UCS.app) — arm64 + arm64e"
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

echo "[3/4] 拷贝 App 资源 + ldid 签名"
# 资源：Info.plist / 图标 / PkgInfo（不拷 boot.sh，那是 daemon 变体用的）
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

echo "[4/4] 生成 control / postinst 并打包"
cat > staging/DEBIAN/control << EOF
Package: com.sykes.ucs
Name: UCS
Version: ${VER}
Architecture: iphoneos-arm64e
Installed-Size: 1024
Depends: firmware (>= 13.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: UCS - modifies Apple Health data (steps, distance, flights climbed).
Section: utilities
Priority: optional
EOF

cat > staging/DEBIAN/postinst << 'EOF'
#!/bin/sh
# roothide 上 App 在 /Applications（= /var/roothide/Applications）。
# 装完后刷新图标缓存，让 SpringBoard 注册这个新 App。
# 用 uicache -a 刷新全部（避免 -p 路径在 roothide 上的歧义），不杀 SpringBoard，
# 以免 Sileo（跑在 SpringBoard 里）被中断导致 dpkg 卡 half-installed。
if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -a 2>/dev/null || true
elif [ -x /usr/bin/uicache ]; then
  /usr/bin/uicache -a 2>/dev/null || true
fi
# 同时显式刷一次具体路径（容错：上面的 -a 失败也能兜底）
if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -p /Applications/UCS.app 2>/dev/null || true
elif [ -x /usr/bin/uicache ]; then
  /usr/bin/uicache -p /Applications/UCS.app 2>/dev/null || true
fi
exit 0
EOF

chmod 755 staging/DEBIAN/postinst

dpkg-deb -b -Zgzip staging "$OUT"
echo "  -> $(ls -lh "$OUT" | awk '{print $5}') bytes"
echo "DONE(APP): $OUT"

# ============================================================================
# 第二部分：构建「干净注入 tweak」StepFaker（与 App-only deb 分开打包）
# ----------------------------------------------------------------------------
# 只注入 com.tencent.xin（微信）/ com.alipay.iphoneclient（支付宝），
# hook CMPedometerData.numberOfSteps 返回假步数。
# 目标步数由 HealthBoost App 写入微信/支付宝容器 Documents/hb_steps.txt
# 或 CFPreferences 系统域，tweak 在进程内读取。为 0 时原样放行。
# 路径使用 roothide 根相对 ./Library/MobileSubstrate/DynamicLibraries/。
# ============================================================================

STEP_VER="1.0.${GITHUB_RUN_NUMBER:-$(date +%s)}-1"
STEP_PKG="com.sykes.stepfaker"
STEP_OUT="${STEP_PKG}_${STEP_VER}_iphoneos-arm64e.deb"

echo "[5/5] 编译 StepFaker tweak dylib (arm64 + arm64e)"
rm -rf tweak_staging
mkdir -p tweak_staging/Library/MobileSubstrate/DynamicLibraries
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

echo "  拷贝 filter plist"
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

mkdir -p tweak_staging/DEBIAN
cat > tweak_staging/DEBIAN/control << EOF
Package: ${STEP_PKG}
Name: StepFaker (HealthBoost WeChat/Alipay step faker)
Version: ${STEP_VER}
Architecture: iphoneos-arm64e
Installed-Size: 128
Depends: firmware (>= 13.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: Injects only WeChat/Alipay and fakes CMPedometer step count.
Section: tweaks
Priority: optional
EOF

cat > tweak_staging/DEBIAN/postinst << 'EOF'
#!/bin/sh
# 装完强制杀掉微信/支付宝，让 tweak 在下次启动时加载并读取最新步数。
# 注意：支付宝的进程名是 AlipayWallet（不是 Alipay）。
# 写错就杀不掉，tweak 不会在支付宝里重新加载 —— 曾被误判为「插件没效果」。
for k in /var/jb/bin/killall /usr/bin/killall killall; do
  if [ -x "$k" ]; then
    "$k" -9 WeChat 2>/dev/null || true
    "$k" -9 AlipayWallet 2>/dev/null || true
    break
  fi
done
exit 0
EOF
chmod 755 tweak_staging/DEBIAN/postinst

dpkg-deb -b -Zgzip tweak_staging "$STEP_OUT"
echo "  -> $(ls -lh "$STEP_OUT" | awk '{print $5}') bytes"
echo "DONE(TWEAK): $STEP_OUT"
