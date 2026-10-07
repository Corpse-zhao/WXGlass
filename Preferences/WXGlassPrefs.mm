#import <Preferences/Preferences.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ============================================================
//  WXGlass 设置面板
//
//  ⚠️ 本 bundle 是独立的进程（Settings.app），
//     **不加载 tweak 的 dylib**，所以绝不能引用 WXGCommon.h 里的
//     任何符号（WXG_VERSION / WXGLog / WXGProbeRead …）。
//     一旦引用 → bundle 链接失败 或 运行时符号缺失闪退。
//     版本号必须在设置侧独立定义一份，再与探针文件的内容比对。
// ============================================================

// 设置侧版本（必须与 Tweak 侧 WXG_VERSION 手工保持一致）
static NSString * const kDLPrefsVersion = @"0.2.1";

static NSString * const kWXGPrefsDomain = @"com.banliren.wxglass";
static NSString * const kWXGProbePath = @"/var/mobile/Documents/WXGlass/wxg_probe.txt";

// ⭐ v0.2.1：探针是**多路径兜底**写入的（键盘是沙盒 app extension，
//   /var/mobile/Documents 很可能没有写权限 —— 这正是此前「探针没数据」的根因）。
//   设置侧必须把**所有**候选路径都读一遍，否则永远显示空白。
static NSArray<NSString *> *WXGProbePaths(void) {
    NSMutableArray *a = [NSMutableArray array];
    [a addObject:@"/var/mobile/Documents/WXGlass/wxg_probe.txt"];
    [a addObject:@"/var/mobile/Library/WXGlass/wxg_probe.txt"];
    NSString *home = NSHomeDirectory();
    if (home.length) {
        [a addObject:[home stringByAppendingPathComponent:@"Documents/wxg_probe.txt"]];
        [a addObject:[home stringByAppendingPathComponent:@"tmp/wxg_probe.txt"]];
    }
    return a;
}

#pragma mark - 主设置控制器

@interface WXGlassPrefsListController : PSListController
@end

@implementation WXGlassPrefsListController

- (id)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Settings" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = @"液态玻璃键盘";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 回到本页时刷新（诊断页可能改过状态）
    [self reloadSpecifiers];
}

@end

#pragma mark - 诊断控制器（版本自检 = 判断「插件到底加载没加载」）

@interface WXGlassDiagController : PSListController
@end

@implementation WXGlassDiagController {
    NSString *_cachedProbe;
    NSString *_cachedProbeSource;
}

- (id)specifiers {
    if (_specifiers == nil) {
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *g0 = [PSSpecifier groupSpecifierWithName:@"版本自检"];
        [g0 setProperty:@"设置侧版本来自 Preferences bundle；键盘进程版本来自探针文件（由插件本体写入）。两者一致 = 插件已加载到微信输入法进程。"
                  forKey:@"footerText"];
        [specs addObject:g0];

        [specs addObject:[self _infoSpec:@"设置面板版本" value:kDLPrefsVersion]];
        [specs addObject:[self _infoSpec:@"键盘进程版本" value:[self _keyboardVersion]]];
        [specs addObject:[self _infoSpec:@"判定" value:[self _verdict]]];

        PSSpecifier *g1 = [PSSpecifier groupSpecifierWithName:@"探针文件"];
        // footer 显示**实际读到的那一个**路径（多路径兜底，读到哪个显示哪个）
        [g1 setProperty:[self _probeSource] forKey:@"footerText"];
        [specs addObject:g1];

        NSString *probe = [self _probeText];
        NSString *tail = [self _tailOf:probe lines:40];
        [specs addObject:[self _infoSpec:@"最近日志（末 40 行）"
                                   value:(tail.length ? tail : @"（空 —— 插件可能尚未在键盘进程运行过）")]];

        // ⭐ v0.2.1：关键诊断指标，单独成组，一眼看出卡在哪一环
        PSSpecifier *g3 = [PSSpecifier groupSpecifierWithName:@"关键指标"];
        [g3 setProperty:@"hook 命中 0 次 = hook 根本没生效（最常见原因：%ctor 里漏了 %init）。"
                  forKey:@"footerText"];
        [specs addObject:g3];
        [specs addObject:[self _infoSpec:@"进程命中" value:[self _extractAfter:@"processHit = " upTo:@" " fallback:@"（无）"]]];
        [specs addObject:[self _infoSpec:@"WBMainInputView" value:[self _extractAfter:@"WBMainInputView存在=" upTo:@"\n" fallback:@"（无）"]]];
        [specs addObject:[self _infoSpec:@"hook 命中次数" value:[self _extractAfter:@"🔎 hook 自检：4s 内命中 " upTo:@" 次" fallback:@"（无）"]]];

        PSSpecifier *g2 = [PSSpecifier groupSpecifierWithName:@"操作"];
        [g2 setProperty:@"刷新会重新读取探针文件；清空会删除探针，下次键盘弹出时重新写入。"
                  forKey:@"footerText"];
        [specs addObject:g2];

        PSSpecifier *refresh = [PSSpecifier preferenceSpecifierNamed:@"刷新"
                                                              target:self
                                                                 set:NULL
                                                                 get:NULL
                                                              detail:nil
                                                                cell:PSButtonCell
                                                                edit:nil];
        [refresh setProperty:@"refreshProbe:" forKey:@"action"];
        [specs addObject:refresh];

        PSSpecifier *clear = [PSSpecifier preferenceSpecifierNamed:@"清空探针文件"
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                            detail:nil
                                                              cell:PSButtonCell
                                                              edit:nil];
        [clear setProperty:@"clearProbe:" forKey:@"action"];
        [clear setProperty:@(1) forKey:@"isDestructive"];
        [specs addObject:clear];

        _specifiers = specs;
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = @"运行状态自检";
}

#pragma mark - 辅助

// ⭐⭐ v0.2.1 关键修复：PSStaticTextCell 在 iOS 16 上**只 setProperty:forKey:@"value" 不显示**。
//   用户截图证实三个字段全空白。三保险同时上：
//   ① setProperty:forKey:@"value"         —— 连 cell 自己的 value 属性
//   ② setProperty:forKey:@"valueGetter"   —— iOS 16 部分版本改读这个 key
//   ③ cell 直接塞 detailTextLabel          —— cellForSpecifier 兜底
//   ④ 兜底把值拼进 name                   —— 即使前三条全失效，用户仍能看到
- (PSSpecifier *)_infoSpec:(NSString *)label value:(NSString *)value {
    NSString *v = (value.length ? value : @"—");
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:self
                                                       set:NULL
                                                       get:NULL
                                                    detail:nil
                                                      cell:PSStaticTextCell
                                                      edit:nil];
    [s setProperty:v forKey:@"value"];
    [s setProperty:v forKey:@"valueGetter"];
    [s setProperty:v forKey:@"detail"];
    // 兜底：值直接进 name（多行日志会很长，但至少不是一片空白）
    if (v.length <= 60 && ![v containsString:@"\n"]) {
        s.name = [NSString stringWithFormat:@"%@：%@", label, v];
    }
    return s;
}

- (NSString *)_probeText {
    if (_cachedProbe) return _cachedProbe;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *chunks = [NSMutableArray array];
    NSMutableArray *hits = [NSMutableArray array];
    for (NSString *p in WXGProbePaths()) {
        if (![fm fileExistsAtPath:p]) continue;
        NSString *raw = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
        if (!raw.length) continue;
        [hits addObject:p];
        [chunks addObject:raw];
    }
    _cachedProbeSource = hits.count ? [hits componentsJoinedByString:@"\n"] : @"（四个候选路径都没有探针文件）";
    _cachedProbe = chunks.count ? [chunks componentsJoinedByString:@"\n"] : @"";
    return _cachedProbe;
}

- (NSString *)_probeSource {
    if (!_cachedProbe) (void)[self _probeText];   // 触发一次读取
    return _cachedProbeSource ?: @"（未读取）";
}

// 从探针文本里抽出某个字段后面的值
- (NSString *)_extractAfter:(NSString *)key upTo:(NSString *)terminator fallback:(NSString *)fb {
    NSString *probe = [self _probeText];
    if (!probe.length) return fb;
    NSRange r = [probe rangeOfString:key];
    if (r.location == NSNotFound) return fb;
    NSString *rest = [probe substringFromIndex:NSMaxRange(r)];
    NSRange end = [rest rangeOfString:terminator];
    NSString *val = (end.location == NSNotFound) ? rest : [rest substringToIndex:end.location];
    val = [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return val.length ? val : fb;
}

- (NSString *)_tailOf:(NSString *)text lines:(NSInteger)n {
    if (!text.length) return @"";
    NSArray *all = [text componentsSeparatedByString:@"\n"];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *l in all) {
        if (l.length) [keep addObject:l];
    }
    if ((NSInteger)keep.count <= n) return [keep componentsJoinedByString:@"\n"];
    NSArray *sub = [keep subarrayWithRange:NSMakeRange(keep.count - n, n)];
    return [sub componentsJoinedByString:@"\n"];
}

// 从探针里找插件本体的启动横幅，抽出其中的版本号
- (NSString *)_keyboardVersion {
    NSString *probe = [self _probeText];
    if (!probe.length) return @"（未检测到）";

    __block NSString *found = nil;
    [probe enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        // 匹配形如： WXGlass 0.2.0 启动
        NSRange r = [line rangeOfString:@"WXGlass "];
        if (r.location == NSNotFound) return;
        NSString *rest = [line substringFromIndex:r.location + r.length];
        NSRange end = [rest rangeOfString:@" 启动"];
        if (end.location == NSNotFound) return;
        found = [rest substringToIndex:end.location];
        *stop = YES;
    }];
    return found ?: @"（未检测到）";
}

- (NSString *)_verdict {
    NSString *kv = [self _keyboardVersion];
    if ([kv isEqualToString:@"（未检测到）"]) {
        return @"❌ 插件本体未在键盘进程运行 —— 请确认已安装并重开输入法";
    }
    if ([kv isEqualToString:kDLPrefsVersion]) {
        return @"✅ 一致，插件已加载";
    }
    return [NSString stringWithFormat:@"⚠️ 版本不一致（设置 %@ / 本体 %@）—— 请重新安装 deb",
            kDLPrefsVersion, kv];
}

#pragma mark - 按钮

- (void)refreshProbe:(PSSpecifier *)sender {
    _cachedProbe = nil;
    _cachedProbeSource = nil;
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)clearProbe:(PSSpecifier *)sender {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in WXGProbePaths()) {   // ⭐ 多路径，全部清掉
        [fm removeItemAtPath:p error:NULL];
    }
    _cachedProbe = nil;
    _cachedProbeSource = nil;
    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
