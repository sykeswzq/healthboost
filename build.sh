#!/bin/bash
# build trigger marker: rebuild to refresh CI checkout (UCS rebrand + Alipay fix + single deb)
set -euo pipefail

# ============================================================================
# HealthBoost æå»ºèæ¬ï¼roothide èå¼ Â· åä¸ deb åæ¶å?App + tweakï¼?# ----------------------------------------------------------------------------
# å³é®çº¦å®ï¼æ¥è?roothide å®æ¹ RootHideManagerApp / Developer ææ¡£ï¼ï¼
#   1) App è£å¨ãæ ¹ç¸å¯¹ã?./Applications/UCS.app
#      ââ?roothide ççå®æ ¹å°±æ¯ /var/roothideï¼dpkg è§£ååè½å?#         /var/roothide/Applications/UCS.appãç»ä¸è½ç?./var/jb/ æ?#         ./var/roothide/ è¿ç§å¸¦åç¼çè·¯å¾ï¼dpkg ä¼æ¥ No such fileï¼ã?#   2) tweak è£å¨ãæ ¹ç¸å¯¹ã?./Library/MobileSubstrate/DynamicLibraries/
#      ââ?è§£ååè½å?/var/roothide/Library/MobileSubstrate/DynamicLibraries/ã?#   3) ç­¾åç?ldid -M -S<entitlements>ï¼å®æ¹åæ³ï¼ãç¦æ­¢å¨æ¬æºç?Python ææ
#      Mach-O ç­¾åââpage-hash / superblob ææååï¼åç­¾åä¼è¢« amfi å?#      main() åç´æ?SIGKILLï¼è¡¨ç°ä¸ºç¹å¾æ éªéãæ  .ipsãAppSync ä¹æä¸äºï¼ã?#   4) entitlements å¿é¡»å?roothide 4 é¡¹åºç¡æé + healthkit ç§ææé
#      ï¼è§ HealthBoost.entitlements.plistï¼ã?# ============================================================================

# 版本号：v2.2.14（修复：通知点击不触发 + 后台切换闪退根因）
VER="2.2.14"
echo "版本号: $VER"
PKG="com.sykes.ucs"
OUT="${PKG}_${VER}_iphoneos-arm64e.deb"

echo "[1/5] åå»º staging ç®å½ï¼roothide æ ¹ç¸å¯?./Applications + ./Libraryï¼?
rm -rf staging tweak_staging pkg
mkdir -p staging/Applications/UCS.app
mkdir -p staging/Library/MobileSubstrate/DynamicLibraries
mkdir -p staging/DEBIAN
mkdir -p tweak_staging/Library/MobileSubstrate/DynamicLibraries

SDK=$(xcrun --sdk iphoneos --show-sdk-path)

echo "[2/5] ç¼è¯ iOS App (UCS.app) â?arm64 + arm64e"
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

echo "[3/5] æ·è´ App èµæº + ldid ç­¾å"
cp HealthBoostApp/Info.plist  staging/Applications/UCS.app/
cp HealthBoostApp/HealthBoost/AppIcon60x60@2x.png staging/Applications/UCS.app/
cp HealthBoostApp/HealthBoost/PkgInfo    staging/Applications/UCS.app/
chmod 644 staging/Applications/UCS.app/Info.plist
chmod 644 staging/Applications/UCS.app/AppIcon60x60@2x.png
chmod 644 staging/Applications/UCS.app/PkgInfo

if ! command -v ldid >/dev/null 2>&1; then
  echo "ERROR: ldid æªå®è£ï¼æ æ³ç­¾åï¼ç»æ­¢æå»?
  exit 1
fi
if [ ! -f HealthBoost.entitlements.plist ]; then
  echo "ERROR: HealthBoost.entitlements.plist ç¼ºå¤±ï¼ç»æ­¢æå»?
  exit 1
fi
# -Mï¼åæ¸é¤å·²æï¼å¯è½åçï¼ç­¾åï¼?S<file>ï¼ç¨å®æ¹ entitlements éæ° ad-hoc ç­¾å
ldid -M -SHealthBoost.entitlements.plist staging/Applications/UCS.app/HealthBoostApp
echo "  å·²ç¨ ldid éç­¾ App"

# æ ¡éª 1ï¼ç­¾åå¿é¡»å« healthkit æéï¼å¦åæ æ³åå¥å¥åº·æ°æ®ï¼
if ! ldid -e staging/Applications/UCS.app/HealthBoostApp 2>/dev/null | grep -q "healthkit"; then
  echo "ERROR: ç­¾ååæªæ£æµå° healthkit æéï¼ç»æ­¢æå»?
  exit 1
fi
# æ ¡éª 2ï¼å¿é¡»å« roothide åºç¡ no-sandbox æé
if ! ldid -e staging/Applications/UCS.app/HealthBoostApp 2>/dev/null | grep -q "no-sandbox"; then
  echo "ERROR: ç­¾ååæªæ£æµå° com.apple.private.security.no-sandboxï¼App å?roothide ä¸ä¼è¢«æ²çéå¶ï¼ç»æ­¢æå»º"
  exit 1
fi
# æ ¡éª 3ï¼äºè¿å¶ä»æ¯åæ³ Mach-Oï¼magic éªè¯ï¼?magic=$(xxd -p -l4 staging/Applications/UCS.app/HealthBoostApp 2>/dev/null || od -An -tx1 -N4 staging/Applications/UCS.app/HealthBoostApp | tr -d ' \n')
if [ "$magic" != "cafebabe" ]; then
  echo "ERROR: ç­¾åå?Mach-O å¤´å¼å¸?(magic=$magic)ï¼ç»æ­¢æå»?
  exit 1
fi
echo "  ç­¾åæ ¡éªéè¿: healthkit + no-sandbox åå­å¨ï¼Mach-O å¤´æ­£å¸?

echo "[4/5] ç¼è¯å¹¶ç­¾å?StepFaker tweakï¼å¹¶å¥åä¸ debï¼?
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
  echo "  å·²ç¨ ldid ç­¾å tweak dylib"
else
  echo "WARN: ldid ä¸å¯ç¨ï¼tweak dylib æªç­¾åï¼roothide ä¸å¯è½å è½½å¤±è´¥ï¼"
fi

# æ ¡éª dylib ä»æ¯åæ³ Mach-Oï¼èäºè¿å?magic=cafebabeï¼?smagic=$(xxd -p -l4 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib 2>/dev/null || od -An -tx1 -N4 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib | tr -d ' \n')
if [ "$smagic" != "cafebabe" ]; then
  echo "ERROR: tweak dylib Mach-O å¤´å¼å¸?(magic=$smagic)ï¼ç»æ­¢æå»?
  exit 1
fi
echo "  tweak ç­¾åæ ¡éªéè¿: Mach-O å¤´æ­£å¸?

echo "  å°?tweak å¹¶å¥ä¸?staging"
cp tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
cp tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist
chmod 755 staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
chmod 644 staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist

echo "[5/5] çæ control / postinst å¹¶æåï¼åä¸ debï¼?
cat > staging/DEBIAN/control << EOF
Package: com.sykes.ucs
Name: UCS
Version: ${VER}
Architecture: iphoneos-arm64e
Installed-Size: 1152
Depends: firmware (>= 13.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: UCS - è¿å¨æ°æ®æ³¨å¥å·¥å·ï¼æ¯æå¾®ä¿¡æ­¥æ°åæ­¥ã?Section: utilities
Priority: optional
EOF

cat > staging/DEBIAN/postinst << 'EOF'
#!/bin/sh
# roothide ä¸?App å?/Applicationsï¼? /var/roothide/Applicationsï¼ã?# å·æ°å¾æ ç¼å­ï¼è®© SpringBoard æ³¨åè¿ä¸ªæ?Appï¼uicache -a å¨éï¼åæ¾å¼è¡¥ä¸æ¬¡è·¯å¾ï¼ã?if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -a 2>/dev/null || true
  /var/jb/usr/bin/uicache -p /Applications/UCS.app 2>/dev/null || true
elif [ -x /usr/bin/uicache ]; then
  /usr/bin/uicache -a 2>/dev/null || true
  /usr/bin/uicache -p /Applications/UCS.app 2>/dev/null || true
fi
# è£å®å¼ºå¶ææå¾®ä¿¡ï¼è®?tweak å¨ä¸æ¬¡å¯å¨æ¶å è½½å¹¶è¯»åææ°æ­¥æ°ã?for k in /var/jb/bin/killall /usr/bin/killall killall; do
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
