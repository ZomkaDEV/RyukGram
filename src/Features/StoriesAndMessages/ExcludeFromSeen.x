// Per-chat exclusion list. Injects an Add/Remove item into the inbox row
// context menu, and tracks the currently-visible thread for the gating sites
// in SeenButtons / OverlayButtons / VisualMsgModifier. Storage lives in
// SCIExcludedThreads.

#import "../../Utils.h"
#import "../../InstagramHeaders.h"
#import "SCIExcludedThreads.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static id sci_safeKey(id obj, NSString *k) {
    @try { return [obj valueForKey:k]; } @catch (__unused id e) { return nil; }
}

// Build a persistence-ready dict from a live IGDirectInboxThreadCellViewModel.
static NSDictionary *sci_entryFromVM(id vm) {
    if (!vm) return nil;
    NSString *tid  = sci_safeKey(vm, @"threadId");
    NSString *name = sci_safeKey(vm, @"threadName");
    NSNumber *grp  = sci_safeKey(vm, @"isGroupThread");
    if (tid.length == 0) return nil;

    NSMutableArray *users = [NSMutableArray array];
    id active = sci_safeKey(vm, @"recentlyActiveUsers");
    if ([active isKindOfClass:[NSArray class]]) {
        for (id u in (NSArray *)active) {
            id pk = sci_safeKey(u, @"pk");
            id un = sci_safeKey(u, @"username");
            id fn = sci_safeKey(u, @"fullName");
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            if (pk) d[@"pk"]       = [NSString stringWithFormat:@"%@", pk];
            if (un) d[@"username"] = [NSString stringWithFormat:@"%@", un];
            if (fn) d[@"fullName"] = [NSString stringWithFormat:@"%@", fn];
            if (d.count) [users addObject:d];
        }
    }
    return @{
        @"threadId":   tid,
        @"threadName": name ?: @"",
        @"isGroup":    @([grp boolValue]),
        @"users":      users,
    };
}

// Inbox row context menu — wrap IG's UIContextMenuConfiguration to append our
// add/remove item without losing any of IG's own actions.
static id (*orig_ctxMenuCfg)(id, SEL, id);
static id new_ctxMenuCfg(id self, SEL _cmd, id indexPath) {
    id cfg = orig_ctxMenuCfg(self, _cmd, indexPath);
    if (![SCIExcludedThreads isFeatureEnabled]) return cfg;
    if (![cfg isKindOfClass:[UIContextMenuConfiguration class]]) return cfg;

    id adapter = sci_safeKey(self, @"listAdapter");
    if (!adapter || ![indexPath respondsToSelector:@selector(section)]) return cfg;
    NSInteger section = [(NSIndexPath *)indexPath section];
    SEL secSel = NSSelectorFromString(@"sectionControllerForSection:");
    if (![adapter respondsToSelector:secSel]) return cfg;
    id secCtrl = ((id(*)(id,SEL,NSInteger))objc_msgSend)(adapter, secSel, section);
    id vm = sci_safeKey(secCtrl, @"viewModel");
    if (!vm) vm = sci_safeKey(secCtrl, @"item");
    NSDictionary *entry = sci_entryFromVM(vm);
    if (!entry) return cfg;
    NSString *tid = entry[@"threadId"];

    // actionProvider / previewProvider aren't public on UIContextMenuConfiguration
    UIContextMenuConfiguration *orig = (UIContextMenuConfiguration *)cfg;
    UIContextMenuActionProvider origProvider = sci_safeKey(orig, @"actionProvider");
    id<NSCopying> origIdent = sci_safeKey(orig, @"identifier");
    UIContextMenuContentPreviewProvider origPreview = sci_safeKey(orig, @"previewProvider");

    UIContextMenuActionProvider wrapped = ^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIMenu *base = origProvider ? origProvider(suggested) : [UIMenu menuWithChildren:suggested];
        BOOL excluded = [SCIExcludedThreads isThreadIdExcluded:tid];
        NSString *title = excluded ? @"Un-exclude chat" : @"Exclude chat";
        UIImage *img = [UIImage systemImageNamed:excluded ? @"eye.fill" : @"eye.slash"];
        UIAction *toggle = [UIAction actionWithTitle:title image:img identifier:nil
                                             handler:^(__kindof UIAction *_) {
            if (excluded) {
                [SCIExcludedThreads removeThreadId:tid];
            } else {
                [SCIExcludedThreads addOrUpdateEntry:entry];
            }
        }];
        NSMutableArray *kids = [base.children mutableCopy] ?: [NSMutableArray array];
        [kids addObject:toggle];
        return [base menuByReplacingChildren:kids];
    };

    return [UIContextMenuConfiguration configurationWithIdentifier:origIdent
                                                   previewProvider:origPreview
                                                    actionProvider:wrapped];
}

// Active thread tracking. Set on viewWillAppear so visual-message viewMode
// reads it before the chat finishes loading. Only cleared on a real leave —
// a visual viewer modal pushed on top mustn't drop context.
%hook IGDirectThreadViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    NSString *tid = sci_safeKey(self, @"threadId");
    if (tid) [SCIExcludedThreads setActiveThreadId:tid];
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (self.isMovingFromParentViewController || self.isBeingDismissed || self.parentViewController == nil) {
        NSString *cur = [SCIExcludedThreads activeThreadId];
        NSString *mine = sci_safeKey(self, @"threadId");
        if (cur && mine && [cur isEqualToString:mine]) {
            [SCIExcludedThreads setActiveThreadId:nil];
        }
    }
}
- (void)dealloc {
    NSString *cur = [SCIExcludedThreads activeThreadId];
    NSString *mine = sci_safeKey(self, @"threadId");
    if (cur && mine && [cur isEqualToString:mine]) {
        [SCIExcludedThreads setActiveThreadId:nil];
    }
    %orig;
}
%end

%ctor {
    SEL sel = NSSelectorFromString(@"networkingCoordinator_contextMenuConfigurationForThreadCellAtIndexPath:");
    unsigned int n = 0;
    Class *all = objc_copyClassList(&n);
    for (unsigned int i = 0; i < n; i++) {
        unsigned int mn = 0;
        Method *ms = class_copyMethodList(all[i], &mn);
        BOOL has = NO;
        for (unsigned int j = 0; j < mn; j++) {
            if (sel_isEqual(method_getName(ms[j]), sel)) { has = YES; break; }
        }
        if (ms) free(ms);
        if (has) {
            MSHookMessageEx(all[i], sel, (IMP)new_ctxMenuCfg, (IMP *)&orig_ctxMenuCfg);
        }
    }
    if (all) free(all);
}
