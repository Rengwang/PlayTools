//
//  PlayEfficiencyHooks.m
//  PlayTools
//

#import "PlayEfficiencyHooks.h"
#import "PlayLoader.h"
#import "NSObject+Swizzle.h"

#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>

#import <PlayTools/PlayTools-Swift.h>

static NSString *const kPTWindowVisibilityDidChangeNotification = @"PTWindowVisibilityDidChangeNotification";

static const NSUInteger kPTDefaultNSCacheCostLimit = 64u * 1024u * 1024u;
static const NSUInteger kPTMaxURLCacheMemoryCapacity = 8u * 1024u * 1024u;
static const NSInteger kPTOccludedLowFPS = 5;
static const NSTimeInterval kPTOcclusionDelaySeconds = 10.0;
static const double kPTMaxAVPeakBitRate = 3000000.0;
static const NSTimeInterval kPTMaxAVForwardBufferDuration = 8.0;

static BOOL pt_powerSavingMode = NO;
static BOOL pt_memorySavingMode = NO;
static BOOL pt_metalMemorySaver = NO;
static BOOL pt_avMediaSaver = NO;
static NSInteger pt_configuredFrameRateCap = 0;

static _Atomic BOOL pt_forceReduceAccessibility = false;
static _Atomic BOOL pt_occludedLowFPSActive = false;
static BOOL pt_lastKnownWindowVisible = YES;

static os_unfair_lock pt_nsCacheLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<NSCache *> *pt_registeredNSCaches = nil;

static os_unfair_lock pt_mtkViewLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<MTKView *> *pt_trackedMTKViews = nil;

static os_unfair_lock pt_displayLinkLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<CADisplayLink *> *pt_trackedDisplayLinks = nil;

static os_unfair_lock pt_webViewLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<WKWebView *> *pt_trackedWKWebViews = nil;

static __weak id pt_cachedAKPlugin = nil;
static dispatch_block_t pt_pendingOcclusionWorkItem = nil;

static const void *const kPTWebViewMediaSuspendedKey = &kPTWebViewMediaSuspendedKey;
static const void *const kPTDisplayLinkRateStateKey = &kPTDisplayLinkRateStateKey;
static const void *const kPTMTKViewRequestedFPSKey = &kPTMTKViewRequestedFPSKey;

#pragma mark - Settings Helpers

static BOOL pt_settingsBool(id _Nullable settingsObj, SEL sel) {
    if (!settingsObj || !sel || ![settingsObj respondsToSelector:sel]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(settingsObj, sel);
}

static NSInteger pt_settingsInteger(id _Nullable settingsObj, SEL sel) {
    if (!settingsObj || !sel || ![settingsObj respondsToSelector:sel]) {
        return 0;
    }
    return ((NSInteger (*)(id, SEL))objc_msgSend)(settingsObj, sel);
}

#pragma mark - Accessibility Interpose & Class Hook

typedef BOOL (*pt_accessibility_bool_fn)(void);

static BOOL pt_hook_UIAccessibilityIsReduceTransparencyEnabled(void);
static BOOL pt_hook_UIAccessibilityIsReduceMotionEnabled(void);

DYLD_INTERPOSE(pt_hook_UIAccessibilityIsReduceTransparencyEnabled, UIAccessibilityIsReduceTransparencyEnabled)
DYLD_INTERPOSE(pt_hook_UIAccessibilityIsReduceMotionEnabled, UIAccessibilityIsReduceMotionEnabled)

static BOOL pt_hook_UIAccessibilityIsReduceTransparencyEnabled(void) {
    if (atomic_load_explicit(&pt_forceReduceAccessibility, memory_order_acquire)) {
        return YES;
    }
    return DYLD_INTERPOSE_ORIG(pt_accessibility_bool_fn, UIAccessibilityIsReduceTransparencyEnabled)();
}

static BOOL pt_hook_UIAccessibilityIsReduceMotionEnabled(void) {
    if (atomic_load_explicit(&pt_forceReduceAccessibility, memory_order_acquire)) {
        return YES;
    }
    return DYLD_INTERPOSE_ORIG(pt_accessibility_bool_fn, UIAccessibilityIsReduceMotionEnabled)();
}

static BOOL pt_accessibilityClassReturnYES(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return YES;
}

static void pt_installAccessibilityHooks(void) {
    atomic_store_explicit(&pt_forceReduceAccessibility, true, memory_order_release);

    Class accCls = objc_getClass("UIAccessibility");
    Class accMeta = accCls ? object_getClass((id)accCls) : Nil;
    if (!accMeta) {
        return;
    }
    SEL selectors[2] = {
        NSSelectorFromString(@"isReduceTransparencyEnabled"),
        NSSelectorFromString(@"isReduceMotionEnabled")
    };
    for (size_t i = 0; i < 2; i++) {
        Method m = class_getClassMethod(accCls, selectors[i]);
        if (m) {
            class_replaceMethod(accMeta, selectors[i], (IMP)pt_accessibilityClassReturnYES, method_getTypeEncoding(m));
        }
    }
}

#pragma mark - NSCache & NSURLCache Governance

static void pt_registerNSCache(NSCache * _Nullable cache) {
    if (!cache) {
        return;
    }
    os_unfair_lock_lock(&pt_nsCacheLock);
    if (!pt_registeredNSCaches) {
        pt_registeredNSCaches = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    [pt_registeredNSCaches addObject:cache];
    os_unfair_lock_unlock(&pt_nsCacheLock);
}

static NSUInteger pt_clampedURLCacheMemoryCapacity(NSUInteger memoryCapacity) {
    return (memoryCapacity > kPTMaxURLCacheMemoryCapacity) ? kPTMaxURLCacheMemoryCapacity : memoryCapacity;
}

@interface NSCache (PTEfficiencyHooks)
- (instancetype)pt_eff_init __attribute__((objc_method_family(init)));
- (void)pt_eff_setTotalCostLimit:(NSUInteger)lim;
- (void)pt_eff_setCountLimit:(NSUInteger)lim;
@end

@implementation NSCache (PTEfficiencyHooks)

- (instancetype)pt_eff_init {
    NSCache *instance = [self pt_eff_init];
    if (instance) {
        pt_registerNSCache(instance);
        if (instance.totalCostLimit == 0 && instance.countLimit == 0) {
            [instance pt_eff_setTotalCostLimit:kPTDefaultNSCacheCostLimit];
        }
    }
    return instance;
}

- (void)pt_eff_setTotalCostLimit:(NSUInteger)lim {
    pt_registerNSCache(self);
    NSUInteger effectiveLim = (lim == 0 && self.countLimit == 0) ? kPTDefaultNSCacheCostLimit : lim;
    [self pt_eff_setTotalCostLimit:effectiveLim];
}

- (void)pt_eff_setCountLimit:(NSUInteger)lim {
    pt_registerNSCache(self);
    [self pt_eff_setCountLimit:lim];
    if (lim == 0 && self.totalCostLimit == 0) {
        [self pt_eff_setTotalCostLimit:kPTDefaultNSCacheCostLimit];
    }
}

@end

@interface NSURLCache (PTEfficiencyHooks)
- (instancetype)pt_eff_initWithMemoryCapacity:(NSUInteger)memoryCapacity
                                diskCapacity:(NSUInteger)diskCapacity
                                directoryURL:(nullable NSURL *)directoryURL __attribute__((objc_method_family(init)));
- (void)pt_eff_setMemoryCapacity:(NSUInteger)memoryCapacity;
@end

@implementation NSURLCache (PTEfficiencyHooks)

- (instancetype)pt_eff_initWithMemoryCapacity:(NSUInteger)memoryCapacity
                                diskCapacity:(NSUInteger)diskCapacity
                                directoryURL:(nullable NSURL *)directoryURL {
    return [self pt_eff_initWithMemoryCapacity:pt_clampedURLCacheMemoryCapacity(memoryCapacity)
                                  diskCapacity:diskCapacity
                                  directoryURL:directoryURL];
}

- (void)pt_eff_setMemoryCapacity:(NSUInteger)memoryCapacity {
    [self pt_eff_setMemoryCapacity:pt_clampedURLCacheMemoryCapacity(memoryCapacity)];
}

@end

static void pt_installCacheGovernanceHooks(void) {
    Class nsCacheCls = [NSCache class];
    pt_swizzleInstanceMethod(nsCacheCls, @selector(init), @selector(pt_eff_init));
    pt_swizzleInstanceMethod(nsCacheCls, @selector(setTotalCostLimit:), @selector(pt_eff_setTotalCostLimit:));
    pt_swizzleInstanceMethod(nsCacheCls, @selector(setCountLimit:), @selector(pt_eff_setCountLimit:));

    Class urlCacheCls = [NSURLCache class];
    pt_swizzleInstanceMethod(urlCacheCls,
                             @selector(initWithMemoryCapacity:diskCapacity:directoryURL:),
                             @selector(pt_eff_initWithMemoryCapacity:diskCapacity:directoryURL:));
    pt_swizzleInstanceMethod(urlCacheCls, @selector(setMemoryCapacity:), @selector(pt_eff_setMemoryCapacity:));

    NSURLCache *sharedCache = [NSURLCache sharedURLCache];
    if (sharedCache.memoryCapacity > kPTMaxURLCacheMemoryCapacity) {
        sharedCache.memoryCapacity = kPTMaxURLCacheMemoryCapacity;
    }
}

#pragma mark - Metal & Backing Store Hooks

static void (*pt_origMetalLayerSetWantsEDR)(id, SEL, BOOL) = NULL;

static void pt_hook_metalLayerSetWantsEDR(id self, SEL _cmd, BOOL wantsEDR) {
    (void)wantsEDR;
    if (pt_origMetalLayerSetWantsEDR) {
        pt_origMetalLayerSetWantsEDR(self, _cmd, NO);
    }
}

@interface CAMetalLayer (PTEfficiencyHooks)
- (instancetype)pt_eff_metalLayerInit __attribute__((objc_method_family(init)));
- (void)pt_eff_setMaximumDrawableCount:(NSUInteger)count;
@end

@implementation CAMetalLayer (PTEfficiencyHooks)

- (instancetype)pt_eff_metalLayerInit {
    CAMetalLayer *layer = [self pt_eff_metalLayerInit];
    if (layer) {
        if (layer.maximumDrawableCount > 2) {
            layer.maximumDrawableCount = 2;
        }
        SEL setEdrSel = NSSelectorFromString(@"setWantsExtendedDynamicRangeContent:");
        if (setEdrSel && [layer respondsToSelector:setEdrSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, setEdrSel, NO);
        }
    }
    return layer;
}

- (void)pt_eff_setMaximumDrawableCount:(NSUInteger)count {
    NSUInteger clamped = (count > 2) ? 2 : count;
    [self pt_eff_setMaximumDrawableCount:clamped];
}

@end

@interface CALayer (PTEfficiencyHooks)
- (void)pt_eff_setContentsFormat:(CALayerContentsFormat)contentsFormat;
@end

@implementation CALayer (PTEfficiencyHooks)

- (void)pt_eff_setContentsFormat:(CALayerContentsFormat)contentsFormat {
    (void)contentsFormat;
    [self pt_eff_setContentsFormat:kCAContentsFormatRGBA8Uint];
}

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"

@interface UIGraphicsImageRendererFormat (PTEfficiencyHooks)
- (BOOL)pt_eff_prefersExtendedRange;
- (void)pt_eff_setPrefersExtendedRange:(BOOL)prefersExtendedRange;
- (UIGraphicsImageRendererFormatRange)pt_eff_preferredRange;
- (void)pt_eff_setPreferredRange:(UIGraphicsImageRendererFormatRange)preferredRange;
@end

@implementation UIGraphicsImageRendererFormat (PTEfficiencyHooks)

- (BOOL)pt_eff_prefersExtendedRange {
    return NO;
}

- (void)pt_eff_setPrefersExtendedRange:(BOOL)prefersExtendedRange {
    (void)prefersExtendedRange;
    [self pt_eff_setPrefersExtendedRange:NO];
}

- (UIGraphicsImageRendererFormatRange)pt_eff_preferredRange {
    UIGraphicsImageRendererFormatRange orig = [self pt_eff_preferredRange];
    if (orig == UIGraphicsImageRendererFormatRangeExtended ||
        orig == UIGraphicsImageRendererFormatRangeAutomatic) {
        return UIGraphicsImageRendererFormatRangeStandard;
    }
    return orig;
}

- (void)pt_eff_setPreferredRange:(UIGraphicsImageRendererFormatRange)preferredRange {
    UIGraphicsImageRendererFormatRange clamped = preferredRange;
    if (clamped == UIGraphicsImageRendererFormatRangeExtended ||
        clamped == UIGraphicsImageRendererFormatRangeAutomatic) {
        clamped = UIGraphicsImageRendererFormatRangeStandard;
    }
    [self pt_eff_setPreferredRange:clamped];
}

@end

#pragma clang diagnostic pop

static void pt_installMetalAndBackingStoreHooks(void) {
    Class metalLayerCls = [CAMetalLayer class];
    pt_swizzleInstanceMethod(metalLayerCls, @selector(init), @selector(pt_eff_metalLayerInit));
    pt_swizzleInstanceMethod(metalLayerCls,
                             @selector(setMaximumDrawableCount:),
                             @selector(pt_eff_setMaximumDrawableCount:));

    SEL setEdrSel = NSSelectorFromString(@"setWantsExtendedDynamicRangeContent:");
    Method edrMethod = setEdrSel ? class_getInstanceMethod(metalLayerCls, setEdrSel) : NULL;
    if (edrMethod) {
        IMP origImp = method_getImplementation(edrMethod);
        if (origImp != (IMP)pt_hook_metalLayerSetWantsEDR) {
            pt_origMetalLayerSetWantsEDR = (void (*)(id, SEL, BOOL))origImp;
            class_replaceMethod(metalLayerCls,
                                setEdrSel,
                                (IMP)pt_hook_metalLayerSetWantsEDR,
                                method_getTypeEncoding(edrMethod));
        }
    }

    pt_swizzleInstanceMethod([CALayer class],
                             @selector(setContentsFormat:),
                             @selector(pt_eff_setContentsFormat:));

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    Class fmtCls = [UIGraphicsImageRendererFormat class];
    pt_swizzleInstanceMethod(fmtCls, @selector(prefersExtendedRange), @selector(pt_eff_prefersExtendedRange));
    pt_swizzleInstanceMethod(fmtCls, @selector(setPrefersExtendedRange:), @selector(pt_eff_setPrefersExtendedRange:));
    pt_swizzleInstanceMethod(fmtCls, @selector(preferredRange), @selector(pt_eff_preferredRange));
    pt_swizzleInstanceMethod(fmtCls, @selector(setPreferredRange:), @selector(pt_eff_setPreferredRange:));
#pragma clang diagnostic pop
}

#pragma mark - Frame Rate Ceiling & MTKView Tracking

typedef NS_ENUM(NSInteger, PTDisplayLinkRateMode) {
    PTDisplayLinkRateModeDefault = 0,
    PTDisplayLinkRateModeRange = 1,
    PTDisplayLinkRateModeFPS = 2,
    PTDisplayLinkRateModeInterval = 3,
};

@interface PTDisplayLinkRateState : NSObject
@property (nonatomic, assign) PTDisplayLinkRateMode mode;
@property (nonatomic, assign) CAFrameRateRange requestedRange;
@property (nonatomic, assign) NSInteger requestedFPS;
@property (nonatomic, assign) NSInteger requestedInterval;
@end

@implementation PTDisplayLinkRateState
@end

static NSInteger pt_activeFPSCeiling(void) {
    BOOL lowFPS = atomic_load_explicit(&pt_occludedLowFPSActive, memory_order_acquire);
    if (lowFPS) {
        if (pt_configuredFrameRateCap > 0) {
            return MIN(pt_configuredFrameRateCap, kPTOccludedLowFPS);
        }
        return kPTOccludedLowFPS;
    }
    return pt_configuredFrameRateCap;
}

static CAFrameRateRange pt_clampFrameRateRange(CAFrameRateRange range, NSInteger ceiling) {
    if (ceiling <= 0) {
        return range;
    }
    float cap = (float)ceiling;
    if (range.minimum <= 0.0f && range.maximum <= 0.0f && range.preferred <= 0.0f) {
        return CAFrameRateRangeMake(cap, cap, cap);
    }
    float maxFPS = (range.maximum > 0.0f) ? MIN(range.maximum, cap) : cap;
    float minFPS = (range.minimum > 0.0f) ? MIN(range.minimum, maxFPS) : 0.0f;
    float prefFPS = (range.preferred > 0.0f) ? MIN(range.preferred, maxFPS) : maxFPS;
    if (prefFPS < minFPS) {
        prefFPS = minFPS;
    }
    return CAFrameRateRangeMake(minFPS, maxFPS, prefFPS);
}

static NSInteger pt_clampDisplayLinkFPS(NSInteger fps, NSInteger ceiling) {
    if (ceiling <= 0) {
        return fps;
    }
    if (fps <= 0) {
        return ceiling;
    }
    return MIN(fps, ceiling);
}

static NSInteger pt_clampDisplayLinkInterval(NSInteger interval, NSInteger ceiling) {
    NSInteger baseInterval = MAX(1, interval);
    if (ceiling <= 0) {
        return interval;
    }
    NSInteger minInterval = MAX(1, (NSInteger)ceil(60.0 / (double)ceiling));
    return MAX(baseInterval, minInterval);
}

static NSInteger pt_clampMTKViewFPS(NSInteger fps, NSInteger ceiling) {
    if (ceiling <= 0 || fps <= 0) {
        return fps;
    }
    return MIN(fps, ceiling);
}

static void pt_registerDisplayLink(CADisplayLink * _Nullable link) {
    if (!link) {
        return;
    }
    os_unfair_lock_lock(&pt_displayLinkLock);
    if (!pt_trackedDisplayLinks) {
        pt_trackedDisplayLinks = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    [pt_trackedDisplayLinks addObject:link];
    os_unfair_lock_unlock(&pt_displayLinkLock);
}

static PTDisplayLinkRateState *pt_stateForDisplayLink(CADisplayLink *link) {
    @synchronized (link) {
        PTDisplayLinkRateState *state = objc_getAssociatedObject(link, kPTDisplayLinkRateStateKey);
        if (!state) {
            state = [[PTDisplayLinkRateState alloc] init];
            state.mode = PTDisplayLinkRateModeDefault;
            state.requestedRange = CAFrameRateRangeDefault;
            state.requestedFPS = 0;
            state.requestedInterval = 1;
            objc_setAssociatedObject(link, kPTDisplayLinkRateStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return state;
    }
}

static void pt_registerMTKView(MTKView * _Nullable view) {
    if (!view) {
        return;
    }
    os_unfair_lock_lock(&pt_mtkViewLock);
    if (!pt_trackedMTKViews) {
        pt_trackedMTKViews = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    [pt_trackedMTKViews addObject:view];
    os_unfair_lock_unlock(&pt_mtkViewLock);
}

@interface CADisplayLink (PTEfficiencyHooks)
+ (CADisplayLink *)pt_eff_displayLinkWithTarget:(id)target selector:(SEL)sel;
- (CAFrameRateRange)pt_eff_preferredFrameRateRange;
- (void)pt_eff_setPreferredFrameRateRange:(CAFrameRateRange)range;
- (void)pt_eff_setPreferredFramesPerSecond:(NSInteger)fps;
- (void)pt_eff_setFrameInterval:(NSInteger)interval;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"

@implementation CADisplayLink (PTEfficiencyHooks)

+ (CADisplayLink *)pt_eff_displayLinkWithTarget:(id)target selector:(SEL)sel {
    CADisplayLink *link = [self pt_eff_displayLinkWithTarget:target selector:sel];
    if (link) {
        pt_registerDisplayLink(link);
        NSInteger ceiling = pt_activeFPSCeiling();
        if (ceiling > 0) {
            [link pt_eff_setPreferredFrameRateRange:pt_clampFrameRateRange(CAFrameRateRangeDefault, ceiling)];
        }
    }
    return link;
}

- (CAFrameRateRange)pt_eff_preferredFrameRateRange {
    pt_registerDisplayLink(self);
    CAFrameRateRange current = [self pt_eff_preferredFrameRateRange];
    return pt_clampFrameRateRange(current, pt_activeFPSCeiling());
}

- (void)pt_eff_setPreferredFrameRateRange:(CAFrameRateRange)range {
    pt_registerDisplayLink(self);
    PTDisplayLinkRateState *state = pt_stateForDisplayLink(self);
    @synchronized (self) {
        state.mode = PTDisplayLinkRateModeRange;
        state.requestedRange = range;
    }
    CAFrameRateRange clamped = pt_clampFrameRateRange(range, pt_activeFPSCeiling());
    [self pt_eff_setPreferredFrameRateRange:clamped];
}

- (void)pt_eff_setPreferredFramesPerSecond:(NSInteger)fps {
    pt_registerDisplayLink(self);
    PTDisplayLinkRateState *state = pt_stateForDisplayLink(self);
    @synchronized (self) {
        state.mode = PTDisplayLinkRateModeFPS;
        state.requestedFPS = fps;
    }
    NSInteger clamped = pt_clampDisplayLinkFPS(fps, pt_activeFPSCeiling());
    [self pt_eff_setPreferredFramesPerSecond:clamped];
}

- (void)pt_eff_setFrameInterval:(NSInteger)interval {
    pt_registerDisplayLink(self);
    PTDisplayLinkRateState *state = pt_stateForDisplayLink(self);
    @synchronized (self) {
        state.mode = PTDisplayLinkRateModeInterval;
        state.requestedInterval = interval;
    }
    NSInteger clamped = pt_clampDisplayLinkInterval(interval, pt_activeFPSCeiling());
    [self pt_eff_setFrameInterval:clamped];
}

@end

#pragma clang diagnostic pop

static BOOL pt_shouldTrackMTKView(void) {
    return pt_memorySavingMode || pt_metalMemorySaver || pt_powerSavingMode || pt_configuredFrameRateCap > 0;
}

static BOOL pt_shouldClampFPS(void) {
    return pt_powerSavingMode || pt_configuredFrameRateCap > 0;
}

@interface MTKView (PTEfficiencyHooks)
- (instancetype)pt_eff_initWithFrame:(CGRect)frameRect device:(nullable id<MTLDevice>)device __attribute__((objc_method_family(init)));
- (nullable instancetype)pt_eff_initWithCoder:(NSCoder *)coder __attribute__((objc_method_family(init)));
- (void)pt_eff_mtk_setPreferredFramesPerSecond:(NSInteger)preferredFramesPerSecond;
@end

@implementation MTKView (PTEfficiencyHooks)

- (instancetype)pt_eff_initWithFrame:(CGRect)frameRect device:(nullable id<MTLDevice>)device {
    MTKView *view = [self pt_eff_initWithFrame:frameRect device:device];
    if (view && pt_shouldTrackMTKView()) {
        pt_registerMTKView(view);
        if (pt_shouldClampFPS()) {
            NSInteger initialFPS = view.preferredFramesPerSecond;
            objc_setAssociatedObject(view, kPTMTKViewRequestedFPSKey, @(initialFPS), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSInteger ceiling = pt_activeFPSCeiling();
            if (ceiling > 0) {
                [view pt_eff_mtk_setPreferredFramesPerSecond:pt_clampMTKViewFPS(initialFPS, ceiling)];
            }
        }
    }
    return view;
}

- (nullable instancetype)pt_eff_initWithCoder:(NSCoder *)coder {
    MTKView *view = [self pt_eff_initWithCoder:coder];
    if (view && pt_shouldTrackMTKView()) {
        pt_registerMTKView(view);
        if (pt_shouldClampFPS()) {
            NSInteger initialFPS = view.preferredFramesPerSecond;
            objc_setAssociatedObject(view, kPTMTKViewRequestedFPSKey, @(initialFPS), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSInteger ceiling = pt_activeFPSCeiling();
            if (ceiling > 0) {
                [view pt_eff_mtk_setPreferredFramesPerSecond:pt_clampMTKViewFPS(initialFPS, ceiling)];
            }
        }
    }
    return view;
}

- (void)pt_eff_mtk_setPreferredFramesPerSecond:(NSInteger)preferredFramesPerSecond {
    pt_registerMTKView(self);
    objc_setAssociatedObject(self, kPTMTKViewRequestedFPSKey, @(preferredFramesPerSecond), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSInteger clamped = pt_clampMTKViewFPS(preferredFramesPerSecond, pt_activeFPSCeiling());
    [self pt_eff_mtk_setPreferredFramesPerSecond:clamped];
}

@end

static void pt_reapplyActiveFPSCeilingToAllTracked(void) {
    NSInteger ceiling = pt_activeFPSCeiling();

    os_unfair_lock_lock(&pt_displayLinkLock);
    NSArray<CADisplayLink *> *links = [pt_trackedDisplayLinks allObjects];
    os_unfair_lock_unlock(&pt_displayLinkLock);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (CADisplayLink *link in links) {
        PTDisplayLinkRateMode mode = PTDisplayLinkRateModeDefault;
        CAFrameRateRange reqRange = CAFrameRateRangeDefault;
        NSInteger reqFPS = 0;
        NSInteger reqInterval = 1;
        @synchronized (link) {
            PTDisplayLinkRateState *state = objc_getAssociatedObject(link, kPTDisplayLinkRateStateKey);
            if (state) {
                mode = state.mode;
                reqRange = state.requestedRange;
                reqFPS = state.requestedFPS;
                reqInterval = state.requestedInterval;
            }
        }
        switch (mode) {
            case PTDisplayLinkRateModeRange:
                [link pt_eff_setPreferredFrameRateRange:pt_clampFrameRateRange(reqRange, ceiling)];
                break;
            case PTDisplayLinkRateModeFPS:
                [link pt_eff_setPreferredFramesPerSecond:pt_clampDisplayLinkFPS(reqFPS, ceiling)];
                break;
            case PTDisplayLinkRateModeInterval:
                [link pt_eff_setFrameInterval:pt_clampDisplayLinkInterval(reqInterval, ceiling)];
                break;
            case PTDisplayLinkRateModeDefault:
                if (ceiling > 0) {
                    [link pt_eff_setPreferredFrameRateRange:pt_clampFrameRateRange(CAFrameRateRangeDefault, ceiling)];
                } else {
                    [link pt_eff_setPreferredFrameRateRange:CAFrameRateRangeDefault];
                }
                break;
        }
    }
#pragma clang diagnostic pop

    os_unfair_lock_lock(&pt_mtkViewLock);
    NSArray<MTKView *> *views = [pt_trackedMTKViews allObjects];
    os_unfair_lock_unlock(&pt_mtkViewLock);

    for (MTKView *view in views) {
        NSNumber *savedNum = objc_getAssociatedObject(view, kPTMTKViewRequestedFPSKey);
        NSInteger reqFPS = savedNum ? [savedNum integerValue] : view.preferredFramesPerSecond;
        if (!savedNum) {
            objc_setAssociatedObject(view, kPTMTKViewRequestedFPSKey, @(reqFPS), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [view pt_eff_mtk_setPreferredFramesPerSecond:pt_clampMTKViewFPS(reqFPS, ceiling)];
    }
}

static void pt_installFrameRateHooks(void) {
    Class displayLinkCls = [CADisplayLink class];
    pt_swizzleClassMethod(displayLinkCls,
                          @selector(displayLinkWithTarget:selector:),
                          @selector(pt_eff_displayLinkWithTarget:selector:));
    pt_swizzleInstanceMethod(displayLinkCls,
                             @selector(preferredFrameRateRange),
                             @selector(pt_eff_preferredFrameRateRange));
    pt_swizzleInstanceMethod(displayLinkCls,
                             @selector(setPreferredFrameRateRange:),
                             @selector(pt_eff_setPreferredFrameRateRange:));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    pt_swizzleInstanceMethod(displayLinkCls,
                             @selector(setPreferredFramesPerSecond:),
                             @selector(pt_eff_setPreferredFramesPerSecond:));
    pt_swizzleInstanceMethod(displayLinkCls,
                             @selector(setFrameInterval:),
                             @selector(pt_eff_setFrameInterval:));
#pragma clang diagnostic pop

    pt_swizzleInstanceMethod([MTKView class],
                             @selector(setPreferredFramesPerSecond:),
                             @selector(pt_eff_mtk_setPreferredFramesPerSecond:));
}

static void pt_installMTKViewInitHooks(void) {
    Class mtkViewCls = [MTKView class];
    pt_swizzleInstanceMethod(mtkViewCls,
                             @selector(initWithFrame:device:),
                             @selector(pt_eff_initWithFrame:device:));
    pt_swizzleInstanceMethod(mtkViewCls,
                             @selector(initWithCoder:),
                             @selector(pt_eff_initWithCoder:));
}

#pragma mark - WKWebView Tracking & Media Suspension

static void pt_registerWKWebView(WKWebView * _Nullable webView) {
    if (!webView) {
        return;
    }
    os_unfair_lock_lock(&pt_webViewLock);
    if (!pt_trackedWKWebViews) {
        pt_trackedWKWebViews = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    [pt_trackedWKWebViews addObject:webView];
    os_unfair_lock_unlock(&pt_webViewLock);
}

static void pt_updateTrackedWKWebViewsMediaSuspended(BOOL suspended) {
    os_unfair_lock_lock(&pt_webViewLock);
    NSArray<WKWebView *> *webViews = [pt_trackedWKWebViews allObjects];
    os_unfair_lock_unlock(&pt_webViewLock);

    for (WKWebView *webView in webViews) {
        BOOL wasSuspended = [objc_getAssociatedObject(webView, kPTWebViewMediaSuspendedKey) boolValue];
        if (wasSuspended == suspended) {
            continue;
        }
        objc_setAssociatedObject(webView,
                                 kPTWebViewMediaSuspendedKey,
                                 suspended ? @YES : nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([webView respondsToSelector:@selector(setAllMediaPlaybackSuspended:completionHandler:)]) {
            [webView setAllMediaPlaybackSuspended:suspended completionHandler:nil];
        }
    }
}

@interface WKWebView (PTEfficiencyHooks)
- (instancetype)pt_eff_initWithFrame:(CGRect)frame
                       configuration:(WKWebViewConfiguration *)configuration __attribute__((objc_method_family(init)));
@end

@implementation WKWebView (PTEfficiencyHooks)

- (instancetype)pt_eff_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    WKWebView *webView = [self pt_eff_initWithFrame:frame configuration:configuration];
    if (webView) {
        pt_registerWKWebView(webView);
        if (!pt_lastKnownWindowVisible) {
            objc_setAssociatedObject(webView,
                                     kPTWebViewMediaSuspendedKey,
                                     @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if ([webView respondsToSelector:@selector(setAllMediaPlaybackSuspended:completionHandler:)]) {
                [webView setAllMediaPlaybackSuspended:YES completionHandler:nil];
            }
        }
    }
    return webView;
}

@end

static void pt_installWKWebViewHooks(void) {
    pt_swizzleInstanceMethod([WKWebView class],
                             @selector(initWithFrame:configuration:),
                             @selector(pt_eff_initWithFrame:configuration:));
}

#pragma mark - AVPlayerItem Saver

static CGSize pt_maxAVResolution(void) {
    return pt_powerSavingMode ? CGSizeMake(1280.0, 720.0) : CGSizeMake(1920.0, 1080.0);
}

static CGSize pt_clampAVResolution(CGSize size) {
    CGSize cap = pt_maxAVResolution();
    if (size.width <= 0.0 || size.height <= 0.0) {
        return cap;
    }
    return CGSizeMake(MIN(size.width, cap.width), MIN(size.height, cap.height));
}

static double pt_clampAVPeakBitRate(double bitRate) {
    if (bitRate <= 0.0) {
        return kPTMaxAVPeakBitRate;
    }
    return MIN(bitRate, kPTMaxAVPeakBitRate);
}

static NSTimeInterval pt_clampAVForwardBufferDuration(NSTimeInterval duration) {
    if (duration <= 0.0) {
        return kPTMaxAVForwardBufferDuration;
    }
    return MIN(duration, kPTMaxAVForwardBufferDuration);
}

@interface AVPlayerItem (PTEfficiencyHooks)
- (instancetype)pt_eff_initWithAsset:(AVAsset *)asset
        automaticallyLoadedAssetKeys:(nullable NSArray<NSString *> *)automaticallyLoadedAssetKeys __attribute__((objc_method_family(init)));
- (void)pt_eff_setPreferredMaximumResolution:(CGSize)preferredMaximumResolution;
- (void)pt_eff_setPreferredPeakBitRate:(double)preferredPeakBitRate;
- (void)pt_eff_setPreferredForwardBufferDuration:(NSTimeInterval)preferredForwardBufferDuration;
- (void)pt_eff_setCanUseNetworkResourcesForLiveStreamingWhilePaused:(BOOL)canUse;
@end

@implementation AVPlayerItem (PTEfficiencyHooks)

- (instancetype)pt_eff_initWithAsset:(AVAsset *)asset
        automaticallyLoadedAssetKeys:(nullable NSArray<NSString *> *)automaticallyLoadedAssetKeys {
    AVPlayerItem *item = [self pt_eff_initWithAsset:asset
                       automaticallyLoadedAssetKeys:automaticallyLoadedAssetKeys];
    if (item) {
        [item pt_eff_setPreferredMaximumResolution:pt_maxAVResolution()];
        [item pt_eff_setPreferredPeakBitRate:kPTMaxAVPeakBitRate];
        [item pt_eff_setPreferredForwardBufferDuration:kPTMaxAVForwardBufferDuration];
        [item pt_eff_setCanUseNetworkResourcesForLiveStreamingWhilePaused:NO];
    }
    return item;
}

- (void)pt_eff_setPreferredMaximumResolution:(CGSize)preferredMaximumResolution {
    [self pt_eff_setPreferredMaximumResolution:pt_clampAVResolution(preferredMaximumResolution)];
}

- (void)pt_eff_setPreferredPeakBitRate:(double)preferredPeakBitRate {
    [self pt_eff_setPreferredPeakBitRate:pt_clampAVPeakBitRate(preferredPeakBitRate)];
}

- (void)pt_eff_setPreferredForwardBufferDuration:(NSTimeInterval)preferredForwardBufferDuration {
    [self pt_eff_setPreferredForwardBufferDuration:pt_clampAVForwardBufferDuration(preferredForwardBufferDuration)];
}

- (void)pt_eff_setCanUseNetworkResourcesForLiveStreamingWhilePaused:(BOOL)canUse {
    (void)canUse;
    [self pt_eff_setCanUseNetworkResourcesForLiveStreamingWhilePaused:NO];
}

@end

static void pt_installAVPlayerItemHooks(void) {
    Class itemCls = [AVPlayerItem class];
    pt_swizzleInstanceMethod(itemCls,
                             @selector(initWithAsset:automaticallyLoadedAssetKeys:),
                             @selector(pt_eff_initWithAsset:automaticallyLoadedAssetKeys:));
    pt_swizzleInstanceMethod(itemCls,
                             @selector(setPreferredMaximumResolution:),
                             @selector(pt_eff_setPreferredMaximumResolution:));
    pt_swizzleInstanceMethod(itemCls,
                             @selector(setPreferredPeakBitRate:),
                             @selector(pt_eff_setPreferredPeakBitRate:));
    pt_swizzleInstanceMethod(itemCls,
                             @selector(setPreferredForwardBufferDuration:),
                             @selector(pt_eff_setPreferredForwardBufferDuration:));
    pt_swizzleInstanceMethod(itemCls,
                             @selector(setCanUseNetworkResourcesForLiveStreamingWhilePaused:),
                             @selector(pt_eff_setCanUseNetworkResourcesForLiveStreamingWhilePaused:));
}

#pragma mark - Window Visibility & Occlusion Handling

static BOOL pt_isMainAppNSWindow(id win) {
    if (!win) {
        return NO;
    }
    NSString *className = NSStringFromClass([win class]);
    if ([className containsString:@"Menu"] ||
        [className containsString:@"StatusBar"] ||
        [className containsString:@"Tooltip"]) {
        return NO;
    }
    SEL canMainSel = NSSelectorFromString(@"canBecomeMainWindow");
    SEL isSheetSel = NSSelectorFromString(@"isSheet");
    BOOL canBecomeMain = canMainSel && [win respondsToSelector:canMainSel]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(win, canMainSel)
        : YES;
    BOOL isSheet = isSheetSel && [win respondsToSelector:isSheetSel]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(win, isSheetSel)
        : NO;
    return canBecomeMain && !isSheet;
}

static BOOL pt_queryWindowUnoccludedVisible(NSNotification * _Nullable notif) {
    SEL unoccludedSel = NSSelectorFromString(@"hasUnoccludedVisibleWindow");
    if (notif.object && [notif.object respondsToSelector:unoccludedSel]) {
        pt_cachedAKPlugin = notif.object;
        return ((BOOL (*)(id, SEL))objc_msgSend)(notif.object, unoccludedSel);
    }

    id cachedPlugin = pt_cachedAKPlugin;
    if (cachedPlugin && [cachedPlugin respondsToSelector:unoccludedSel]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(cachedPlugin, unoccludedSel);
    }

    NSNumber *userInfoVal = notif.userInfo[@"hasUnoccludedVisibleWindow"];
    if ([userInfoVal isKindOfClass:[NSNumber class]]) {
        return [userInfoVal boolValue];
    }

    Class nsAppCls = NSClassFromString(@"NSApplication");
    SEL sharedAppSel = NSSelectorFromString(@"sharedApplication");
    SEL windowsSel = NSSelectorFromString(@"windows");
    if (nsAppCls && sharedAppSel && windowsSel && [nsAppCls respondsToSelector:sharedAppSel]) {
        id nsApp = ((id (*)(id, SEL))objc_msgSend)(nsAppCls, sharedAppSel);
        if (nsApp && [nsApp respondsToSelector:windowsSel]) {
            NSArray *windows = ((NSArray *(*)(id, SEL))objc_msgSend)(nsApp, windowsSel);
            BOOL sawMainWindow = NO;
            SEL visibleSel = NSSelectorFromString(@"isVisible");
            SEL miniSel = NSSelectorFromString(@"isMiniaturized");
            SEL occlusionSel = NSSelectorFromString(@"occlusionState");
            for (id win in windows) {
                if (!pt_isMainAppNSWindow(win)) {
                    continue;
                }
                sawMainWindow = YES;
                BOOL isVisible = visibleSel && [win respondsToSelector:visibleSel]
                    ? ((BOOL (*)(id, SEL))objc_msgSend)(win, visibleSel)
                    : YES;
                BOOL isMini = miniSel && [win respondsToSelector:miniSel]
                    ? ((BOOL (*)(id, SEL))objc_msgSend)(win, miniSel)
                    : NO;
                NSUInteger occlusion = occlusionSel && [win respondsToSelector:occlusionSel]
                    ? ((NSUInteger (*)(id, SEL))objc_msgSend)(win, occlusionSel)
                    : (1UL << 1);
                if (isVisible && !isMini && ((occlusion & (1UL << 1)) != 0)) {
                    return YES;
                }
            }
            if (sawMainWindow) {
                return NO;
            }
        }
    }

    return YES;
}

static void pt_cancelPendingOcclusionTimer(void) {
    if (pt_pendingOcclusionWorkItem) {
        dispatch_block_cancel(pt_pendingOcclusionWorkItem);
        pt_pendingOcclusionWorkItem = nil;
    }
}

static void pt_releaseTrackedMTKViewDrawables(void) {
    os_unfair_lock_lock(&pt_mtkViewLock);
    NSArray<MTKView *> *views = [pt_trackedMTKViews allObjects];
    os_unfair_lock_unlock(&pt_mtkViewLock);

    for (MTKView *view in views) {
        [view releaseDrawables];
    }
}

static void pt_scheduleOcclusionActionsIfNeeded(void) {
    BOOL needMTKRelease = (pt_memorySavingMode || pt_metalMemorySaver);
    BOOL needLowFPS = pt_powerSavingMode;
    if (!needMTKRelease && !needLowFPS) {
        return;
    }
    if (pt_pendingOcclusionWorkItem) {
        return;
    }

    dispatch_block_t work = dispatch_block_create(0, ^{
        pt_pendingOcclusionWorkItem = nil;
        if (pt_queryWindowUnoccludedVisible(nil)) {
            return;
        }
        if (needMTKRelease) {
            pt_releaseTrackedMTKViewDrawables();
        }
        if (needLowFPS) {
            BOOL otherAudioPlaying = [[AVAudioSession sharedInstance] isOtherAudioPlaying];
            if (!otherAudioPlaying) {
                atomic_store_explicit(&pt_occludedLowFPSActive, true, memory_order_release);
                pt_reapplyActiveFPSCeilingToAllTracked();
            }
        }
    });
    pt_pendingOcclusionWorkItem = work;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPTOcclusionDelaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   work);
}

static void pt_handleWindowVisibilityDidChange(NSNotification * _Nullable notif) {
    BOOL isVisible = pt_queryWindowUnoccludedVisible(notif);
    pt_lastKnownWindowVisible = isVisible;

    if (isVisible) {
        pt_cancelPendingOcclusionTimer();
        if (pt_powerSavingMode) {
            pt_updateTrackedWKWebViewsMediaSuspended(NO);
            if (atomic_exchange_explicit(&pt_occludedLowFPSActive, false, memory_order_acq_rel)) {
                pt_reapplyActiveFPSCeilingToAllTracked();
            }
        }
    } else {
        if (pt_powerSavingMode) {
            pt_updateTrackedWKWebViewsMediaSuspended(YES);
        }
        pt_scheduleOcclusionActionsIfNeeded();
    }
}

static void pt_installVisibilityObserverIfNeeded(void) {
    if (!pt_powerSavingMode && !pt_memorySavingMode && !pt_metalMemorySaver) {
        return;
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:kPTWindowVisibilityDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        pt_handleWindowVisibilityDidChange(note);
    }];
}

#pragma mark - PTEfficiencyHooks

@implementation PTEfficiencyHooks

+ (void)installIfNeeded {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary<NSString *, NSString *> *env = [[NSProcessInfo processInfo] environment];
        if ([env[@"PLAYTOOLS_DISABLE_EFFICIENCY_HOOKS"] isEqualToString:@"1"]) {
            return;
        }

        id settings = [PlaySettings shared];
        pt_powerSavingMode = pt_settingsBool(settings, NSSelectorFromString(@"powerSavingMode"));
        pt_memorySavingMode = pt_settingsBool(settings, NSSelectorFromString(@"memorySavingMode"));
        pt_configuredFrameRateCap = pt_settingsInteger(settings, NSSelectorFromString(@"frameRateCap"));
        pt_metalMemorySaver = pt_settingsBool(settings, NSSelectorFromString(@"metalMemorySaver"));
        pt_avMediaSaver = pt_settingsBool(settings, NSSelectorFromString(@"avMediaSaver"));

        if (!pt_powerSavingMode &&
            !pt_memorySavingMode &&
            pt_configuredFrameRateCap <= 0 &&
            !pt_metalMemorySaver &&
            !pt_avMediaSaver) {
            return;
        }

        if (pt_powerSavingMode) {
            pt_installAccessibilityHooks();
            pt_installWKWebViewHooks();
        }
        if (pt_memorySavingMode) {
            pt_installCacheGovernanceHooks();
        }
        if (pt_memorySavingMode || pt_metalMemorySaver) {
            pt_installMetalAndBackingStoreHooks();
        }
        if (pt_shouldTrackMTKView()) {
            pt_installMTKViewInitHooks();
        }
        if (pt_shouldClampFPS()) {
            pt_installFrameRateHooks();
        }
        if (pt_avMediaSaver) {
            pt_installAVPlayerItemHooks();
        }

        pt_installVisibilityObserverIfNeeded();
    });
}

+ (void)trimRegisteredNSCaches {
    os_unfair_lock_lock(&pt_nsCacheLock);
    NSArray<NSCache *> *caches = pt_registeredNSCaches ? [pt_registeredNSCaches allObjects] : @[];
    os_unfair_lock_unlock(&pt_nsCacheLock);

    for (NSCache *cache in caches) {
        [cache removeAllObjects];
    }
}

@end
