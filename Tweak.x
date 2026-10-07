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

#pragma mark - 玻璃层安装

static void WXGPlaceGlassInHost(UIView *host) {
    if (!host) return;

    if (!sGlass) {
        sGlass = [[WXGGlassView alloc] initWithFrame:host.bounds];
        sGlass.tag = kWXGlassTag;
        WXGLog(@"玻璃层已创建");
    }

    if (sGlass.superview != host) {
        [host insertSubview:sGlass atIndex:0];
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
    }
}

#pragma mark - 轮询 worker（唯一允许改视图树的地方）

static void WXGWorkerTick(void);

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
        WXGLog(@"========== WXGlass %@ 启动（WXG_VERSION）==========", WXG_VERSION);

        if (!WXGIsWeChatProcess()) {
            WXGLog(@"当前进程不是微信/微信输入法 → 不干预");
            return;
        }

        WXGLog(@"已注入微信系进程：%@", WXGProcessName());
        WXGStartWorker();

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
    if (!WXGIsWeChatProcess()) return;
    if (!WXGBool(@"enabled", YES)) return;
    // ⚠️ 只记弱引用 + 置脏标记，零视图操作
    sSeenHost = self;
    sDirty = YES;
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
    if (!WXGIsWeChatProcess()) return;
    if (!WXGBool(@"enabled", YES)) return;
    UIView *host = self.view;
    if (host && WXGIsKeyboardSized(host)) sSeenHost = host;
    sDirty = YES;
}
%end

// ============================================================
//  锚点③：WBMainInputView（微信输入法自有类）
//  ✅ 2026-10-07 实锤：KBStyle.dylib（同为微信输入法着色插件）
//     正是用 MSHookMessageEx 挂此类的 layoutSubviews —— 类名真实存在。
//     （此前「可能不存在被静默丢弃」的担忧解除）
//  它的 frame 最贴合「键盘面板本尊」，优先级最高的宿主来源。
// ============================================================
%hook WBMainInputView
- (void)layoutSubviews {
    %orig;
    if (!WXGIsWeChatProcess()) return;
    if (!WXGBool(@"enabled", YES)) return;
    sSeenHost = self;
    sDirty = YES;
}
%end
