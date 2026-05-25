#include "pushnotification_ios.h"
#include "mobileuiappdelegate_ios.h"

#ifdef Q_OS_IOS

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <UIKit/UIKit.h>

#include <QCoreApplication>
#include <QMetaObject>

PushNotificationIOS* PushNotificationIOS::s_instance = nullptr;
static NotificationPermissionCallback s_permissionCallback = nullptr;

// Pending iOS UIBackgroundFetchResult completion blocks awaiting status-desktop's
// finishBackgroundFetch() (or the safety timer). Touched only on the main queue.
static NSMutableArray* s_pendingCompletions = nil;
// Safety timer that fires finishBackgroundFetch(true) if status-desktop never reports
// back within iOS's ~30s background budget. Touched only on the main queue.
static NSTimer* s_backgroundFetchSafetyTimer = nil;
static const NSTimeInterval kBackgroundFetchSafetyInterval = 25.0;

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
    NSLog(@"[StatusPNDiag] updatePermissionCacheWithStatus: UN status=%d granted=%d previous=%d forceEmit=%d",
          status, granted, previous, forceEmit);
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
    NSLog(@"[StatusPNDiag] requestAPNSToken called; cached permissionState=%d permissionStatus=%d",
          m_permissionState.load(), m_permissionStatus.load());
    if (!hasNotificationPermission()) {
        NSLog(@"[StatusPNDiag] requestAPNSToken EARLY RETURN — hasNotificationPermission()==false");
        return;
    }

    NSLog(@"[StatusPNDiag] requestAPNSToken: calling [UIApplication registerForRemoteNotifications]");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] registerForRemoteNotifications];
    });
}

void PushNotificationIOS::showNotification(const QString& title,
                                          const QString& message,
                                          const QString& identifier,
                                          const QString& threadIdentifier)
{
    const QString titleCopy = title;
    const QString messageCopy = message;
    const QString identifierCopy = identifier;
    const QString threadIdentifierCopy = threadIdentifier;

    auto showBlock = ^{
        UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
        content.title = titleCopy.toNSString();
        content.body = messageCopy.toNSString();
        content.sound = [UNNotificationSound defaultSound];
        content.badge = @([[UIApplication sharedApplication] applicationIconBadgeNumber] + 1);

        content.userInfo = @{@"identifier": identifierCopy.toNSString()};

        if (!threadIdentifierCopy.isEmpty())
            content.threadIdentifier = threadIdentifierCopy.toNSString();

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
    NSLog(@"[StatusPNDiag] onAPNSTokenReceived: token length=%lu first16=%@",
          (unsigned long)token.length(),
          token.length() >= 16 ? token.left(16).toNSString() : token.toNSString());

    if (m_tokenCallback != nullptr) {
        m_tokenCallback(token.toUtf8().constData());
    }

    emit tokenReceived(token);
    NSLog(@"[StatusPNDiag] onAPNSTokenReceived: emitted tokenReceived signal");
}

void PushNotificationIOS::onRemoteNotificationReceived()
{
    NSLog(@"[StatusPNDiag] onRemoteNotificationReceived: marshaling remoteNotificationReceived to main thread");

    QMetaObject::invokeMethod(this, [this]() {
        emit remoteNotificationReceived();
    }, Qt::QueuedConnection);

    // (Re)arm the safety timer so iOS's background budget is honored even if
    // status-desktop never calls finishBackgroundFetch(). Timer lives on the main queue.
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
                if (s_pendingCompletions != nil && s_pendingCompletions.count > 0) {
                    NSLog(@"[StatusPNDiag] background fetch safety timer fired with %lu pending completion(s); finishing best-effort (NewData)",
                          (unsigned long)s_pendingCompletions.count);
                    if (auto* inst = PushNotificationIOS::instance()) {
                        inst->finishBackgroundFetch(true);
                    }
                }
            }];
        NSLog(@"[StatusPNDiag] onRemoteNotificationReceived: armed %.0fs safety timer", kBackgroundFetchSafetyInterval);
    });
}

void PushNotificationIOS::enqueueBackgroundCompletion(void* handler)
{
    if (handler == nullptr) {
        NSLog(@"[StatusPNDiag] enqueueBackgroundCompletion: null handler, ignoring");
        return;
    }

    // Copy the block now (it is stack-allocated at the call site) and retain it for later.
    void (^completion)(UIBackgroundFetchResult) = [(__bridge void (^)(UIBackgroundFetchResult))handler copy];

    // Mutate the shared array only on the main queue to avoid races with finishBackgroundFetch.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_pendingCompletions == nil) {
            s_pendingCompletions = [[NSMutableArray alloc] init];
        }
        [s_pendingCompletions addObject:completion];
        NSLog(@"[StatusPNDiag] enqueueBackgroundCompletion: now %lu pending completion(s)",
              (unsigned long)s_pendingCompletions.count);
    });
}

void PushNotificationIOS::finishBackgroundFetch(bool hadNewData)
{
    // Drain on the main queue so the array/timer are only ever touched from one thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[StatusPNDiag] finishBackgroundFetch: DRAIN-ENTER (hadNewData=%d)", hadNewData); // PNDBG
        if (s_backgroundFetchSafetyTimer != nil) {
            [s_backgroundFetchSafetyTimer invalidate];
            s_backgroundFetchSafetyTimer = nil;
        }

        if (s_pendingCompletions == nil || s_pendingCompletions.count == 0) {
            NSLog(@"[StatusPNDiag] finishBackgroundFetch(hadNewData=%d): no pending completions, no-op", hadNewData);
            return;
        }

        // Snapshot then clear first, so re-entrant calls (or a late timer) see an empty queue.
        NSArray* completions = [s_pendingCompletions copy];
        [s_pendingCompletions removeAllObjects];

        const UIBackgroundFetchResult result =
            hadNewData ? UIBackgroundFetchResultNewData : UIBackgroundFetchResultNoData;
        NSLog(@"[StatusPNDiag] finishBackgroundFetch(hadNewData=%d): invoking %lu completion(s) with result=%ld",
              hadNewData, (unsigned long)completions.count, (long)result);

        int pndbgIdx = 0;
        for (id obj in completions) {
            NSLog(@"[StatusPNDiag] finishBackgroundFetch: PRE-invoke completion #%d", pndbgIdx);  // PNDBG
            void (^completion)(UIBackgroundFetchResult) = (void (^)(UIBackgroundFetchResult))obj;
            completion(result);
            NSLog(@"[StatusPNDiag] finishBackgroundFetch: POST-invoke completion #%d", pndbgIdx); // PNDBG
            pndbgIdx++;
        }
        NSLog(@"[StatusPNDiag] finishBackgroundFetch: DRAIN-DONE"); // PNDBG
    });
}

#endif // Q_OS_IOS
