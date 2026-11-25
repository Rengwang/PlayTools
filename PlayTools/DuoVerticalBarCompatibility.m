//
//  DuoVerticalBarCompatibility.m
//  PlayTools
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <PlayTools/PlayTools-Swift.h>
#import "PlayLoader.h"

BOOL PTShouldEnableDuoVerticalBar(void) {
    return PlaySettings.shared.layoutIdiom == 3 && PlaySettings.shared.duoVerticalBar;
}

#if TARGET_OS_MACCATALYST

static const CGFloat kPTDuoVerticalBarWidth = 60.0;
static const CGFloat kPTDuoVerticalBarMinWindowWidth = 600.0;
static const CGFloat kPTDuoVerticalBarMinWindowHeight = 320.0;

// MARK: - PTDuoVerticalBarMath

static inline BOOL PTDuoShouldActivateForGeometry(BOOL settingEnabled,
                                                  CGFloat windowWidth,
                                                  CGFloat windowHeight,
                                                  NSInteger preferredBehavior) {
    // UIVerticalBarBehaviorDisabled == 1
    return settingEnabled
        && isfinite(windowWidth) && isfinite(windowHeight)
        && windowWidth >= kPTDuoVerticalBarMinWindowWidth
        && windowHeight >= kPTDuoVerticalBarMinWindowHeight
        && preferredBehavior != 1;
}

static inline UIRectEdge PTDuoResolvePhysicalBarEdge(BOOL isDirectional,
                                                     UIRectEdge edge,
                                                     NSDirectionalRectEdge directionalEdge,
                                                     UIUserInterfaceLayoutDirection layoutDirection) {
    if (!isDirectional) {
        return edge;
    }
    BOOL isRTL = (layoutDirection == UIUserInterfaceLayoutDirectionRightToLeft);
    if (directionalEdge == NSDirectionalRectEdgeTrailing) {
        return isRTL ? UIRectEdgeLeft : UIRectEdgeRight;
    }
    if (directionalEdge == NSDirectionalRectEdgeLeading) {
        return isRTL ? UIRectEdgeRight : UIRectEdgeLeft;
    }
    if (directionalEdge == NSDirectionalRectEdgeTop) {
        return UIRectEdgeTop;
    }
    if (directionalEdge == NSDirectionalRectEdgeBottom) {
        return UIRectEdgeBottom;
    }
    return UIRectEdgeNone;
}

static inline CGFloat PTDuoResolveBarExtent(BOOL hasExplicitExtent,
                                            CGFloat requestedExtent,
                                            CGFloat viewWidth) {
    CGFloat extent = (hasExplicitExtent && isfinite(requestedExtent) && requestedExtent > 0.0)
        ? requestedExtent
        : kPTDuoVerticalBarWidth;
    if (isfinite(viewWidth) && viewWidth > 0.0) {
        extent = MIN(extent, viewWidth);
    }
    return extent;
}

static inline BOOL PTDuoRectIsAppSidebarCandidate(CGRect rectInWindow, CGRect windowBounds) {
    CGFloat winW = CGRectGetWidth(windowBounds);
    CGFloat winH = CGRectGetHeight(windowBounds);
    if (winW < kPTDuoVerticalBarMinWindowWidth || winH < kPTDuoVerticalBarMinWindowHeight) {
        return NO;
    }
    CGFloat w = CGRectGetWidth(rectInWindow);
    CGFloat h = CGRectGetHeight(rectInWindow);
    if (!isfinite(w) || !isfinite(h) || w < 24.0 || w > (kPTDuoVerticalBarWidth + 24.0) || h < 40.0) {
        return NO;
    }
    CGFloat minX = CGRectGetMinX(rectInWindow);
    CGFloat maxX = CGRectGetMaxX(rectInWindow);
    CGFloat stripStart = CGRectGetMaxX(windowBounds) - kPTDuoVerticalBarWidth;
    return (minX >= stripStart - 12.0) && (maxX >= CGRectGetMaxX(windowBounds) - 20.0);
}

typedef NS_ENUM(NSInteger, PTDuoNavBarSuppressionMode) {
    PTDuoNavBarSuppressionNone = 0,
    PTDuoNavBarSuppressionFull = 1,
    PTDuoNavBarSuppressionItemsOnly = 2,
};

static inline PTDuoNavBarSuppressionMode PTDuoClassifyNavBarSuppression(BOOL navBarVisibleByApp,
                                                                        BOOL mirroredNavBarItemsOrBack,
                                                                        BOOL hasUnmirroredTopBarContent) {
    if (!navBarVisibleByApp || !mirroredNavBarItemsOrBack) {
        return PTDuoNavBarSuppressionNone;
    }
    return hasUnmirroredTopBarContent ? PTDuoNavBarSuppressionItemsOnly : PTDuoNavBarSuppressionFull;
}

static inline CGFloat PTDuoAdjustedSuppressedNavBarTopInset(CGFloat originalTopInset,
                                                            BOOL insetsAreAbsolute,
                                                            CGFloat windowTopSafeArea) {
    if (!isfinite(originalTopInset) || originalTopInset <= 0.0) {
        return 0.0;
    }
    if (!insetsAreAbsolute) {
        // Relative delta added solely by the suppressed UINavigationBar above window safe area.
        return 0.0;
    }
    CGFloat baseline = (isfinite(windowTopSafeArea) && windowTopSafeArea > 0.0) ? windowTopSafeArea : 0.0;
    return MIN(originalTopInset, baseline);
}

// MARK: - Associated Object Keys & State Types

typedef NS_ENUM(NSInteger, PTDuoBarState) {
    PTDuoBarStateUnset = 0,
    PTDuoBarStateActive = 1,
    PTDuoBarStateBehaviorDisabled = 2,
    PTDuoBarStateInactive = 3,
};

static const void *kPTDuoBarRegionMetaKey = &kPTDuoBarRegionMetaKey;
static const void *kPTDuoViewBarGuidesKey = &kPTDuoViewBarGuidesKey;
static const void *kPTDuoWindowStateKey = &kPTDuoWindowStateKey;
static const void *kPTDuoWindowTraitStateKey = &kPTDuoWindowTraitStateKey;
static const void *kPTDuoSceneTraitStateKey = &kPTDuoSceneTraitStateKey;
static const void *kPTDuoWindowHostViewKey = &kPTDuoWindowHostViewKey;
static const void *kPTDuoWindowRefreshScheduledKey = &kPTDuoWindowRefreshScheduledKey;
static const void *kPTDuoWindowLastLayoutSizeKey = &kPTDuoWindowLastLayoutSizeKey;
static const void *kPTDuoWindowLastSidebarScanTimeKey = &kPTDuoWindowLastSidebarScanTimeKey;
static const void *kPTDuoTabBarRelocatedKey = &kPTDuoTabBarRelocatedKey;
static const void *kPTDuoTabBarAppHiddenKey = &kPTDuoTabBarAppHiddenKey;
static const void *kPTDuoNavControllerSuppressionKey = &kPTDuoNavControllerSuppressionKey;
static const void *kPTDuoToolbarControllerSuppressionKey = &kPTDuoToolbarControllerSuppressionKey;
static const void *kPTDuoNavBarSuppressedKey = &kPTDuoNavBarSuppressedKey;
static const void *kPTDuoNavBarAppHiddenKey = &kPTDuoNavBarAppHiddenKey;
static const void *kPTDuoNavBarAppAlphaKey = &kPTDuoNavBarAppAlphaKey;
static const void *kPTDuoToolbarSuppressedKey = &kPTDuoToolbarSuppressedKey;
static const void *kPTDuoToolbarAppHiddenKey = &kPTDuoToolbarAppHiddenKey;
static const void *kPTDuoToolbarAppAlphaKey = &kPTDuoToolbarAppAlphaKey;
static const void *kPTDuoBarItemSuppressedKey = &kPTDuoBarItemSuppressedKey;
static const void *kPTDuoBarItemAppHiddenKey = &kPTDuoBarItemAppHiddenKey;
static const void *kPTDuoNavItemSuppressedBackKey = &kPTDuoNavItemSuppressedBackKey;
static const void *kPTDuoNavItemAppHidesBackKey = &kPTDuoNavItemAppHidesBackKey;

static BOOL pt_duoVerticalBarInstalled = NO;
static __thread NSInteger pt_duoRefreshDepth = 0;
static __thread NSInteger pt_duoInternalTabBarHiddenDepth = 0;
static __thread NSInteger pt_duoInternalNavBarVisualDepth = 0;
static __thread NSInteger pt_duoInternalToolbarVisualDepth = 0;
static __thread NSInteger pt_duoInternalBarItemHiddenDepth = 0;
static __thread NSInteger pt_duoInternalNavItemBackDepth = 0;

static void pt_scheduleRefreshForWindow(UIWindow *window);
static void pt_refreshDuoVerticalBarForWindow(UIWindow *window);

// MARK: - UIViewLayoutRegion Metadata

@interface PTDuoBarLayoutRegionMeta : NSObject
@property (nonatomic, assign) BOOL isDirectional;
@property (nonatomic, assign) UIRectEdge edge;
@property (nonatomic, assign) NSDirectionalRectEdge directionalEdge;
@property (nonatomic, assign) BOOL hasExplicitExtent;
@property (nonatomic, assign) CGFloat extent;
@end

@implementation PTDuoBarLayoutRegionMeta
@end

static inline BOOL pt_isTaggedPointer(id obj) {
    uintptr_t raw = (uintptr_t)(__bridge void *)obj;
    return (raw == 0) || ((raw & 1u) != 0) || ((raw >> 63) != 0);
}

static void pt_attachBarRegionMeta(id region,
                                   BOOL isDirectional,
                                   UIRectEdge edge,
                                   NSDirectionalRectEdge directionalEdge,
                                   BOOL hasExplicitExtent,
                                   CGFloat extent) {
    if (!region || pt_isTaggedPointer(region)) {
        return;
    }
    PTDuoBarLayoutRegionMeta *meta = [[PTDuoBarLayoutRegionMeta alloc] init];
    meta.isDirectional = isDirectional;
    meta.edge = edge;
    meta.directionalEdge = directionalEdge;
    meta.hasExplicitExtent = hasExplicitExtent;
    meta.extent = extent;
    objc_setAssociatedObject(region, kPTDuoBarRegionMetaKey, meta, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: - Window & ViewController State Resolution

static BOOL pt_isEligiblePrimaryWindow(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) {
        return NO;
    }
    if (window.windowLevel != UIWindowLevelNormal) {
        return NO;
    }
    if (!window.rootViewController) {
        return NO;
    }
    NSString *clsName = NSStringFromClass([window class]);
    if ([clsName hasPrefix:@"_UI"]
        || [clsName containsString:@"Keyboard"]
        || [clsName containsString:@"TextEffects"]
        || [clsName containsString:@"StatusBar"]
        || [clsName containsString:@"Alert"]) {
        return NO;
    }
    return YES;
}

static UIViewController *pt_topPresentedFullscreenController(UIViewController *rootVC, CGRect windowBounds) {
    UIViewController *current = rootVC;
    NSInteger depth = 0;
    while (current.presentedViewController && depth < 16) {
        UIViewController *presented = current.presentedViewController;
        if (presented.isBeingDismissed) {
            break;
        }
        UIModalPresentationStyle style = presented.modalPresentationStyle;
        BOOL coversScreen = (style == UIModalPresentationFullScreen
                             || style == UIModalPresentationOverFullScreen
                             || style == UIModalPresentationCurrentContext
                             || style == UIModalPresentationOverCurrentContext);
        if (!coversScreen && presented.isViewLoaded && CGRectGetWidth(windowBounds) > 1.0) {
            CGRect f = presented.view.frame;
            if (CGRectGetWidth(f) >= CGRectGetWidth(windowBounds) * 0.9
                && CGRectGetHeight(f) >= CGRectGetHeight(windowBounds) * 0.9) {
                coversScreen = YES;
            }
        }
        if (!coversScreen) {
            break;
        }
        current = presented;
        depth++;
    }
    return current;
}

static NSInteger pt_preferredVerticalBarBehaviorForVC(UIViewController *vc) {
    if (!vc) {
        return 0;
    }
    SEL behaviorSel = sel_registerName("preferredVerticalBarBehavior");
    if ([vc respondsToSelector:behaviorSel]) {
        typedef NSInteger (*pt_behavior_fn)(id, SEL);
        return ((pt_behavior_fn)objc_msgSend)(vc, behaviorSel);
    }
    return 0;
}

static NSInteger pt_resolveVerticalBarBehaviorForWindow(UIWindow *window) {
    UIViewController *rootVC = window.rootViewController;
    if (!rootVC) {
        return 0;
    }
    UIViewController *current = pt_topPresentedFullscreenController(rootVC, window.bounds);
    NSHashTable<UIViewController *> *visited = [NSHashTable weakObjectsHashTable];
    SEL childSel = sel_registerName("childViewControllerForPreferredVerticalBarBehavior");

    for (NSInteger depth = 0; depth < 32 && current != nil; depth++) {
        if ([visited containsObject:current]) {
            break;
        }
        [visited addObject:current];

        UIViewController *next = nil;
        if ([current respondsToSelector:childSel]) {
            typedef UIViewController *(*pt_child_fn)(id, SEL);
            next = ((pt_child_fn)objc_msgSend)(current, childSel);
        }
        if (!next) {
            if ([current isKindOfClass:[UINavigationController class]]) {
                next = ((UINavigationController *)current).topViewController;
            } else if ([current isKindOfClass:[UITabBarController class]]) {
                next = ((UITabBarController *)current).selectedViewController;
            } else if ([current isKindOfClass:[UISplitViewController class]]) {
                NSArray<UIViewController *> *vcs = ((UISplitViewController *)current).viewControllers;
                next = vcs.lastObject;
            }
        }
        if (!next || next == current) {
            return pt_preferredVerticalBarBehaviorForVC(current);
        }
        // If a container explicitly sets Disabled without delegating to a child via
        // childViewControllerForPreferredVerticalBarBehavior, respect it.
        if (pt_preferredVerticalBarBehaviorForVC(current) == 1) {
            return 1;
        }
        current = next;
    }
    return pt_preferredVerticalBarBehaviorForVC(current);
}

static PTDuoBarState pt_computeDesiredBarStateForWindow(UIWindow *window) {
    if (!PTShouldEnableDuoVerticalBar() || !pt_isEligiblePrimaryWindow(window)) {
        return PTDuoBarStateInactive;
    }
    CGFloat w = CGRectGetWidth(window.bounds);
    CGFloat h = CGRectGetHeight(window.bounds);
    if (!isfinite(w) || !isfinite(h) || w < kPTDuoVerticalBarMinWindowWidth || h < kPTDuoVerticalBarMinWindowHeight) {
        return PTDuoBarStateInactive;
    }
    NSInteger behavior = pt_resolveVerticalBarBehaviorForWindow(window);
    if (!PTDuoShouldActivateForGeometry(YES, w, h, behavior)) {
        return (behavior == 1) ? PTDuoBarStateBehaviorDisabled : PTDuoBarStateInactive;
    }
    return PTDuoBarStateActive;
}

static BOOL pt_isDuoVerticalBarActiveForWindow(UIWindow *window) {
    if (!window || !PTShouldEnableDuoVerticalBar()) {
        return NO;
    }
    NSNumber *cached = objc_getAssociatedObject(window, kPTDuoWindowStateKey);
    if (cached) {
        PTDuoBarState state = (PTDuoBarState)cached.integerValue;
        if (state == PTDuoBarStateActive) {
            return CGRectGetWidth(window.bounds) >= kPTDuoVerticalBarMinWindowWidth;
        }
        return NO;
    }
    return pt_computeDesiredBarStateForWindow(window) == PTDuoBarStateActive;
}

// MARK: - Private Trait Override Application

static void pt_applyVerticalBarTraitsToObject(id target, const void *stateKey, PTDuoBarState state) {
    if (!target || ![target respondsToSelector:@selector(traitOverrides)]) {
        return;
    }
    NSNumber *prev = objc_getAssociatedObject(target, stateKey);
    if (prev && prev.integerValue == state) {
        return;
    }

    Class tSystemAllowed = NSClassFromString(@"_UITraitSystemVerticalBarAllowed");
    Class tSystemEdge = NSClassFromString(@"_UITraitSystemVerticalBarHorizontalEdge");
    Class tAllowed = NSClassFromString(@"_UITraitVerticalBarAllowed");
    if (!tSystemAllowed || !tSystemEdge || !tAllowed) {
        return;
    }

    if (@available(iOS 17.0, *)) {
        id overrides = ((id (*)(id, SEL))objc_msgSend)(target, @selector(traitOverrides));
        if (!overrides) {
            return;
        }
        SEL setIntSel = @selector(setNSIntegerValue:forTrait:);
        SEL removeSel = @selector(removeTrait:);
        if (![overrides respondsToSelector:setIntSel] || ![overrides respondsToSelector:removeSel]) {
            return;
        }
        typedef void (*pt_set_trait_int_fn)(id, SEL, NSInteger, Class);
        typedef void (*pt_remove_trait_fn)(id, SEL, Class);
        pt_set_trait_int_fn setIntFn = (pt_set_trait_int_fn)objc_msgSend;
        pt_remove_trait_fn removeFn = (pt_remove_trait_fn)objc_msgSend;

        if (state == PTDuoBarStateActive) {
            setIntFn(overrides, setIntSel, 1, tSystemAllowed);
            setIntFn(overrides, setIntSel, 2, tSystemEdge);
            setIntFn(overrides, setIntSel, 1, tAllowed);
        } else if (state == PTDuoBarStateBehaviorDisabled) {
            setIntFn(overrides, setIntSel, 1, tSystemAllowed);
            setIntFn(overrides, setIntSel, 2, tSystemEdge);
            setIntFn(overrides, setIntSel, 2, tAllowed);
        } else {
            removeFn(overrides, removeSel, tAllowed);
            removeFn(overrides, removeSel, tSystemEdge);
            removeFn(overrides, removeSel, tSystemAllowed);
        }
        objc_setAssociatedObject(target, stateKey, @(state), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// MARK: - App-Rendered Custom Sidebar Auto-Yield Detection

static BOOL pt_isSystemBarOrPrivateChromeView(UIView *view) {
    if ([view isKindOfClass:[UINavigationBar class]]
        || [view isKindOfClass:[UITabBar class]]
        || [view isKindOfClass:[UIToolbar class]]) {
        return YES;
    }
    NSString *clsName = NSStringFromClass([view class]);
    if ([clsName hasPrefix:@"_UI"]
        || [clsName hasPrefix:@"UI"]
        || [clsName hasPrefix:@"PTDuo"]) {
        // Note: Plain UIView / UIControl / UIStackView could be an app's custom sidebar container,
        // so only filter out private _UI* chrome and specific system bar/scroll indicator classes.
        if ([clsName hasPrefix:@"_UI"]
            || [clsName hasPrefix:@"PTDuo"]
            || [clsName isEqualToString:@"UIScrollView"]
            || [clsName isEqualToString:@"UITableView"]
            || [clsName isEqualToString:@"UICollectionView"]
            || [clsName isEqualToString:@"UILayoutContainerView"]
            || [clsName isEqualToString:@"UITransitionView"]
            || [clsName isEqualToString:@"UIViewControllerWrapperView"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_hasVisibleInteractiveDescendant(UIView *view, NSInteger depth, NSInteger *budget) {
    if (!view || depth > 8 || *budget <= 0) {
        return NO;
    }
    for (UIView *sub in view.subviews) {
        (*budget)--;
        if (*budget <= 0) {
            return NO;
        }
        if (sub.hidden || sub.alpha <= 0.05 || !sub.userInteractionEnabled) {
            continue;
        }
        if (CGRectGetWidth(sub.bounds) < 8.0 || CGRectGetHeight(sub.bounds) < 8.0) {
            continue;
        }
        if ([sub isKindOfClass:[UIControl class]] || sub.gestureRecognizers.count > 0) {
            return YES;
        }
        if (pt_hasVisibleInteractiveDescendant(sub, depth + 1, budget)) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_viewIsInteractiveSidebarCandidate(UIView *view, UIWindow *window, CGRect windowBounds) {
    if (!view || view.hidden || view.alpha <= 0.05 || !view.userInteractionEnabled) {
        return NO;
    }
    if (pt_isSystemBarOrPrivateChromeView(view)) {
        return NO;
    }
    CGRect rectInWin = [view convertRect:view.bounds toView:window];
    if (!PTDuoRectIsAppSidebarCandidate(rectInWin, windowBounds)) {
        return NO;
    }
    if ([view isKindOfClass:[UIControl class]] || view.gestureRecognizers.count > 0) {
        return YES;
    }
    NSInteger subBudget = 60;
    if (pt_hasVisibleInteractiveDescendant(view, 0, &subBudget)) {
        return YES;
    }
    return NO;
}

static BOOL pt_scanForAppRenderedSidebar(UIView *node,
                                         UIWindow *window,
                                         UIView *excludedHost,
                                         CGRect windowBounds,
                                         CGRect rightStrip,
                                         NSInteger depth,
                                         NSInteger *visitBudget) {
    if (!node || node == excludedHost || node.hidden || node.alpha <= 0.05) {
        return NO;
    }
    if (depth > 24 || *visitBudget <= 0) {
        return NO;
    }
    (*visitBudget)--;

    if ([node isKindOfClass:[UINavigationBar class]]
        || [node isKindOfClass:[UITabBar class]]
        || [node isKindOfClass:[UIToolbar class]]) {
        return NO;
    }

    if (depth > 0) {
        CGRect rectInWin = [node convertRect:node.bounds toView:window];
        if (node.clipsToBounds && !CGRectIntersectsRect(rectInWin, rightStrip)) {
            return NO;
        }
        if (pt_viewIsInteractiveSidebarCandidate(node, window, windowBounds)) {
            return YES;
        }
    }

    for (UIView *sub in node.subviews) {
        if (*visitBudget <= 0) {
            break;
        }
        if (pt_scanForAppRenderedSidebar(sub, window, excludedHost, windowBounds, rightStrip, depth + 1, visitBudget)) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_windowHasAppRenderedRightSidebar(UIWindow *window, UIView *hostView) {
    if (!window) {
        return NO;
    }
    CGRect winBounds = window.bounds;
    CGRect rightStrip = CGRectMake(CGRectGetMaxX(winBounds) - kPTDuoVerticalBarWidth - 12.0,
                                   CGRectGetMinY(winBounds),
                                   kPTDuoVerticalBarWidth + 12.0,
                                   CGRectGetHeight(winBounds));
    NSInteger budget = 500;
    return pt_scanForAppRenderedSidebar(window, window, hostView, winBounds, rightStrip, 0, &budget);
}

// MARK: - Native vs Custom UITabBar Detection & Restoration

static BOOL pt_duoIsSystemTabBarSubviewClassName(NSString *clsName) {
    return [clsName hasPrefix:@"_UI"] || [clsName hasPrefix:@"UITabBar"];
}

static BOOL pt_duoTabBarIsCustomReplacement(UITabBar *tabBar) {
    if (!tabBar) {
        return YES;
    }
    NSArray<UITabBarItem *> *items = tabBar.items;
    if (items.count < 2) {
        return YES;
    }
    BOOL allEmpty = YES;
    for (UITabBarItem *item in items) {
        if (item.title.length > 0 || item.image != nil || item.selectedImage != nil) {
            allEmpty = NO;
            break;
        }
    }
    if (allEmpty) {
        return YES;
    }
    CGFloat width = CGRectGetWidth(tabBar.bounds);
    if (width > 1.0) {
        BOOL hasWideCustomOverlay = NO;
        for (UIView *sub in tabBar.subviews) {
            if (sub.hidden || sub.alpha <= 0.01) {
                continue;
            }
            NSString *clsName = NSStringFromClass([sub class]);
            if (pt_duoIsSystemTabBarSubviewClassName(clsName)) {
                continue;
            }
            if (CGRectGetWidth(sub.frame) >= width * 0.75 && CGRectGetHeight(sub.frame) >= 28.0) {
                hasWideCustomOverlay = YES;
                break;
            }
        }
        // If a wide custom overlay covers the tab bar and most items lack icons, don't hijack.
        if (hasWideCustomOverlay) {
            NSInteger iconCount = 0;
            for (UITabBarItem *item in items) {
                if (item.image != nil || item.selectedImage != nil) {
                    iconCount++;
                }
            }
            if (iconCount < 2) {
                return YES;
            }
        }
    }
    return NO;
}

static void pt_setTabBarRelocatedHidden(UITabBar *tabBar, BOOL relocateHidden) {
    if (!tabBar) {
        return;
    }
    BOOL currentlyRelocated = [objc_getAssociatedObject(tabBar, kPTDuoTabBarRelocatedKey) boolValue];
    if (relocateHidden) {
        if (!currentlyRelocated) {
            objc_setAssociatedObject(tabBar, kPTDuoTabBarAppHiddenKey, @(tabBar.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tabBar, kPTDuoTabBarRelocatedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        pt_duoInternalTabBarHiddenDepth++;
        @try {
            if (!tabBar.hidden) {
                tabBar.hidden = YES;
            }
            if (tabBar.alpha > 0.0) {
                tabBar.alpha = 0.0;
            }
            if (tabBar.userInteractionEnabled) {
                tabBar.userInteractionEnabled = NO;
            }
        } @finally {
            pt_duoInternalTabBarHiddenDepth--;
        }
    } else if (currentlyRelocated) {
        NSNumber *appHidden = objc_getAssociatedObject(tabBar, kPTDuoTabBarAppHiddenKey);
        objc_setAssociatedObject(tabBar, kPTDuoTabBarRelocatedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalTabBarHiddenDepth++;
        @try {
            tabBar.hidden = appHidden ? appHidden.boolValue : NO;
            tabBar.alpha = 1.0;
            tabBar.userInteractionEnabled = YES;
        } @finally {
            pt_duoInternalTabBarHiddenDepth--;
        }
    }
}

// MARK: - Active Navigation & TabBar Discovery

static void pt_findActiveNavAndTabControllers(UIWindow *window,
                                              UINavigationController * __autoreleasing *outNav,
                                              UITabBarController * __autoreleasing *outTab) {
    UIViewController *root = window.rootViewController;
    if (!root) {
        return;
    }
    UIViewController *topRoot = pt_topPresentedFullscreenController(root, window.bounds);
    BOOL isModalPresented = (topRoot != root);

    UINavigationController *foundNav = nil;
    UITabBarController *foundTab = nil;
    UIViewController *cursor = topRoot;
    NSHashTable<UIViewController *> *visited = [NSHashTable weakObjectsHashTable];

    for (NSInteger depth = 0; depth < 24 && cursor != nil; depth++) {
        if ([visited containsObject:cursor]) {
            break;
        }
        [visited addObject:cursor];

        if ([cursor isKindOfClass:[UINavigationController class]]) {
            foundNav = (UINavigationController *)cursor;
            cursor = foundNav.topViewController;
        } else if ([cursor isKindOfClass:[UITabBarController class]]) {
            if (!isModalPresented) {
                foundTab = (UITabBarController *)cursor;
            }
            cursor = ((UITabBarController *)cursor).selectedViewController;
        } else if ([cursor isKindOfClass:[UISplitViewController class]]) {
            NSArray<UIViewController *> *vcs = ((UISplitViewController *)cursor).viewControllers;
            cursor = vcs.lastObject;
        } else {
            break;
        }
    }

    if (outNav) { *outNav = foundNav; }
    if (outTab) { *outTab = foundTab; }
}

static BOOL pt_barItemAppWantsHidden(UIBarButtonItem *item) {
    if (!item) {
        return YES;
    }
    if ([objc_getAssociatedObject(item, kPTDuoBarItemSuppressedKey) boolValue]) {
        NSNumber *appHidden = objc_getAssociatedObject(item, kPTDuoBarItemAppHiddenKey);
        return appHidden ? appHidden.boolValue : NO;
    }
    if ([item respondsToSelector:@selector(isHidden)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(isHidden));
    }
    return NO;
}

static BOOL pt_navItemAppWantsHidesBackButton(UINavigationItem *navItem) {
    if (!navItem) {
        return YES;
    }
    if ([objc_getAssociatedObject(navItem, kPTDuoNavItemSuppressedBackKey) boolValue]) {
        NSNumber *appHides = objc_getAssociatedObject(navItem, kPTDuoNavItemAppHidesBackKey);
        return appHides ? appHides.boolValue : NO;
    }
    return navItem.hidesBackButton;
}

static BOOL pt_barItemIsHorizontalOnly(UIBarButtonItem *item) {
    if (!item) {
        return NO;
    }
    SEL axisSel = sel_registerName("axisBehavior");
    if ([item respondsToSelector:axisSel]) {
        return (((NSInteger (*)(id, SEL))objc_msgSend)(item, axisSel) == 1);
    }
    return NO;
}

static BOOL pt_barItemIsVisibleActionable(UIBarButtonItem *item) {
    if (!item || pt_barItemAppWantsHidden(item)) {
        return NO;
    }
    return (item.image != nil || item.title.length > 0 || item.customView != nil)
        && (item.action != NULL || item.primaryAction != nil || item.menu != nil || item.customView != nil);
}

static BOOL pt_navigationBarHasUnmirroredContent(UINavigationController *nav) {
    if (!nav) {
        return NO;
    }
    UINavigationItem *topItem = nav.topViewController.navigationItem ?: nav.navigationBar.topItem;
    if (!topItem) {
        return NO;
    }
    NSString *trimmedTitle = [topItem.title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedTitle.length > 0) {
        return YES;
    }
    NSString *trimmedPrompt = [topItem.prompt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedPrompt.length > 0) {
        return YES;
    }
    if (topItem.titleView && !topItem.titleView.hidden && topItem.titleView.alpha > 0.01) {
        return YES;
    }
    if (topItem.searchController != nil) {
        return YES;
    }
    if (@available(iOS 16.0, *)) {
        for (UIBarButtonItemGroup *group in topItem.leadingItemGroups) {
            if (group.hidden) { continue; }
            for (UIBarButtonItem *item in group.barButtonItems) {
                if (pt_barItemIsVisibleActionable(item)) {
                    return YES;
                }
            }
        }
        for (UIBarButtonItemGroup *group in topItem.centerItemGroups) {
            if (group.hidden) { continue; }
            for (UIBarButtonItem *item in group.barButtonItems) {
                if (pt_barItemIsVisibleActionable(item)) {
                    return YES;
                }
            }
        }
        // Any visible trailing item explicitly marked HorizontalOnly (1) stays on the horizontal bar.
        for (UIBarButtonItemGroup *group in topItem.trailingItemGroups) {
            if (group.hidden) { continue; }
            for (UIBarButtonItem *item in group.barButtonItems) {
                if (pt_barItemIsVisibleActionable(item) && (pt_barItemIsHorizontalOnly(item) || item.customView != nil)) {
                    return YES;
                }
            }
        }
    }
    for (UIBarButtonItem *item in topItem.leftBarButtonItems) {
        if (pt_barItemIsVisibleActionable(item)) {
            return YES;
        }
    }
    for (UIBarButtonItem *item in topItem.rightBarButtonItems) {
        if (pt_barItemIsVisibleActionable(item) && (pt_barItemIsHorizontalOnly(item) || item.customView != nil)) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_toolbarHasUnmirroredContent(UINavigationController *nav) {
    if (!nav || !nav.topViewController) {
        return NO;
    }
    for (UIBarButtonItem *item in nav.topViewController.toolbarItems) {
        if (pt_barItemIsVisibleActionable(item) && (pt_barItemIsHorizontalOnly(item) || item.customView != nil)) {
            return YES;
        }
    }
    return NO;
}

static void pt_setToolbarVisualSuppressed(UINavigationController *nav, BOOL suppress) {
    if (!nav) {
        return;
    }
    UIToolbar *toolbar = nav.toolbar;
    if (!toolbar) {
        return;
    }
    PTDuoNavBarSuppressionMode prevMode = (PTDuoNavBarSuppressionMode)[objc_getAssociatedObject(nav, kPTDuoToolbarControllerSuppressionKey) integerValue];
    BOOL wasSuppressed = (prevMode == PTDuoNavBarSuppressionFull);

    if (suppress) {
        if (![objc_getAssociatedObject(toolbar, kPTDuoToolbarSuppressedKey) boolValue]) {
            objc_setAssociatedObject(toolbar, kPTDuoToolbarAppHiddenKey, @(toolbar.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(toolbar, kPTDuoToolbarAppAlphaKey, @(toolbar.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(toolbar, kPTDuoToolbarSuppressedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(nav, kPTDuoToolbarControllerSuppressionKey, @(PTDuoNavBarSuppressionFull), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalToolbarVisualDepth++;
        @try {
            if (!toolbar.hidden) {
                toolbar.hidden = YES;
            }
            if (toolbar.alpha > 0.0) {
                toolbar.alpha = 0.0;
            }
            if (toolbar.userInteractionEnabled) {
                toolbar.userInteractionEnabled = NO;
            }
        } @finally {
            pt_duoInternalToolbarVisualDepth--;
        }
    } else if ([objc_getAssociatedObject(toolbar, kPTDuoToolbarSuppressedKey) boolValue] || wasSuppressed) {
        NSNumber *appHidden = objc_getAssociatedObject(toolbar, kPTDuoToolbarAppHiddenKey);
        NSNumber *appAlpha = objc_getAssociatedObject(toolbar, kPTDuoToolbarAppAlphaKey);
        objc_setAssociatedObject(toolbar, kPTDuoToolbarSuppressedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(nav, kPTDuoToolbarControllerSuppressionKey, @(PTDuoNavBarSuppressionNone), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalToolbarVisualDepth++;
        @try {
            toolbar.hidden = appHidden ? appHidden.boolValue : NO;
            toolbar.alpha = appAlpha ? appAlpha.doubleValue : 1.0;
            toolbar.userInteractionEnabled = YES;
        } @finally {
            pt_duoInternalToolbarVisualDepth--;
        }
    }

    if (wasSuppressed != suppress) {
        SEL eagerSel = sel_registerName("_eagerlyUpdateSafeAreaInsets");
        if ([nav respondsToSelector:eagerSel]) {
            ((void (*)(id, SEL))objc_msgSend)(nav, eagerSel);
        }
        [nav.view setNeedsLayout];
        [nav.topViewController.viewIfLoaded setNeedsLayout];
    }
}

static void pt_setNavBarVisualSuppressed(UINavigationController *nav, BOOL suppress) {
    if (!nav) {
        return;
    }
    UINavigationBar *navBar = nav.navigationBar;
    if (!navBar) {
        return;
    }
    PTDuoNavBarSuppressionMode prevMode = (PTDuoNavBarSuppressionMode)[objc_getAssociatedObject(nav, kPTDuoNavControllerSuppressionKey) integerValue];
    BOOL wasSuppressed = (prevMode == PTDuoNavBarSuppressionFull);

    if (suppress) {
        if (![objc_getAssociatedObject(navBar, kPTDuoNavBarSuppressedKey) boolValue]) {
            objc_setAssociatedObject(navBar, kPTDuoNavBarAppHiddenKey, @(navBar.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(navBar, kPTDuoNavBarAppAlphaKey, @(navBar.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(navBar, kPTDuoNavBarSuppressedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(nav, kPTDuoNavControllerSuppressionKey, @(PTDuoNavBarSuppressionFull), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalNavBarVisualDepth++;
        @try {
            if (!navBar.hidden) {
                navBar.hidden = YES;
            }
            if (navBar.alpha > 0.0) {
                navBar.alpha = 0.0;
            }
            if (navBar.userInteractionEnabled) {
                navBar.userInteractionEnabled = NO;
            }
        } @finally {
            pt_duoInternalNavBarVisualDepth--;
        }
    } else if ([objc_getAssociatedObject(navBar, kPTDuoNavBarSuppressedKey) boolValue] || wasSuppressed) {
        NSNumber *appHidden = objc_getAssociatedObject(navBar, kPTDuoNavBarAppHiddenKey);
        NSNumber *appAlpha = objc_getAssociatedObject(navBar, kPTDuoNavBarAppAlphaKey);
        objc_setAssociatedObject(navBar, kPTDuoNavBarSuppressedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(nav, kPTDuoNavControllerSuppressionKey, @(PTDuoNavBarSuppressionNone), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalNavBarVisualDepth++;
        @try {
            navBar.hidden = appHidden ? appHidden.boolValue : NO;
            navBar.alpha = appAlpha ? appAlpha.doubleValue : 1.0;
            navBar.userInteractionEnabled = YES;
        } @finally {
            pt_duoInternalNavBarVisualDepth--;
        }
    }

    if (wasSuppressed != suppress) {
        SEL eagerSel = sel_registerName("_eagerlyUpdateSafeAreaInsets");
        if ([nav respondsToSelector:eagerSel]) {
            ((void (*)(id, SEL))objc_msgSend)(nav, eagerSel);
        }
        [nav.view setNeedsLayout];
        [nav.topViewController.viewIfLoaded setNeedsLayout];
    }
}

static void pt_setBarItemHorizontalSuppressed(UIBarButtonItem *item, BOOL suppress) {
    if (!item || ![item respondsToSelector:@selector(setHidden:)] || ![item respondsToSelector:@selector(isHidden)]) {
        return;
    }
    BOOL currentlySuppressed = [objc_getAssociatedObject(item, kPTDuoBarItemSuppressedKey) boolValue];
    if (suppress) {
        if (!currentlySuppressed) {
            BOOL origHidden = ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(isHidden));
            objc_setAssociatedObject(item, kPTDuoBarItemAppHiddenKey, @(origHidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(item, kPTDuoBarItemSuppressedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        pt_duoInternalBarItemHiddenDepth++;
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(item, @selector(setHidden:), YES);
        } @finally {
            pt_duoInternalBarItemHiddenDepth--;
        }
    } else if (currentlySuppressed) {
        NSNumber *origHidden = objc_getAssociatedObject(item, kPTDuoBarItemAppHiddenKey);
        objc_setAssociatedObject(item, kPTDuoBarItemSuppressedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalBarItemHiddenDepth++;
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(item, @selector(setHidden:), origHidden ? origHidden.boolValue : NO);
        } @finally {
            pt_duoInternalBarItemHiddenDepth--;
        }
    }
}

static void pt_setNavItemBackButtonSuppressed(UINavigationItem *navItem, BOOL suppress) {
    if (!navItem) {
        return;
    }
    BOOL currentlySuppressed = [objc_getAssociatedObject(navItem, kPTDuoNavItemSuppressedBackKey) boolValue];
    if (suppress) {
        if (!currentlySuppressed) {
            objc_setAssociatedObject(navItem, kPTDuoNavItemAppHidesBackKey, @(navItem.hidesBackButton), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(navItem, kPTDuoNavItemSuppressedBackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        pt_duoInternalNavItemBackDepth++;
        @try {
            if (!navItem.hidesBackButton) {
                [navItem setHidesBackButton:YES animated:NO];
            }
        } @finally {
            pt_duoInternalNavItemBackDepth--;
        }
    } else if (currentlySuppressed) {
        NSNumber *origHides = objc_getAssociatedObject(navItem, kPTDuoNavItemAppHidesBackKey);
        objc_setAssociatedObject(navItem, kPTDuoNavItemSuppressedBackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_duoInternalNavItemBackDepth++;
        @try {
            [navItem setHidesBackButton:(origHides ? origHides.boolValue : NO) animated:NO];
        } @finally {
            pt_duoInternalNavItemBackDepth--;
        }
    }
}

static NSArray<UIBarButtonItem *> *pt_collectVerticalBarButtonItems(UINavigationController *nav,
                                                                    NSArray<UIBarButtonItem *> * __autoreleasing *outNavBarItems,
                                                                    NSArray<UIBarButtonItem *> * __autoreleasing *outToolbarItems) {
    if (outNavBarItems) { *outNavBarItems = @[]; }
    if (outToolbarItems) { *outToolbarItems = @[]; }
    if (!nav || !nav.topViewController) {
        return @[];
    }
    UIViewController *topVC = nav.topViewController;
    NSMutableArray<UIBarButtonItem *> *raw = [NSMutableArray array];
    NSMutableArray<UIBarButtonItem *> *navItems = [NSMutableArray array];
    NSMutableArray<UIBarButtonItem *> *toolItems = [NSMutableArray array];
    NSHashTable<UIBarButtonItem *> *seen = [NSHashTable weakObjectsHashTable];

    void (^appendItem)(UIBarButtonItem *, NSMutableArray<UIBarButtonItem *> *) = ^(UIBarButtonItem *item, NSMutableArray<UIBarButtonItem *> *bucket) {
        if (!item || [seen containsObject:item]) {
            return;
        }
        if (pt_barItemAppWantsHidden(item)) {
            return;
        }
        // Skip UIBarButtonItemAxisBehaviorHorizontalOnly (1)
        SEL axisSel = sel_registerName("axisBehavior");
        if ([item respondsToSelector:axisSel]) {
            NSInteger axis = ((NSInteger (*)(id, SEL))objc_msgSend)(item, axisSel);
            if (axis == 1) {
                return;
            }
        }
        BOOL hasActionableContent = (item.image != nil || item.title.length > 0)
            && (item.action != NULL || item.primaryAction != nil || item.menu != nil);
        if (!hasActionableContent) {
            return;
        }
        [seen addObject:item];
        [raw addObject:item];
        [bucket addObject:item];
    };

    if (@available(iOS 16.0, *)) {
        for (UIBarButtonItemGroup *group in topVC.navigationItem.trailingItemGroups) {
            if (group.hidden) {
                continue;
            }
            for (UIBarButtonItem *item in group.barButtonItems) {
                appendItem(item, navItems);
            }
        }
    }
    for (UIBarButtonItem *item in topVC.navigationItem.rightBarButtonItems) {
        appendItem(item, navItems);
    }

    if (topVC.toolbarItems.count > 0) {
        for (UIBarButtonItem *item in topVC.toolbarItems) {
            BOOL verticalPreferred = NO;
            SEL axisSel = sel_registerName("axisBehavior");
            if ([item respondsToSelector:axisSel]) {
                verticalPreferred = (((NSInteger (*)(id, SEL))objc_msgSend)(item, axisSel) == 2);
            }
            if (!nav.isToolbarHidden || verticalPreferred) {
                appendItem(item, toolItems);
            }
        }
    }

    if (raw.count > 6) {
        NSArray<UIBarButtonItem *> *trimmed = [raw subarrayWithRange:NSMakeRange(0, 6)];
        NSHashTable<UIBarButtonItem *> *kept = [NSHashTable weakObjectsHashTable];
        for (UIBarButtonItem *it in trimmed) { [kept addObject:it]; }
        NSMutableArray<UIBarButtonItem *> *keptNav = [NSMutableArray array];
        for (UIBarButtonItem *it in navItems) { if ([kept containsObject:it]) [keptNav addObject:it]; }
        NSMutableArray<UIBarButtonItem *> *keptTool = [NSMutableArray array];
        for (UIBarButtonItem *it in toolItems) { if ([kept containsObject:it]) [keptTool addObject:it]; }
        if (outNavBarItems) { *outNavBarItems = keptNav; }
        if (outToolbarItems) { *outToolbarItems = keptTool; }
        return trimmed;
    }
    if (outNavBarItems) { *outNavBarItems = navItems; }
    if (outToolbarItems) { *outToolbarItems = toolItems; }
    return raw;
}

// MARK: - Synthetic Liquid Glass Vertical Bar Host View

@interface PTDuoBarPillContainerView : UIView
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIStackView *stackView;
- (instancetype)initWithCornerRadius:(CGFloat)radius;
- (void)applyGlassBorderForTraitCollection:(UITraitCollection *)traits;
@end

@implementation PTDuoBarPillContainerView

- (instancetype)initWithCornerRadius:(CGFloat)radius {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [UIColor clearColor];

        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.14;
        self.layer.shadowRadius = 10.0;
        self.layer.shadowOffset = CGSizeMake(0.0, 3.0);

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.translatesAutoresizingMaskIntoConstraints = NO;
        _blurView.layer.cornerRadius = radius;
        _blurView.layer.cornerCurve = kCACornerCurveContinuous;
        _blurView.layer.borderWidth = 0.75;
        _blurView.clipsToBounds = YES;
        [self addSubview:_blurView];

        _stackView = [[UIStackView alloc] init];
        _stackView.translatesAutoresizingMaskIntoConstraints = NO;
        _stackView.axis = UILayoutConstraintAxisVertical;
        _stackView.alignment = UIStackViewAlignmentCenter;
        _stackView.distribution = UIStackViewDistributionEqualSpacing;
        _stackView.spacing = 4.0;
        [_blurView.contentView addSubview:_stackView];

        [NSLayoutConstraint activateConstraints:@[
            [_blurView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_blurView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_blurView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_blurView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_stackView.leadingAnchor constraintEqualToAnchor:_blurView.contentView.leadingAnchor constant:3.0],
            [_stackView.trailingAnchor constraintEqualToAnchor:_blurView.contentView.trailingAnchor constant:-3.0],
            [_stackView.topAnchor constraintEqualToAnchor:_blurView.contentView.topAnchor constant:4.0],
            [_stackView.bottomAnchor constraintEqualToAnchor:_blurView.contentView.bottomAnchor constant:-4.0],
        ]];
        [self applyGlassBorderForTraitCollection:self.traitCollection];
    }
    return self;
}

- (void)applyGlassBorderForTraitCollection:(UITraitCollection *)traits {
    BOOL isDark = (traits.userInterfaceStyle == UIUserInterfaceStyleDark);
    _blurView.layer.borderColor = (isDark
        ? [UIColor colorWithWhite:1.0 alpha:0.18]
        : [UIColor colorWithWhite:0.0 alpha:0.09]).CGColor;
    self.layer.shadowOpacity = isDark ? 0.30 : 0.14;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyGlassBorderForTraitCollection:self.traitCollection];
}

@end

@interface PTDuoVerticalBarHostView : UIView
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, weak) UINavigationController *activeNavController;
@property (nonatomic, weak) UINavigationController *suppressedNavController;
@property (nonatomic, weak) UINavigationController *suppressedToolbarNavController;
@property (nonatomic, weak) UINavigationItem *suppressedBackNavItem;
@property (nonatomic, strong) NSHashTable<UIBarButtonItem *> *suppressedBarItems;
@property (nonatomic, weak) UITabBarController *activeTabBarController;
@property (nonatomic, weak) UITabBar *relocatedTabBar;
@property (nonatomic, strong) NSArray<UIBarButtonItem *> *boundBarItems;
@property (nonatomic, copy) NSString *lastRenderSignature;

@property (nonatomic, strong) UIStackView *topStackView;
@property (nonatomic, strong) PTDuoBarPillContainerView *backPill;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) PTDuoBarPillContainerView *itemsPill;
@property (nonatomic, strong) PTDuoBarPillContainerView *dockPill;
@end

@implementation PTDuoVerticalBarHostView

- (instancetype)initWithWindow:(UIWindow *)window {
    CGRect frame = CGRectMake(CGRectGetWidth(window.bounds) - kPTDuoVerticalBarWidth,
                              0.0,
                              kPTDuoVerticalBarWidth,
                              CGRectGetHeight(window.bounds));
    self = [super initWithFrame:frame];
    if (self) {
        _hostWindow = window;
        _suppressedBarItems = [NSHashTable weakObjectsHashTable];
        self.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.hidden = YES;
        self.layer.zPosition = 900.0;

        _topStackView = [[UIStackView alloc] init];
        _topStackView.translatesAutoresizingMaskIntoConstraints = NO;
        _topStackView.axis = UILayoutConstraintAxisVertical;
        _topStackView.alignment = UIStackViewAlignmentCenter;
        _topStackView.distribution = UIStackViewDistributionFill;
        _topStackView.spacing = 10.0;
        [self addSubview:_topStackView];

        _backPill = [[PTDuoBarPillContainerView alloc] initWithCornerRadius:22.0];
        _backPill.hidden = YES;
        [_topStackView addArrangedSubview:_backPill];

        _backButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _backButton.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:16.0
                                                                                           weight:UIImageSymbolWeightSemibold];
        [_backButton setImage:[UIImage systemImageNamed:@"chevron.backward" withConfiguration:symCfg]
                     forState:UIControlStateNormal];
        _backButton.tintColor = [UIColor labelColor];
        _backButton.accessibilityLabel = @"Back";
        [_backButton addTarget:self action:@selector(handleBackTap:) forControlEvents:UIControlEventTouchUpInside];
        [NSLayoutConstraint activateConstraints:@[
            [_backButton.widthAnchor constraintEqualToConstant:38.0],
            [_backButton.heightAnchor constraintEqualToConstant:36.0],
        ]];
        [_backPill.stackView addArrangedSubview:_backButton];

        _itemsPill = [[PTDuoBarPillContainerView alloc] initWithCornerRadius:22.0];
        _itemsPill.hidden = YES;
        [_topStackView addArrangedSubview:_itemsPill];

        _dockPill = [[PTDuoBarPillContainerView alloc] initWithCornerRadius:23.0];
        _dockPill.hidden = YES;
        [self addSubview:_dockPill];

        [NSLayoutConstraint activateConstraints:@[
            [_topStackView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_topStackView.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor constant:16.0],
            [_backPill.widthAnchor constraintEqualToConstant:44.0],
            [_itemsPill.widthAnchor constraintEqualToConstant:44.0],

            [_dockPill.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_dockPill.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-18.0],
            [_dockPill.widthAnchor constraintEqualToConstant:46.0],
        ]];
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha <= 0.01 || !self.userInteractionEnabled) {
        return nil;
    }
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == self.topStackView) ? nil : hit;
}

- (void)restoreRelocatedTabBarIfNeeded {
    if (self.relocatedTabBar) {
        pt_setTabBarRelocatedHidden(self.relocatedTabBar, NO);
        self.relocatedTabBar = nil;
    }
}

- (void)restoreSuppressedNavChromeIfNeeded {
    if (self.suppressedNavController) {
        pt_setNavBarVisualSuppressed(self.suppressedNavController, NO);
        self.suppressedNavController = nil;
    }
    if (self.suppressedToolbarNavController) {
        pt_setToolbarVisualSuppressed(self.suppressedToolbarNavController, NO);
        self.suppressedToolbarNavController = nil;
    }
    if (self.suppressedBackNavItem) {
        pt_setNavItemBackButtonSuppressed(self.suppressedBackNavItem, NO);
        self.suppressedBackNavItem = nil;
    }
    if (self.suppressedBarItems.count > 0) {
        for (UIBarButtonItem *item in [self.suppressedBarItems allObjects]) {
            pt_setBarItemHorizontalSuppressed(item, NO);
        }
        [self.suppressedBarItems removeAllObjects];
    }
}

- (void)syncSuppressedNavChromeForNav:(UINavigationController *)nav
                             showBack:(BOOL)showBack
                       mirroredNavBar:(NSArray<UIBarButtonItem *> *)mirroredNavItems
                      mirroredToolbar:(NSArray<UIBarButtonItem *> *)mirroredToolItems {
    if (self.suppressedNavController && self.suppressedNavController != nav) {
        pt_setNavBarVisualSuppressed(self.suppressedNavController, NO);
        self.suppressedNavController = nil;
    }
    if (self.suppressedToolbarNavController && self.suppressedToolbarNavController != nav) {
        pt_setToolbarVisualSuppressed(self.suppressedToolbarNavController, NO);
        self.suppressedToolbarNavController = nil;
    }

    BOOL navBarVisibleByApp = NO;
    if (nav && nav.navigationBar && !nav.isNavigationBarHidden) {
        BOOL alreadySuppressed = [objc_getAssociatedObject(nav.navigationBar, kPTDuoNavBarSuppressedKey) boolValue];
        NSNumber *appHidden = objc_getAssociatedObject(nav.navigationBar, kPTDuoNavBarAppHiddenKey);
        BOOL appWantsHidden = alreadySuppressed ? (appHidden ? appHidden.boolValue : NO) : nav.navigationBar.hidden;
        navBarVisibleByApp = !appWantsHidden;
    }

    BOOL mirroredAnyNavBarControl = (showBack || mirroredNavItems.count > 0);
    BOOL hasUnmirroredTopContent = navBarVisibleByApp ? pt_navigationBarHasUnmirroredContent(nav) : NO;
    PTDuoNavBarSuppressionMode mode = PTDuoClassifyNavBarSuppression(navBarVisibleByApp,
                                                                     mirroredAnyNavBarControl,
                                                                     hasUnmirroredTopContent);

    if (mode == PTDuoNavBarSuppressionFull) {
        // Case 1: UINavigationBar has no title/titleView/search/leading/HorizontalOnly items —
        // suppress the entire redundant horizontal bar and its extra top safe-area push cleanly.
        if (self.suppressedBackNavItem) {
            pt_setNavItemBackButtonSuppressed(self.suppressedBackNavItem, NO);
            self.suppressedBackNavItem = nil;
        }
        pt_setNavBarVisualSuppressed(nav, YES);
        self.suppressedNavController = nav;
    } else {
        if (self.suppressedNavController) {
            pt_setNavBarVisualSuppressed(self.suppressedNavController, NO);
            self.suppressedNavController = nil;
        }
        // Case 2: Keep title/search/leading/HorizontalOnly top bar visible, hiding ONLY relocated back & items.
        UINavigationItem *targetBackNavItem = (mode == PTDuoNavBarSuppressionItemsOnly && showBack)
            ? nav.topViewController.navigationItem
            : nil;
        if (self.suppressedBackNavItem && self.suppressedBackNavItem != targetBackNavItem) {
            pt_setNavItemBackButtonSuppressed(self.suppressedBackNavItem, NO);
            self.suppressedBackNavItem = nil;
        }
        if (targetBackNavItem) {
            pt_setNavItemBackButtonSuppressed(targetBackNavItem, YES);
            self.suppressedBackNavItem = targetBackNavItem;
        }
    }

    // Symmetrical iOS 27.1 rule for bottom UIToolbar
    BOOL toolbarVisibleByApp = NO;
    if (nav && nav.toolbar && !nav.isToolbarHidden) {
        BOOL alreadyToolbarSuppressed = [objc_getAssociatedObject(nav.toolbar, kPTDuoToolbarSuppressedKey) boolValue];
        NSNumber *appHidden = objc_getAssociatedObject(nav.toolbar, kPTDuoToolbarAppHiddenKey);
        BOOL appWantsHidden = alreadyToolbarSuppressed ? (appHidden ? appHidden.boolValue : NO) : nav.toolbar.hidden;
        toolbarVisibleByApp = !appWantsHidden;
    }
    BOOL hasUnmirroredToolbarContent = toolbarVisibleByApp ? pt_toolbarHasUnmirroredContent(nav) : NO;
    PTDuoNavBarSuppressionMode toolbarMode = PTDuoClassifyNavBarSuppression(toolbarVisibleByApp,
                                                                            mirroredToolItems.count > 0,
                                                                            hasUnmirroredToolbarContent);
    if (toolbarMode == PTDuoNavBarSuppressionFull) {
        pt_setToolbarVisualSuppressed(nav, YES);
        self.suppressedToolbarNavController = nav;
    } else if (self.suppressedToolbarNavController) {
        pt_setToolbarVisualSuppressed(self.suppressedToolbarNavController, NO);
        self.suppressedToolbarNavController = nil;
    }

    // Determine exact set of UIBarButtonItems that should be hidden in visible horizontal bars
    // (Case 2 nav-bar items + Case 2 toolbar items).
    NSHashTable<UIBarButtonItem *> *desiredSuppressedItems = [NSHashTable weakObjectsHashTable];
    if (mode == PTDuoNavBarSuppressionItemsOnly) {
        for (UIBarButtonItem *item in mirroredNavItems) {
            [desiredSuppressedItems addObject:item];
        }
    }
    if (toolbarMode == PTDuoNavBarSuppressionItemsOnly) {
        for (UIBarButtonItem *item in mirroredToolItems) {
            [desiredSuppressedItems addObject:item];
        }
    }

    for (UIBarButtonItem *prevItem in [self.suppressedBarItems allObjects]) {
        if (![desiredSuppressedItems containsObject:prevItem]) {
            pt_setBarItemHorizontalSuppressed(prevItem, NO);
            [self.suppressedBarItems removeObject:prevItem];
        }
    }
    for (UIBarButtonItem *nextItem in [desiredSuppressedItems allObjects]) {
        pt_setBarItemHorizontalSuppressed(nextItem, YES);
        [self.suppressedBarItems addObject:nextItem];
    }
}

- (void)hideAndRestore {
    [self restoreRelocatedTabBarIfNeeded];
    [self restoreSuppressedNavChromeIfNeeded];
    self.hidden = YES;
    self.lastRenderSignature = nil;
}

- (void)handleBackTap:(UIButton *)sender {
    (void)sender;
    UINavigationController *nav = self.activeNavController;
    if (nav && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:YES];
        pt_scheduleRefreshForWindow(self.hostWindow);
    }
}

- (void)handleBarItemTap:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || idx >= (NSInteger)self.boundBarItems.count) {
        return;
    }
    UIBarButtonItem *item = self.boundBarItems[(NSUInteger)idx];
    if (!item || !item.enabled) {
        return;
    }
    if (@available(iOS 14.0, *)) {
        if (item.primaryAction) {
            SEL performSel = sel_registerName("performWithSender:target:");
            if ([item.primaryAction respondsToSelector:performSel]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(item.primaryAction, performSel, item, nil);
                pt_scheduleRefreshForWindow(self.hostWindow);
                return;
            }
        }
    }
    if (item.action != NULL) {
        [[UIApplication sharedApplication] sendAction:item.action to:item.target from:item forEvent:nil];
        pt_scheduleRefreshForWindow(self.hostWindow);
    }
}

- (void)handleTabItemTap:(UIButton *)sender {
    UITabBarController *tabVC = self.activeTabBarController;
    if (!tabVC) {
        return;
    }
    NSUInteger idx = (NSUInteger)sender.tag;
    NSArray<UIViewController *> *vcs = tabVC.viewControllers;
    if (idx >= vcs.count) {
        return;
    }
    UIViewController *targetVC = vcs[idx];
    id<UITabBarControllerDelegate> delegate = tabVC.delegate;
    if (delegate && [delegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)]) {
        if (![delegate tabBarController:tabVC shouldSelectViewController:targetVC]) {
            return;
        }
    }
    tabVC.selectedIndex = idx;
    if (delegate && [delegate respondsToSelector:@selector(tabBarController:didSelectViewController:)]) {
        [delegate tabBarController:tabVC didSelectViewController:targetVC];
    }
    pt_scheduleRefreshForWindow(self.hostWindow);
}

- (void)syncWithWindow:(UIWindow *)window {
    self.hostWindow = window;
    CGRect targetFrame = CGRectMake(CGRectGetWidth(window.bounds) - kPTDuoVerticalBarWidth,
                                    0.0,
                                    kPTDuoVerticalBarWidth,
                                    CGRectGetHeight(window.bounds));
    if (!CGRectEqualToRect(self.frame, targetFrame)) {
        self.frame = targetFrame;
    }

    // Critical Auto-Yield Rule: if the app renders its own sidebar inside the right strip,
    // yield completely so there is zero overlap or duplicate back button.
    if (pt_windowHasAppRenderedRightSidebar(window, self)) {
        [self hideAndRestore];
        return;
    }

    UINavigationController *nav = nil;
    UITabBarController *tabVC = nil;
    pt_findActiveNavAndTabControllers(window, &nav, &tabVC);
    self.activeNavController = nav;
    self.activeTabBarController = tabVC;

    BOOL showBack = (nav != nil
                     && nav.viewControllers.count > 1
                     && !pt_navItemAppWantsHidesBackButton(nav.topViewController.navigationItem));

    NSArray<UIBarButtonItem *> *mirroredNavItems = nil;
    NSArray<UIBarButtonItem *> *mirroredToolItems = nil;
    NSArray<UIBarButtonItem *> *barItems = pt_collectVerticalBarButtonItems(nav, &mirroredNavItems, &mirroredToolItems);

    // Check whether UITabBar is eligible for vertical dock relocation
    UITabBar *eligibleTabBar = nil;
    if (tabVC && tabVC.tabBar) {
        UITabBar *tb = tabVC.tabBar;
        BOOL isAlreadyRelocated = [objc_getAssociatedObject(tb, kPTDuoTabBarRelocatedKey) boolValue];
        NSNumber *appHiddenNum = objc_getAssociatedObject(tb, kPTDuoTabBarAppHiddenKey);
        BOOL appWantsHidden = isAlreadyRelocated ? (appHiddenNum ? appHiddenNum.boolValue : NO) : tb.hidden;
        BOOL navHidesBottomBar = NO;
        if (nav && nav.viewControllers.count > 1) {
            for (NSUInteger i = 1; i < nav.viewControllers.count; i++) {
                if (nav.viewControllers[i].hidesBottomBarWhenPushed) {
                    navHidesBottomBar = YES;
                    break;
                }
            }
        }
        if (!appWantsHidden && !navHidesBottomBar && !pt_duoTabBarIsCustomReplacement(tb)) {
            eligibleTabBar = tb;
        }
    }

    if (self.relocatedTabBar && self.relocatedTabBar != eligibleTabBar) {
        [self restoreRelocatedTabBarIfNeeded];
    }

    if (!showBack && barItems.count == 0 && eligibleTabBar == nil) {
        [self hideAndRestore];
        return;
    }

    [self syncSuppressedNavChromeForNav:nav
                               showBack:showBack
                         mirroredNavBar:mirroredNavItems
                        mirroredToolbar:mirroredToolItems];

    if (eligibleTabBar) {
        pt_setTabBarRelocatedHidden(eligibleTabBar, YES);
        self.relocatedTabBar = eligibleTabBar;
    }

    // Build compact signature to avoid unnecessary view churn
    NSMutableString *sig = [NSMutableString stringWithFormat:@"b:%d|i:", showBack ? 1 : 0];
    for (UIBarButtonItem *item in barItems) {
        [sig appendFormat:@"%p:%d:%@,", item, item.enabled ? 1 : 0, item.title ?: @""];
    }
    if (eligibleTabBar) {
        [sig appendFormat:@"|t:%p:%lu:%lu:", eligibleTabBar,
         (unsigned long)eligibleTabBar.items.count,
         (unsigned long)tabVC.selectedIndex];
        for (UITabBarItem *ti in eligibleTabBar.items) {
            [sig appendFormat:@"%@,", ti.title ?: @""];
        }
    }

    if (![sig isEqualToString:self.lastRenderSignature]) {
        self.lastRenderSignature = sig;
        self.boundBarItems = barItems;
        [self rebuildPillsWithShowBack:showBack
                              barItems:barItems
                                 tabVC:eligibleTabBar ? tabVC : nil
                                tabBar:eligibleTabBar];
    }

    self.hidden = NO;
    if (window.subviews.lastObject != self) {
        [window bringSubviewToFront:self];
    }
}

- (void)rebuildPillsWithShowBack:(BOOL)showBack
                        barItems:(NSArray<UIBarButtonItem *> *)barItems
                           tabVC:(UITabBarController *)tabVC
                          tabBar:(UITabBar *)tabBar {
    self.backPill.hidden = !showBack;

    // Rebuild nav/toolbar items pill
    for (UIView *v in [self.itemsPill.stackView.arrangedSubviews copy]) {
        [self.itemsPill.stackView removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    self.itemsPill.hidden = (barItems.count == 0);
    for (NSUInteger i = 0; i < barItems.count; i++) {
        UIBarButtonItem *item = barItems[i];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        btn.tag = (NSInteger)i;
        btn.enabled = item.enabled;
        btn.tintColor = item.tintColor ?: [UIColor labelColor];
        btn.accessibilityLabel = item.accessibilityLabel ?: item.title;
        if (item.image) {
            UIImage *img = item.image;
            if (img.renderingMode == UIImageRenderingModeAutomatic) {
                img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            }
            [btn setImage:img forState:UIControlStateNormal];
            btn.imageView.contentMode = UIViewContentModeScaleAspectFit;
            btn.imageEdgeInsets = UIEdgeInsetsMake(7.0, 7.0, 7.0, 7.0);
        } else if (item.title.length > 0) {
            NSString *label = item.title.length > 3 ? [item.title substringToIndex:3] : item.title;
            [btn setTitle:label forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
        }
        if (@available(iOS 14.0, *)) {
            if (item.menu) {
                btn.menu = item.menu;
                btn.showsMenuAsPrimaryAction = (item.primaryAction == nil && item.action == NULL);
            }
        }
        [btn addTarget:self action:@selector(handleBarItemTap:) forControlEvents:UIControlEventTouchUpInside];
        [NSLayoutConstraint activateConstraints:@[
            [btn.widthAnchor constraintEqualToConstant:36.0],
            [btn.heightAnchor constraintEqualToConstant:36.0],
        ]];
        [self.itemsPill.stackView addArrangedSubview:btn];
    }

    // Rebuild vertical dock pill for UITabBar
    for (UIView *v in [self.dockPill.stackView.arrangedSubviews copy]) {
        [self.dockPill.stackView removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    BOOL showDock = (tabVC != nil && tabBar != nil && tabBar.items.count >= 2);
    self.dockPill.hidden = !showDock;
    if (showDock) {
        NSArray<UITabBarItem *> *items = tabBar.items;
        NSUInteger maxTabs = MIN(items.count, (NSUInteger)6);
        UIColor *activeTint = tabBar.tintColor ?: [UIColor systemBlueColor];
        for (NSUInteger i = 0; i < maxTabs; i++) {
            UITabBarItem *ti = items[i];
            BOOL isSelected = (tabVC.selectedIndex == i);

            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.translatesAutoresizingMaskIntoConstraints = NO;
            btn.tag = (NSInteger)i;
            btn.layer.cornerRadius = 18.0;
            btn.layer.cornerCurve = kCACornerCurveContinuous;
            btn.backgroundColor = isSelected ? [activeTint colorWithAlphaComponent:0.18] : [UIColor clearColor];
            btn.tintColor = isSelected ? activeTint : [UIColor secondaryLabelColor];
            btn.accessibilityLabel = ti.title ?: [NSString stringWithFormat:@"Tab %lu", (unsigned long)(i + 1)];

            UIImage *img = isSelected ? (ti.selectedImage ?: ti.image) : ti.image;
            if (img) {
                if (img.renderingMode == UIImageRenderingModeAutomatic) {
                    img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
                }
                [btn setImage:img forState:UIControlStateNormal];
                btn.imageView.contentMode = UIViewContentModeScaleAspectFit;
                btn.imageEdgeInsets = UIEdgeInsetsMake(7.0, 7.0, 7.0, 7.0);
            } else if (ti.title.length > 0) {
                NSString *shortTitle = ti.title.length > 2 ? [ti.title substringToIndex:2] : ti.title;
                [btn setTitle:shortTitle forState:UIControlStateNormal];
                btn.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:isSelected ? UIFontWeightSemibold : UIFontWeightRegular];
            }

            [btn addTarget:self action:@selector(handleTabItemTap:) forControlEvents:UIControlEventTouchUpInside];
            [NSLayoutConstraint activateConstraints:@[
                [btn.widthAnchor constraintEqualToConstant:38.0],
                [btn.heightAnchor constraintEqualToConstant:38.0],
            ]];
            [self.dockPill.stackView addArrangedSubview:btn];
        }
    }
}

@end

// MARK: - Window Refresh Orchestrator

static PTDuoVerticalBarHostView *pt_hostViewForWindow(UIWindow *window, BOOL createIfNeeded) {
    if (!window) {
        return nil;
    }
    PTDuoVerticalBarHostView *host = objc_getAssociatedObject(window, kPTDuoWindowHostViewKey);
    if (!host && createIfNeeded) {
        host = [[PTDuoVerticalBarHostView alloc] initWithWindow:window];
        [window addSubview:host];
        objc_setAssociatedObject(window, kPTDuoWindowHostViewKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return host;
}

static void pt_refreshDuoVerticalBarForWindow(UIWindow *window) {
    if (!window || ![NSThread isMainThread]) {
        return;
    }
    if (pt_duoRefreshDepth > 0) {
        return;
    }
    pt_duoRefreshDepth++;
    @try {
        PTDuoBarState prevState = PTDuoBarStateUnset;
        NSNumber *prevNum = objc_getAssociatedObject(window, kPTDuoWindowStateKey);
        if (prevNum) {
            prevState = (PTDuoBarState)prevNum.integerValue;
        }
        PTDuoBarState nextState = pt_computeDesiredBarStateForWindow(window);
        BOOL wasActive = (prevState == PTDuoBarStateActive);
        BOOL isActive = (nextState == PTDuoBarStateActive);

        // Apply traits to window and windowScene using dedicated trait-state keys
        pt_applyVerticalBarTraitsToObject(window, kPTDuoWindowTraitStateKey, nextState);
        if (window.windowScene) {
            pt_applyVerticalBarTraitsToObject(window.windowScene, kPTDuoSceneTraitStateKey, nextState);
        }
        objc_setAssociatedObject(window, kPTDuoWindowStateKey, @(nextState), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (wasActive != isActive) {
            SEL safeAreaChangeSel = sel_registerName("_sceneSettingsSafeAreaInsetsDidChange");
            if ([window respondsToSelector:safeAreaChangeSel]) {
                ((void (*)(id, SEL))objc_msgSend)(window, safeAreaChangeSel);
            }
            // Schedule a short follow-up scan so apps that mount custom sidebars
            // asynchronously after receiving verticalBarEdge/safeArea updates trigger auto-yield.
            if (isActive) {
                __weak UIWindow *weakWin = window;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UIWindow *strongWin = weakWin;
                    if (strongWin) {
                        pt_refreshDuoVerticalBarForWindow(strongWin);
                    }
                });
            }
        }

        if (isActive) {
            PTDuoVerticalBarHostView *host = pt_hostViewForWindow(window, YES);
            [host syncWithWindow:window];
        } else {
            PTDuoVerticalBarHostView *host = pt_hostViewForWindow(window, NO);
            if (host) {
                [host hideAndRestore];
            }
        }
    } @finally {
        pt_duoRefreshDepth--;
    }
}

static void pt_scheduleRefreshForWindow(UIWindow *window) {
    if (!window || !PTShouldEnableDuoVerticalBar()) {
        return;
    }
    if (![NSThread isMainThread]) {
        __weak UIWindow *weakWin = window;
        dispatch_async(dispatch_get_main_queue(), ^{
            pt_scheduleRefreshForWindow(weakWin);
        });
        return;
    }
    if ([objc_getAssociatedObject(window, kPTDuoWindowRefreshScheduledKey) boolValue]) {
        return;
    }
    objc_setAssociatedObject(window, kPTDuoWindowRefreshScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIWindow *weakWin = window;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *strongWin = weakWin;
        if (!strongWin) {
            return;
        }
        objc_setAssociatedObject(strongWin, kPTDuoWindowRefreshScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_refreshDuoVerticalBarForWindow(strongWin);
    });
}

static UIWindow *pt_findActivePrimaryWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow && pt_isEligiblePrimaryWindow(w)) {
                return w;
            }
        }
        for (UIWindow *w in ws.windows) {
            if (pt_isEligiblePrimaryWindow(w)) {
                return w;
            }
        }
    }
    return nil;
}

// MARK: - Swizzled UIKit Hooks

static UIEdgeInsets (*pt_origWindowSceneSafeArea)(UIWindow *, SEL, BOOL) = NULL;
static UIEdgeInsets pt_windowSceneSafeArea(UIWindow *self, SEL _cmd, BOOL includingStatusBar) {
    UIEdgeInsets insets = pt_origWindowSceneSafeArea
        ? pt_origWindowSceneSafeArea(self, _cmd, includingStatusBar)
        : UIEdgeInsetsZero;
    if (pt_isDuoVerticalBarActiveForWindow(self)) {
        insets.right = MAX(insets.right, kPTDuoVerticalBarWidth);
    }
    return insets;
}

static UIEdgeInsets (*pt_origSceneSafeAreaForOrientation)(UIWindowScene *, SEL, UIInterfaceOrientation, BOOL) = NULL;
static UIEdgeInsets pt_sceneSafeAreaForOrientation(UIWindowScene *self,
                                                   SEL _cmd,
                                                   UIInterfaceOrientation orientation,
                                                   BOOL statusBarHidden) {
    UIEdgeInsets insets = pt_origSceneSafeAreaForOrientation
        ? pt_origSceneSafeAreaForOrientation(self, _cmd, orientation, statusBarHidden)
        : UIEdgeInsetsZero;
    if (PTShouldEnableDuoVerticalBar()) {
        for (UIWindow *w in self.windows) {
            if (pt_isEligiblePrimaryWindow(w) && pt_isDuoVerticalBarActiveForWindow(w)) {
                insets.right = MAX(insets.right, kPTDuoVerticalBarWidth);
                break;
            }
        }
    }
    return insets;
}

// UIViewLayoutRegion factory/init hooks
static id (*pt_origRegionBarEdgeExtent)(id, SEL, UIRectEdge, CGFloat) = NULL;
static id pt_regionBarEdgeExtent(id self, SEL _cmd, UIRectEdge edge, CGFloat extent) {
    id r = pt_origRegionBarEdgeExtent ? pt_origRegionBarEdgeExtent(self, _cmd, edge, extent) : nil;
    pt_attachBarRegionMeta(r, NO, edge, NSDirectionalRectEdgeNone, YES, extent);
    return r;
}

static id (*pt_origRegionBarDirEdgeExtent)(id, SEL, NSDirectionalRectEdge, CGFloat) = NULL;
static id pt_regionBarDirEdgeExtent(id self, SEL _cmd, NSDirectionalRectEdge edge, CGFloat extent) {
    id r = pt_origRegionBarDirEdgeExtent ? pt_origRegionBarDirEdgeExtent(self, _cmd, edge, extent) : nil;
    pt_attachBarRegionMeta(r, YES, UIRectEdgeNone, edge, YES, extent);
    return r;
}

static id (*pt_origRegionBarEdgeDefault)(id, SEL, UIRectEdge) = NULL;
static id pt_regionBarEdgeDefault(id self, SEL _cmd, UIRectEdge edge) {
    id r = pt_origRegionBarEdgeDefault ? pt_origRegionBarEdgeDefault(self, _cmd, edge) : nil;
    pt_attachBarRegionMeta(r, NO, edge, NSDirectionalRectEdgeNone, NO, kPTDuoVerticalBarWidth);
    return r;
}

static id (*pt_origRegionBarDirEdgeDefault)(id, SEL, NSDirectionalRectEdge) = NULL;
static id pt_regionBarDirEdgeDefault(id self, SEL _cmd, NSDirectionalRectEdge edge) {
    id r = pt_origRegionBarDirEdgeDefault ? pt_origRegionBarDirEdgeDefault(self, _cmd, edge) : nil;
    pt_attachBarRegionMeta(r, YES, UIRectEdgeNone, edge, NO, kPTDuoVerticalBarWidth);
    return r;
}

static id (*pt_origInitBarEdgeExtent)(id, SEL, UIRectEdge, CGFloat) = NULL;
static id pt_initBarEdgeExtent(id self, SEL _cmd, UIRectEdge edge, CGFloat extent) {
    id r = pt_origInitBarEdgeExtent ? pt_origInitBarEdgeExtent(self, _cmd, edge, extent) : nil;
    pt_attachBarRegionMeta(r, NO, edge, NSDirectionalRectEdgeNone, YES, extent);
    return r;
}

static id (*pt_origInitBarDirEdgeExtent)(id, SEL, NSDirectionalRectEdge, CGFloat) = NULL;
static id pt_initBarDirEdgeExtent(id self, SEL _cmd, NSDirectionalRectEdge edge, CGFloat extent) {
    id r = pt_origInitBarDirEdgeExtent ? pt_origInitBarDirEdgeExtent(self, _cmd, edge, extent) : nil;
    pt_attachBarRegionMeta(r, YES, UIRectEdgeNone, edge, YES, extent);
    return r;
}

static id (*pt_origInitBarEdgeDefault)(id, SEL, UIRectEdge) = NULL;
static id pt_initBarEdgeDefault(id self, SEL _cmd, UIRectEdge edge) {
    id r = pt_origInitBarEdgeDefault ? pt_origInitBarEdgeDefault(self, _cmd, edge) : nil;
    pt_attachBarRegionMeta(r, NO, edge, NSDirectionalRectEdgeNone, NO, kPTDuoVerticalBarWidth);
    return r;
}

static id (*pt_origInitBarDirEdgeDefault)(id, SEL, NSDirectionalRectEdge) = NULL;
static id pt_initBarDirEdgeDefault(id self, SEL _cmd, NSDirectionalRectEdge edge) {
    id r = pt_origInitBarDirEdgeDefault ? pt_origInitBarDirEdgeDefault(self, _cmd, edge) : nil;
    pt_attachBarRegionMeta(r, YES, UIRectEdgeNone, edge, NO, kPTDuoVerticalBarWidth);
    return r;
}

// UIView layoutGuideForLayoutRegion: / edgeInsetsForLayoutRegion: / directionalEdgeInsetsForLayoutRegion:
static UIWindow *pt_windowForView(UIView *view) {
    if ([view isKindOfClass:[UIWindow class]]) {
        return (UIWindow *)view;
    }
    return view.window;
}

static BOOL pt_matchActiveRightBarRegion(UIView *view, id layoutRegion, CGFloat *outExtent) {
    if (!view || !layoutRegion || pt_isTaggedPointer(layoutRegion)) {
        return NO;
    }
    PTDuoBarLayoutRegionMeta *meta = objc_getAssociatedObject(layoutRegion, kPTDuoBarRegionMetaKey);
    if (!meta) {
        return NO;
    }
    UIWindow *win = pt_windowForView(view);
    if (!win || !pt_isDuoVerticalBarActiveForWindow(win)) {
        return NO;
    }
    UIRectEdge physicalEdge = PTDuoResolvePhysicalBarEdge(meta.isDirectional,
                                                          meta.edge,
                                                          meta.directionalEdge,
                                                          view.effectiveUserInterfaceLayoutDirection);
    if (physicalEdge != UIRectEdgeRight) {
        return NO;
    }
    if (outExtent) {
        *outExtent = PTDuoResolveBarExtent(meta.hasExplicitExtent, meta.extent, CGRectGetWidth(view.bounds));
    }
    return YES;
}

static UILayoutGuide *(*pt_origLayoutGuideForLayoutRegion)(UIView *, SEL, id) = NULL;
static UILayoutGuide *pt_layoutGuideForLayoutRegion(UIView *self, SEL _cmd, id layoutRegion) {
    CGFloat extent = 0.0;
    if (pt_matchActiveRightBarRegion(self, layoutRegion, &extent)) {
        NSMutableDictionary<NSNumber *, UILayoutGuide *> *guides =
            objc_getAssociatedObject(self, kPTDuoViewBarGuidesKey);
        if (!guides) {
            guides = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(self, kPTDuoViewBarGuidesKey, guides, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSNumber *key = @((NSInteger)llround(extent * 10.0));
        UILayoutGuide *guide = guides[key];
        if (!guide || guide.owningView != self) {
            guide = [[UILayoutGuide alloc] init];
            guide.identifier = [NSString stringWithFormat:@"PTDuoVerticalBarRegionGuide.right.%.1f", extent];
            [self addLayoutGuide:guide];
            NSLayoutConstraint *widthC = [guide.widthAnchor constraintEqualToConstant:extent];
            widthC.priority = UILayoutPriorityRequired - 1;
            [NSLayoutConstraint activateConstraints:@[
                [guide.topAnchor constraintEqualToAnchor:self.topAnchor],
                [guide.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
                [guide.rightAnchor constraintEqualToAnchor:self.rightAnchor],
                widthC,
            ]];
            guides[key] = guide;
        }
        return guide;
    }
    return pt_origLayoutGuideForLayoutRegion ? pt_origLayoutGuideForLayoutRegion(self, _cmd, layoutRegion) : nil;
}

static UIEdgeInsets (*pt_origEdgeInsetsForLayoutRegion)(UIView *, SEL, id) = NULL;
static UIEdgeInsets pt_edgeInsetsForLayoutRegion(UIView *self, SEL _cmd, id layoutRegion) {
    CGFloat extent = 0.0;
    if (pt_matchActiveRightBarRegion(self, layoutRegion, &extent)) {
        return UIEdgeInsetsMake(0.0, 0.0, 0.0, extent);
    }
    return pt_origEdgeInsetsForLayoutRegion ? pt_origEdgeInsetsForLayoutRegion(self, _cmd, layoutRegion) : UIEdgeInsetsZero;
}

static NSDirectionalEdgeInsets (*pt_origDirectionalEdgeInsetsForLayoutRegion)(UIView *, SEL, id) = NULL;
static NSDirectionalEdgeInsets pt_directionalEdgeInsetsForLayoutRegion(UIView *self, SEL _cmd, id layoutRegion) {
    CGFloat extent = 0.0;
    if (pt_matchActiveRightBarRegion(self, layoutRegion, &extent)) {
        BOOL isRTL = (self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft);
        return isRTL
            ? NSDirectionalEdgeInsetsMake(0.0, extent, 0.0, 0.0)
            : NSDirectionalEdgeInsetsMake(0.0, 0.0, 0.0, extent);
    }
    return pt_origDirectionalEdgeInsetsForLayoutRegion
        ? pt_origDirectionalEdgeInsetsForLayoutRegion(self, _cmd, layoutRegion)
        : NSDirectionalEdgeInsetsZero;
}

// Lifecycle & Configuration Refresh Hooks
static void (*pt_origWindowMakeKeyAndVisible)(UIWindow *, SEL) = NULL;
static void pt_windowMakeKeyAndVisible(UIWindow *self, SEL _cmd) {
    if (pt_origWindowMakeKeyAndVisible) {
        pt_origWindowMakeKeyAndVisible(self, _cmd);
    }
    pt_scheduleRefreshForWindow(self);
}

static void (*pt_origWindowSetRootVC)(UIWindow *, SEL, UIViewController *) = NULL;
static void pt_windowSetRootVC(UIWindow *self, SEL _cmd, UIViewController *vc) {
    if (pt_origWindowSetRootVC) {
        pt_origWindowSetRootVC(self, _cmd, vc);
    }
    pt_scheduleRefreshForWindow(self);
}

static void (*pt_origWindowLayoutSubviews)(UIWindow *, SEL) = NULL;
static void pt_windowLayoutSubviews(UIWindow *self, SEL _cmd) {
    if (pt_origWindowLayoutSubviews) {
        pt_origWindowLayoutSubviews(self, _cmd);
    }
    if (!pt_isEligiblePrimaryWindow(self)) {
        return;
    }
    CGSize currentSize = self.bounds.size;
    NSValue *lastSizeVal = objc_getAssociatedObject(self, kPTDuoWindowLastLayoutSizeKey);
    BOOL sizeChanged = (!lastSizeVal
                        || fabs(lastSizeVal.CGSizeValue.width - currentSize.width) > 0.5
                        || fabs(lastSizeVal.CGSizeValue.height - currentSize.height) > 0.5);
    if (sizeChanged) {
        objc_setAssociatedObject(self,
                                 kPTDuoWindowLastLayoutSizeKey,
                                 [NSValue valueWithCGSize:currentSize],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_scheduleRefreshForWindow(self);
        return;
    }

    // Periodically re-check auto-yield when the synthetic host view is active so lazy-mounted
    // app sidebars (e.g. opened after navigating to a detail page) trigger immediate yield.
    PTDuoVerticalBarHostView *host = pt_hostViewForWindow(self, NO);
    if (host && !host.hidden) {
        CFTimeInterval now = CACurrentMediaTime();
        NSNumber *lastScan = objc_getAssociatedObject(self, kPTDuoWindowLastSidebarScanTimeKey);
        if (!lastScan || (now - lastScan.doubleValue) >= 0.25) {
            objc_setAssociatedObject(self, kPTDuoWindowLastSidebarScanTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            pt_scheduleRefreshForWindow(self);
        }
    }
}

static void (*pt_origVCSetNeedsUpdateVerticalBar)(UIViewController *, SEL) = NULL;
static void pt_vcSetNeedsUpdateVerticalBar(UIViewController *self, SEL _cmd) {
    if (pt_origVCSetNeedsUpdateVerticalBar) {
        pt_origVCSetNeedsUpdateVerticalBar(self, _cmd);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origVCViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static void pt_vcViewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (pt_origVCViewDidAppear) {
        pt_origVCViewDidAppear(self, _cmd, animated);
    }
    UIWindow *win = self.viewIfLoaded.window;
    if (win && pt_isEligiblePrimaryWindow(win)) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origTabBarControllerSetSelectedIndex)(UITabBarController *, SEL, NSUInteger) = NULL;
static void pt_tabBarControllerSetSelectedIndex(UITabBarController *self, SEL _cmd, NSUInteger index) {
    if (pt_origTabBarControllerSetSelectedIndex) {
        pt_origTabBarControllerSetSelectedIndex(self, _cmd, index);
    }
    UIWindow *win = self.viewIfLoaded.window;
    if (win && pt_isEligiblePrimaryWindow(win)) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origTabBarSetHidden)(UITabBar *, SEL, BOOL) = NULL;
static void pt_tabBarSetHidden(UITabBar *self, SEL _cmd, BOOL hidden) {
    if (pt_duoInternalTabBarHiddenDepth == 0) {
        BOOL relocated = [objc_getAssociatedObject(self, kPTDuoTabBarRelocatedKey) boolValue];
        if (relocated) {
            objc_setAssociatedObject(self, kPTDuoTabBarAppHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!hidden) {
                // Keep bottom bar hidden while relocated onto the vertical rail; refresh to re-verify.
                if (self.window) {
                    pt_scheduleRefreshForWindow(self.window);
                }
                return;
            }
            // App explicitly hid the tab bar (e.g. hidesBottomBarWhenPushed); refresh so dock hides too.
            if (self.window) {
                pt_scheduleRefreshForWindow(self.window);
            }
        }
    }
    if (pt_origTabBarSetHidden) {
        pt_origTabBarSetHidden(self, _cmd, hidden);
    }
}

static void (*pt_origNavItemSetRightItems)(UINavigationItem *, SEL, NSArray<UIBarButtonItem *> *, BOOL) = NULL;
static void pt_navItemSetRightItems(UINavigationItem *self, SEL _cmd, NSArray<UIBarButtonItem *> *items, BOOL animated) {
    if (pt_origNavItemSetRightItems) {
        pt_origNavItemSetRightItems(self, _cmd, items, animated);
    }
    UIWindow *win = pt_findActivePrimaryWindow();
    if (win) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origNavItemSetTrailingGroups)(UINavigationItem *, SEL, NSArray *) = NULL;
static void pt_navItemSetTrailingGroups(UINavigationItem *self, SEL _cmd, NSArray *groups) {
    if (pt_origNavItemSetTrailingGroups) {
        pt_origNavItemSetTrailingGroups(self, _cmd, groups);
    }
    UIWindow *win = pt_findActivePrimaryWindow();
    if (win) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origVCSetToolbarItems)(UIViewController *, SEL, NSArray<UIBarButtonItem *> *, BOOL) = NULL;
static void pt_vcSetToolbarItems(UIViewController *self, SEL _cmd, NSArray<UIBarButtonItem *> *items, BOOL animated) {
    if (pt_origVCSetToolbarItems) {
        pt_origVCSetToolbarItems(self, _cmd, items, animated);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win) {
        pt_scheduleRefreshForWindow(win);
    }
}

// Horizontal UINavigationBar / UIToolbar / UIBarButtonItem / UINavigationItem dedup & inset hooks
static void (*pt_origNavBarSetHidden)(UINavigationBar *, SEL, BOOL) = NULL;
static void pt_navBarSetHidden(UINavigationBar *self, SEL _cmd, BOOL hidden) {
    if (pt_duoInternalNavBarVisualDepth == 0 && [objc_getAssociatedObject(self, kPTDuoNavBarSuppressedKey) boolValue]) {
        objc_setAssociatedObject(self, kPTDuoNavBarAppHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (self.window) {
            pt_scheduleRefreshForWindow(self.window);
        }
        if (!hidden) {
            return;
        }
    }
    if (pt_origNavBarSetHidden) {
        pt_origNavBarSetHidden(self, _cmd, hidden);
    }
}

static void (*pt_origNavBarSetAlpha)(UINavigationBar *, SEL, CGFloat) = NULL;
static void pt_navBarSetAlpha(UINavigationBar *self, SEL _cmd, CGFloat alpha) {
    if (pt_duoInternalNavBarVisualDepth == 0 && [objc_getAssociatedObject(self, kPTDuoNavBarSuppressedKey) boolValue]) {
        objc_setAssociatedObject(self, kPTDuoNavBarAppAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (alpha > 0.0) {
            return;
        }
    }
    if (pt_origNavBarSetAlpha) {
        pt_origNavBarSetAlpha(self, _cmd, alpha);
    }
}

static void (*pt_origToolbarSetHidden)(UIToolbar *, SEL, BOOL) = NULL;
static void pt_toolbarSetHidden(UIToolbar *self, SEL _cmd, BOOL hidden) {
    if (pt_duoInternalToolbarVisualDepth == 0 && [objc_getAssociatedObject(self, kPTDuoToolbarSuppressedKey) boolValue]) {
        objc_setAssociatedObject(self, kPTDuoToolbarAppHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (self.window) {
            pt_scheduleRefreshForWindow(self.window);
        }
        if (!hidden) {
            return;
        }
    }
    if (pt_origToolbarSetHidden) {
        pt_origToolbarSetHidden(self, _cmd, hidden);
    }
}

static void (*pt_origToolbarSetAlpha)(UIToolbar *, SEL, CGFloat) = NULL;
static void pt_toolbarSetAlpha(UIToolbar *self, SEL _cmd, CGFloat alpha) {
    if (pt_duoInternalToolbarVisualDepth == 0 && [objc_getAssociatedObject(self, kPTDuoToolbarSuppressedKey) boolValue]) {
        objc_setAssociatedObject(self, kPTDuoToolbarAppAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (alpha > 0.0) {
            return;
        }
    }
    if (pt_origToolbarSetAlpha) {
        pt_origToolbarSetAlpha(self, _cmd, alpha);
    }
}

static void (*pt_origBarItemSetHidden)(UIBarButtonItem *, SEL, BOOL) = NULL;
static void pt_barItemSetHidden(UIBarButtonItem *self, SEL _cmd, BOOL hidden) {
    if (pt_duoInternalBarItemHiddenDepth == 0 && [objc_getAssociatedObject(self, kPTDuoBarItemSuppressedKey) boolValue]) {
        objc_setAssociatedObject(self, kPTDuoBarItemAppHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIWindow *win = pt_findActivePrimaryWindow();
        if (win) {
            pt_scheduleRefreshForWindow(win);
        }
        if (!hidden) {
            return;
        }
    }
    if (pt_origBarItemSetHidden) {
        pt_origBarItemSetHidden(self, _cmd, hidden);
    }
}

static void (*pt_origNavItemSetHidesBack)(UINavigationItem *, SEL, BOOL) = NULL;
static void pt_navItemSetHidesBack(UINavigationItem *self, SEL _cmd, BOOL hides) {
    if (pt_duoInternalNavItemBackDepth == 0 && [objc_getAssociatedObject(self, kPTDuoNavItemSuppressedBackKey) boolValue]) {
        objc_setAssociatedObject(self, kPTDuoNavItemAppHidesBackKey, @(hides), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIWindow *win = pt_findActivePrimaryWindow();
        if (win) {
            pt_scheduleRefreshForWindow(win);
        }
        if (!hides) {
            return;
        }
    }
    if (pt_origNavItemSetHidesBack) {
        pt_origNavItemSetHidesBack(self, _cmd, hides);
    }
}

static void (*pt_origNavItemSetHidesBackAnimated)(UINavigationItem *, SEL, BOOL, BOOL) = NULL;
static void pt_navItemSetHidesBackAnimated(UINavigationItem *self, SEL _cmd, BOOL hides, BOOL animated) {
    if (pt_duoInternalNavItemBackDepth == 0 && [objc_getAssociatedObject(self, kPTDuoNavItemSuppressedBackKey) boolValue]) {
        objc_setAssociatedObject(self, kPTDuoNavItemAppHidesBackKey, @(hides), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIWindow *win = pt_findActivePrimaryWindow();
        if (win) {
            pt_scheduleRefreshForWindow(win);
        }
        if (!hides) {
            return;
        }
    }
    if (pt_origNavItemSetHidesBackAnimated) {
        pt_origNavItemSetHidesBackAnimated(self, _cmd, hides, animated);
    }
}

static BOOL pt_isNavBarFullySuppressed(UINavigationController *nav) {
    return nav != nil
        && (PTDuoNavBarSuppressionMode)[objc_getAssociatedObject(nav, kPTDuoNavControllerSuppressionKey) integerValue] == PTDuoNavBarSuppressionFull;
}

static BOOL pt_isToolbarFullySuppressed(UINavigationController *nav) {
    return nav != nil
        && (PTDuoNavBarSuppressionMode)[objc_getAssociatedObject(nav, kPTDuoToolbarControllerSuppressionKey) integerValue] == PTDuoNavBarSuppressionFull;
}

static BOOL (*pt_origNavShouldInsetVC)(UINavigationController *, SEL, UIViewController *) = NULL;
static BOOL pt_navShouldInsetVC(UINavigationController *self, SEL _cmd, UIViewController *vc) {
    if (pt_isNavBarFullySuppressed(self)) {
        return NO;
    }
    return pt_origNavShouldInsetVC ? pt_origNavShouldInsetVC(self, _cmd, vc) : YES;
}

static BOOL (*pt_origNavShouldInsetVCOrOverlay)(UINavigationController *, SEL, UIViewController *, BOOL *) = NULL;
static BOOL pt_navShouldInsetVCOrOverlay(UINavigationController *self, SEL _cmd, UIViewController *vc, BOOL *overlay) {
    if (pt_isNavBarFullySuppressed(self)) {
        if (overlay) {
            *overlay = NO;
        }
        return NO;
    }
    return pt_origNavShouldInsetVCOrOverlay ? pt_origNavShouldInsetVCOrOverlay(self, _cmd, vc, overlay) : YES;
}

static BOOL (*pt_origToolbarShouldInsetVC)(UINavigationController *, SEL, UIToolbar *, UIViewController *) = NULL;
static BOOL pt_toolbarShouldInsetVC(UINavigationController *self, SEL _cmd, UIToolbar *tb, UIViewController *vc) {
    if (pt_isToolbarFullySuppressed(self)) {
        return NO;
    }
    return pt_origToolbarShouldInsetVC ? pt_origToolbarShouldInsetVC(self, _cmd, tb, vc) : YES;
}

static BOOL (*pt_origToolbarShouldInsetVCOrOverlay)(UINavigationController *, SEL, UIToolbar *, UIViewController *, BOOL *) = NULL;
static BOOL pt_toolbarShouldInsetVCOrOverlay(UINavigationController *self, SEL _cmd, UIToolbar *tb, UIViewController *vc, BOOL *overlay) {
    if (pt_isToolbarFullySuppressed(self)) {
        if (overlay) {
            *overlay = NO;
        }
        return NO;
    }
    return pt_origToolbarShouldInsetVCOrOverlay ? pt_origToolbarShouldInsetVCOrOverlay(self, _cmd, tb, vc, overlay) : YES;
}

static UIEdgeInsets (*pt_origNavEdgeInsetsForChild)(UINavigationController *, SEL, UIViewController *, BOOL *) = NULL;
static UIEdgeInsets pt_navEdgeInsetsForChild(UINavigationController *self, SEL _cmd, UIViewController *vc, BOOL *insetsAreAbsolute) {
    UIEdgeInsets insets = pt_origNavEdgeInsetsForChild
        ? pt_origNavEdgeInsetsForChild(self, _cmd, vc, insetsAreAbsolute)
        : UIEdgeInsetsZero;
    BOOL isAbs = (insetsAreAbsolute != NULL) ? *insetsAreAbsolute : NO;
    if (pt_isNavBarFullySuppressed(self)) {
        CGFloat winTop = self.viewIfLoaded.window ? self.viewIfLoaded.window.safeAreaInsets.top : 0.0;
        insets.top = PTDuoAdjustedSuppressedNavBarTopInset(insets.top, isAbs, winTop);
    }
    if (pt_isToolbarFullySuppressed(self)) {
        CGFloat winBottom = self.viewIfLoaded.window ? self.viewIfLoaded.window.safeAreaInsets.bottom : 0.0;
        insets.bottom = PTDuoAdjustedSuppressedNavBarTopInset(insets.bottom, isAbs, winBottom);
    }
    return insets;
}

static void (*pt_origNavSetNavBarHiddenAnimated)(UINavigationController *, SEL, BOOL, BOOL) = NULL;
static void pt_navSetNavBarHiddenAnimated(UINavigationController *self, SEL _cmd, BOOL hidden, BOOL animated) {
    if (pt_origNavSetNavBarHiddenAnimated) {
        pt_origNavSetNavBarHiddenAnimated(self, _cmd, hidden, animated);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win) {
        pt_scheduleRefreshForWindow(win);
    }
}

static void (*pt_origNavSetToolbarHiddenAnimated)(UINavigationController *, SEL, BOOL, BOOL) = NULL;
static void pt_navSetToolbarHiddenAnimated(UINavigationController *self, SEL _cmd, BOOL hidden, BOOL animated) {
    if (pt_origNavSetToolbarHiddenAnimated) {
        pt_origNavSetToolbarHiddenAnimated(self, _cmd, hidden, animated);
    }
    UIWindow *win = self.viewIfLoaded.window ?: pt_findActivePrimaryWindow();
    if (win) {
        pt_scheduleRefreshForWindow(win);
    }
}

// MARK: - Swizzle Helper & Installer

static void pt_replaceInstanceMethod(Class cls, SEL sel, IMP replacement, IMP *outOriginal) {
    if (!cls || !sel || !replacement) {
        return;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        return;
    }
    IMP orig = method_getImplementation(m);
    if (orig == replacement) {
        return;
    }
    if (outOriginal) {
        *outOriginal = orig;
    }
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(m));
}

static void pt_replaceClassMethod(Class cls, SEL sel, IMP replacement, IMP *outOriginal) {
    if (!cls || !sel || !replacement) {
        return;
    }
    Class meta = object_getClass(cls);
    Method m = class_getClassMethod(cls, sel);
    if (!meta || !m) {
        return;
    }
    IMP orig = method_getImplementation(m);
    if (orig == replacement) {
        return;
    }
    if (outOriginal) {
        *outOriginal = orig;
    }
    class_replaceMethod(meta, sel, replacement, method_getTypeEncoding(m));
}

__attribute__((visibility("hidden")))
void pt_installDuoVerticalBarCompatibility(void) {
    if (pt_duoVerticalBarInstalled) {
        return;
    }
    // Strict per-app opt-in: zero hooks installed when duoVerticalBar is OFF or layoutIdiom != 3.
    if (!PTShouldEnableDuoVerticalBar()) {
        return;
    }
    pt_duoVerticalBarInstalled = YES;

    Class uiWindow = objc_getClass("UIWindow");
    Class uiWindowScene = objc_getClass("UIWindowScene");
    Class uiView = objc_getClass("UIView");
    Class uiVC = objc_getClass("UIViewController");
    Class uiTabBar = objc_getClass("UITabBar");
    Class uiTabBarController = objc_getClass("UITabBarController");
    Class uiNavController = objc_getClass("UINavigationController");
    Class uiNavBar = objc_getClass("UINavigationBar");
    Class uiToolbar = objc_getClass("UIToolbar");
    Class uiBarButtonItem = objc_getClass("UIBarButtonItem");
    Class uiNavItem = objc_getClass("UINavigationItem");
    Class uiLayoutRegion = objc_getClass("UIViewLayoutRegion");

    // 1. Trailing safe area hooks
    pt_replaceInstanceMethod(uiWindow,
                             sel_registerName("_sceneSafeAreaInsetsIncludingStatusBar:"),
                             (IMP)pt_windowSceneSafeArea,
                             (IMP *)&pt_origWindowSceneSafeArea);
    pt_replaceInstanceMethod(uiWindowScene,
                             sel_registerName("_safeAreaInsetsForInterfaceOrientation:statusBarHidden:"),
                             (IMP)pt_sceneSafeAreaForOrientation,
                             (IMP *)&pt_origSceneSafeAreaForOrientation);

    // 2. UIViewLayoutRegion factory/init & UIView layout region backing
    if (uiLayoutRegion) {
        pt_replaceClassMethod(uiLayoutRegion,
                              sel_registerName("layoutRegionForBarOnEdge:extent:"),
                              (IMP)pt_regionBarEdgeExtent,
                              (IMP *)&pt_origRegionBarEdgeExtent);
        pt_replaceClassMethod(uiLayoutRegion,
                              sel_registerName("layoutRegionForBarOnDirectionalEdge:extent:"),
                              (IMP)pt_regionBarDirEdgeExtent,
                              (IMP *)&pt_origRegionBarDirEdgeExtent);
        pt_replaceClassMethod(uiLayoutRegion,
                              sel_registerName("layoutRegionForBarOnEdge:"),
                              (IMP)pt_regionBarEdgeDefault,
                              (IMP *)&pt_origRegionBarEdgeDefault);
        pt_replaceClassMethod(uiLayoutRegion,
                              sel_registerName("layoutRegionForBarOnDirectionalEdge:"),
                              (IMP)pt_regionBarDirEdgeDefault,
                              (IMP *)&pt_origRegionBarDirEdgeDefault);
        pt_replaceInstanceMethod(uiLayoutRegion,
                                 sel_registerName("initWithBarOnEdge:extent:"),
                                 (IMP)pt_initBarEdgeExtent,
                                 (IMP *)&pt_origInitBarEdgeExtent);
        pt_replaceInstanceMethod(uiLayoutRegion,
                                 sel_registerName("initWithBarOnDirectionalEdge:extent:"),
                                 (IMP)pt_initBarDirEdgeExtent,
                                 (IMP *)&pt_origInitBarDirEdgeExtent);
        pt_replaceInstanceMethod(uiLayoutRegion,
                                 sel_registerName("initWithBarOnEdge:"),
                                 (IMP)pt_initBarEdgeDefault,
                                 (IMP *)&pt_origInitBarEdgeDefault);
        pt_replaceInstanceMethod(uiLayoutRegion,
                                 sel_registerName("initWithBarOnDirectionalEdge:"),
                                 (IMP)pt_initBarDirEdgeDefault,
                                 (IMP *)&pt_origInitBarDirEdgeDefault);
    }

    pt_replaceInstanceMethod(uiView,
                             sel_registerName("layoutGuideForLayoutRegion:"),
                             (IMP)pt_layoutGuideForLayoutRegion,
                             (IMP *)&pt_origLayoutGuideForLayoutRegion);
    pt_replaceInstanceMethod(uiView,
                             sel_registerName("edgeInsetsForLayoutRegion:"),
                             (IMP)pt_edgeInsetsForLayoutRegion,
                             (IMP *)&pt_origEdgeInsetsForLayoutRegion);
    pt_replaceInstanceMethod(uiView,
                             sel_registerName("directionalEdgeInsetsForLayoutRegion:"),
                             (IMP)pt_directionalEdgeInsetsForLayoutRegion,
                             (IMP *)&pt_origDirectionalEdgeInsetsForLayoutRegion);

    // 3. Window/VC lifecycle & vertical bar configuration update hooks
    pt_replaceInstanceMethod(uiWindow,
                             @selector(makeKeyAndVisible),
                             (IMP)pt_windowMakeKeyAndVisible,
                             (IMP *)&pt_origWindowMakeKeyAndVisible);
    pt_replaceInstanceMethod(uiWindow,
                             @selector(setRootViewController:),
                             (IMP)pt_windowSetRootVC,
                             (IMP *)&pt_origWindowSetRootVC);
    pt_replaceInstanceMethod(uiWindow,
                             @selector(layoutSubviews),
                             (IMP)pt_windowLayoutSubviews,
                             (IMP *)&pt_origWindowLayoutSubviews);
    pt_replaceInstanceMethod(uiVC,
                             sel_registerName("setNeedsUpdateOfVerticalBarConfiguration"),
                             (IMP)pt_vcSetNeedsUpdateVerticalBar,
                             (IMP *)&pt_origVCSetNeedsUpdateVerticalBar);
    pt_replaceInstanceMethod(uiVC,
                             @selector(viewDidAppear:),
                             (IMP)pt_vcViewDidAppear,
                             (IMP *)&pt_origVCViewDidAppear);
    pt_replaceInstanceMethod(uiTabBarController,
                             @selector(setSelectedIndex:),
                             (IMP)pt_tabBarControllerSetSelectedIndex,
                             (IMP *)&pt_origTabBarControllerSetSelectedIndex);
    pt_replaceInstanceMethod(uiTabBar,
                             @selector(setHidden:),
                             (IMP)pt_tabBarSetHidden,
                             (IMP *)&pt_origTabBarSetHidden);
    pt_replaceInstanceMethod(uiNavItem,
                             @selector(setRightBarButtonItems:animated:),
                             (IMP)pt_navItemSetRightItems,
                             (IMP *)&pt_origNavItemSetRightItems);
    pt_replaceInstanceMethod(uiNavItem,
                             sel_registerName("setTrailingItemGroups:"),
                             (IMP)pt_navItemSetTrailingGroups,
                             (IMP *)&pt_origNavItemSetTrailingGroups);
    pt_replaceInstanceMethod(uiVC,
                             @selector(setToolbarItems:animated:),
                             (IMP)pt_vcSetToolbarItems,
                             (IMP *)&pt_origVCSetToolbarItems);

    // 4. Horizontal UINavigationBar / UIToolbar deduplication & redundant safe-area push removal
    pt_replaceInstanceMethod(uiNavBar,
                             @selector(setHidden:),
                             (IMP)pt_navBarSetHidden,
                             (IMP *)&pt_origNavBarSetHidden);
    pt_replaceInstanceMethod(uiNavBar,
                             @selector(setAlpha:),
                             (IMP)pt_navBarSetAlpha,
                             (IMP *)&pt_origNavBarSetAlpha);
    pt_replaceInstanceMethod(uiToolbar,
                             @selector(setHidden:),
                             (IMP)pt_toolbarSetHidden,
                             (IMP *)&pt_origToolbarSetHidden);
    pt_replaceInstanceMethod(uiToolbar,
                             @selector(setAlpha:),
                             (IMP)pt_toolbarSetAlpha,
                             (IMP *)&pt_origToolbarSetAlpha);
    pt_replaceInstanceMethod(uiBarButtonItem,
                             sel_registerName("setHidden:"),
                             (IMP)pt_barItemSetHidden,
                             (IMP *)&pt_origBarItemSetHidden);
    pt_replaceInstanceMethod(uiNavItem,
                             @selector(setHidesBackButton:),
                             (IMP)pt_navItemSetHidesBack,
                             (IMP *)&pt_origNavItemSetHidesBack);
    pt_replaceInstanceMethod(uiNavItem,
                             @selector(setHidesBackButton:animated:),
                             (IMP)pt_navItemSetHidesBackAnimated,
                             (IMP *)&pt_origNavItemSetHidesBackAnimated);
    pt_replaceInstanceMethod(uiNavController,
                             sel_registerName("_shouldNavigationBarInsetViewController:"),
                             (IMP)pt_navShouldInsetVC,
                             (IMP *)&pt_origNavShouldInsetVC);
    pt_replaceInstanceMethod(uiNavController,
                             sel_registerName("_shouldNavigationBarInsetViewController:orOverlayContent:"),
                             (IMP)pt_navShouldInsetVCOrOverlay,
                             (IMP *)&pt_origNavShouldInsetVCOrOverlay);
    pt_replaceInstanceMethod(uiNavController,
                             sel_registerName("_shouldToolBar:insetViewController:"),
                             (IMP)pt_toolbarShouldInsetVC,
                             (IMP *)&pt_origToolbarShouldInsetVC);
    pt_replaceInstanceMethod(uiNavController,
                             sel_registerName("_shouldToolBar:insetViewController:orOverlayContent:"),
                             (IMP)pt_toolbarShouldInsetVCOrOverlay,
                             (IMP *)&pt_origToolbarShouldInsetVCOrOverlay);
    pt_replaceInstanceMethod(uiNavController,
                             sel_registerName("_edgeInsetsForChildViewController:insetsAreAbsolute:"),
                             (IMP)pt_navEdgeInsetsForChild,
                             (IMP *)&pt_origNavEdgeInsetsForChild);
    pt_replaceInstanceMethod(uiNavController,
                             @selector(setNavigationBarHidden:animated:),
                             (IMP)pt_navSetNavBarHiddenAnimated,
                             (IMP *)&pt_origNavSetNavBarHiddenAnimated);
    pt_replaceInstanceMethod(uiNavController,
                             @selector(setToolbarHidden:animated:),
                             (IMP)pt_navSetToolbarHiddenAnimated,
                             (IMP *)&pt_origNavSetToolbarHiddenAnimated);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        UIWindow *w = [note.object isKindOfClass:[UIWindow class]] ? (UIWindow *)note.object : nil;
        if (w) {
            pt_scheduleRefreshForWindow(w);
        }
    }];
}

#endif
