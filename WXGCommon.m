#import "WXGCommon.h"
#import <unistd.h>
#import <stdlib.h>

#pragma mark - 配置读取

CGFloat WXGCGFloat(NSString *key, CGFloat def) {
    CFNumberRef n = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                              (__bridge CFStringRef)WXG_PREFS_DOMAIN);
    CGFloat v = def;
    if (n) {
        if (CFGetTypeID(n) == CFNumberGetTypeID()) {
            CFNumberGetValue(n, kCFNumberCGFloatType, &v);
        }
        CFRelease(n);
    }
    return v;
}

BOOL WXGBool(NSString *key, BOOL def) {
    CFBooleanRef b = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                               (__bridge CFStringRef)WXG_PREFS_DOMAIN);
    BOOL v = def;
    if (b) {
        if (CFGetTypeID(b) == CFBooleanGetTypeID()) {
            v = CFBooleanGetValue(b);
        } else if (CFGetTypeID(b) == CFNumberGetTypeID()) {
            int tmp = 0;
            CFNumberGetValue((CFNumberRef)b, kCFNumberIntType, &tmp);   // ⭐ CFBooleanRef→CFNumberRef 需显式强转（ARC 硬约束）
            v = (tmp != 0);
        }
        CFRelease(b);
    }
    return v;
}

void WXGSetValue(NSString *key, id value) {
    if (!key) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)WXG_PREFS_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)WXG_PREFS_DOMAIN);
}

#pragma mark - 进程判定

NSString *WXGProcessName(void) {
    return [NSProcessInfo processInfo].processName ?: @"?";
}

NSString *WXGBundleIDString(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cached = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    });
    return cached;
}

// ⭐ v0.2.0 放宽判定：不再只认 bundleID 前缀。
//  血泪：第三方键盘在 iOS 上是 **app extension 进程**，且不同 iOS 版本下
//  mainBundle 可能是宿主 App、extension、或一个临时容器，前缀判定会漏 →
//  表现就是「装了完全没反应」，与「没装」无法区分。
//  改为「bundleID / 进程名 关键词命中」：
//    · com.tencent.wetype          微信输入法主 App
//    · com.tencent.wetype.keyboard 键盘扩展
//    · com.tencent.xin             微信
//    · 进程名含 WeType / wetype / WXGKeyboard
static BOOL WXGNameLooksLikeTarget(NSString *s) {
    if (!s.length) return NO;
    NSString *low = s.lowercaseString;
    if ([low containsString:@"wetype"]) return YES;
    if ([low containsString:@"wemix"]) return YES;
    if ([low containsString:@"tencent.xin"]) return YES;
    if ([low containsString:@"tencent.wx"]) return YES;
    return NO;
}

BOOL WXGIsWeChatProcess(void) {
    if (WXGNameLooksLikeTarget(WXGBundleIDString())) return YES;
    if (WXGNameLooksLikeTarget(WXGProcessName())) return YES;
    // 进程可执行路径兜底（扩展容器路径里常含 WeType）
    static NSString *exe = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exe = [[[NSBundle mainBundle] executablePath] copy] ?: @"";
    });
    if (WXGNameLooksLikeTarget(exe)) return YES;
    return NO;
}

// ⭐ force 开关：设置里打开后，无论进程是否命中都强行介入。
//   用途只有一个 —— 排查「插件到底有没有被注入到这个进程」。
//   注入成功但进程判定漏了 → 打开 force 立刻能看到玻璃/横幅；
//   打开了还是毫无变化 → 说明 **根本没注入**，问题在打包/过滤清单层。
BOOL WXGShouldIntervene(void) {
    if (WXGBool(@"enabled", YES) == NO) return NO;
    if (WXGBool(@"forceAll", NO)) return YES;
    return WXGIsWeChatProcess();
}

#pragma mark - 探针

// 512KB 封顶：超了就整份重写，不再 append 到天荒地老
static const unsigned long long kWXGProbeLimit = 512ULL * 1024ULL;

// ⭐ v0.2.0：候选探针路径（按可写性依次尝试）。
//  键盘扩展是沙盒进程，/var/mobile/Documents 常常**不可写**；
//  只写一条路径会导致「插件明明活着，探针却空白」——
//  而空白与「没注入」无法区分，是上一轮定位失败的根本原因。
static NSArray<NSString *> *WXGProbeCandidates(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    // 1) 首选：全局 Documents（越狱环境通常可写，Filza 好找）
    [paths addObject:WXG_PROBE_PATH];
    // 2) 备选：/var/mobile/Library（扩展沙盒外，权限更宽松）
    [paths addObject:[WXG_PROBE_FALLBACK_DIR stringByAppendingPathComponent:@"wxg_probe.txt"]];
    // 3) 兜底：进程自己的沙盒（一定可写，但要用 Filza 找到容器）
    NSString *home = NSHomeDirectory();
    if (home.length) {
        [paths addObject:[home stringByAppendingPathComponent:@"Documents/wxg_probe.txt"]];
        [paths addObject:[home stringByAppendingPathComponent:@"tmp/wxg_probe.txt"]];
    }
    return paths;
}

// 找到第一个「可写」的路径并缓存；全部不可写则返回 nil
static NSString *WXGProbeResolvedPath(void) {
    static NSString *resolved = nil;
    static BOOL tried = NO;
    if (tried) return resolved;
    tried = YES;

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in WXGProbeCandidates()) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir
          withIntermediateDirectories:YES
                           attributes:nil
                                error:NULL];
            [fm setAttributes:@{NSFilePosixPermissions: @(0777)}
                  ofItemAtPath:dir error:NULL];
        }
        // 已存在 → 直接可用
        if ([fm fileExistsAtPath:p]) { resolved = p; break; }
        // 不存在 → 试着创建一个空文件，成功即认为可写
        if ([fm createFileAtPath:p contents:[NSData data] attributes:nil]) {
            resolved = p; break;
        }
    }
    return resolved;
}

void WXGProbeWrite(NSString *line) {
    if (!line) return;
    NSString *path = WXGProbeResolvedPath();
    if (!path) return;   // 全路径都不可写（极少见），静默放弃，绝不崩

    NSString *text = [line stringByAppendingString:@"\n"];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long sz = [[fm attributesOfItemAtPath:path error:NULL] fileSize];

    if (sz > kWXGProbeLimit || ![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *h = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (h) {
        [h seekToEndOfFile];
        [h writeData:data];
        [h closeFile];
    } else {
        [data writeToFile:path atomically:YES];
    }
}

// 汇总读：把所有候选里存在的内容拼起来，方便用户一次看全
NSString *WXGProbeRead(void) {
    NSMutableString *all = [NSMutableString string];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in WXGProbeCandidates()) {
        if (![fm fileExistsAtPath:p]) continue;
        NSString *raw = [NSString stringWithContentsOfFile:p
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        if (!raw.length) continue;
        [all appendFormat:@"\n===== %@ =====\n%@", p, raw];
    }
    return all;
}

BOOL WXGProbeClear(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL allOK = YES;
    for (NSString *p in WXGProbeCandidates()) {
        if ([fm fileExistsAtPath:p]) {
            if (![fm removeItemAtPath:p error:NULL]) allOK = NO;
        }
    }
    return allOK;
}

NSString *WXGProbePathForSummary(void) {
    NSString *p = WXGProbeResolvedPath();
    return p ?: @"（无任何可写路径！）";
}

#pragma mark - 日志

void WXGLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!body) return;

    NSString *line = [NSString stringWithFormat:@"[%@][%@ pid=%d] %@",
                      [NSDate date], WXGProcessName(), (int)getpid(), body];
    NSLog(@"[WXGlass] %@", body);
    WXGProbeWrite(line);
}

void WXGLogQuiet(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!body) return;

    NSString *line = [NSString stringWithFormat:@"[%@][%@ pid=%d] %@",
                      [NSDate date], WXGProcessName(), (int)getpid(), body];
    WXGProbeWrite(line);
}
