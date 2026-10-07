#ifndef WXG_COMMON_H
#define WXG_COMMON_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 单一版本号来源 —— 所有展示/日志都必须引用它，不许手写第二份
#define WXG_VERSION @"0.2.1"

// 偏好域
#define WXG_PREFS_DOMAIN @"com.banliren.wxglass"

// 探针文件（Filza 友好路径）
// ⭐ v0.2.0：键盘是**沙盒内的 app extension 进程**，很可能没有权限写
//   /var/mobile/Documents/。旧版只写这一条路径，「写失败」和「没注入」
//   在用户侧长得一模一样 → 无法定位。改为多路径依次尝试。
#define WXG_PROBE_PATH @"/var/mobile/Documents/WXGlass/wxg_probe.txt"
#define WXG_PROBE_FALLBACK_DIR @"/var/mobile/Library/WXGlass"

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
// ⭐ v0.2.0：放宽为「关键词命中」而非「bundleID 前缀」——键盘扩展进程的
//    mainBundle 可能是 extension bundle，前缀判定会漏。另提供 force 开关，
//    让用户在设置里手动放行，用于排查「到底注入没注入」。
BOOL WXGIsWeChatProcess(void);
BOOL WXGShouldIntervene(void);      // = 进程命中 或 force 开关打开
NSString *WXGProcessName(void);
NSString *WXGBundleIDString(void);  // 暴露 bundleID 供探针记录

// ---- 探针 ----
void WXGProbeWrite(NSString *line);
NSString *WXGProbeRead(void);
BOOL WXGProbeClear(void);
NSString *WXGProbePathForSummary(void);

#ifdef __cplusplus
}
#endif

#endif /* WXG_COMMON_H */
