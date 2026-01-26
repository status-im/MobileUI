#include "pushnotification_android.h"

#ifdef Q_OS_ANDROID

#include <QCoreApplication>
#include <QJniEnvironment>
#include <QJniObject>
#include <QMetaObject>
#include <QtCore/qnativeinterface.h>

static void jni_onNotificationPermissionResult(JNIEnv* env, jobject obj, jboolean granted);

PushNotificationAndroid* PushNotificationAndroid::s_instance = nullptr;
static NotificationPermissionCallback s_permissionCallback = nullptr;
static PushNotificationAndroid* s_qtInstance = nullptr;
static bool s_nativeMethodsRegistered = false;

PushNotificationAndroid::PushNotificationAndroid(QObject* parent)
    : QObject(parent)
    , m_initialized(false)
{
    ensureNativeMethodsRegistered();
}

PushNotificationAndroid* PushNotificationAndroid::instance()
{
    if (!s_instance) {
        s_instance = new PushNotificationAndroid(qApp);
        s_qtInstance = s_instance;
    }
    return s_instance;
}

void PushNotificationAndroid::setNotificationPermissionCallback(NotificationPermissionCallback callback)
{
    s_permissionCallback = callback;
}

void PushNotificationAndroid::initialize(PushNotificationTokenCallback tokenCallback)
{
    if (m_initialized) {
        return;
    }

    Q_UNUSED(tokenCallback);

    {
        QJniEnvironment env;
        if (env.isValid()) {
            QJniObject context = QNativeInterface::QAndroidApplication::context();
            if (context.isValid()) {
                QJniObject::callStaticMethod<void>(
                    "im/status/mobileui/PushNotificationHelper",
                    "initialize",
                    "(Landroid/content/Context;)V",
                    context.object()
                );
                if (env->ExceptionCheck()) {
                    env->ExceptionClear();
                }
            }
        }
    }

    m_initialized = true;
}

bool PushNotificationAndroid::hasNotificationPermission()
{
    QJniEnvironment env;
    if (!env.isValid()) {
        return false;
    }

    QJniObject activity = QNativeInterface::QAndroidApplication::context();
    if (!activity.isValid()) {
        return false;
    }

    jboolean result = QJniObject::callStaticMethod<jboolean>(
        "im/status/mobileui/PushNotificationHelper",
        "hasNotificationPermission",
        "(Landroid/content/Context;)Z",
        activity.object()
    );

    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        return false;
    }

    return result;
}

bool PushNotificationAndroid::isNotificationPermissionRequestable()
{
    QJniEnvironment env;
    if (!env.isValid()) {
        return false;
    }

    QJniObject activity = QNativeInterface::QAndroidApplication::context();
    if (!activity.isValid()) {
        return false;
    }

    jboolean result = QJniObject::callStaticMethod<jboolean>(
        "im/status/mobileui/PushNotificationHelper",
        "isNotificationPermissionRequestable",
        "(Landroid/content/Context;)Z",
        activity.object()
    );

    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        return false;
    }

    return result;
}

bool PushNotificationAndroid::areNotificationsEnabled()
{
    QJniEnvironment env;
    if (!env.isValid()) {
        return false;
    }

    QJniObject activity = QNativeInterface::QAndroidApplication::context();
    if (!activity.isValid()) {
        return false;
    }

    jboolean result = QJniObject::callStaticMethod<jboolean>(
        "im/status/mobileui/PushNotificationHelper",
        "areNotificationsEnabled",
        "(Landroid/content/Context;)Z",
        activity.object()
    );

    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        return false;
    }

    return result;
}

void PushNotificationAndroid::requestNotificationPermission()
{
    ensureNativeMethodsRegistered();
    QJniEnvironment env;
    if (!env.isValid()) {
        return;
    }

    QJniObject activity = QNativeInterface::QAndroidApplication::context();
    if (!activity.isValid()) {
        return;
    }

    QJniObject::callStaticMethod<void>(
        "im/status/mobileui/PushNotificationHelper",
        "requestNotificationPermission",
        "(Landroid/content/Context;)V",
        activity.object()
    );

    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        return;
    }
}

void PushNotificationAndroid::openNotificationSettings()
{
    QJniEnvironment env;
    if (!env.isValid()) {
        return;
    }

    QJniObject context = QNativeInterface::QAndroidApplication::context();
    if (!context.isValid()) {
        return;
    }

    QJniObject::callStaticMethod<void>(
        "im/status/mobileui/PushNotificationHelper",
        "openNotificationSettings",
        "(Landroid/content/Context;)V",
        context.object()
    );

    if (env->ExceptionCheck()) {
        env->ExceptionClear();
    }
}

void PushNotificationAndroid::showNotification(const QString& title,
                                               const QString& message,
                                               const QString& identifier)
{
    QJniEnvironment env;
    if (!env.isValid()) {
        return;
    }

    QJniObject::callStaticMethod<void>(
        "im/status/mobileui/PushNotificationHelper",
        "showNotification",
        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V",
        QJniObject::fromString(title).object<jstring>(),
        QJniObject::fromString(message).object<jstring>(),
        QJniObject::fromString(identifier).object<jstring>()
    );

    if (env->ExceptionCheck()) {
        env->ExceptionClear();
    }
}

void PushNotificationAndroid::clearNotifications(const QString& chatId)
{
    QJniEnvironment env;
    if (!env.isValid()) {
        return;
    }

    QJniObject::callStaticMethod<void>(
        "im/status/mobileui/PushNotificationHelper",
        "clearNotifications",
        "(Ljava/lang/String;)V",
        QJniObject::fromString(chatId).object<jstring>()
    );

    if (env->ExceptionCheck()) {
        env->ExceptionClear();
    }
}

void PushNotificationAndroid::registerNativeMethods()
{
    if (s_nativeMethodsRegistered) {
        return;
    }

    QJniEnvironment env;
    if (!env.isValid()) {
        return;
    }

    QJniObject context = QNativeInterface::QAndroidApplication::context();
    if (!context.isValid()) {
        return;
    }

    QJniObject classLoader = context.callObjectMethod(
        "getClassLoader",
        "()Ljava/lang/ClassLoader;"
    );
    if (!classLoader.isValid()) {
        return;
    }

    QJniObject helperClassObj = classLoader.callObjectMethod(
        "loadClass",
        "(Ljava/lang/String;)Ljava/lang/Class;",
        QJniObject::fromString("im.status.mobileui.PushNotificationHelper").object<jstring>()
    );
    if (!helperClassObj.isValid()) {
        return;
    }

    jclass helperClass = static_cast<jclass>(helperClassObj.object<jclass>());
    if (!helperClass) {
        env->ExceptionClear();
        return;
    }

    JNINativeMethod methods[] = {
        {
            const_cast<char*>("nativeOnNotificationPermissionResult"),
            const_cast<char*>("(Z)V"),
            reinterpret_cast<void*>(jni_onNotificationPermissionResult)
        }
    };

    jint result = env->RegisterNatives(helperClass, methods, 1);
    if (result != JNI_OK) {
        env->ExceptionClear();
    }

    s_nativeMethodsRegistered = true;
}

void PushNotificationAndroid::ensureNativeMethodsRegistered()
{
    if (!s_nativeMethodsRegistered) {
        registerNativeMethods();
    }
}

void jni_onNotificationPermissionResult(JNIEnv* env, jobject obj, jboolean granted)
{
    Q_UNUSED(env);
    Q_UNUSED(obj);

    const int grantedInt = granted ? 1 : 0;
    QObject* receiver = s_qtInstance ? static_cast<QObject*>(s_qtInstance)
                                     : static_cast<QObject*>(QCoreApplication::instance());
    if (!receiver) {
        if (s_permissionCallback != nullptr) {
            s_permissionCallback(grantedInt);
        }
        return;
    }

    QMetaObject::invokeMethod(receiver, [grantedInt]() {
        if (s_permissionCallback != nullptr) {
            s_permissionCallback(grantedInt);
        }

        if (s_qtInstance) {
            emit s_qtInstance->notificationPermissionChanged(grantedInt != 0);
        }
    }, Qt::QueuedConnection);
}

#endif // Q_OS_ANDROID
