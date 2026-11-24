#import <Foundation/Foundation.h>
#import <os/lock.h>
#import <limits.h>
#import "AUCPrefs.h"

@interface UpdatesContext : NSObject
- (BOOL)isBackgroundRequest;
- (BOOL)userInitiated;
@end

@interface PerformUpdatesTask : NSObject
@property (nonatomic, retain) UpdatesContext *context;
@property (nonatomic, copy) NSArray<NSString *> *orderedBundleIDs;
- (void)main;
@end

@interface AppUpdateMemoryEntity : NSObject
- (NSString *)bundleID;
- (NSInteger)parentalControlsRank;
@end

@interface ASDPurchase : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, assign) BOOL isUpdate;
@property (nonatomic, assign) BOOL isBackgroundUpdate;
@end

@interface ASDSoftwareUpdate : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@end

static os_unfair_lock gPrefsLock = OS_UNFAIR_LOCK_INIT;
static BOOL gEnabled = YES;
static NSInteger gDefaultMode = AUCUpdateModeAuto;
static NSDictionary<NSString *, NSNumber *> *gAppModes = nil;

static __thread BOOL tInPerformUpdatesTask = NO;
static __thread BOOL tIsBackgroundUpdateTask = NO;

static void auc_load_prefs(void) {
    CFPreferencesSynchronize(AUC_SUITE, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

    id enabledVal = auc_cf_get(@"enabled");
    id defVal = auc_cf_get(@"defaultMode");
    id modesVal = auc_cf_get(@"appModes");

    BOOL enabled = [enabledVal respondsToSelector:@selector(boolValue)] ? [enabledVal boolValue] : YES;
    NSInteger defMode = [defVal respondsToSelector:@selector(integerValue)] ? [defVal integerValue] : AUCUpdateModeAuto;
    if (defMode < AUCUpdateModeAuto || defMode > AUCUpdateModeDisabled) defMode = AUCUpdateModeAuto;
    NSDictionary *modes = [modesVal isKindOfClass:[NSDictionary class]] ? [modesVal copy] : @{};

    os_unfair_lock_lock(&gPrefsLock);
    gEnabled = enabled;
    gDefaultMode = defMode;
    gAppModes = modes;
    os_unfair_lock_unlock(&gPrefsLock);
}

static void auc_reload_callback(CFNotificationCenterRef center __unused,
                                void *observer __unused,
                                CFStringRef name __unused,
                                const void *object __unused,
                                CFDictionaryRef userInfo __unused) {
    auc_load_prefs();
}

static AUCUpdateMode auc_effective_mode(NSString *bundleID) {
    if (!bundleID || bundleID.length == 0) return AUCUpdateModeAuto;

    os_unfair_lock_lock(&gPrefsLock);
    BOOL enabled = gEnabled;
    NSInteger defMode = gDefaultMode;
    NSNumber *perApp = gAppModes[bundleID];
    os_unfair_lock_unlock(&gPrefsLock);

    if (!enabled) return AUCUpdateModeAuto;
    if ([perApp respondsToSelector:@selector(integerValue)]) {
        NSInteger v = [perApp integerValue];
        if (v >= AUCUpdateModeAuto && v <= AUCUpdateModeDisabled) {
            return (AUCUpdateMode)v;
        }
    }
    return (AUCUpdateMode)defMode;
}

static NSArray<NSString *> *auc_filter_disabled_bundle_ids(NSArray<NSString *> *bundleIDs) {
    if (![bundleIDs isKindOfClass:[NSArray class]] || bundleIDs.count == 0) return bundleIDs;
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:bundleIDs.count];
    for (NSString *bid in bundleIDs) {
        if ([bid isKindOfClass:[NSString class]] && auc_effective_mode(bid) == AUCUpdateModeDisabled) {
            continue;
        }
        [out addObject:bid];
    }
    return [out copy];
}

static NSArray *auc_filter_disabled_updates(NSArray *updates) {
    if (![updates isKindOfClass:[NSArray class]] || updates.count == 0) return updates;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:updates.count];
    for (id item in updates) {
        NSString *bid = nil;
        if ([item respondsToSelector:@selector(bundleIdentifier)]) {
            bid = [item bundleIdentifier];
        } else if ([item respondsToSelector:@selector(bundleID)]) {
            bid = [(id)item bundleID];
        }
        if (bid && auc_effective_mode(bid) == AUCUpdateModeDisabled) {
            continue;
        }
        [out addObject:item];
    }
    return [out copy];
}

%hook PerformUpdatesTask

- (void)main {
    BOOL prevInTask = tInPerformUpdatesTask;
    BOOL prevBg = tIsBackgroundUpdateTask;
    UpdatesContext *ctx = [self respondsToSelector:@selector(context)] ? [self context] : nil;
    BOOL isBg = NO;
    if (ctx) {
        if ([ctx respondsToSelector:@selector(isBackgroundRequest)]) {
            isBg = [ctx isBackgroundRequest];
        } else if ([ctx respondsToSelector:@selector(userInitiated)]) {
            isBg = ![ctx userInitiated];
        }
    }
    tInPerformUpdatesTask = YES;
    tIsBackgroundUpdateTask = isBg;
    @try {
        %orig;
    } @finally {
        tInPerformUpdatesTask = prevInTask;
        tIsBackgroundUpdateTask = prevBg;
    }
}

%end

%hook AppUpdateMemoryEntity

- (NSInteger)parentalControlsRank {
    if (tInPerformUpdatesTask) {
        NSString *bid = [self respondsToSelector:@selector(bundleID)] ? [self bundleID] : nil;
        AUCUpdateMode mode = auc_effective_mode(bid);
        if (mode == AUCUpdateModeDisabled || (tIsBackgroundUpdateTask && mode == AUCUpdateModeManual)) {
            return NSIntegerMax;
        }
    }
    return %orig;
}

%end

%hook PurchaseManager

- (void)processPurchases:(NSArray *)purchases requestToken:(id)token withReplyHandler:(void (^)(id, NSError *))replyHandler {
    if ([purchases isKindOfClass:[NSArray class]] && purchases.count > 0) {
        NSMutableArray *allowed = [NSMutableArray arrayWithCapacity:purchases.count];
        BOOL blockedAny = NO;
        for (id p in purchases) {
            NSString *bid = [p respondsToSelector:@selector(bundleID)] ? [p bundleID] : nil;
            BOOL isUpdate = [p respondsToSelector:@selector(isUpdate)] ? [p isUpdate] : NO;
            BOOL isBgUpdate = [p respondsToSelector:@selector(isBackgroundUpdate)] ? [p isBackgroundUpdate] : NO;
            AUCUpdateMode mode = auc_effective_mode(bid);

            if (mode == AUCUpdateModeDisabled && (isUpdate || isBgUpdate)) {
                blockedAny = YES;
                continue;
            }
            if (mode == AUCUpdateModeManual && isBgUpdate) {
                blockedAny = YES;
                continue;
            }
            [allowed addObject:p];
        }
        if (blockedAny) {
            if (allowed.count == 0) {
                if (replyHandler) {
                    NSError *err = [NSError errorWithDomain:@"com.siri666666.appupdatecontrol"
                                                       code:1301
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Update blocked by AppUpdateControl"}];
                    replyHandler(nil, err);
                }
                return;
            }
            %orig([allowed copy], token, replyHandler);
            return;
        }
    }
    %orig;
}

%end

%hook UpdatesService

- (void)getUpdatesWithReplyHandler:(void (^)(NSArray *, NSError *))replyHandler {
    if (!replyHandler) { %orig; return; }
    %orig(^(NSArray *updates, NSError *error) {
        replyHandler(auc_filter_disabled_updates(updates), error);
    });
}

- (void)updateAllWithOrder:(NSArray<NSString *> *)order replyHandler:(id)replyHandler {
    %orig(auc_filter_disabled_bundle_ids(order), replyHandler);
}

%end

%hook SoftwareUpdateListener

- (void)getUpdatesWithCompletionBlock:(void (^)(NSArray *, NSError *))completionBlock {
    if (!completionBlock) { %orig; return; }
    %orig(^(NSArray *updates, NSError *error) {
        completionBlock(auc_filter_disabled_updates(updates), error);
    });
}

- (void)updateAllWithOrder:(NSArray<NSString *> *)order completionBlock:(id)completionBlock {
    %orig(auc_filter_disabled_bundle_ids(order), completionBlock);
}

%end

%ctor {
    auc_load_prefs();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        auc_reload_callback,
        AUC_NOTIF,
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );
}
