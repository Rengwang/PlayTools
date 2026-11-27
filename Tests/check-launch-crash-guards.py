#!/usr/bin/env python3
"""Contract and standalone Mac Catalyst runtime verification for generic launch crash guards:

1. CoreMotion `virtualAlmondDevice` over-release UAF guard (`pt_CMMotionManager_dealloc`).
2. `NSNotificationCenter` synchronous `NSUserDefaultsDidChangeNotification` & depth-16 recursion guard.
3. Pre-`main` `CoreGraphics` <-> `SkyLight` recursive `dispatch_once` deadlock guard via `DYLD_INTERPOSE`.
"""

import argparse
import re
import subprocess
import tempfile
from pathlib import Path


def resolve_root() -> Path:
    here = Path(__file__).resolve()
    root = here.parent.parent.parent
    if (root / "PlayTools" / "PlayTools").is_dir():
        return root
    return Path.cwd()


def read_text(path: Path) -> str:
    if not path.is_file():
        raise FileNotFoundError(f"Missing file: {path}")
    return path.read_text(encoding="utf-8", errors="replace")


def check_source_contracts(root: Path) -> None:
    pt_dir = root / "PlayTools" / "PlayTools"
    swizzle = read_text(pt_dir / "Controls" / "PTFakeTouch" / "NSObject+Swizzle.m")
    loader = read_text(pt_dir / "PlayLoader.m")

    required = [
        ("Swizzle:cmDeallocHook", swizzle, "pt_CMMotionManager_dealloc"),
        ("Swizzle:cmVirtualAlmondSelector", swizzle, 'sel_registerName("virtualAlmondDevice")'),
        ("Swizzle:cmCalibrationDone", swizzle, "sCMVirtualAlmondCalibrationDone"),
        ("Swizzle:cmExtraRetainEnabled", swizzle, "sCMVirtualAlmondExtraRetainEnabled"),
        ("Swizzle:cmRetainCountCheck", swizzle, "CFGetRetainCount"),
        ("PlayLoader:skylightPrewarm", loader, "pt_ensure_skylight_prewarmed"),
        ("PlayLoader:skylightFrameworkPath", loader, "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"),
        ("PlayLoader:skylightReentrancyGuard", loader, "pt_in_skylight_prewarm"),
        ("PlayLoader:nsClassFromStringInterpose", loader, "DYLD_INTERPOSE(pt_NSClassFromString, NSClassFromString)"),
        ("PlayLoader:dispatchAsyncInterpose", loader, "DYLD_INTERPOSE(pt_dispatch_async, dispatch_async)"),
        ("PlayLoader:nsClassFromStringVoidPtr", loader, "PT_INTERPOSE_EXPORT void *_Nullable pt_NSClassFromString(void *aClassName)"),
        ("PlayLoader:dispatchAsyncVoidPtr", loader, "PT_INTERPOSE_EXPORT void pt_dispatch_async(void *queue, void *block)"),
        ("PlayLoader:notificationGuardInstall", loader, "pt_installNotificationRecursionGuard"),
        ("PlayLoader:notificationGuardHook", loader, "pt_postNotificationNameObjectUserInfo"),
        ("PlayLoader:notificationDefaultsName", loader, "NSUserDefaultsDidChangeNotification"),
        ("PlayLoader:notificationMaxDepth", loader, "PT_NOTIFICATION_GENERAL_MAX_DEPTH"),
        ("PlayLoader:osVersionGuardInstall", loader, "pt_installOSVersionStringASCIIGuard"),
        ("PlayLoader:osVersionRuntimeHook", loader, "pt_runtimeProcessInfoOSVersionString"),
        ("PlayLoader:osVersionBaseHook", loader, "pt_baseProcessInfoOSVersionString"),
        ("PlayLoader:osVersionSelector", loader, "@selector(operatingSystemVersionString)"),
        ("PlayLoader:osVersionASCIIEncoding", loader, "NSASCIIStringEncoding"),
        ("PlayLoader:osVersionSysctlBuild", loader, "kern.osversion"),
    ]
    for label, text, token in required:
        if token not in text:
            raise AssertionError(f"MISSING {label}: '{token}'")

    # Ensure zero bundleIdentifier / target-app hardcodes in the new generic guard regions.
    cm_region = swizzle[swizzle.index("pt_CMMotionManager_dealloc"):swizzle.index("pt_installDeviceLayoutIdentity")]
    sky_region = loader[loader.index("pt_skylight_prewarmed"):loader.index("shouldHideInterface")]
    notif_region = loader[loader.index("PT_NOTIFICATION_STACK_CAP"):loader.index("pt_installUniversalCompatibilityGuards")]
    os_ver_region = loader[loader.index("pt_formatSafeASCIIOSVersionString"):loader.index("pt_initializePlatformIdentity")]
    for region_name, region in [
        ("CoreMotionDealloc", cm_region),
        ("SkyLightPrewarm", sky_region),
        ("NotificationRecursion", notif_region),
        ("OSVersionASCIIGuard", os_ver_region),
    ]:
        for bad in ("bundleIdentifier", "com.sina.weibo", "com.qiyi.iphone", "com.netease.cloudmusic"):
            if bad in region:
                raise AssertionError(f"FORBIDDEN {bad} in {region_name}")
        if re.search(r'"(com|cn|tv|org|net|io)\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_.-]+"', region):
            raise AssertionError(f"FORBIDDEN reverse-DNS literal in {region_name}")
    print("PASS: source-contracts")


def check_built_slices(root: Path) -> None:
    xcfw = root / "PlayCover" / "Carthage" / "Build" / "PlayTools.xcframework"
    ios_bin = xcfw / "ios-arm64" / "PlayTools.framework" / "PlayTools"
    cat_bin = xcfw / "ios-arm64-maccatalyst" / "PlayTools.framework" / "PlayTools"
    if not ios_bin.exists() or not cat_bin.exists():
        raise FileNotFoundError(f"Built xcframework slices not found at {xcfw}")

    ios_syms = subprocess.check_output(["nm", "-gU", str(ios_bin)], text=True)
    for sym in ("_pt_NSClassFromString", "_pt_dispatch_async"):
        if sym in ios_syms:
            raise AssertionError(f"ios-arm64 slice must not export Catalyst interpose {sym}")

    cat_syms = subprocess.check_output(["nm", "-gU", str(cat_bin)], text=True)
    for sym in ("_pt_NSClassFromString", "_pt_dispatch_async"):
        if sym not in cat_syms:
            raise AssertionError(f"maccatalyst slice missing expected interpose {sym}")

    # Verify built pt_NSClassFromString & pt_dispatch_async emit ZERO ARC retain/release calls
    disasm = subprocess.check_output([
        "lldb", "-b",
        "-o", f"target create {cat_bin}",
        "-o", "disassemble -n pt_NSClassFromString",
        "-o", "disassemble -n pt_dispatch_async",
        "-o", "quit",
    ], text=True, stderr=subprocess.STDOUT)
    forbidden_arc = (
        "objc_retain",
        "objc_release",
        "objc_retainAutoreleasedReturnValue",
        "objc_autoreleaseReturnValue",
        "objc_unsafeClaimAutoreleasedReturnValue",
    )
    for fn_name in ("pt_NSClassFromString", "pt_dispatch_async"):
        marker = f"PlayTools`{fn_name}:"
        if marker not in disasm:
            raise AssertionError(f"Missing disassembly for {fn_name} in {cat_bin}")
        section = disasm[disasm.index(marker):]
        # Slice until next function header or `(lldb) quit`
        next_idx = len(section)
        for stop_tok in ("\nPlayTools`", "\n(lldb) "):
            pos = section.find(stop_tok, len(marker))
            if pos != -1 and pos < next_idx:
                next_idx = pos
        fn_disasm = section[:next_idx]
        for arc_call in forbidden_arc:
            if arc_call in fn_disasm:
                raise AssertionError(f"Forbidden ARC helper '{arc_call}' found in {fn_name}:\n{fn_disasm}")
    print("PASS: built-slices-catalyst-and-ios-clean-and-no-arc-in-interposers")


def run_coremotion_runtime_test() -> None:
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    src = r'''
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdio.h>
#import <assert.h>

@interface PTTestVirtualDevice : NSObject
- (BOOL)isAccelerometerAvailable;
@end
@implementation PTTestVirtualDevice
- (BOOL)isAccelerometerAvailable { return YES; }
@end

static id gBuggyGlobalDev = nil;
static id gFixedGlobalDev = nil;

@interface PTBuggyMotionManager : NSObject
+ (void)setVirtualAlmondDevice:(id)dev;
+ (id)virtualAlmondDevice;
@end
@implementation PTBuggyMotionManager
+ (void)setVirtualAlmondDevice:(id)dev { gBuggyGlobalDev = [dev retain]; }
+ (id)virtualAlmondDevice { return gBuggyGlobalDev; }
- (void)dealloc {
    [gBuggyGlobalDev release]; // mirrors macOS 27.2.1 deallocPrivate unmatched release
    [(PTTestVirtualDevice *)gBuggyGlobalDev isAccelerometerAvailable]; // UAF if freed
    [super dealloc];
}
@end

@interface PTFixedMotionManager : NSObject
+ (void)setVirtualAlmondDevice:(id)dev;
+ (id)virtualAlmondDevice;
@end
@implementation PTFixedMotionManager
+ (void)setVirtualAlmondDevice:(id)dev { gFixedGlobalDev = [dev retain]; }
+ (id)virtualAlmondDevice { return gFixedGlobalDev; }
- (void)dealloc {
    // Future fixed macOS: balanced / does not over-release
    [(PTTestVirtualDevice *)gFixedGlobalDev isAccelerometerAvailable];
    [super dealloc];
}
@end

static void install_guard_on(Class targetCls, BOOL simulateBuggyOS) {
    __block void (*origDealloc)(id, SEL) = NULL;
    __block atomic_bool calibDone = ATOMIC_VAR_INIT(false);
    __block atomic_bool extraRetain = ATOMIC_VAR_INIT(true);
    __block os_unfair_lock calibLock = OS_UNFAIR_LOCK_INIT;
    SEL deallocSel = sel_registerName("dealloc");
    Method m = class_getInstanceMethod(targetCls, deallocSel);
    origDealloc = (void (*)(id, SEL))method_getImplementation(m);
    IMP hook = imp_implementationWithBlock(^void(id selfObj) {
        if (!atomic_load_explicit(&calibDone, memory_order_acquire)) {
            os_unfair_lock_lock(&calibLock);
            if (!atomic_load_explicit(&calibDone, memory_order_relaxed)) {
                CFTypeRef retainedDev = NULL;
                CFIndex beforeCount = 0;
                SEL devSel = sel_registerName("virtualAlmondDevice");
                if ([targetCls respondsToSelector:devSel]) {
                    id dev = ((id (*)(id, SEL))objc_msgSend)(targetCls, devSel);
                    if (dev) {
                        retainedDev = (CFTypeRef)dev;
                        beforeCount = CFGetRetainCount(retainedDev);
                        CFRetain(retainedDev);
                    }
                }
                origDealloc(selfObj, deallocSel);
                if (retainedDev) {
                    CFIndex afterCount = CFGetRetainCount(retainedDev);
                    if (afterCount == beforeCount + 1) {
                        atomic_store_explicit(&extraRetain, false, memory_order_release);
                        CFRelease(retainedDev);
                    }
                    atomic_store_explicit(&calibDone, true, memory_order_release);
                }
                os_unfair_lock_unlock(&calibLock);
                return;
            }
            os_unfair_lock_unlock(&calibLock);
        }
        if (atomic_load_explicit(&extraRetain, memory_order_acquire)) {
            SEL devSel = sel_registerName("virtualAlmondDevice");
            if ([targetCls respondsToSelector:devSel]) {
                id dev = ((id (*)(id, SEL))objc_msgSend)(targetCls, devSel);
                if (dev) { CFRetain((CFTypeRef)dev); }
            }
        }
        origDealloc(selfObj, deallocSel);
    });
    class_replaceMethod(targetCls, deallocSel, hook, method_getTypeEncoding(m));
    (void)simulateBuggyOS;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL unguardedCrashTest = (argc > 1 && strcmp(argv[1], "--crash") == 0);
        if (unguardedCrashTest) {
            PTTestVirtualDevice *dev = [[PTTestVirtualDevice alloc] init];
            [PTBuggyMotionManager setVirtualAlmondDevice:dev];
            [dev release];
            [[[PTBuggyMotionManager alloc] init] release];
            [[[PTBuggyMotionManager alloc] init] release];
            return 0;
        }

        // 1. Buggy macOS 27.2.1 behavior -> guarded keeps retainCount == 1 across 5 cycles
        PTTestVirtualDevice *dev1 = [[PTTestVirtualDevice alloc] init];
        [PTBuggyMotionManager setVirtualAlmondDevice:dev1];
        [dev1 release];
        install_guard_on([PTBuggyMotionManager class], YES);
        for (int i = 0; i < 5; i++) {
            [[[PTBuggyMotionManager alloc] init] release];
            assert(CFGetRetainCount((CFTypeRef)gBuggyGlobalDev) == 1);
        }

        // 2. Future fixed macOS -> self-calibrates on 1st dealloc and never leaks (rc stays 1)
        PTTestVirtualDevice *dev2 = [[PTTestVirtualDevice alloc] init];
        [PTFixedMotionManager setVirtualAlmondDevice:dev2];
        [dev2 release];
        install_guard_on([PTFixedMotionManager class], NO);
        for (int i = 0; i < 5; i++) {
            [[[PTFixedMotionManager alloc] init] release];
            assert(CFGetRetainCount((CFTypeRef)gFixedGlobalDev) == 1);
        }

        // 3. Also exercise real CoreMotion CMMotionManager with PlayTools-compatible dealloc guard
        Class cmCls = [CMMotionManager class];
        if (cmCls) {
            install_guard_on(cmCls, YES);
            for (int i = 0; i < 3; i++) {
                CMMotionManager *mgr = [[CMMotionManager alloc] init];
                (void)[mgr isAccelerometerAvailable];
                [mgr release];
            }
        }
        printf("COREMOTION_GUARD_OK\n");
    }
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix="pt-cm-test-") as tmp:
        src_p = Path(tmp) / "cm_test.m"
        bin_p = Path(tmp) / "cm_test"
        src_p.write_text(src, encoding="utf-8")
        subprocess.run([
            "xcrun", "clang", "-fno-objc-arc",
            "-target", "arm64-apple-ios16.0-macabi",
            "-isysroot", sdk,
            "-isystem", f"{sdk}/System/iOSSupport/usr/include",
            "-iframework", f"{sdk}/System/iOSSupport/System/Library/Frameworks",
            "-framework", "Foundation", "-framework", "CoreMotion",
            str(src_p), "-o", str(bin_p),
        ], check=True)

        # Unguarded UAF sends message to freed gBuggyGlobalDev on 1st/2nd cycle (enable NSZombie/MallocScribble or 2 cycles)
        env = dict(**{"MallocScribble": "1", "MallocPreScribble": "1"})
        crash_run = subprocess.run([str(bin_p), "--crash"], env=env, capture_output=True, text=True, check=False)
        assert crash_run.returncode < 0, f"Expected unguarded UAF crash, got rc={crash_run.returncode}"

        guard_run = subprocess.run([str(bin_p)], env=env, capture_output=True, text=True, check=False)
        assert guard_run.returncode == 0 and "COREMOTION_GUARD_OK" in guard_run.stdout, (
            f"CoreMotion guard failed (rc={guard_run.returncode}): {guard_run.stdout} {guard_run.stderr}"
        )
    print("PASS: coremotion-virtualAlmondDevice-dealloc-balance-and-calibration")


def run_notification_recursion_test() -> None:
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    src = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <assert.h>

#define PT_NOTIFICATION_STACK_CAP 32
#define PT_NOTIFICATION_GENERAL_MAX_DEPTH 16

typedef struct {
    const void *center;
    const void *namePtr;
} pt_notif_dispatch_entry_t;

static __thread pt_notif_dispatch_entry_t pt_notif_stack[PT_NOTIFICATION_STACK_CAP];
static __thread NSUInteger pt_notif_stack_depth = 0;
static void (*pt_origPost)(id, SEL, NSNotificationName, id, NSDictionary *) = NULL;

static void pt_post(NSNotificationCenter *self, SEL _cmd, NSNotificationName name, id object, NSDictionary *userInfo) {
    if (!pt_origPost) return;
    const void *centerPtr = (__bridge const void *)self;
    const void *namePtr = (__bridge const void *)name;
    BOOL isDefaultsDidChange = (name != nil && [name isEqualToString:NSUserDefaultsDidChangeNotification]);
    NSUInteger activeCount = MIN(pt_notif_stack_depth, (NSUInteger)PT_NOTIFICATION_STACK_CAP);
    NSUInteger samePairCount = 0;
    for (NSUInteger i = 0; i < activeCount; i++) {
        pt_notif_dispatch_entry_t entry = pt_notif_stack[i];
        if (entry.center == centerPtr
            && (entry.namePtr == namePtr
                || (name != nil && entry.namePtr != NULL && [(__bridge NSString *)entry.namePtr isEqualToString:name]))) {
            samePairCount++;
            if (isDefaultsDidChange || samePairCount >= PT_NOTIFICATION_GENERAL_MAX_DEPTH) {
                return;
            }
        }
    }
    BOOL recorded = (pt_notif_stack_depth < PT_NOTIFICATION_STACK_CAP);
    if (recorded) {
        pt_notif_stack[pt_notif_stack_depth].center = centerPtr;
        pt_notif_stack[pt_notif_stack_depth].namePtr = namePtr;
    }
    pt_notif_stack_depth++;
    @try {
        pt_origPost(self, _cmd, name, object, userInfo);
    } @finally {
        if (pt_notif_stack_depth > 0) pt_notif_stack_depth--;
        if (recorded) {
            pt_notif_stack[pt_notif_stack_depth].center = NULL;
            pt_notif_stack[pt_notif_stack_depth].namePtr = NULL;
        }
    }
}

@interface PTTestObserver : NSObject
@property (nonatomic, assign) NSInteger defaultsLoopCount;
@property (nonatomic, assign) NSInteger generalLoopCount;
@property (nonatomic, assign) NSInteger outerACount;
@property (nonatomic, assign) NSInteger innerBCount;
@end

@implementation PTTestObserver
- (void)onWildcardNotification:(NSNotification *)note {
    if ([note.name isEqualToString:NSUserDefaultsDidChangeNotification] || [note.name isEqualToString:@"TriggerStart"]) {
        self.defaultsLoopCount++;
        // Mirrors BBASMAccountAdapterManager writing @(0) to NSUserDefaults on wildcard notification
        [[NSUserDefaults standardUserDefaults] setObject:@(0) forKey:@"pt_test_iqiyi_login_key"];
    } else if ([note.name isEqualToString:@"GeneralSelfLoop"]) {
        self.generalLoopCount++;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"GeneralSelfLoop" object:nil userInfo:nil];
    } else if ([note.name isEqualToString:@"OuterA"]) {
        self.outerACount++;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"InnerB" object:nil userInfo:nil];
    } else if ([note.name isEqualToString:@"InnerB"]) {
        self.innerBCount++;
    }
}
@end

int main(void) {
    @autoreleasepool {
        Class ncCls = [NSNotificationCenter class];
        SEL sel = @selector(postNotificationName:object:userInfo:);
        Method m = class_getInstanceMethod(ncCls, sel);
        pt_origPost = (void (*)(id, SEL, NSNotificationName, id, NSDictionary *))method_getImplementation(m);
        class_replaceMethod(ncCls, sel, (IMP)pt_post, method_getTypeEncoding(m));

        PTTestObserver *obs = [PTTestObserver new];
        // Register name:nil wildcard observer exactly like iQIYI BBASMAccountAdapterManager
        [[NSNotificationCenter defaultCenter] addObserver:obs
                                                 selector:@selector(onWildcardNotification:)
                                                     name:nil
                                                   object:nil];

        // 1. Trigger wildcard notification -> writes NSUserDefaults -> posts NSUserDefaultsDidChangeNotification
        // -> observer re-writes NSUserDefaults -> synchronous re-entry broken cleanly on depth >= 1!
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TriggerStart" object:nil userInfo:nil];
        assert(obs.defaultsLoopCount == 2); // TriggerStart + first NSUserDefaultsDidChangeNotification
        assert([[[NSUserDefaults standardUserDefaults] objectForKey:@"pt_test_iqiyi_login_key"] isEqual:@(0)]);
        assert(pt_notif_stack_depth == 0);

        // 2. Subsequent top-level NSUserDefaultsDidChangeNotification still delivers cleanly
        [[NSNotificationCenter defaultCenter] postNotificationName:NSUserDefaultsDidChangeNotification object:nil userInfo:nil];
        assert(obs.defaultsLoopCount == 3);

        // 3. General self-recursion guard caps exact (center, name) at depth 16 instead of stack overflow
        [[NSNotificationCenter defaultCenter] postNotificationName:@"GeneralSelfLoop" object:nil userInfo:nil];
        assert(obs.generalLoopCount == PT_NOTIFICATION_GENERAL_MAX_DEPTH);
        assert(pt_notif_stack_depth == 0);

        // 4. Legitimate nested A -> B notifications and name:nil wildcard preserved
        [[NSNotificationCenter defaultCenter] postNotificationName:@"OuterA" object:nil userInfo:nil];
        assert(obs.outerACount == 1 && obs.innerBCount == 1);

        [[NSNotificationCenter defaultCenter] removeObserver:obs];
        printf("NOTIFICATION_GUARD_OK\n");
    }
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix="pt-nc-test-") as tmp:
        src_p = Path(tmp) / "nc_test.m"
        bin_p = Path(tmp) / "nc_test"
        src_p.write_text(src, encoding="utf-8")
        subprocess.run([
            "xcrun", "clang", "-fobjc-arc",
            "-target", "arm64-apple-ios16.0-macabi",
            "-isysroot", sdk,
            "-framework", "Foundation",
            str(src_p), "-o", str(bin_p),
        ], check=True)
        run = subprocess.run([str(bin_p)], capture_output=True, text=True, check=False)
        assert run.returncode == 0 and "NOTIFICATION_GUARD_OK" in run.stdout, (
            f"Notification guard test failed (rc={run.returncode}): {run.stdout} {run.stderr}"
        )
    print("PASS: notification-recursion-guard")


def run_skylight_prewarm_repro_test() -> None:
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()

    # Exact reproduction of NetEase Cloud Music's LC_LOAD_DYLIB order:
    #   [1] PreloadStub.dylib (Foundation only) -> +load calls NSClassFromString + dispatch_async -> UIView
    #   [2] UIKit.framework
    #   [Last] MockPlayTools.dylib (DYLD_INTERPOSE on NSClassFromString + dispatch_async)
    preload_src = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

static dispatch_semaphore_t gDone = nil;

@interface PTReproPreloadStub : NSObject
@end
@implementation PTReproPreloadStub
+ (void)load {
    gDone = dispatch_semaphore_create(0);
    // Exact NetEase pattern: +load calls NSClassFromString + dispatch_async -> UIView without blocking +load on semaphore
    Class nsObj = NSClassFromString(@"NSObject");
    (void)nsObj;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        Class cls = NSClassFromString(@"UIView");
        (void)[cls self];
        dispatch_semaphore_signal(gDone);
    });
    usleep(50000);
}
@end

void pt_wait_preload_done(void) {
    if (gDone) dispatch_semaphore_wait(gDone, DISPATCH_TIME_FOREVER);
}
'''
    mock_pt_src = r'''
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <stdatomic.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

static atomic_bool pt_skylight_prewarmed = ATOMIC_VAR_INIT(false);
static os_unfair_lock pt_skylight_prewarm_lock = OS_UNFAIR_LOCK_INIT;
static __thread BOOL pt_in_skylight_prewarm = NO;

static void pt_ensure_skylight_prewarmed(void) {
    if (atomic_load_explicit(&pt_skylight_prewarmed, memory_order_acquire) || pt_in_skylight_prewarm) {
        return;
    }
    os_unfair_lock_lock(&pt_skylight_prewarm_lock);
    if (!atomic_load_explicit(&pt_skylight_prewarmed, memory_order_relaxed) && !pt_in_skylight_prewarm) {
        pt_in_skylight_prewarm = YES;
        void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (handle) dlclose(handle);
        atomic_store_explicit(&pt_skylight_prewarmed, true, memory_order_release);
        pt_in_skylight_prewarm = NO;
    }
    os_unfair_lock_unlock(&pt_skylight_prewarm_lock);
}

void *pt_NSClassFromString(void *aClassName) {
    pt_ensure_skylight_prewarmed();
    return (__bridge void *)NSClassFromString((__bridge NSString *)aClassName);
}

void pt_dispatch_async(void *queue, void *block) {
    pt_ensure_skylight_prewarmed();
    dispatch_async((__bridge dispatch_queue_t)queue, (__bridge dispatch_block_t)block);
}

DYLD_INTERPOSE(pt_NSClassFromString, NSClassFromString)
DYLD_INTERPOSE(pt_dispatch_async, dispatch_async)

__attribute__((constructor))
static void pt_mock_init(void) {
    atomic_store_explicit(&pt_skylight_prewarmed, true, memory_order_release);
}
'''
    main_src = r'''
#import <UIKit/UIKit.h>
#import <stdio.h>
extern void pt_wait_preload_done(void);
int main(void) {
    pt_wait_preload_done();
    (void)[UIView class];
    printf("SKYLIGHT_PREWARM_OK\n");
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix="pt-sky-test-") as tmp:
        t = Path(tmp)
        (t / "preload.m").write_text(preload_src, encoding="utf-8")
        (t / "mockpt.m").write_text(mock_pt_src, encoding="utf-8")
        (t / "main.m").write_text(main_src, encoding="utf-8")

        common = [
            "xcrun", "clang", "-fobjc-arc",
            "-target", "arm64-apple-ios16.0-macabi",
            "-isysroot", sdk,
            "-isystem", f"{sdk}/System/iOSSupport/usr/include",
            "-iframework", f"{sdk}/System/iOSSupport/System/Library/Frameworks",
        ]
        subprocess.run(common + [
            "-dynamiclib", "-framework", "Foundation",
            "-install_name", "@executable_path/libPreload.dylib",
            str(t / "preload.m"), "-o", str(t / "libPreload.dylib"),
        ], check=True)
        subprocess.run(common + [
            "-dynamiclib", "-framework", "Foundation",
            "-install_name", "@executable_path/libMockPT.dylib",
            str(t / "mockpt.m"), "-o", str(t / "libMockPT.dylib"),
        ], check=True)
        subprocess.run(common + [
            str(t / "main.m"),
            str(t / "libPreload.dylib"),
            "-framework", "UIKit", "-framework", "Foundation",
            "-o", str(t / "repro_unguarded"),
        ], check=True)
        subprocess.run(common + [
            str(t / "main.m"),
            str(t / "libPreload.dylib"),
            "-framework", "UIKit", "-framework", "Foundation",
            str(t / "libMockPT.dylib"),
            "-o", str(t / "repro_guarded"),
        ], check=True)

        bad = subprocess.run([str(t / "repro_unguarded")], capture_output=True, text=True, check=False, timeout=10)
        assert bad.returncode == -5, f"Expected pre-main SIGTRAP (-5) without prewarm, got rc={bad.returncode}: {bad.stderr}"

        good = subprocess.run([str(t / "repro_guarded")], capture_output=True, text=True, check=False, timeout=10)
        assert good.returncode == 0 and "SKYLIGHT_PREWARM_OK" in good.stdout, (
            f"Guarded launch failed (rc={good.returncode}): {good.stdout} {good.stderr}"
        )
    print("PASS: skylight-prewarm-interpose-last-dylib-order")


def run_nsclassfromstring_arc_reentry_test() -> None:
    """Verify ARC-returning pt_NSClassFromString traps on uninitialized SubClass (+initialize dispatch_once),
    while pure C void* pt_NSClassFromString completes cleanly without triggering SubClass +initialize."""
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    arc_interpose_src = r'''
#import <Foundation/Foundation.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

Class pt_NSClassFromString(NSString *aClassName) {
    return NSClassFromString(aClassName);
}
DYLD_INTERPOSE(pt_NSClassFromString, NSClassFromString)
'''
    voidptr_interpose_src = r'''
#import <Foundation/Foundation.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

void *pt_NSClassFromString(void *aClassName) {
    return (__bridge void *)NSClassFromString((__bridge NSString *)aClassName);
}
DYLD_INTERPOSE(pt_NSClassFromString, NSClassFromString)
'''
    main_src = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <stdio.h>
#import <stdlib.h>

static int gInitCallCount = 0;
static BOOL gSubClassLookupSucceeded = NO;

@interface PTReentrySuper : NSObject
@end

@interface PTReentrySub : PTReentrySuper
@end

@implementation PTReentrySuper
+ (void)initialize {
    if (self == [PTReentrySuper class] || self == [PTReentrySub class]) {
        gInitCallCount++;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            Class sub = NSClassFromString(@"PTReentrySub");
            if (sub != Nil) {
                unsigned int mcount = 0;
                Method *methods = class_copyMethodList(object_getClass(sub), &mcount);
                free(methods);
                gSubClassLookupSucceeded = YES;
            }
        });
    }
}
@end

@implementation PTReentrySub
@end

int main(void) {
    @autoreleasepool {
        (void)[PTReentrySuper self];
        if (!gSubClassLookupSucceeded || gInitCallCount != 1) {
            fprintf(stderr, "Unexpected state: ok=%d initCount=%d\n", gSubClassLookupSucceeded, gInitCallCount);
            return 2;
        }
        printf("ARC_REENTRY_OK\n");
    }
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix="pt-arc-reentry-") as tmp:
        t = Path(tmp)
        (t / "arc_interpose.m").write_text(arc_interpose_src, encoding="utf-8")
        (t / "void_interpose.m").write_text(voidptr_interpose_src, encoding="utf-8")
        (t / "main.m").write_text(main_src, encoding="utf-8")

        common = [
            "xcrun", "clang", "-fobjc-arc",
            "-target", "arm64-apple-ios16.0-macabi",
            "-isysroot", sdk,
        ]
        subprocess.run(common + [
            "-dynamiclib", "-framework", "Foundation",
            "-install_name", "@executable_path/libArcInterpose.dylib",
            str(t / "arc_interpose.m"), "-o", str(t / "libArcInterpose.dylib"),
        ], check=True)
        subprocess.run(common + [
            "-dynamiclib", "-framework", "Foundation",
            "-install_name", "@executable_path/libVoidInterpose.dylib",
            str(t / "void_interpose.m"), "-o", str(t / "libVoidInterpose.dylib"),
        ], check=True)
        subprocess.run(common + [
            str(t / "main.m"), "-framework", "Foundation",
            str(t / "libArcInterpose.dylib"),
            "-o", str(t / "test_arc_bug"),
        ], check=True)
        subprocess.run(common + [
            str(t / "main.m"), "-framework", "Foundation",
            str(t / "libVoidInterpose.dylib"),
            "-o", str(t / "test_void_fix"),
        ], check=True)

        bad = subprocess.run([str(t / "test_arc_bug")], capture_output=True, text=True, check=False, timeout=10)
        assert bad.returncode == -5, f"Expected SIGTRAP (-5) from ARC NSClassFromString reentry, got rc={bad.returncode}: {bad.stderr}"

        good = subprocess.run([str(t / "test_void_fix")], capture_output=True, text=True, check=False, timeout=10)
        assert good.returncode == 0 and "ARC_REENTRY_OK" in good.stdout, (
            f"Expected void* NSClassFromString to avoid SubClass +initialize reentry (rc={good.returncode}): {good.stdout} {good.stderr}"
        )
    print("PASS: nsclassfromstring-voidptr-no-arc-reentry")


def run_os_version_string_ascii_guard_test() -> None:
    """Verify operatingSystemVersionString ASCII fallback prevents NULL cStringUsingEncoding(1) crashes."""
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    test_src = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <assert.h>
#import <stdio.h>
#import <string.h>

typedef NSString * (*str_fn)(id, SEL);
static str_fn origFn = NULL;

static NSString *pt_testFormatASCII(NSProcessInfo *procInfo, NSString *orig) {
    if (orig && orig.length > 0 && [orig canBeConvertedToEncoding:NSASCIIStringEncoding]) {
        return orig;
    }
    NSOperatingSystemVersion ver = procInfo.operatingSystemVersion;
    NSMutableString *formatted = (ver.patchVersion == 0)
        ? [NSMutableString stringWithFormat:@"Version %ld.%ld",
           (long)ver.majorVersion, (long)ver.minorVersion]
        : [NSMutableString stringWithFormat:@"Version %ld.%ld.%ld",
           (long)ver.majorVersion, (long)ver.minorVersion, (long)ver.patchVersion];
    char buildBuf[64] = {0};
    size_t buildLen = sizeof(buildBuf);
    if (sysctlbyname("kern.osversion", buildBuf, &buildLen, NULL, 0) == 0 && buildBuf[0] != '\0') {
        buildBuf[sizeof(buildBuf) - 1] = '\0';
        BOOL asciiBuild = YES;
        for (size_t i = 0; buildBuf[i] != '\0'; i++) {
            unsigned char ch = (unsigned char)buildBuf[i];
            if (ch < 0x20 || ch >= 0x7f) { asciiBuild = NO; break; }
        }
        if (asciiBuild) {
            [formatted appendFormat:@" (Build %s)", buildBuf];
        }
    }
    return [formatted copy];
}

@interface PTMockProcessInfo : NSObject
@property (nonatomic, assign) NSOperatingSystemVersion operatingSystemVersion;
@property (nonatomic, copy) NSString *mockVersionString;
@end
@implementation PTMockProcessInfo
- (NSString *)operatingSystemVersionString {
    return self.mockVersionString;
}
@end

static NSString *hookedVersionString(id self, SEL _cmd) {
    NSString *orig = origFn ? origFn(self, _cmd) : nil;
    return pt_testFormatASCII((NSProcessInfo *)self, orig);
}

int main(void) {
    @autoreleasepool {
        // 1. Reproduce CouchbaseLite crash condition on localized Chinese macOS string
        NSString *zhStr = @"\u7248\u672c27.2.1\uff08\u7248\u53f726B131\uff09";
        assert([zhStr cStringUsingEncoding:NSASCIIStringEncoding] == NULL);

        // 2. Hook mock processInfo and verify ASCII conversion succeeds
        Method m = class_getInstanceMethod([PTMockProcessInfo class], @selector(operatingSystemVersionString));
        origFn = (str_fn)method_getImplementation(m);
        class_replaceMethod([PTMockProcessInfo class], @selector(operatingSystemVersionString), (IMP)hookedVersionString, method_getTypeEncoding(m));

        PTMockProcessInfo *p1 = [PTMockProcessInfo new];
        p1.operatingSystemVersion = (NSOperatingSystemVersion){27, 2, 1};
        p1.mockVersionString = zhStr;
        NSString *res1 = [p1 operatingSystemVersionString];
        const char *c1 = [res1 cStringUsingEncoding:NSASCIIStringEncoding];
        assert(c1 != NULL && strncmp(c1, "Version 27.2.1", 14) == 0);

        // 3. Patch == 0 omits trailing .0
        PTMockProcessInfo *p2 = [PTMockProcessInfo new];
        p2.operatingSystemVersion = (NSOperatingSystemVersion){27, 2, 0};
        p2.mockVersionString = zhStr;
        NSString *res2 = [p2 operatingSystemVersionString];
        const char *c2 = [res2 cStringUsingEncoding:NSASCIIStringEncoding];
        assert(c2 != NULL && strncmp(c2, "Version 27.2", 12) == 0 && strncmp(c2, "Version 27.2.0", 14) != 0);

        // 4. ASCII original passes through untouched
        PTMockProcessInfo *p3 = [PTMockProcessInfo new];
        p3.operatingSystemVersion = (NSOperatingSystemVersion){27, 2, 1};
        p3.mockVersionString = @"Version 27.2.1 (Build TEST123)";
        assert([[p3 operatingSystemVersionString] isEqualToString:@"Version 27.2.1 (Build TEST123)"]);

        // 5. Real NSProcessInfo guarded check
        NSString *liveASCII = pt_testFormatASCII([NSProcessInfo processInfo], zhStr);
        assert([liveASCII canBeConvertedToEncoding:NSASCIIStringEncoding]);
        assert([liveASCII cStringUsingEncoding:NSASCIIStringEncoding] != NULL);
        printf("OS_VER_ASCII_GUARD_OK\n");
    }
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix="pt-osver-ascii-") as tmp:
        t = Path(tmp)
        (t / "test_osver.m").write_text(test_src, encoding="utf-8")
        subprocess.run([
            "xcrun", "clang", "-fobjc-arc",
            "-target", "arm64-apple-ios16.0-macabi",
            "-isysroot", sdk,
            "-framework", "Foundation",
            str(t / "test_osver.m"), "-o", str(t / "test_osver"),
        ], check=True)
        out = subprocess.check_output([str(t / "test_osver")], text=True, timeout=10)
        assert "OS_VER_ASCII_GUARD_OK" in out, f"Unexpected test output: {out}"
    print("PASS: os-version-string-ascii-guard")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-only", action="store_true", help="Skip built xcframework binary checks")
    args = parser.parse_args()

    root = resolve_root()
    check_source_contracts(root)
    if not args.source_only:
        check_built_slices(root)
    run_coremotion_runtime_test()
    run_notification_recursion_test()
    run_skylight_prewarm_repro_test()
    run_nsclassfromstring_arc_reentry_test()
    run_os_version_string_ascii_guard_test()
    print("ALL launch crash guard checks PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
