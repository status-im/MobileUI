#include "pushnotification_ios.h"
#include "mobileuiappdelegate_ios.h"

#ifdef Q_OS_IOS

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <UIKit/UIKit.h>

#include <QCoreApplication>
#include <QDesktopServices>
#include <QMetaObject>
#include <QString>
#include <QUrl>

PushNotificationIOS* PushNotificationIOS::s_instance = nullptr;
static NotificationPermissionCallback s_permissionCallback = nullptr;

// Pending iOS background-fetch completion blocks. Mutated only on the main queue.
static NSMutableArray* s_pendingCompletions = nil;
// Safety net to honor iOS's ~30 s background budget if finishBackgroundFetch() is never called.
static NSTimer* s_backgroundFetchSafetyTimer = nil;
static const NSTimeInterval kBackgroundFetchSafetyInterval = 25.0;

// Schemes we allow QDesktopServices::openUrl to receive from a notification payload:
// any scheme the host app has registered via CFBundleURLTypes, plus https (universal
// links). Defence-in-depth — without this, a deepLink with e.g. `tel:` or
// `http://attacker/…` would otherwise be opened by iOS without app involvement.
static NSSet<NSString*>* allowedNotificationUrlSchemes()
{
    static NSSet<NSString*>* s_allowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableSet<NSString*>* set = [NSMutableSet new];
        [set addObject:@"https"];
        id urlTypes = [NSBundle mainBundle].infoDictionary[@"CFBundleURLTypes"];
        if ([urlTypes isKindOfClass:[NSArray class]]) {
            for (id type in (NSArray*)urlTypes) {
                if (![type isKindOfClass:[NSDictionary class]]) continue;
                id schemes = ((NSDictionary*)type)[@"CFBundleURLSchemes"];
                if (![schemes isKindOfClass:[NSArray class]]) continue;
                for (id scheme in (NSArray*)schemes) {
                    if ([scheme isKindOfClass:[NSString class]])
                        [set addObject:[(NSString*)scheme lowercaseString]];
                }
            }
        }
        s_allowed = [set copy];
    });
    return s_allowed;
}

// Notification-center delegate: forwards userInfo[deepLink] to QDesktopServices::openUrl().
@interface StatusUNDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation StatusUNDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
    didReceiveNotificationResponse:(UNNotificationResponse*)response
             withCompletionHandler:(void (^)(void))completionHandler
{
    (void)center;
    if ([response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier]) {
        NSDictionary* userInfo = response.notification.request.content.userInfo;
        id deepLink = userInfo[@"deepLink"];
        if (![deepLink isKindOfClass:[NSString class]]) {
            id data = userInfo[@"data"];
            if ([data isKindOfClass:[NSDictionary class]]) {
                deepLink = data[@"deepLink"];
            }
        }
        if ([deepLink isKindOfClass:[NSString class]] && [(NSString*)deepLink length] > 0) {
            // Only route URLs whose scheme the host app registered (plus https). And in
            // case iOS delivers the response before Qt's main() constructs the app, skip
            // routing rather than crash on a null qApp.
            NSURL* url = [NSURL URLWithString:(NSString*)deepLink];
            NSString* scheme = url.scheme.lowercaseString;
            if (scheme.length > 0 && [allowedNotificationUrlSchemes() containsObject:scheme]) {
                if (auto* app = QCoreApplication::instance()) {
                    const QString link = QString::fromNSString((NSString*)deepLink);
                    QMetaObject::invokeMethod(app, [link]() {
                        QDesktopServices::openUrl(QUrl(link));
                    }, Qt::QueuedConnection);
                }
            }
        }
    }
    completionHandler();
}

@end

void mobileui_installPushTapDelegate()
{
    // The center holds its delegate weakly; keep a strong static reference. Idempotent.
    static StatusUNDelegate* s_unDelegate = nil;
    if (s_unDelegate == nil) {
        s_unDelegate = [[StatusUNDelegate alloc] init];
        [UNUserNotificationCenter currentNotificationCenter].delegate = s_unDelegate;
    }
}

static void emitPermissionChanged(bool granted)
{
    if (auto* inst = PushNotificationIOS::instance()) {
        QMetaObject::invokeMethod(inst, [inst, granted]() {
            emit inst->notificationPermissionChanged(granted);
        }, Qt::QueuedConnection);
    }
}

PushNotificationIOS::PushNotificationIOS(QObject* parent)
    : QObject(parent)
    , m_initialized(false)
    , m_permissionState(-1)
    , m_permissionStatus(-1)
    , m_permissionObserverAdded(false)
{
}

PushNotificationIOS* PushNotificationIOS::instance()
{
    if (!s_instance) {
        s_instance = new PushNotificationIOS(qApp);
    }
    return s_instance;
}

void PushNotificationIOS::initialize(PushNotificationTokenCallback tokenCallback)
{
    if (m_initialized) {
        return;
    }

    mobileui_initIOSAppDelegateCategory();

    // Belt-and-suspenders: also installed from +load to catch cold-launch taps.
    mobileui_installPushTapDelegate();

    m_tokenCallback = tokenCallback;
    refreshNotificationPermissionCache();

    if (!m_permissionObserverAdded) {
        m_permissionObserverAdded = true;
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification* notification) {
                        (void)notification;
                        if (auto* inst = PushNotificationIOS::instance()) {
                            inst->refreshNotificationPermissionCache();
                        }
                    }];
    }

    m_initialized = true;
}

void PushNotificationIOS::setNotificationPermissionCallback(NotificationPermissionCallback callback)
{
    s_permissionCallback = callback;
}

bool PushNotificationIOS::hasNotificationPermission()
{
    int cached = m_permissionState.load();
    if (cached == -1) {
        refreshNotificationPermissionCache();
        return false;
    }

    return cached == 1;
}

void PushNotificationIOS::refreshNotificationPermissionCache()
{
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
    auto* self = this;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings* settings) {
        self->updatePermissionCacheWithStatus(settings.authorizationStatus, false);
    }];
}

void PushNotificationIOS::updatePermissionCacheWithStatus(int status, bool forceEmit)
{
    const bool granted = (status == UNAuthorizationStatusAuthorized);
    const int newValue = granted ? 1 : 0;
    const int previous = m_permissionState.exchange(newValue);
    m_permissionStatus.store(status);
    if (forceEmit || previous != newValue) {
        emitPermissionChanged(granted);
    }
}

void PushNotificationIOS::updatePermissionGranted(bool granted, bool forceEmit)
{
    const int newValue = granted ? 1 : 0;
    const int previous = m_permissionState.exchange(newValue);
    if (forceEmit || previous != newValue) {
        emitPermissionChanged(granted);
    }
}

bool PushNotificationIOS::isNotificationPermissionRequestable()
{
    int cachedStatus = m_permissionStatus.load();
    if (cachedStatus == -1) {
        refreshNotificationPermissionCache();
        return true;
    }

    return cachedStatus != UNAuthorizationStatusDenied;
}

void PushNotificationIOS::requestNotificationPermission()
{
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];

    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings* settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusAuthorized) {
            updatePermissionCacheWithStatus(settings.authorizationStatus, true);
            dispatch_async(dispatch_get_main_queue(), ^{
                [[UIApplication sharedApplication] registerForRemoteNotifications];
            });
            if (s_permissionCallback != nullptr) {
                s_permissionCallback(1);
            }
        } else if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            UNAuthorizationOptions options = UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge;

            [center requestAuthorizationWithOptions:options
                                  completionHandler:^(BOOL granted, NSError* error) {
                if (error) {
                    updatePermissionGranted(false, true);
                    if (s_permissionCallback != nullptr) {
                        s_permissionCallback(0);
                    }
                    return;
                }

                if (granted) {
                    updatePermissionCacheWithStatus(UNAuthorizationStatusAuthorized, true);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[UIApplication sharedApplication] registerForRemoteNotifications];
                    });
                    if (s_permissionCallback != nullptr) {
                        s_permissionCallback(1);
                    }
                } else {
                    updatePermissionCacheWithStatus(UNAuthorizationStatusDenied, true);
                    if (s_permissionCallback != nullptr) {
                        s_permissionCallback(0);
                    }
                }
            }];
        } else {
            updatePermissionCacheWithStatus(settings.authorizationStatus, true);
            if (s_permissionCallback != nullptr) {
                s_permissionCallback(0);
            }
        }
    }];
}

void PushNotificationIOS::openNotificationSettings()
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL* url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        if (!url) {
            return;
        }

        UIApplication* app = [UIApplication sharedApplication];
        if (!app) {
            return;
        }

        if (@available(iOS 10.0, *)) {
            [app openURL:url options:@{} completionHandler:nil];
        } else {
            [app openURL:url];
        }
    });
}

void PushNotificationIOS::requestAPNSToken()
{
    if (!hasNotificationPermission()) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] registerForRemoteNotifications];
    });
}

void PushNotificationIOS::showNotification(const QString& title,
                                          const QString& message,
                                          const QString& identifier)
{
    const QString titleCopy = title;
    const QString messageCopy = message;
    const QString identifierCopy = identifier;

    auto showBlock = ^{
        UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
        content.title = titleCopy.toNSString();
        content.body = messageCopy.toNSString();
        content.sound = [UNNotificationSound defaultSound];
        content.badge = @([[UIApplication sharedApplication] applicationIconBadgeNumber] + 1);

        content.userInfo = @{@"identifier": identifierCopy.toNSString()};

        UNTimeIntervalNotificationTrigger* trigger = [UNTimeIntervalNotificationTrigger
            triggerWithTimeInterval:0.1 repeats:NO];

        UNNotificationRequest* request = [UNNotificationRequest
            requestWithIdentifier:identifierCopy.toNSString()
            content:content
            trigger:trigger];

        UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
        [center addNotificationRequest:request withCompletionHandler:^(NSError* error) {
            Q_UNUSED(error);
        }];
    };

    if ([NSThread isMainThread]) {
        showBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), showBlock);
    }
}

void PushNotificationIOS::clearNotifications(const QString& identifier)
{
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];

    [center removeDeliveredNotificationsWithIdentifiers:@[identifier.toNSString()]];

    [center removePendingNotificationRequestsWithIdentifiers:@[identifier.toNSString()]];
}

void PushNotificationIOS::onAPNSTokenReceived(const QString& token)
{
    if (m_tokenCallback != nullptr) {
        m_tokenCallback(token.toUtf8().constData());
    }

    emit tokenReceived(token);
}

void PushNotificationIOS::onRemoteNotificationReceived()
{
    QMetaObject::invokeMethod(this, [this]() {
        emit remoteNotificationReceived();
    }, Qt::QueuedConnection);

    // (Re)arm the safety timer so iOS's background budget is honored even without a
    // finishBackgroundFetch() call. Timer lives on the main queue.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_backgroundFetchSafetyTimer != nil) {
            [s_backgroundFetchSafetyTimer invalidate];
            s_backgroundFetchSafetyTimer = nil;
        }
        s_backgroundFetchSafetyTimer = [NSTimer
            scheduledTimerWithTimeInterval:kBackgroundFetchSafetyInterval
                                   repeats:NO
                                     block:^(NSTimer* timer) {
                (void)timer;
                // No ARC: the static doesn't retain the timer, which the runloop is about
                // to release. Null it before finishBackgroundFetch can message a freed pointer.
                s_backgroundFetchSafetyTimer = nil;
                if (s_pendingCompletions != nil && s_pendingCompletions.count > 0) {
                    if (auto* inst = PushNotificationIOS::instance()) {
                        inst->finishBackgroundFetch(true);
                    }
                }
            }];
    });
}

void PushNotificationIOS::enqueueBackgroundCompletion(void* handler)
{
    if (handler == nullptr) {
        return;
    }

    // Copy the stack-allocated block so it survives until drained.
    void (^completion)(UIBackgroundFetchResult) = [(__bridge void (^)(UIBackgroundFetchResult))handler copy];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_pendingCompletions == nil) {
            s_pendingCompletions = [[NSMutableArray alloc] init];
        }
        [s_pendingCompletions addObject:completion];
    });
}

void PushNotificationIOS::finishBackgroundFetch(bool hadNewData)
{
    // Drain on the main queue (single-threaded access to array/timer).
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_backgroundFetchSafetyTimer != nil) {
            [s_backgroundFetchSafetyTimer invalidate];
            s_backgroundFetchSafetyTimer = nil;
        }

        if (s_pendingCompletions == nil || s_pendingCompletions.count == 0) {
            return;
        }

        // Snapshot then clear so re-entrant calls (or a late timer) see an empty queue.
        NSArray* completions = [s_pendingCompletions copy];
        [s_pendingCompletions removeAllObjects];

        const UIBackgroundFetchResult result =
            hadNewData ? UIBackgroundFetchResultNewData : UIBackgroundFetchResultNoData;

        for (id obj in completions) {
            void (^completion)(UIBackgroundFetchResult) = (void (^)(UIBackgroundFetchResult))obj;
            completion(result);
        }
    });
}

#endif // Q_OS_IOS
