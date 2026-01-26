#pragma once

#include <QObject>
#include <QString>

#ifdef Q_OS_ANDROID
#include <jni.h>
#endif

#include "pushnotification_callbacks.h"

#ifdef Q_OS_ANDROID

class PushNotificationAndroid : public QObject
{
    Q_OBJECT

public:
    static PushNotificationAndroid* instance();

    void initialize(PushNotificationTokenCallback tokenCallback);

    bool hasNotificationPermission();
    bool isNotificationPermissionRequestable();
    bool areNotificationsEnabled();
    void requestNotificationPermission();
    void openNotificationSettings();
    void setNotificationPermissionCallback(NotificationPermissionCallback callback);
    void showNotification(const QString& title, const QString& message, const QString& identifier);
    void clearNotifications(const QString& chatId);

signals:
    void notificationPermissionChanged(bool granted);
    void notificationTapped(const QString& identifier);

private:
    PushNotificationAndroid(QObject* parent = nullptr);
    ~PushNotificationAndroid() = default;

    void ensureNativeMethodsRegistered();
    void registerNativeMethods();

    static PushNotificationAndroid* s_instance;
    bool m_initialized;
};

#endif // Q_OS_ANDROID
