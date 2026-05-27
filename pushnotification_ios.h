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
    void showNotification(const QString& title,
                          const QString& body,
                          const QString& identifier,
                          const QString& threadIdentifier = QString(),
                          const QString& senderName = QString(),
                          const QString& senderId = QString(),
                          const QString& avatarBase64 = QString(),
                          const QString& conversationName = QString(),
                          const QString& conversationImageBase64 = QString(),
                          const QString& deepLink = QString());
    void clearNotifications(const QString& identifier);
    void clearAllNotifications();
    void onAPNSTokenReceived(const QString& token);
    void onRemoteNotificationReceived();              // marshals a queued signal to the main thread
    void enqueueBackgroundCompletion(void* handler);  // stores a copied UIBackgroundFetchResult completion block (void* keeps header ObjC-free)
    void finishBackgroundFetch(bool hadNewData);      // drains all pending completion blocks
signals:
    void tokenReceived(const QString& token);
    void notificationPermissionChanged(bool granted);
    void notificationTapped(const QString& identifier);
    void remoteNotificationReceived();

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
