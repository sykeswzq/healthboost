#!/bin/sh
# UCS / StepFaker 真机一键诊断（分步打点版）
# 用法: sh ucs_diag.sh      （请把输出整段复制回来）
#
# 本版配合 1.0.153+ 的「纯 POSIX 日志 + 分步打点」：
#   dylib 被加载后会在 /var/mobile/hb_probe_raw.log 依次留下
#   P0 -> P1 -> P2 -> P3 -> P4 -> P5 -> P9
#   崩溃时日志会停在某一步，据此可精确定位崩溃发生在哪一行之后。

echo "############################################################"
echo "# UCS/StepFaker 诊断（分步打点版）   $(date '+%F %T')"
echo "############################################################"

ROOTS="/var/jb /var/LIY /var/ulb /var/mobile/.jbroot"
JBDIR=""
for r in $ROOTS; do
  if [ -d "$r/Library/MobileSubstrate/DynamicLibraries" ]; then JBDIR="$r"; break; fi
done
[ -z "$JBDIR" ] && JBDIR="(未找到 MobileSubstrate 目录)"
echo ""
echo "[0] 越狱根目录: $JBDIR"
echo "    iOS: $(sw_vers -productVersion 2>/dev/null || uname -a)"

# ---------- [1] tweak 安装状态 / filter ----------
echo ""
echo "==================== [1] tweak 安装状态 ===================="
DL="Library/MobileSubstrate/DynamicLibraries"
FOUND=0
for r in $ROOTS; do
  if [ -f "$r/$DL/StepFaker.dylib" ]; then
    FOUND=1
    echo "  dylib : $r/$DL/StepFaker.dylib  ($(stat -f%z "$r/$DL/StepFaker.dylib" 2>/dev/null) bytes)"
    echo "  版本  : $(dpkg -s com.sykes.stepfaker 2>/dev/null | grep '^Version' | head -1)"
    echo "  plist :"
    cat "$r/$DL/StepFaker.plist" 2>/dev/null | sed 's/^/    /'
    echo "  --- 关键项判定 ---"
    grep -q "com.alipay.iphoneclient" "$r/$DL/StepFaker.plist" 2>/dev/null \
      && echo "    [OK]   Bundles 含 com.alipay.iphoneclient" \
      || echo "    [FAIL] Bundles 缺 com.alipay.iphoneclient"
    grep -q "AlipayWallet" "$r/$DL/StepFaker.plist" 2>/dev/null \
      && echo "    [OK]   Executables 含 AlipayWallet" \
      || echo "    [FAIL] Executables 不含 AlipayWallet（旧错值 Alipay 会完全失配）"
  fi
done
[ "$FOUND" = "0" ] && echo "  [FAIL] 未找到 StepFaker.dylib"

# ---------- [2] 支付宝二进制 / 反注入标记 ----------
echo ""
echo "==================== [2] 支付宝二进制 ===================="
APP=""
for base in /var/containers/Bundle/Application /private/var/containers/Bundle/Application; do
  APP=$(find "$base" -maxdepth 3 -type d -name "AlipayWallet.app" 2>/dev/null | head -1)
  [ -n "$APP" ] && break
done
if [ -z "$APP" ]; then
  echo "  [WARN] 未找到 AlipayWallet.app"
  find /var/containers -maxdepth 4 -type d -name "*.app" 2>/dev/null | grep -i alipay | head -5 | sed 's/^/    候选: /'
else
  echo "  App 路径: $APP"
  EXE=""; BID=""
  if command -v plutil >/dev/null 2>&1; then
    EXE=$(plutil -key CFBundleExecutable "$APP/Info.plist" 2>/dev/null)
    BID=$(plutil -key CFBundleIdentifier   "$APP/Info.plist" 2>/dev/null)
  fi
  echo "  CFBundleExecutable = ${EXE:-?}   <-- filter 的 Executables 必须等于这个值"
  echo "  CFBundleIdentifier = ${BID:-?}"
  BIN="$APP/${EXE:-AlipayWallet}"
  if [ -f "$BIN" ]; then
    echo "  二进制: $BIN ($(stat -f%z "$BIN" 2>/dev/null) bytes)"
    echo -n "  __RESTRICT 反注入标记: "
    if grep -aq "__restrict" "$BIN" 2>/dev/null; then
      echo "存在 !!  dyld 会忽略 DYLD_INSERT_LIBRARIES，任何 tweak 都注不进去"
    else
      echo "未发现"
    fi
  fi
fi

# ---------- [3] 探针日志一览 ----------
echo ""
echo "==================== [3] /var/mobile 下探针日志 ===================="
G=$(ls -1 /var/mobile/hb_probe*.log 2>/dev/null)
if [ -z "$G" ]; then
  echo "  一个都没有。"
else
  echo "$G" | while read -r f; do
    echo "  --- $f  ($(wc -l < "$f") 行) ---"
    tail -30 "$f" | sed 's/^/    /'
  done
fi

# ---------- [4] 打点定位（核心） ----------
echo ""
echo "==================== [4] 分步打点定位（核心） ===================="
echo "  说明: P0=进入constructor  P1=安全模式  P2=进程名  P3=Substrate"
echo "        P4=开始hook  P5=hook完成  P9=全部完成"
echo ""
RAW="/var/mobile/hb_probe_raw.log"
ALI="/var/mobile/hb_probe_AlipayWallet_log.log"
SRC=""
if [ -f "$ALI" ]; then SRC="$ALI"; elif [ -f "$RAW" ]; then SRC="$RAW"; fi

if [ -z "$SRC" ]; then
  echo "  [结论] 连 P0 都没有 -> dylib **从未被加载**，或崩在 dyld 加载阶段。"
  echo "         请继续看 [5] 崩溃日志确认。"
else
  echo "  来源文件: $SRC"
  echo "  --- 支付宝进程的打点序列 ---"
  grep -a "AlipayWallet\]" "$SRC" 2>/dev/null | grep -ao "P[0-9][A-Z]*_[A-Za-z0-9_]*" | sed 's/^/    /'
  echo "  --- 微信进程的打点序列（对照，应该能跑完）---"
  grep -a "WeChat\]" "$SRC" 2>/dev/null | grep -ao "P[0-9][A-Z]*_[A-Za-z0-9_]*" | sed 's/^/    /'
  echo ""
  LASTP=$(grep -a "AlipayWallet\]" "$SRC" 2>/dev/null | grep -ao "P[0-9][A-Z]*_[A-Za-z0-9_]*" | tail -1)
  if [ -z "$LASTP" ]; then
    echo "  [结论] raw 日志存在，但没有任何支付宝进程的打点记录"
    echo "         -> 支付宝进程从未执行到 constructor"
  else
    echo "  支付宝最后打点: $LASTP"
    echo ""
    case "$LASTP" in
      P0_ENTER*)     echo "  [结论] 崩在 P0 之后、P1 之前（access 检查）——极罕见，多半是环境异常";;
      P1_SAFEMODE*)  echo "  [结论] 崩在 P1 之后、P2 之前（getprogname）——极罕见";;
      P2_PROG*)      echo "  [结论] 崩在 P2 之后、P3 之前 -> **dlsym/dlopen 解析 Substrate 时崩溃**";;
      P3A_DLSYM*|P3B_DLOPEN*) echo "  [结论] 崩在 dlopen 某个候选路径时 -> 该路径的库有问题，看上面的 P3B_DLOPEN 最后一行";;
      P3_SUBSTRATE*) echo "  [结论] 崩在 P3 之后、P4 之前 -> Substrate 解析完就崩，与 hook 无关";;
      P4_ALIPAY*)    echo "  [结论] 崩在 **安装 APStepInfo hook 的过程中** -> hook 本身触发崩溃";;
      P5_ALIPAY*)    echo "  [结论] hook 已装完，崩在返回之后（App 启动阶段）";;
      P9_DONE_ALIPAY*) echo "  [结论] constructor **完整跑完**！崩溃发生在更晚的 App 运行期";;
      *)             echo "  [结论] 停在 $LASTP，请对照上面的序列判断";;
    esac
  fi
  echo ""
  echo "  --- 安全模式开关状态 ---"
  if [ -f /var/mobile/hb_nohook ]; then
    echo "    /var/mobile/hb_nohook 存在 -> 当前处于安全模式（只记日志、不装任何 hook）"
  else
    echo "    /var/mobile/hb_nohook 不存在 -> 当前为正常模式（会装 hook）"
    echo "    想验证崩溃是否与 hook 无关，可执行: touch /var/mobile/hb_nohook"
    echo "    （然后彻底杀掉支付宝重开；验证完用 rm /var/mobile/hb_nohook 复原）"
  fi
fi

# ---------- [5] 容器内第二份日志 ----------
echo ""
echo "==================== [5] App 容器内的 hb_probe.log ===================="
C=$(find /var/mobile/Containers/Data/Application -maxdepth 3 -name "hb_probe.log" 2>/dev/null)
if [ -z "$C" ]; then
  echo "  未在任何 App 容器中找到"
else
  echo "$C" | while read -r f; do
    echo "  --- $f ---"
    tail -15 "$f" | sed 's/^/    /'
  done
fi

# ---------- [6] 崩溃日志 ----------
echo ""
echo "==================== [6] 崩溃日志 ===================="
CR=""
for d in /var/mobile/Library/Logs/CrashReporter /private/var/mobile/Library/Logs/CrashReporter \
         /var/mobile/Library/Logs/CrashReporter/Retired; do
  [ -d "$d" ] && CR="$d" && break
done
if [ -z "$CR" ]; then
  echo "  [WARN] 未找到 CrashReporter 目录"
else
  echo "  目录: $CR"
  HIT=""
  for f in $(ls -t "$CR" 2>/dev/null | head -10); do
    p="$CR/$f"
    if grep -aqi "alipay" "$p" 2>/dev/null; then HIT="$p"; break; fi
  done
  if [ -n "$HIT" ]; then
    echo "  命中: $HIT"
    echo -n "  StepFaker 是否在 Binary Images 中: "
    grep -aq "StepFaker.dylib" "$HIT" 2>/dev/null && echo "是（dylib 确实被加载了）" || echo "否"
    echo "  --- 该进程加载的越狱 dylib ---"
    grep -ao "/var/[A-Za-z0-9_./-]*DynamicLibraries/[A-Za-z0-9_.+-]*\.dylib" "$HIT" 2>/dev/null \
      | sort -u | head -30 | sed 's/^/    /'
    echo "  --- 异常类型 ---"
    grep -a -m4 -E "Exception Type|Exception Codes|Termination Reason|Triggered by Thread" "$HIT" 2>/dev/null | sed 's/^/    /'
    echo "  --- 崩溃线程的栈顶几帧 ---"
    awk '/Thread [0-9]+ Crashed/,/^$/' "$HIT" 2>/dev/null | head -14 | sed 's/^/    /'
  else
    echo "  最近 10 个崩溃文件中没有支付宝的"
  fi
fi

# ---------- [7] 对号入座 ----------
echo ""
echo "==================== [7] 对号入座 ===================="
cat <<'EOF'
  A. [4] 显示 P9_DONE_ALIPAY
     -> constructor 跑完了。崩溃在更晚的运行期，把 [6] 的栈顶发来定位。

  B. [4] 显示 P4_ALIPAY 后中断
     -> 装 APStepInfo hook 时崩。tweak 层面需换策略（如延迟 hook）。

  C. [4] 显示 P2/P3 后中断
     -> 崩在解析 Substrate，与 hook 无关，是注入框架环境问题。

  D. [4] 连 P0 都没有 + [6] Binary Images 无 StepFaker
     -> dylib 从未加载。查 [1] filter 与 [2] __RESTRICT 标记。
        若 __RESTRICT 存在：支付宝自带 dyld 级反注入，任何 tweak 都进不去。

  E. 开安全模式(touch /var/mobile/hb_nohook)后不闪退
     -> 崩溃确由 hook 引起，按 B 处理。
  F. 开安全模式后仍闪退
     -> 崩溃与 hook 无关，是支付宝的越狱检测，需 Choicy/A-Bypass/Shadow。
EOF
echo ""
echo "################################ 诊断结束 ################################"
