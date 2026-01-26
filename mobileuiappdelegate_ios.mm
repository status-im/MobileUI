#import "mobileuiappdelegate_ios.h"
#import <objc/runtime.h>

#include <QString>
#include "pushnotification_ios.h"

static bool s_hasOriginalTokenMethod = false;

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
    });
}

- (void)mobileUISwizzled_application:(UIApplication *)application
    didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
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

@end
