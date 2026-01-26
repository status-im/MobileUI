#pragma once

void mobileui_initIOSAppDelegateCategory();

#ifdef __OBJC__

#import <UIKit/UIKit.h>

@interface QIOSApplicationDelegate : NSObject
@end

@interface QIOSApplicationDelegate (MobileUIPushNotifications)
@end

#endif // __OBJC__
