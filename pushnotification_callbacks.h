#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#ifndef PUSH_NOTIFICATION_CALLBACKS_DEFINED
#define PUSH_NOTIFICATION_CALLBACKS_DEFINED
typedef void (*PushNotificationTokenCallback)(const char* token);
#endif

#ifndef NOTIFICATION_PERMISSION_CALLBACK_DEFINED
#define NOTIFICATION_PERMISSION_CALLBACK_DEFINED
typedef void (*NotificationPermissionCallback)(int granted);
#endif

#ifdef __cplusplus
}
#endif