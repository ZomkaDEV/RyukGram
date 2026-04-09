#import "../../Utils.h"
#import "../../InstagramHeaders.h"
#import "SCIExcludedThreads.h"
#import <objc/runtime.h>
#import <substrate.h>

// Keep-deleted messages.
//
// Pipeline: each iris delta is per-thread, so its threadId is stashed in TLS
// while the orig handler runs. The IGDirectMessageUpdate alloc hook stamps
// new updates with that tid. At apply time we classify each update; remote
// unsends get their _removeMessages_messageKeys cleared in place so IG's
// applicator runs but removes nothing.
//
// _removeMessages_reason: 0 = unsend, 2 = delete-for-you.

// ============ STATE ============

#define SCI_SENDER_MAP_MAX        4000
#define SCI_CONTENT_CLASSES_MAX   4000
#define SCI_PENDING_MAX           500
#define SCI_PRESERVED_MAX         200
#define SCI_PRESERVED_IDS_KEY     @"SCIPreservedMsgIds"
#define SCI_PRESERVED_TAG         1399

static NSString * const kSCIDeltaTidTLSKey = @"SCI.currentDeltaTid";
static const void *kSCIUpdateThreadIdKey = &kSCIUpdateThreadIdKey;

static BOOL                                            sciLocalDeleteInProgress = NO;
static NSMutableArray                                 *sciPendingUpdates        = nil;
static NSMutableDictionary<NSString *, NSDate *>      *sciDeleteForYouKeys      = nil;
static NSMutableSet                                   *sciPreservedIds          = nil;
static NSMutableDictionary<NSString *, NSString *>    *sciMessageContentClasses = nil;
static NSMutableDictionary<NSString *, NSString *>    *sciSenderPkBySid         = nil;
static NSMutableSet<NSString *>                       *sciPendingLocalSids      = nil;

static void sciUpdateCellIndicator(id cell);

// ============ HELPERS ============

static NSString *sciGetCurrentDeltaTid(void) {
    return [NSThread currentThread].threadDictionary[kSCIDeltaTidTLSKey];
}

static void sciSetCurrentDeltaTid(NSString *tid) {
    NSMutableDictionary *td = [NSThread currentThread].threadDictionary;
    if (tid) td[kSCIDeltaTidTLSKey] = tid;
    else     [td removeObjectForKey:kSCIDeltaTidTLSKey];
}

static BOOL sciKeepDeletedEnabled() {
    return [SCIUtils getBoolPref:@"keep_deleted_message"];
}

static BOOL sciIndicateUnsentEnabled() {
    return [SCIUtils getBoolPref:@"indicate_unsent_messages"];
}

NSMutableSet *sciGetPreservedIds() {
    if (!sciPreservedIds) {
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:SCI_PRESERVED_IDS_KEY];
        sciPreservedIds = saved ? [NSMutableSet setWithArray:saved] : [NSMutableSet set];
    }
    return sciPreservedIds;
}

static void sciSavePreservedIds() {
    NSMutableSet *ids = sciGetPreservedIds();
    while (ids.count > SCI_PRESERVED_MAX)
        [ids removeObject:[ids anyObject]];
    [[NSUserDefaults standardUserDefaults] setObject:[ids allObjects] forKey:SCI_PRESERVED_IDS_KEY];
}

void sciClearPreservedIds() {
    [sciGetPreservedIds() removeAllObjects];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:SCI_PRESERVED_IDS_KEY];
}

static NSMutableSet<NSString *> *sciGetPendingLocalSids() {
    if (!sciPendingLocalSids) sciPendingLocalSids = [NSMutableSet set];
    return sciPendingLocalSids;
}

static NSMutableDictionary<NSString *, NSString *> *sciGetSenderMap() {
    if (!sciSenderPkBySid) sciSenderPkBySid = [NSMutableDictionary dictionary];
    return sciSenderPkBySid;
}

static void sciTrackSenderPk(NSString *sid, NSString *pk) {
    if (!sid.length || !pk.length) return;
    NSMutableDictionary *m = sciGetSenderMap();
    m[sid] = pk;
    if (m.count > SCI_SENDER_MAP_MAX) {
        NSArray *keys = [m allKeys];
        for (NSUInteger i = 0; i < keys.count / 10; i++) [m removeObjectForKey:keys[i]];
    }
}

static NSMutableDictionary<NSString *, NSString *> *sciGetContentClasses() {
    if (!sciMessageContentClasses) sciMessageContentClasses = [NSMutableDictionary dictionary];
    return sciMessageContentClasses;
}

static void sciTrackInsertedMessage(NSString *sid, NSString *className) {
    if (!sid.length || !className.length) return;
    NSMutableDictionary *map = sciGetContentClasses();
    map[sid] = className;
    if (map.count > SCI_CONTENT_CLASSES_MAX) {
        NSArray *keys = [map allKeys];
        for (NSUInteger i = 0; i < keys.count / 10; i++) [map removeObjectForKey:keys[i]];
    }
}

static BOOL sciIsReactionRelatedMessage(NSString *sid) {
    if (!sid.length) return NO;
    NSString *className = sciGetContentClasses()[sid];
    if (!className.length) return NO;
    return [className containsString:@"Reaction"] ||
           [className containsString:@"ActionLog"] ||
           [className containsString:@"reaction"] ||
           [className containsString:@"actionLog"];
}

// Walks IGWindow.userSession.user trying common pk field names. Cached.
static NSString *sciCurrentUserPk() {
    static NSString *cached = nil;
    if (cached) return cached;
    @try {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            id session = nil;
            @try { session = [w valueForKey:@"userSession"]; } @catch (__unused id e) {}
            if (!session) continue;
            id user = nil;
            @try { user = [session valueForKey:@"user"]; } @catch (__unused id e) {}
            if (!user) continue;
            for (NSString *key in @[@"pk", @"instagramUserID", @"instagramUserId", @"userID", @"userId", @"identifier"]) {
                @try {
                    id v = [user valueForKey:key];
                    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
                        cached = [v copy];
                        return cached;
                    }
                    if ([v isKindOfClass:[NSNumber class]]) {
                        cached = [[(NSNumber *)v stringValue] copy];
                        return cached;
                    }
                } @catch (__unused id e) {}
            }
        }
    } @catch (__unused id e) {}
    return nil;
}

static NSString *sciExtractServerId(id key) {
    @try {
        Ivar sidIvar = class_getInstanceVariable([key class], "_messageServerId");
        if (sidIvar) {
            NSString *sid = object_getIvar(key, sidIvar);
            if ([sid isKindOfClass:[NSString class]] && sid.length > 0) return sid;
        }
    } @catch(id e) {}
    return nil;
}

// ============ IRIS DELTA STAMPING ============

static NSString *sciDeltaThreadId(id delta) {
    @try {
        id payload = [delta valueForKey:@"payload"];
        if (!payload) return nil;
        Ivar tdIvar = class_getInstanceVariable([payload class], "_threadDeltaPayload");
        id threadDelta = tdIvar ? object_getIvar(payload, tdIvar) : nil;
        if (!threadDelta) return nil;
        return [threadDelta valueForKey:@"threadId"];
    } @catch (__unused id e) { return nil; }
}

static void (*orig_handleIrisDeltas)(id self, SEL _cmd, NSArray *deltas);
static void new_handleIrisDeltas(id self, SEL _cmd, NSArray *deltas) {
    if (!deltas || deltas.count == 0) { orig_handleIrisDeltas(self, _cmd, deltas); return; }
    for (id delta in deltas) {
        sciSetCurrentDeltaTid(sciDeltaThreadId(delta));
        @try { orig_handleIrisDeltas(self, _cmd, @[delta]); } @catch (__unused id e) {}
        sciSetCurrentDeltaTid(nil);
    }
}

// Some IG paths bypass the top-level handler and call the per-thread variant.
static void (*orig_handleIrisDeltasGrouped)(id self, SEL _cmd, NSArray *deltas);
static void new_handleIrisDeltasGrouped(id self, SEL _cmd, NSArray *deltas) {
    if (!deltas || deltas.count == 0) { orig_handleIrisDeltasGrouped(self, _cmd, deltas); return; }
    sciSetCurrentDeltaTid(sciDeltaThreadId(deltas.firstObject));
    @try { orig_handleIrisDeltasGrouped(self, _cmd, deltas); } @catch (__unused id e) {}
    sciSetCurrentDeltaTid(nil);
}

// ============ ALLOC TRACKING ============

static id (*orig_msgUpdate_alloc)(id self, SEL _cmd);
static id new_msgUpdate_alloc(id self, SEL _cmd) {
    id instance = orig_msgUpdate_alloc(self, _cmd);
    if (instance && sciKeepDeletedEnabled()) {
        NSString *tid = sciGetCurrentDeltaTid();
        if (tid) {
            objc_setAssociatedObject(instance, kSCIUpdateThreadIdKey, tid,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        if (!sciPendingUpdates) sciPendingUpdates = [NSMutableArray array];
        @synchronized(sciPendingUpdates) {
            [sciPendingUpdates addObject:instance];
            while (sciPendingUpdates.count > SCI_PENDING_MAX)
                [sciPendingUpdates removeObjectAtIndex:0];
        }
    }
    return instance;
}

// ============ REMOTE UNSEND DETECTION ============

static void sciPruneStaleDeleteForYouKeys() {
    if (!sciDeleteForYouKeys) return;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-10.0];
    for (NSString *k in [sciDeleteForYouKeys allKeys]) {
        if ([sciDeleteForYouKeys[k] compare:cutoff] == NSOrderedAscending)
            [sciDeleteForYouKeys removeObjectForKey:k];
    }
}

// Clear the keys ivar in place — IG's later apply iterates an empty list.
static void sciNeuterRemoveUpdate(id update) {
    @try {
        Ivar ivar = class_getInstanceVariable([update class], "_removeMessages_messageKeys");
        if (ivar) object_setIvar(update, ivar, nil);
    } @catch (__unused id e) {}
}

static void sciProcessOneUpdate(id update, NSMutableSet<NSString *> *preserved) {
    @try {
        Ivar removeIvar = class_getInstanceVariable([update class], "_removeMessages_messageKeys");
        if (!removeIvar) return;
        NSArray *keys = object_getIvar(update, removeIvar);
        if (!keys || keys.count == 0) return;

        long long reason = -1;
        Ivar reasonIvar = class_getInstanceVariable([update class], "_removeMessages_reason");
        if (reasonIvar) {
            ptrdiff_t off = ivar_getOffset(reasonIvar);
            reason = *(long long *)((char *)(__bridge void *)update + off);
        }

        // reason 2 = delete-for-you. Track keys so the reason=0 follow-up
        // (if any) can be recognised and let through.
        if (reason == 2) {
            NSDate *now = [NSDate date];
            for (id key in keys) {
                NSString *sid = sciExtractServerId(key);
                if (sid) sciDeleteForYouKeys[sid] = now;
            }
            return;
        }

        if (reason != 0) return;

        // Per-sid intent: sids the user just locally removed via a hooked
        // mutation processor. Exact, raceless. Consumed on match.
        {
            NSMutableSet *pending = sciGetPendingLocalSids();
            BOOL anyIntent = NO;
            for (id key in keys) {
                NSString *sid = sciExtractServerId(key);
                if (sid && [pending containsObject:sid]) { anyIntent = YES; break; }
            }
            if (anyIntent) {
                for (id key in keys) {
                    NSString *sid = sciExtractServerId(key);
                    if (sid) [pending removeObject:sid];
                }
                return;
            }
        }

        if (sciLocalDeleteInProgress) return;

        // Delete-for-you follow-up: any tracked key → let the whole batch through.
        BOOL anyMatched = NO;
        for (id key in keys) {
            NSString *sid = sciExtractServerId(key);
            if (sid && sciDeleteForYouKeys[sid]) { anyMatched = YES; break; }
        }
        if (anyMatched) {
            for (id key in keys) {
                NSString *sid = sciExtractServerId(key);
                if (sid) [sciDeleteForYouKeys removeObjectForKey:sid];
            }
            return;
        }

        // Real remote unsend — preserve, skipping reactions/action-logs and
        // any message recorded as sent by the current user.
        NSString *myPk = sciCurrentUserPk();
        for (id key in keys) {
            NSString *sid = sciExtractServerId(key);
            if (!sid) continue;
            if (sciIsReactionRelatedMessage(sid)) continue;
            NSString *senderPk = sciGetSenderMap()[sid];
            if (senderPk && myPk && [senderPk isEqualToString:myPk]) continue;
            [sciGetPreservedIds() addObject:sid];
            [preserved addObject:sid];
        }
    } @catch (__unused id e) {}
}

// Classify and neuter every pending update stamped with `tid`. Excluded
// threads are passed through untouched.
static NSSet<NSString *> *sciNeuterAndPreserveForThread(NSString *tid) {
    NSMutableSet<NSString *> *preserved = [NSMutableSet set];
    if (!sciPendingUpdates || tid.length == 0) return preserved;
    if (!sciDeleteForYouKeys) sciDeleteForYouKeys = [NSMutableDictionary dictionary];
    sciPruneStaleDeleteForYouKeys();

    BOOL excluded = [SCIExcludedThreads shouldKeepDeletedBeBlockedForThreadId:tid];

    @synchronized(sciPendingUpdates) {
        NSMutableArray *remaining = [NSMutableArray array];
        for (id update in sciPendingUpdates) {
            NSString *stamp = objc_getAssociatedObject(update, kSCIUpdateThreadIdKey);
            if (![stamp isEqualToString:tid]) {
                [remaining addObject:update];
                continue;
            }
            if (excluded) continue;
            NSUInteger before = preserved.count;
            sciProcessOneUpdate(update, preserved);
            if (preserved.count > before) sciNeuterRemoveUpdate(update);
        }
        [sciPendingUpdates setArray:remaining];
    }
    if (preserved.count > 0) sciSavePreservedIds();
    return preserved;
}

// ============ CACHE UPDATE HOOK ============

static void sciShowUnsentToast() {
    UIView *hostView = [UIApplication sharedApplication].keyWindow;
    if (!hostView) return;

    UIView *pill = [[UIView alloc] init];
    pill.backgroundColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.15 alpha:0.95];
    pill.layer.cornerRadius = 18;
    pill.layer.shadowColor = [UIColor blackColor].CGColor;
    pill.layer.shadowOpacity = 0.4;
    pill.layer.shadowOffset = CGSizeMake(0, 2);
    pill.layer.shadowRadius = 8;
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.alpha = 0;

    UILabel *label = [[UILabel alloc] init];
    label.text = @"A message was unsent";
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [pill addSubview:label];
    [hostView addSubview:pill];

    [NSLayoutConstraint activateConstraints:@[
        [pill.topAnchor constraintEqualToAnchor:hostView.safeAreaLayoutGuide.topAnchor constant:8],
        [pill.centerXAnchor constraintEqualToAnchor:hostView.centerXAnchor],
        [pill.heightAnchor constraintEqualToConstant:36],
        [label.centerXAnchor constraintEqualToAnchor:pill.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:20],
        [label.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-20],
    ]];

    [UIView animateWithDuration:0.3 animations:^{ pill.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ pill.alpha = 0; } completion:^(BOOL f) {
            [pill removeFromSuperview];
        }];
    });
}

static void sciRefreshVisibleCellIndicators() {
    Class cellClass = NSClassFromString(@"IGDirectMessageCell");
    if (!cellClass) return;
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:cellClass]) {
            sciUpdateCellIndicator(v);
            continue;
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
}

static void (*orig_applyUpdates)(id self, SEL _cmd, id updates, id completion, id userAccess);
static void new_applyUpdates(id self, SEL _cmd, id updates, id completion, id userAccess) {
    if (!sciKeepDeletedEnabled()) {
        orig_applyUpdates(self, _cmd, updates, completion, userAccess);
        return;
    }

    NSMutableSet<NSString *> *preserved = [NSMutableSet set];
    if ([updates isKindOfClass:[NSArray class]]) {
        for (id tu in (NSArray *)updates) {
            NSString *tid = nil;
            @try { tid = [tu valueForKey:@"threadId"]; } @catch (__unused id e) {}
            if (tid.length == 0) continue;
            NSSet *p = sciNeuterAndPreserveForThread(tid);
            if (p.count > 0) [preserved unionSet:p];
        }
    }

    orig_applyUpdates(self, _cmd, updates, completion, userAccess);

    if (preserved.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sciRefreshVisibleCellIndicators();
            if ([SCIUtils getBoolPref:@"unsent_message_toast"]) sciShowUnsentToast();
        });
    }
}

// ============ LOCAL DELETE TRACKING ============

// Hooked on the unsend mutation processor. Reads target sids straight off
// _messageKeys for the per-sid intent path; the time-window flag stays as
// a safety net for any sid the extraction may miss.
static void (*orig_removeMutation_execute)(id self, SEL _cmd, id handler, id pkg);
static void new_removeMutation_execute(id self, SEL _cmd, id handler, id pkg) {
    @try {
        Ivar mkIvar = class_getInstanceVariable([self class], "_messageKeys");
        id keys = mkIvar ? object_getIvar(self, mkIvar) : nil;
        if ([keys isKindOfClass:[NSArray class]]) {
            static const char *kSidNames[] = {"_serverId", "_messageServerId"};
            for (id k in (NSArray *)keys) {
                NSString *sid = nil;
                for (int ni = 0; ni < 2; ni++) {
                    Ivar sidIvar = class_getInstanceVariable([k class], kSidNames[ni]);
                    if (sidIvar) {
                        id v = object_getIvar(k, sidIvar);
                        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
                            sid = v; break;
                        }
                    }
                }
                if (sid) [sciGetPendingLocalSids() addObject:sid];
            }
        }
    } @catch (__unused id e) {}

    sciLocalDeleteInProgress = YES;
    orig_removeMutation_execute(self, _cmd, handler, pkg);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sciLocalDeleteInProgress = NO;
    });
}

// Sweeps every IGDirect*Outgoing*MutationProcessor and wraps its execute.
// IGDirectGenericOutgoingMutationProcessor is the empirical DFY signal —
// it fires for "Delete for you" but not for sends (sends use the *GraphQL*
// or NonMedia variants). Other classes are wrapped only when their name
// suggests removal, as a defensive net. Each class gets its own block so
// origImp is captured per-class.
static void sciHookAllRemovalMutationProcessors(void) {
    unsigned int count = 0;
    Class *all = objc_copyClassList(&count);
    if (!all) return;
    SEL execSel = NSSelectorFromString(@"executeWithResultHandler:accessoryPackage:");
    Class baseUnsend = NSClassFromString(@"IGDirectMessageOutgoingUpdateRemoveMessagesMutationProcessor");
    for (unsigned int i = 0; i < count; i++) {
        Class c = all[i];
        const char *cn = class_getName(c);
        if (!cn) continue;
        if (c == baseUnsend) continue;
        if (strstr(cn, "MutationProcessor") == NULL) continue;
        if (strstr(cn, "IGDirect") == NULL) continue;
        if (strstr(cn, "Outgoing") == NULL) continue;
        Method m = class_getInstanceMethod(c, execSel);
        if (!m) continue;

        BOOL isDfySignal = (strcmp(cn, "IGDirectGenericOutgoingMutationProcessor") == 0);
        BOOL looksLikeRemoval = (strstr(cn, "Remove") != NULL ||
                                 strstr(cn, "Delete") != NULL ||
                                 strstr(cn, "Hide")   != NULL ||
                                 strstr(cn, "Visibility") != NULL);
        if (!isDfySignal && !looksLikeRemoval) continue;

        __block IMP origImp = method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^(id self, id handler, id pkg) {
            sciLocalDeleteInProgress = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                sciLocalDeleteInProgress = NO;
            });
            ((void(*)(id, SEL, id, id))origImp)(self, execSel, handler, pkg);
        });
        IMP prev = class_replaceMethod(c, execSel, newImp, method_getTypeEncoding(m));
        if (prev) origImp = prev;
    }
    free(all);
}

// ============ VISUAL INDICATOR ============

static NSString * _Nullable sciGetCellServerId(id cell) {
    @try {
        Ivar vmIvar = class_getInstanceVariable([cell class], "_viewModel");
        if (!vmIvar) return nil;
        id vm = object_getIvar(cell, vmIvar);
        if (!vm) return nil;

        SEL metaSel = NSSelectorFromString(@"messageMetadata");
        if (![vm respondsToSelector:metaSel]) return nil;
        id meta = ((id(*)(id,SEL))objc_msgSend)(vm, metaSel);
        if (!meta) return nil;

        Ivar keyIvar = class_getInstanceVariable([meta class], "_key");
        if (!keyIvar) return nil;
        id keyObj = object_getIvar(meta, keyIvar);
        if (!keyObj) return nil;

        Ivar sidIvar = class_getInstanceVariable([keyObj class], "_serverId");
        if (!sidIvar) return nil;
        NSString *serverId = object_getIvar(keyObj, sidIvar);
        return [serverId isKindOfClass:[NSString class]] ? serverId : nil;
    } @catch(id e) {}
    return nil;
}

static BOOL sciCellIsPreserved(id cell) {
    NSString *sid = sciGetCellServerId(cell);
    return sid && [sciGetPreservedIds() containsObject:sid];
}

// Closest squarish ancestor (32-60pt, ~equal w/h) — the visible button wrapper.
static UIView *sciFindAccessoryWrapper(UIView *view) {
    UIView *cur = view;
    while (cur && cur.superview) {
        CGRect f = cur.frame;
        if (f.size.width >= 32 && f.size.width <= 60 &&
            fabs(f.size.width - f.size.height) < 4) {
            return cur;
        }
        cur = cur.superview;
    }
    return view;
}

// Hide trailing action buttons on preserved cells — they don't work and
// overlap the "Unsent" label.
static void sciSetTrailingButtonsHidden(UIView *cell, BOOL hidden) {
    if (!cell) return;
    Ivar accIvar = class_getInstanceVariable([cell class], "_tappableAccessoryViews");
    if (!accIvar) return;
    id accViews = object_getIvar(cell, accIvar);
    if (![accViews isKindOfClass:[NSArray class]]) return;
    for (UIView *v in (NSArray *)accViews) {
        if (![v isKindOfClass:[UIView class]]) continue;
        UIView *wrapper = sciFindAccessoryWrapper(v);
        wrapper.hidden = hidden;
        if (wrapper != v) v.hidden = hidden;
    }
}

static void (*orig_addTappableAccessoryView)(id self, SEL _cmd, id view);
static void new_addTappableAccessoryView(id self, SEL _cmd, id view) {
    orig_addTappableAccessoryView(self, _cmd, view);
    if (sciIndicateUnsentEnabled() && sciCellIsPreserved(self)) {
        if ([view isKindOfClass:[UIView class]]) {
            UIView *wrapper = sciFindAccessoryWrapper((UIView *)view);
            wrapper.hidden = YES;
            if (wrapper != view) ((UIView *)view).hidden = YES;
        }
    }
}

static void sciUpdateCellIndicator(id cell) {
    UIView *view = (UIView *)cell;
    UIView *oldIndicator = [view viewWithTag:SCI_PRESERVED_TAG];
    Ivar bubbleIvar = class_getInstanceVariable([cell class], "_messageContentContainerView");
    UIView *bubble = bubbleIvar ? object_getIvar(cell, bubbleIvar) : nil;

    if (!sciIndicateUnsentEnabled()) {
        if (oldIndicator) [oldIndicator removeFromSuperview];
        sciSetTrailingButtonsHidden(view, NO);
        return;
    }

    NSString *serverId = sciGetCellServerId(cell);
    BOOL isPreserved = serverId && [sciGetPreservedIds() containsObject:serverId];

    if (!isPreserved) {
        if (oldIndicator) [oldIndicator removeFromSuperview];
        sciSetTrailingButtonsHidden(view, NO);
        return;
    }

    sciSetTrailingButtonsHidden(view, YES);
    if (oldIndicator) return;

    UIView *parent = bubble ?: view;
    UILabel *label = [[UILabel alloc] init];
    label.tag = SCI_PRESERVED_TAG;
    label.text = @"Unsent";
    label.font = [UIFont italicSystemFontOfSize:10];
    label.textColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:0.9];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:4],
        [label.centerYAnchor constraintEqualToAnchor:parent.centerYAnchor],
    ]];
}

static void (*orig_configureCell)(id self, SEL _cmd, id vm, id ringSpec, id launcherSet);
static void new_configureCell(id self, SEL _cmd, id vm, id ringSpec, id launcherSet) {
    orig_configureCell(self, _cmd, vm, ringSpec, launcherSet);
    // Capture serverId -> senderPk for every configured cell so the apply
    // hook can identify "from me" messages and skip preserving them.
    @try {
        Ivar vmIvar = class_getInstanceVariable([self class], "_viewModel");
        id vmObj = vmIvar ? object_getIvar(self, vmIvar) : nil;
        SEL metaSel = NSSelectorFromString(@"messageMetadata");
        id meta = (vmObj && [vmObj respondsToSelector:metaSel])
                  ? ((id(*)(id,SEL))objc_msgSend)(vmObj, metaSel) : nil;
        if (meta) {
            Ivar keyIvar = class_getInstanceVariable([meta class], "_key");
            id keyObj = keyIvar ? object_getIvar(meta, keyIvar) : nil;
            Ivar sidIvar = keyObj ? class_getInstanceVariable([keyObj class], "_serverId") : NULL;
            NSString *sid = sidIvar ? object_getIvar(keyObj, sidIvar) : nil;

            Ivar pkIvar = class_getInstanceVariable([meta class], "_senderPk");
            id pk = pkIvar ? object_getIvar(meta, pkIvar) : nil;
            if ([sid isKindOfClass:[NSString class]] && [pk isKindOfClass:[NSString class]]) {
                sciTrackSenderPk(sid, pk);
            }
        }
    } @catch (__unused id e) {}
    sciUpdateCellIndicator(self);
}

static void (*orig_cellLayoutSubviews)(id self, SEL _cmd);
static void new_cellLayoutSubviews(id self, SEL _cmd) {
    orig_cellLayoutSubviews(self, _cmd);
    sciUpdateCellIndicator(self);
}

// ============ ACTION LOG TRACKING ============

// IGDirectThreadActionLog is the local model for "X liked a message" rows.
// Recording the message id lets the unsend path skip these as bookkeeping.
static id (*orig_actionLogFullInit)(id, SEL, id, id, id, id, id, BOOL, BOOL, id);
static id new_actionLogFullInit(id self, SEL _cmd,
                                 id message, id title, id textAttributes, id textParts,
                                 id actionLogType, BOOL collapsible, BOOL hidden, id genAIMetadata) {
    id result = orig_actionLogFullInit(self, _cmd, message, title, textAttributes, textParts,
                                        actionLogType, collapsible, hidden, genAIMetadata);
    @try {
        SEL midSel = @selector(messageId);
        if ([result respondsToSelector:midSel]) {
            id mid = ((id(*)(id, SEL))objc_msgSend)(result, midSel);
            if ([mid isKindOfClass:[NSString class]]) {
                sciTrackInsertedMessage(mid, @"IGDirectThreadActionLog");
            }
        }
    } @catch(id e) {}
    return result;
}

// ============ RUNTIME HOOKS ============

%ctor {
    Class actionLogCls = NSClassFromString(@"IGDirectThreadActionLog");
    if (actionLogCls) {
        SEL fullInit = NSSelectorFromString(@"initWithMessage:title:textAttributes:textParts:actionLogType:collapsible:hidden:genAIMetadata:");
        if (class_getInstanceMethod(actionLogCls, fullInit))
            MSHookMessageEx(actionLogCls, fullInit, (IMP)new_actionLogFullInit, (IMP *)&orig_actionLogFullInit);
    }

    Class msgUpdateClass = NSClassFromString(@"IGDirectMessageUpdate");
    if (msgUpdateClass) {
        MSHookMessageEx(object_getClass(msgUpdateClass), @selector(alloc),
                        (IMP)new_msgUpdate_alloc, (IMP *)&orig_msgUpdate_alloc);
    }

    Class cacheClass = NSClassFromString(@"IGDirectCacheUpdatesApplicator");
    if (cacheClass) {
        SEL sel = NSSelectorFromString(@"_applyThreadUpdates:completion:userAccess:");
        if (class_getInstanceMethod(cacheClass, sel))
            MSHookMessageEx(cacheClass, sel, (IMP)new_applyUpdates, (IMP *)&orig_applyUpdates);
    }

    Class irisClass = NSClassFromString(@"IGDirectRealtimeIrisDeltaHandler");
    if (irisClass) {
        SEL sel1 = NSSelectorFromString(@"handleIrisDeltas:");
        if (class_getInstanceMethod(irisClass, sel1))
            MSHookMessageEx(irisClass, sel1,
                            (IMP)new_handleIrisDeltas, (IMP *)&orig_handleIrisDeltas);

        SEL sel2 = NSSelectorFromString(@"_handleIrisDeltasGroupedByThread:");
        if (class_getInstanceMethod(irisClass, sel2))
            MSHookMessageEx(irisClass, sel2,
                            (IMP)new_handleIrisDeltasGrouped, (IMP *)&orig_handleIrisDeltasGrouped);
    }

    Class cellClass = NSClassFromString(@"IGDirectMessageCell");
    if (cellClass) {
        SEL configSel = NSSelectorFromString(@"configureWithViewModel:ringViewSpecFactory:launcherSet:");
        if (class_getInstanceMethod(cellClass, configSel))
            MSHookMessageEx(cellClass, configSel,
                            (IMP)new_configureCell, (IMP *)&orig_configureCell);

        SEL layoutSel = @selector(layoutSubviews);
        MSHookMessageEx(cellClass, layoutSel,
                        (IMP)new_cellLayoutSubviews, (IMP *)&orig_cellLayoutSubviews);

        SEL addAccSel = NSSelectorFromString(@"_addTappableAccessoryView:");
        if (class_getInstanceMethod(cellClass, addAccSel))
            MSHookMessageEx(cellClass, addAccSel,
                            (IMP)new_addTappableAccessoryView, (IMP *)&orig_addTappableAccessoryView);
    }

    Class removeMutationClass = NSClassFromString(@"IGDirectMessageOutgoingUpdateRemoveMessagesMutationProcessor");
    if (removeMutationClass) {
        SEL execSel = NSSelectorFromString(@"executeWithResultHandler:accessoryPackage:");
        if (class_getInstanceMethod(removeMutationClass, execSel))
            MSHookMessageEx(removeMutationClass, execSel,
                            (IMP)new_removeMutation_execute, (IMP *)&orig_removeMutation_execute);
    }

    sciHookAllRemovalMutationProcessors();

    if (![SCIUtils getBoolPref:@"indicate_unsent_messages"]) {
        sciClearPreservedIds();
    }
}
