#import "WXGGlassView.h"
#import "WXGCommon.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

// ============================================================
//  WXGGlassView —— 路线 B：对标 GlassSuiteX（用户 2026-10-07 选定）
//
//  真玻璃 = CABackdropLayer（真实采样背后内容）
//         + gaussianBlur（真实模糊，半径 = 模糊强度 pt）
//         + zoomBlur（真实折射：内容被拉向中心 → 边缘呈透镜扭曲）
//  边缘折射带 + 高光 + 内描边 = 玻璃边亮线（GlassSuiteX 观感）
//
//  ⭐ fail-open 铁律：CAFilter / CABackdropLayer 任一缺失
//     → 自动降级路线 A（UIBlurEffect），永不白屏/崩溃
//
//  安全铁律：userInteractionEnabled 恒为 NO
// ============================================================

#pragma mark - 私有 API 声明（全部运行时探测，绝不裸调）

static Class WXGCAFilterClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"CAFilter"); });
    return c;
}

static Class WXGCABackdropLayerClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"CABackdropLayer"); });
    return c;
}

// 运行时构造 CAFilter —— 拿不到就返回 nil（调用方自行降级）
static id WXGNewFilter(NSString *name) {
    Class c = WXGCAFilterClass();
    if (!c) return nil;
    SEL sel = sel_registerName("filterWithName:");
    if (![c respondsToSelector:sel]) return nil;
    id f = ((id (*)(id, SEL, id))objc_msgSend)(c, sel, name);
    return f;
}

@implementation WXGGlassView {
    // 路线 B（首选）
    CALayer *_backdrop;             // CABackdropLayer 实例
    BOOL     _backdropOK;           // 能力探测结果
    // 路线 A（降级）
    UIVisualEffectView *_blurView;

    CALayer *_tint;                 // 底色（在模糊之上 = 着色玻璃）
    CAGradientLayer *_glow;
    CAGradientLayer *_edgeTop;
    CAGradientLayer *_edgeBottom;
    CAGradientLayer *_edgeLeft;
    CAGradientLayer *_edgeRight;
    CALayer *_rim;

    // ⭐ v0.2.0 诊断：一条可见色带（证明「插件确实活到了绘制这一步」）
    CAGradientLayer *_dbgBar;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // ⭐ 安全铁律：恒不接收触摸
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        // ⭐ 折射的关键：backdrop 比 self 大一圈（向外扩），被 self 裁剪，
        //    可视边缘显示的是「从外面拉进来的内容」→ 透镜折射观感
        self.clipsToBounds = YES;

        // ---- 能力探测：决定走 B 还是 A ----
        Class backdropClass = WXGCABackdropLayerClass();
        id blurProbe = WXGNewFilter(@"gaussianBlur");
        if (backdropClass && blurProbe) {
            _backdrop = [[backdropClass alloc] init];
            _backdropOK = YES;
            WXGLog(@"玻璃路线 B：CABackdropLayer + gaussianBlur ✅");
        } else {
            _backdropOK = NO;
            WXGLog(@"玻璃路线 A 降级：CAFilter=%@ CABackdropLayer=%@",
                   WXGCAFilterClass() ? @"有" : @"无",
                   backdropClass ? @"有" : @"无");
        }

        if (_backdropOK) {
            _backdrop.frame = self.bounds;
            [self.layer addSublayer:_backdrop];
        } else {
            _blurView = [[UIVisualEffectView alloc] initWithEffect:nil];
            _blurView.userInteractionEnabled = NO;   // ⭐ 双保险
            _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                         UIViewAutoresizingFlexibleHeight;
            [self addSubview:_blurView];
        }

        // ---- 着色层（底色浓度，盖在模糊之上）----
        _tint = [CALayer layer];
        [self.layer addSublayer:_tint];

        // ---- 折射亮带 + 高光 + 内描边 ----
        _glow       = [CAGradientLayer layer];
        _edgeTop    = [CAGradientLayer layer];
        _edgeBottom = [CAGradientLayer layer];
        _edgeLeft   = [CAGradientLayer layer];
        _edgeRight  = [CAGradientLayer layer];
        _rim        = [CALayer layer];

        [self.layer addSublayer:_edgeTop];
        [self.layer addSublayer:_edgeBottom];
        [self.layer addSublayer:_edgeLeft];
        [self.layer addSublayer:_edgeRight];
        [self.layer addSublayer:_glow];
        [self.layer addSublayer:_rim];

        // ⭐ v0.2.0 诊断色带：设置里打开「诊断色带」后，键盘顶部会出现一条
        //    渐变彩条。看到它 = 插件一路活到了「玻璃层已插入并绘制」；
        //    看不到它 = 插件没注入 / 锚点没命中 / 宿主没找到。一眼定性。
        _dbgBar = [CAGradientLayer layer];
        _dbgBar.colors = @[
            (id)[UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:0.95].CGColor,
            (id)[UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:0.95].CGColor,
            (id)[UIColor colorWithRed:0.2 green:0.9 blue:0.3 alpha:0.95].CGColor,
        ];
        _dbgBar.startPoint = CGPointMake(0, 0.5);
        _dbgBar.endPoint   = CGPointMake(1, 0.5);
        [self.layer addSublayer:_dbgBar];

        [self refreshAppearance];
    }
    return self;
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];
    [self _layoutLayers];
}

- (void)_layoutLayers {
    CGRect b = self.bounds;
    CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0) return;

    CGFloat edge = self._edgeAmount;

    // ⭐ backdrop 向外扩 edge pt：边缘被裁掉的部分就是「折射进来的内容」
    if (_backdropOK) {
        _backdrop.frame = UIEdgeInsetsInsetRect(b, UIEdgeInsetsMake(-edge, -edge, -edge, -edge));
    } else {
        _blurView.frame = b;
    }

    CGFloat bandW = self._edgeBandWidth;

    _tint.frame = b;
    _glow.frame = CGRectMake(0, 0, w, h * 0.45);
    _edgeTop.frame    = CGRectMake(0, 0, w, bandW);
    _edgeBottom.frame = CGRectMake(0, h - bandW, w, bandW);
    _edgeLeft.frame   = CGRectMake(0, 0, bandW, h);
    _edgeRight.frame  = CGRectMake(w - bandW, 0, bandW, h);
    _rim.frame = CGRectInset(b, 0.5, 0.5);

    // 诊断色带：贴着顶部，高 6pt
    BOOL dbg = WXGBool(@"debugBanner", NO);
    _dbgBar.hidden = !dbg;
    if (dbg) _dbgBar.frame = CGRectMake(0, 0, w, 6.0);
}

// 折射量（pt）→ backdrop 外扩尺寸 + zoomBlur 强度
- (CGFloat)_edgeAmount {
    CGFloat e = MAX(0.0, MIN(30.0, WXGCGFloat(@"edgeRefraction", 12.0)));
    return e;
}

// 亮带宽度（视觉上的「玻璃边厚度」）
- (CGFloat)_edgeBandWidth {
    CGFloat e = self._edgeAmount;
    if (e <= 0.01) return 0;
    return MAX(1.5, MIN(24.0, e));
}

- (UIColor *)_tintColorForStyle:(UIUserInterfaceStyle)style {
    CGFloat base = MAX(0.0, MIN(1.0, WXGCGFloat(@"baseColor", 0.25)));
    BOOL dark = (style == UIUserInterfaceStyleDark);
    if (dark) return [UIColor colorWithWhite:0.04 alpha:base];
    return [UIColor colorWithWhite:1.0 alpha:base * 0.85];
}

#pragma mark - 外观（参数变化 / 深浅模式切换时调用）

- (void)refreshAppearance {
    CGFloat glow = MAX(0.0, MIN(1.0, WXGCGFloat(@"glowStrength", 0.6)));
    CGFloat edge = self._edgeAmount;
    CGFloat blur = MAX(0.0, MIN(60.0, WXGCGFloat(@"blurRadius", 20.0)));
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;

    // ---- 1. 背景（B：真模糊+真折射 / A：系统材质）----
    if (_backdropOK) {
        NSMutableArray *filters = [NSMutableArray array];

        id blurF = WXGNewFilter(@"gaussianBlur");
        if (blurF) {
            [blurF setValue:@(MAX(0.5, blur)) forKey:@"inputRadius"];
            [filters addObject:blurF];
        }

        // zoomBlur = 折射本体：backdrop 外扩 + 内容向中心缩拢 → 边缘透镜扭曲
        if (edge > 0.01) {
            id zoomF = WXGNewFilter(@"zoomBlur");
            if (zoomF) {
                [zoomF setValue:@(edge * 0.8) forKey:@"inputAmount"];
                [zoomF setValue:[NSValue valueWithCGPoint:CGPointMake(0.5, 0.5)]
                         forKey:@"inputCenter"];
                [filters addObject:zoomF];
            }
        }

        // CALayer.filters 是私有属性 —— 用 KVC 设，避免链接符号
        [_backdrop setValue:(filters.count == 0 ? nil : filters) forKey:@"filters"];
    } else {
        // 路线 A：UIBlurEffect 档位映射
        // （blur<2 时用 UltraThin + alpha=0 等效关闭；UIBlurEffectStyleClear 在部分 SDK 头里未暴露）
        UIBlurEffectStyle bs;
        if (blur < 8) {
            bs = dark ? UIBlurEffectStyleSystemUltraThinMaterialDark
                      : UIBlurEffectStyleSystemUltraThinMaterialLight;
        } else if (blur < 20) {
            bs = dark ? UIBlurEffectStyleSystemThinMaterialDark
                      : UIBlurEffectStyleSystemThinMaterialLight;
        } else if (blur < 40) {
            bs = dark ? UIBlurEffectStyleSystemMaterialDark
                      : UIBlurEffectStyleSystemMaterialLight;
        } else {
            bs = dark ? UIBlurEffectStyleSystemThickMaterialDark
                      : UIBlurEffectStyleSystemThickMaterialLight;
        }
        _blurView.effect = nil;
        _blurView.effect = [UIBlurEffect effectWithStyle:bs];
        _blurView.alpha = blur < 2 ? 0.0 : 1.0;
    }

    // ---- 2. 底色 ----
    _tint.backgroundColor = [self _tintColorForStyle:self.traitCollection.userInterfaceStyle].CGColor;

    // ---- 3. 顶部高光 ----
    CGFloat gA = glow * (dark ? 0.30 : 0.42);
    _glow.colors = @[
        (id)[[UIColor colorWithWhite:1.0 alpha:gA] CGColor],
        (id)[[UIColor colorWithWhite:1.0 alpha:gA * 0.35] CGColor],
        (id)[[UIColor colorWithWhite:1.0 alpha:0.0] CGColor]
    ];
    _glow.locations = @[@0.0, @0.55, @1.0];

    // ---- 4. 边缘折射亮带 ----
    CGFloat bandW = self._edgeBandWidth;
    BOOL showEdge = (bandW > 0.5);
    CGFloat eA = showEdge ? (dark ? 0.20 : 0.34) : 0.0;
    CGFloat eA2 = eA * 0.45;

    void (^setBand)(CAGradientLayer *, NSArray *, NSArray *) =
        ^(CAGradientLayer *l, NSArray *colors, NSArray *locs) {
            l.colors = colors;
            l.locations = locs;
            l.hidden = !showEdge;
        };

    setBand(_edgeTop, @[
        (id)[[UIColor colorWithWhite:1.0 alpha:eA] CGColor],
        (id)[[UIColor colorWithWhite:1.0 alpha:eA2] CGColor],
        (id)[[UIColor colorWithWhite:1.0 alpha:0.0] CGColor]
    ], @[@0.0, @0.5, @1.0]);

    setBand(_edgeBottom, @[
        (id)[[UIColor colorWithWhite:1.0 alpha:0.0] CGColor],
        (id)[[UIColor colorWithWhite:1.0 alpha:eA2] CGColor],
        (id)[[UIColor colorWithWhite:1.0 alpha:eA] CGColor]
    ], @[@0.0, @0.5, @1.0]);

    _edgeLeft.type = kCAGradientLayerRadial;
    _edgeLeft.startPoint = CGPointMake(0.0, 0.5);
    _edgeLeft.endPoint   = CGPointMake(1.0, 0.5);
    setBand(_edgeLeft, @[
        (id)[[UIColor colorWithWhite:1.0 alpha:eA] CGColor],
        (id)[[UIColor colorWithWhite:1.0 alpha:eA2] CGColor],
        (id)[[UIColor colorWithWhite:1.0 alpha:0.0] CGColor]
    ], @[@0.0, @0.5, @1.0]);

    _edgeRight.type = kCAGradientLayerRadial;
    _edgeRight.startPoint = CGPointMake(1.0, 0.5);
    _edgeRight.endPoint   = CGPointMake(0.0, 0.5);
    setBand(_edgeRight, @[
        (id)[[UIColor colorWithWhite:1.0 alpha:eA] CGColor],
        (id)[[UIColor colorWithWhite:1.0 alpha:eA2] CGColor],
        (id)[[UIColor colorWithWhite:1.0 alpha:0.0] CGColor]
    ], @[@0.0, @0.5, @1.0]);

    // ---- 5. 内描边 ----
    _rim.hidden = !showEdge;
    _rim.borderWidth = showEdge ? 1.0 : 0.0;
    _rim.borderColor = [[UIColor colorWithWhite:1.0
                                          alpha:showEdge ? (dark ? 0.22 : 0.40) : 0.0] CGColor];
}

// 深浅模式切换自动跟随（对标 KBStyle 的 traitCollectionDidChange:）
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        // ⭐ 正确选择器名是 hasDifferentColorAppearanceComparedToTraitCollection:
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self refreshAppearance];
            [self _layoutLayers];
        }
    }
}

@end
