#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <dlfcn.h>
#import "ATLApplicationListMultiSelectionController.h"
#import "../AUCPrefs.h"

static NSString *auc_root_path(NSString *path) {
    typedef const char *(*jbroot_fn)(const char *);
    jbroot_fn fn = (jbroot_fn)dlsym(RTLD_DEFAULT, "jbroot");
    if (fn) {
        const char *resolved = fn(path.UTF8String);
        if (resolved) return [NSString stringWithUTF8String:resolved];
    }
    NSString *jbPath = [@"/var/jb" stringByAppendingString:path];
    if ([[NSFileManager defaultManager] fileExistsAtPath:jbPath]) return jbPath;
    return path;
}

static NSDictionary *auc_app_modes_dict(void) {
    id val = auc_cf_get(@"appModes");
    return [val isKindOfClass:[NSDictionary class]] ? val : @{};
}

static NSInteger auc_mode_for_app(NSString *bundleID) {
    if (!bundleID.length) return AUCUpdateModeDefault;
    NSNumber *v = auc_app_modes_dict()[bundleID];
    if ([v respondsToSelector:@selector(integerValue)]) {
        NSInteger m = [v integerValue];
        if (m >= AUCUpdateModeAuto && m <= AUCUpdateModeDisabled) return m;
    }
    return AUCUpdateModeDefault;
}

static void auc_set_mode_for_app(NSString *bundleID, NSInteger mode) {
    if (!bundleID.length) return;
    NSMutableDictionary *m = [auc_app_modes_dict() mutableCopy];
    if (mode < AUCUpdateModeAuto || mode > AUCUpdateModeDisabled) {
        [m removeObjectForKey:bundleID];
    } else {
        m[bundleID] = @(mode);
    }
    auc_cf_set(@"appModes", [m copy]);
    auc_post_saved_notification();
}

static NSUInteger auc_count_for_mode(NSInteger mode) {
    NSDictionary *dict = auc_app_modes_dict();
    NSUInteger count = 0;
    for (NSString *k in dict) {
        id v = dict[k];
        if ([v respondsToSelector:@selector(integerValue)] && [v integerValue] == mode) {
            count++;
        }
    }
    return count;
}

@interface AUCModeSwitchListController : ATLApplicationListMultiSelectionController
- (AUCUpdateMode)targetMode;
@end

@implementation AUCModeSwitchListController

- (AUCUpdateMode)targetMode {
    return AUCUpdateModeAuto;
}

- (void)loadPreferences {
    _defaultApplicationSwitchValue = NO;
    NSMutableSet *selected = [NSMutableSet set];
    NSDictionary *dict = auc_app_modes_dict();
    AUCUpdateMode target = [self targetMode];
    for (NSString *bid in dict) {
        id v = dict[bid];
        if ([v respondsToSelector:@selector(integerValue)] && [v integerValue] == target) {
            [selected addObject:bid];
        }
    }
    _selectedApplications = selected;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadPreferences];
    [self reloadSpecifiers];
}

- (id)readApplicationEnabled:(PSSpecifier *)specifier {
    NSString *bid = [specifier propertyForKey:@"applicationIdentifier"];
    if (!bid.length) return @NO;
    return @(auc_mode_for_app(bid) == [self targetMode]);
}

- (void)setApplicationEnabled:(NSNumber *)enabledNum specifier:(PSSpecifier *)specifier {
    NSString *bid = [specifier propertyForKey:@"applicationIdentifier"];
    if (!bid.length) return;
    BOOL enabled = [enabledNum boolValue];
    AUCUpdateMode target = [self targetMode];
    if (enabled) {
        [_selectedApplications addObject:bid];
        auc_set_mode_for_app(bid, target);
    } else {
        [_selectedApplications removeObject:bid];
        if (auc_mode_for_app(bid) == target) {
            auc_set_mode_for_app(bid, AUCUpdateModeDefault);
        }
    }
}

@end

@interface AUCAutoListController : AUCModeSwitchListController
@end
@implementation AUCAutoListController
- (AUCUpdateMode)targetMode { return AUCUpdateModeAuto; }
@end

@interface AUCManualListController : AUCModeSwitchListController
@end
@implementation AUCManualListController
- (AUCUpdateMode)targetMode { return AUCUpdateModeManual; }
@end

@interface AUCDisabledListController : AUCModeSwitchListController
@end
@implementation AUCDisabledListController
- (AUCUpdateMode)targetMode { return AUCUpdateModeDisabled; }
@end

@interface AUCRootListController : PSListController
@end

@implementation AUCRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (NSString *)getAutoCount:(PSSpecifier *)specifier {
    NSUInteger c = auc_count_for_mode(AUCUpdateModeAuto);
    return c > 0 ? [NSString stringWithFormat:@"%lu 项", (unsigned long)c] : @"0 项";
}

- (NSString *)getManualCount:(PSSpecifier *)specifier {
    NSUInteger c = auc_count_for_mode(AUCUpdateModeManual);
    return c > 0 ? [NSString stringWithFormat:@"%lu 项", (unsigned long)c] : @"0 项";
}

- (NSString *)getDisabledCount:(PSSpecifier *)specifier {
    NSUInteger c = auc_count_for_mode(AUCUpdateModeDisabled);
    return c > 0 ? [NSString stringWithFormat:@"%lu 项", (unsigned long)c] : @"0 项";
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return [super readPreferenceValue:specifier];
    id val = auc_cf_get(key);
    if (val != nil) return val;
    return [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key) {
        auc_cf_set(key, value);
        auc_post_saved_notification();
    } else {
        [super setPreferenceValue:value specifier:specifier];
    }
}

- (void)restartAppStoreDaemon {
    pid_t pid;
    NSString *killall = auc_root_path(@"/usr/bin/killall");
    const char *args[] = { "killall", "appstored", NULL };
    posix_spawn(&pid, killall.UTF8String, NULL, NULL, (char * const *)args, NULL);

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"已发送重启指令"
                       message:@"appstored 会在后台自动拉起，重新打开 App Store 下拉刷新即可看到最新更新状态。"
                preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearAllRules {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"清空单应用规则"
                       message:@"确定清除所有已配置的单个 App 更新规则（恢复跟随默认）吗？"
                preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认清空"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        auc_cf_set(@"appModes", @{});
        auc_post_saved_notification();
        [self reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openGitHub {
    NSURL *url = [NSURL URLWithString:@"https://github.com/siri666666/AppUpdateControl"];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end
