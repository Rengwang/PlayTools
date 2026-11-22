//
//  NSObject+PrivateSwizzle.m
//  PlayTools
//
//  Created by siri on 06.10.2021.
//

#import "NSObject+Swizzle.h"
#import "PlayLoader.h"
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

__attribute__((visibility("hidden")))
@interface PTSwizzleMethods : NSObject
- (instancetype)pt_hook_UIMenuBuilder_initWithRootMenu:(id)rootMenu __attribute__((objc_method_family(init)));
- (instancetype)pt_hook_CMMotionManager_init __attribute__((objc_method_family(init)));
- (instancetype)pt_hook_UICollectionView_initWithFrame:(CGRect)frame
                                  collectionViewLayout:(UICollectionViewLayout *)layout
    __attribute__((objc_method_family(init)));
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
    pt_swizzleInstanceMethod(cls, origSelector, newSelector);
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

@end

@implementation PTSwizzleMethods

- (BOOL) pt_hook_IOSViewController_prefersPointerLocked {
    return false;
}

- (CGRect) pt_hook_FBSSceneSettings_frameDefault {
    return [PlayScreen frameDefault:[self pt_hook_FBSSceneSettings_frameDefault]];
}

- (CGRect) pt_hook_FBSSceneSettings_boundsDefault {
    return [PlayScreen boundsDefault:[self pt_hook_FBSSceneSettings_boundsDefault]];
}

- (CGRect) pt_hook_UIScreen_nativeBoundsDefault {
    return [PlayScreen nativeBoundsDefault:[self pt_hook_UIScreen_nativeBoundsDefault]];
}

- (CGSize) pt_hook_FBSDisplayMode_sizeDefault {
    return [PlayScreen sizeAspectRatioDefault:[self pt_hook_FBSDisplayMode_sizeDefault]];
}


- (CGRect) pt_hook_FBSSceneSettings_frame {
    return [PlayScreen frame:[self pt_hook_FBSSceneSettings_frame]];
}

- (CGRect) pt_hook_FBSSceneSettings_bounds {
    return [PlayScreen bounds:[self pt_hook_FBSSceneSettings_bounds]];
}

- (CGRect) pt_hook_UIScreen_nativeBounds {
    return [PlayScreen nativeBounds:[self pt_hook_UIScreen_nativeBounds]];
}

- (CGSize) pt_hook_FBSDisplayMode_size {
    return [PlayScreen sizeAspectRatio:[self pt_hook_FBSDisplayMode_size]];
}



- (long long) pt_hook_UIDevice_orientation {
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

- (double) pt_hook_UIScreen_nativeScale {
    return pt_cachedCustomScaler();
}

- (double) pt_hook_UIScreen_scale {
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

- (CGRect) pt_hook_UIScreen_bounds {
    return [PlayScreen boundsResizable:[self pt_hook_UIScreen_bounds]];
}

- (CGRect) pt_hook_UIScreen_applicationFrame {
    return [PlayScreen boundsResizable:[self pt_hook_UIScreen_applicationFrame]];
}

- (CGRect) pt_hook_UIScreen_nativeBoundsResizable {
    return [PlayScreen nativeBoundsResizable:[self pt_hook_UIScreen_nativeBoundsResizable]];
}

- (void) pt_hook_UIWindow_layoutSubviews {
    [self pt_hook_UIWindow_layoutSubviews];
    if ([self isKindOfClass:[UIWindow class]]) {
        [PlayScreen onWindowLayoutSubviews:(UIWindow *)self];
    }
}

- (void) pt_hook_UIWindow_setFrame:(CGRect)frame {
    if ([self isKindOfClass:[UIWindow class]]
        && [PlayScreen interceptWindowSetFrame:(UIWindow *)self frame:frame]) {
        return;
    }
    [self pt_hook_UIWindow_setFrame:frame];
}

- (void) pt_hook_UIWindow_setBounds:(CGRect)bounds {
    if ([self isKindOfClass:[UIWindow class]]
        && [PlayScreen interceptWindowSetBounds:(UIWindow *)self bounds:bounds]) {
        return;
    }
    [self pt_hook_UIWindow_setBounds:bounds];
}

- (void) pt_hook_UIWindow_setRootViewController:(UIViewController *)rootViewController {
    if ([self isKindOfClass:[UIWindow class]]) {
        [PlayScreen onWindowWillSetRootViewController:(UIWindow *)self];
    }
    [self pt_hook_UIWindow_setRootViewController:rootViewController];
}

- (void) pt_hook_UIWindow_didAddSubview:(UIView *)subview {
    [self pt_hook_UIWindow_didAddSubview:subview];
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

- (void) pt_hook_UIView_didMoveToWindow {
    [self pt_hook_UIView_didMoveToWindow];
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

- (UIInterfaceOrientation) pt_hook_UIWindowScene_interfaceOrientation {
    UIInterfaceOrientation orig = [self pt_hook_UIWindowScene_interfaceOrientation];
    if ([self isKindOfClass:[UIWindowScene class]]) {
        return [PlayScreen resolvedInterfaceOrientation:orig scene:(UIWindowScene *)self];
    }
    return orig;
}

- (UIInterfaceOrientation) pt_hook_UIApplication_statusBarOrientation {
    UIInterfaceOrientation orig = [self pt_hook_UIApplication_statusBarOrientation];
    return [PlayScreen resolvedInterfaceOrientation:orig scene:nil];
}

- (UIInterfaceOrientation) pt_hook_UIWindowSceneGeometry_interfaceOrientation {
    UIInterfaceOrientation orig = [self pt_hook_UIWindowSceneGeometry_interfaceOrientation];
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

- (CGRect) pt_hook_UIScreenFixedCoordinateSpace_bounds {
    CGRect orig = [self pt_hook_UIScreenFixedCoordinateSpace_bounds];
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

- (id) pt_hook_NSBundle_objectForInfoDictionaryKey:(NSString *)key {
    id orig = [self pt_hook_NSBundle_objectForInfoDictionaryKey:key];
    if (key && [self isEqual:[NSBundle mainBundle]]) {
        return [PlayScreen resolvedMainBundleInfoValue:orig forKey:key];
    }
    return orig;
}

- (NSDictionary<NSString *, id> *) pt_hook_NSBundle_infoDictionary {
    NSDictionary<NSString *, id> *orig = [self pt_hook_NSBundle_infoDictionary];
    if ([self isEqual:[NSBundle mainBundle]]) {
        return [PlayScreen resolvedMainBundleInfoDictionary:orig];
    }
    return orig;
}

- (void) pt_hook_UIViewController_viewWillLayoutSubviews {
    [self pt_hook_UIViewController_viewWillLayoutSubviews];
    if ([self isKindOfClass:[UIViewController class]]) {
        [PlayScreen onViewControllerLayout:(UIViewController *)self];
    }
}

- (void) pt_hook_UIViewController_viewDidAppear:(BOOL)animated {
    [self pt_hook_UIViewController_viewDidAppear:animated];
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

- (void) pt_hook_UICollectionViewLayout_prepareLayout {
    [self pt_hook_UICollectionViewLayout_prepareLayout];
    if ([NSThread isMainThread] && [self isKindOfClass:[UICollectionViewLayout class]]) {
        [PTPreparedLayouts() addObject:self];
    }
}

- (void) pt_hook_UICollectionViewLayout_invalidateLayoutWithContext:(UICollectionViewLayoutInvalidationContext *)context {
    if ([NSThread isMainThread] && [self isKindOfClass:[UICollectionViewLayout class]]) {
        UICollectionViewLayout *layout = (UICollectionViewLayout *)self;
        const void *instancePtr = (__bridge const void *)layout;
        [PTPreparedLayouts() removeObject:layout];
        if (!CFSetContainsValue(PTActiveLazyLayoutCalculations(), instancePtr) &&
            ![PTCurrentlyPreparingLayouts() containsObject:layout]) {
            [PTPrimedLayoutBounds() removeObjectForKey:layout];
        }
    }
    [self pt_hook_UICollectionViewLayout_invalidateLayoutWithContext:context];
}

- (instancetype) pt_hook_UICollectionView_initWithFrame:(CGRect)frame
                                collectionViewLayout:(UICollectionViewLayout *)layout {
    PTEnsureCustomCollectionViewLayoutHooked(layout);
    return [self pt_hook_UICollectionView_initWithFrame:frame collectionViewLayout:layout];
}

- (void) pt_hook_UICollectionView_setCollectionViewLayout:(UICollectionViewLayout *)layout {
    PTEnsureCustomCollectionViewLayoutHooked(layout);
    [self pt_hook_UICollectionView_setCollectionViewLayout:layout];
}

- (void) pt_hook_UICollectionView_setCollectionViewLayout:(UICollectionViewLayout *)layout
                                              animated:(BOOL)animated {
    PTEnsureCustomCollectionViewLayoutHooked(layout);
    [self pt_hook_UICollectionView_setCollectionViewLayout:layout animated:animated];
}

- (void) pt_hook_UICollectionView_setCollectionViewLayout:(UICollectionViewLayout *)layout
                                              animated:(BOOL)animated
                                            completion:(void (^)(BOOL finished))completion {
    PTEnsureCustomCollectionViewLayoutHooked(layout);
    [self pt_hook_UICollectionView_setCollectionViewLayout:layout animated:animated completion:completion];
}

- (void) pt_hook_UICollectionView_layoutSubviews {
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
    [self pt_hook_UICollectionView_layoutSubviews];
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

- (BOOL) pt_hook_UIApplicationInfoParser_requiresFullScreen {
    return NO;
}

// `VSSubscription` does not exist on Mac Catalyst, so the parameter is kept
// untyped: the class is resolved by name at runtime and is simply absent there.
- (void) pt_hook_VSSubscriptionRegistrationCenter_setCurrentSubscription:(id)currentSubscription {
    // do nothing
}

- (NSString *)pt_hook_NSString_stringByReplacingOccurrencesOfRegularExpressionPattern:(NSString *)pattern
                                                             withTemplate:(NSString *)template
                                                                  options:(NSRegularExpressionOptions)options
                                                                    range:(NSRange)range {
    // If the string is empty, return immediately to prevent a range out-of-bounds error.
    if ([(NSString*)self isEqualToString:@""]) {
        return @"";
    }
    return [self pt_hook_NSString_stringByReplacingOccurrencesOfRegularExpressionPattern:pattern
                                                                withTemplate:template
                                                                     options:options
                                                                       range:range];
}

- (void)pt_hook_AVAudioSession_requestRecordPermission:(void (^)(BOOL))response {
    BOOL granted = [[AVAudioSession sharedInstance] recordPermission] == AVAudioSessionRecordPermissionGranted;
    if (granted) {
        response(granted);
    } else {
        [self pt_hook_AVAudioSession_requestRecordPermission:response];
    }
}

- (instancetype)pt_hook_CMMotionManager_init {
    CMMotionManager *motionManager = (CMMotionManager *)[self pt_hook_CMMotionManager_init];
    // The default update interval is 0, which may lead to excessive CPU usage
    motionManager.accelerometerUpdateInterval = 0.01;
    motionManager.deviceMotionUpdateInterval = 0.01;
    motionManager.gyroUpdateInterval = 0.01;
    return (id)motionManager;
}

+ (GCMouse *)pt_hook_GCMouse_current {
    return nil;
}

+ (NSArray *)pt_hook_GCMouse_mice {
    return @[];
}

+ (void)pt_hook_KeyboardDelegate_Initialize {
    @try {
        [self pt_hook_KeyboardDelegate_Initialize];
    }
    @catch (NSException *exception) {
        NSLog(@"Caught exception: %@, reason: %@", exception.name, exception.reason);
    }
}

bool menuWasCreated = false;
- (instancetype)pt_hook_UIMenuBuilder_initWithRootMenu:(id)rootMenu {
    self = [self pt_hook_UIMenuBuilder_initWithRootMenu:rootMenu];
    if (!menuWasCreated) {
        [PlayCover initMenuWithMenu: self];
        menuWasCreated = TRUE;
    }
    return self;
}

@end

// Keep the aliases on the exact target class. An inherited Method may belong
// to NSObject or a UIKit superclass, whose dispatch must remain independent.
static void pt_installSwizzle(Class target, SEL originalSelector, Class carrier, SEL aliasSelector) {
    if (!target) {
        return;
    }
    Method original = class_getInstanceMethod(target, originalSelector);
    Method hook = class_getInstanceMethod(carrier, aliasSelector);
    if (!original || !hook) {
        return;
    }
    const char *encoding = method_getTypeEncoding(original);
    if (strcmp(encoding, method_getTypeEncoding(hook)) != 0) {
        return;
    }
    IMP replacement = method_getImplementation(hook);
    IMP originalImplementation = method_getImplementation(original);
    if (replacement == originalImplementation) {
        return;
    }
    class_replaceMethod(target, aliasSelector, originalImplementation, encoding);
    class_replaceMethod(target, originalSelector, replacement, encoding);
}

static void pt_installInstanceSwizzle(Class target, SEL original, SEL alias) {
    pt_installSwizzle(target, original, PTSwizzleMethods.class, alias);
}

static void pt_installClassSwizzle(Class target, SEL original, SEL alias) {
    pt_installSwizzle(object_getClass(target), original, object_getClass(PTSwizzleMethods.class), alias);
}

static UIUserInterfaceIdiom pt_phoneIdiom(id self, SEL selector) {
    return UIUserInterfaceIdiomPhone;
}

static UIUserInterfaceIdiom pt_padIdiom(id self, SEL selector) {
    return UIUserInterfaceIdiomPad;
}

static NSString *pt_phoneModel(id self, SEL selector) {
    return @"iPhone";
}

static NSString *pt_padModel(id self, SEL selector) {
    return @"iPad";
}

static NSString *pt_phoneSystemName(id self, SEL selector) {
    return @"iOS";
}

static void pt_overrideIdentityGetter(Class target, SEL selector, IMP implementation) {
    Method getter = class_getInstanceMethod(target, selector);
    if (getter) {
        class_replaceMethod(target, selector, implementation, method_getTypeEncoding(getter));
    }
}

static void pt_installDeviceLayoutIdentity(NSInteger layoutIdiom) {
    if (layoutIdiom == 0) {
        return;
    }

    BOOL phone = layoutIdiom == 1 || layoutIdiom == 3;
    IMP idiom = phone ? (IMP)pt_phoneIdiom : (IMP)pt_padIdiom;
    IMP model = phone ? (IMP)pt_phoneModel : (IMP)pt_padModel;
    Class device = objc_getClass("UIDevice");
    pt_overrideIdentityGetter(device, @selector(userInterfaceIdiom), idiom);
    pt_overrideIdentityGetter(objc_getClass("UITraitCollection"), @selector(userInterfaceIdiom), idiom);
    pt_overrideIdentityGetter(device, @selector(model), model);
    pt_overrideIdentityGetter(device, @selector(localizedModel), model);
    if (phone) {
        pt_overrideIdentityGetter(device, @selector(systemName), (IMP)pt_phoneSystemName);
    }
}

@implementation PTSwizzleLoader
+ (void)load {
    pt_initializePlatformIdentity();
    pt_installDeviceLayoutIdentity(PlaySettings.shared.layoutIdiom);
    // This might need refactor soon
    if(@available(iOS 16.3, *)) {
        if ([[PlaySettings shared] dynamicWindowMode]) {
            pt_installInstanceSwizzle(objc_getClass("_UIApplicationInfoParser"), NSSelectorFromString(@"requiresFullScreen"), @selector(pt_hook_UIApplicationInfoParser_requiresFullScreen));
            pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(bounds), @selector(pt_hook_UIScreen_bounds));
            pt_installInstanceSwizzle(objc_getClass("UIScreen"), NSSelectorFromString(@"applicationFrame"), @selector(pt_hook_UIScreen_applicationFrame));
            pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(nativeBounds), @selector(pt_hook_UIScreen_nativeBoundsResizable));
            pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(nativeScale), @selector(pt_hook_UIScreen_nativeScale));
            pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(scale), @selector(pt_hook_UIScreen_scale));
            pt_installInstanceSwizzle(objc_getClass("UIWindow"), @selector(layoutSubviews), @selector(pt_hook_UIWindow_layoutSubviews));
            pt_installInstanceSwizzle(objc_getClass("UIWindow"), @selector(setFrame:), @selector(pt_hook_UIWindow_setFrame:));
            pt_installInstanceSwizzle(objc_getClass("UIWindow"), @selector(setBounds:), @selector(pt_hook_UIWindow_setBounds:));
            pt_installInstanceSwizzle(objc_getClass("UIWindow"), @selector(setRootViewController:), @selector(pt_hook_UIWindow_setRootViewController:));
            pt_installInstanceSwizzle(objc_getClass("UIWindow"), @selector(didAddSubview:), @selector(pt_hook_UIWindow_didAddSubview:));
            pt_installInstanceSwizzle(objc_getClass("UIWindowScene"), @selector(interfaceOrientation), @selector(pt_hook_UIWindowScene_interfaceOrientation));
            pt_installInstanceSwizzle(objc_getClass("UIApplication"), @selector(statusBarOrientation), @selector(pt_hook_UIApplication_statusBarOrientation));
            Class sceneGeomCls = objc_getClass("UIWindowSceneGeometry");
            if (sceneGeomCls) {
                pt_installInstanceSwizzle(sceneGeomCls, @selector(interfaceOrientation), @selector(pt_hook_UIWindowSceneGeometry_interfaceOrientation));
            }
            Class fixedSpaceCls = objc_getClass("_UIScreenFixedCoordinateSpace");
            if (fixedSpaceCls) {
                pt_installInstanceSwizzle(fixedSpaceCls, @selector(bounds), @selector(pt_hook_UIScreenFixedCoordinateSpace_bounds));
            }
            if ([[PlaySettings shared] sdkShift]) {
                Class bundleCls = objc_getClass("NSBundle");
                pt_installInstanceSwizzle(bundleCls, @selector(objectForInfoDictionaryKey:), @selector(pt_hook_NSBundle_objectForInfoDictionaryKey:));
                pt_installInstanceSwizzle(bundleCls, @selector(infoDictionary), @selector(pt_hook_NSBundle_infoDictionary));
            }
            pt_installInstanceSwizzle(objc_getClass("UIViewController"), @selector(viewWillLayoutSubviews), @selector(pt_hook_UIViewController_viewWillLayoutSubviews));
            pt_installInstanceSwizzle(objc_getClass("UIViewController"), @selector(viewDidAppear:), @selector(pt_hook_UIViewController_viewDidAppear:));
            Class baseLayoutCls = objc_getClass("UICollectionViewLayout");
            sBaseLayoutPrepareMethod = class_getInstanceMethod(baseLayoutCls, @selector(prepareLayout));
            sBaseLayoutContentSizeMethod = class_getInstanceMethod(baseLayoutCls, @selector(collectionViewContentSize));
            pt_installInstanceSwizzle(baseLayoutCls, @selector(prepareLayout), @selector(pt_hook_UICollectionViewLayout_prepareLayout));
            pt_installInstanceSwizzle(baseLayoutCls, @selector(invalidateLayoutWithContext:), @selector(pt_hook_UICollectionViewLayout_invalidateLayoutWithContext:));
            Class cvCls = objc_getClass("UICollectionView");
            pt_installInstanceSwizzle(cvCls, @selector(initWithFrame:collectionViewLayout:), @selector(pt_hook_UICollectionView_initWithFrame:collectionViewLayout:));
            pt_installInstanceSwizzle(cvCls, @selector(setCollectionViewLayout:), @selector(pt_hook_UICollectionView_setCollectionViewLayout:));
            pt_installInstanceSwizzle(cvCls, @selector(setCollectionViewLayout:animated:), @selector(pt_hook_UICollectionView_setCollectionViewLayout:animated:));
            pt_installInstanceSwizzle(cvCls, @selector(setCollectionViewLayout:animated:completion:), @selector(pt_hook_UICollectionView_setCollectionViewLayout:animated:completion:));
            pt_installInstanceSwizzle(cvCls, @selector(layoutSubviews), @selector(pt_hook_UICollectionView_layoutSubviews));
        }
        else if ([[PlaySettings shared] adaptiveDisplay]) {
            // This is an experimental fix
            if ([[PlaySettings shared] inverseScreenValues]) {
                // This lines set External Scene settings and other IOS10 Runtime services by swizzling
                // In Sonoma 14.1 betas, frame method seems to be moved to FBSSceneSettingsCore
                if(@available(iOS 17.1, *))
                    pt_installInstanceSwizzle(objc_getClass("FBSSceneSettingsCore"), @selector(frame), @selector(pt_hook_FBSSceneSettings_frameDefault));
                else
                    pt_installInstanceSwizzle(objc_getClass("FBSSceneSettings"), @selector(frame), @selector(pt_hook_FBSSceneSettings_frameDefault));
                pt_installInstanceSwizzle(objc_getClass("FBSSceneSettings"), @selector(bounds), @selector(pt_hook_FBSSceneSettings_boundsDefault));
                pt_installInstanceSwizzle(objc_getClass("FBSDisplayMode"), @selector(size), @selector(pt_hook_FBSDisplayMode_sizeDefault));
                
                // Fixes Apple mess at MacOS 13.2
                pt_installInstanceSwizzle(objc_getClass("UIDevice"), @selector(orientation), @selector(pt_hook_UIDevice_orientation));
                pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(nativeBounds), @selector(pt_hook_UIScreen_nativeBoundsDefault));
                pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(nativeScale), @selector(pt_hook_UIScreen_nativeScale));
                pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(scale), @selector(pt_hook_UIScreen_scale));
            } else {
                // This acutally runs when adaptiveDisplay is normally triggered
                if(@available(iOS 17.1, *))
                    pt_installInstanceSwizzle(objc_getClass("FBSSceneSettingsCore"), @selector(frame), @selector(pt_hook_FBSSceneSettings_frame));
                else
                    pt_installInstanceSwizzle(objc_getClass("FBSSceneSettings"), @selector(frame), @selector(pt_hook_FBSSceneSettings_frame));
                pt_installInstanceSwizzle(objc_getClass("FBSSceneSettings"), @selector(bounds), @selector(pt_hook_FBSSceneSettings_bounds));
                pt_installInstanceSwizzle(objc_getClass("FBSDisplayMode"), @selector(size), @selector(pt_hook_FBSDisplayMode_size));
                
                pt_installInstanceSwizzle(objc_getClass("UIDevice"), @selector(orientation), @selector(pt_hook_UIDevice_orientation));
                pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(nativeBounds), @selector(pt_hook_UIScreen_nativeBounds));
                pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(nativeScale), @selector(pt_hook_UIScreen_nativeScale));
                pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(scale), @selector(pt_hook_UIScreen_scale));
            }
        }
        else {
            if ([[PlaySettings shared] windowFixMethod] == 1) {
                // do nothing:tm:
            }
            else {
                CGSize screenSize = UIScreen.mainScreen.bounds.size;
                [[PlaySettings shared] setValue:@(screenSize.width) forKey:@"windowSizeWidth"];
                [[PlaySettings shared] setValue:@(screenSize.height) forKey:@"windowSizeHeight"];
                if (![[PlaySettings shared] inverseScreenValues]) {
                    if(@available(iOS 17.1, *))
                        pt_installInstanceSwizzle(objc_getClass("FBSSceneSettingsCore"), @selector(frame), @selector(pt_hook_FBSSceneSettings_frameDefault));
                    else
                        pt_installInstanceSwizzle(objc_getClass("FBSSceneSettings"), @selector(frame), @selector(pt_hook_FBSSceneSettings_frameDefault));
                    pt_installInstanceSwizzle(objc_getClass("FBSSceneSettings"), @selector(bounds), @selector(pt_hook_FBSSceneSettings_boundsDefault));
                    pt_installInstanceSwizzle(objc_getClass("FBSDisplayMode"), @selector(size), @selector(pt_hook_FBSDisplayMode_sizeDefault));
                }
                pt_installInstanceSwizzle(objc_getClass("UIDevice"), @selector(orientation), @selector(pt_hook_UIDevice_orientation));
                pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(nativeBounds), @selector(pt_hook_UIScreen_nativeBoundsDefault));
                
                pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(nativeScale), @selector(pt_hook_UIScreen_nativeScale));
                pt_installInstanceSwizzle(objc_getClass("UIScreen"), @selector(scale), @selector(pt_hook_UIScreen_scale));
            }
        }
    } 
    else {
        if ([[PlaySettings shared] adaptiveDisplay]) {
                if(@available(iOS 17.1, *))
                    pt_installInstanceSwizzle(objc_getClass("FBSSceneSettingsCore"), @selector(frame), @selector(pt_hook_FBSSceneSettings_frame));
                else
                    pt_installInstanceSwizzle(objc_getClass("FBSSceneSettings"), @selector(frame), @selector(pt_hook_FBSSceneSettings_frame));
                pt_installInstanceSwizzle(objc_getClass("FBSSceneSettings"), @selector(bounds), @selector(pt_hook_FBSSceneSettings_bounds));
                pt_installInstanceSwizzle(objc_getClass("FBSDisplayMode"), @selector(size), @selector(pt_hook_FBSDisplayMode_size));
            }
    }
    
    pt_installInstanceSwizzle(objc_getClass("_UIMenuBuilder"), sel_getUid("initWithRootMenu:"), @selector(pt_hook_UIMenuBuilder_initWithRootMenu:));
    pt_installInstanceSwizzle(objc_getClass("IOSViewController"), @selector(prefersPointerLocked), @selector(pt_hook_IOSViewController_prefersPointerLocked));
    pt_installInstanceSwizzle(objc_getClass("VSSubscriptionRegistrationCenter"), @selector(setCurrentSubscription:), @selector(pt_hook_VSSubscriptionRegistrationCenter_setCurrentSubscription:));

    if (PlayInfo.isUnrealEngine) {
        // Fix NSRegularExpression crash when system language is set to Chinese
        CFStringEncoding encoding = CFStringGetSystemEncoding();
        if (encoding == kCFStringEncodingMacChineseSimp || encoding == kCFStringEncodingMacChineseTrad) {
            SEL origSelector = NSSelectorFromString(@"_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:");
            SEL newSelector = @selector(pt_hook_NSString_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:);
            pt_installInstanceSwizzle(objc_getClass("NSString"), origSelector, newSelector);
        }
    }

    if ([[PlaySettings shared] checkMicPermissionSync]) {
        pt_installInstanceSwizzle(objc_getClass("AVAudioSession"), @selector(requestRecordPermission:), @selector(pt_hook_AVAudioSession_requestRecordPermission:));
    }

    if ([[PlaySettings shared] limitMotionUpdateFrequency]) {
        pt_installInstanceSwizzle(objc_getClass("CMMotionManager"), @selector(init), @selector(pt_hook_CMMotionManager_init));
    }

    if (([[PlaySettings shared] disableBuiltinMouse])) {
        pt_installClassSwizzle(objc_getClass("GCMouse"), @selector(current), @selector(pt_hook_GCMouse_current));
        pt_installClassSwizzle(objc_getClass("GCMouse"), @selector(mice), @selector(pt_hook_GCMouse_mice));
    }

    // Delay a frame to wait for some frameworks (such as UnityFramework) to load
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.01 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([[PlaySettings shared] ignoreUnityKeyboardInitializationError]) {
            pt_installClassSwizzle(objc_getClass("KeyboardDelegate"), NSSelectorFromString(@"Initialize"), @selector(pt_hook_KeyboardDelegate_Initialize));
        }
    });
}

@end
