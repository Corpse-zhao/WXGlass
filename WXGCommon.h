#ifndef WXG_COMMON_H
#define WXG_COMMON_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 单一版本号来源 —— 所有展示/日志都必须引用它，不许手写第二份
#define WXG_VERSION @"0.1.0"

// 偏好域
#define WXG_PREFS_DOMAIN @"com.banliren.wxglass"

// 探针文件（Filza 友好路径）
#define WXG_PROBE_PATH @"/var/mobile/Documents/WXGlass/wxg_probe.txt"

#ifdef __cplusplus
extern "C" {
#endif

// ---- 配置读取 ----
CGFloat WXGCGFloat(NSString *key, CGFloat def);
BOOL    WXGBool(NSString *key, BOOL def);
void    WXGSetValue(NSString *key, id value);

// ---- 日志 ----
// 进程名 + pid 前缀，便于区分宿主进程 / 键盘扩展进程
void WXGLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
// 只写文件不写 NSLog（避免污染日志），供高频路径使用
void WXGLogQuiet(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

// ---- 进程判定 ----
BOOL WXGIsWeChatProcess(void);
NSString *WXGProcessName(void);

// ---- 探针 ----
void WXGProbeWrite(NSString *line);
NSString *WXGProbeRead(void);
BOOL WXGProbeClear(void);
NSString *WXGProbePathForSummary(void);

#ifdef __cplusplus
}
#endif

#endif /* WXG_COMMON_H */
