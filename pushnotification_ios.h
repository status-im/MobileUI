#pragma once

#include <QObject>
#include <QString>

#include "pushnotification_callbacks.h"

#ifdef Q_OS_IOS
#include <atomic>

class PushNotificationIOS : public QObject
{
    Q_OBJECT

public:
    static PushNotificationIOS* instance();

    void initialize(PushNotificationTokenCallback tokenCallback);
    bool hasNotificationPermission();
    bool isNotificationPermissionRequestable();
    void requestNotificationPermission();
    void openNotificationSettings();
    void setNotificationPermissionCallback(NotificationPermissionCallback callback);
    void requestAPNSToken();
    void showNotification(const QString& title, const QString& message, const QString& identifier);
    void clearNotifications(const QString& identifier);
    void onAPNSTokenReceived(const QString& token);
signals:
    void tokenReceived(const QString& token);
    void notificationPermissionChanged(bool granted);
    void notificationTapped(const QString& identifier);

private:
    explicit PushNotificationIOS(QObject* parent = nullptr);
    ~PushNotificationIOS() = default;

    void refreshNotificationPermissionCache();
    void updatePermissionCacheWithStatus(int status, bool forceEmit);
    void updatePermissionGranted(bool granted, bool forceEmit);

    static PushNotificationIOS* s_instance;
    bool m_initialized;
    PushNotificationTokenCallback m_tokenCallback = nullptr;
    std::atomic<int> m_permissionState;
    std::atomic<int> m_permissionStatus;
    bool m_permissionObserverAdded;
};

#endif // Q_OS_IOS
