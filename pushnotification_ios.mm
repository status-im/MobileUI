#include "pushnotification_ios.h"
#include "mobileuiappdelegate_ios.h"

#ifdef Q_OS_IOS

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <UIKit/UIKit.h>

// Apple's Intents headers (e.g. INActivateCarSignalIntent.h) declare a property named
// `signals`, which collides with Qt's `signals` macro (expands to `public`). Suspend Qt's
// moc keyword macros just for this import, then restore them.
#pragma push_macro("signals")
#pragma push_macro("slots")
#undef signals
#undef slots
#import <Intents/Intents.h>
#pragma pop_macro("slots")
#pragma pop_macro("signals")

#include <QCoreApplication>
#include <QMetaObject>
#include <QDesktopServices>
#include <QUrl>

PushNotificationIOS* PushNotificationIOS::s_instance = nullptr;
static NotificationPermissionCallback s_permissionCallback = nullptr;

// Pending iOS UIBackgroundFetchResult completion blocks awaiting status-desktop's
// finishBackgroundFetch() (or the safety timer). Touched only on the main queue.
static NSMutableArray* s_pendingCompletions = nil;
// Safety timer that fires finishBackgroundFetch(true) if status-desktop never reports
// back within iOS's ~30s background budget. Touched only on the main queue.
static NSTimer* s_backgroundFetchSafetyTimer = nil;
static const NSTimeInterval kBackgroundFetchSafetyInterval = 25.0;

static void emitPermissionChanged(bool granted)
{
    if (auto* inst = PushNotificationIOS::instance()) {
        QMetaObject::invokeMethod(inst, [inst, granted]() {
            emit inst->notificationPermissionChanged(granted);
        }, Qt::QueuedConnection);
    }
}

// Routes a tapped notification's deep link into the app's existing in-app status-app://
// URL handler (registered at startup via QDesktopServices::setUrlHandler in DOtherSide's
// UrlSchemeEvent). This mirrors Android's PendingIntent(ACTION_VIEW, deepLink): both feed
// the same UrlsManager -> activateStatusDeepLink path that opens the conversation.
@interface StatusUNDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation StatusUNDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter*)center
    didReceiveNotificationResponse:(UNNotificationResponse*)response
             withCompletionHandler:(void (^)(void))completionHandler
{
    (void)center;
    NSString* deepLink = response.notification.request.content.userInfo[@"deepLink"];
    if (deepLink.length > 0) {
        const QString url = QString::fromNSString(deepLink);
        // Hop onto the Qt/GUI thread: openUrl() synchronously invokes the registered
        // status-app handler, which must run where the QML engine lives.
        QMetaObject::invokeMethod(qApp, [url]() {
            QDesktopServices::openUrl(QUrl(url));
        }, Qt::QueuedConnection);
    }
    completionHandler();
}

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       willPresentNotification:(UNNotification*)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
{
    (void)center;
    // Real message notifications are meant for the background, so we suppress them while
    // the app is in the foreground (the default). The in-app TEST notification is the one
    // exception — surface it so the settings "send test notification" button is verifiable.
    if ([notification.request.identifier isEqualToString:@"status-test-notification"]) {
        completionHandler(UNNotificationPresentationOptionBanner
                          | UNNotificationPresentationOptionList
                          | UNNotificationPresentationOptionSound);
    } else {
        completionHandler(UNNotificationPresentationOptionNone);
    }
}
@end

PushNotificationIOS::PushNotificationIOS(QObject* parent)
    : QObject(parent)
    , m_initialized(false)
    , m_permissionState(-1)
    , m_permissionStatus(-1)
    , m_permissionObserverAdded(false)
{
}

PushNotificationIOS* PushNotificationIOS::instance()
{
    if (!s_instance) {
        s_instance = new PushNotificationIOS(qApp);
    }
    return s_instance;
}

void PushNotificationIOS::initialize(PushNotificationTokenCallback tokenCallback)
{
    if (m_initialized) {
        return;
    }

    mobileui_initIOSAppDelegateCategory();

    m_tokenCallback = tokenCallback;
    refreshNotificationPermissionCache();

    if (!m_permissionObserverAdded) {
        m_permissionObserverAdded = true;
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification* notification) {
                        (void)notification;
                        if (auto* inst = PushNotificationIOS::instance()) {
                            inst->refreshNotificationPermissionCache();
                        }
                    }];
    }

    // Set the notification-center delegate so taps route their deep link into the app.
    // The center keeps only a WEAK reference to its delegate, so keep ours alive in a
    // static (MRC: intentionally retained for the process lifetime).
    static StatusUNDelegate* s_unDelegate = nil;
    if (!s_unDelegate) {
        s_unDelegate = [[StatusUNDelegate alloc] init];
        [UNUserNotificationCenter currentNotificationCenter].delegate = s_unDelegate;
    }

    m_initialized = true;
}

void PushNotificationIOS::setNotificationPermissionCallback(NotificationPermissionCallback callback)
{
    s_permissionCallback = callback;
}

bool PushNotificationIOS::hasNotificationPermission()
{
    int cached = m_permissionState.load();
    if (cached == -1) {
        refreshNotificationPermissionCache();
        return false;
    }

    return cached == 1;
}

void PushNotificationIOS::refreshNotificationPermissionCache()
{
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
    auto* self = this;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings* settings) {
        self->updatePermissionCacheWithStatus(settings.authorizationStatus, false);
    }];
}

void PushNotificationIOS::updatePermissionCacheWithStatus(int status, bool forceEmit)
{
    const bool granted = (status == UNAuthorizationStatusAuthorized);
    const int newValue = granted ? 1 : 0;
    const int previous = m_permissionState.exchange(newValue);
    m_permissionStatus.store(status);
    if (forceEmit || previous != newValue) {
        emitPermissionChanged(granted);
    }
}

void PushNotificationIOS::updatePermissionGranted(bool granted, bool forceEmit)
{
    const int newValue = granted ? 1 : 0;
    const int previous = m_permissionState.exchange(newValue);
    if (forceEmit || previous != newValue) {
        emitPermissionChanged(granted);
    }
}

bool PushNotificationIOS::isNotificationPermissionRequestable()
{
    int cachedStatus = m_permissionStatus.load();
    if (cachedStatus == -1) {
        refreshNotificationPermissionCache();
        return true;
    }

    return cachedStatus != UNAuthorizationStatusDenied;
}

void PushNotificationIOS::requestNotificationPermission()
{
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];

    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings* settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusAuthorized) {
            updatePermissionCacheWithStatus(settings.authorizationStatus, true);
            dispatch_async(dispatch_get_main_queue(), ^{
                [[UIApplication sharedApplication] registerForRemoteNotifications];
            });
            if (s_permissionCallback != nullptr) {
                s_permissionCallback(1);
            }
        } else if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            UNAuthorizationOptions options = UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge;

            [center requestAuthorizationWithOptions:options
                                  completionHandler:^(BOOL granted, NSError* error) {
                if (error) {
                    updatePermissionGranted(false, true);
                    if (s_permissionCallback != nullptr) {
                        s_permissionCallback(0);
                    }
                    return;
                }

                if (granted) {
                    updatePermissionCacheWithStatus(UNAuthorizationStatusAuthorized, true);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[UIApplication sharedApplication] registerForRemoteNotifications];
                    });
                    if (s_permissionCallback != nullptr) {
                        s_permissionCallback(1);
                    }
                } else {
                    updatePermissionCacheWithStatus(UNAuthorizationStatusDenied, true);
                    if (s_permissionCallback != nullptr) {
                        s_permissionCallback(0);
                    }
                }
            }];
        } else {
            updatePermissionCacheWithStatus(settings.authorizationStatus, true);
            if (s_permissionCallback != nullptr) {
                s_permissionCallback(0);
            }
        }
    }];
}

void PushNotificationIOS::openNotificationSettings()
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL* url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        if (!url) {
            return;
        }

        UIApplication* app = [UIApplication sharedApplication];
        if (!app) {
            return;
        }

        if (@available(iOS 10.0, *)) {
            [app openURL:url options:@{} completionHandler:nil];
        } else {
            [app openURL:url];
        }
    });
}

void PushNotificationIOS::requestAPNSToken()
{
    if (!hasNotificationPermission()) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] registerForRemoteNotifications];
    });
}

// Decodes a base64 image (optionally prefixed with a "data:...;base64," URI) into a UIImage.
// We deliberately rely on base64 ONLY: the media server backing http(s) avatar URLs is
// unreachable while the app is backgrounded (observed "Connection refused"), so a URL fetch
// here would just fail. Returns nil when the string is empty, a URL, or not decodable.
static UIImage* pn_imageFromBase64(NSString* s)
{
    if (s.length == 0)
        return nil;
    NSString* b64 = s;
    const NSRange marker = [s rangeOfString:@";base64,"];
    if (marker.location != NSNotFound)
        b64 = [s substringFromIndex:NSMaxRange(marker)];
    else if ([s hasPrefix:@"data:"] || [s hasPrefix:@"http"])
        return nil; // a URL or non-base64 data URI — nothing we can render offline
    NSData* data = [[[NSData alloc] initWithBase64EncodedString:b64
        options:NSDataBase64DecodingIgnoreUnknownCharacters] autorelease];
    if (data.length == 0)
        return nil;
    return [UIImage imageWithData:data];
}

// Colored-initials avatar, mirroring Android's createInitialsAvatar fallback for senders
// without a picture. The hue is derived from the name so a contact keeps a stable color.
static UIImage* pn_initialsAvatar(NSString* name, CGFloat size)
{
    NSString* trimmed = [name stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString* initial = trimmed.length > 0 ? [[trimmed substringToIndex:1] uppercaseString] : @"?";

    NSUInteger hash = 5381;
    for (NSUInteger i = 0; i < name.length; ++i)
        hash = ((hash << 5) + hash) + [name characterAtIndex:i];
    CGFloat hue = (hash % 360) / 360.0;
    UIColor* bg = [UIColor colorWithHue:hue saturation:0.55 brightness:0.75 alpha:1.0];

    UIGraphicsImageRenderer* renderer = [[[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(size, size)] autorelease];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* ctx) {
        CGRect rect = CGRectMake(0, 0, size, size);
        [bg setFill];
        CGContextFillEllipseInRect(ctx.CGContext, rect);
        UIFont* font = [UIFont systemFontOfSize:size * 0.42 weight:UIFontWeightSemibold];
        NSDictionary* attrs = @{ NSFontAttributeName: font,
                                 NSForegroundColorAttributeName: [UIColor whiteColor] };
        CGSize textSize = [initial sizeWithAttributes:attrs];
        CGPoint origin = CGPointMake((size - textSize.width) / 2.0,
                                     (size - textSize.height) / 2.0);
        [initial drawAtPoint:origin withAttributes:attrs];
    }];
}

void PushNotificationIOS::showNotification(const QString& title,
                                           const QString& body,
                                           const QString& identifier,
                                           const QString& threadIdentifier,
                                           const QString& senderName,
                                           const QString& senderId,
                                           const QString& avatarBase64,
                                           const QString& conversationName,
                                           const QString& conversationImageBase64,
                                           const QString& deepLink)
{
    // Snapshot every field by value; the block below runs on the main queue.
    const QString idCopy           = identifier;
    const QString titleCopy        = title;
    const QString bodyCopy         = body;
    const QString threadCopy       = threadIdentifier;
    const QString senderNameCopy   = senderName;
    const QString senderIdCopy     = senderId;
    const QString convNameCopy     = conversationName;
    const QString avatarB64Copy    = avatarBase64;
    const QString convImageB64Copy = conversationImageBase64;
    const QString deepLinkCopy     = deepLink;

    auto showBlock = ^{
        NSString* identifier = idCopy.toNSString();
        NSString* title      = titleCopy.toNSString();
        NSString* body       = bodyCopy.toNSString();
        NSString* threadId   = threadCopy.toNSString();
        NSString* senderName = senderNameCopy.toNSString();
        NSString* senderId   = senderIdCopy.toNSString();
        NSString* convName     = convNameCopy.toNSString();
        NSString* convImageB64 = convImageB64Copy.toNSString();
        NSString* deepLink     = deepLinkCopy.toNSString();

        // We show only the sender's avatar (base64, with an Android-style initials
        // fallback). The conversation context goes in the subtitle text below, not as a
        // composited badge — iOS already stamps its own non-removable app-icon overlay.
        UIImage* personImage = pn_imageFromBase64(avatarB64Copy.toNSString());
        if (!personImage)
            personImage = pn_initialsAvatar(senderName.length > 0 ? senderName : convName, 256.0);

        // Base text content — used as-is if the communication-notification path fails.
        UNMutableNotificationContent* content = [[[UNMutableNotificationContent alloc] init] autorelease];
        // The title is the conversation, so the user can tell a message's origin apart:
        // the sender's name for 1:1, or the group / "community · channel" name otherwise.
        // speakableGroupName (below) drives the same distinction in the communication-
        // notification layout (where the subtitle is not reliably shown).
        content.title = convName.length > 0 ? convName : title;
        content.body = body;
        content.sound = nil; // silent: replaces the already-delivered generic remote push
        content.badge = @([[UIApplication sharedApplication] applicationIconBadgeNumber] + 1);
        // Carry the deep link so a tap can route into the conversation (see the
        // UNUserNotificationCenterDelegate below).
        NSMutableDictionary* userInfo =
            [NSMutableDictionary dictionaryWithObject:identifier forKey:@"identifier"];
        if (deepLink.length > 0)
            userInfo[@"deepLink"] = deepLink;
        content.userInfo = userInfo;
        if (threadId.length > 0)
            content.threadIdentifier = threadId;

        UNNotificationContent* finalContent = content;

        // iOS 15+ Communication Notification: donate an INSendMessageIntent so the system
        // renders the sender avatar (plus its automatic app-icon overlay).
        if (@available(iOS 15.0, *)) {
            @try {
                INImage* inImage = personImage ? [INImage imageWithUIImage:personImage] : nil;
                INPersonHandle* handle = [[[INPersonHandle alloc]
                    initWithValue:senderId type:INPersonHandleTypeUnknown] autorelease];
                INPerson* sender = [[[INPerson alloc]
                    initWithPersonHandle:handle
                          nameComponents:nil
                             displayName:senderName
                                   image:inImage
                       contactIdentifier:nil
                        customIdentifier:senderId] autorelease];

                // A communication notification needs a recipient list, and iOS only honors
                // speakableGroupName when the message looks like a GROUP — i.e. has more
                // than one recipient. So we add the local user ("me") plus the sender for
                // group/community, and just "me" for 1:1. With recipients:nil every type
                // fell back to the sender, which is why they all looked identical.
                INPersonHandle* meHandle = [[[INPersonHandle alloc]
                    initWithValue:@"me" type:INPersonHandleTypeUnknown] autorelease];
                INPerson* mePerson = [[[INPerson alloc]
                    initWithPersonHandle:meHandle nameComponents:nil displayName:nil image:nil
                    contactIdentifier:nil customIdentifier:nil isMe:YES
                    suggestionType:INPersonSuggestionTypeNone] autorelease];
                NSArray<INPerson*>* recipients = convName.length > 0
                    ? @[mePerson, sender]   // >1 recipient -> GROUP -> speakableGroupName shows
                    : @[mePerson];          // 1:1
                INSpeakableString* groupName = convName.length > 0
                    ? [[[INSpeakableString alloc] initWithSpokenPhrase:convName] autorelease]
                    : nil;
                INSendMessageIntent* intent = [[[INSendMessageIntent alloc]
                    initWithRecipients:recipients
                    outgoingMessageType:INOutgoingMessageTypeOutgoingMessageText
                    content:nil
                    speakableGroupName:groupName
                    conversationIdentifier:(threadId.length > 0 ? threadId : identifier)
                    serviceName:nil
                    sender:sender
                    attachments:nil] autorelease];
                if (inImage)
                    [intent setImage:inImage forParameterNamed:@"sender"];
                // Group/community: feed the conversation (group/community) icon to the
                // group image slot. Now that recipients mark this as a group, iOS should
                // render speakableGroupName's image as the conversation icon.
                if (convName.length > 0) {
                    UIImage* convImg = pn_imageFromBase64(convImageB64);
                    if (convImg)
                        [intent setImage:[INImage imageWithUIImage:convImg]
                            forParameterNamed:@"speakableGroupName"];
                }

                INInteraction* interaction = [[[INInteraction alloc] initWithIntent:intent response:nil] autorelease];
                interaction.direction = INInteractionDirectionIncoming;
                [interaction donateInteractionWithCompletion:nil];

                NSError* updErr = nil;
                UNNotificationContent* updated =
                    [content contentByUpdatingWithProvider:intent error:&updErr];
                if (updated && !updErr) {
                    finalContent = updated;
                    qDebug("Status push: enriched notification posted");
                } else {
                    qWarning("Status push: failed to enrich notification: %s",
                             updErr ? updErr.localizedDescription.UTF8String : "unknown");
                }
            } @catch (NSException* ex) {
                qWarning("Status push: enrich exception: %s", ex.reason.UTF8String);
            }
        }

        UNTimeIntervalNotificationTrigger* trigger = [UNTimeIntervalNotificationTrigger
            triggerWithTimeInterval:0.1 repeats:NO];
        UNNotificationRequest* request = [UNNotificationRequest
            requestWithIdentifier:identifier content:finalContent trigger:trigger];

        UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
        // Remove the already-delivered generic remote push for this message before posting
        // the enriched one (see showNotification for the full rationale).
        [center removeDeliveredNotificationsWithIdentifiers:@[identifier]];
        [center addNotificationRequest:request withCompletionHandler:^(NSError* error) {
            if (error)
                qWarning("Status push: failed to post notification: %s", error.localizedDescription.UTF8String);
        }];
    };

    if ([NSThread isMainThread])
        showBlock();
    else
        dispatch_async(dispatch_get_main_queue(), showBlock);
}

void PushNotificationIOS::clearNotifications(const QString& identifier)
{
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];

    [center removeDeliveredNotificationsWithIdentifiers:@[identifier.toNSString()]];

    [center removePendingNotificationRequestsWithIdentifiers:@[identifier.toNSString()]];
}

void PushNotificationIOS::clearAllNotifications()
{
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
    [center removeAllDeliveredNotifications];
    [center removeAllPendingNotificationRequests];
    [center setBadgeCount:0 withCompletionHandler:nil];   // iOS 16+; deployment target is 26
}

void PushNotificationIOS::onAPNSTokenReceived(const QString& token)
{
    if (m_tokenCallback != nullptr) {
        m_tokenCallback(token.toUtf8().constData());
    }

    emit tokenReceived(token);
}

void PushNotificationIOS::onRemoteNotificationReceived()
{
    QMetaObject::invokeMethod(this, [this]() {
        emit remoteNotificationReceived();
    }, Qt::QueuedConnection);

    // (Re)arm the safety timer so iOS's background budget is honored even if
    // status-desktop never calls finishBackgroundFetch(). Timer lives on the main queue.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_backgroundFetchSafetyTimer != nil) {
            [s_backgroundFetchSafetyTimer invalidate];
            s_backgroundFetchSafetyTimer = nil;
        }
        s_backgroundFetchSafetyTimer = [NSTimer
            scheduledTimerWithTimeInterval:kBackgroundFetchSafetyInterval
                                   repeats:NO
                                     block:^(NSTimer* timer) {
                (void)timer;
                // This non-repeating timer has fired; the run loop is about to
                // release it. This file is built WITHOUT ARC, so the static does
                // not retain the timer — clear it NOW so neither finishBackgroundFetch
                // nor the re-arm path messages the soon-to-be-freed timer (EXC_BAD_ACCESS).
                s_backgroundFetchSafetyTimer = nil;
                if (s_pendingCompletions != nil && s_pendingCompletions.count > 0) {
                    if (auto* inst = PushNotificationIOS::instance()) {
                        inst->finishBackgroundFetch(true);
                    }
                }
            }];
    });
}

void PushNotificationIOS::enqueueBackgroundCompletion(void* handler)
{
    if (handler == nullptr) {
        return;
    }

    // Copy the block now (it is stack-allocated at the call site) and retain it for later.
    void (^completion)(UIBackgroundFetchResult) = [(__bridge void (^)(UIBackgroundFetchResult))handler copy];

    // Mutate the shared array only on the main queue to avoid races with finishBackgroundFetch.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_pendingCompletions == nil) {
            s_pendingCompletions = [[NSMutableArray alloc] init];
        }
        [s_pendingCompletions addObject:completion];
    });
}

void PushNotificationIOS::finishBackgroundFetch(bool hadNewData)
{
    // Drain on the main queue so the array/timer are only ever touched from one thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_backgroundFetchSafetyTimer != nil) {
            [s_backgroundFetchSafetyTimer invalidate];
            s_backgroundFetchSafetyTimer = nil;
        }

        if (s_pendingCompletions == nil || s_pendingCompletions.count == 0) {
            return;
        }

        // Snapshot then clear first, so re-entrant calls (or a late timer) see an empty queue.
        NSArray* completions = [s_pendingCompletions copy];
        [s_pendingCompletions removeAllObjects];

        const UIBackgroundFetchResult result =
            hadNewData ? UIBackgroundFetchResultNewData : UIBackgroundFetchResultNoData;

        for (id obj in completions) {
            void (^completion)(UIBackgroundFetchResult) = (void (^)(UIBackgroundFetchResult))obj;
            completion(result);
        }
    });
}

#endif // Q_OS_IOS
