#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// ---------- 设置读取(偏好域 com.banliren.wxglass) ----------
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

static const NSInteger kWXGlassTag = 0x57161;

// ---------- 高光玻璃层(液态玻璃:半透明基底 + 顶部高光 + 边缘折射) ----------
@interface WXGlassView : UIView
@end

@implementation WXGlassView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CGFloat glow = PFCGFloat(@"glowStrength", 0.55);    // 高光强度
        CGFloat edge = PFCGFloat(@"edgeRefraction", 1.0);   // 边缘折射

        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;

        // 顶部高光渐变(玻璃反光)
        CAGradientLayer *grad = [CAGradientLayer layer];
        grad.frame = CGRectMake(0, 0, frame.size.width, frame.size.height * 0.5);
        grad.colors = @[
            (id)[[UIColor colorWithWhite:1.0 alpha:glow * 0.45] CGColor],
            (id)[[UIColor colorWithWhite:1.0 alpha:0.0] CGColor]
        ];
        grad.locations = @[@0.0, @1.0];
        [self.layer addSublayer:grad];

        // 边缘折射:白色细描边
        if (edge > 0.01) {
            self.layer.borderWidth = 1.0;
            self.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.28 * edge] CGColor];
        }
    }
    return self;
}
@end

// ---------- Hook 微信输入法键盘主视图(WBMainInputView) ----------
// 注入目标与 KBStyle 一致:Filter=com.apple.UIKit,该类只存在于微信键盘进程,其他 App 无此 Class 自动跳过
%hook WBMainInputView
- (void)layoutSubviews {
    %orig;
    if (!PFBool(@"enabled", YES)) return;
    @try {
        UIView *v = (UIView *)self; // 私有类无头文件,按 UIView 处理
        CGFloat base = PFCGFloat(@"baseColor", 0.25); // 底色浓度 = 半透明 alpha
        v.backgroundColor = [UIColor colorWithWhite:0.08 alpha:base];

        WXGlassView *glass = (WXGlassView *)[v viewWithTag:kWXGlassTag];
        if (!glass) {
            glass = [[WXGlassView alloc] initWithFrame:v.bounds];
            glass.tag = kWXGlassTag;
            [v insertSubview:glass atIndex:0];
        }
        glass.frame = v.bounds;
        NSLog(@"[WXGlass] glass applied to WBMainInputView (%@)", NSStringFromClass([v class]));
    } @catch (NSException *e) {
        NSLog(@"[WXGlass] caught: %@", e);
    }
}
%end

// ---------- 键盘 Dock(仿 KBStyle,仅该类存在时生效) ----------
%hook UIKeyboardDockView
- (void)layoutSubviews {
    %orig;
    if (!PFBool(@"enabled", YES)) return;
    @try {
        UIView *v = (UIView *)self;
        CGFloat base = PFCGFloat(@"baseColor", 0.25);
        v.backgroundColor = [UIColor colorWithWhite:0.08 alpha:base];
    } @catch (NSException *e) {
        NSLog(@"[WXGlass] dock caught: %@", e);
    }
}
%end
