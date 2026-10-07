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

static NSString *WXGBundleID(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cached = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    });
    return cached;
}

BOOL WXGIsWeChatProcess(void) {
    NSString *bid = WXGBundleID();
    if (!bid.length) return NO;
    return [bid hasPrefix:@"com.tencent.wetype"] ||
           [bid hasPrefix:@"com.tencent.xin"];
}

#pragma mark - 探针

// 512KB 封顶：超了就整份重写，不再 append 到天荒地老
static const unsigned long long kWXGProbeLimit = 512ULL * 1024ULL;

static void WXGEnsureProbeDir(void) {
    NSString *dir = [WXG_PROBE_PATH stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:NULL];
        // Filza 默认能看到即可，权限失败不致命
        [fm setAttributes:@{NSFilePosixPermissions: @(0777)} ofItemAtPath:dir error:NULL];
    }
}

void WXGProbeWrite(NSString *line) {
    if (!line) return;
    NSString *text = [line stringByAppendingString:@"\n"];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    WXGEnsureProbeDir();

    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long sz = [[fm attributesOfItemAtPath:WXG_PROBE_PATH error:NULL] fileSize];

    if (sz > kWXGProbeLimit) {
        // 超限：同时试「清空重写」
        [data writeToFile:WXG_PROBE_PATH atomically:YES];
        return;
    }

    if (![fm fileExistsAtPath:WXG_PROBE_PATH]) {
        [data writeToFile:WXG_PROBE_PATH atomically:YES];
        return;
    }

    NSFileHandle *h = [NSFileHandle fileHandleForUpdatingAtPath:WXG_PROBE_PATH];
    if (h) {
        [h seekToEndOfFile];
        [h writeData:data];
        [h closeFile];
    } else {
        [data writeToFile:WXG_PROBE_PATH atomically:YES];
    }
}

NSString *WXGProbeRead(void) {
    NSString *raw = [NSString stringWithContentsOfFile:WXG_PROBE_PATH
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    return raw ?: @"";
}

BOOL WXGProbeClear(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:WXG_PROBE_PATH]) {
        return [fm removeItemAtPath:WXG_PROBE_PATH error:NULL];
    }
    return YES;
}

NSString *WXGProbePathForSummary(void) {
    return WXG_PROBE_PATH;
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
