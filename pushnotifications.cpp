#include "pushnotifications.h"

#include <QGuiApplication>

#if defined(Q_OS_ANDROID)
#include "pushnotification_android.h"
#elif defined(Q_OS_IOS)
#include "pushnotification_ios.h"
#endif

PushNotifications::PushNotifications(QObject* parent)
    : QObject(parent)
{
#if defined(Q_OS_ANDROID)
    PushNotificationAndroid::instance()->initialize(nullptr);
    connect(PushNotificationAndroid::instance(),
            &PushNotificationAndroid::notificationPermissionChanged,
            this,
            [this](bool) { updateStatus(true); });
#elif defined(Q_OS_IOS)
    PushNotificationIOS::instance()->initialize(nullptr);
    connect(PushNotificationIOS::instance(),
            &PushNotificationIOS::notificationPermissionChanged,
            this,
            [this](bool) { updateStatus(true); });
    connect(PushNotificationIOS::instance(),
            &PushNotificationIOS::tokenReceived,
            this,
            [this](const QString& token) { setToken(token); });
#endif

    if (qApp) {
        connect(qApp, &QGuiApplication::applicationStateChanged, this,
                [this](Qt::ApplicationState state) {
            if (state == Qt::ApplicationActive) {
                updateStatus();
            }
        });
    }

    updateStatus();
}

PushNotifications::Status PushNotifications::status() const
{
    return m_status;
}

QString PushNotifications::token() const
{
    return m_token;
}

void PushNotifications::request()
{
#if defined(Q_OS_ANDROID)
    PushNotificationAndroid::instance()->requestNotificationPermission();
#elif defined(Q_OS_IOS)
    PushNotificationIOS::instance()->requestNotificationPermission();
#else
    updateStatus();
#endif
}

void PushNotifications::requestToken()
{
#if defined(Q_OS_ANDROID)
    // iOS-only for now.
#elif defined(Q_OS_IOS)
    PushNotificationIOS::instance()->requestAPNSToken();
#else
    // iOS-only for now.
#endif
}

void PushNotifications::openSettings()
{
#if defined(Q_OS_ANDROID)
    PushNotificationAndroid::instance()->openNotificationSettings();
#elif defined(Q_OS_IOS)
    PushNotificationIOS::instance()->openNotificationSettings();
#endif
}

void PushNotifications::showNotification(const QString& title,
                                         const QString& message,
                                         const QString& identifier)
{
#if defined(Q_OS_ANDROID)
    PushNotificationAndroid::instance()->showNotification(title, message, identifier);
#elif defined(Q_OS_IOS)
    PushNotificationIOS::instance()->showNotification(title, message, identifier);
#else
    Q_UNUSED(title);
    Q_UNUSED(message);
    Q_UNUSED(identifier);
#endif
}

void PushNotifications::clearNotifications(const QString& identifier)
{
#if defined(Q_OS_ANDROID)
    PushNotificationAndroid::instance()->clearNotifications(identifier);
#elif defined(Q_OS_IOS)
    PushNotificationIOS::instance()->clearNotifications(identifier);
#else
    Q_UNUSED(identifier);
#endif
}

void PushNotifications::setStatus(PushNotifications::Status status, bool forceEmit)
{
    if (!forceEmit && m_status == status) {
        return;
    }
    m_status = status;
    emit statusChanged();
}

void PushNotifications::setToken(const QString& token)
{
    if (m_token == token) {
        return;
    }
    m_token = token;
    emit tokenChanged();
}

void PushNotifications::updateStatus(bool forceEmit)
{
#if defined(Q_OS_ANDROID)
    const bool hasPermission = PushNotificationAndroid::instance()->hasNotificationPermission();
    const bool notificationsEnabled = PushNotificationAndroid::instance()->areNotificationsEnabled();
    const bool requestable = PushNotificationAndroid::instance()->isNotificationPermissionRequestable();

    if (hasPermission && notificationsEnabled) {
        setStatus(Granted, forceEmit);
        return;
    }

    if (!requestable || (hasPermission && !notificationsEnabled)) {
        setStatus(Denied, forceEmit);
        return;
    }

    setStatus(Unknown, forceEmit);
#elif defined(Q_OS_IOS)
    const bool hasPermission = PushNotificationIOS::instance()->hasNotificationPermission();
    if (hasPermission) {
        setStatus(Granted, forceEmit);
        return;
    }

    if (!PushNotificationIOS::instance()->isNotificationPermissionRequestable()) {
        setStatus(Denied, forceEmit);
        return;
    }

    setStatus(Unknown, forceEmit);
#else
    setStatus(Granted, forceEmit);
#endif
}
