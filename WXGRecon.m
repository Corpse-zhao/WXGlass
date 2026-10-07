#import "WXGRecon.h"
#import "WXGCommon.h"

#pragma mark - 类名侦查

// 「像键盘」的关键词表 —— 只用它来筛选嫌疑类，不做任何挂钩决定
static NSArray<NSString *> *WXGSuspectKeywords(void) {
    return @[ @"Keyboard", @"Keyplane", @"KeyView", @"InputBackdrop",
              @"InputView", @"InputSetHost", @"Backdrop", @"Dock",
              @"Candidate", @"Assistant", @"WBMain", @"WB", @"IME" ];
}

// 只认系统镜像 / 微信自身镜像，绝不枚举第三方框架（避免破坏别的 App）
static BOOL WXGIsRelevantImage(Class c) {
    const char *img = class_getImageName(c);
    if (!img) return NO;
    NSString *p = [NSString stringWithUTF8String:img];
    if (!p.length) return NO;
    return [p hasPrefix:@"/System/Library/"] ||
           [p hasPrefix:@"/usr/lib/"] ||
           [p containsString:@"Tencent"] ||
           [p containsString:@"Wetype"] ||
           [p containsString:@"WeType"];
}

void WXGReconDumpKeyboardClasses(void) {
    @autoreleasepool {
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (!classes) {
            WXGLog(@"侦查：objc_copyClassList 返回空");
            return;
        }

        NSArray<NSString *> *keys = WXGSuspectKeywords();
        NSMutableArray<NSString *> *hits = [NSMutableArray arrayWithCapacity:64];

        for (unsigned int i = 0; i < count; i++) {
            Class c = classes[i];
            if (!c) continue;
            const char *nm = class_getName(c);
            if (!nm || !nm[0]) continue;

            NSString *name = [NSString stringWithUTF8String:nm];
            if (!name.length) continue;
            // 跳过隐藏类（下划线开头的通常是系统的，反而最可能是真凶 → 保留）
            // 这里只跳过明显无意义的短名
            if (name.length < 3) continue;

            BOOL matched = NO;
            for (NSString *k in keys) {
                if ([name rangeOfString:k].location != NSNotFound) { matched = YES; break; }
            }
            if (!matched) continue;
            if (!WXGIsRelevantImage(c)) continue;

            // 统计它自己实现了多少个方法，便于判断「是不是干活的类」
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            unsigned int own = ms ? mc : 0;
            if (ms) free(ms);

            NSString *img = @"?";
            const char *ip = class_getImageName(c);
            if (ip) img = [[NSString stringWithUTF8String:ip] lastPathComponent];

            [hits addObject:[NSString stringWithFormat:@"%@ (%@, 自身方法 %u)",
                                                       name, img, own]];
            if (hits.count >= 200) break;
        }

        free(classes);

        WXGLog(@"========== 键盘类名侦查开始（进程 %@）==========", WXGProcessName());
        WXGLog(@"命中 %lu 个嫌疑类：", (unsigned long)hits.count);
        for (NSString *h in hits) {
            WXGLog(@"  · %@", h);
        }
        WXGLog(@"========== 键盘类名侦查结束 ==========");
    }
}

#pragma mark - 视图树侦查

static void WXGDumpSubtree(UIView *v, NSInteger depth, NSInteger maxDepth,
                           NSMutableArray<NSString *> *out) {
    if (!v || depth > maxDepth) return;
    if (out.count >= 400) return;

    NSString *cls = NSStringFromClass([v class]);
    CGRect f = v.frame;

    // 背景色信息：确认 WeType 浅灰背景的载体（backgroundColor vs layer）
    NSString *bg = @"-";
    UIColor *bc = v.backgroundColor;
    CGFloat r, g, b, a;
    if (bc && [bc getRed:&r green:&g blue:&b alpha:&a]) {
        bg = [NSString stringWithFormat:@"rgba(%.2f,%.2f,%.2f,%.2f)", r, g, b, a];
    }

    NSString *line = [NSString stringWithFormat:@"%@%@ {{%.0f,%.0f},{%.0f,%.0f}} a=%.2f h=%d uie=%d bg=%@",
                                                [@"" stringByPaddingToLength:(NSUInteger)(depth * 3)
                                                                  withString:@" "
                                                             startingAtIndex:0],
                                                cls,
                                                f.origin.x, f.origin.y,
                                                f.size.width, f.size.height,
                                                v.alpha, v.hidden ? 1 : 0,
                                                v.userInteractionEnabled ? 1 : 0,
                                                bg];
    [out addObject:line];

    for (UIView *sub in v.subviews) {
        WXGDumpSubtree(sub, depth + 1, maxDepth, out);
    }
}

static NSArray<UIWindow *> *WXGAllWindows(void) {
    // ⭐ 只走 scene API（iOS 15 起 UIApplication.windows 已弃用，-Werror 会炸）
    NSMutableArray<UIWindow *> *all = [NSMutableArray array];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w && ![all containsObject:w]) [all addObject:w];
        }
    }
    return all;
}

void WXGReconDumpKeyWindowTree(void) {
    @autoreleasepool {
        NSArray<UIWindow *> *wins = WXGAllWindows();
        WXGLog(@"========== 窗口/视图树侦查开始（共 %lu 个窗口）==========",
               (unsigned long)wins.count);
        if (wins.count == 0) {
            WXGLog(@"⚠️ 一个窗口都没有 —— 可能进程刚启动或不是 UI 进程");
        }
        for (UIWindow *w in wins) {
            WXGLog(@"---- 窗口 %@ level=%.0f hidden=%d key=%d",
                   NSStringFromClass([w class]), w.windowLevel,
                   w.hidden ? 1 : 0, w.isKeyWindow ? 1 : 0);
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
            WXGDumpSubtree(w, 0, 8, lines);
            for (NSString *l in lines) WXGLogQuiet(@"%@", l);
        }
        WXGLog(@"========== 窗口/视图树侦查结束 ==========");
    }
}

#pragma mark - 玻璃能力探测（路线 B 前置条件）

#import <objc/message.h>

static id WXGProbeNewFilter(NSString *name) {
    Class c = NSClassFromString(@"CAFilter");
    if (!c) return nil;
    SEL sel = sel_registerName("filterWithName:");
    if (![c respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(c, sel, name);
}

void WXGReconProbeGlassCapabilities(void) {
    @autoreleasepool {
        WXGLog(@"---- 玻璃能力探测（路线 B 前置条件）----");

        Class backdrop = NSClassFromString(@"CABackdropLayer");
        WXGLog(@"  CABackdropLayer : %@", backdrop ? @"✅ 存在" : @"❌ 不存在");

        Class filter = NSClassFromString(@"CAFilter");
        WXGLog(@"  CAFilter        : %@", filter ? @"✅ 存在" : @"❌ 不存在");

        id blur = WXGProbeNewFilter(@"gaussianBlur");
        WXGLog(@"  gaussianBlur    : %@", blur ? @"✅ 可创建" : @"❌ 不可用");

        id zoom = WXGProbeNewFilter(@"zoomBlur");
        WXGLog(@"  zoomBlur        : %@", zoom ? @"✅ 可创建（真实折射可用）" : @"❌ 不可用（折射将只剩亮带）");

        BOOL routeB = backdrop && blur;
        WXGLog(@"  ⇒ 玻璃路线：%@", routeB ? @"B（真折射，对标 GlassSuiteX）"
                                              : @"A（公开 API 降级，fail-open）");
    }
}

#pragma mark - 候选类存在性检查

void WXGReconCheckCandidates(NSArray<NSString *> *names) {
    @autoreleasepool {
        WXGLog(@"---- 候选类存在性检查 ----");
        for (NSString *n in names) {
            Class c = objc_getClass([n UTF8String]);
            if (!c) {
                WXGLog(@"  %@ : ❌ 不存在", n);
                continue;
            }
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            unsigned int own = ms ? mc : 0;
            if (ms) free(ms);

            BOOL hasLayout = NO;
            for (Class cur = c; cur && cur != [NSObject class]; cur = class_getSuperclass(cur)) {
                unsigned int n2 = 0;
                Method *m2 = class_copyMethodList(cur, &n2);
                for (unsigned int i = 0; m2 && i < n2; i++) {
                    NSString *sn = NSStringFromSelector(method_getName(m2[i]));
                    if ([sn isEqualToString:@"layoutSubviews"]) { hasLayout = YES; break; }
                }
                if (m2) free(m2);
                if (hasLayout) break;
            }
            WXGLog(@"  %@ : ✅ 存在（自身方法 %u, layoutSubviews=%d）",
                   n, own, hasLayout ? 1 : 0);
        }
    }
}
