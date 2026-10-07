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

// ---------- 液态玻璃视图 ----------
@interface WXGlassView : UIView
@end

@implementation WXGlassView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CGFloat base = PFCGFloat(@"baseColor", 0.25);      // 底色浓度
        CGFloat blurR = PFCGFloat(@"blurRadius", 20.0);    // 模糊强度
        CGFloat glow  = PFCGFloat(@"glowStrength", 0.55);  // 高光强度
        CGFloat edge  = PFCGFloat(@"edgeRefraction", 1.0); // 边缘折射

        // 半透明磨砂基底
        self.backgroundColor = [UIColor colorWithWhite:0.14 alpha:base];
        self.layer.cornerRadius = 16;
        self.clipsToBounds = YES;

        // 模糊层(键盘扩展沙盒下可能受限,尽力而为)
        if (blurR > 0.5) {
            UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
            UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:effect];
            blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            blur.frame = self.bounds;
            [self addSubview:blur];
        }

        // 高光:顶部渐变
        if (glow > 0.01) {
            CAGradientLayer *grad = [CAGradientLayer layer];
            grad.frame = CGRectMake(0, 0, frame.size.width, frame.size.height * 0.45);
            grad.colors = @[
                (id)[[UIColor colorWithWhite:1.0 alpha:glow * 0.5] CGColor],
                (id)[[UIColor colorWithWhite:1.0 alpha:0.0] CGColor]
            ];
            grad.locations = @[@0.0, @1.0];
            [self.layer addSublayer:grad];
        }

        // 边缘折射:描边
        if (edge > 0.01) {
            self.layer.borderWidth = 1.0;
            self.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.26 * edge] CGColor];
        }
    }
    return self;
}
@end

static void WXApplyToView(UIView *v) {
    if (!v) return;
    WXGlassView *glass = [[WXGlassView alloc] initWithFrame:v.bounds];
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    glass.userInteractionEnabled = NO;
    [v addSubview:glass];
}

// ---------- Hook 键盘 ----------
%hook UIInputViewController
- (void)viewDidLoad {
    %orig;
    if (!PFBool(@"enabled", YES)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            WXApplyToView(self.view);
            NSLog(@"[WXGlass] keyboard glass applied to %@", self);
        } @catch (NSException *e) {
            NSLog(@"[WXGlass] caught: %@", e);
        }
    });
}
%end
