#import "mobileuiappdelegate_ios.h"
#import <objc/runtime.h>

#include <QString>
#include "pushnotification_ios.h"

static bool s_hasOriginalTokenMethod = false;
static bool s_hasOriginalReceiveMethod = false;

void mobileui_initIOSAppDelegateCategory()
{
    [QIOSApplicationDelegate class];
}

@implementation QIOSApplicationDelegate (MobileUIPushNotifications)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class originalClass = NSClassFromString(@"QIOSApplicationDelegate");
        Class swizzledClass = [self class];

        if (!originalClass) {
            return;
        }
        SEL tokenSelector = @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:);
        SEL swizzledTokenSelector = @selector(mobileUISwizzled_application:didRegisterForRemoteNotificationsWithDeviceToken:);

        Method tokenMethod = class_getInstanceMethod(originalClass, tokenSelector);
        s_hasOriginalTokenMethod = (tokenMethod != nullptr);
        Method swizzledTokenMethod = class_getInstanceMethod(swizzledClass, swizzledTokenSelector);

        if (swizzledTokenMethod) {
            if (!tokenMethod) {
                class_addMethod(originalClass, tokenSelector,
                               method_getImplementation(swizzledTokenMethod),
                               method_getTypeEncoding(swizzledTokenMethod));
            } else {
                method_exchangeImplementations(tokenMethod, swizzledTokenMethod);
            }
        }

        SEL receiveSelector = @selector(application:didReceiveRemoteNotification:fetchCompletionHandler:);
        SEL swizzledReceiveSelector = @selector(mobileUISwizzled_application:didReceiveRemoteNotification:fetchCompletionHandler:);

        Method receiveMethod = class_getInstanceMethod(originalClass, receiveSelector);
        s_hasOriginalReceiveMethod = (receiveMethod != nullptr);
        Method swizzledReceiveMethod = class_getInstanceMethod(swizzledClass, swizzledReceiveSelector);

        if (swizzledReceiveMethod) {
            if (!receiveMethod) {
                class_addMethod(originalClass, receiveSelector,
                               method_getImplementation(swizzledReceiveMethod),
                               method_getTypeEncoding(swizzledReceiveMethod));
            } else {
                method_exchangeImplementations(receiveMethod, swizzledReceiveMethod);
            }
        }
    });
}

- (void)mobileUISwizzled_application:(UIApplication *)application
    didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    NSLog(@"[StatusPNDiag] didRegisterForRemoteNotificationsWithDeviceToken: iOS delivered APNS token (length=%lu bytes)",
          (unsigned long)deviceToken.length);
    (void)application;

    const unsigned char *bytes = (const unsigned char *)[deviceToken bytes];
    NSMutableString *hexToken = [NSMutableString stringWithCapacity:(deviceToken.length * 2)];

    for (NSUInteger i = 0; i < deviceToken.length; i++) {
        [hexToken appendFormat:@"%02x", bytes[i]];
    }
    PushNotificationIOS::instance()->onAPNSTokenReceived(
        QString::fromNSString(hexToken)
    );

    if (s_hasOriginalTokenMethod) {
        [self mobileUISwizzled_application:application
            didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
    }
}

- (void)mobileUISwizzled_application:(UIApplication *)application
      didReceiveRemoteNotification:(NSDictionary *)userInfo
            fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    NSLog(@"[StatusPNDiag] didReceiveRemoteNotification (background wake)");
    PushNotificationIOS::instance()->enqueueBackgroundCompletion((__bridge void*)completionHandler);
    PushNotificationIOS::instance()->onRemoteNotificationReceived();
    // CONTENTLESS: do NOT read userInfo content (payload is only Shake256 hashes + flags)
    if (s_hasOriginalReceiveMethod) {
        [self mobileUISwizzled_application:application didReceiveRemoteNotification:userInfo fetchCompletionHandler:completionHandler];
    }
}

- (void)application:(UIApplication *)application
    didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
    (void)application;
    NSLog(@"[StatusPNDiag] didFailToRegisterForRemoteNotificationsWithError: %@",
          error.localizedDescription ?: @"(nil)");
}

@end
