#import <Preferences/Preferences.h>
#import <Foundation/Foundation.h>

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
@end
