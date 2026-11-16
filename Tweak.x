// GmailActions by tb
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdarg.h>

@interface GBTNotificationActionController : NSObject
- (void)handleBackgroundActionWithIdentifier:(NSString *)identifier
                        notificationUserInfo:(NSDictionary *)userInfo
                      fromRemoteNotification:(BOOL)fromRemote
                           completionHandler:(void (^)(void))completionHandler;
@end

@interface HUBUserNotificationsServiceImpl : NSObject
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void(^)(void))completionHandler;
- (void)passDecryptedNotificationToService:(id)service
                          actionIdentifier:(NSString *)actionIdentifier
                          decryptedContent:(UNNotificationContent *)decryptedContent
                         completionHandler:(void (^)(void))completionHandler;
@end

@interface GBTNotificationActionHelperServiceImpl : NSObject
- (NSArray<NSNumber *> *)getActionIdentifiersForNotificationCategoryType:(NSUInteger)categoryType;
- (NSString *)getActionTitleForIdentifier:(NSInteger)identifier;
- (UNNotificationAction *)generateActionWithIdentifier:(NSInteger)identifier;
@end

// Gmail internal notification action IDs (verified on com.google.Gmail 6.0.241006):
//   1 = Archive (background, UNNotificationActionOptionNone)
//   3 = Trash (destructive, UNNotificationActionOptionDestructive)
//   4 = Reply all (foreground)
//   6 = Reply (foreground)
//   10 = Mark as read (background, UNNotificationActionOptionNone)
// Custom action IDs:
//   100 = Mark as Read & Archive (background, UNNotificationActionOptionNone)
//   101 = Mark as Read & Delete (background, UNNotificationActionOptionDestructive)

static NSInteger const kGmailActionArchiveID = 1;
static NSInteger const kGmailActionTrashID = 3;
static NSInteger const kGmailActionReplyAllID = 4;
static NSInteger const kGmailActionReplyID = 6;
static NSInteger const kGmailActionMarkAsReadID = 10;
static NSInteger const kGmailActionMarkAsReadAndArchiveID = 100;
static NSInteger const kGmailActionMarkAsReadAndDeleteID = 101;

static NSString *const kGmailActionArchiveStr = @"1";
static NSString *const kGmailActionTrashStr = @"3";
static NSString *const kGmailActionReplyAllStr = @"4";
static NSString *const kGmailActionReplyStr = @"6";
static NSString *const kGmailActionMarkAsReadStr = @"10";
static NSString *const kGmailActionMarkAsReadAndArchiveStr = @"100";
static NSString *const kGmailActionMarkAsReadAndDeleteStr = @"101";

static NSString *const kMarkAsReadAndArchiveTitle = @"Mark as Read & Archive";
static NSString *const kMarkAsReadAndDeleteTitle = @"Mark as Read & Delete";

static NSTimeInterval const kGMAInFlightTimeoutSeconds = 15.0;
static char const kChainedActionKey = 'k';

// Thread-safe tracking of pending combined actions and preferences
static NSMutableDictionary<NSString *, NSDictionary *> *gPendingChainedActions = nil;
static NSInteger gInFlightChainedAction = 0;
static CFAbsoluteTime gInFlightChainedTimestamp = 0;
static NSString *gInFlightChainedKey = nil;
static dispatch_queue_t gPendingActionsQueue = nil;
static dispatch_queue_t gPrefsQueue = nil;

static __weak GBTNotificationActionHelperServiceImpl *gHelperInstance = nil;
static NSMutableDictionary<NSString *, UNNotificationAction *> *gNativeActionsCache = nil;
static NSDictionary *gCachedPrefs = nil;

static void gma_ensureState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gPendingActionsQueue = dispatch_queue_create("com.tb.gmailactions.pending", DISPATCH_QUEUE_SERIAL);
        gPrefsQueue = dispatch_queue_create("com.tb.gmailactions.prefs", DISPATCH_QUEUE_SERIAL);
        gPendingChainedActions = [NSMutableDictionary dictionary];
        gNativeActionsCache = [NSMutableDictionary dictionary];
    });
}

static void gma_auditLog(const char *fmt, ...) {
#ifdef DEBUG
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docs) return;
    NSString *path = [docs stringByAppendingPathComponent:@"gmail_actions_audit.txt"];
    FILE *fp = fopen([path UTF8String], "a");
    if (!fp) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(fp, fmt, args);
    va_end(args);
    fclose(fp);
#else
    (void)fmt;
#endif
}

#pragma mark - Preferences

static NSDictionary *gma_readPlistAtPath(NSString *path, NSDate **outMtime) {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    if (outMtime) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        *outMtime = attrs[NSFileModificationDate];
    }
    return dict;
}

static NSUInteger gma_reloadPreferencesLocked(void) {
    NSDate *jbMtime = nil;
    NSDate *mobileMtime = nil;
    NSDictionary *jbDict = gma_readPlistAtPath(@"/var/jb/var/mobile/Library/Preferences/com.tb.gmailactions.plist", &jbMtime);
    NSDictionary *mobileDict = gma_readPlistAtPath(@"/var/mobile/Library/Preferences/com.tb.gmailactions.plist", &mobileMtime);

    NSDictionary *cfDict = nil;
    CFStringRef appID = CFSTR("com.tb.gmailactions");
    CFPreferencesAppSynchronize(appID);
    CFArrayRef keyList = CFPreferencesCopyKeyList(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keyList) {
        CFDictionaryRef rawCfDict = CFPreferencesCopyMultiple(keyList, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (rawCfDict) {
            cfDict = CFBridgingRelease(rawCfDict);
        }
        CFRelease(keyList);
    }

    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    BOOL jbIsNewerThanMobile = (jbDict != nil && mobileDict != nil && jbMtime != nil && mobileMtime != nil &&
                                [jbMtime compare:mobileMtime] == NSOrderedDescending);
    if (jbIsNewerThanMobile) {
        if (cfDict) [merged addEntriesFromDictionary:cfDict];
        if (mobileDict) [merged addEntriesFromDictionary:mobileDict];
        if (jbDict) [merged addEntriesFromDictionary:jbDict];
    } else {
        if (jbDict) [merged addEntriesFromDictionary:jbDict];
        if (mobileDict) [merged addEntriesFromDictionary:mobileDict];
        if (cfDict) [merged addEntriesFromDictionary:cfDict];
    }

    gCachedPrefs = [merged copy];
    return gCachedPrefs.count;
}

static void gma_reloadPreferences(void) {
    gma_ensureState();
    __block NSUInteger count = 0;
    dispatch_sync(gPrefsQueue, ^{
        count = gma_reloadPreferencesLocked();
    });
    gma_auditLog("Loaded preferences (%lu entries)\n", (unsigned long)count);
}

static BOOL gma_isOptionEnabled(NSString *key, BOOL defaultVal) {
    gma_ensureState();
    __block id valObj = nil;
    dispatch_sync(gPrefsQueue, ^{
        if (!gCachedPrefs) {
            gma_reloadPreferencesLocked();
        }
        valObj = gCachedPrefs[key];
    });

    if (valObj != nil) {
        return [valObj boolValue];
    }

    // Direct CFPreferences query fallback
    CFStringRef appID = CFSTR("com.tb.gmailactions");
    Boolean keyExists = false;
    Boolean val = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key, appID, &keyExists);
    if (keyExists) {
        return (BOOL)val;
    }

    return defaultVal;
}

#pragma mark - Native Action Cache & Category Rebuilding

static NSSet<NSString *> *gma_mailCategoryIdentifiers(void) {
    static NSSet<NSString *> *ids = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ids = [NSSet setWithObjects:@"10", @"11", @"12", @"13", nil];
    });
    return ids;
}

static void gma_cacheNativeAction(UNNotificationAction *action) {
    if (!action || action.identifier.length == 0) return;
    gma_ensureState();
    @synchronized (gNativeActionsCache) {
        gNativeActionsCache[action.identifier] = action;
    }
}

static void gma_harvestActionsFromCategories(NSSet<UNNotificationCategory *> *categories) {
    if (!categories) return;
    NSSet<NSString *> *mailIDs = gma_mailCategoryIdentifiers();
    for (UNNotificationCategory *cat in categories) {
        if (![mailIDs containsObject:cat.identifier]) continue;
        for (UNNotificationAction *act in cat.actions) {
            if (act.identifier.length > 0 &&
                ![act.identifier isEqualToString:kGmailActionMarkAsReadAndArchiveStr] &&
                ![act.identifier isEqualToString:kGmailActionMarkAsReadAndDeleteStr]) {
                gma_cacheNativeAction(act);
            }
        }
    }
}

static UNNotificationAction *gma_cachedOrFallbackNativeAction(NSInteger identifier, GBTNotificationActionHelperServiceImpl *helper) {
    gma_ensureState();
    NSString *idStr = [NSString stringWithFormat:@"%ld", (long)identifier];
    UNNotificationAction *cached = nil;
    @synchronized (gNativeActionsCache) {
        cached = gNativeActionsCache[idStr];
    }
    if (cached) {
        return cached;
    }

    NSString *title = nil;
    if (helper && [helper respondsToSelector:@selector(getActionTitleForIdentifier:)]) {
        title = [helper getActionTitleForIdentifier:identifier];
    }

    UNNotificationActionOptions options = UNNotificationActionOptionNone;
    if (identifier == kGmailActionArchiveID) {
        if (title.length == 0) title = @"Archive";
        options = UNNotificationActionOptionNone;
    } else if (identifier == kGmailActionTrashID) {
        if (title.length == 0) title = @"Trash";
        options = UNNotificationActionOptionDestructive;
    } else if (identifier == kGmailActionReplyAllID) {
        if (title.length == 0) title = @"Reply all";
        options = UNNotificationActionOptionForeground;
    } else if (identifier == kGmailActionReplyID) {
        if (title.length == 0) title = @"Reply";
        options = UNNotificationActionOptionForeground;
    } else if (identifier == kGmailActionMarkAsReadID) {
        if (title.length == 0) title = @"Mark as read";
        options = UNNotificationActionOptionNone;
    }

    if (title.length == 0) {
        return nil;
    }

    UNNotificationAction *fallback = [UNNotificationAction actionWithIdentifier:idStr
                                                                        title:title
                                                                      options:options];
    if (fallback) {
        gma_cacheNativeAction(fallback);
    }
    return fallback;
}

static NSArray<NSNumber *> *gma_defaultNativeActionIDsForCategoryType(NSUInteger categoryType) {
    switch (categoryType) {
        case 10:
            return @[@(kGmailActionArchiveID), @(kGmailActionReplyID)];
        case 11:
            return @[@(kGmailActionArchiveID), @(kGmailActionReplyAllID), @(kGmailActionReplyID)];
        case 12:
            return @[@(kGmailActionTrashID), @(kGmailActionReplyID)];
        case 13:
            return @[@(kGmailActionTrashID), @(kGmailActionReplyAllID), @(kGmailActionReplyID)];
        default:
            return @[];
    }
}

static void gma_rebuildAndRegisterCategories(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center getNotificationCategoriesWithCompletionHandler:^(NSSet<UNNotificationCategory *> *existingCategories) {
            if (!existingCategories || existingCategories.count == 0) return;

            gma_harvestActionsFromCategories(existingCategories);

            GBTNotificationActionHelperServiceImpl *helper = gHelperInstance;
            if (!helper) {
                Class helperCls = %c(GBTNotificationActionHelperServiceImpl);
                if (helperCls) {
                    helper = [[helperCls alloc] init];
                }
            }

            NSSet<NSString *> *mailIDs = gma_mailCategoryIdentifiers();
            NSMutableSet<UNNotificationCategory *> *newCategories = [NSMutableSet set];

            for (UNNotificationCategory *cat in existingCategories) {
                if (![mailIDs containsObject:cat.identifier] || !helper) {
                    [newCategories addObject:cat];
                    continue;
                }

                NSUInteger catType = (NSUInteger)[cat.identifier integerValue];
                NSArray<NSNumber *> *actionIDs = [helper getActionIdentifiersForNotificationCategoryType:catType];
                NSMutableArray<UNNotificationAction *> *actions = [NSMutableArray array];
                for (NSNumber *actID in actionIDs) {
                    UNNotificationAction *action = [helper generateActionWithIdentifier:[actID integerValue]];
                    if (action) {
                        [actions addObject:action];
                    }
                }

                NSString *placeholder = [cat respondsToSelector:@selector(hiddenPreviewsBodyPlaceholder)] ? cat.hiddenPreviewsBodyPlaceholder : nil;
                NSString *summaryFormat = [cat respondsToSelector:@selector(categorySummaryFormat)] ? cat.categorySummaryFormat : nil;

                UNNotificationCategory *updatedCat = nil;
                if ([UNNotificationCategory respondsToSelector:@selector(categoryWithIdentifier:actions:intentIdentifiers:hiddenPreviewsBodyPlaceholder:categorySummaryFormat:options:)]) {
                    updatedCat = [UNNotificationCategory categoryWithIdentifier:cat.identifier
                                                                        actions:actions
                                                              intentIdentifiers:cat.intentIdentifiers
                                                  hiddenPreviewsBodyPlaceholder:placeholder
                                                          categorySummaryFormat:summaryFormat
                                                                        options:cat.options];
                } else if ([UNNotificationCategory respondsToSelector:@selector(categoryWithIdentifier:actions:intentIdentifiers:hiddenPreviewsBodyPlaceholder:options:)] && placeholder != nil) {
                    updatedCat = [UNNotificationCategory categoryWithIdentifier:cat.identifier
                                                                        actions:actions
                                                              intentIdentifiers:cat.intentIdentifiers
                                                  hiddenPreviewsBodyPlaceholder:placeholder
                                                                        options:cat.options];
                } else {
                    updatedCat = [UNNotificationCategory categoryWithIdentifier:cat.identifier
                                                                        actions:actions
                                                              intentIdentifiers:cat.intentIdentifiers
                                                                        options:cat.options];
                }
                [newCategories addObject:updatedCat];
            }

            [center setNotificationCategories:newCategories];
            gma_auditLog("Dynamically updated %lu notification categories with UNUserNotificationCenter\n", (unsigned long)newCategories.count);
        }];
    });
}

static void gma_settingsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    gma_auditLog("Received com.tb.gmailactions/settingschanged notification!\n");
    gma_reloadPreferences();
    gma_rebuildAndRegisterCategories();
}

#pragma mark - State Management

static NSString *gma_keyForUserInfo(NSDictionary *userInfo) {
    if (![userInfo isKindOfClass:[NSDictionary class]]) return nil;

    NSArray<NSString *> *idKeys = @[@"c", @"gcm.message_id", @"google.c.a.c_id", @"mid", @"i", @"m", @"t"];
    for (NSString *k in idKeys) {
        id val = userInfo[k];
        if (val && ![val isKindOfClass:[NSNull class]]) {
            NSString *desc = [val description];
            if (desc.length > 0) {
                return [NSString stringWithFormat:@"%@_%@", k, desc];
            }
        }
    }

    id aps = userInfo[@"aps"];
    if ([aps isKindOfClass:[NSDictionary class]]) {
        id threadId = aps[@"thread-id"];
        if (threadId && ![threadId isKindOfClass:[NSNull class]]) {
            NSString *desc = [threadId description];
            if (desc.length > 0) {
                return [NSString stringWithFormat:@"aps_thread_%@", desc];
            }
        }
    }

    NSArray *allKeys = [[userInfo allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [[a description] compare:[b description]];
    }];
    NSMutableString *fp = [NSMutableString string];
    for (id k in allKeys) {
        id v = userInfo[k];
        [fp appendFormat:@"%@=%@;", [k description], [v description] ?: @""];
    }
    return fp.length > 0 ? fp : [NSString stringWithFormat:@"p_%p", userInfo];
}

static void gma_pruneExpiredPendingLocked(CFAbsoluteTime now) {
    if (gPendingChainedActions.count > 0) {
        NSArray<NSString *> *keys = [gPendingChainedActions allKeys];
        for (NSString *k in keys) {
            NSDictionary *entry = gPendingChainedActions[k];
            if (![entry isKindOfClass:[NSDictionary class]]) {
                [gPendingChainedActions removeObjectForKey:k];
                continue;
            }
            CFAbsoluteTime ts = [entry[@"ts"] doubleValue];
            if ((now - ts) > kGMAInFlightTimeoutSeconds) {
                [gPendingChainedActions removeObjectForKey:k];
            }
        }
    }
    if (gInFlightChainedAction != 0 && (now - gInFlightChainedTimestamp) > kGMAInFlightTimeoutSeconds) {
        gInFlightChainedAction = 0;
        gInFlightChainedTimestamp = 0;
        gInFlightChainedKey = nil;
    }
}

static void gma_markPendingChainedAction(NSDictionary *userInfo, NSInteger chainedActionID) {
    gma_ensureState();
    if (userInfo && [userInfo isKindOfClass:[NSDictionary class]]) {
        objc_setAssociatedObject(userInfo, &kChainedActionKey, @(chainedActionID), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSString *key = gma_keyForUserInfo(userInfo);
    dispatch_sync(gPendingActionsQueue, ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        gma_pruneExpiredPendingLocked(now);
        if (key) {
            gPendingChainedActions[key] = @{ @"action": @(chainedActionID), @"ts": @(now) };
        }
        gInFlightChainedAction = chainedActionID;
        gInFlightChainedTimestamp = now;
        gInFlightChainedKey = [key copy];
    });
}

static NSInteger gma_propagateInFlightChainedAction(NSDictionary *decUserInfo) {
    gma_ensureState();
    __block NSInteger result = 0;
    if (decUserInfo && [decUserInfo isKindOfClass:[NSDictionary class]]) {
        NSNumber *tag = objc_getAssociatedObject(decUserInfo, &kChainedActionKey);
        if (tag) {
            result = [tag integerValue];
        }
    }

    NSString *decKey = gma_keyForUserInfo(decUserInfo);
    dispatch_sync(gPendingActionsQueue, ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        gma_pruneExpiredPendingLocked(now);
        if (result == 0 && decKey) {
            NSDictionary *entry = gPendingChainedActions[decKey];
            if (entry) {
                result = [entry[@"action"] integerValue];
            }
        }
        if (result == 0 && gInFlightChainedAction != 0 && (now - gInFlightChainedTimestamp) <= kGMAInFlightTimeoutSeconds) {
            result = gInFlightChainedAction;
        }
        if (result != 0 && gInFlightChainedKey && (!decKey || ![gInFlightChainedKey isEqualToString:decKey])) {
            [gPendingChainedActions removeObjectForKey:gInFlightChainedKey];
        }
    });

    return result;
}

static void gma_clearPendingChainedAction(NSDictionary *userInfo) {
    gma_ensureState();
    if (userInfo && [userInfo isKindOfClass:[NSDictionary class]]) {
        objc_setAssociatedObject(userInfo, &kChainedActionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSString *key = gma_keyForUserInfo(userInfo);
    dispatch_sync(gPendingActionsQueue, ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        gma_pruneExpiredPendingLocked(now);
        if (key) {
            [gPendingChainedActions removeObjectForKey:key];
        }
        if (gInFlightChainedKey) {
            [gPendingChainedActions removeObjectForKey:gInFlightChainedKey];
        }
        gInFlightChainedAction = 0;
        gInFlightChainedTimestamp = 0;
        gInFlightChainedKey = nil;
    });
}

static NSInteger gma_consumePendingChainedAction(NSDictionary *userInfo) {
    gma_ensureState();
    __block NSInteger result = 0;
    if (userInfo && [userInfo isKindOfClass:[NSDictionary class]]) {
        NSNumber *tag = objc_getAssociatedObject(userInfo, &kChainedActionKey);
        if (tag) {
            result = [tag integerValue];
            objc_setAssociatedObject(userInfo, &kChainedActionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    NSString *key = gma_keyForUserInfo(userInfo);
    dispatch_sync(gPendingActionsQueue, ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        gma_pruneExpiredPendingLocked(now);

        if (key) {
            NSDictionary *entry = gPendingChainedActions[key];
            if (entry) {
                if (result == 0) {
                    result = [entry[@"action"] integerValue];
                }
                [gPendingChainedActions removeObjectForKey:key];
            }
        }

        if (result != 0) {
            if (gInFlightChainedAction == result || (key && gInFlightChainedKey && [key isEqualToString:gInFlightChainedKey])) {
                if (gInFlightChainedKey) {
                    [gPendingChainedActions removeObjectForKey:gInFlightChainedKey];
                }
                gInFlightChainedAction = 0;
                gInFlightChainedTimestamp = 0;
                gInFlightChainedKey = nil;
            }
        } else if (gInFlightChainedAction != 0 && (now - gInFlightChainedTimestamp) <= kGMAInFlightTimeoutSeconds) {
            result = gInFlightChainedAction;
            if (gInFlightChainedKey) {
                [gPendingChainedActions removeObjectForKey:gInFlightChainedKey];
            }
            gInFlightChainedAction = 0;
            gInFlightChainedTimestamp = 0;
            gInFlightChainedKey = nil;
        }
    });

    return result;
}

#pragma mark - 1. Notification Category & Action Registration

%hook GBTNotificationActionHelperServiceImpl

- (id)init {
    id orig = %orig;
    if (orig) {
        gHelperInstance = orig;
    }
    return orig;
}

- (NSArray<NSNumber *> *)getActionIdentifiersForNotificationCategoryType:(NSUInteger)categoryType {
    gHelperInstance = self;
    NSArray<NSNumber *> *orig = %orig;

    // Mail notification categories:
    //   10: Archive + Reply
    //   11: Archive + Reply all + Reply
    //   12: Trash + Reply
    //   13: Trash + Reply all + Reply
    if (categoryType < 10 || categoryType > 13) {
        return orig;
    }

    NSArray<NSNumber *> *effectiveOrig = (orig.count > 0) ? orig : gma_defaultNativeActionIDsForCategoryType(categoryType);

    // Master Switch Check
    if (!gma_isOptionEnabled(@"enabled", YES)) {
        gma_auditLog("Tweak disabled via master switch, returning stock actions.\n");
        return effectiveOrig;
    }

    NSMutableArray<NSNumber *> *ordered = [NSMutableArray array];

    // 1. Mark as read (10)
    if (gma_isOptionEnabled(@"enableMarkAsRead", YES)) {
        [ordered addObject:@(kGmailActionMarkAsReadID)];
    }

    // 2. Mark as Read & Archive (100)
    if (gma_isOptionEnabled(@"enableMarkAsReadAndArchive", YES)) {
        [ordered addObject:@(kGmailActionMarkAsReadAndArchiveID)];
    }

    // 3. Mark as Read & Delete (101)
    if (gma_isOptionEnabled(@"enableMarkAsReadAndDelete", YES)) {
        [ordered addObject:@(kGmailActionMarkAsReadAndDeleteID)];
    }

    // 4. Primary action: Archive (1) or Trash (3) based on effectiveOrig / categoryType
    if ([effectiveOrig containsObject:@(kGmailActionArchiveID)]) {
        if (gma_isOptionEnabled(@"enableArchive", YES)) {
            [ordered addObject:@(kGmailActionArchiveID)];
        }
    } else if ([effectiveOrig containsObject:@(kGmailActionTrashID)]) {
        if (gma_isOptionEnabled(@"enableTrash", YES)) {
            [ordered addObject:@(kGmailActionTrashID)];
        }
    } else if (categoryType == 12 || categoryType == 13) {
        if (gma_isOptionEnabled(@"enableTrash", YES)) {
            [ordered addObject:@(kGmailActionTrashID)];
        }
    } else {
        if (gma_isOptionEnabled(@"enableArchive", YES)) {
            [ordered addObject:@(kGmailActionArchiveID)];
        }
    }

    // 5. Secondary actions: Reply all (4) if present, then Reply (6)
    if ([effectiveOrig containsObject:@(kGmailActionReplyAllID)] && gma_isOptionEnabled(@"enableReplyAll", YES)) {
        [ordered addObject:@(kGmailActionReplyAllID)];
    }
    if (gma_isOptionEnabled(@"enableReply", YES)) {
        [ordered addObject:@(kGmailActionReplyID)];
    }

    // Append any other actions from effectiveOrig without duplicates, respecting disabled toggles
    for (NSNumber *act in effectiveOrig) {
        NSInteger val = [act integerValue];
        if (val == kGmailActionArchiveID && !gma_isOptionEnabled(@"enableArchive", YES)) continue;
        if (val == kGmailActionTrashID && !gma_isOptionEnabled(@"enableTrash", YES)) continue;
        if (val == kGmailActionReplyAllID && !gma_isOptionEnabled(@"enableReplyAll", YES)) continue;
        if (val == kGmailActionReplyID && !gma_isOptionEnabled(@"enableReply", YES)) continue;
        if (val == kGmailActionMarkAsReadID && !gma_isOptionEnabled(@"enableMarkAsRead", YES)) continue;

        if (![ordered containsObject:act]) {
            [ordered addObject:act];
        }
    }

    gma_auditLog("Category %lu action IDs after preferences: %s\n", (unsigned long)categoryType, [[ordered description] UTF8String]);

    return [ordered copy];
}

- (NSString *)getActionTitleForIdentifier:(NSInteger)identifier {
    if (identifier == kGmailActionMarkAsReadAndArchiveID) {
        return kMarkAsReadAndArchiveTitle;
    }
    if (identifier == kGmailActionMarkAsReadAndDeleteID) {
        return kMarkAsReadAndDeleteTitle;
    }
    return %orig;
}

- (UNNotificationAction *)generateActionWithIdentifier:(NSInteger)identifier {
    gHelperInstance = self;
    UNNotificationAction *act = nil;
    if (identifier == kGmailActionMarkAsReadAndArchiveID) {
        act = [UNNotificationAction actionWithIdentifier:kGmailActionMarkAsReadAndArchiveStr
                                                   title:kMarkAsReadAndArchiveTitle
                                                 options:UNNotificationActionOptionNone];
    } else if (identifier == kGmailActionMarkAsReadAndDeleteID) {
        act = [UNNotificationAction actionWithIdentifier:kGmailActionMarkAsReadAndDeleteStr
                                                   title:kMarkAsReadAndDeleteTitle
                                                 options:UNNotificationActionOptionDestructive];
    } else {
        act = %orig;
        if (act && act.identifier.length > 0) {
            gma_cacheNativeAction(act);
        } else {
            act = gma_cachedOrFallbackNativeAction(identifier, self);
        }
    }

    if (act) {
        gma_auditLog("Generated Action ID %ld: identifier='%s' title='%s' options=%lu\n",
                     (long)identifier,
                     [act.identifier UTF8String],
                     [act.title UTF8String],
                     (unsigned long)act.options);
    }
    return act;
}

- (BOOL)canOpenInForegroundForIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:kGmailActionMarkAsReadStr] ||
        [identifier isEqualToString:kGmailActionMarkAsReadAndArchiveStr] ||
        [identifier isEqualToString:kGmailActionMarkAsReadAndDeleteStr]) {
        return NO;
    }
    return %orig;
}

- (NSInteger)convertActionIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:kGmailActionMarkAsReadAndArchiveStr]) {
        return kGmailActionArchiveID;
    }
    if ([identifier isEqualToString:kGmailActionMarkAsReadAndDeleteStr]) {
        return kGmailActionTrashID;
    }
    return %orig;
}

- (void)logMetricsForIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:kGmailActionMarkAsReadAndArchiveStr]) {
        %orig(kGmailActionArchiveStr);
        return;
    }
    if ([identifier isEqualToString:kGmailActionMarkAsReadAndDeleteStr]) {
        %orig(kGmailActionTrashStr);
        return;
    }
    %orig;
}

%end

#pragma mark - 2. HUBUserNotificationsServiceImpl Routing & Decryption

%hook HUBUserNotificationsServiceImpl

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    NSString *actionID = [response respondsToSelector:@selector(actionIdentifier)] ? response.actionIdentifier : nil;
    NSDictionary *userInfo = nil;
    if ([response respondsToSelector:@selector(notification)]) {
        UNNotification *notif = response.notification;
        if ([notif respondsToSelector:@selector(request)] &&
            [notif.request respondsToSelector:@selector(content)] &&
            [notif.request.content respondsToSelector:@selector(userInfo)]) {
            userInfo = notif.request.content.userInfo;
        }
    }

    NSInteger chainedID = 0;
    if ([actionID isEqualToString:kGmailActionMarkAsReadAndArchiveStr]) {
        chainedID = kGmailActionArchiveID;
    } else if ([actionID isEqualToString:kGmailActionMarkAsReadAndDeleteStr]) {
        chainedID = kGmailActionTrashID;
    }

    if (chainedID != 0) {
        if (response) {
            objc_setAssociatedObject(response, &kChainedActionKey, @(chainedID), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        gma_markPendingChainedAction(userInfo, chainedID);

        // Normalize actionIdentifier to @"10" (native Mark as Read) so early validation checks pass
        BOOL updated = NO;
        @try {
            [response setValue:kGmailActionMarkAsReadStr forKey:@"actionIdentifier"];
            updated = [response.actionIdentifier isEqualToString:kGmailActionMarkAsReadStr];
        } @catch (NSException *exception) {
            updated = NO;
        }
        if (!updated && response) {
            Ivar ivar = class_getInstanceVariable([UNNotificationResponse class], "_actionIdentifier");
            if (ivar) {
                object_setIvar(response, ivar, kGmailActionMarkAsReadStr);
            }
        }
    } else if ([actionID isEqualToString:kGmailActionMarkAsReadStr]) {
        gma_clearPendingChainedAction(userInfo);
    }
    %orig;
}

- (void)passDecryptedNotificationToService:(id)service
                          actionIdentifier:(NSString *)actionIdentifier
                          decryptedContent:(UNNotificationContent *)decryptedContent
                         completionHandler:(void (^)(void))completionHandler {
    NSDictionary *decUserInfo = (decryptedContent && [decryptedContent respondsToSelector:@selector(userInfo)]) ? decryptedContent.userInfo : nil;
    NSInteger chainedID = 0;
    if ([actionIdentifier isEqualToString:kGmailActionMarkAsReadAndArchiveStr]) {
        chainedID = kGmailActionArchiveID;
    } else if ([actionIdentifier isEqualToString:kGmailActionMarkAsReadAndDeleteStr]) {
        chainedID = kGmailActionTrashID;
    } else if ([actionIdentifier isEqualToString:kGmailActionMarkAsReadStr]) {
        chainedID = gma_propagateInFlightChainedAction(decUserInfo);
    }

    if (chainedID != 0) {
        if (decUserInfo) {
            gma_markPendingChainedAction(decUserInfo, chainedID);
        }
        // Route through HUBUserNotificationsServiceImpl using native Mark as Read (@"10")
        // so unknown-action guards and upgrade checks treat it as a valid background action.
        %orig(service, kGmailActionMarkAsReadStr, decryptedContent, completionHandler);
        return;
    }
    %orig;
}

%end

#pragma mark - 3. Background Execution (Mark as Read Chaining)

%hook GBTNotificationActionController

- (void)handleBackgroundActionWithIdentifier:(NSString *)identifier
                        notificationUserInfo:(NSDictionary *)userInfo
                      fromRemoteNotification:(BOOL)fromRemote
                           completionHandler:(void (^)(void))completionHandler {
    NSInteger chainedAction = 0;
    if ([identifier isEqualToString:kGmailActionMarkAsReadAndArchiveStr]) {
        chainedAction = kGmailActionArchiveID;
    } else if ([identifier isEqualToString:kGmailActionMarkAsReadAndDeleteStr]) {
        chainedAction = kGmailActionTrashID;
    } else if ([identifier isEqualToString:kGmailActionMarkAsReadStr]) {
        chainedAction = gma_consumePendingChainedAction(userInfo);
    }

    if (chainedAction != 0) {
        NSString *secondActionStr = (chainedAction == kGmailActionTrashID) ? kGmailActionTrashStr : kGmailActionArchiveStr;

        UIApplication *app = [UIApplication sharedApplication];
        __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
        __block BOOL didTriggerStep2 = NO;
        __block BOOL didFinish = NO;

        void (^finishChain)(void) = ^{
            dispatch_block_t completeBlock = ^{
                if (didFinish) return;
                didFinish = YES;
                if (completionHandler) {
                    completionHandler();
                }
                if (bgTask != UIBackgroundTaskInvalid) {
                    UIBackgroundTaskIdentifier taskToEnd = bgTask;
                    bgTask = UIBackgroundTaskInvalid;
                    [app endBackgroundTask:taskToEnd];
                }
            };
            if ([NSThread isMainThread]) {
                completeBlock();
            } else {
                dispatch_async(dispatch_get_main_queue(), completeBlock);
            }
        };

        bgTask = [app beginBackgroundTaskWithName:@"com.tb.gmailactions.chain" expirationHandler:^{
            gma_auditLog("Background task expired during chained action, finishing safely\n");
            finishChain();
        }];

        // Step 1: Mark as Read (@"10") in background
        void (^afterMarkRead)(void) = ^{
            // Step 2: Dispatch secondary action (Archive or Trash) on next runloop turn after Mark as Read completes
            dispatch_async(dispatch_get_main_queue(), ^{
                if (didTriggerStep2 || didFinish) {
                    return;
                }
                didTriggerStep2 = YES;
                if ([self respondsToSelector:@selector(handleBackgroundActionWithIdentifier:notificationUserInfo:fromRemoteNotification:completionHandler:)]) {
                    [self handleBackgroundActionWithIdentifier:secondActionStr
                                          notificationUserInfo:userInfo
                                        fromRemoteNotification:fromRemote
                                             completionHandler:finishChain];
                } else {
                    finishChain();
                }
            });
        };
        %orig(kGmailActionMarkAsReadStr, userInfo, fromRemote, afterMarkRead);
        return;
    }

    %orig;
}

%end

#pragma mark - Constructor

%ctor {
    gma_ensureState();
    gma_reloadPreferences();

    %init;

    // Observe PreferenceLoader changes across processes
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback)gma_settingsChanged,
        CFSTR("com.tb.gmailactions/settingschanged"),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );

    // Sync categories on startup in case preferences were modified while Gmail was closed
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gma_rebuildAndRegisterCategories();

#ifdef DEBUG
        [[UNUserNotificationCenter currentNotificationCenter] getNotificationCategoriesWithCompletionHandler:^(NSSet<UNNotificationCategory *> *categories) {
            NSSet<NSString *> *mailIDs = gma_mailCategoryIdentifiers();
            gma_auditLog("\n=== Live Registered Notification Categories (%lu) ===\n", (unsigned long)categories.count);
            for (UNNotificationCategory *cat in categories) {
                if ([mailIDs containsObject:cat.identifier]) {
                    gma_auditLog("Category '%s' (options: %lu):\n", [cat.identifier UTF8String], (unsigned long)cat.options);
                    for (UNNotificationAction *act in cat.actions) {
                        gma_auditLog("  - ID: %s | Title: '%s' | Options: %lu\n",
                                     [act.identifier UTF8String],
                                     [act.title UTF8String],
                                     (unsigned long)act.options);
                    }
                }
            }
        }];
#endif
    });
}
