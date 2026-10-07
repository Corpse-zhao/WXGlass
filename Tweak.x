#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// ---------- 设置读取 ----------
static CGFloat PFCGFloat(NSString *key, CGFloat def) {
    CFNumberRef n = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.banliren.wxglass"));
    CGFloat v = def;
    if (n) { CFNumberGetValue(n, kCFNumberCGFloatType, &v); CFRelease(n); }
    return v;
}
static BOOL PFBool(NSString *key, BOOL def) {
    CFBooleanRef b = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.banliren.wxglass"));
    BOOL v = b ? CFBooleanGetValue(b) : def;
    if (b) CFRelease(b);
    return v;
}

// ---------- 液态玻璃效果 ----------
@interface WXGlassView : UIView
@end

@implementation WXGlassView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // 底色浓度(半透明基底)
        CGFloat base = PFCGFloat(@"baseColor", 0.35);
        CGFloat blurR = PFCGFloat(@"blurRadius", 20.0);      // 模糊强度
        CGFloat glow  = PFCGFloat(@"glowStrength", 0.6);     // 高光强度
        CGFloat edge  = PFCGFloat(@"edgeRefraction", 1.0);   // 边缘折射

        // 底色:半透明磨砂基底
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:base];
        self.layer.cornerRadius = 18;
        self.clipsToBounds = YES;

        // 模糊层(UIVisualEffectView 提供真实背景模糊)
        if (blurR > 0.5) {
            UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
            UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:effect];
            blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            blur.frame = self.bounds;
            [self addSubview:blur];
        }

        // 高光:顶部渐变白
        if (glow > 0.01) {
            CAGradientLayer *grad = [CAGradientLayer layer];
            grad.frame = CGRectMake(0, 0, frame.size.width, frame.size.height * 0.45);
            grad.colors = @[
                (id)[[UIColor colorWithWhite:1.0 alpha:glow * 0.55] CGColor],
                (id)[[UIColor colorWithWhite:1.0 alpha:0.0] CGColor]
            ];
            grad.locations = @[@0.0, @1.0];
            [self.layer addSublayer:grad];
        }

        // 边缘折射:描边高光
        if (edge > 0.01) {
            self.layer.borderWidth = 1.0;
            self.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.28 * edge] CGColor];
        }
    }
    return self;
}
@end

// ---------- 注入入口 ----------
static void WXApplyToWindow(UIWindow *win) {
    if (!win) return;
    // 在窗口上叠加一层液态玻璃遮罩(验证渲染)
    WXGlassView *glass = [[WXGlassView alloc] initWithFrame:win.bounds];
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    glass.userInteractionEnabled = NO;
    [win addSubview:glass];
}

%ctor {
    if (!PFBool(@"enabled", YES)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                UIWindow *kw = nil;
                if (@available(iOS 13.0, *)) {
                    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                        if ([sc isKindOfClass:[UIWindowScene class]]) {
                            UIWindowScene *ws = (UIWindowScene *)sc;
                            if (ws.keyWindow) { kw = ws.keyWindow; break; }
                        }
                    }
                }
                if (kw) {
                    WXApplyToWindow(kw);
                    NSLog(@"[WXGlass] injected & applied to window: %@", kw);
                }
            } @catch (NSException *e) {
                NSLog(@"[WXGlass] caught: %@", e);
            }
        });
    });
}
