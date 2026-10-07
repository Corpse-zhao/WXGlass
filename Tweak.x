#import "WXGCommon.h"
#import "WXGRecon.h"
#import "WXGGlassView.h"
#import <QuartzCore/QuartzCore.h>

// ============================================================
//  WXGlass —— 微信输入法液态玻璃
//
//  设计铁律（血泪换来的）：
//  ① 私有类名一律运行时侦查，绝不硬编码猜测（§56：hook 不存在的方法 =
//     静默死代码，编译过、CI 绿、装了毫无反应）
//  ② 只钩「确定存在」的锚点：UIInputSetHostView 是键盘宿主，一定在
//  ③ 玻璃层 userInteractionEnabled = NO，从机制上不可能挡触摸
//  ④ 视图树变更只在「稳定态」做，绝不在 layoutSubviews 里改（§38 反馈环）
// ============================================================

static const NSInteger kWXGlassTag = 0x57161;

// ------------------------------------------------------------
// 稳定态守卫：不在布局回调里改视图树，改为标记 + 低频轮询
// ------------------------------------------------------------
static __weak UIView *sSeenHost = nil;
static BOOL sDirty = NO;
static CGRect sLastFrame = {0};
static NSInteger sStableCount = 0;
static BOOL sWorkerRunning = NO;

static WXGGlassView *sGlass = nil;

// ⭐ v0.2.0：hook 命中计数 —— 这是判断「锚点对不对」的核心指标。
//  0 = hook 挂在了一个系统从不调用的类上（静默死代码，血泪 §56）
//  >0 = 锚点命中，问题在后续链路
static volatile int32_t sHookHits = 0;

#pragma mark - 工具

static BOOL WXGIsKeyboardSized(UIView *v) {
    if (!v) return NO;
    CGFloat sw = v.window ? v.window.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    if (sw <= 0) return NO;
    if (v.frame.size.width < sw * 0.85) return NO;
    return (v.frame.size.width * v.frame.size.height) >= sw * 120.0;
}

static BOOL WXGIsOnScreen(UIView *v) {
    if (!v || !v.window) return NO;
    CGRect inWindow = [v convertRect:v.bounds toView:v.window];
    CGRect vis = CGRectIntersection(inWindow, v.window.bounds);
    if (CGRectIsNull(vis) || CGRectIsEmpty(vis)) return NO;
    CGFloat full = v.bounds.size.width * v.bounds.size.height;
    if (full <= 0) return NO;
    return (vis.size.width * vis.size.height) >= full * 0.6;
}

// 子树里是否含「键盘内容」—— 判据是内容不是类名
static BOOL WXGContainsKeyboardContent(UIView *v, NSInteger depth) {
    if (!v || depth > 10) return NO;
    for (UIView *sub in v.subviews) {
        NSString *n = NSStringFromClass([sub class]);
        if ([n rangeOfString:@"Keyplane"].location != NSNotFound) return YES;
        if ([n rangeOfString:@"KeyView"].location != NSNotFound) return YES;
        if ([n rangeOfString:@"KeyboardLayout"].location != NSNotFound) return YES;
        if (WXGContainsKeyboardContent(sub, depth + 1)) return YES;
    }
    return NO;
}

// 宿主里最靠上的「按键层」—— 玻璃要插在它下面
// ⚠️ 必须沿子树钻，深度给足（真实按键层在第 6~7 层）
static UIView *WXGFirstKeyLayerInHost(UIView *host) {
    if (!host) return nil;
    UIView *best = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:host];
    NSUInteger guard = 0;
    while (queue.count > 0 && guard++ < 3000) {
        UIView *cur = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (cur != host && WXGContainsKeyboardContent(cur, 0)) {
            best = cur;
            break;
        }
        for (UIView *sub in cur.subviews) [queue addObject:sub];
    }
    return best;
}

#pragma mark - 背景板透明化（对抗 WeType 自绘不透明背景）

// WeType 是自绘键盘：浅灰背景大概率来自「host 直接子视图中与宿主同宽的大背景板」。
// 玻璃在 index 0 会被它盖住 → 必须把它压成半透明，玻璃才能透出 App 内容。
// 判据按几何而非类名（铁律：不猜类名）：宽 ≥90% 宿主 且 高 ≥55% 宿主。
// 幂等：每个 tick 重跑，微信点击后重刷背景也会在 0.4s 内被压回。
static void WXGClearOpaqueBackdrops(UIView *host) {
    if (!host) return;
    CGRect hb = host.bounds;
    CGFloat base = MAX(0.15, MIN(0.85, WXGCGFloat(@"baseColor", 0.25)));

    for (UIView *sub in host.subviews) {
        if (sub.tag == kWXGlassTag) continue;
        CGRect f = sub.frame;
        if (f.size.width < hb.size.width * 0.9) continue;
        if (f.size.height < hb.size.height * 0.55) continue;

        // backgroundColor 路径
        UIColor *c = sub.backgroundColor;
        CGFloat r, g, b, a;
        if (c && [c getRed:&r green:&g blue:&b alpha:&a] && a > 0.95) {
            sub.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:base];
        }
        // layer.backgroundColor 路径（有的视图直接设 layer）
        CGColorRef lc = sub.layer.backgroundColor;
        if (lc) {
            UIColor *lc2 = [UIColor colorWithCGColor:lc];
            CGFloat r2, g2, b2, a2;
            if ([lc2 getRed:&r2 green:&g2 blue:&b2 alpha:&a2] && a2 > 0.95) {
                sub.layer.backgroundColor =
                    [UIColor colorWithRed:r2 green:g2 blue:b2 alpha:base].CGColor;
            }
        }
    }
}

#pragma mark - 玻璃层安装

static void WXGPlaceGlassInHost(UIView *host) {
    if (!host) return;

    if (!sGlass) {
        sGlass = [[WXGGlassView alloc] initWithFrame:host.bounds];
        sGlass.tag = kWXGlassTag;
        WXGLog(@"玻璃层已创建 frame=%.0fx%.0f", host.bounds.size.width, host.bounds.size.height);
    }

    if (sGlass.superview != host) {
        [host insertSubview:sGlass atIndex:0];
        WXGLog(@"玻璃层已插入 host=%@ subviews=%lu",
               NSStringFromClass([host class]), (unsigned long)host.subviews.count);
    }

    sGlass.frame = host.bounds;
    [sGlass refreshAppearance];

    // z 序：插到「按键层」之下；找不到按键层就保持在 index 0（最底，压不到按键）
    UIView *fg = WXGFirstKeyLayerInHost(host);
    if (fg && fg.superview == host) {
        NSInteger target = (NSInteger)[host.subviews indexOfObject:fg];
        NSInteger cur = (NSInteger)[host.subviews indexOfObject:sGlass];
        if (cur != NSNotFound && cur < target) target--;
        if (target < 0) target = 0;
        if (cur != target && (NSUInteger)target <= host.subviews.count) {
            [host insertSubview:sGlass atIndex:(NSUInteger)target];
        }
    }

    sGlass.hidden = NO;
}

static void WXGRemoveGlass(void) {
    if (sGlass) {
        [sGlass removeFromSuperview];
        sGlass.hidden = YES;
    }
}

#pragma mark - 主刷新（只在稳定态调用）

static void WXGRefresh(void) {
    @autoreleasepool {
        UIView *host = sSeenHost;
        if (!host) return;

        BOOL enabled = WXGBool(@"enabled", YES);
        if (!enabled) {
            WXGRemoveGlass();
            return;
        }

        if (!WXGIsKeyboardSized(host) || !WXGIsOnScreen(host)) {
            // 键盘不在屏幕上（收起态）→ 隐藏但不撤出视图树，
            // 避免「撤掉后再也没人装回来」的死锁（§37）
            if (sGlass) sGlass.hidden = YES;
            return;
        }

        WXGPlaceGlassInHost(host);
        WXGClearOpaqueBackdrops(host);   // ⭐ 每 tick 压背景，对抗微信点击后重刷
    }
}

#pragma mark - 轮询 worker（唯一允许改视图树的地方）

static void WXGWorkerTick(void);

// ⭐ v0.2.0 心跳：每 2s 写一行，附带当前状态。
//  作用：把「插件死了」和「插件活着但没找到宿主」区分开。
//  若探针里只有启动横幅、没有任何 HB 行 → worker 没跑起来（注入不完整）。
//  若 HB 一直打但 host=nil → 注入正常，是**锚点没命中**（hook 打在错的类上）。
static void WXGStartHeartbeat(void) {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_main_queue());
    dispatch_source_set_timer(t,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                              (uint64_t)(2.0 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{
        @autoreleasepool {
            UIView *h = sSeenHost;
            WXGLog(@"HB alive | host=%@ size=%.0fx%.0f glass=%@ hbCount=%ld",
                   h ? NSStringFromClass([h class]) : @"nil",
                   h ? h.frame.size.width : 0.0,
                   h ? h.frame.size.height : 0.0,
                   sGlass ? (sGlass.hidden ? @"hidden" : @"visible") : @"nil",
                   (long)sHookHits);
        }
    });
    dispatch_resume(t);
}

static void WXGStartWorker(void) {
    if (sWorkerRunning) return;
    sWorkerRunning = YES;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                              (uint64_t)(0.4 * NSEC_PER_SEC),
                              (uint64_t)(0.05 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{ WXGWorkerTick(); });
    dispatch_resume(timer);
}

static void WXGWorkerTick(void) {
    @autoreleasepool {
        UIView *host = sSeenHost;
        if (!host || !host.window) return;

        CGRect f = host.frame;
        if (!CGRectEqualToRect(f, sLastFrame)) {
            // 还在动（动画中）→ 一律不碰
            sLastFrame = f;
            sStableCount = 1;
            return;
        }
        if (sStableCount < 2) {
            sStableCount++;
            return;
        }
        // 稳定了 → 每 0.4s 刷一次（幂等，无副作用）
        WXGRefresh();
    }
}

#pragma mark - %ctor

%ctor {
    @autoreleasepool {
        // ⭐⭐ v0.2.0 铁律：本条日志必须在**任何** 进程判定/开关之前写。
        //  它是「插件有没有被注入到这个进程」的唯一证据。
        //  以前先判进程、不命中就 return，导致「没注入」和「注入了但被判定滤掉」
        //  在探针里长得一模一样 —— 完全无法定位。
        WXGLog(@"========== WXGlass %@ 启动 ==========", WXG_VERSION);
        WXGLog(@"bundleID   = %@", WXGBundleIDString());
        WXGLog(@"process    = %@ (pid=%d)", WXGProcessName(), (int)getpid());
        WXGLog(@"exePath    = %@", [[NSBundle mainBundle] executablePath] ?: @"?");
        WXGLog(@"processHit = %d (1=判定为微信系)", WXGIsWeChatProcess() ? 1 : 0);
        WXGLog(@"enabled=%d forceAll=%d",
               WXGBool(@"enabled", YES) ? 1 : 0, WXGBool(@"forceAll", NO) ? 1 : 0);

        if (!WXGShouldIntervene()) {
            WXGLog(@"⚠️ 不介入：%s", (!WXGBool(@"enabled", YES))
                   ? "总开关关闭(enabled=NO)"
                   : "进程未命中且 forceAll=NO —— 若确认本进程就是输入法，请在设置里打开「强制启用」");
            return;
        }
        WXGLog(@"已介入：%@（forceAll=%d）", WXGProcessName(), WXGBool(@"forceAll", NO) ? 1 : 0);

        WXGStartWorker();
        // 心跳：每 2s 打一行，证明确实活着（也便于看 worker 有没有跑起来）
        WXGStartHeartbeat();

        // 延后侦查：构造器阶段类可能还没注册齐
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                WXGReconProbeGlassCapabilities();
                WXGReconCheckCandidates(@[
                    @"WBMainInputView",
                    @"UIKeyboardDockView",
                    @"UIInputSetHostView",
                    @"UIInputWindowController",
                    @"TUISystemInputAssistantView"
                ]);
            }
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                WXGReconDumpKeyboardClasses();
                WXGReconDumpKeyWindowTree();
            }
        });
    }
}

// ============================================================
//  锚点①：UIInputSetHostView —— 键盘宿主，一定存在
//  只「标记」，绝不在这里改视图树（§38 反馈环）
// ============================================================
@interface UIInputSetHostView : UIView
@end

%hook UIInputSetHostView
- (void)layoutSubviews {
    %orig;
    if (!WXGShouldIntervene()) return;
    // ⚠️ 只记弱引用 + 置脏标记，零视图操作
    sSeenHost = self;
    sDirty = YES;
    if (sHookHits++ == 0) {
        WXGLog(@"🎯 锚点①命中 UIInputSetHostView layoutSubviews（首个 hook 生效！）");
    }
}
%end

// ============================================================
//  锚点②：UIInputWindowController —— 兜底
// ============================================================
@interface UIInputWindowController : UIViewController
@end

%hook UIInputWindowController
- (void)viewDidLayoutSubviews {
    %orig;
    if (!WXGShouldIntervene()) return;
    UIView *host = self.view;
    if (host && WXGIsKeyboardSized(host)) sSeenHost = host;
    sDirty = YES;
    if (sHookHits++ == 0) {
        WXGLog(@"🎯 锚点②命中 UIInputWindowController viewDidLayoutSubviews");
    }
}
%end

// ============================================================
//  锚点③：WBMainInputView（微信输入法自有类）
//  ✅ 2026-10-07 实锤：KBStyle.dylib（同为微信输入法着色插件）
//     正是用 MSHookMessageEx 挂此类的 layoutSubviews —— 类名真实存在。
//  它的 frame 最贴合「键盘面板本尊」，优先级最高的宿主来源。
// ============================================================

// ============================================================
//  背景/触摸误判修复（v0.1.1，用户真机反馈「点击一下就恢复原样」）：
//  WeType 是自绘键盘，无系统 Keyplane → 玻璃插在 index 0 会被
//  微信自己的不透明浅灰背景盖住；且每次点击微信都会重设背景色。
//  → hook setBackgroundColor:（继承自 UIView，必然存在，不会静默丢弃）
//    把每次刷上来的不透明背景拦成半透明，玻璃从底下透出 App 内容。
//    （KBStyle 同路数，真机验证过稳定）
// ============================================================
%hook WBMainInputView
- (void)setBackgroundColor:(UIColor *)color {
    if (WXGShouldIntervene()) {
        CGFloat r = 0, g = 0, b = 0, a = 0;
        if (color && [color getRed:&r green:&g blue:&b alpha:&a]) {
            // 只拦「不透明」背景（alpha>0.95）；本身就是透明的设置放行
            if (a > 0.95) {
                CGFloat base = MAX(0.15, MIN(0.85, WXGCGFloat(@"baseColor", 0.25)));
                color = [UIColor colorWithRed:r green:g blue:b alpha:base];
            }
        }
    }
    %orig(color);
}

- (void)layoutSubviews {
    %orig;
    if (!WXGShouldIntervene()) return;
    // ⭐ Logos 生成的接口无父类声明，self 赋 UIView* 需显式强转（-Werror）
    sSeenHost = (UIView *)self;
    sDirty = YES;
    if (sHookHits++ == 0) {
        WXGLog(@"🎯 锚点③命中 WBMainInputView layoutSubviews（微信输入法自有类）");
    }
}
%end
