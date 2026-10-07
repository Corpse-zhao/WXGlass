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
echo "[1/7] 打包方案（roothide 隐根）"
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
echo "[2/7] PreferenceLoader 入口 plist"
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
echo "[3/7] bundle Info.plist"
INFO="Preferences/Info.plist"
if [ -f "$INFO" ]; then
    if grep -q '<string>WXGlassPrefsListController</string>' "$INFO"; then
        ok "NSPrincipalClass = WXGlassPrefsListController"
    elif grep -q '<string>PSListController</string>' "$INFO"; then
        bad "NSPrincipalClass 是抽象基类 PSListController → 应改为控制器真实类名"
    else
        bad "NSPrincipalClass 未设置或值不对"
    fi
else
    bad "$INFO 不存在"
fi

# ── 4. 版本号一致性 ─────────────────────────────────────────
echo ""
echo "[4/7] 版本号一致性"
TV=$(grep -oE 'WXG_VERSION @"[0-9.]+"' WXGCommon.h 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
PV=$(grep -oE 'kDLPrefsVersion = @"[0-9.]+"' Preferences/WXGlassPrefs.mm 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
CV=$(grep -E '^Version:' control 2>/dev/null | awk '{print $2}')
echo "     Tweak=$TV  Prefs=$PV  control=$CV"
if [ -n "$TV" ] && [ "$TV" = "$PV" ]; then ok "Tweak 与 Prefs 版本一致"; else bad "Tweak($TV) 与 Prefs($PV) 版本不一致 → 自检会误报"; fi
if [ -n "$TV" ] && [ "$TV" = "$CV" ]; then ok "Tweak 与 control 版本一致"; else bad "Tweak($TV) 与 control($CV) 版本不一致"; fi

# ── 5. 反馈环防护 ───────────────────────────────────────────
echo ""
echo "[5/7] 反馈环防护（hook 内禁止改视图树）"
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
echo "[6/7] 运行时侦查（禁止纯硬编码私有类名）"
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
echo "[7/7] 触摸安全"
if grep -q 'userInteractionEnabled = NO' WXGGlassView.m 2>/dev/null; then
    ok "玻璃层 userInteractionEnabled = NO"
else
    bad "玻璃层未禁用交互 → 可能挡住键盘触摸"
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
