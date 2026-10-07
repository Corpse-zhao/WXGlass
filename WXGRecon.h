#ifndef WXG_RECON_H
#define WXG_RECON_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 运行时枚举当前进程所有类，把「像键盘背景/键面」的类名列出来。
/// 只观察、不改写、不挂钩 —— 零风险。
/// 结果写进探针文件，供用户在 Filza 里查看 / 回传。
void WXGReconDumpKeyboardClasses(void);

/// 把当前所有窗口的视图树（限深）转成文本，写进探针。
/// 用来确认「我们要加玻璃的那一层到底叫什么」。
void WXGReconDumpKeyWindowTree(void);

/// 检查一批候选类名是否真实存在，并把结果写进探针。
/// 替代「硬编码类名」—— 让日志自证钩子挂得上还是挂不上。
void WXGReconCheckCandidates(NSArray<NSString *> *names);

/// 玻璃能力探测（路线 B 前置条件）：
/// CABackdropLayer / CAFilter(gaussianBlur, zoomBlur) 是否可用。
/// 结果写探针 —— 与 WXGGlassView 的自动降级互相印证。
void WXGReconProbeGlassCapabilities(void);

#ifdef __cplusplus
}
#endif

#endif /* WXG_RECON_H */
