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
static NSString * const kDLPrefsVersion = @"0.2.0";

static NSString * const kWXGPrefsDomain = @"com.banliren.wxglass";
static NSString * const kWXGProbePath = @"/var/mobile/Documents/WXGlass/wxg_probe.txt";

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
        [g1 setProperty:kWXGProbePath forKey:@"footerText"];
        [specs addObject:g1];

        NSString *probe = [self _probeText];
        NSString *tail = [self _tailOf:probe lines:40];
        [specs addObject:[self _infoSpec:@"最近日志（末 40 行）"
                                   value:(tail.length ? tail : @"（空 —— 插件可能尚未在键盘进程运行过）")]];

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

- (PSSpecifier *)_infoSpec:(NSString *)label value:(NSString *)value {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:self
                                                       set:NULL
                                                       get:NULL
                                                    detail:nil
                                                      cell:PSStaticTextCell
                                                      edit:nil];
    [s setProperty:(value ?: @"—") forKey:@"value"];
    return s;
}

- (NSString *)_probeText {
    if (_cachedProbe) return _cachedProbe;
    NSString *raw = [NSString stringWithContentsOfFile:kWXGProbePath
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    _cachedProbe = raw ?: @"";
    return _cachedProbe;
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
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)clearProbe:(PSSpecifier *)sender {
    [[NSFileManager defaultManager] removeItemAtPath:kWXGProbePath error:NULL];
    _cachedProbe = nil;
    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
