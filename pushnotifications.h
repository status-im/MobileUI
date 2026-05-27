#pragma once

#include <QObject>
#include <QString>

class PushNotifications : public QObject
{
    Q_OBJECT
    Q_PROPERTY(Status status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString token READ token NOTIFY tokenChanged)

public:
    enum Status {
        Unknown,
        Granted,
        Denied
    };
    Q_ENUM(Status)

    explicit PushNotifications(QObject* parent = nullptr);

    Status status() const;
    QString token() const;

    Q_INVOKABLE void request();
    Q_INVOKABLE void requestToken();
    Q_INVOKABLE void openSettings();
    Q_INVOKABLE void showNotification(const QString& title,
                                      const QString& body,
                                      const QString& identifier,
                                      const QString& threadIdentifier = QString(),
                                      const QString& senderName = QString(),
                                      const QString& senderId = QString(),
                                      const QString& avatarBase64 = QString(),
                                      const QString& conversationName = QString(),
                                      const QString& conversationImageBase64 = QString(),
                                      const QString& deepLink = QString());
    Q_INVOKABLE void clearNotifications(const QString& identifier);
    Q_INVOKABLE void clearAllNotifications();
    Q_INVOKABLE void finishBackgroundFetch(bool hadNewData);

Q_SIGNALS:
    void statusChanged();
    void tokenChanged();
    void remoteNotificationReceived();

private:
    void updateStatus(bool forceEmit = false);
    void setStatus(Status status, bool forceEmit = false);
    void setToken(const QString& token);

    Status m_status = Unknown;
    QString m_token;
};
