#ifndef WXG_GLASS_VIEW_H
#define WXG_GLASS_VIEW_H

#import <UIKit/UIKit.h>

/// 液态玻璃层：半透明基底 + 顶部高光 + 边缘折射
/// userInteractionEnabled 恒为 NO —— 从机制上不可能挡触摸
@interface WXGGlassView : UIView

/// 按当前偏好重新应用外观（参数变了可再次调用）
- (void)refreshAppearance;

@end

#endif /* WXG_GLASS_VIEW_H */
