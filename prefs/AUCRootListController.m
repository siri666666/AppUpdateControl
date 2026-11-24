#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <dlfcn.h>
#import "ATLApplicationListSubcontrollerController.h"
#import "ATLApplicationListSubcontroller.h"
#import "../AUCPrefs.h"

@interface PSSpecifier (AUCSegment)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

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

@interface AUCAppDetailController : ATLApplicationListSubcontroller
@end

@implementation AUCAppDetailController

- (NSString *)aucTargetBundleID {
    NSString *bid = nil;
    if ([self respondsToSelector:@selector(applicationID)]) {
        bid = [self applicationID];
    }
    if (!bid.length) {
        bid = [self.specifier propertyForKey:@"applicationIdentifier"];
    }
    return bid ?: @"";
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"更新策略"
            target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:@"跟随默认：使用外层默认策略\n自动更新：允许 App Store 后台自动更新\n仅手动：阻止后台自动更新，保留手动点击更新\n禁用：屏蔽自动/手动/全部更新，并从更新列表隐藏"
                    forKey:@"footerText"];
        [specs addObject:group];

        PSSpecifier *seg = [PSSpecifier preferenceSpecifierNamed:@"更新模式"
            target:self
            set:@selector(setAppMode:specifier:)
            get:@selector(getAppMode:)
            detail:nil
            cell:PSSegmentCell
            edit:nil];
        [seg setValues:@[@(-1), @(0), @(1), @(2)]
                titles:@[@"默认", @"自动", @"仅手动", @"禁用"]];
        [specs addObject:seg];

        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (id)getAppMode:(PSSpecifier *)specifier {
    return @(auc_mode_for_app([self aucTargetBundleID]));
}

- (void)setAppMode:(id)value specifier:(PSSpecifier *)specifier {
    NSInteger mode = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : AUCUpdateModeDefault;
    auc_set_mode_for_app([self aucTargetBundleID], mode);
}

@end

@interface AUCAppListController : ATLApplicationListSubcontrollerController
@end

@implementation AUCAppListController

- (NSString *)previewStringForApplicationWithIdentifier:(NSString *)applicationID {
    NSInteger mode = auc_mode_for_app(applicationID);
    if (mode == AUCUpdateModeAuto) return @"自动更新";
    if (mode == AUCUpdateModeManual) return @"仅手动";
    if (mode == AUCUpdateModeDisabled) return @"已禁用";
    return @"";
}

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
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openGitHub {
    NSURL *url = [NSURL URLWithString:@"https://github.com/siri666666/AppUpdateControl"];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end
