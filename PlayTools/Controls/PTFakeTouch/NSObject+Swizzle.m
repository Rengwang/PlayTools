//
//  NSObject+PrivateSwizzle.m
//  PlayTools
//
//  Created by siri on 06.10.2021.
//

#import "NSObject+Swizzle.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <os/lock.h>
#import "CoreGraphics/CoreGraphics.h"
#import "UIKit/UIKit.h"
#import <PlayTools/PlayTools-Swift.h>
#import "PTFakeMetaTouch.h"
#import <VideoSubscriberAccount/VideoSubscriberAccount.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <GameController/GameController.h>

__attribute__((visibility("hidden")))
@interface PTSwizzleLoader : NSObject
@end

void pt_swizzleInstanceMethod(Class _Nullable cls, SEL origSelector, SEL newSelector) {
    if (!cls) {
        return;
    }
    // If current class doesn't exist selector, then get super
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, newSelector);
    if (!originalMethod || !swizzledMethod) {
        return;
    }

    // Add selector if it doesn't exist, implement append with method
    if (class_addMethod(cls,
                        origSelector,
                        method_getImplementation(swizzledMethod),
                        method_getTypeEncoding(swizzledMethod))) {
        // Replace class instance method, added if selector not exist
        // For class cluster, it always adds new selector here
        class_replaceMethod(cls,
                            newSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        // SwizzleMethod maybe belongs to super
        class_replaceMethod(cls,
                            newSelector,
                            class_replaceMethod(cls,
                                                origSelector,
                                                method_getImplementation(swizzledMethod),
                                                method_getTypeEncoding(swizzledMethod)),
                            method_getTypeEncoding(originalMethod));
    }
}

void pt_swizzleExchangeInstanceMethod(Class _Nullable cls, SEL origSelector, SEL newSelector) {
    if (!cls) {
        return;
    }
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, newSelector);
    if (!originalMethod || !swizzledMethod) {
        return;
    }

    method_exchangeImplementations(originalMethod, swizzledMethod);
}

void pt_swizzleClassMethod(Class _Nullable cls, SEL origSelector, SEL newSelector) {
    if (!cls) {
        return;
    }
    Class meta = object_getClass((id)cls);
    if (!meta) {
        return;
    }
    Method originalMethod = class_getClassMethod(cls, origSelector);
    Method swizzledMethod = class_getClassMethod(cls, newSelector);
    if (!originalMethod || !swizzledMethod) {
        return;
    }

    if (class_addMethod(meta,
                        origSelector,
                        method_getImplementation(swizzledMethod),
                        method_getTypeEncoding(swizzledMethod))) {
        class_replaceMethod(meta,
                            newSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        class_replaceMethod(meta,
                            newSelector,
                            class_replaceMethod(meta,
                                                origSelector,
                                                method_getImplementation(swizzledMethod),
                                                method_getTypeEncoding(swizzledMethod)),
                            method_getTypeEncoding(originalMethod));
    }
}

@implementation NSObject (Swizzle)

- (void) swizzleInstanceMethod:(SEL)origSelector withMethod:(SEL)newSelector
{
    pt_swizzleInstanceMethod([self class], origSelector, newSelector);
}

- (void) swizzleExchangeMethod:(SEL)origSelector withMethod:(SEL)newSelector
{
    pt_swizzleExchangeInstanceMethod([self class], origSelector, newSelector);
}

+ (void) swizzleClassMethod:(SEL)origSelector withMethod:(SEL)newSelector {
    pt_swizzleClassMethod(self, origSelector, newSelector);
}

- (BOOL) hook_prefersPointerLocked {
    return false;
}

- (CGRect) hook_frameDefault {
    return [PlayScreen frameDefault:[self hook_frameDefault]];
}

- (CGRect) hook_boundsDefault {
    return [PlayScreen boundsDefault:[self hook_boundsDefault]];
}

- (CGRect) hook_nativeBoundsDefault {
    return [PlayScreen nativeBoundsDefault:[self hook_nativeBoundsDefault]];
}

- (CGSize) hook_sizeDelfault {
    return [PlayScreen sizeAspectRatioDefault:[self hook_sizeDelfault]];
}


- (CGRect) hook_frame {
    return [PlayScreen frame:[self hook_frame]];
}

- (CGRect) hook_bounds {
    return [PlayScreen bounds:[self hook_bounds]];
}

- (CGRect) hook_nativeBounds {
    return [PlayScreen nativeBounds:[self hook_nativeBounds]];
}

- (CGSize) hook_size {
    return [PlayScreen sizeAspectRatio:[self hook_size]];
}



- (long long) hook_orientation {
    return 0;
}

static double pt_cachedCustomScaler(void) {
    static double cached = 2.0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cached = [[PlaySettings shared] customScaler];
    });
    return cached;
}

- (double) hook_nativeScale {
    return pt_cachedCustomScaler();
}

- (double) hook_scale {
    // Return rounded value of [[PlaySettings shared] customScaler]
    // Even though it is a double return, this will only accept .0 value or apps will crash
    return round(pt_cachedCustomScaler());
}

- (double) get_default_height {
    return [[UIScreen mainScreen] bounds].size.height;
    
}
- (double) get_default_width {
    return [[UIScreen mainScreen] bounds].size.width;
    
}

- (CGRect) hook_boundsResizable {
    return [PlayScreen boundsResizable:[self hook_boundsResizable]];
}

- (CGRect) hook_nativeBoundsResizable {
    return [PlayScreen nativeBoundsResizable:[self hook_nativeBoundsResizable]];
}

- (void) hook_uiwindow_layoutSubviews {
    [self hook_uiwindow_layoutSubviews];
    if ([self isKindOfClass:[UIWindow class]]) {
        [PlayScreen onWindowLayoutSubviews:(UIWindow *)self];
    }
}

- (void) hook_uiwindow_setFrame:(CGRect)frame {
    if ([self isKindOfClass:[UIWindow class]]
        && [PlayScreen interceptWindowSetFrame:(UIWindow *)self frame:frame]) {
        return;
    }
    [self hook_uiwindow_setFrame:frame];
}

- (void) hook_uiwindow_setBounds:(CGRect)bounds {
    if ([self isKindOfClass:[UIWindow class]]
        && [PlayScreen interceptWindowSetBounds:(UIWindow *)self bounds:bounds]) {
        return;
    }
    [self hook_uiwindow_setBounds:bounds];
}

- (void) hook_uiwindow_setRootViewController:(UIViewController *)rootViewController {
    if ([self isKindOfClass:[UIWindow class]]) {
        [PlayScreen onWindowWillSetRootViewController:(UIWindow *)self];
    }
    [self hook_uiwindow_setRootViewController:rootViewController];
}

- (void) hook_uiwindow_didAddSubview:(UIView *)subview {
    [self hook_uiwindow_didAddSubview:subview];
    if ([self isKindOfClass:[UIWindow class]] && subview) {
        [PlayScreen onWindow:(UIWindow *)self didAddSubview:subview];
    }
}

static void pt_fitWindowModal(UIView *backdrop) {
    UIView *container = backdrop.superview;
    UIView *content = backdrop.subviews.firstObject;
    CGRect bounds = container.bounds;
    CGFloat red = 1;
    CGFloat green = 1;
    CGFloat blue = 1;
    CGFloat alpha = 0;
    if (object_getClass(backdrop) != UIView.class || !content || !backdrop.window
        || backdrop.subviews.count != 1 || !CGAffineTransformIsIdentity(backdrop.transform)
        || ![backdrop.backgroundColor getRed:&red green:&green blue:&blue alpha:&alpha]
        || fmax(red, fmax(green, blue)) > 0.05 || alpha <= 0 || alpha >= 1
        || CGRectIsEmpty(bounds) || CGRectIsEmpty(content.bounds)
        || CGRectGetWidth(backdrop.frame) <= CGRectGetWidth(bounds) + 2
        || CGRectGetHeight(backdrop.frame) <= CGRectGetHeight(bounds) + 2
        || CGRectGetWidth(content.bounds) > CGRectGetWidth(bounds)
        || CGRectGetHeight(content.bounds) > CGRectGetHeight(bounds)
        || !CGPointEqualToPoint(backdrop.frame.origin, bounds.origin)
        || fabs(content.center.x - CGRectGetMidX(backdrop.bounds)) > 2
        || fabs(content.center.y - CGRectGetMidY(backdrop.bounds)) > 2) {
        return;
    }
    backdrop.frame = bounds;
    backdrop.autoresizingMask |= UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    content.center = CGPointMake(CGRectGetMidX(backdrop.bounds), CGRectGetMidY(backdrop.bounds));
    content.autoresizingMask |= UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                              | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
}

- (void) hook_uiview_didMoveToWindow {
    [self hook_uiview_didMoveToWindow];
    UIView *view = (UIView *)self;
    UIView *candidate = view.superview;
    if (object_getClass(candidate) == UIView.class && view.window && candidate.subviews.count == 1
        && CGRectGetWidth(candidate.bounds) > CGRectGetWidth(candidate.superview.bounds) + 2
        && CGRectGetHeight(candidate.bounds) > CGRectGetHeight(candidate.superview.bounds) + 2) {
        __weak UIView *backdrop = candidate;
        dispatch_async(dispatch_get_main_queue(), ^{
            pt_fitWindowModal(backdrop);
        });
    }
}

- (UIInterfaceOrientation) hook_uiscene_interfaceOrientation {
    UIInterfaceOrientation orig = [self hook_uiscene_interfaceOrientation];
    if ([self isKindOfClass:[UIWindowScene class]]) {
        return [PlayScreen resolvedInterfaceOrientation:orig scene:(UIWindowScene *)self];
    }
    return orig;
}

- (UIInterfaceOrientation) hook_uiapp_statusBarOrientation {
    UIInterfaceOrientation orig = [self hook_uiapp_statusBarOrientation];
    return [PlayScreen resolvedInterfaceOrientation:orig scene:nil];
}

- (UIInterfaceOrientation) hook_uiscenegeometry_interfaceOrientation {
    UIInterfaceOrientation orig = [self hook_uiscenegeometry_interfaceOrientation];
    CGRect geomBounds = CGRectZero;
    SEL coordSel = NSSelectorFromString(@"coordinateSpace");
    if ([self respondsToSelector:coordSel]) {
        id space = ((id (*)(id, SEL))objc_msgSend)(self, coordSel);
        if (space && [space conformsToProtocol:@protocol(UICoordinateSpace)]) {
            geomBounds = [(id<UICoordinateSpace>)space bounds];
        }
    }
    return [PlayScreen resolvedGeometryInterfaceOrientation:orig coordinateSpaceBounds:geomBounds];
}

- (CGRect) hook_uiscreenfixedspace_bounds {
    CGRect orig = [self hook_uiscreenfixedspace_bounds];
    UIScreen *screen = nil;
    SEL screenSel = NSSelectorFromString(@"_screen");
    if ([self respondsToSelector:screenSel]) {
        id candidate = ((id (*)(id, SEL))objc_msgSend)(self, screenSel);
        if ([candidate isKindOfClass:[UIScreen class]]) {
            screen = (UIScreen *)candidate;
        }
    }
    return [PlayScreen resolvedFixedCoordinateSpaceBounds:orig screen:screen];
}

- (id) hook_nsbundle_objectForInfoDictionaryKey:(NSString *)key {
    id orig = [self hook_nsbundle_objectForInfoDictionaryKey:key];
    if (key && [self isEqual:[NSBundle mainBundle]]) {
        return [PlayScreen resolvedMainBundleInfoValue:orig forKey:key];
    }
    return orig;
}

- (NSDictionary<NSString *, id> *) hook_nsbundle_infoDictionary {
    NSDictionary<NSString *, id> *orig = [self hook_nsbundle_infoDictionary];
    if ([self isEqual:[NSBundle mainBundle]]) {
        return [PlayScreen resolvedMainBundleInfoDictionary:orig];
    }
    return orig;
}

- (void) hook_vc_viewWillLayoutSubviews {
    [self hook_vc_viewWillLayoutSubviews];
    if ([self isKindOfClass:[UIViewController class]]) {
        [PlayScreen onViewControllerLayout:(UIViewController *)self];
    }
}

- (void) hook_vc_viewDidAppear:(BOOL)animated {
    [self hook_vc_viewDidAppear:animated];
    if ([self isKindOfClass:[UIViewController class]]) {
        [PlayScreen onViewControllerLayout:(UIViewController *)self];
    }
}

typedef CGSize (*PTLayoutContentSizeIMP)(id, SEL);
typedef void (*PTLayoutPrepareIMP)(id, SEL);

static os_unfair_lock sCustomLayoutHookLock = OS_UNFAIR_LOCK_INIT;
static Method sBaseLayoutPrepareMethod = NULL;
static Method sBaseLayoutContentSizeMethod = NULL;

// Fast main-thread class cache so UICollectionView.layoutSubviews does 0 locks
// and 0 NSValue allocations on already-checked layout classes.
#define PT_MAIN_LAYOUT_CACHE_CAPACITY 16
static Class sMainLayoutCacheClasses[PT_MAIN_LAYOUT_CACHE_CAPACITY];
static BOOL sMainLayoutCacheHooked[PT_MAIN_LAYOUT_CACHE_CAPACITY];
static NSUInteger sMainLayoutCacheCount = 0;

static CFMutableSetRef PTCheckedLayoutClasses(void) {
    static CFMutableSetRef set = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
    });
    return set;
}

static CFMutableSetRef PTHookedCustomLayoutClasses(void) {
    static CFMutableSetRef set = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
    });
    return set;
}

static CFMutableSetRef PTHookedLayoutMethods(void) {
    static CFMutableSetRef set = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
    });
    return set;
}

static NSHashTable *PTPreparedLayouts(void) {
    static NSHashTable *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static NSHashTable *PTCurrentlyPreparingLayouts(void) {
    static NSHashTable *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static NSMapTable<UICollectionViewLayout *, NSValue *> *PTPrimedLayoutBounds(void) {
    static NSMapTable<UICollectionViewLayout *, NSValue *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = [NSMapTable weakToStrongObjectsMapTable];
    });
    return map;
}

static NSMapTable<UICollectionViewLayout *, NSValue *> *PTLayoutSubviewsInvalidatedBounds(void) {
    static NSMapTable<UICollectionViewLayout *, NSValue *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = [NSMapTable weakToStrongObjectsMapTable];
    });
    return map;
}

static CFMutableSetRef PTActiveLazyLayoutCalculations(void) {
    static CFMutableSetRef active = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        active = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
    });
    return active;
}

static BOOL PTCollectionViewHasAnyItems(UICollectionView *cv) {
    NSInteger sections = [cv numberOfSections];
    for (NSInteger s = 0; s < sections; s++) {
        if ([cv numberOfItemsInSection:s] > 0) {
            return YES;
        }
    }
    return NO;
}

static BOOL PTShouldPrimeLayoutAtSize(UICollectionViewLayout *layout, CGSize size) {
    NSValue *primedVal = [PTPrimedLayoutBounds() objectForKey:layout];
    if (!primedVal) {
        return YES;
    }
    CGSize prev = [primedVal CGSizeValue];
    return (fabs(prev.width - size.width) > 0.5 || fabs(prev.height - size.height) > 0.5);
}

static BOOL PTShouldInvalidateInLayoutSubviews(UICollectionViewLayout *layout, CGSize size) {
    NSValue *prevVal = [PTLayoutSubviewsInvalidatedBounds() objectForKey:layout];
    if (!prevVal) {
        return YES;
    }
    CGSize prev = [prevVal CGSizeValue];
    return (fabs(prev.width - size.width) > 0.5 || fabs(prev.height - size.height) > 0.5);
}

static BOOL PTIsSystemOrPlayToolsIMP(IMP imp) {
    if (!imp) {
        return YES;
    }
    Dl_info info;
    if (dladdr((const void *)imp, &info) == 0 || !info.dli_fname) {
        return YES;
    }
    static const void *sSelfBase = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Dl_info selfInfo;
        if (dladdr((const void *)&PTIsSystemOrPlayToolsIMP, &selfInfo) != 0) {
            sSelfBase = selfInfo.dli_fbase;
        }
    });
    if (sSelfBase && info.dli_fbase == sSelfBase) {
        return YES;
    }
    NSString *fname = [NSString stringWithUTF8String:info.dli_fname];
    if ([fname hasPrefix:@"/System/"] ||
        [fname hasPrefix:@"/usr/lib/"] ||
        [fname hasPrefix:@"/Library/Apple/"]) {
        return YES;
    }
    return NO;
}

static inline void PTCacheMainLayoutClassResult(Class cls, BOOL isHooked) {
    if (![NSThread isMainThread] || !cls) {
        return;
    }
    for (NSUInteger i = 0; i < sMainLayoutCacheCount; i++) {
        if (sMainLayoutCacheClasses[i] == cls) {
            sMainLayoutCacheHooked[i] = isHooked;
            return;
        }
    }
    if (sMainLayoutCacheCount < PT_MAIN_LAYOUT_CACHE_CAPACITY) {
        sMainLayoutCacheClasses[sMainLayoutCacheCount] = cls;
        sMainLayoutCacheHooked[sMainLayoutCacheCount] = isHooked;
        sMainLayoutCacheCount++;
    }
}

static BOOL PTEnsureCustomCollectionViewLayoutHooked(UICollectionViewLayout *layout) {
    if (!layout) {
        return NO;
    }
    Class cls = [layout class];
    if (!cls) {
        return NO;
    }
    BOOL onMain = [NSThread isMainThread];
    if (onMain) {
        for (NSUInteger i = 0; i < sMainLayoutCacheCount; i++) {
            if (sMainLayoutCacheClasses[i] == cls) {
                return sMainLayoutCacheHooked[i];
            }
        }
    }
    if (![layout isKindOfClass:[UICollectionViewLayout class]]) {
        return NO;
    }

    const void *clsPtr = (__bridge const void *)cls;
    os_unfair_lock_lock(&sCustomLayoutHookLock);
    CFMutableSetRef checkedSet = PTCheckedLayoutClasses();
    CFMutableSetRef hookedClasses = PTHookedCustomLayoutClasses();
    if (CFSetContainsValue(checkedSet, clsPtr)) {
        BOOL hooked = CFSetContainsValue(hookedClasses, clsPtr) ? YES : NO;
        os_unfair_lock_unlock(&sCustomLayoutHookLock);
        if (onMain) {
            PTCacheMainLayoutClassResult(cls, hooked);
        }
        return hooked;
    }

    SEL csSel = @selector(collectionViewContentSize);
    Method csMethod = class_getInstanceMethod(cls, csSel);
    if (!csMethod || csMethod == sBaseLayoutContentSizeMethod) {
        CFSetAddValue(checkedSet, clsPtr);
        os_unfair_lock_unlock(&sCustomLayoutHookLock);
        if (onMain) {
            PTCacheMainLayoutClassResult(cls, NO);
        }
        return NO;
    }

    CFMutableSetRef hookedMethods = PTHookedLayoutMethods();
    const void *csMethodPtr = (const void *)csMethod;
    BOOL hasCustomCS = CFSetContainsValue(hookedMethods, csMethodPtr) ? YES : NO;
    if (!hasCustomCS) {
        IMP csImp = method_getImplementation(csMethod);
        if (PTIsSystemOrPlayToolsIMP(csImp)) {
            CFSetAddValue(checkedSet, clsPtr);
            os_unfair_lock_unlock(&sCustomLayoutHookLock);
            if (onMain) {
                PTCacheMainLayoutClassResult(cls, NO);
            }
            return NO;
        }
        PTLayoutContentSizeIMP origContentSize = (PTLayoutContentSizeIMP)csImp;
        IMP wrappedCS = imp_implementationWithBlock(^CGSize(UICollectionViewLayout *selfLayout) {
            CGSize cs = origContentSize(selfLayout, csSel);
            if (cs.width > 0.5 && cs.height > 0.5) {
                return cs;
            }
            if (![NSThread isMainThread] || !selfLayout) {
                return cs;
            }
            if (![PTPreparedLayouts() containsObject:selfLayout] ||
                [PTCurrentlyPreparingLayouts() containsObject:selfLayout]) {
                return cs;
            }
            const void *instancePtr = (__bridge const void *)selfLayout;
            CFMutableSetRef active = PTActiveLazyLayoutCalculations();
            if (CFSetContainsValue(active, instancePtr)) {
                return cs;
            }
            UICollectionView *cv = selfLayout.collectionView;
            if (!cv || cv.bounds.size.width <= 1.0 || cv.bounds.size.height <= 1.0) {
                return cs;
            }
            CGSize boundsSize = cv.bounds.size;
            if (!PTShouldPrimeLayoutAtSize(selfLayout, boundsSize)) {
                return cs;
            }
            if (!PTCollectionViewHasAnyItems(cv)) {
                return cs;
            }
            [PTPrimedLayoutBounds() setObject:[NSValue valueWithCGSize:boundsSize] forKey:selfLayout];
            CFSetAddValue(active, instancePtr);
            @try {
                CGRect queryRect = CGRectMake(cv.bounds.origin.x,
                                              cv.bounds.origin.y,
                                              MAX(boundsSize.width, 1.0),
                                              MAX(boundsSize.height, 1.0));
                [selfLayout layoutAttributesForElementsInRect:queryRect];
            } @finally {
                CFSetRemoveValue(active, instancePtr);
            }
            cs = origContentSize(selfLayout, csSel);
            return cs;
        });
        method_setImplementation(csMethod, wrappedCS);
        CFSetAddValue(hookedMethods, csMethodPtr);
        hasCustomCS = YES;
    }

    if (!hasCustomCS) {
        CFSetAddValue(checkedSet, clsPtr);
        os_unfair_lock_unlock(&sCustomLayoutHookLock);
        if (onMain) {
            PTCacheMainLayoutClassResult(cls, NO);
        }
        return NO;
    }

    SEL prepSel = @selector(prepareLayout);
    Method prepMethod = class_getInstanceMethod(cls, prepSel);
    if (prepMethod && prepMethod != sBaseLayoutPrepareMethod) {
        const void *prepMethodPtr = (const void *)prepMethod;
        if (!CFSetContainsValue(hookedMethods, prepMethodPtr)) {
            IMP prepImp = method_getImplementation(prepMethod);
            if (!PTIsSystemOrPlayToolsIMP(prepImp)) {
                PTLayoutPrepareIMP origPrepare = (PTLayoutPrepareIMP)prepImp;
                IMP wrappedPrep = imp_implementationWithBlock(^void(UICollectionViewLayout *selfLayout) {
                    BOOL prepOnMain = [NSThread isMainThread] && selfLayout != nil;
                    if (prepOnMain) {
                        [PTCurrentlyPreparingLayouts() addObject:selfLayout];
                    }
                    @try {
                        origPrepare(selfLayout, prepSel);
                    } @finally {
                        if (prepOnMain) {
                            [PTCurrentlyPreparingLayouts() removeObject:selfLayout];
                            [PTPreparedLayouts() addObject:selfLayout];
                        }
                    }
                });
                method_setImplementation(prepMethod, wrappedPrep);
                CFSetAddValue(hookedMethods, prepMethodPtr);
            }
        }
    }

    CFSetAddValue(hookedClasses, clsPtr);
    CFSetAddValue(checkedSet, clsPtr);
    os_unfair_lock_unlock(&sCustomLayoutHookLock);
    if (onMain) {
        PTCacheMainLayoutClassResult(cls, YES);
    }
    return YES;
}

- (void) hook_uicollectionviewlayout_prepareLayout {
    [self hook_uicollectionviewlayout_prepareLayout];
    if ([NSThread isMainThread] && [self isKindOfClass:[UICollectionViewLayout class]]) {
        [PTPreparedLayouts() addObject:self];
    }
}

- (void) hook_uicollectionviewlayout_invalidateLayoutWithContext:(UICollectionViewLayoutInvalidationContext *)context {
    if ([NSThread isMainThread] && [self isKindOfClass:[UICollectionViewLayout class]]) {
        UICollectionViewLayout *layout = (UICollectionViewLayout *)self;
        const void *instancePtr = (__bridge const void *)layout;
        [PTPreparedLayouts() removeObject:layout];
        if (!CFSetContainsValue(PTActiveLazyLayoutCalculations(), instancePtr) &&
            ![PTCurrentlyPreparingLayouts() containsObject:layout]) {
            [PTPrimedLayoutBounds() removeObjectForKey:layout];
        }
    }
    [self hook_uicollectionviewlayout_invalidateLayoutWithContext:context];
}

- (instancetype) hook_uicollectionview_initWithFrame:(CGRect)frame
                                collectionViewLayout:(UICollectionViewLayout *)layout {
    PTEnsureCustomCollectionViewLayoutHooked(layout);
    return [self hook_uicollectionview_initWithFrame:frame collectionViewLayout:layout];
}

- (void) hook_uicollectionview_setCollectionViewLayout:(UICollectionViewLayout *)layout {
    PTEnsureCustomCollectionViewLayoutHooked(layout);
    [self hook_uicollectionview_setCollectionViewLayout:layout];
}

- (void) hook_uicollectionview_setCollectionViewLayout:(UICollectionViewLayout *)layout
                                              animated:(BOOL)animated {
    PTEnsureCustomCollectionViewLayoutHooked(layout);
    [self hook_uicollectionview_setCollectionViewLayout:layout animated:animated];
}

- (void) hook_uicollectionview_setCollectionViewLayout:(UICollectionViewLayout *)layout
                                              animated:(BOOL)animated
                                            completion:(void (^)(BOOL finished))completion {
    PTEnsureCustomCollectionViewLayoutHooked(layout);
    [self hook_uicollectionview_setCollectionViewLayout:layout animated:animated completion:completion];
}

- (void) hook_uicollectionview_layoutSubviews {
    UICollectionView *cv = nil;
    UICollectionViewLayout *initialLayout = nil;
    BOOL isCustomLayout = NO;
    if ([self isKindOfClass:[UICollectionView class]]) {
        cv = (UICollectionView *)self;
        initialLayout = cv.collectionViewLayout;
        if (initialLayout) {
            isCustomLayout = PTEnsureCustomCollectionViewLayoutHooked(initialLayout);
        }
    }
    [self hook_uicollectionview_layoutSubviews];
    if (cv && [NSThread isMainThread]) {
        UICollectionViewLayout *layout = cv.collectionViewLayout;
        if (layout != initialLayout) {
            isCustomLayout = layout ? PTEnsureCustomCollectionViewLayoutHooked(layout) : NO;
        }
        if (isCustomLayout && layout) {
            CGSize boundsSize = cv.bounds.size;
            if (boundsSize.width > 1.0 && boundsSize.height > 1.0 &&
                (cv.contentSize.width <= 0.5 || cv.contentSize.height <= 0.5) &&
                ![PTCurrentlyPreparingLayouts() containsObject:layout] &&
                PTShouldPrimeLayoutAtSize(layout, boundsSize) &&
                PTShouldInvalidateInLayoutSubviews(layout, boundsSize) &&
                PTCollectionViewHasAnyItems(cv)) {
                [PTLayoutSubviewsInvalidatedBounds() setObject:[NSValue valueWithCGSize:boundsSize]
                                                        forKey:layout];
                [layout invalidateLayout];
            }
        }
    }
}

- (BOOL) hook_requiresFullScreen {
    return NO;
}

// `VSSubscription` does not exist on Mac Catalyst, so the parameter is kept
// untyped: the class is resolved by name at runtime and is simply absent there.
- (void) hook_setCurrentSubscription:(id)currentSubscription {
    // do nothing
}

- (NSString *)hook_stringByReplacingOccurrencesOfRegularExpressionPattern:(NSString *)pattern
                                                             withTemplate:(NSString *)template
                                                                  options:(NSRegularExpressionOptions)options
                                                                    range:(NSRange)range {
    // If the string is empty, return immediately to prevent a range out-of-bounds error.
    if ([(NSString*)self isEqualToString:@""]) {
        return @"";
    }
    return [self hook_stringByReplacingOccurrencesOfRegularExpressionPattern:pattern
                                                                withTemplate:template
                                                                     options:options
                                                                       range:range];
}

- (void)hook_requestRecordPermission:(void (^)(BOOL))response {
    BOOL granted = [[AVAudioSession sharedInstance] recordPermission] == AVAudioSessionRecordPermissionGranted;
    if (granted) {
        response(granted);
    } else {
        [self hook_requestRecordPermission:response];
    }
}

- (instancetype)hook_CMMotionManager_init {
    CMMotionManager *motionManager = (CMMotionManager *)[self hook_CMMotionManager_init];
    // The default update interval is 0, which may lead to excessive CPU usage
    motionManager.accelerometerUpdateInterval = 0.01;
    motionManager.deviceMotionUpdateInterval = 0.01;
    motionManager.gyroUpdateInterval = 0.01;
    return motionManager;
}

+ (GCMouse *)hook_GCMouse_current {
    return nil;
}

+ (NSArray *)hook_GCMouse_mice {
    return @[];
}

+ (void)hook_Unity_KeyboardDelegate_Initialize {
    @try {
        [self hook_Unity_KeyboardDelegate_Initialize];
    }
    @catch (NSException *exception) {
        NSLog(@"Caught exception: %@, reason: %@", exception.name, exception.reason);
    }
}

// Hook for UIUserInterfaceIdiom & UIDevice model override

- (long long) hook_userInterfaceIdiom_phone {
    return UIUserInterfaceIdiomPhone;
}

- (long long) hook_userInterfaceIdiom_pad {
    return UIUserInterfaceIdiomPad;
}

- (NSString *) hook_deviceModel_phone {
    return @"iPhone";
}

- (NSString *) hook_deviceModel_pad {
    return @"iPad";
}

bool menuWasCreated = false;
- (id) initWithRootMenuHook:(id)rootMenu {
    self = [self initWithRootMenuHook:rootMenu];
    if (!menuWasCreated) {
        [PlayCover initMenuWithMenu: self];
        menuWasCreated = TRUE;
    }
    return self;
}

@end

/*
 This class only exists to apply swizzles from the +load of a class that won't have any categories/extensions. The reason
 for not doing this in a C module initializer is that obj-c initialization happens before any __attribute__((constructor))
 is called. This way we can guarantee the hooks will be applied before [PlayCover launch] is called (in PlayLoader.m).
 
 Side note:
 While adding method replacements to NSObject does work, I'm not certain this doesn't (or won't) have any side effects. The
 way Apple does method swizzling internally is by creating a category of the swizzled class and adding the replacements there.
 This keeps all those replacements "local" to that class. Example:
 
 '''
 @interface FBSSceneSettings (Swizzle)
 -(CGRect) hook_frame {
    ...
 }
 @end
 
 Somewhere else:
 swizzle(FBSSceneSettings.class, @selector(frame), @selector(hook_frame);
 '''
 
 However, doing this would require generating @interface declarations (either with class-dump or by hand) which would add a lot
 of code and complexity. I'm not sure this trade-off is "worth it", at least at the time of writing.
 */

@implementation PTSwizzleLoader
+ (void)load {
    // This might need refactor soon
    if(@available(iOS 16.3, *)) {
        if ([[PlaySettings shared] dynamicWindowMode]) {
            pt_swizzleInstanceMethod(objc_getClass("_UIApplicationInfoParser"), NSSelectorFromString(@"requiresFullScreen"), @selector(hook_requiresFullScreen));
            pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(bounds), @selector(hook_boundsResizable));
            pt_swizzleInstanceMethod(objc_getClass("UIScreen"), NSSelectorFromString(@"applicationFrame"), @selector(hook_boundsResizable));
            pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeBounds), @selector(hook_nativeBoundsResizable));
            pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeScale), @selector(hook_nativeScale));
            pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(scale), @selector(hook_scale));
            pt_swizzleInstanceMethod(objc_getClass("UIWindow"), @selector(layoutSubviews), @selector(hook_uiwindow_layoutSubviews));
            pt_swizzleInstanceMethod(objc_getClass("UIWindow"), @selector(setFrame:), @selector(hook_uiwindow_setFrame:));
            pt_swizzleInstanceMethod(objc_getClass("UIWindow"), @selector(setBounds:), @selector(hook_uiwindow_setBounds:));
            pt_swizzleInstanceMethod(objc_getClass("UIWindow"), @selector(setRootViewController:), @selector(hook_uiwindow_setRootViewController:));
            pt_swizzleInstanceMethod(objc_getClass("UIWindow"), @selector(didAddSubview:), @selector(hook_uiwindow_didAddSubview:));
            pt_swizzleInstanceMethod(objc_getClass("UIWindowScene"), @selector(interfaceOrientation), @selector(hook_uiscene_interfaceOrientation));
            pt_swizzleInstanceMethod(objc_getClass("UIApplication"), @selector(statusBarOrientation), @selector(hook_uiapp_statusBarOrientation));
            Class sceneGeomCls = objc_getClass("UIWindowSceneGeometry");
            if (sceneGeomCls) {
                pt_swizzleInstanceMethod(sceneGeomCls, @selector(interfaceOrientation), @selector(hook_uiscenegeometry_interfaceOrientation));
            }
            Class fixedSpaceCls = objc_getClass("_UIScreenFixedCoordinateSpace");
            if (fixedSpaceCls) {
                pt_swizzleInstanceMethod(fixedSpaceCls, @selector(bounds), @selector(hook_uiscreenfixedspace_bounds));
            }
            if ([[PlaySettings shared] sdkShift]) {
                Class bundleCls = objc_getClass("NSBundle");
                pt_swizzleInstanceMethod(bundleCls, @selector(objectForInfoDictionaryKey:), @selector(hook_nsbundle_objectForInfoDictionaryKey:));
                pt_swizzleInstanceMethod(bundleCls, @selector(infoDictionary), @selector(hook_nsbundle_infoDictionary));
            }
            pt_swizzleInstanceMethod(objc_getClass("UIViewController"), @selector(viewWillLayoutSubviews), @selector(hook_vc_viewWillLayoutSubviews));
            pt_swizzleInstanceMethod(objc_getClass("UIViewController"), @selector(viewDidAppear:), @selector(hook_vc_viewDidAppear:));
            Class baseLayoutCls = objc_getClass("UICollectionViewLayout");
            sBaseLayoutPrepareMethod = class_getInstanceMethod(baseLayoutCls, @selector(prepareLayout));
            sBaseLayoutContentSizeMethod = class_getInstanceMethod(baseLayoutCls, @selector(collectionViewContentSize));
            pt_swizzleInstanceMethod(baseLayoutCls, @selector(prepareLayout), @selector(hook_uicollectionviewlayout_prepareLayout));
            pt_swizzleInstanceMethod(baseLayoutCls, @selector(invalidateLayoutWithContext:), @selector(hook_uicollectionviewlayout_invalidateLayoutWithContext:));
            Class cvCls = objc_getClass("UICollectionView");
            pt_swizzleInstanceMethod(cvCls, @selector(initWithFrame:collectionViewLayout:), @selector(hook_uicollectionview_initWithFrame:collectionViewLayout:));
            pt_swizzleInstanceMethod(cvCls, @selector(setCollectionViewLayout:), @selector(hook_uicollectionview_setCollectionViewLayout:));
            pt_swizzleInstanceMethod(cvCls, @selector(setCollectionViewLayout:animated:), @selector(hook_uicollectionview_setCollectionViewLayout:animated:));
            pt_swizzleInstanceMethod(cvCls, @selector(setCollectionViewLayout:animated:completion:), @selector(hook_uicollectionview_setCollectionViewLayout:animated:completion:));
            pt_swizzleInstanceMethod(cvCls, @selector(layoutSubviews), @selector(hook_uicollectionview_layoutSubviews));
        }
        else if ([[PlaySettings shared] adaptiveDisplay]) {
            // This is an experimental fix
            if ([[PlaySettings shared] inverseScreenValues]) {
                // This lines set External Scene settings and other IOS10 Runtime services by swizzling
                // In Sonoma 14.1 betas, frame method seems to be moved to FBSSceneSettingsCore
                if(@available(iOS 17.1, *))
                    pt_swizzleExchangeInstanceMethod(objc_getClass("FBSSceneSettingsCore"), @selector(frame), @selector(hook_frameDefault));
                else
                    pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(frame), @selector(hook_frameDefault));
                pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(bounds), @selector(hook_boundsDefault));
                pt_swizzleInstanceMethod(objc_getClass("FBSDisplayMode"), @selector(size), @selector(hook_sizeDelfault));
                
                // Fixes Apple mess at MacOS 13.2
                pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(orientation), @selector(hook_orientation));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeBounds), @selector(hook_nativeBoundsDefault));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeScale), @selector(hook_nativeScale));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(scale), @selector(hook_scale));
            } else {
                // This acutally runs when adaptiveDisplay is normally triggered
                if(@available(iOS 17.1, *))
                    pt_swizzleExchangeInstanceMethod(objc_getClass("FBSSceneSettingsCore"), @selector(frame), @selector(hook_frame));
                else
                    pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(frame), @selector(hook_frame));
                pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(bounds), @selector(hook_bounds));
                pt_swizzleInstanceMethod(objc_getClass("FBSDisplayMode"), @selector(size), @selector(hook_size));
                
                pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(orientation), @selector(hook_orientation));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeBounds), @selector(hook_nativeBounds));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeScale), @selector(hook_nativeScale));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(scale), @selector(hook_scale));   
            }
        }
        else {
            if ([[PlaySettings shared] windowFixMethod] == 1) {
                // do nothing:tm:
            }
            else {
                CGFloat newValueW = (CGFloat) [self get_default_width];
                [[PlaySettings shared] setValue:@(newValueW) forKey:@"windowSizeWidth"];
                
                CGFloat newValueH = (CGFloat)[self get_default_height];
                [[PlaySettings shared] setValue:@(newValueH) forKey:@"windowSizeHeight"];
                if (![[PlaySettings shared] inverseScreenValues]) {
                    if(@available(iOS 17.1, *))
                        pt_swizzleExchangeInstanceMethod(objc_getClass("FBSSceneSettingsCore"), @selector(frame), @selector(hook_frameDefault));
                    else
                        pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(frame), @selector(hook_frameDefault));
                    pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(bounds), @selector(hook_boundsDefault));
                    pt_swizzleInstanceMethod(objc_getClass("FBSDisplayMode"), @selector(size), @selector(hook_sizeDelfault));
                }
                pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(orientation), @selector(hook_orientation));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeBounds), @selector(hook_nativeBoundsDefault));
                
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(nativeScale), @selector(hook_nativeScale));
                pt_swizzleInstanceMethod(objc_getClass("UIScreen"), @selector(scale), @selector(hook_scale));
            }
        }
    } 
    else {
        if ([[PlaySettings shared] adaptiveDisplay]) {
                if(@available(iOS 17.1, *))
                    pt_swizzleExchangeInstanceMethod(objc_getClass("FBSSceneSettingsCore"), @selector(frame), @selector(hook_frame));
                else
                    pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(frame), @selector(hook_frame));
                pt_swizzleInstanceMethod(objc_getClass("FBSSceneSettings"), @selector(bounds), @selector(hook_bounds));
                pt_swizzleInstanceMethod(objc_getClass("FBSDisplayMode"), @selector(size), @selector(hook_size));
            }
    }
    
    pt_swizzleInstanceMethod(objc_getClass("_UIMenuBuilder"), sel_getUid("initWithRootMenu:"), @selector(initWithRootMenuHook:));
    pt_swizzleInstanceMethod(objc_getClass("IOSViewController"), @selector(prefersPointerLocked), @selector(hook_prefersPointerLocked));
    // Override device layout idiom (0 = auto, 1 = iPhone, 2 = iPad, 3 = iPhone Duo)
    NSInteger layoutIdiom = [[PlaySettings shared] layoutIdiom];
    if (layoutIdiom == 1 || layoutIdiom == 3) {
        pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(userInterfaceIdiom), @selector(hook_userInterfaceIdiom_phone));
        pt_swizzleInstanceMethod(objc_getClass("UITraitCollection"), @selector(userInterfaceIdiom), @selector(hook_userInterfaceIdiom_phone));
        pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(model), @selector(hook_deviceModel_phone));
        pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(localizedModel), @selector(hook_deviceModel_phone));
    } else if (layoutIdiom == 2) {
        pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(userInterfaceIdiom), @selector(hook_userInterfaceIdiom_pad));
        pt_swizzleInstanceMethod(objc_getClass("UITraitCollection"), @selector(userInterfaceIdiom), @selector(hook_userInterfaceIdiom_pad));
        pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(model), @selector(hook_deviceModel_pad));
        pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(localizedModel), @selector(hook_deviceModel_pad));
    }

    pt_swizzleInstanceMethod(objc_getClass("VSSubscriptionRegistrationCenter"), @selector(setCurrentSubscription:), @selector(hook_setCurrentSubscription:));

    if (PlayInfo.isUnrealEngine) {
        // Fix NSRegularExpression crash when system language is set to Chinese
        CFStringEncoding encoding = CFStringGetSystemEncoding();
        if (encoding == kCFStringEncodingMacChineseSimp || encoding == kCFStringEncodingMacChineseTrad) {
            SEL origSelector = NSSelectorFromString(@"_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:");
            SEL newSelector = @selector(hook_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:);
            pt_swizzleInstanceMethod(objc_getClass("NSString"), origSelector, newSelector);
        }
    }

    if ([[PlaySettings shared] checkMicPermissionSync]) {
        pt_swizzleInstanceMethod(objc_getClass("AVAudioSession"), @selector(requestRecordPermission:), @selector(hook_requestRecordPermission:));
    }

    if ([[PlaySettings shared] limitMotionUpdateFrequency]) {
        pt_swizzleInstanceMethod(objc_getClass("CMMotionManager"), @selector(init), @selector(hook_CMMotionManager_init));
    }

    if (([[PlaySettings shared] disableBuiltinMouse])) {
        pt_swizzleClassMethod(objc_getClass("GCMouse"), @selector(current), @selector(hook_GCMouse_current));
        pt_swizzleClassMethod(objc_getClass("GCMouse"), @selector(mice), @selector(hook_GCMouse_mice));
    }

    // Delay a frame to wait for some frameworks (such as UnityFramework) to load
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.01 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([[PlaySettings shared] ignoreUnityKeyboardInitializationError]) {
            pt_swizzleClassMethod(objc_getClass("KeyboardDelegate"), NSSelectorFromString(@"Initialize"), @selector(hook_Unity_KeyboardDelegate_Initialize));
        }
    });
}

@end
