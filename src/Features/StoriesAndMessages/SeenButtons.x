#import "../../InstagramHeaders.h"
#import "../../Tweak.h"
#import "../../Utils.h"
#import "SCIExcludedThreads.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// Returns the threadId for an IGDirectThreadViewController, or nil.
static NSString *sciThreadIdForVC(id vc) {
    if (!vc) return nil;
    @try { return [vc valueForKey:@"threadId"]; } @catch (__unused id e) { return nil; }
}


// Seen buttons (in DMs)
// - Enables no seen for messages
// - Enables unlimited views of DM visual messages

BOOL dmSeenToggleEnabled = NO;
static BOOL sciSeenAutoBypass = NO;
__weak IGDirectThreadViewController *sciActiveThreadVC = nil;

static BOOL sciIsSeenToggleMode() {
    return [[SCIUtils getStringPref:@"seen_mode"] isEqualToString:@"toggle"];
}

static BOOL sciAutoInteractEnabled() {
    if ([SCIExcludedThreads isActiveThreadExcluded]) return NO;
    return [SCIUtils getBoolPref:@"remove_lastseen"] && [SCIUtils getBoolPref:@"seen_auto_on_interact"];
}

BOOL sciAutoTypingEnabled() {
    if ([SCIExcludedThreads isActiveThreadExcluded]) return NO;
    return [SCIUtils getBoolPref:@"remove_lastseen"] && [SCIUtils getBoolPref:@"seen_auto_on_typing"];
}

void sciDoAutoSeen(IGDirectThreadViewController *threadVC) {
    sciSeenAutoBypass = YES;
    [threadVC markLastMessageAsSeen];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sciSeenAutoBypass = NO;
    });
}

// ============ AUTO SEEN ON SEND ============

static void (*orig_setHasSent)(id self, SEL _cmd, BOOL sent);
static void new_setHasSent(id self, SEL _cmd, BOOL sent) {
    orig_setHasSent(self, _cmd, sent);
    if (!sent || !sciAutoInteractEnabled()) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sciDoAutoSeen((IGDirectThreadViewController *)self);
    });
}

// ============ AUTO SEEN ON TYPING ============
// Tracks the visible thread VC so the typing-service hook (in
// DisableTypingStatus.x) can mark its messages as seen.

%hook IGDirectThreadViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sciActiveThreadVC = self;
}
- (void)viewWillDisappear:(BOOL)animated {
    if (sciActiveThreadVC == self) sciActiveThreadVC = nil;
    %orig;
}
%end

// ============ NAV BAR BUTTONS ============

// Re-runs setRightBarButtonItems with the live items. The hook tags its own
// buttons so they get stripped and rebuilt against the new exclusion state.
static void sciRefreshNavBarItems(UIView *anchor) {
    if (!anchor || ![anchor respondsToSelector:@selector(setRightBarButtonItems:)]) return;
    NSArray *cur = [(id)anchor performSelector:@selector(rightBarButtonItems)];
    [(id)anchor performSelector:@selector(setRightBarButtonItems:) withObject:cur];
}

// Long-press menu shared by the seen button and the un-exclude button.
static UIMenu *sciBuildThreadActionsMenu(UIView *anchor, NSString *threadId, UIWindow *window) {
    BOOL excluded = threadId && [SCIExcludedThreads isThreadIdExcluded:threadId];
    BOOL seenFeatureOn = [SCIUtils getBoolPref:@"remove_lastseen"];

    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];

    if (seenFeatureOn && !excluded) {
        BOOL toggleMode = sciIsSeenToggleMode();
        NSString *title;
        UIImage *img;
        if (toggleMode) {
            title = dmSeenToggleEnabled ? @"Disable read receipts" : @"Enable read receipts";
            img = [UIImage systemImageNamed:dmSeenToggleEnabled ? @"eye.slash" : @"eye"];
        } else {
            title = @"Mark messages as seen";
            img = [UIImage systemImageNamed:@"eye"];
        }
        UIAction *seenAction = [UIAction actionWithTitle:title image:img identifier:nil
                                                 handler:^(__kindof UIAction *_) {
            UIViewController *nearestVC = [SCIUtils nearestViewControllerForView:anchor];
            if (![nearestVC isKindOfClass:%c(IGDirectThreadViewController)]) return;
            if (toggleMode) {
                dmSeenToggleEnabled = !dmSeenToggleEnabled;
                if (dmSeenToggleEnabled) {
                    [(IGDirectThreadViewController *)nearestVC markLastMessageAsSeen];
                    [SCIUtils showToastForDuration:2.0 title:@"Read receipts enabled"];
                } else {
                    [SCIUtils showToastForDuration:2.0 title:@"Read receipts disabled"];
                }
            } else {
                [(IGDirectThreadViewController *)nearestVC markLastMessageAsSeen];
                [SCIUtils showToastForDuration:2.0 title:@"Marked messages as seen"];
            }
        }];
        [items addObject:seenAction];
    }

    NSString *toggleTitle = excluded ? @"Un-exclude chat" : @"Exclude chat";
    UIImage *toggleImg = [UIImage systemImageNamed:excluded ? @"eye.fill" : @"eye.slash"];
    __weak UIView *weakAnchor = anchor;
    UIAction *toggle = [UIAction actionWithTitle:toggleTitle image:toggleImg identifier:nil
                                         handler:^(__kindof UIAction *_) {
        if (!threadId) return;
        if (excluded) {
            [SCIExcludedThreads removeThreadId:threadId];
            [SCIUtils showToastForDuration:2.0 title:@"Un-excluded"];
        } else {
            [SCIExcludedThreads addOrUpdateEntry:@{ @"threadId": threadId,
                                                    @"threadName": @"",
                                                    @"isGroup": @NO,
                                                    @"users": @[] }];
            [SCIUtils showToastForDuration:2.0 title:@"Excluded"];
            // Immediately mark seen since exclusion means normal behavior.
            UIViewController *nearestVC = [SCIUtils nearestViewControllerForView:weakAnchor];
            if ([nearestVC isKindOfClass:%c(IGDirectThreadViewController)])
                [(IGDirectThreadViewController *)nearestVC markLastMessageAsSeen];
        }
        sciRefreshNavBarItems(weakAnchor);
    }];
    if (excluded) toggle.attributes = UIMenuElementAttributesDestructive;
    [items addObject:toggle];

    UIAction *openSettings = [UIAction actionWithTitle:@"Messages settings"
                                                 image:[UIImage systemImageNamed:@"gear"]
                                            identifier:nil
                                               handler:^(__kindof UIAction *_) {
        UIWindow *win = window;
        if (!win) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
        }
        [SCIUtils showSettingsVC:win atTopLevelEntry:@"Messages"];
    }];
    [items addObject:openSettings];

    return [UIMenu menuWithTitle:@"" children:items];
}

%hook IGTallNavigationBarView

%new - (void)sciUnexcludeButtonHandler:(UIBarButtonItem *)sender {
    UIViewController *nearestVC = [SCIUtils nearestViewControllerForView:self];
    NSString *tid = sciThreadIdForVC(nearestVC);
    if (!tid) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Remove from exclusion?"
                         message:@"This chat will resume normal read-receipt behavior."
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
        [SCIExcludedThreads removeThreadId:tid];
        [SCIUtils showToastForDuration:2.0 title:@"Removed from exclusion"];
        sciRefreshNavBarItems(weakSelf);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [nearestVC presentViewController:alert animated:YES completion:nil];
}
- (void)setRightBarButtonItems:(NSArray <UIBarButtonItem *> *)items {
    // Strip our own injected buttons so re-running this hook doesn't dupe them.
    NSMutableArray *new_items = [[items filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(UIBarButtonItem *value, NSDictionary *_) {
            NSString *aid = value.accessibilityIdentifier;
            if ([aid isEqualToString:@"sci-seen-btn"] ||
                [aid isEqualToString:@"sci-unex-btn"] ||
                [aid isEqualToString:@"sci-visual-btn"]) return NO;
            if ([SCIUtils getBoolPref:@"hide_reels_blend"])
                return ![aid isEqualToString:@"blend-button"];
            return YES;
        }]
    ] mutableCopy];

    // setRightBarButtonItems: runs before viewDidAppear: fires, so the global
    // active thread id isn't reliable here — read it directly from the VC.
    UIViewController *navNearestVC = [SCIUtils nearestViewControllerForView:self];
    NSString *navThreadId = sciThreadIdForVC(navNearestVC);
    BOOL navExcluded = navThreadId && [SCIExcludedThreads isThreadIdExcluded:navThreadId];

    if ([SCIUtils getBoolPref:@"remove_lastseen"] && !navExcluded) {
        UIBarButtonItem *seenButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"eye"] style:UIBarButtonItemStylePlain target:self action:@selector(seenButtonHandler:)];
        seenButton.accessibilityIdentifier = @"sci-seen-btn";
        if (sciIsSeenToggleMode())
            [seenButton setTintColor:dmSeenToggleEnabled ? SCIUtils.SCIColor_Primary : UIColor.labelColor];
        seenButton.menu = sciBuildThreadActionsMenu(self, navThreadId, self.window);
        [new_items addObject:seenButton];
    }

    // Excluded chats hide the seen button — surface an un-exclude affordance instead.
    if ([SCIUtils getBoolPref:@"remove_lastseen"] && navExcluded &&
        [SCIUtils getBoolPref:@"unexclude_inbox_button"]) {
        UIBarButtonItem *unexBtn = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"eye.slash.fill"]
                    style:UIBarButtonItemStylePlain
                   target:self
                   action:@selector(sciUnexcludeButtonHandler:)];
        unexBtn.accessibilityIdentifier = @"sci-unex-btn";
        unexBtn.tintColor = SCIUtils.SCIColor_Primary;
        unexBtn.menu = sciBuildThreadActionsMenu(self, navThreadId, self.window);
        [new_items addObject:unexBtn];
    }

    if ([SCIUtils getBoolPref:@"unlimited_replay"] && !navExcluded) {
        UIBarButtonItem *dmVisualMsgsViewedButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"photo.badge.checkmark"] style:UIBarButtonItemStylePlain target:self action:@selector(dmVisualMsgsViewedButtonHandler:)];
        dmVisualMsgsViewedButton.accessibilityIdentifier = @"sci-visual-btn";
        [new_items addObject:dmVisualMsgsViewedButton];
        [dmVisualMsgsViewedButton setTintColor:dmVisualMsgsViewedButtonEnabled ? SCIUtils.SCIColor_Primary : UIColor.labelColor];
    }

    %orig([new_items copy]);
}

// ============ MESSAGES SEEN BUTTON ============

%new - (void)seenButtonHandler:(UIBarButtonItem *)sender {
    if (sciIsSeenToggleMode()) {
        dmSeenToggleEnabled = !dmSeenToggleEnabled;
        [sender setTintColor:dmSeenToggleEnabled ? SCIUtils.SCIColor_Primary : UIColor.labelColor];
        if (dmSeenToggleEnabled) {
            UIViewController *nearestVC = [SCIUtils nearestViewControllerForView:self];
            if ([nearestVC isKindOfClass:%c(IGDirectThreadViewController)])
                [(IGDirectThreadViewController *)nearestVC markLastMessageAsSeen];
            [SCIUtils showToastForDuration:2.5 title:@"Read receipts enabled"];
        } else {
            [SCIUtils showToastForDuration:2.5 title:@"Read receipts disabled"];
        }
    } else {
        UIViewController *nearestVC = [SCIUtils nearestViewControllerForView:self];
        if ([nearestVC isKindOfClass:%c(IGDirectThreadViewController)]) {
            [(IGDirectThreadViewController *)nearestVC markLastMessageAsSeen];
            [SCIUtils showToastForDuration:2.5 title:@"Marked messages as seen"];
        }
    }
}

// ============ DM VISUAL MESSAGES VIEWED BUTTON ============

%new - (void)dmVisualMsgsViewedButtonHandler:(UIBarButtonItem *)sender {
    if (dmVisualMsgsViewedButtonEnabled) {
        dmVisualMsgsViewedButtonEnabled = false;
        [sender setTintColor:UIColor.labelColor];
        [SCIUtils showToastForDuration:4.5 title:@"Visual messages can be replayed without expiring"];
    } else {
        dmVisualMsgsViewedButtonEnabled = true;
        [sender setTintColor:SCIUtils.SCIColor_Primary];
        [SCIUtils showToastForDuration:4.5 title:@"Visual messages will now expire after viewing"];
    }
}
%end

// ============ SEEN BLOCKING LOGIC ============

%hook IGDirectThreadViewListAdapterDataSource
- (BOOL)shouldUpdateLastSeenMessage {
    if ([SCIUtils getBoolPref:@"remove_lastseen"]) {
        if ([SCIExcludedThreads isActiveThreadExcluded]) return %orig; // excluded → behave normally
        if (sciIsSeenToggleMode() && dmSeenToggleEnabled) return %orig;
        if (sciSeenAutoBypass) return %orig;
        return false;
    }
    return %orig;
}
%end

// ============ DM VISUAL MESSAGES VIEWED LOGIC ============

%hook IGDirectVisualMessageViewerEventHandler
- (void)visualMessageViewerController:(id)arg1 didBeginPlaybackForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {
    if ([SCIUtils getBoolPref:@"unlimited_replay"] && !dmVisualMsgsViewedButtonEnabled
        && ![SCIExcludedThreads isActiveThreadExcluded]) return;
    %orig;
}
- (void)visualMessageViewerController:(id)arg1 didEndPlaybackForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 mediaCurrentTime:(CGFloat)arg4 forNavType:(NSInteger)arg5 {
    if ([SCIUtils getBoolPref:@"unlimited_replay"] && !dmVisualMsgsViewedButtonEnabled
        && ![SCIExcludedThreads isActiveThreadExcluded]) return;
    %orig;
}
%end

// ============ RUNTIME HOOKS ============

%ctor {
    Class threadVCClass = NSClassFromString(@"IGDirectThreadViewController");
    if (threadVCClass) {
        SEL sentSel = NSSelectorFromString(@"setHasSentAMessageOrUpdate:");
        if (class_getInstanceMethod(threadVCClass, sentSel)) {
            MSHookMessageEx(threadVCClass, sentSel,
                            (IMP)new_setHasSent, (IMP *)&orig_setHasSent);
        }
    }
}
