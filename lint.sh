#!/usr/bin/env bash
# ============================================================
#  WXGlass 本地静态预检
#
#  用途：推送前在 Windows 上自查，把 CI 会拦的低级错误提前抓出来。
#  不编译，只做静态断言 —— 秒级完成。
#
#  用法：bash lint.sh
# ============================================================
set -uo pipefail

PASS=0
FAIL=0

ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "═══ WXGlass 静态预检 ═══"
echo ""

# ── 1. 打包方案 ──────────────────────────────────────────────
echo "[1/10] 打包方案（roothide 隐根）"
if grep -q 'THEOS_PACKAGE_SCHEME = roothide' Makefile 2>/dev/null; then
    ok "Makefile: THEOS_PACKAGE_SCHEME = roothide"
else
    bad "Makefile 缺少 THEOS_PACKAGE_SCHEME = roothide（rootless 会被 Sileo 拒装）"
fi

if grep -q '^Architecture: iphoneos-arm64e' control 2>/dev/null; then
    ok "control: Architecture = iphoneos-arm64e"
else
    bad "control: Architecture 必须是 iphoneos-arm64e（当前：$(grep '^Architecture:' control 2>/dev/null | awk '{print $2}')）"
fi

if grep -q 'ARCHS = arm64 arm64e' Makefile 2>/dev/null; then
    ok "Makefile: ARCHS = arm64 arm64e"
else
    bad "Makefile: 必须 ARCHS = arm64 arm64e"
fi

# ── 2. 入口 plist ────────────────────────────────────────────
echo ""
echo "[2/10] PreferenceLoader 入口 plist"
ENTRY="Preferences/WXGlassEntry.plist"
if [ -f "$ENTRY" ]; then
    if grep -q '<key>entry</key>' "$ENTRY"; then
        ok "含 entry 包裹"
    else
        bad "缺 entry 包裹 → PreferenceLoader 静默跳过 → 设置里没入口"
    fi
    for k in bundle cell detail isController label; do
        if grep -q "<key>$k</key>" "$ENTRY"; then
            ok "entry 内含 $k"
        else
            bad "entry 内缺 $k"
        fi
    done
else
    bad "$ENTRY 不存在"
fi

# ── 3. bundle Info.plist ─────────────────────────────────────
echo ""
echo "[3/10] bundle Info.plist"
# ⭐ 必须在 Resources/ 下：Theos bundle.mk 只把 Resources/* 装进 bundle，
#    放在 Preferences/ 根目录的 Info.plist 不会进包 → NSPrincipalClass 丢失 → 入口白屏
INFO="Preferences/Resources/Info.plist"
if [ -f "$INFO" ]; then
    if grep -q '<string>WXGlassPrefsListController</string>' "$INFO"; then
        ok "NSPrincipalClass = WXGlassPrefsListController"
    elif grep -q '<string>PSListController</string>' "$INFO"; then
        bad "NSPrincipalClass 是抽象基类 PSListController → 应改为控制器真实类名"
    else
        bad "NSPrincipalClass 未设置或值不对"
    fi
else
    bad "$INFO 不存在（放在 Preferences/ 根目录不会被打进 bundle）"
fi

# ── 4. 版本号一致性 ─────────────────────────────────────────
echo ""
echo "[4/10] 版本号一致性"
TV=$(grep -oE 'WXG_VERSION @"[0-9.]+"' WXGCommon.h 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
PV=$(grep -oE 'kDLPrefsVersion = @"[0-9.]+"' Preferences/WXGlassPrefs.mm 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
CV=$(grep -E '^Version:' control 2>/dev/null | awk '{print $2}')
echo "     Tweak=$TV  Prefs=$PV  control=$CV"
if [ -n "$TV" ] && [ "$TV" = "$PV" ]; then ok "Tweak 与 Prefs 版本一致"; else bad "Tweak($TV) 与 Prefs($PV) 版本不一致 → 自检会误报"; fi
if [ -n "$TV" ] && [ "$TV" = "$CV" ]; then ok "Tweak 与 control 版本一致"; else bad "Tweak($TV) 与 control($CV) 版本不一致"; fi

# ── 5. 反馈环防护 ───────────────────────────────────────────
echo ""
echo "[5/10] 反馈环防护（hook 内禁止改视图树）"
if command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    PY=$(command -v python3 || command -v python)
    "$PY" - <<'PYEOF'
import re, sys
src = open("Tweak.x", encoding="utf-8").read()
blocks = re.findall(r'%hook\s+\w+(.*?)%end', src, re.S)
bad = False
for b in blocks:
    for m in ("insertSubview", "addSubview", "removeFromSuperview"):
        if m in b:
            print(f"  ❌ hook 块内出现 {m} → 会触发 layout 反馈环")
            bad = True
if not bad:
    print(f"  ✅ {len(blocks)} 个 hook 块均未在布局回调内改视图树")
sys.exit(1 if bad else 0)
PYEOF
    [ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
else
    if grep -A30 '%hook UIInputSetHostView' Tweak.x | grep -qE 'addSubview|insertSubview'; then
        bad "hook 内出现视图操作"
    else
        ok "未发现明显视图操作（粗略检查）"
    fi
fi

# ── 6. 运行时侦查 ───────────────────────────────────────────
echo ""
echo "[6/10] 运行时侦查（禁止纯硬编码私有类名）"
if grep -q 'objc_copyClassList' WXGRecon.m 2>/dev/null; then
    ok "WXGRecon.m 含 objc_copyClassList"
else
    bad "缺 objc_copyClassList → 无法确认钩子是否挂上"
fi
if grep -q 'WXGReconCheckCandidates' Tweak.x 2>/dev/null; then
    ok "%ctor 调用 WXGReconCheckCandidates"
else
    bad "%ctor 未做候选类存在性检查"
fi

# ── 7. 触摸安全 ─────────────────────────────────────────────
echo ""
echo "[7/10] 触摸安全"
if grep -q 'userInteractionEnabled = NO' WXGGlassView.m 2>/dev/null; then
    ok "玻璃层 userInteractionEnabled = NO"
else
    bad "玻璃层未禁用交互 → 可能挡住键盘触摸"
fi

# ── 8. 注入清单（⭐ ElleKit 语义：有 bundleID 的进程只看 Bundles）──
echo ""
echo "[8/10] 注入清单（ElleKit Bundles/Executables 语义）"
# ⭐ ElleKit 源码实锤：Bundles 与 Executables **永不共同求值**。
#   键盘是 app extension → 一定有 bundleID → 只走 Bundles 分支。
if grep -q 'com.apple.uikit' WXGlass.plist 2>/dev/null; then
    ok "Bundles 含 com.apple.uikit（ElleKit 全局注入开关，绕开 bundleID 猜测）"
else
    bad "Bundles 缺 com.apple.uikit → 若真实 bundleID 与猜测不符则永不注入（血泪）"
fi
if grep -q 'Executables' WXGlass.plist 2>/dev/null; then
    ok "保留 Executables（无 bundleID 的进程走这条）"
else
    bad "filter plist 缺 Executables → 无 bundleID 的进程注入不到"
fi
if grep -q 'com.tencent.wetype' WXGlass.plist 2>/dev/null; then
    ok "filter plist 含 com.tencent.wetype"
else
    bad "filter plist 缺 com.tencent.wetype"
fi

# ── 9. 探针必须多路径兜底（沙盒进程可能写不了 Documents）──────
echo ""
echo "[9/10] 探针多路径兜底"
if grep -q 'WXGProbeCandidates' WXGCommon.m 2>/dev/null; then
    ok "探针多路径尝试（避免沙盒写失败被误判成没注入）"
else
    bad "探针只有单一路径 → 沙盒写失败会与「没注入」混淆"
fi
if grep -q 'NSHomeDirectory' WXGCommon.m 2>/dev/null; then
    ok "探针含沙盒兜底路径 (NSHomeDirectory)"
else
    bad "探针缺沙盒兜底路径"
fi
# 启动横幅必须在进程判定之前（否则「没注入」与「被判定滤掉」无法区分）
if awk '/%ctor/,/^}/' Tweak.x 2>/dev/null | grep -n 'WXGLog' | head -1 \
   | grep -q 'WXGlass.*启动'; then
    ok "启动横幅在进程判定之前（可区分「没注入」与「被滤掉」）"
else
    bad "启动横幅未在进程判定之前 → 无法定位注入失败"
fi

# ── 10. ⭐⭐⭐ %init 使用规则（读 Logos 源码后的定论）───────────
echo ""
echo "[10/10] Logos %ctor/%init 规则"
# 【Logos 源码实锤 bin/logos.pl】
#   · %ctor → 独立的 __attribute__((constructor)) 函数（第 554~558 行）
#   · 默认构造器 _logosLocalInit() **只在全文件无 %init 时**才生成（第 875 行）
#   · %init 是把 group 初始化语句**原样展开在该行**（第 566 行起）
#   → 结论：%ctor 与默认构造器**互不取代**，写了 %ctor 也照样挂 hook。
#   → 但**手写 %init 反而会编译失败**：展开出的代码引用文件后部才声明的
#     `_logos_method$...` 符号 → use of undeclared identifier。
#   → 所以本项目：**禁止手写 %init**。
if grep -vE '^\s*//' Tweak.x | grep -qE '^\s*%init\s*;'; then
    bad "Tweak.x 手写了 %init; → 会展开引用后部声明的 _logos_method\$ 符号 → 编译失败"
    bad "  ↑ 默认构造器已自动生成，手写 %init 是多余的且会 break 构建"
else
    ok "未手写 %init（交给 Logos 默认构造器，避免前置引用）"
fi
# %ctor 存在即可，无需额外条件 —— 但必须确认它确实在文件里
if grep -qE '^\s*%ctor' Tweak.x; then
    ok "存在 %ctor（展开为独立 constructor，与默认构造器并列执行）"
else
    bad "缺少 %ctor"
fi

# ── 汇总 ────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════"
echo "  通过 $PASS 项，失败 $FAIL 项"
echo "═══════════════════════════════════════"
if [ "$FAIL" -gt 0 ]; then
    echo "❌ 有 $FAIL 项未通过，先修再推。"
    exit 1
fi
echo "✅ 全部通过，可以推送。"
