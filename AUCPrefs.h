#ifndef AUCPREFS_H
#define AUCPREFS_H

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

#define AUC_SUITE CFSTR("com.siri666666.appupdatecontrolprefs")
#define AUC_SUITE_NS @"com.siri666666.appupdatecontrolprefs"
#define AUC_NOTIF CFSTR("com.siri666666.appupdatecontrolprefs/saved")

// Per-app mode values:
// -1 = Follow global defaultMode
//  0 = Auto update (normal)
//  1 = Manual only (skip background auto-update, keep manual Update button)
//  2 = Disabled (block background auto-update, Update All, manual Update, and hide from updates list)
typedef NS_ENUM(NSInteger, AUCUpdateMode) {
    AUCUpdateModeDefault  = -1,
    AUCUpdateModeAuto     = 0,
    AUCUpdateModeManual   = 1,
    AUCUpdateModeDisabled = 2,
};

static inline id auc_cf_get(NSString *key) {
    if (!key) return nil;
    CFPropertyListRef val = CFPreferencesCopyValue(
        (__bridge CFStringRef)key,
        AUC_SUITE,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );
    return (__bridge_transfer id)val;
}

static inline void auc_cf_set(NSString *key, id value) {
    if (!key) return;
    CFPreferencesSetValue(
        (__bridge CFStringRef)key,
        (__bridge CFPropertyListRef)value,
        AUC_SUITE,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );
    CFPreferencesSynchronize(AUC_SUITE, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

static inline void auc_post_saved_notification(void) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        AUC_NOTIF,
        NULL,
        NULL,
        YES
    );
}

#endif
