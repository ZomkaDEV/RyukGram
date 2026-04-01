#import "../../Utils.h"
#import "../../InstagramHeaders.h"
#import "../../Downloader/Download.h"
#import <objc/runtime.h>
#import <objc/message.h>

// === State ===
static BOOL sciSeenBypassActive = NO;
static NSMutableSet *sciAllowedSeenPKs = nil;

// === Helpers ===
typedef id (*SCIMsgSend)(id, SEL);
typedef id (*SCIMsgSend1)(id, SEL, id);

static id sciCall(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((SCIMsgSend)objc_msgSend)(obj, sel);
}
static id sciCall1(id obj, SEL sel, id arg1) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((SCIMsgSend1)objc_msgSend)(obj, sel, arg1);
}

static void sciAllowSeenForPK(id media) {
    if (!media) return;
    id pk = sciCall(media, @selector(pk));
    if (!pk) return;
    if (!sciAllowedSeenPKs) sciAllowedSeenPKs = [NSMutableSet set];
    NSString *pkStr = [NSString stringWithFormat:@"%@", pk];
    [sciAllowedSeenPKs addObject:pkStr];
    NSLog(@"[SCInsta] Allow-listed PK: %@", pkStr);
}

static BOOL sciIsPKAllowed(id media) {
    if (!media || !sciAllowedSeenPKs || sciAllowedSeenPKs.count == 0) return NO;
    id pk = sciCall(media, @selector(pk));
    if (!pk) return NO;
    return [sciAllowedSeenPKs containsObject:[NSString stringWithFormat:@"%@", pk]];
}

static BOOL sciShouldBlockSeenNetwork() {
    if (sciSeenBypassActive) return NO;
    return [SCIUtils getBoolPref:@"no_seen_receipt"];
}

static BOOL sciShouldBlockSeenVisual() {
    if (sciSeenBypassActive) return NO;
    return [SCIUtils getBoolPref:@"no_seen_receipt"] && [SCIUtils getBoolPref:@"no_seen_visual"];
}

static UIViewController * _Nullable sciFindVC(UIResponder *start, NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    UIResponder *r = start;
    while (r) {
        if ([r isKindOfClass:cls]) return (UIViewController *)r;
        r = [r nextResponder];
    }
    return nil;
}

static IGMedia * _Nullable sciExtractMediaFromItem(id item) {
    if (!item) return nil;
    Class mediaClass = NSClassFromString(@"IGMedia");
    if (!mediaClass) return nil;
    NSArray *trySelectors = @[@"media", @"mediaItem", @"storyItem", @"item",
                              @"feedItem", @"igMedia", @"model", @"backingModel",
                              @"storyMedia", @"mediaModel"];
    for (NSString *selName in trySelectors) {
        id val = sciCall(item, NSSelectorFromString(selName));
        if (val && [val isKindOfClass:mediaClass]) return (IGMedia *)val;
    }
    unsigned int iCount = 0;
    Ivar *ivars = class_copyIvarList([item class], &iCount);
    for (unsigned int i = 0; i < iCount; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (type && type[0] == '@') {
            id val = object_getIvar(item, ivars[i]);
            if (val && [val isKindOfClass:mediaClass]) { free(ivars); return (IGMedia *)val; }
        }
    }
    if (ivars) free(ivars);
    return nil;
}

static id _Nullable sciGetCurrentStoryItem(UIResponder *start) {
    UIViewController *storyVC = sciFindVC(start, @"IGStoryViewerViewController");
    if (!storyVC) return nil;
    id vm = sciCall(storyVC, @selector(currentViewModel));
    if (!vm) return nil;
    return sciCall1(storyVC, @selector(currentStoryItemForViewModel:), vm);
}

// Find section controller: VC -> collectionView -> visibleCell -> containerView -> delegate
static id _Nullable sciFindSectionController(UIViewController *storyVC) {
    Class sectionClass = NSClassFromString(@"IGStoryFullscreenSectionController");
    if (!sectionClass || !storyVC) return nil;

    // Find collection view in VC ivars
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([storyVC class], &count);
    UICollectionView *cv = nil;
    for (unsigned int i = 0; i < count; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (!type || type[0] != '@') continue;
        id val = object_getIvar(storyVC, ivars[i]);
        if (val && [val isKindOfClass:[UICollectionView class]]) { cv = val; break; }
    }
    if (ivars) free(ivars);
    if (!cv) return nil;

    // Scan visible cells -> containerView -> delegate
    for (UICollectionViewCell *cell in cv.visibleCells) {
        unsigned int cCount = 0;
        Ivar *cIvars = class_copyIvarList([cell class], &cCount);
        for (unsigned int i = 0; i < cCount; i++) {
            const char *type = ivar_getTypeEncoding(cIvars[i]);
            if (!type || type[0] != '@') continue;
            id val = object_getIvar(cell, cIvars[i]);
            if (!val) continue;
            // Check val's ivars for section controller (L4: cell.containerView.delegate)
            unsigned int vCount = 0;
            Ivar *vIvars = class_copyIvarList([val class], &vCount);
            for (unsigned int j = 0; j < vCount; j++) {
                const char *type2 = ivar_getTypeEncoding(vIvars[j]);
                if (!type2 || type2[0] != '@') continue;
                id val2 = object_getIvar(val, vIvars[j]);
                if (val2 && [val2 isKindOfClass:sectionClass]) { free(vIvars); free(cIvars); return val2; }
            }
            if (vIvars) free(vIvars);
        }
        if (cIvars) free(cIvars);
    }
    return nil;
}

// Story downloaders
static SCIDownloadDelegate *sciStoryVideoDl = nil;
static SCIDownloadDelegate *sciStoryImageDl = nil;

static void sciInitStoryDownloaders() {
    NSString *method = [SCIUtils getStringPref:@"dw_save_action"];
    DownloadAction action = [method isEqualToString:@"photos"] ? saveToPhotos : share;
    DownloadAction imgAction = [method isEqualToString:@"photos"] ? saveToPhotos : quickLook;
    sciStoryVideoDl = [[SCIDownloadDelegate alloc] initWithAction:action showProgress:YES];
    sciStoryImageDl = [[SCIDownloadDelegate alloc] initWithAction:imgAction showProgress:NO];
}

static void sciDownloadMedia(IGMedia *media) {
    sciInitStoryDownloaders();
    NSURL *videoUrl = [SCIUtils getVideoUrlForMedia:media];
    if (videoUrl) {
        [sciStoryVideoDl downloadFileWithURL:videoUrl fileExtension:[[videoUrl lastPathComponent] pathExtension] hudLabel:nil];
        return;
    }
    NSURL *photoUrl = [SCIUtils getPhotoUrlForMedia:media];
    if (photoUrl) {
        [sciStoryImageDl downloadFileWithURL:photoUrl fileExtension:[[photoUrl lastPathComponent] pathExtension] hudLabel:nil];
        return;
    }
    [SCIUtils showErrorHUDWithDescription:@"Could not extract URL from story"];
}

// ============ BLOCK NETWORK SEEN ============

%hook IGStorySeenStateUploader
- (void)uploadSeenStateWithMedia:(id)arg1 {
    // Allow if: bypass active, or this specific media was manually marked
    if (!sciSeenBypassActive && sciShouldBlockSeenNetwork() && !sciIsPKAllowed(arg1)) return;
    %orig;
}
- (void)uploadSeenState {
    // Batch upload — allow if bypass or any manual PKs are pending
    if (!sciSeenBypassActive && sciShouldBlockSeenNetwork() && !(sciAllowedSeenPKs && sciAllowedSeenPKs.count > 0)) return;
    %orig;
}
- (void)_uploadSeenState:(id)arg1 {
    if (!sciSeenBypassActive && sciShouldBlockSeenNetwork() && !sciIsPKAllowed(arg1)) return;
    %orig;
}
- (void)sendSeenReceipt:(id)arg1 {
    if (!sciSeenBypassActive && sciShouldBlockSeenNetwork() && !sciIsPKAllowed(arg1)) return;
    %orig;
}
// NEVER block networker — returning nil breaks the uploader permanently
- (id)networker { return %orig; }
%end

// ============ BLOCK VISUAL SEEN ============

%hook IGStoryFullscreenSectionController
// Visual seen blocking
- (void)markItemAsSeen:(id)arg1 { if (sciShouldBlockSeenVisual() && !sciIsPKAllowed(arg1)) return; %orig; }
- (void)_markItemAsSeen:(id)arg1 { if (sciShouldBlockSeenVisual() && !sciIsPKAllowed(arg1)) return; %orig; }
- (void)storySeenStateDidChange:(id)arg1 { if (sciShouldBlockSeenVisual()) return; %orig; }
- (void)sendSeenRequestForCurrentItem { if (sciShouldBlockSeenVisual()) return; %orig; }
- (void)markCurrentItemAsSeen { if (sciShouldBlockSeenVisual()) return; %orig; }

// Stop auto-advance: block timer-triggered advances, allow manual taps
- (void)storyPlayerMediaViewDidPlayToEnd:(id)arg1 {
    if ([SCIUtils getBoolPref:@"stop_story_auto_advance"]) return;
    %orig;
}
- (void)advanceToNextReelForAutoScroll {
    if ([SCIUtils getBoolPref:@"stop_story_auto_advance"]) return;
    %orig;
}
%end

%hook IGStoryViewerViewController
- (void)fullscreenSectionController:(id)arg1 didMarkItemAsSeen:(id)arg2 {
    if (sciShouldBlockSeenVisual() && !sciIsPKAllowed(arg2)) return;
    %orig;
}
%end

%hook IGStoryTrayViewModel
- (void)markAsSeen { if (sciShouldBlockSeenVisual()) return; %orig; }
- (void)setHasUnseenMedia:(BOOL)arg1 { if (sciShouldBlockSeenVisual()) { %orig(YES); return; } %orig; }
- (BOOL)hasUnseenMedia { if (sciShouldBlockSeenVisual()) return YES; return %orig; }
- (void)setIsSeen:(BOOL)arg1 { if (sciShouldBlockSeenVisual()) { %orig(NO); return; } %orig; }
- (BOOL)isSeen { if (sciShouldBlockSeenVisual()) return NO; return %orig; }
%end

%hook IGStoryItem
- (void)setHasSeen:(BOOL)arg1 { if (sciShouldBlockSeenVisual()) { %orig(NO); return; } %orig; }
- (BOOL)hasSeen { if (sciShouldBlockSeenVisual()) return NO; return %orig; }
%end

%hook IGStoryGradientRingView
- (void)setIsSeen:(BOOL)arg1 { if (sciShouldBlockSeenVisual()) { %orig(NO); return; } %orig; }
- (void)setSeen:(BOOL)arg1 { if (sciShouldBlockSeenVisual()) { %orig(NO); return; } %orig; }
- (void)updateRingForSeenState:(BOOL)arg1 { if (sciShouldBlockSeenVisual()) { %orig(NO); return; } %orig; }
%end

// ============ OVERLAY BUTTONS ============

%hook IGStoryFullscreenOverlayView
- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;

    if ([SCIUtils getBoolPref:@"dw_story"] && ![self viewWithTag:1340]) {
        UIButton *dlBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        dlBtn.tag = 1340;
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
        [dlBtn setImage:[UIImage systemImageNamed:@"arrow.down" withConfiguration:config] forState:UIControlStateNormal];
        dlBtn.tintColor = [UIColor whiteColor];
        dlBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
        dlBtn.layer.cornerRadius = 18;
        dlBtn.clipsToBounds = YES;
        dlBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [dlBtn addTarget:self action:@selector(sciStoryDownloadTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:dlBtn];
        [NSLayoutConstraint activateConstraints:@[
            [dlBtn.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-100],
            [dlBtn.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [dlBtn.widthAnchor constraintEqualToConstant:36],
            [dlBtn.heightAnchor constraintEqualToConstant:36]
        ]];
    }

    if ([SCIUtils getBoolPref:@"no_seen_receipt"] && ![self viewWithTag:1339]) {
        UIButton *seenBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        seenBtn.tag = 1339;
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
        [seenBtn setImage:[UIImage systemImageNamed:@"eye" withConfiguration:config] forState:UIControlStateNormal];
        seenBtn.tintColor = [UIColor whiteColor];
        seenBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
        seenBtn.layer.cornerRadius = 18;
        seenBtn.clipsToBounds = YES;
        seenBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [seenBtn addTarget:self action:@selector(sciMarkSeenTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:seenBtn];
        UIView *dlBtn = [self viewWithTag:1340];
        if (dlBtn) {
            [NSLayoutConstraint activateConstraints:@[
                [seenBtn.centerYAnchor constraintEqualToAnchor:dlBtn.centerYAnchor],
                [seenBtn.trailingAnchor constraintEqualToAnchor:dlBtn.leadingAnchor constant:-10],
                [seenBtn.widthAnchor constraintEqualToConstant:36],
                [seenBtn.heightAnchor constraintEqualToConstant:36]
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [seenBtn.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-100],
                [seenBtn.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
                [seenBtn.widthAnchor constraintEqualToConstant:36],
                [seenBtn.heightAnchor constraintEqualToConstant:36]
            ]];
        }
    }
}

// ============ STORY DOWNLOAD ============

%new - (void)sciStoryDownloadTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
    [UIView animateWithDuration:0.1 animations:^{ sender.transform = CGAffineTransformMakeScale(0.8, 0.8); }
                     completion:^(BOOL f) { [UIView animateWithDuration:0.1 animations:^{ sender.transform = CGAffineTransformIdentity; }]; }];
    @try {
        id item = sciGetCurrentStoryItem(self);
        IGMedia *media = sciExtractMediaFromItem(item);
        if (media) {
            if ([SCIUtils getBoolPref:@"dw_confirm"]) {
                [SCIUtils showConfirmation:^{ sciDownloadMedia(media); } title:@"Download story?"];
            } else {
                sciDownloadMedia(media);
            }
            return;
        }
        [SCIUtils showErrorHUDWithDescription:@"Could not find story media"];
    } @catch (NSException *e) {
        [SCIUtils showErrorHUDWithDescription:[NSString stringWithFormat:@"Error: %@", e.reason]];
    }
}

// ============ MARK SEEN ============

%new - (void)sciMarkSeenTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
    [UIView animateWithDuration:0.1 animations:^{ sender.transform = CGAffineTransformMakeScale(0.8, 0.8); sender.alpha = 0.6; }
                     completion:^(BOOL f) { [UIView animateWithDuration:0.15 animations:^{ sender.transform = CGAffineTransformIdentity; sender.alpha = 1.0; }]; }];

    @try {
        UIViewController *storyVC = sciFindVC(self, @"IGStoryViewerViewController");
        if (!storyVC) { [SCIUtils showErrorHUDWithDescription:@"Story VC not found"]; return; }

        // Get current story media
        id sectionCtrl = sciFindSectionController(storyVC);
        id storyItem = sectionCtrl ? sciCall(sectionCtrl, NSSelectorFromString(@"currentStoryItem")) : nil;
        if (!storyItem) storyItem = sciGetCurrentStoryItem(self);
        IGMedia *media = (storyItem && [storyItem isKindOfClass:NSClassFromString(@"IGMedia")]) ? storyItem : sciExtractMediaFromItem(storyItem);

        if (!media) { [SCIUtils showErrorHUDWithDescription:@"Could not find story media"]; return; }

        // Add this media PK to the permanent allow list
        // When Instagram's deferred upload eventually fires, our hooks will let this PK through
        sciAllowSeenForPK(media);

        // Also set bypass for immediate calls
        sciSeenBypassActive = YES;

        // Trigger the visual seen update via VC delegate
        SEL delegateSel = @selector(fullscreenSectionController:didMarkItemAsSeen:);
        if ([storyVC respondsToSelector:delegateSel]) {
            typedef void (*Func)(id, SEL, id, id);
            ((Func)objc_msgSend)(storyVC, delegateSel, sectionCtrl, media);
        }

        // Trigger the section controller's mark flow
        if (sectionCtrl) {
            SEL markSel = NSSelectorFromString(@"markItemAsSeen:");
            if ([sectionCtrl respondsToSelector:markSel]) {
                ((SCIMsgSend1)objc_msgSend)(sectionCtrl, markSel, media);
            }
        }

        // Update the session seen state manager
        id seenManager = sciCall(storyVC, @selector(viewingSessionSeenStateManager));
        id vm = sciCall(storyVC, @selector(currentViewModel));
        if (seenManager && vm) {
            SEL setSeenSel = NSSelectorFromString(@"setSeenMediaId:forReelPK:");
            if ([seenManager respondsToSelector:setSeenSel]) {
                id mediaPK = sciCall(media, @selector(pk));
                id reelPK = sciCall(vm, NSSelectorFromString(@"reelPK"));
                if (!reelPK) reelPK = sciCall(vm, @selector(pk));
                if (mediaPK && reelPK) {
                    typedef void (*SetFunc)(id, SEL, id, id);
                    ((SetFunc)objc_msgSend)(seenManager, setSeenSel, mediaPK, reelPK);
                }
            }
        }

        sciSeenBypassActive = NO;

        [SCIUtils showToastForDuration:2.0 title:@"Marked as seen" subtitle:@"Will sync when leaving stories"];
    } @catch (NSException *e) {
        sciSeenBypassActive = NO;
        [SCIUtils showErrorHUDWithDescription:[NSString stringWithFormat:@"Error: %@", e.reason]];
    }
}
%end
