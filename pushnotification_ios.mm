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

#endif // Q_OS_IOS
