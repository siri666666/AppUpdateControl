#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <dlfcn.h>
#import "ATLApplicationListControllerBase.h"
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

static AUCUpdateMode auc_mode_for_app(NSString *bundleID) {
    if (!bundleID.length) return AUCUpdateModeDisabled;
    NSNumber *v = auc_app_modes_dict()[bundleID];
    if ([v respondsToSelector:@selector(integerValue)]) {
        NSInteger m = [v integerValue];
        if (m == AUCUpdateModeAuto || m == AUCUpdateModeManual) return (AUCUpdateMode)m;
    }
    return AUCUpdateModeDisabled;
}

static void auc_set_mode_for_app(NSString *bundleID, AUCUpdateMode mode) {
    if (!bundleID.length) return;
    NSMutableDictionary *m = [auc_app_modes_dict() mutableCopy];
    if (mode == AUCUpdateModeAuto || mode == AUCUpdateModeManual) {
        m[bundleID] = @(mode);
    } else {
        [m removeObjectForKey:bundleID];
    }
    auc_cf_set(@"appModes", [m copy]);
    auc_post_saved_notification();
}

static NSUInteger auc_count_for_mode(AUCUpdateMode mode) {
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

@interface AUCUnifiedAppListController : ATLApplicationListControllerBase
@end

@implementation AUCUnifiedAppListController

- (void)viewDidLoad {
    self.alphabeticIndexingEnabled = NO;
    [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)animated {
    self.alphabeticIndexingEnabled = NO;
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (PSCellType)cellTypeForApplicationCells {
    return PSStaticTextCell;
}

- (SEL)getterForSpecifierOfApplicationProxy:(LSApplicationProxy *)applicationProxy {
    return @selector(readModeLabel:);
}

- (NSString *)readModeLabel:(PSSpecifier *)specifier {
    NSString *bid = [specifier propertyForKey:@"applicationIdentifier"];
    AUCUpdateMode mode = auc_mode_for_app(bid);
    if (mode == AUCUpdateModeAuto) return @"自动更新";
    if (mode == AUCUpdateModeManual) return @"仅手动";
    return @"禁用";
}

- (NSArray *)specifiers {
    self.alphabeticIndexingEnabled = NO;
    NSArray *base = [super specifiers];
    if (!base.count) return base;

    NSMutableArray *autoSpecs = [NSMutableArray array];
    NSMutableArray *manualSpecs = [NSMutableArray array];
    NSMutableArray *disabledSpecs = [NSMutableArray array];

    for (PSSpecifier *spec in base) {
        NSString *bid = [spec propertyForKey:@"applicationIdentifier"];
        if (!bid.length) continue;
        AUCUpdateMode mode = auc_mode_for_app(bid);
        if (mode == AUCUpdateModeAuto) {
            [autoSpecs addObject:spec];
        } else if (mode == AUCUpdateModeManual) {
            [manualSpecs addObject:spec];
        } else {
            [disabledSpecs addObject:spec];
        }
    }

    NSMutableArray *result = [NSMutableArray arrayWithCapacity:base.count + 4];
    if (autoSpecs.count > 0) {
        NSString *title = [NSString stringWithFormat:@"自动更新 (%lu)", (unsigned long)autoSpecs.count];
        [result addObject:[PSSpecifier preferenceSpecifierNamed:title target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil]];
        [result addObjectsFromArray:autoSpecs];
    }
    if (manualSpecs.count > 0) {
        NSString *title = [NSString stringWithFormat:@"仅手动更新 (%lu)", (unsigned long)manualSpecs.count];
        [result addObject:[PSSpecifier preferenceSpecifierNamed:title target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil]];
        [result addObjectsFromArray:manualSpecs];
    }
    if (disabledSpecs.count > 0) {
        NSString *title = [NSString stringWithFormat:@"默认禁止更新 (%lu)", (unsigned long)disabledSpecs.count];
        [result addObject:[PSSpecifier preferenceSpecifierNamed:title target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil]];
        [result addObjectsFromArray:disabledSpecs];
    }

    _specifiers = result;
    return _specifiers;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSString *bid = [spec propertyForKey:@"applicationIdentifier"];
    if (bid.length) {
        AUCUpdateMode mode = auc_mode_for_app(bid);
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        if (cell.detailTextLabel) {
            if (mode == AUCUpdateModeAuto) {
                cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            } else if (mode == AUCUpdateModeManual) {
                cell.detailTextLabel.textColor = [UIColor systemOrangeColor];
            } else {
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            }
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSString *bid = [spec propertyForKey:@"applicationIdentifier"];
    if (!bid.length) return;

    NSString *appName = spec.name ?: bid;
    AUCUpdateMode cur = auc_mode_for_app(bid);
    NSString *curText = (cur == AUCUpdateModeAuto) ? @"自动更新" : ((cur == AUCUpdateModeManual) ? @"仅手动更新" : @"禁用更新（默认）");

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:appName
                       message:[NSString stringWithFormat:@"%@\n当前：%@", bid, curText]
                preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    void (^applyMode)(AUCUpdateMode) = ^(AUCUpdateMode newMode) {
        auc_set_mode_for_app(bid, newMode);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf reloadSpecifiers];
        });
    };

    [sheet addAction:[UIAlertAction actionWithTitle:(cur == AUCUpdateModeAuto ? @"✓ 自动更新" : @"自动更新")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) { applyMode(AUCUpdateModeAuto); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:(cur == AUCUpdateModeManual ? @"✓ 仅手动更新" : @"仅手动更新")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) { applyMode(AUCUpdateModeManual); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:(cur == AUCUpdateModeDisabled ? @"✓ 禁用更新（默认）" : @"禁用更新（默认）")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *a) { applyMode(AUCUpdateModeDisabled); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (sheet.popoverPresentationController) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (NSString *)getSummaryCount:(PSSpecifier *)specifier {
    NSUInteger autoCnt = auc_count_for_mode(AUCUpdateModeAuto);
    NSUInteger manualCnt = auc_count_for_mode(AUCUpdateModeManual);
    return [NSString stringWithFormat:@"自动 %lu · 手动 %lu", (unsigned long)autoCnt, (unsigned long)manualCnt];
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
        alertControllerWithTitle:@"重置为默认禁止"
                       message:@"确定清空所有已放行的自动/手动更新配置（恢复全部默认禁止更新）吗？"
                preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认重置"
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
