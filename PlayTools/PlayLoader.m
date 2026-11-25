//
//  PlayLoader.m
//  PlayTools
//

#include <Foundation/Foundation.h>
#include <errno.h>
#include <limits.h>
#include <stdatomic.h>
#include <sys/sysctl.h>

#import "PlayLoader.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <PlayTools/PlayTools-Swift.h>
#import <sys/utsname.h>
#import "NSObject+Swizzle.h"
#import <dlfcn.h>
#import <ifaddrs.h>
#import <libkern/OSCacheControl.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stddef.h>
#import <sys/stat.h>
#import <unistd.h>

@import CFNetwork;
@import MachO;

#ifndef PF_ROUTE
#define PF_ROUTE 17
#endif
#ifndef NET_RT_IFLIST2
#define NET_RT_IFLIST2 6
#endif
#ifndef RTM_IFINFO2
#define RTM_IFINFO2 0x12
#endif
#define PT_IF_MSGHDR_SIZE 112
#define PT_IF_MSGHDR2_SIZE 160
struct pt_if_msghdr_prefix {
    uint16_t ifm_msglen;
    uint8_t ifm_version;
    uint8_t ifm_type;
};
_Static_assert(sizeof(struct pt_if_msghdr_prefix) == 4, "pt_if_msghdr_prefix must match if_msghdr header prefix");

extern uint32_t dyld_get_active_platform(void);

typedef struct {
    uint32_t platform;
    uint32_t version;
} pt_build_version_t;

extern bool _availability_version_check(uint32_t count, const pt_build_version_t versions[]);

static atomic_bool pt_use_native_platform = ATOMIC_VAR_INIT(false);

static BOOL pt_tencentVideoIsOnMacPlatform(id self, SEL cmd) {
    return NO;
}

static void pt_installTencentVideoPhoneNavigation(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.tencent.live4iphone"]) {
        return;
    }

    // This SDK caches the host platform before PlayTools can reliably adjust it.
    // Select phone navigation at the SDK's layout check and leave UIKit's host platform intact.
    Class cls = objc_lookUpClass("VBBaseCoreUtils");
    SEL selector = sel_registerName("isOnMacPlatform");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (method && method_getNumberOfArguments(method) == 2) {
        char returnType[8];
        method_getReturnType(method, returnType, sizeof(returnType));
        if (strcmp(returnType, @encode(BOOL)) == 0) {
            class_replaceMethod(object_getClass(cls), selector, (IMP)pt_tencentVideoIsOnMacPlatform,
                                method_getTypeEncoding(method));
        }
    }
}

// Cache device model / OEM ID / blockSleepSpamming once in C storage so hot
// libc interpose paths (sysctl/sysctlbyname/uname/usleep) avoid ObjC messaging.

static os_unfair_lock pt_settings_cache_lock = OS_UNFAIR_LOCK_INIT;
static char pt_cached_device_model_buf[128] = "iPhone19,4";
static size_t pt_cached_device_model_len = 10;
static char pt_cached_oem_id_buf[64] = "J320xAP";
static size_t pt_cached_oem_id_len = 7;
static atomic_bool pt_device_cache_ready = ATOMIC_VAR_INIT(false);
static atomic_bool pt_block_sleep_cache_ready = ATOMIC_VAR_INIT(false);
static atomic_bool pt_block_sleep_spamming_val = ATOMIC_VAR_INIT(false);
static __thread BOOL pt_in_settings_lookup = NO;

static void pt_ensure_device_settings_cached(void) {
    if (atomic_load_explicit(&pt_device_cache_ready, memory_order_acquire) || pt_in_settings_lookup) {
        return;
    }
    pt_in_settings_lookup = YES;
    NSString *model = [[PlaySettings shared] deviceModel];
    NSString *oem = [[PlaySettings shared] oemID];
    const char *modelUtf8 = [model UTF8String];
    const char *oemUtf8 = [oem UTF8String];
    os_unfair_lock_lock(&pt_settings_cache_lock);
    if (!atomic_load_explicit(&pt_device_cache_ready, memory_order_relaxed)) {
        if (modelUtf8 && modelUtf8[0] != '\0') {
            strlcpy(pt_cached_device_model_buf, modelUtf8, sizeof(pt_cached_device_model_buf));
            pt_cached_device_model_len = strlen(pt_cached_device_model_buf);
        }
        if (oemUtf8 && oemUtf8[0] != '\0') {
            strlcpy(pt_cached_oem_id_buf, oemUtf8, sizeof(pt_cached_oem_id_buf));
            pt_cached_oem_id_len = strlen(pt_cached_oem_id_buf);
        }
        atomic_store_explicit(&pt_device_cache_ready, true, memory_order_release);
    }
    os_unfair_lock_unlock(&pt_settings_cache_lock);
    pt_in_settings_lookup = NO;
}

static BOOL pt_should_block_sleep_spamming(void) {
    if (atomic_load_explicit(&pt_block_sleep_cache_ready, memory_order_acquire)) {
        return atomic_load_explicit(&pt_block_sleep_spamming_val, memory_order_relaxed);
    }
    if (pt_in_settings_lookup) {
        return NO;
    }
    pt_in_settings_lookup = YES;
    BOOL val = [[PlaySettings shared] blockSleepSpamming];
    atomic_store_explicit(&pt_block_sleep_spamming_val, val ? true : false, memory_order_relaxed);
    atomic_store_explicit(&pt_block_sleep_cache_ready, true, memory_order_release);
    pt_in_settings_lookup = NO;
    return val;
}

#define PT_INTERPOSE_EXPORT __attribute__((visibility("default"), used))

PT_INTERPOSE_EXPORT int pt_uname(struct utsname *uts);
PT_INTERPOSE_EXPORT int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1);
PT_INTERPOSE_EXPORT int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
PT_INTERPOSE_EXPORT void *pt_dlsym(void *handle, const char *symbol);
PT_INTERPOSE_EXPORT CFDictionaryRef pt_CFNetworkCopySystemProxySettings(void);
PT_INTERPOSE_EXPORT CFArrayRef pt_CFNetworkCopyProxiesForURL(CFURLRef url, CFDictionaryRef proxySettings);
PT_INTERPOSE_EXPORT int pt_getifaddrs(struct ifaddrs **ifap);
PT_INTERPOSE_EXPORT void pt_freeifaddrs(struct ifaddrs *ifa);

typedef int (*pt_uname_fn)(struct utsname *);
typedef int (*pt_sysctl_fn)(int *, u_int, void *, size_t *, void *, size_t);
typedef int (*pt_sysctlbyname_fn)(const char *, void *, size_t *, void *, size_t);
typedef uint32_t (*pt_active_platform_fn)(void);
typedef void *(*pt_dlsym_fn)(void *, const char *);
typedef int (*pt_getifaddrs_fn)(struct ifaddrs **);
typedef void (*pt_freeifaddrs_fn)(struct ifaddrs *);
typedef bool (*pt_availability_version_check_fn)(uint32_t, const pt_build_version_t []);
PT_INTERPOSE_EXPORT uint32_t pt_active_platform(void);
PT_INTERPOSE_EXPORT bool pt_availability_version_check(uint32_t count, const pt_build_version_t versions[]);

// Declare interposes before wrapper bodies so every wrapper can call the
// dyld-bound original pointer directly from __DATA_CONST,__interpose via
// DYLD_INTERPOSE_ORIG without emitting __got/__la_symbol_ptr stubs that
// runtime fishhook/rebind_symbols hooks could turn into mutual recursion.
DYLD_INTERPOSE(pt_uname, uname)
DYLD_INTERPOSE(pt_sysctlbyname, sysctlbyname)
DYLD_INTERPOSE(pt_sysctl, sysctl)
DYLD_INTERPOSE(pt_active_platform, dyld_get_active_platform)
DYLD_INTERPOSE(pt_dlsym, dlsym)
DYLD_INTERPOSE(pt_CFNetworkCopySystemProxySettings, CFNetworkCopySystemProxySettings)
DYLD_INTERPOSE(pt_CFNetworkCopyProxiesForURL, CFNetworkCopyProxiesForURL)
DYLD_INTERPOSE(pt_getifaddrs, getifaddrs)
DYLD_INTERPOSE(pt_freeifaddrs, freeifaddrs)
DYLD_INTERPOSE(pt_availability_version_check, _availability_version_check)

#if TARGET_OS_MACCATALYST
typedef int (*pt_atexit_fn)(void (*)(void));
typedef const struct mach_header *(*pt_dyld_image_header_fn)(const void *);
extern int __cxa_atexit(void (*func)(void *), void *arg, void *dso_handle);
PT_INTERPOSE_EXPORT int pt_atexit(void (*func)(void));
DYLD_INTERPOSE(pt_atexit, atexit)
#endif

#define PT_MARKETPLACEKIT_PATH "/System/Library/Frameworks/MarketplaceKit.framework/MarketplaceKit"

static bool pt_caller_weak_links_marketplacekit(const void *caller) {
    Dl_info info;
    if (!dladdr(caller, &info) || !info.dli_fbase) {
        return false;
    }
    const struct mach_header_64 *header = info.dli_fbase;
    if (header->magic != MH_MAGIC_64) {
        return false;
    }

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    size_t remaining = header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds && remaining >= sizeof(struct load_command); i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > remaining || command->cmdsize % 8 != 0) {
            return false;
        }
        if (command->cmd == LC_LOAD_WEAK_DYLIB && command->cmdsize >= sizeof(struct dylib_command)) {
            const struct dylib_command *dylib = (const struct dylib_command *)command;
            uint32_t offset = dylib->dylib.name.offset;
            if (offset >= sizeof(*dylib) && offset <= command->cmdsize
                && command->cmdsize - offset >= sizeof(PT_MARKETPLACEKIT_PATH)
                && memcmp(cursor + offset, PT_MARKETPLACEKIT_PATH, sizeof(PT_MARKETPLACEKIT_PATH)) == 0) {
                return true;
            }
        }
        remaining -= command->cmdsize;
        cursor += command->cmdsize;
    }
    return false;
}

static bool pt_marketplacekit_loaded(void) {
    static bool loaded = false;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(PT_MARKETPLACEKIT_PATH, RTLD_LAZY | RTLD_NOLOAD);
        if (!handle) {
            handle = dlopen("/System/iOSSupport" PT_MARKETPLACEKIT_PATH, RTLD_LAZY | RTLD_NOLOAD);
        }
        if (handle) {
            dlclose(handle);
            loaded = true;
        } else if (DYLD_INTERPOSE_ORIG(pt_dlsym_fn, dlsym)(RTLD_DEFAULT, "$s14MarketplaceKit14AppDistributorOMn") != NULL) {
            loaded = true;
        }
    });
    return loaded;
}

PT_INTERPOSE_EXPORT bool pt_availability_version_check(uint32_t count, const pt_build_version_t versions[]) {
    // MarketplaceKit's AppDistributor was introduced in iOS 17.4. Catalyst can
    // report that version as available even when the weak framework is absent.
    // Scope the fallback from upstream PlayTools #238 to that specific query.
    const uint32_t appDistributorVersion = 0x00110400;
    if (count == 1 && versions && versions[0].platform == PLATFORM_IOS
        && versions[0].version == appDistributorVersion
        && DYLD_INTERPOSE_ORIG(pt_active_platform_fn, dyld_get_active_platform)() == PLATFORM_MACCATALYST
        && !pt_marketplacekit_loaded()
        && pt_caller_weak_links_marketplacekit(__builtin_return_address(0))) {
        return false;
    }
    return DYLD_INTERPOSE_ORIG(pt_availability_version_check_fn, _availability_version_check)(count, versions);
}

PT_INTERPOSE_EXPORT void *pt_dlsym(void *handle, const char *symbol) {
    pt_dlsym_fn orig_dlsym = DYLD_INTERPOSE_ORIG(pt_dlsym_fn, dlsym);
    static __thread BOOL pt_in_gles_dlsym = NO;
    if (!pt_in_gles_dlsym && symbol != NULL &&
        symbol[0] == 'g' && symbol[1] == 'l' && symbol[2] >= 'A' && symbol[2] <= 'Z') {
        BOOL shouldRedirect = (handle == RTLD_DEFAULT);
        if (!shouldRedirect &&
            handle != NULL &&
            handle != RTLD_NEXT &&
            handle != RTLD_SELF &&
            handle != RTLD_MAIN_ONLY) {
            static _Atomic(uintptr_t) pt_desktopGLHandle = 0;
            uintptr_t handleVal = (uintptr_t)handle;
            uintptr_t cached = atomic_load_explicit(&pt_desktopGLHandle, memory_order_relaxed);
            if (handleVal == cached) {
                shouldRedirect = YES;
            } else {
                pt_in_gles_dlsym = YES;
                // Desktop libGL.dylib exports immediate-mode glBegin, while iOS/Catalyst OpenGLES.framework does not.
                void *glBeginSym = orig_dlsym(handle, "glBegin");
                pt_in_gles_dlsym = NO;
                if (glBeginSym != NULL) {
                    atomic_store_explicit(&pt_desktopGLHandle, handleVal, memory_order_relaxed);
                    shouldRedirect = YES;
                }
            }
        }
        if (shouldRedirect) {
            pt_in_gles_dlsym = YES;
            static void *glesHandle = NULL;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                glesHandle = dlopen("/System/iOSSupport/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY | RTLD_LOCAL);
            });
            void *sym = NULL;
            if (glesHandle != NULL) {
                sym = orig_dlsym(glesHandle, symbol);
            }
            pt_in_gles_dlsym = NO;
            if (sym != NULL) {
                return sym;
            }
        }
    }
    return orig_dlsym(handle, symbol);
}

#if TARGET_OS_MACCATALYST
static void pt_atexit_trampoline(void *arg) {
    void (*fn)(void) = (void (*)(void))arg;
    if (fn) {
        fn();
    }
}

/// Fast `atexit` interpose for Mac Catalyst.
/// Apple's `libsystem_c` `atexit(fn)` calls `dladdr(fn, &info)` solely to obtain
/// `info.dli_fbase`, forcing `dyld` to linearly scan millions of `nlist` symbols
/// (for example in Unreal-based apps like AnTuTu Benchmark) on every C++ static
/// initializer. Resolving the Mach-O header via `dyld_image_header_containing_address`
/// and delegating directly to `__cxa_atexit` preserves exact `atexit` semantics in O(images).
PT_INTERPOSE_EXPORT int pt_atexit(void (*func)(void)) {
    if (!func) {
        return DYLD_INTERPOSE_ORIG(pt_atexit_fn, atexit)(func);
    }
    static pt_dyld_image_header_fn header_fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *disable = getenv("PLAYTOOLS_DISABLE_FAST_ATEXIT");
        if (disable && disable[0] == '1' && disable[1] == '\0') {
            return;
        }
        pt_dlsym_fn orig_dlsym = DYLD_INTERPOSE_ORIG(pt_dlsym_fn, dlsym);
        header_fn = (pt_dyld_image_header_fn)orig_dlsym(RTLD_DEFAULT, "dyld_image_header_containing_address");
    });
    if (!header_fn) {
        return DYLD_INTERPOSE_ORIG(pt_atexit_fn, atexit)(func);
    }
    void *dso_handle = (void *)header_fn((const void *)func);
    return __cxa_atexit(pt_atexit_trampoline, (void *)func, dso_handle);
}
#endif

// Hand Catalyst apps the iOS view of the host network: un-VPN'd iOS devices do
// not expose macOS HTTP/SOCKS system proxies or desktop tunnel interfaces
// (utun*, ppp*, ipsec*, etc.), which third-party risk-control SDKs inspect.
static BOOL shouldHideInterface(const char *name, size_t maxLen) {
    if (!name || maxLen == 0) return NO;
    char buf[32];
    size_t n = maxLen < sizeof(buf) - 1 ? maxLen : sizeof(buf) - 1;
    memcpy(buf, name, n);
    buf[n] = '\0';
    return strncmp(buf, "utun", 4) == 0 ||
           strncmp(buf, "ppp", 3) == 0 ||
           strncmp(buf, "ipsec", 5) == 0 ||
           strncmp(buf, "tap", 3) == 0 ||
           strncmp(buf, "tun", 3) == 0 ||
           strncmp(buf, "gpd", 3) == 0;
}

PT_INTERPOSE_EXPORT CFDictionaryRef pt_CFNetworkCopySystemProxySettings(void) {
    return CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                              &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

PT_INTERPOSE_EXPORT CFArrayRef pt_CFNetworkCopyProxiesForURL(CFURLRef url, CFDictionaryRef proxySettings) {
    (void)url;
    (void)proxySettings;
    const void *keys[] = { kCFProxyTypeKey };
    const void *values[] = { kCFProxyTypeNone };
    CFDictionaryRef direct = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef result = CFArrayCreate(kCFAllocatorDefault, (const void **)&direct, 1, &kCFTypeArrayCallBacks);
    CFRelease(direct);
    return result;
}

typedef struct {
    struct ifaddrs *returnedHead;
    struct ifaddrs *realHead;
} IfaddrsAllocEntry;

static os_unfair_lock gIfaddrsLock = OS_UNFAIR_LOCK_INIT;
static IfaddrsAllocEntry gIfaddrsMap[64];

static void recordIfaddrsHead(struct ifaddrs *returnedHead, struct ifaddrs *realHead) {
    if (returnedHead == realHead) return;
    os_unfair_lock_lock(&gIfaddrsLock);
    for (int i = 0; i < 64; i++) {
        if (gIfaddrsMap[i].returnedHead == NULL) {
            gIfaddrsMap[i].returnedHead = returnedHead;
            gIfaddrsMap[i].realHead = realHead;
            break;
        }
    }
    os_unfair_lock_unlock(&gIfaddrsLock);
}

static struct ifaddrs *consumeRealIfaddrsHead(struct ifaddrs *returnedHead) {
    struct ifaddrs *realHead = returnedHead;
    os_unfair_lock_lock(&gIfaddrsLock);
    for (int i = 0; i < 64; i++) {
        if (gIfaddrsMap[i].returnedHead == returnedHead) {
            realHead = gIfaddrsMap[i].realHead;
            gIfaddrsMap[i].returnedHead = NULL;
            gIfaddrsMap[i].realHead = NULL;
            break;
        }
    }
    os_unfair_lock_unlock(&gIfaddrsLock);
    return realHead;
}

PT_INTERPOSE_EXPORT int pt_getifaddrs(struct ifaddrs **ifap) {
    int r = DYLD_INTERPOSE_ORIG(pt_getifaddrs_fn, getifaddrs)(ifap);
    if (r != 0 || ifap == NULL || *ifap == NULL) return r;

    struct ifaddrs *realHead = *ifap;
    struct ifaddrs *newHead = realHead;
    struct ifaddrs *prev = NULL;
    struct ifaddrs *cur = realHead;
    while (cur) {
        struct ifaddrs *next = cur->ifa_next;
        if (cur->ifa_name && shouldHideInterface(cur->ifa_name, strlen(cur->ifa_name))) {
            if (prev) {
                prev->ifa_next = next;
            } else {
                newHead = next;
            }
            cur->ifa_next = NULL;
        } else {
            prev = cur;
        }
        cur = next;
    }
    *ifap = newHead;
    if (newHead != NULL && newHead != realHead) {
        recordIfaddrsHead(newHead, realHead);
    } else if (newHead == NULL && realHead != NULL) {
        DYLD_INTERPOSE_ORIG(pt_freeifaddrs_fn, freeifaddrs)(realHead);
    }
    return r;
}

PT_INTERPOSE_EXPORT void pt_freeifaddrs(struct ifaddrs *ifa) {
    if (!ifa) return;
    struct ifaddrs *realHead = consumeRealIfaddrsHead(ifa);
    DYLD_INTERPOSE_ORIG(pt_freeifaddrs_fn, freeifaddrs)(realHead);
}

PT_INTERPOSE_EXPORT uint32_t pt_active_platform(void) {
    if (atomic_load_explicit(&pt_use_native_platform, memory_order_relaxed)) {
        return DYLD_INTERPOSE_ORIG(pt_active_platform_fn, dyld_get_active_platform)();
    }
    return PLATFORM_IOS;
}
// Change the machine output by uname to match expected output on iOS
PT_INTERPOSE_EXPORT int pt_uname(struct utsname *uts) {
    int r = DYLD_INTERPOSE_ORIG(pt_uname_fn, uname)(uts);
    if (r != 0 || uts == NULL) {
        return r;
    }
    pt_ensure_device_settings_cached();
    strncpy(uts->machine, pt_cached_device_model_buf, sizeof(uts->machine) - 1);
    uts->machine[sizeof(uts->machine) - 1] = '\0';
    return 0;
}


// Update output of sysctl for key values hw.machine, hw.product and hw.target to match iOS output
// This spoofs the device type to apps allowing us to report as any iOS device
PT_INTERPOSE_EXPORT int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
    if (name != NULL && types >= 2 && size != NULL && name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE || name[1] == HW_PRODUCT) {
            pt_ensure_device_settings_cached();
            size_t needed = pt_cached_device_model_len + 1;
            if (buf == NULL) {
                *size = needed;
                return 0;
            }
            if (*size < needed) {
                *size = needed;
                errno = ENOMEM;
                return -1;
            }
            memcpy(buf, pt_cached_device_model_buf, needed);
            *size = needed;
            return 0;
        } else if (name[1] == HW_TARGET) {
            pt_ensure_device_settings_cached();
            size_t needed = pt_cached_oem_id_len + 1;
            if (buf == NULL) {
                *size = needed;
                return 0;
            }
            if (*size < needed) {
                *size = needed;
                errno = ENOMEM;
                return -1;
            }
            memcpy(buf, pt_cached_oem_id_buf, needed);
            *size = needed;
            return 0;
        }
    }

    int r = DYLD_INTERPOSE_ORIG(pt_sysctl_fn, sysctl)(name, types, buf, size, arg0, arg1);
    if (r != 0 || buf == NULL || name == NULL || size == NULL) return r;
    if (!(types >= 5 && name[0] == CTL_NET && name[1] == PF_ROUTE && name[4] == NET_RT_IFLIST2)) return r;

    uint8_t *base = (uint8_t *)buf;
    size_t total = *size;
    size_t out = 0;
    size_t off = 0;
    BOOL hideCurrentIf = NO;
    while (off + sizeof(struct pt_if_msghdr_prefix) <= total) {
        struct pt_if_msghdr_prefix *hdr = (struct pt_if_msghdr_prefix *)(base + off);
        if (hdr->ifm_msglen < sizeof(struct pt_if_msghdr_prefix) || off + hdr->ifm_msglen > total) break;
        if (hdr->ifm_type == RTM_IFINFO2 && hdr->ifm_msglen >= PT_IF_MSGHDR2_SIZE + sizeof(struct sockaddr_dl)) {
            struct sockaddr_dl *sdl = (struct sockaddr_dl *)((uint8_t *)hdr + PT_IF_MSGHDR2_SIZE);
            size_t maxData = hdr->ifm_msglen - PT_IF_MSGHDR2_SIZE - offsetof(struct sockaddr_dl, sdl_data);
            size_t nlen = sdl->sdl_nlen < maxData ? sdl->sdl_nlen : maxData;
            hideCurrentIf = shouldHideInterface(sdl->sdl_data, nlen);
        }
        if (hideCurrentIf) {
            off += hdr->ifm_msglen;
            continue;
        }
        if (out != off) memmove(base + out, base + off, hdr->ifm_msglen);
        out += hdr->ifm_msglen;
        off += hdr->ifm_msglen;
    }
    *size = out;
    return r;
}

PT_INTERPOSE_EXPORT int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name != NULL && oldlenp != NULL) {
        if ((strcmp(name, "hw.machine") == 0) || (strcmp(name, "hw.product") == 0) || (strcmp(name, "hw.model") == 0)) {
            pt_ensure_device_settings_cached();
            size_t needed = pt_cached_device_model_len + 1;
            if (oldp == NULL) {
                *oldlenp = needed;
                return 0;
            }
            if (*oldlenp < needed) {
                *oldlenp = needed;
                errno = ENOMEM;
                return -1;
            }
            memcpy(oldp, pt_cached_device_model_buf, needed);
            *oldlenp = needed;
            return 0;
        } else if (strcmp(name, "hw.target") == 0) {
            pt_ensure_device_settings_cached();
            size_t needed = pt_cached_oem_id_len + 1;
            if (oldp == NULL) {
                *oldlenp = needed;
                return 0;
            }
            if (*oldlenp < needed) {
                *oldlenp = needed;
                errno = ENOMEM;
                return -1;
            }
            memcpy(oldp, pt_cached_oem_id_buf, needed);
            *oldlenp = needed;
            return 0;
        }
    }
    return DYLD_INTERPOSE_ORIG(pt_sysctlbyname_fn, sysctlbyname)(name, oldp, oldlenp, newp, newlen);
}

// Same-image calls to the public symbols bypass their replacements. The opt-in
// self-test uses these entry points to verify the values handed to other images.
__attribute__((visibility("hidden")))
uint32_t pt_selftest_platform(char *unameMachine, char *sysctlMachine) {
    struct utsname information;
    if (pt_uname(&information) == 0) {
        strlcpy(unameMachine, information.machine, 256);
    }
    size_t length = 256;
    pt_sysctlbyname("hw.machine", sysctlMachine, &length, NULL, 0);
    return pt_active_platform();
}

// Interpose Apple Keychain functions (SecItemCopyMatching, SecItemAdd, SecItemUpdate, SecItemDelete)
// This allows us to intercept keychain requests and return our own data

typedef OSStatus (*pt_SecItemCopyMatching_fn)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*pt_SecItemAdd_fn)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*pt_SecItemUpdate_fn)(CFDictionaryRef, CFDictionaryRef);
typedef OSStatus (*pt_SecItemDelete_fn)(CFDictionaryRef);
typedef SecKeyRef (*pt_SecKeyCreateRandomKey_fn)(CFDictionaryRef, CFErrorRef *);
typedef OSStatus (*pt_SecKeyGeneratePair_fn)(CFDictionaryRef, SecKeyRef *, SecKeyRef *);

PT_INTERPOSE_EXPORT OSStatus pt_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result);
PT_INTERPOSE_EXPORT OSStatus pt_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result);
PT_INTERPOSE_EXPORT OSStatus pt_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
PT_INTERPOSE_EXPORT OSStatus pt_SecItemDelete(CFDictionaryRef query);
PT_INTERPOSE_EXPORT SecKeyRef pt_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error);
PT_INTERPOSE_EXPORT OSStatus pt_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey);

DYLD_INTERPOSE(pt_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(pt_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(pt_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(pt_SecItemDelete, SecItemDelete)
DYLD_INTERPOSE(pt_SecKeyCreateRandomKey, SecKeyCreateRandomKey)
DYLD_INTERPOSE(pt_SecKeyGeneratePair, SecKeyGeneratePair)

// Use the implementations from PlayKeychain
PT_INTERPOSE_EXPORT OSStatus pt_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain copyMatching:(__bridge NSDictionary * _Nonnull)(query) result:result];
    } else {
        retval = DYLD_INTERPOSE_ORIG(pt_SecItemCopyMatching_fn, SecItemCopyMatching)(query, result);
    }
    if (result != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching: %@", query]];
            [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching result: %@", *result]];
        }
    }
    return retval;
}

PT_INTERPOSE_EXPORT OSStatus pt_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain add:(__bridge NSDictionary * _Nonnull)(attributes) result:result];
    } else {
        retval = DYLD_INTERPOSE_ORIG(pt_SecItemAdd_fn, SecItemAdd)(attributes, result);
    }
    if (result != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemAdd: %@", attributes]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemAdd result: %@", *result]];
        }
    }
    return retval;
}

PT_INTERPOSE_EXPORT OSStatus pt_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain update:(__bridge NSDictionary * _Nonnull)(query) attributesToUpdate:(__bridge NSDictionary * _Nonnull)(attributesToUpdate)];
    } else {
        retval = DYLD_INTERPOSE_ORIG(pt_SecItemUpdate_fn, SecItemUpdate)(query, attributesToUpdate);
    }
    if (attributesToUpdate != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemUpdate: %@", query]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemUpdate attributesToUpdate: %@", attributesToUpdate]];
        }
    }
    return retval;

}

PT_INTERPOSE_EXPORT OSStatus pt_SecItemDelete(CFDictionaryRef query) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain delete:(__bridge NSDictionary * _Nonnull)(query)];
    } else {
        retval = DYLD_INTERPOSE_ORIG(pt_SecItemDelete_fn, SecItemDelete)(query);
    }
    if ([[PlaySettings shared] playChainDebugging]) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemDelete: %@", query]];
    }
    return retval;
}

PT_INTERPOSE_EXPORT SecKeyRef pt_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    SecKeyRef result;
    if ([[PlaySettings shared] playChain]) {
        result = [PlayKeychain keyCreateRandomKey:(__bridge NSDictionary * _Nonnull)(parameters) error:error];
    } else {
        result = DYLD_INTERPOSE_ORIG(pt_SecKeyCreateRandomKey_fn, SecKeyCreateRandomKey)(parameters, error);
    }
    
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey: %@", parameters]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey result: %@", result]];
        }
    
    return result;
}

// Deprecated, but some apps might still use it.
PT_INTERPOSE_EXPORT OSStatus pt_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain keyGeneratePair:(__bridge NSDictionary * _Nonnull)(parameters) publicKey:(void *)publicKey privateKey:(void *)privateKey];
    } else {
        retval = DYLD_INTERPOSE_ORIG(pt_SecKeyGeneratePair_fn, SecKeyGeneratePair)(parameters, publicKey, privateKey);
    }
    
    if ([[PlaySettings shared] playChainDebugging]) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair: %@", parameters]];
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair public key result: %@", publicKey != NULL ? *publicKey : nil]];
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair private key result: %@", privateKey != NULL ? *privateKey : nil]];
    }
    
    return retval;
}

static uint8_t ue_status = 0;
static char UE_PATTERN[1024] = "//Users/";
static BOOL ue_pattern_ready = NO;

static void init_ue_pattern(void) {
    if (ue_pattern_ready) return;
    if (getlogin_r(UE_PATTERN + 8, sizeof(UE_PATTERN) - 8) == 0 && UE_PATTERN[8] != '\0') {
        ue_pattern_ready = YES;
    }
}

static char const* ue_fix_filename(char const* filename) {
    // Only rewrite Unreal Engine paths, and never call getlogin_r here: crash reporters
    // like Heimdallr suspend threads while invoking rename/open, which deadlocks on
    // libsystem_c's internal getlogin mutex if any suspended thread holds it.
    if (ue_status != 2 || !ue_pattern_ready || !filename) {
        return filename;
    }

    char const* p = filename;
    char const* last_p = p;
    while ((p = strstr(p, UE_PATTERN))) {
        last_p = ++p;
    }
    return last_p;
}

typedef int (*pt_open_fn)(char const* restrict, int, ...);
typedef int (*pt_stat_fn)(char const* restrict, struct stat* restrict);
typedef int (*pt_access_fn)(char const*, int);
typedef int (*pt_rename_fn)(char const* restrict, char const* restrict);
typedef int (*pt_unlink_fn)(char const*);
typedef int (*pt_usleep_fn)(useconds_t);

PT_INTERPOSE_EXPORT int pt_open(char const* restrict filename, int oflag, ...);
PT_INTERPOSE_EXPORT int pt_stat(char const* restrict path, struct stat* restrict buf);
PT_INTERPOSE_EXPORT int pt_access(char const* path, int mode);
PT_INTERPOSE_EXPORT int pt_rename(char const* restrict old_name, char const* restrict new_name);
PT_INTERPOSE_EXPORT int pt_unlink(char const* path);
PT_INTERPOSE_EXPORT int pt_usleep(useconds_t time);

DYLD_INTERPOSE(pt_open, open)
DYLD_INTERPOSE(pt_stat, stat)
DYLD_INTERPOSE(pt_access, access)
DYLD_INTERPOSE(pt_rename, rename)
DYLD_INTERPOSE(pt_unlink, unlink)
DYLD_INTERPOSE(pt_usleep, usleep)

PT_INTERPOSE_EXPORT int pt_open(char const* restrict filename, int oflag, ... ) {
    filename = ue_fix_filename(filename);
    pt_open_fn orig_fn = DYLD_INTERPOSE_ORIG(pt_open_fn, open);

    if (oflag & O_CREAT) {
        int mod;
        va_list ap;
        va_start(ap, oflag);
        mod = va_arg(ap, int);
        va_end(ap);

        return orig_fn(filename, oflag, mod);
    }

    return orig_fn(filename, oflag);
}

PT_INTERPOSE_EXPORT int pt_stat(char const* restrict path, struct stat* restrict buf) {
    return DYLD_INTERPOSE_ORIG(pt_stat_fn, stat)(ue_fix_filename(path), buf);
}

PT_INTERPOSE_EXPORT int pt_access(char const* path, int mode) {
    return DYLD_INTERPOSE_ORIG(pt_access_fn, access)(ue_fix_filename(path), mode);
}

PT_INTERPOSE_EXPORT int pt_rename(char const* restrict old_name, char const* restrict new_name) {
    return DYLD_INTERPOSE_ORIG(pt_rename_fn, rename)(ue_fix_filename(old_name), ue_fix_filename(new_name));
}

PT_INTERPOSE_EXPORT int pt_unlink(char const* path) {
    return DYLD_INTERPOSE_ORIG(pt_unlink_fn, unlink)(ue_fix_filename(path));
}

static NSMutableDictionary *thread_sleep_counters = nil;
static NSMutableDictionary *last_sleep_attempts = nil;
static dispatch_once_t thread_sleep_once;
static NSLock *thread_sleep_lock = nil;

PT_INTERPOSE_EXPORT int pt_usleep(useconds_t time) {
    if (pt_should_block_sleep_spamming()) {
        dispatch_once(&thread_sleep_once, ^{
            thread_sleep_counters = [NSMutableDictionary dictionary];
            last_sleep_attempts = [NSMutableDictionary dictionary];
            thread_sleep_lock = [[NSLock alloc] init];
            [thread_sleep_lock lock];
        });

        int thread_id = pthread_mach_thread_np(pthread_self());
        NSNumber *threadKey = @(thread_id);

        BOOL exceeded_sleep_limit = NO;
        @synchronized (thread_sleep_counters) {
            int thread_sleep_counter = [thread_sleep_counters[threadKey] intValue];
            int last_sleep_attempt = [last_sleep_attempts[threadKey] intValue];

            if (time == 100000) {
                int timestamp = (int)[[NSDate date] timeIntervalSince1970];
                // If it sleeps too fast, increase counter
                if (timestamp - last_sleep_attempt < 2) {
                    thread_sleep_counter++;
                } else {
                    thread_sleep_counter = 1;
                }
                last_sleep_attempt = timestamp;
                thread_sleep_counters[threadKey] = @(thread_sleep_counter);
                last_sleep_attempts[threadKey] = @(last_sleep_attempt);
            }

            exceeded_sleep_limit = thread_sleep_counter > 100;
        }

        if (exceeded_sleep_limit) {
            // Stop this thread from spamming usleep calls
            NSLog(@"[PC] Thread %i exceeded usleep limit. Seem sus, stopping this "
                  @"thread FOREVER",
                  thread_id);
            
            [thread_sleep_lock lock];
            [thread_sleep_lock unlock];
            
            return 0;
        }
    }
    
    return DYLD_INTERPOSE_ORIG(pt_usleep_fn, usleep)(time);
}

#pragma mark - Universal Catalyst Compatibility & Anti-Tamper Guards

typedef struct {
    uintptr_t addr;
    uint32_t insn;
} pt_inline_patch_t;

// Neutralize raw inline `svc #0x80` exit stubs inside FirebaseNIMessInstallation
// when that module is loaded (no-op for apps that do not ship it).
static int pt_patchFirebaseInlineExits(void) {
    static const uint32_t exitRetPat[4] = { 0xd2800000, 0x52800030, 0xd4001001, 0xd65f03c0 };
    static const uint32_t exitClobberPat[4] = { 0xd2800000, 0x52800030, 0xd4001001, 0xd2800001 };

    pt_inline_patch_t patches[64];
    size_t patchCount = 0;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count && patchCount < 64; i++) {
        const char *imgName = _dyld_get_image_name(i);
        if (!imgName || strstr(imgName, "FirebaseNIMessInstallation") == NULL) continue;

        const struct mach_header *rawHdr = _dyld_get_image_header(i);
        if (!rawHdr || rawHdr->magic != MH_MAGIC_64) continue;
        const struct mach_header_64 *hdr = (const struct mach_header_64 *)rawHdr;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        const uint8_t *cursor = (const uint8_t *)(hdr + 1);
        for (uint32_t c = 0; c < hdr->ncmds && patchCount < 64; c++) {
            const struct load_command *lc = (const struct load_command *)cursor;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                if ((seg->initprot & VM_PROT_EXECUTE) && seg->filesize >= 16) {
                    uintptr_t textStart = (uintptr_t)seg->vmaddr + (uintptr_t)slide;
                    uintptr_t textEnd = textStart + (uintptr_t)seg->vmsize;
                    for (uintptr_t addr = textStart; addr + 16 <= textEnd && patchCount < 64; addr += 4) {
                        const uint32_t *w = (const uint32_t *)addr;
                        if (w[0] == exitRetPat[0] && w[1] == exitRetPat[1] &&
                            w[2] == exitRetPat[2] && w[3] == exitRetPat[3]) {
                            patches[patchCount++] = (pt_inline_patch_t){ addr + 8, 0xd503201f };
                        } else if (w[0] == exitClobberPat[0] && w[1] == exitClobberPat[1] &&
                                   w[2] == exitClobberPat[2] && w[3] == exitClobberPat[3]) {
                            patches[patchCount++] = (pt_inline_patch_t){ addr + 8, 0xd65f03c0 };
                        }
                    }
                }
            }
            cursor += lc->cmdsize;
        }
    }

    if (patchCount == 0) {
        return 0;
    }

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;
    thread_t selfThread = mach_thread_self();
    kern_return_t tr = task_threads(mach_task_self(), &threads, &threadCount);
    if (tr == KERN_SUCCESS && threads != NULL) {
        for (mach_msg_type_number_t t = 0; t < threadCount; t++) {
            if (threads[t] != selfThread) {
                thread_suspend(threads[t]);
            }
        }
    }

    int totalPatched = 0;
    vm_size_t pageSz = vm_page_size;
    for (size_t idx = 0; idx < patchCount; idx++) {
        pt_inline_patch_t p = patches[idx];
        vm_address_t page = p.addr & ~(pageSz - 1);
        kern_return_t kr = vm_protect(mach_task_self(), page, pageSz, FALSE,
                                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr == KERN_SUCCESS) {
            *(uint32_t *)p.addr = p.insn;
            vm_protect(mach_task_self(), page, pageSz, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
            sys_icache_invalidate((void *)p.addr, sizeof(uint32_t));
            totalPatched++;
        }
    }

    if (tr == KERN_SUCCESS && threads != NULL) {
        for (mach_msg_type_number_t t = 0; t < threadCount; t++) {
            if (threads[t] != selfThread) {
                thread_resume(threads[t]);
            }
            mach_port_deallocate(mach_task_self(), threads[t]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads, threadCount * sizeof(thread_act_t));
    }
    mach_port_deallocate(mach_task_self(), selfThread);

    return totalPatched;
}

static IMP pt_origRegisterForRemoteNotifications;
static os_unfair_lock pt_remoteRegLock = OS_UNFAIR_LOCK_INIT;
static CFTimeInterval pt_lastRemoteRegTime = 0;

static BOOL pt_shouldThrottleRemoteRegistration(void) {
    static BOOL missingPushEntitlements = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        typedef CFTypeRef (*CreateTask)(CFAllocatorRef);
        typedef CFDictionaryRef (*CopyEntitlements)(CFTypeRef, CFArrayRef, CFErrorRef *);
        CreateTask createTask = (CreateTask)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
        CopyEntitlements copyEntitlements = (CopyEntitlements)dlsym(RTLD_DEFAULT, "SecTaskCopyValuesForEntitlements");
        if (!createTask || !copyEntitlements) {
            return;
        }
        CFTypeRef task = createTask(kCFAllocatorDefault);
        if (!task) {
            return;
        }
        NSArray<NSString *> *keys = @[@"aps-environment", @"com.apple.developer.aps-environment"];
        CFDictionaryRef entitlements = copyEntitlements(task, (__bridge CFArrayRef)keys, NULL);
        if (entitlements) {
            missingPushEntitlements = CFDictionaryGetCount(entitlements) == 0;
            CFRelease(entitlements);
        }
        CFRelease(task);
    });
    return missingPushEntitlements;
}

static BOOL pt_allowUnentitledRemoteRegistration(void) {
    CFTimeInterval now = CACurrentMediaTime();
    BOOL allow = NO;
    os_unfair_lock_lock(&pt_remoteRegLock);
    if (pt_lastRemoteRegTime == 0 || (now - pt_lastRemoteRegTime) >= 30.0) {
        pt_lastRemoteRegTime = now;
        allow = YES;
    }
    os_unfair_lock_unlock(&pt_remoteRegLock);
    return allow;
}

static void pt_registerForRemoteNotifications(id self, SEL _cmd) {
    // Keep the retry-loop guard for confirmed unentitled processes. UIKit owns
    // provisioning validation and callbacks whenever the signing state is unknown.
    if (pt_shouldThrottleRemoteRegistration() && !pt_allowUnentitledRemoteRegistration()) {
        return;
    }
    if (pt_origRegisterForRemoteNotifications) {
        ((void (*)(id, SEL))pt_origRegisterForRemoteNotifications)(self, _cmd);
    }
}

static IMP pt_origPostNotification;
static os_unfair_lock pt_notiLock = OS_UNFAIR_LOCK_INIT;
static CFAbsoluteTime pt_lastCheckNotiTime = 0;

static void pt_postNotificationName(id self, SEL _cmd, NSNotificationName name, id obj, NSDictionary *userInfo) {
    if ([name isKindOfClass:[NSString class]] &&
        [(NSString *)name isEqualToString:@"kJPUSHCheckNotiAuthNotification"]) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        BOOL allow = NO;
        os_unfair_lock_lock(&pt_notiLock);
        if (pt_lastCheckNotiTime == 0 || (now - pt_lastCheckNotiTime) >= 10.0) {
            pt_lastCheckNotiTime = now;
            allow = YES;
        }
        os_unfair_lock_unlock(&pt_notiLock);
        if (!allow) return;
    }
    if (pt_origPostNotification) {
        ((void (*)(id, SEL, id, id, id))pt_origPostNotification)(self, _cmd, name, obj, userInfo);
    }
}

static BOOL pt_shouldSuppressRiskBannerText(id text) {
    if (![text isKindOfClass:[NSString class]]) return NO;
    NSString *lower = [(NSString *)text lowercaseString];
    return [lower containsString:@"hooking"] ||
           [lower containsString:@"proxy detected"] ||
           [lower containsString:@"integrity"] ||
           [lower containsString:@"compromise"] ||
           [lower containsString:@"re-download"] ||
           [lower containsString:@"official"] ||
           [lower containsString:@"tamper"] ||
           [lower containsString:@"数据安全风险"];
}

static IMP pt_origSetMessageText;
static void pt_setMessageText(id self, SEL _cmd, id text) {
    if (pt_shouldSuppressRiskBannerText(text)) {
        return;
    }
    if (pt_origSetMessageText) {
        ((void (*)(id, SEL, id))pt_origSetMessageText)(self, _cmd, text);
    }
}

static IMP pt_origPendJetPrinterOperation;
static void pt_pendJetPrinterOperation(id self, SEL _cmd, id msg, double duration) {
    if (pt_shouldSuppressRiskBannerText(msg)) {
        return;
    }
    if (pt_origPendJetPrinterOperation) {
        ((void (*)(id, SEL, id, double))pt_origPendJetPrinterOperation)(self, _cmd, msg, duration);
    }
}

static void pt_installRiskBannerHooks(void) {
    Class mgr = objc_getClass("PrinterPlatformizationManger");
    if (mgr && !pt_origPendJetPrinterOperation) {
        Method m = class_getInstanceMethod(mgr, sel_registerName("pendJetPrinterOperation:duration:"));
        if (m) {
            pt_origPendJetPrinterOperation = method_getImplementation(m);
            if (pt_origPendJetPrinterOperation != (IMP)pt_pendJetPrinterOperation) {
                class_replaceMethod(mgr, sel_registerName("pendJetPrinterOperation:duration:"),
                                    (IMP)pt_pendJetPrinterOperation, method_getTypeEncoding(m));
            }
        }
    }
    Class impl = objc_getClass("PrinterPlatformizationMangerImpl");
    if (impl && !pt_origSetMessageText) {
        Method m = class_getInstanceMethod(impl, sel_registerName("setMessageText:"));
        if (m) {
            pt_origSetMessageText = method_getImplementation(m);
            if (pt_origSetMessageText != (IMP)pt_setMessageText) {
                class_replaceMethod(impl, sel_registerName("setMessageText:"),
                                    (IMP)pt_setMessageText, method_getTypeEncoding(m));
            }
        }
    }
}

static void pt_applyUIScaleFactor(void) {
    double uiScale = [[PlaySettings shared] uiScale];
    if (uiScale <= 0.0) {
        uiScale = 1.0;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (uiScale >= 0.76 && uiScale <= 0.78) {
        if ([defaults objectForKey:@"iOSMacScaleFactor"] != nil) {
            [defaults removeObjectForKey:@"iOSMacScaleFactor"];
        }
    } else {
        double targetScale = (uiScale >= 0.5 && uiScale <= 3.0) ? uiScale : 1.0;
        id existing = [defaults objectForKey:@"iOSMacScaleFactor"];
        if (![existing isKindOfClass:[NSNumber class]] || fabs([(NSNumber *)existing doubleValue] - targetScale) > 0.0001) {
            [defaults setDouble:targetScale forKey:@"iOSMacScaleFactor"];
        }
    }
    if ([defaults objectForKey:@"UINSLastUsedWindowScaleFactor"] != nil) {
        [defaults removeObjectForKey:@"UINSLastUsedWindowScaleFactor"];
    }
}

static void pt_installTerminationTimeoutHooks(void);
static void pt_installCloudKitCompatibilityHooks(void);

static BOOL pt_jpushNotiHookInstalled = NO;

static void pt_installJPushNotificationThrottleIfNeeded(void) {
    if (pt_jpushNotiHookInstalled || objc_getClass("JPUSHService") == Nil) {
        return;
    }
    Class nc = objc_getClass("NSNotificationCenter");
    if (nc) {
        Method m = class_getInstanceMethod(nc, @selector(postNotificationName:object:userInfo:));
        if (m) {
            pt_origPostNotification = method_getImplementation(m);
            class_replaceMethod(nc, @selector(postNotificationName:object:userInfo:),
                                (IMP)pt_postNotificationName, method_getTypeEncoding(m));
            pt_jpushNotiHookInstalled = YES;
        }
    }
}

static NSArray<NSString *> *(*pt_origFontNamesForFamilyName)(id, SEL, NSString *) = NULL;
static BOOL pt_fontNamesHookInstalled = NO;

static NSArray<NSString *> *pt_fontNamesForFamilyName(id self, SEL _cmd, NSString *familyName) {
    NSArray<NSString *> *result = pt_origFontNamesForFamilyName ? pt_origFontNamesForFamilyName(self, _cmd, familyName) : nil;
    return result ?: @[];
}

static NSHashTable<UIWindow *> *pt_pendingOrphanWindows = nil;
static BOOL pt_orphanWindowHooksInstalled = NO;
static const void *kPTOrphanWantedKeyKey = &kPTOrphanWantedKeyKey;
static void (*pt_origWindowMakeKeyAndVisible)(id, SEL) = NULL;
static void (*pt_origWindowSetHidden)(id, SEL, BOOL) = NULL;

static BOOL pt_isAppWindow(UIWindow *win) {
    if (!win) {
        return NO;
    }
    NSString *clsName = NSStringFromClass(object_getClass(win));
    if ([clsName hasPrefix:@"_UI"]) {
        return NO;
    }
    for (NSString *excluded in @[@"Keyboard", @"TextEffects", @"Snapshot", @"Menu", @"StatusBar", @"Input", @"EditorWindow"]) {
        if ([clsName containsString:excluded]) {
            return NO;
        }
    }
    return YES;
}

static BOOL pt_isEligibleOrphanWindow(UIWindow *win) {
    if (!pt_isAppWindow(win) || win.windowScene != nil) {
        return NO;
    }
    return (win.rootViewController != nil || win.subviews.count > 0);
}

static UIWindowScene *pt_activeApplicationWindowScene(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) {
        return nil;
    }
    UIWindowScene *inactiveCandidate = nil;
    UIWindowScene *fallbackCandidate = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *winScene = (UIWindowScene *)scene;
        if (![winScene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
            continue;
        }
        if (winScene.activationState == UISceneActivationStateForegroundActive) {
            return winScene;
        }
        if (!inactiveCandidate && winScene.activationState == UISceneActivationStateForegroundInactive) {
            inactiveCandidate = winScene;
        }
        if (!fallbackCandidate) {
            fallbackCandidate = winScene;
        }
    }
    return inactiveCandidate ?: fallbackCandidate;
}

static void pt_attachOrphanWindowToScene(UIWindow *win, UIWindowScene *scene, BOOL makeKey) {
    if (!win || !scene || win.windowScene != nil) {
        return;
    }
    win.windowScene = scene;
    CGRect sceneBounds = scene.coordinateSpace.bounds;
    if (!CGRectIsEmpty(sceneBounds) &&
        (CGRectIsEmpty(win.bounds) ||
         win.frame.size.width > sceneBounds.size.width + 1 ||
         win.frame.size.height > sceneBounds.size.height + 1)) {
        win.frame = sceneBounds;
    }
    if (makeKey && pt_origWindowMakeKeyAndVisible) {
        pt_origWindowMakeKeyAndVisible(win, @selector(makeKeyAndVisible));
    } else if (pt_origWindowSetHidden) {
        pt_origWindowSetHidden(win, @selector(setHidden:), NO);
    }
}

static void pt_recordPendingOrphanWindow(UIWindow *win, BOOL wantedKey) {
    if (!pt_pendingOrphanWindows) {
        pt_pendingOrphanWindows = [NSHashTable weakObjectsHashTable];
    }
    [pt_pendingOrphanWindows addObject:win];
    if (wantedKey) {
        objc_setAssociatedObject(win, kPTOrphanWantedKeyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void pt_windowMakeKeyAndVisible(UIWindow *self, SEL _cmd) {
    if (NSThread.isMainThread && self.windowScene == nil && pt_isEligibleOrphanWindow(self)) {
        UIWindowScene *scene = pt_activeApplicationWindowScene();
        if (scene) {
            pt_attachOrphanWindowToScene(self, scene, YES);
            return;
        } else {
            pt_recordPendingOrphanWindow(self, YES);
        }
    }
    if (pt_origWindowMakeKeyAndVisible) {
        pt_origWindowMakeKeyAndVisible(self, _cmd);
    }
}

static void pt_windowSetHidden(UIWindow *self, SEL _cmd, BOOL hidden) {
    if (NSThread.isMainThread && !hidden && self.windowScene == nil && pt_isEligibleOrphanWindow(self)) {
        UIWindowScene *scene = pt_activeApplicationWindowScene();
        if (scene) {
            pt_attachOrphanWindowToScene(self, scene, NO);
            return;
        } else {
            pt_recordPendingOrphanWindow(self, NO);
        }
    }
    if (pt_origWindowSetHidden) {
        pt_origWindowSetHidden(self, _cmd, hidden);
    }
}

static void pt_flushPendingOrphanWindowsForScene(UIWindowScene *scene) {
    if (!scene ||
        ![scene isKindOfClass:[UIWindowScene class]] ||
        ![scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication] ||
        pt_pendingOrphanWindows.count == 0) {
        return;
    }
    NSArray<UIWindow *> *pending = pt_pendingOrphanWindows.allObjects;
    pending = [pending sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel < b.windowLevel) {
            return NSOrderedAscending;
        }
        if (a.windowLevel > b.windowLevel) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    for (UIWindow *w in pending) {
        [pt_pendingOrphanWindows removeObject:w];
        if (!w.hidden && w.windowScene == nil && pt_isEligibleOrphanWindow(w)) {
            BOOL wantedKey = [objc_getAssociatedObject(w, kPTOrphanWantedKeyKey) boolValue];
            objc_setAssociatedObject(w, kPTOrphanWantedKeyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            pt_attachOrphanWindowToScene(w, scene, wantedKey);
        }
    }
}

static const void *kPTEmptySceneRecoveryScheduledKey = &kPTEmptySceneRecoveryScheduledKey;

static id pt_safeObjectFromTarget(id target, SEL sel, NSString *kvcKey) {
    if (!target) {
        return nil;
    }
    if (sel && [target respondsToSelector:sel]) {
        Method m = class_getInstanceMethod(object_getClass(target), sel);
        if (m) {
            char retType[16] = {0};
            method_getReturnType(m, retType, sizeof(retType));
            if (retType[0] == '@') {
                return ((id (*)(id, SEL))method_getImplementation(m))(target, sel);
            }
        }
        return nil;
    }
    if (kvcKey.length > 0) {
        @try {
            return [target valueForKey:kvcKey];
        } @catch (NSException * _unused) {
            (void)_unused;
        }
    }
    return nil;
}

static BOOL pt_sceneHasVisibleAppContent(UIWindowScene *scene) {
    for (UIWindow *w in scene.windows) {
        if (!pt_isAppWindow(w)) {
            continue;
        }
        if (!w.hidden && w.alpha > 0.01 && (w.rootViewController != nil || w.subviews.count > 0)) {
            return YES;
        }
    }
    return NO;
}

static UIWindow *pt_findPrimaryWindowForScene(UIWindowScene *scene, id<UIApplicationDelegate> delegate) {
    UIWindow *fallbackSceneWindow = nil;
    for (UIWindow *w in scene.windows) {
        if (!pt_isAppWindow(w)) {
            continue;
        }
        if (w.windowLevel == UIWindowLevelNormal) {
            return w;
        }
        if (!fallbackSceneWindow) {
            fallbackSceneWindow = w;
        }
    }
    if (fallbackSceneWindow) {
        return fallbackSceneWindow;
    }
    if (!delegate) {
        return nil;
    }
    if ([delegate respondsToSelector:@selector(window)]) {
        id winObj = pt_safeObjectFromTarget(delegate, @selector(window), nil);
        if ([winObj isKindOfClass:[UIWindow class]] && pt_isAppWindow((UIWindow *)winObj)) {
            return (UIWindow *)winObj;
        }
    }
    id mainWinObj = pt_safeObjectFromTarget(delegate, NSSelectorFromString(@"mainWindow"), @"mainWindow");
    if ([mainWinObj isKindOfClass:[UIWindow class]] && pt_isAppWindow((UIWindow *)mainWinObj)) {
        return (UIWindow *)mainWinObj;
    }
    return nil;
}

static void pt_recoverEmptySceneWindowIfNeeded(UIWindowScene *scene) {
    if (!scene ||
        ![scene isKindOfClass:[UIWindowScene class]] ||
        ![scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication] ||
        scene.activationState != UISceneActivationStateForegroundActive) {
        return;
    }
    if (pt_sceneHasVisibleAppContent(scene)) {
        return;
    }

    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    UIWindow *primaryWindow = pt_findPrimaryWindowForScene(scene, delegate);
    if (!primaryWindow) {
        return;
    }

    if (primaryWindow.rootViewController == nil && delegate) {
        UIViewController *vc = nil;
        NSArray<NSString *> *candidateKeys = @[@"appViewController", @"rootViewController", @"mainViewController"];
        for (NSString *key in candidateKeys) {
            SEL sel = NSSelectorFromString(key);
            NSString *kvcFallback = [key isEqualToString:@"appViewController"] ? key : nil;
            id obj = pt_safeObjectFromTarget(delegate, sel, kvcFallback);
            if ([obj isKindOfClass:[UIViewController class]]) {
                vc = (UIViewController *)obj;
                break;
            }
        }
        if (vc) {
            [UIView performWithoutAnimation:^{
                if (primaryWindow.windowScene == nil) {
                    primaryWindow.windowScene = scene;
                }
                primaryWindow.rootViewController = vc;
                if (!CGRectIsEmpty(scene.coordinateSpace.bounds) && CGRectIsEmpty(primaryWindow.bounds)) {
                    primaryWindow.frame = scene.coordinateSpace.bounds;
                }
                [primaryWindow makeKeyAndVisible];
            }];
            NSLog(@"[PlayTools] Empty scene window recovery: attached %@ to %@",
                  NSStringFromClass([vc class]),
                  NSStringFromClass([primaryWindow class]));
        }
    } else if (primaryWindow.rootViewController != nil && (primaryWindow.windowScene == nil || primaryWindow.hidden)) {
        [UIView performWithoutAnimation:^{
            if (primaryWindow.windowScene == nil) {
                primaryWindow.windowScene = scene;
            }
            if (!CGRectIsEmpty(scene.coordinateSpace.bounds) && CGRectIsEmpty(primaryWindow.bounds)) {
                primaryWindow.frame = scene.coordinateSpace.bounds;
            }
            [primaryWindow makeKeyAndVisible];
        }];
        NSLog(@"[PlayTools] Empty scene window recovery: revealed window %@ (root=%@)",
              NSStringFromClass([primaryWindow class]),
              NSStringFromClass([primaryWindow.rootViewController class]));
    }
}

static void pt_scheduleEmptySceneWindowRecoveryForScene(UIWindowScene *scene) {
    if (!scene ||
        ![scene isKindOfClass:[UIWindowScene class]] ||
        ![scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
        return;
    }
    if (objc_getAssociatedObject(scene, kPTEmptySceneRecoveryScheduledKey) != nil) {
        return;
    }
    objc_setAssociatedObject(scene, kPTEmptySceneRecoveryScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIWindowScene *weakScene = scene;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *strongScene = weakScene;
        if (!strongScene) {
            return;
        }
        objc_setAssociatedObject(strongScene, kPTEmptySceneRecoveryScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pt_recoverEmptySceneWindowIfNeeded(strongScene);
    });
}

#if TARGET_OS_MACCATALYST
static void (*pt_origPresentViewController)(UIViewController *, SEL, UIViewController *, BOOL, void (^)(void));
static CFTimeInterval pt_startupPresentationDeadline;
static char pt_deferredPresentationKey;

static UIViewController *pt_attachedStartupPresenter(UIViewController *presenter) {
    for (UIViewController *candidate = presenter; candidate; candidate = candidate.parentViewController) {
        UIWindow *window = candidate.viewIfLoaded.window;
        UIWindowScene *scene = window.windowScene;
        if (pt_isAppWindow(window) && !window.hidden && window.alpha > 0.01 &&
            (scene.activationState == UISceneActivationStateForegroundActive ||
             scene.activationState == UISceneActivationStateForegroundInactive) &&
            [scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
            return candidate;
        }
    }
    return nil;
}

static UIViewController *pt_visibleOrphanWindowPresenter(UIViewController *presenter) {
    for (UIViewController *candidate = presenter; candidate; candidate = candidate.parentViewController) {
        UIWindow *window = candidate.viewIfLoaded.window;
        if (pt_isAppWindow(window) && !window.hidden && window.alpha > 0.01 && window.windowScene == nil) {
            return candidate;
        }
    }
    return nil;
}

static void pt_waitForStartupPresenter(UIViewController *presenter, SEL command, UIViewController *destination,
                                       BOOL animated, void (^completion)(void), CFTimeInterval deadline) {
    __weak UIViewController *weakPresenter = presenter;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        UIViewController *source = weakPresenter;
        UIViewController *attached = pt_attachedStartupPresenter(source);
        if (source && !destination.presentingViewController && CACurrentMediaTime() < deadline) {
            if (!attached || attached.presentedViewController) {
                pt_waitForStartupPresenter(source, command, destination, animated, completion, deadline);
                return;
            }
            objc_setAssociatedObject(destination, &pt_deferredPresentationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            pt_origPresentViewController(attached, command, destination, animated, completion);
        } else {
            objc_setAssociatedObject(destination, &pt_deferredPresentationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (source && !destination.presentingViewController &&
                source.viewIfLoaded.window != nil && !source.presentedViewController) {
                pt_origPresentViewController(source, command, destination, animated, completion);
            }
        }
    });
}

static void pt_presentViewControllerAtStartup(UIViewController *self, SEL command, UIViewController *destination,
                                              BOOL animated, void (^completion)(void)) {
    CFTimeInterval now = CACurrentMediaTime();
    if (NSThread.isMainThread && destination && now < pt_startupPresentationDeadline) {
        if (objc_getAssociatedObject(destination, &pt_deferredPresentationKey)) { return; }
        if (!destination.presentingViewController && !pt_attachedStartupPresenter(self)) {
            if (pt_visibleOrphanWindowPresenter(self)) {
                // Dedicated overlay UIWindows created before UISceneWillConnectNotification expect synchronous
                // fullscreen modal attachment so bare host VCs do not fire viewDidAppear: prematurely.
                pt_origPresentViewController(self, command, destination, animated, completion);
                if (destination.presentingViewController || self.presentedViewController) {
                    return;
                }
            }
            // The app can request a modal before Catalyst attaches its first scene window.
            objc_setAssociatedObject(destination, &pt_deferredPresentationKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            pt_waitForStartupPresenter(self, command, destination, animated, completion, now + 3.5);
            return;
        }
    }
    pt_origPresentViewController(self, command, destination, animated, completion);
}

static void pt_installStartupPresentationGuard(void) {
    Method method = class_getInstanceMethod(UIViewController.class, @selector(presentViewController:animated:completion:));
    if (method) {
        pt_startupPresentationDeadline = CACurrentMediaTime() + 4.0;
        pt_origPresentViewController = (void *)method_setImplementation(method, (IMP)pt_presentViewControllerAtStartup);
    }
}
#endif

static void pt_installOrphanWindowSceneGuard(void) {
    if (pt_orphanWindowHooksInstalled) {
        return;
    }
    pt_orphanWindowHooksInstalled = YES;

    Class uiWindow = objc_getClass("UIWindow");
    if (uiWindow) {
        Method makeKeyM = class_getInstanceMethod(uiWindow, @selector(makeKeyAndVisible));
        if (makeKeyM) {
            IMP origImp = method_getImplementation(makeKeyM);
            if (origImp != (IMP)pt_windowMakeKeyAndVisible) {
                pt_origWindowMakeKeyAndVisible = (void (*)(id, SEL))origImp;
                class_replaceMethod(uiWindow, @selector(makeKeyAndVisible),
                                    (IMP)pt_windowMakeKeyAndVisible, method_getTypeEncoding(makeKeyM));
            }
        }
        Method setHiddenM = class_getInstanceMethod(uiWindow, @selector(setHidden:));
        if (setHiddenM) {
            IMP origImp = method_getImplementation(setHiddenM);
            if (origImp != (IMP)pt_windowSetHidden) {
                pt_origWindowSetHidden = (void (*)(id, SEL, BOOL))origImp;
                class_replaceMethod(uiWindow, @selector(setHidden:),
                                    (IMP)pt_windowSetHidden, method_getTypeEncoding(setHiddenM));
            }
        }
    }

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    void (^sceneHandler)(NSNotification * _Nonnull) = ^(NSNotification * _Nonnull note) {
        if ([note.object isKindOfClass:[UIWindowScene class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                pt_flushPendingOrphanWindowsForScene((UIWindowScene *)note.object);
            });
        }
    };
    [nc addObserverForName:UISceneWillConnectNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:sceneHandler];
    [nc addObserverForName:UISceneDidActivateNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification * _Nonnull note) {
        sceneHandler(note);
        if ([note.object isKindOfClass:[UIWindowScene class]]) {
            pt_scheduleEmptySceneWindowRecoveryForScene((UIWindowScene *)note.object);
        }
    }];
}

static NSURL *(*pt_origContainerURLForGroupIdentifier)(id, SEL, NSString *) = NULL;
static BOOL pt_appGroupHookInstalled = NO;

static BOOL pt_ensureWritableGroupDirectory(NSFileManager *manager, NSURL *url) {
    if (![url isKindOfClass:[NSURL class]] || !url.isFileURL || url.path.length == 0) {
        return NO;
    }

    NSString *path = url.path;
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&isDirectory]) {
        [manager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
        [manager fileExistsAtPath:path isDirectory:&isDirectory];
    }
    return isDirectory && access(path.fileSystemRepresentation, W_OK | X_OK) == 0;
}

static BOOL pt_isValidGroupIdentifier(NSString *groupIdentifier) {
    return [groupIdentifier isKindOfClass:[NSString class]] &&
           groupIdentifier.length > 0 &&
           ![groupIdentifier containsString:@"/"] &&
           ![groupIdentifier containsString:@".."] &&
           ![groupIdentifier isEqualToString:@"."] &&
           [groupIdentifier rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static NSURL * _Nullable pt_spaceFreeGroupRootURL(NSFileManager *manager) {
    NSURL *libraryURL = [manager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    if (![libraryURL isKindOfClass:[NSURL class]] || !libraryURL.isFileURL || libraryURL.path.length == 0) {
        return nil;
    }
    return [libraryURL URLByAppendingPathComponent:@"PlayCoverGroupContainers" isDirectory:YES];
}

static void pt_migrateLegacyGroupDirectoryIfUninitialized(NSFileManager *manager, NSURL *legacyURL, NSURL *targetURL) {
    if (!legacyURL || !targetURL) {
        return;
    }
    struct stat targetStat;
    if (lstat(targetURL.path.fileSystemRepresentation, &targetStat) == 0 || errno != ENOENT) {
        return;
    }

    BOOL legacyIsDir = NO;
    if (![manager fileExistsAtPath:legacyURL.path isDirectory:&legacyIsDir] || !legacyIsDir) {
        return;
    }

    NSURL *parentURL = [targetURL URLByDeletingLastPathComponent];
    if (!pt_ensureWritableGroupDirectory(manager, parentURL)) {
        return;
    }

    if (![manager moveItemAtURL:legacyURL toURL:targetURL error:nil]) {
        [manager copyItemAtURL:legacyURL toURL:targetURL error:nil];
    }
}

static NSURL * _Nullable pt_spaceFreeAliasForWritableGroupURL(NSFileManager *manager,
                                                               NSURL *origURL,
                                                               NSString *groupIdentifier) {
    NSURL *rootURL = pt_spaceFreeGroupRootURL(manager);
    NSURL *aliasURL = [rootURL URLByAppendingPathComponent:groupIdentifier isDirectory:YES];
    if (!aliasURL || [aliasURL.path containsString:@" "] || !pt_ensureWritableGroupDirectory(manager, rootURL)) {
        return nil;
    }

    NSString *aliasPath = aliasURL.path;
    NSString *destPath = origURL.path;
    struct stat st;
    if (lstat(aliasPath.fileSystemRepresentation, &st) == 0) {
        if (S_ISLNK(st.st_mode)) {
            NSString *existingDest = [manager destinationOfSymbolicLinkAtPath:aliasPath error:nil];
            if (![existingDest isEqualToString:destPath]) {
                [manager removeItemAtPath:aliasPath error:nil];
                [manager createSymbolicLinkAtPath:aliasPath withDestinationPath:destPath error:nil];
            }
        } else if (!S_ISDIR(st.st_mode)) {
            return nil;
        }
    } else if (errno == ENOENT) {
        [manager createSymbolicLinkAtPath:aliasPath withDestinationPath:destPath error:nil];
    } else {
        return nil;
    }

    return access(aliasPath.fileSystemRepresentation, W_OK | X_OK) == 0 ? aliasURL : nil;
}

static NSURL *pt_containerURLForGroupIdentifier(NSFileManager *self, SEL _cmd, NSString *groupIdentifier) {
    NSURL *origURL = pt_origContainerURLForGroupIdentifier ? pt_origContainerURLForGroupIdentifier(self, _cmd, groupIdentifier) : nil;
    if (!pt_isValidGroupIdentifier(groupIdentifier)) {
        return nil;
    }

    // Real iOS App Group containers (/private/var/mobile/Containers/Shared/AppGroup/<UUID>)
    // never contain spaces, so iOS apps frequently strip "file://" from url.absoluteString.
    // Provide a space-free Library/PlayCoverGroupContainers/<group> path to avoid "%20" SQLite failures.
    if (pt_ensureWritableGroupDirectory(self, origURL)) {
        if (![origURL.path containsString:@" "]) {
            return origURL;
        }
        NSURL *aliasURL = pt_spaceFreeAliasForWritableGroupURL(self, origURL, groupIdentifier);
        return aliasURL ?: origURL;
    }

    NSURL *fallbackRoot = pt_spaceFreeGroupRootURL(self);
    NSURL *fallbackURL = [fallbackRoot URLByAppendingPathComponent:groupIdentifier isDirectory:YES];
    if (fallbackURL && ![fallbackURL.path containsString:@" "]) {
        NSURL *appSupport = [self URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *legacyURL = [[appSupport URLByAppendingPathComponent:@"PlayCoverGroupContainers" isDirectory:YES]
            URLByAppendingPathComponent:groupIdentifier isDirectory:YES];
        pt_migrateLegacyGroupDirectoryIfUninitialized(self, legacyURL, fallbackURL);
        if (pt_ensureWritableGroupDirectory(self, fallbackURL)) {
            return fallbackURL;
        }
    }

    NSURL *appSupport = [self URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *legacyURL = [[appSupport URLByAppendingPathComponent:@"PlayCoverGroupContainers" isDirectory:YES]
        URLByAppendingPathComponent:groupIdentifier isDirectory:YES];
    return pt_ensureWritableGroupDirectory(self, legacyURL) ? legacyURL : nil;
}

static void pt_installAppGroupContainerGuard(void) {
    if (pt_appGroupHookInstalled) {
        return;
    }
    Class fmClass = objc_getClass("NSFileManager");
    if (!fmClass) {
        return;
    }
    SEL sel = @selector(containerURLForSecurityApplicationGroupIdentifier:);
    Method m = class_getInstanceMethod(fmClass, sel);
    if (!m) {
        return;
    }
    IMP origImp = method_getImplementation(m);
    if (origImp != (IMP)pt_containerURLForGroupIdentifier) {
        pt_origContainerURLForGroupIdentifier = (NSURL *(*)(id, SEL, NSString *))origImp;
        class_replaceMethod(fmClass, sel, (IMP)pt_containerURLForGroupIdentifier, method_getTypeEncoding(m));
    }
    pt_appGroupHookInstalled = YES;
}

static __thread NSInteger pt_safeAreaDidChangeDepth = 0;
static void (*pt_origSafeAreaInsetsDidChangeFromOldInsets)(id, SEL, UIEdgeInsets) = NULL;
static void (*pt_origViewLayoutBelowIfNeeded)(id, SEL) = NULL;
static BOOL pt_safeAreaLayoutGuardInstalled = NO;

static void pt_safeAreaInsetsDidChangeFromOldInsets(id self, SEL _cmd, UIEdgeInsets oldInsets) {
    pt_safeAreaDidChangeDepth++;
    @try {
        if (pt_origSafeAreaInsetsDidChangeFromOldInsets) {
            pt_origSafeAreaInsetsDidChangeFromOldInsets(self, _cmd, oldInsets);
        }
    } @finally {
        pt_safeAreaDidChangeDepth--;
    }
}

static void pt_viewLayoutBelowIfNeeded(UIView *self, SEL _cmd) {
    // Defer synchronous layoutBelowIfNeeded calls triggered during UIView's safe-area
    // propagation (e.g. viewDidMoveToWindow) so collection/table cells finish mounting
    // with valid layout constraints before sizing passes run.
    if (pt_safeAreaDidChangeDepth > 0 && [NSThread isMainThread]) {
        [self setNeedsLayout];
        return;
    }
    if (pt_origViewLayoutBelowIfNeeded) {
        pt_origViewLayoutBelowIfNeeded(self, _cmd);
    }
}

static void pt_installSafeAreaReentrantLayoutGuard(void) {
    if (pt_safeAreaLayoutGuardInstalled) {
        return;
    }
    Class uiView = objc_getClass("UIView");
    if (!uiView) {
        return;
    }

    SEL safeAreaSel = sel_registerName("_safeAreaInsetsDidChangeFromOldInsets:");
    Method safeAreaM = class_getInstanceMethod(uiView, safeAreaSel);
    SEL layoutSel = @selector(layoutBelowIfNeeded);
    Method layoutM = class_getInstanceMethod(uiView, layoutSel);
    if (!safeAreaM || !layoutM) {
        return;
    }

    IMP origSafeAreaImp = method_getImplementation(safeAreaM);
    if (origSafeAreaImp != (IMP)pt_safeAreaInsetsDidChangeFromOldInsets) {
        pt_origSafeAreaInsetsDidChangeFromOldInsets = (void (*)(id, SEL, UIEdgeInsets))origSafeAreaImp;
        class_replaceMethod(uiView, safeAreaSel, (IMP)pt_safeAreaInsetsDidChangeFromOldInsets, method_getTypeEncoding(safeAreaM));
    }

    IMP origLayoutImp = method_getImplementation(layoutM);
    if (origLayoutImp != (IMP)pt_viewLayoutBelowIfNeeded) {
        pt_origViewLayoutBelowIfNeeded = (void (*)(id, SEL))origLayoutImp;
        class_replaceMethod(uiView, layoutSel, (IMP)pt_viewLayoutBelowIfNeeded, method_getTypeEncoding(layoutM));
    }

    pt_safeAreaLayoutGuardInstalled = YES;
}

static BOOL pt_terminationWatchdogInstalled = NO;

static void pt_installTerminationWatchdog(void) {
    if (pt_terminationWatchdogInstalled) {
        return;
    }
    pt_terminationWatchdogInstalled = YES;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            // UIApplicationWillTerminateNotification is posted after UINSAppLifecycleStateTerminatingPastPointOfNoReturn.
            // If an app observer deadlocks (e.g. shutting down SDK mutexes), ensure the process terminates within 3s
            // so LaunchServices / PlayCover's launch queue cannot wedge waiting for it.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                _exit(0);
            });
        });
    }];
}

static _Atomic(bool) pt_playScreenScaledMode = false;

void pt_setPlayScreenScaledMode(BOOL isScaled) {
    atomic_store_explicit(&pt_playScreenScaledMode, isScaled ? true : false, memory_order_relaxed);
}

BOOL pt_isPlayScreenScaledMode(void) {
    return atomic_load_explicit(&pt_playScreenScaledMode, memory_order_relaxed) ? YES : NO;
}

static void (*pt_origVBLogTestedFaults)(id, SEL, const void *) = NULL;
static BOOL pt_vbFaultGuardInstalled = NO;
static id pt_vbBundleObserver = nil;
static id pt_vbLaunchObserver = nil;

static void pt_removeViewBridgeObservers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (pt_vbBundleObserver) {
        [nc removeObserver:pt_vbBundleObserver];
        pt_vbBundleObserver = nil;
    }
    if (pt_vbLaunchObserver) {
        [nc removeObserver:pt_vbLaunchObserver];
        pt_vbLaunchObserver = nil;
    }
}

static void pt_vbLogTestedFaults(id self, SEL _cmd, const void *timer) {
    // Some weak timer proxies call performSelector: without forwarding the timer.
    // Keep the argument opaque so ARC cannot retain an invalid object pointer.
    @try {
        pt_origVBLogTestedFaults(self, _cmd, timer);
    } @catch (NSException *exception) {
        if (![exception.name isEqualToString:NSInternalInconsistencyException] ||
            ![exception.reason containsString:@"timer == sTestedFaultsUnloggedTimer"]) {
            @throw;
        }
        // ViewBridge accepts a null timer when logging outside its timer callback.
        pt_origVBLogTestedFaults(self, _cmd, NULL);
    }
}

static void pt_tryInstallViewBridgeFaultGuardNow(void) {
    if (pt_vbFaultGuardInstalled) {
        pt_removeViewBridgeObservers();
        return;
    }
    Class cls = objc_getClass("NSVBNamedFault");
    Class meta = cls ? object_getClass(cls) : Nil;
    SEL sel = sel_registerName("logTestedFaults:");
    Method m = cls ? class_getClassMethod(cls, sel) : NULL;
    if (meta && m && method_getNumberOfArguments(m) == 3) {
        IMP origImp = method_getImplementation(m);
        if (origImp != (IMP)pt_vbLogTestedFaults) {
            pt_origVBLogTestedFaults = (void (*)(id, SEL, const void *))origImp;
            class_replaceMethod(meta, sel, (IMP)pt_vbLogTestedFaults, method_getTypeEncoding(m));
        }
        pt_vbFaultGuardInstalled = YES;
        pt_removeViewBridgeObservers();
    }
}

static void pt_installViewBridgeFaultGuard(void) {
    pt_tryInstallViewBridgeFaultGuardNow();
    if (!pt_vbFaultGuardInstalled) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        pt_vbBundleObserver = [nc addObserverForName:NSBundleDidLoadNotification
                                              object:nil
                                               queue:nil
                                          usingBlock:^(NSNotification * _Nonnull note) {
            pt_tryInstallViewBridgeFaultGuardNow();
        }];
        pt_vbLaunchObserver = [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                                              object:nil
                                               queue:nil
                                          usingBlock:^(NSNotification * _Nonnull note) {
            pt_tryInstallViewBridgeFaultGuardNow();
            if (pt_vbLaunchObserver) {
                [[NSNotificationCenter defaultCenter] removeObserver:pt_vbLaunchObserver];
                pt_vbLaunchObserver = nil;
            }
        }];
    }
}

static _Thread_local NSInteger pt_cvInitialSetFrameDepth = 0;
static void (*pt_origCollectionViewSetFrame)(id, SEL, CGRect) = NULL;
static CGRect (*pt_origCollectionViewContentRect)(id, SEL) = NULL;
static BOOL pt_cvInitialFrameGuardInstalled = NO;

static CGRect pt_collectionViewContentRect(id self, SEL _cmd) {
    if (pt_cvInitialSetFrameDepth > 0) {
        return CGRectZero;
    }
    return pt_origCollectionViewContentRect ? pt_origCollectionViewContentRect(self, _cmd) : CGRectZero;
}

static void pt_collectionViewSetFrame(UICollectionView *self, SEL _cmd, CGRect frame) {
    BOOL deferInitialLoad = NSThread.isMainThread &&
                            CGRectIsEmpty(self.bounds) &&
                            !CGRectIsEmpty(frame);
    if (deferInitialLoad) {
        pt_cvInitialSetFrameDepth++;
    }
    if (pt_origCollectionViewSetFrame) {
        pt_origCollectionViewSetFrame(self, _cmd, frame);
    }
    if (deferInitialLoad) {
        pt_cvInitialSetFrameDepth--;
        [self setNeedsLayout];
    }
}

static void pt_installCollectionViewInitialFrameGuard(void) {
    if (pt_cvInitialFrameGuardInstalled) {
        return;
    }
    Class cvClass = objc_getClass("UICollectionView");
    Class cvDataClass = objc_getClass("UICollectionViewData");
    SEL setFrameSel = @selector(setFrame:);
    SEL contentRectSel = sel_registerName("collectionViewContentRect");
    Method setFrameM = cvClass ? class_getInstanceMethod(cvClass, setFrameSel) : NULL;
    Method contentRectM = cvDataClass ? class_getInstanceMethod(cvDataClass, contentRectSel) : NULL;
    if (setFrameM && contentRectM) {
        IMP origSetFrame = method_getImplementation(setFrameM);
        IMP origContentRect = method_getImplementation(contentRectM);
        if (origSetFrame != (IMP)pt_collectionViewSetFrame) {
            pt_origCollectionViewSetFrame = (void (*)(id, SEL, CGRect))origSetFrame;
            class_replaceMethod(cvClass, setFrameSel, (IMP)pt_collectionViewSetFrame, method_getTypeEncoding(setFrameM));
        }
        if (origContentRect != (IMP)pt_collectionViewContentRect) {
            pt_origCollectionViewContentRect = (CGRect (*)(id, SEL))origContentRect;
            class_replaceMethod(cvDataClass, contentRectSel, (IMP)pt_collectionViewContentRect, method_getTypeEncoding(contentRectM));
        }
        pt_cvInitialFrameGuardInstalled = YES;
    }
}

static void (*pt_origNavViewWillAppear)(id, SEL, BOOL) = NULL;
static BOOL pt_navAppearanceGuardInstalled = NO;

static void pt_navViewWillAppear(UINavigationController *self, SEL _cmd, BOOL animated) {
    // On Mac Catalyst initial root presentation (including empty-scene window recovery),
    // UIPresentationController can invoke viewWillAppear: with animated=YES while no
    // transitionCoordinator exists and the view is not yet in a window. UINavigationController
    // forwards animated=YES to navigationController:willShowViewController:animated:, whereas
    // viewDidAppear: later skips pairing it with didShowViewController:animated:, leaving apps
    // that lock UI during animated navigation transitions permanently non-interactive.
    BOOL effectiveAnimated = animated;
    if (effectiveAnimated &&
        self.transitionCoordinator == nil &&
        self.viewIfLoaded.window == nil) {
        effectiveAnimated = NO;
    }
    if (pt_origNavViewWillAppear) {
        pt_origNavViewWillAppear(self, _cmd, effectiveAnimated);
    }
}

static void pt_installNavigationAppearanceBalanceGuard(void) {
    if (pt_navAppearanceGuardInstalled) {
        return;
    }
    pt_navAppearanceGuardInstalled = YES;

    Class navCls = objc_getClass("UINavigationController");
    if (!navCls) {
        return;
    }
    Method m = class_getInstanceMethod(navCls, @selector(viewWillAppear:));
    if (m) {
        IMP origImp = method_getImplementation(m);
        if (origImp != (IMP)pt_navViewWillAppear) {
            pt_origNavViewWillAppear = (void (*)(id, SEL, BOOL))origImp;
            class_replaceMethod(navCls, @selector(viewWillAppear:),
                                (IMP)pt_navViewWillAppear, method_getTypeEncoding(m));
        }
    }
}

static id (*pt_origVisualEffectInitWithEffect)(id, SEL, id) = NULL;
static void (*pt_origVisualEffectSetEffect)(id, SEL, id) = NULL;
static void (*pt_origVisualEffectTraitCollectionDidChange)(id, SEL, UITraitCollection *) = NULL;
static void (*pt_origVisualEffectLayoutSubviews)(id, SEL) = NULL;
static void (*pt_origVisualEffectSetCornerConfiguration)(id, SEL, id) = NULL;
static Class pt_glassEffectClass = Nil;
static BOOL pt_glassEffectGuardInstalled = NO;
static const void *kPTAppliedGlassEffectKey = &kPTAppliedGlassEffectKey;
static const void *kPTAppliedGlassOverlayKey = &kPTAppliedGlassOverlayKey;
static const void *kPTAppliedGlassCornersKey = &kPTAppliedGlassCornersKey;
static const void *kPTAppliedGlassBorderKey = &kPTAppliedGlassBorderKey;
static const void *kPTAppliedGlassStateKey = &kPTAppliedGlassStateKey;

typedef struct {
    CGFloat w;
    CGFloat h;
    CGFloat maxR;
    CACornerMask mask;
    BOOL isDark;
} PTGlassLayoutState;

static UIBlurEffect *pt_fallbackBlurEffectForGlassEffect(id glassEffect,
                                                          UITraitCollection *traitCollection,
                                                          UIColor * __autoreleasing *outTintOverlay) {
    NSInteger glassStyle = 0; // 0 = Regular, 1 = Clear
    SEL styleSel = sel_registerName("style");
    if ([glassEffect respondsToSelector:styleSel]) {
        glassStyle = ((NSInteger (*)(id, SEL))objc_msgSend)(glassEffect, styleSel);
    }

    UIColor *tintColor = nil;
    SEL tintSel = sel_registerName("tintColor");
    if ([glassEffect respondsToSelector:tintSel]) {
        tintColor = ((id (*)(id, SEL))objc_msgSend)(glassEffect, tintSel);
    }

    UITraitCollection *effectiveTraits = traitCollection ?: [UITraitCollection currentTraitCollection];
    UIColor *resolved = tintColor;
    if (resolved && effectiveTraits &&
        [resolved respondsToSelector:@selector(resolvedColorWithTraitCollection:)]) {
        resolved = [resolved resolvedColorWithTraitCollection:effectiveTraits];
    }

    CGFloat r = 0.0, g = 0.0, b = 0.0, alpha = 0.0;
    if (resolved) {
        if (![resolved getRed:&r green:&g blue:&b alpha:&alpha]) {
            CGFloat white = 0.0;
            if ([resolved getWhite:&white alpha:&alpha]) {
                r = white;
                g = white;
                b = white;
            } else {
                alpha = 0.0;
            }
        }
    }

    BOOL isDarkMode = (effectiveTraits != nil && effectiveTraits.userInterfaceStyle == UIUserInterfaceStyleDark);
    CGFloat luminance = 0.299 * r + 0.587 * g + 0.114 * b;
    BOOL useDarkMaterial = isDarkMode;
    if (!isDarkMode && alpha >= 0.55 && luminance < 0.35) {
        useDarkMaterial = YES;
    } else if (isDarkMode && alpha >= 0.55 && luminance > 0.65) {
        useDarkMaterial = NO;
    }

    UIBlurEffectStyle style;
    UIColor *overlay = nil;
    if (glassStyle == 1) {
        // Clear glass style: stay airier with UltraThinMaterial.
        if (@available(iOS 13.0, *)) {
            style = useDarkMaterial ? UIBlurEffectStyleSystemUltraThinMaterialDark
                                    : UIBlurEffectStyleSystemUltraThinMaterialLight;
        } else {
            style = useDarkMaterial ? UIBlurEffectStyleDark : UIBlurEffectStyleLight;
        }
        if (alpha > 0.05) {
            if (!useDarkMaterial && luminance < 0.45) {
                overlay = [resolved colorWithAlphaComponent:MIN(alpha * 0.10, 0.05)];
            } else {
                overlay = [resolved colorWithAlphaComponent:MIN(alpha * 0.20, 0.14)];
            }
        }
    } else {
        if (@available(iOS 13.0, *)) {
            style = useDarkMaterial ? UIBlurEffectStyleSystemThinMaterialDark
                                    : UIBlurEffectStyleSystemThinMaterialLight;
        } else {
            style = useDarkMaterial ? UIBlurEffectStyleDark : UIBlurEffectStyleLight;
        }
        if (alpha > 0.05) {
            if (!useDarkMaterial && luminance < 0.45) {
                overlay = [resolved colorWithAlphaComponent:MIN(alpha * 0.10, 0.05)];
            } else if (useDarkMaterial) {
                overlay = [resolved colorWithAlphaComponent:MIN(alpha * 0.28, 0.20)];
            } else {
                overlay = [resolved colorWithAlphaComponent:MIN(alpha * 0.20, 0.14)];
            }
        }
    }

    if (outTintOverlay) {
        *outTintOverlay = overlay;
    }
    return [UIBlurEffect effectWithStyle:style];
}

static void pt_applyGlassFallbackAppearance(UIVisualEffectView *view, UIColor *overlay) {
    view.backgroundColor = [UIColor clearColor];
    if (overlay) {
        view.contentView.backgroundColor = overlay;
        objc_setAssociatedObject(view, kPTAppliedGlassOverlayKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (objc_getAssociatedObject(view, kPTAppliedGlassOverlayKey) != nil) {
        view.contentView.backgroundColor = nil;
        objc_setAssociatedObject(view, kPTAppliedGlassOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void pt_queryViewCornerRadii(UIView *target,
                                    CGSize boundsSize,
                                    CGFloat *outTL,
                                    CGFloat *outTR,
                                    CGFloat *outBL,
                                    CGFloat *outBR) {
    CGFloat maxPossible = MIN(boundsSize.width, boundsSize.height) * 0.5;
    if (maxPossible <= 0.0) {
        *outTL = *outTR = *outBL = *outBR = 0.0;
        return;
    }

    CGFloat tl = 0.0, tr = 0.0, bl = 0.0, br = 0.0;
    SEL effSel = sel_registerName("effectiveRadiusForCorner:");
    if ([target respondsToSelector:effSel]) {
        CGFloat (*effImp)(id, SEL, UIRectCorner) = (CGFloat (*)(id, SEL, UIRectCorner))objc_msgSend;
        tl = effImp(target, effSel, UIRectCornerTopLeft);
        tr = effImp(target, effSel, UIRectCornerTopRight);
        bl = effImp(target, effSel, UIRectCornerBottomLeft);
        br = effImp(target, effSel, UIRectCornerBottomRight);
        tl = isfinite(tl) ? MAX(0.0, MIN(tl, maxPossible)) : 0.0;
        tr = isfinite(tr) ? MAX(0.0, MIN(tr, maxPossible)) : 0.0;
        bl = isfinite(bl) ? MAX(0.0, MIN(bl, maxPossible)) : 0.0;
        br = isfinite(br) ? MAX(0.0, MIN(br, maxPossible)) : 0.0;
    }

    if (tl <= 0.01 && tr <= 0.01 && bl <= 0.01 && br <= 0.01) {
        CGFloat layerR = target.layer.cornerRadius;
        if (isfinite(layerR) && layerR > 0.01) {
            CGFloat clamped = MIN(layerR, maxPossible);
            CACornerMask masked = target.layer.maskedCorners;
            if (masked & kCALayerMinXMinYCorner) { tl = clamped; }
            if (masked & kCALayerMaxXMinYCorner) { tr = clamped; }
            if (masked & kCALayerMinXMaxYCorner) { bl = clamped; }
            if (masked & kCALayerMaxXMaxYCorner) { br = clamped; }
        }
    }

    *outTL = tl;
    *outTR = tr;
    *outBL = bl;
    *outBR = br;
}

static void pt_resolveGlassCornerRadii(UIView *view,
                                       CGFloat *outTL,
                                       CGFloat *outTR,
                                       CGFloat *outBL,
                                       CGFloat *outBR) {
    CGFloat tl = 0.0, tr = 0.0, bl = 0.0, br = 0.0;
    pt_queryViewCornerRadii(view, view.bounds.size, &tl, &tr, &bl, &br);

    if (tl <= 0.01 && tr <= 0.01 && bl <= 0.01 && br <= 0.01 && view.superview != nil) {
        CGRect f = view.frame;
        CGRect sb = view.superview.bounds;
        if (fabs(f.origin.x - sb.origin.x) <= 1.0 &&
            fabs(f.origin.y - sb.origin.y) <= 1.0 &&
            fabs(f.size.width - sb.size.width) <= 1.0 &&
            fabs(f.size.height - sb.size.height) <= 1.0) {
            pt_queryViewCornerRadii(view.superview, view.bounds.size, &tl, &tr, &bl, &br);
        }
    }

    if (outTL) { *outTL = tl; }
    if (outTR) { *outTR = tr; }
    if (outBL) { *outBL = bl; }
    if (outBR) { *outBR = br; }
}

static void pt_removeGlassDecorationLayers(UIVisualEffectView *view) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (objc_getAssociatedObject(view, kPTAppliedGlassBorderKey) != nil) {
        view.layer.borderWidth = 0.0;
        view.layer.borderColor = NULL;
        objc_setAssociatedObject(view, kPTAppliedGlassBorderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(view, kPTAppliedGlassCornersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kPTAppliedGlassStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction commit];
}

static void pt_updateGlassGeometryAndRim(UIVisualEffectView *view) {
    if (objc_getAssociatedObject(view, kPTAppliedGlassEffectKey) == nil) {
        return;
    }
    CGRect bounds = view.bounds;
    if (bounds.size.width <= 1.0 || bounds.size.height <= 1.0) {
        return;
    }

    CGFloat tl = 0.0, tr = 0.0, bl = 0.0, br = 0.0;
    pt_resolveGlassCornerRadii(view, &tl, &tr, &bl, &br);
    CGFloat maxR = MAX(MAX(tl, tr), MAX(bl, br));

    CACornerMask mask = 0;
    if (tl > 0.5) { mask |= kCALayerMinXMinYCorner; }
    if (tr > 0.5) { mask |= kCALayerMaxXMinYCorner; }
    if (bl > 0.5) { mask |= kCALayerMinXMaxYCorner; }
    if (br > 0.5) { mask |= kCALayerMaxXMaxYCorner; }

    BOOL isDark = (view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    NSValue *prevVal = objc_getAssociatedObject(view, kPTAppliedGlassStateKey);
    if (prevVal) {
        PTGlassLayoutState prev;
        [prevVal getValue:&prev];
        if (fabs(prev.w - bounds.size.width) <= 0.1 &&
            fabs(prev.h - bounds.size.height) <= 0.1 &&
            fabs(prev.maxR - maxR) <= 0.1 &&
            prev.mask == mask &&
            prev.isDark == isDark) {
            return;
        }
    }
    PTGlassLayoutState current = { bounds.size.width, bounds.size.height, maxR, mask, isDark };
    objc_setAssociatedObject(view, kPTAppliedGlassStateKey,
                             [NSValue valueWithBytes:&current objCType:@encode(PTGlassLayoutState)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (maxR > 0.5) {
        view.layer.cornerRadius = maxR;
        view.layer.cornerCurve = kCACornerCurveContinuous;
        view.layer.maskedCorners = mask;
        view.clipsToBounds = YES;
        objc_setAssociatedObject(view, kPTAppliedGlassCornersKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    view.layer.borderWidth = 0.75;
    view.layer.borderColor = (isDark
        ? [UIColor colorWithWhite:1.0 alpha:0.16]
        : [UIColor colorWithWhite:0.0 alpha:0.08]).CGColor;
    objc_setAssociatedObject(view, kPTAppliedGlassBorderKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [CATransaction commit];
}

static id pt_visualEffectInitWithEffect(UIVisualEffectView *self, SEL _cmd, id effect) {
    BOOL isGlass = (pt_glassEffectClass != Nil && effect != nil && [effect isKindOfClass:pt_glassEffectClass]);
    if (!isGlass) {
        return pt_origVisualEffectInitWithEffect ? pt_origVisualEffectInitWithEffect(self, _cmd, effect) : nil;
    }
    UIColor *overlay = nil;
    UITraitCollection *currentTraits = [UITraitCollection currentTraitCollection];
    UIBlurEffect *fallback = pt_fallbackBlurEffectForGlassEffect(effect, currentTraits, &overlay);
    id instance = pt_origVisualEffectInitWithEffect ? pt_origVisualEffectInitWithEffect(self, _cmd, fallback) : nil;
    if (instance) {
        UIVisualEffectView *effectView = (UIVisualEffectView *)instance;
        objc_setAssociatedObject(effectView, kPTAppliedGlassEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIColor *effectiveOverlay = overlay;
        if (effectView.traitCollection.userInterfaceStyle != currentTraits.userInterfaceStyle) {
            UIColor *resolvedOverlay = nil;
            UIBlurEffect *resolvedFallback = pt_fallbackBlurEffectForGlassEffect(effect, effectView.traitCollection, &resolvedOverlay);
            if (pt_origVisualEffectSetEffect) {
                pt_origVisualEffectSetEffect(effectView, @selector(setEffect:), resolvedFallback);
            }
            effectiveOverlay = resolvedOverlay ?: overlay;
        }
        pt_applyGlassFallbackAppearance(effectView, effectiveOverlay);
        pt_updateGlassGeometryAndRim(effectView);
    }
    return instance;
}

static void pt_visualEffectSetEffect(UIVisualEffectView *self, SEL _cmd, id effect) {
    BOOL isGlass = (pt_glassEffectClass != Nil && effect != nil && [effect isKindOfClass:pt_glassEffectClass]);
    if (!isGlass) {
        objc_setAssociatedObject(self, kPTAppliedGlassEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (objc_getAssociatedObject(self, kPTAppliedGlassOverlayKey) != nil) {
            self.contentView.backgroundColor = nil;
            objc_setAssociatedObject(self, kPTAppliedGlassOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        pt_removeGlassDecorationLayers(self);
        if (pt_origVisualEffectSetEffect) {
            pt_origVisualEffectSetEffect(self, _cmd, effect);
        }
        return;
    }
    objc_setAssociatedObject(self, kPTAppliedGlassEffectKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIColor *overlay = nil;
    UIBlurEffect *fallback = pt_fallbackBlurEffectForGlassEffect(effect, self.traitCollection, &overlay);
    if (pt_origVisualEffectSetEffect) {
        pt_origVisualEffectSetEffect(self, _cmd, fallback);
    }
    pt_applyGlassFallbackAppearance(self, overlay);
    pt_updateGlassGeometryAndRim(self);
}

static void pt_visualEffectTraitCollectionDidChange(UIVisualEffectView *self,
                                                    SEL _cmd,
                                                    UITraitCollection *previousTraitCollection) {
    if (pt_origVisualEffectTraitCollectionDidChange) {
        pt_origVisualEffectTraitCollectionDidChange(self, _cmd, previousTraitCollection);
    }
    id glassEffect = objc_getAssociatedObject(self, kPTAppliedGlassEffectKey);
    if (!glassEffect) {
        return;
    }
    if (previousTraitCollection &&
        previousTraitCollection.userInterfaceStyle == self.traitCollection.userInterfaceStyle) {
        return;
    }
    UIColor *overlay = nil;
    UIBlurEffect *fallback = pt_fallbackBlurEffectForGlassEffect(glassEffect, self.traitCollection, &overlay);
    if (pt_origVisualEffectSetEffect) {
        pt_origVisualEffectSetEffect(self, @selector(setEffect:), fallback);
    }
    pt_applyGlassFallbackAppearance(self, overlay);
    pt_updateGlassGeometryAndRim(self);
}

static void pt_visualEffectLayoutSubviews(UIVisualEffectView *self, SEL _cmd) {
    if (pt_origVisualEffectLayoutSubviews) {
        pt_origVisualEffectLayoutSubviews(self, _cmd);
    }
    if (objc_getAssociatedObject(self, kPTAppliedGlassEffectKey) != nil) {
        pt_updateGlassGeometryAndRim(self);
    }
}

static void pt_visualEffectSetCornerConfiguration(UIVisualEffectView *self, SEL _cmd, id cornerConfiguration) {
    if (pt_origVisualEffectSetCornerConfiguration) {
        pt_origVisualEffectSetCornerConfiguration(self, _cmd, cornerConfiguration);
    }
    if (objc_getAssociatedObject(self, kPTAppliedGlassEffectKey) != nil) {
        pt_updateGlassGeometryAndRim(self);
    }
}

static void pt_installGlassEffectCompatibilityGuard(void) {
    if (pt_glassEffectGuardInstalled) {
        return;
    }
    pt_glassEffectGuardInstalled = YES;

    // On Mac Catalyst, UIGlassEffect views can fail to create backdrop sublayers and fall back to
    // an opaque white fill. Map UIGlassEffect to native UIBlurEffect materials preserving tint polarity,
    // continuous corner configuration radii, and a lightweight specular rim/sheen.
    pt_glassEffectClass = NSClassFromString(@"UIGlassEffect");
    Class effectViewCls = objc_getClass("UIVisualEffectView");
    if (!pt_glassEffectClass || !effectViewCls) {
        return;
    }

    Method initM = class_getInstanceMethod(effectViewCls, @selector(initWithEffect:));
    if (initM) {
        IMP origImp = method_getImplementation(initM);
        if (origImp != (IMP)pt_visualEffectInitWithEffect) {
            pt_origVisualEffectInitWithEffect = (id (*)(id, SEL, id))origImp;
            class_replaceMethod(effectViewCls, @selector(initWithEffect:),
                                (IMP)pt_visualEffectInitWithEffect, method_getTypeEncoding(initM));
        }
    }

    Method setM = class_getInstanceMethod(effectViewCls, @selector(setEffect:));
    if (setM) {
        IMP origImp = method_getImplementation(setM);
        if (origImp != (IMP)pt_visualEffectSetEffect) {
            pt_origVisualEffectSetEffect = (void (*)(id, SEL, id))origImp;
            class_replaceMethod(effectViewCls, @selector(setEffect:),
                                (IMP)pt_visualEffectSetEffect, method_getTypeEncoding(setM));
        }
    }

    Method traitM = class_getInstanceMethod(effectViewCls, @selector(traitCollectionDidChange:));
    if (traitM) {
        IMP origImp = method_getImplementation(traitM);
        if (origImp != (IMP)pt_visualEffectTraitCollectionDidChange) {
            pt_origVisualEffectTraitCollectionDidChange = (void (*)(id, SEL, UITraitCollection *))origImp;
            class_replaceMethod(effectViewCls, @selector(traitCollectionDidChange:),
                                (IMP)pt_visualEffectTraitCollectionDidChange, method_getTypeEncoding(traitM));
        }
    }

    Method layoutM = class_getInstanceMethod(effectViewCls, @selector(layoutSubviews));
    if (layoutM) {
        IMP origImp = method_getImplementation(layoutM);
        if (origImp != (IMP)pt_visualEffectLayoutSubviews) {
            pt_origVisualEffectLayoutSubviews = (void (*)(id, SEL))origImp;
            class_replaceMethod(effectViewCls, @selector(layoutSubviews),
                                (IMP)pt_visualEffectLayoutSubviews, method_getTypeEncoding(layoutM));
        }
    }

    SEL setCornerSel = sel_registerName("setCornerConfiguration:");
    Method cornerM = class_getInstanceMethod(effectViewCls, setCornerSel);
    if (cornerM) {
        IMP origImp = method_getImplementation(cornerM);
        if (origImp != (IMP)pt_visualEffectSetCornerConfiguration) {
            pt_origVisualEffectSetCornerConfiguration = (void (*)(id, SEL, id))origImp;
            class_replaceMethod(effectViewCls, setCornerSel,
                                (IMP)pt_visualEffectSetCornerConfiguration, method_getTypeEncoding(cornerM));
        }
    }
}

static void (*pt_origTabBarLayoutSubviews)(id, SEL) = NULL;
static void (*pt_origTabBarTraitCollectionDidChange)(id, SEL, UITraitCollection *) = NULL;
static BOOL pt_floatingTabBarGuardInstalled = NO;
static const void *kPTFloatingTabBarStyledKey = &kPTFloatingTabBarStyledKey;
static const void *kPTFloatingTabBarStateKey = &kPTFloatingTabBarStateKey;

typedef struct {
    CGFloat w;
    CGFloat h;
    CGFloat winW;
    CGFloat winH;
    BOOL isFloating;
    BOOL isDark;
} PTTabBarCapsuleState;

static void pt_updateFloatingTabBarCapsule(UITabBar *tabBar) {
    if (!tabBar.window) {
        return;
    }
    CGFloat width = CGRectGetWidth(tabBar.bounds);
    CGFloat height = CGRectGetHeight(tabBar.bounds);
    if (width <= 1.0 || height <= 1.0) {
        return;
    }

    CGRect rectInWindow = [tabBar convertRect:tabBar.bounds toView:tabBar.window];
    CGRect winBounds = tabBar.window.bounds;
    CGFloat leftGap = CGRectGetMinX(rectInWindow) - CGRectGetMinX(winBounds);
    CGFloat rightGap = CGRectGetMaxX(winBounds) - CGRectGetMaxX(rectInWindow);
    BOOL isFloating = leftGap >= 6.0 && rightGap >= 6.0;
    BOOL isDark = (tabBar.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);

    NSValue *prevVal = objc_getAssociatedObject(tabBar, kPTFloatingTabBarStateKey);
    if (prevVal) {
        PTTabBarCapsuleState prev;
        [prevVal getValue:&prev];
        if (fabs(prev.w - width) <= 0.1 &&
            fabs(prev.h - height) <= 0.1 &&
            fabs(prev.winW - CGRectGetWidth(winBounds)) <= 0.1 &&
            fabs(prev.winH - CGRectGetHeight(winBounds)) <= 0.1 &&
            prev.isFloating == isFloating &&
            prev.isDark == isDark) {
            return;
        }
    }
    PTTabBarCapsuleState current = {
        width, height, CGRectGetWidth(winBounds), CGRectGetHeight(winBounds), isFloating, isDark
    };
    objc_setAssociatedObject(tabBar, kPTFloatingTabBarStateKey,
                             [NSValue valueWithBytes:&current objCType:@encode(PTTabBarCapsuleState)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (!isFloating) {
        if (objc_getAssociatedObject(tabBar, kPTFloatingTabBarStyledKey) != nil) {
            tabBar.layer.cornerRadius = 0.0;
            tabBar.layer.borderWidth = 0.0;
            tabBar.layer.borderColor = NULL;
            tabBar.clipsToBounds = NO;
            objc_setAssociatedObject(tabBar, kPTFloatingTabBarStyledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [CATransaction commit];
        return;
    }

    CGFloat radius = MIN(width, height) * 0.5;
    tabBar.layer.cornerRadius = radius;
    tabBar.layer.cornerCurve = kCACornerCurveContinuous;
    tabBar.clipsToBounds = YES;

    tabBar.layer.borderWidth = 0.75;
    tabBar.layer.borderColor = (isDark
        ? [UIColor colorWithWhite:1.0 alpha:0.16]
        : [UIColor colorWithWhite:0.0 alpha:0.08]).CGColor;

    // Hide the legacy 0.5pt top hairline inside _UIBarBackground on floating tab bars.
    for (UIView *subview in tabBar.subviews) {
        NSString *clsName = NSStringFromClass([subview class]);
        if ([clsName containsString:@"BarBackground"]) {
            for (UIView *child in subview.subviews) {
                NSString *childCls = NSStringFromClass([child class]);
                if ([childCls containsString:@"Shadow"] ||
                    ([child isKindOfClass:[UIImageView class]] &&
                     child.frame.size.height <= 1.5 &&
                     child.frame.size.width >= width * 0.8)) {
                    child.hidden = YES;
                }
            }
        }
    }

    objc_setAssociatedObject(tabBar, kPTFloatingTabBarStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction commit];
}

static void pt_tabBarLayoutSubviews(UITabBar *self, SEL _cmd) {
    if (pt_origTabBarLayoutSubviews) {
        pt_origTabBarLayoutSubviews(self, _cmd);
    }
    pt_updateFloatingTabBarCapsule(self);
}

static void pt_tabBarTraitCollectionDidChange(UITabBar *self,
                                              SEL _cmd,
                                              UITraitCollection *previousTraitCollection) {
    if (pt_origTabBarTraitCollectionDidChange) {
        pt_origTabBarTraitCollectionDidChange(self, _cmd, previousTraitCollection);
    }
    if (!previousTraitCollection ||
        previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        pt_updateFloatingTabBarCapsule(self);
    }
}

static void pt_installFloatingTabBarCapsuleGuard(void) {
    if (pt_floatingTabBarGuardInstalled) {
        return;
    }
    pt_floatingTabBarGuardInstalled = YES;

    Class tabBarCls = objc_getClass("UITabBar");
    if (!tabBarCls) {
        return;
    }

    Method layoutM = class_getInstanceMethod(tabBarCls, @selector(layoutSubviews));
    if (layoutM) {
        IMP origImp = method_getImplementation(layoutM);
        if (origImp != (IMP)pt_tabBarLayoutSubviews) {
            pt_origTabBarLayoutSubviews = (void (*)(id, SEL))origImp;
            class_replaceMethod(tabBarCls, @selector(layoutSubviews),
                                (IMP)pt_tabBarLayoutSubviews, method_getTypeEncoding(layoutM));
        }
    }

    Method traitM = class_getInstanceMethod(tabBarCls, @selector(traitCollectionDidChange:));
    if (traitM) {
        IMP origImp = method_getImplementation(traitM);
        if (origImp != (IMP)pt_tabBarTraitCollectionDidChange) {
            pt_origTabBarTraitCollectionDidChange = (void (*)(id, SEL, UITraitCollection *))origImp;
            class_replaceMethod(tabBarCls, @selector(traitCollectionDidChange:),
                                (IMP)pt_tabBarTraitCollectionDidChange, method_getTypeEncoding(traitM));
        }
    }
}

#if TARGET_OS_MACCATALYST
@interface PTUnsupportedNIDeviceCapability : NSObject
@property (nonatomic, readonly) BOOL supportsPreciseDistanceMeasurement;
@property (nonatomic, readonly) BOOL supportsDirectionMeasurement;
@property (nonatomic, readonly) BOOL supportsCameraAssistance;
@property (nonatomic, readonly) BOOL supportsExtendedDistanceMeasurement;
@property (nonatomic, readonly) BOOL supportsDLTDOAMeasurement;
@property (nonatomic, readonly) BOOL supportsBluetoothChannelSounding;
@end

@implementation PTUnsupportedNIDeviceCapability
- (BOOL)supportsPreciseDistanceMeasurement { return NO; }
- (BOOL)supportsDirectionMeasurement { return NO; }
- (BOOL)supportsCameraAssistance { return NO; }
- (BOOL)supportsExtendedDistanceMeasurement { return NO; }
- (BOOL)supportsDLTDOAMeasurement { return NO; }
- (BOOL)supportsBluetoothChannelSounding { return NO; }
@end

static BOOL pt_nearbyInteractionHooksInstalled = NO;
static id pt_nearbyInteractionBundleObserver = nil;

static BOOL pt_niSessionIsSupported(id self, SEL _cmd) {
    return NO;
}

static id pt_niSessionDeviceCapabilities(id self, SEL _cmd) {
    static PTUnsupportedNIDeviceCapability *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[PTUnsupportedNIDeviceCapability alloc] init];
    });
    return shared;
}

static void pt_tryInstallNearbyInteractionGuardNow(void) {
    if (pt_nearbyInteractionHooksInstalled) {
        if (pt_nearbyInteractionBundleObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:pt_nearbyInteractionBundleObserver];
            pt_nearbyInteractionBundleObserver = nil;
        }
        return;
    }
    Class niSession = objc_getClass("NISession");
    if (!niSession) {
        return;
    }
    Class niMeta = object_getClass(niSession);
    if (!niMeta) {
        return;
    }
    SEL supportedSel = sel_registerName("isSupported");
    Method supportedM = class_getClassMethod(niSession, supportedSel);
    if (supportedM) {
        class_replaceMethod(niMeta, supportedSel, (IMP)pt_niSessionIsSupported,
                            method_getTypeEncoding(supportedM));
    }
    SEL capSel = sel_registerName("deviceCapabilities");
    Method capM = class_getClassMethod(niSession, capSel);
    if (capM) {
        class_replaceMethod(niMeta, capSel, (IMP)pt_niSessionDeviceCapabilities,
                            method_getTypeEncoding(capM));
    }
    pt_nearbyInteractionHooksInstalled = YES;
    if (pt_nearbyInteractionBundleObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:pt_nearbyInteractionBundleObserver];
        pt_nearbyInteractionBundleObserver = nil;
    }
}

/// Mac Catalyst does not support UWB NearbyInteraction, but `+[NISession isSupported]`
/// synchronously waits on a 10-second XPC semaphore before returning NO. Short-circuit
/// both `isSupported` and `deviceCapabilities` so apps linking NearbyInteraction start immediately.
static void pt_installNearbyInteractionGuard(void) {
    pt_tryInstallNearbyInteractionGuardNow();
    if (!pt_nearbyInteractionHooksInstalled) {
        pt_nearbyInteractionBundleObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSBundleDidLoadNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification * _Nonnull note) {
            pt_tryInstallNearbyInteractionGuardNow();
        }];
    }
}

#pragma mark - Generic Third-Party Splash Ad SDK Blocker

typedef struct {
    const char *className;
    Class resolvedClass;
    const char *errorClassName;
    const char *fallbackErrorClassName;
    const char * const *failSels;
    size_t failSelCount;
    const char * const *boolNoSels;
    size_t boolNoSelCount;
    const char * const *boolNo1FailSels;
    size_t boolNo1FailSelCount;
    const char * const *noop1Sels;
    size_t noop1SelCount;
    const char * const *void0Sels;
    size_t void0SelCount;
    const char * const *void1Sels;
    size_t void1SelCount;
    const char * const *void1Bool1Sels;
    size_t void1Bool1SelCount;
    const char * const *void2Sels;
    size_t void2SelCount;
    const char * const *void3Sels;
    size_t void3SelCount;
} PTSplashSDKSpec;

static const char * const pt_csjFailSels[] = {
    "splashAdLoadFail:error:", "splashAd:didFailWithError:", "splashAdDidShowFailed:error:"
};
static const char * const pt_csjVoid0[] = { "loadAdData" };
static const char * const pt_csjVoid1[] = { "showSplashViewInRootViewController:" };

static const char * const pt_abuFailSels[] = {
    "splashAdLoadFail:error:", "splashAdDidShowFailed:error:", "splashAdRenderFail:error:"
};
static const char * const pt_abuVoid0[] = { "loadAd", "showAd" };

static const char * const pt_buViewFailSels[] = { "splashAd:didFailWithError:" };
static const char * const pt_buExpressFailSels[] = {
    "nativeExpressSplashView:didFailWithError:", "splashAd:didFailWithError:"
};

static const char * const pt_gdtFailSels[] = { "splashAdFailToPresent:withError:" };
static const char * const pt_gdtBoolNo[] = { "isAdValid" };
static const char * const pt_gdtNoop1[] = { "preloadSplashOrderWithPlacementId:" };
static const char * const pt_gdtVoid0[] = { "loadAd", "loadFullScreenAd" };
static const char * const pt_gdtVoid1[] = { "loadAdAndShowInWindow:" };
static const char * const pt_gdtVoid2[] = { "loadAdAndShowInWindow:withBottomView:" };
static const char * const pt_gdtVoid3[] = {
    "loadAdAndShowInWindow:withBottomView:skipView:",
    "loadAdAndShowFullScreenInWindow:withLogoImage:skipView:",
    "showAdInWindow:withBottomView:skipView:",
    "showFullScreenAdInWindow:withLogoImage:skipView:",
    "showAdInWindow:adProviderView:skipView:"
};

static const char * const pt_baiduFailSels[] = {
    "splashlFailPresentScreen:withError:", "splashFailPresentScreen:withError:", "splashDidFailWithError:"
};
static const char * const pt_baiduBoolNo[] = { "isReady" };
static const char * const pt_baiduVoid0[] = { "load" };
static const char * const pt_baiduVoid1[] = {
    "loadAndDisplayUsingKeyWindow:", "loadAndDisplayUsingContainerView:",
    "loadBiddingAd:", "showInContainerView:", "showSplashViewInViewController:"
};
static const char * const pt_baiduVoid1Bool1[] = { "loadAdWithContainerView:showAd:" };

static const char * const pt_ksFailSels[] = {
    "ksad_splashAd:didFailWithError:", "splashAd:didFailWithError:"
};
static const char * const pt_ksVoid0[] = { "loadAdData" };
static const char * const pt_ksVoid1[] = {
    "loadAdDataWithResponse:", "loadAdDataWithResponseV2:", "showInView:"
};

static const char * const pt_msFailSels[] = {
    "msSplashLoadedFail:withError:", "msSplashError:withError:"
};
static const char * const pt_msBoolNo[] = { "isAdValid" };
static const char * const pt_msVoid0[] = { "showSplashAd" };
static const char * const pt_msVoid1[] = { "loadSplashAd:", "loadAndShowSplashAd:", "showSplashAdInWindow:" };
static const char * const pt_msVoid2[] = { "loadSplashAdWithPid:adParam:" };
static const char * const pt_msVoid3[] = { "loadAndShowSplashAdWithPid:adParam:inWindow:" };

static const char * const pt_beiziFailSels[] = {
    "BeiZi_splash:didFailToLoadAdWithError:", "beizi_splashDidFailWithError:", "BeiZi_publicDidFailWithError:"
};
static const char * const pt_beiziBoolNo[] = { "isValid" };
static const char * const pt_beiziVoid0[] = { "BeiZi_loadSplashAd" };
static const char * const pt_beiziVoid1[] = { "BeiZi_loadSplashAdWithToken:", "BeiZi_showSplashAdWithWindow:" };

static const char * const pt_jadFailSels[] = {
    "jadSplashViewDidLoadFailure:error:", "jadSplashViewDidRenderFailure:error:", "jadSplashView:didFailWithError:"
};
static const char * const pt_jadVoid0[] = { "loadAdData", "preloadAdData" };

static const char * const pt_windFailSels[] = {
    "onSplashAdLoadFail:error:", "splashAdDidFailToLoad:error:"
};
static const char * const pt_windBoolNo[] = { "isAdReady" };
static const char * const pt_windVoid0[] = { "loadAdData", "loadAndShow" };
static const char * const pt_windVoid1[] = { "loadAdAndShowSplashAdWithWindow:" };

static const char * const pt_abusFailSels[] = {
    "splashAd:didLoadFailWithError:", "splashAdLoadFail:error:", "splashAd:didFailWithError:", "splashAdDidShowFailed:error:"
};
static const char * const pt_abusBoolNo[] = { "isReady" };
static const char * const pt_abusBoolNo1Fail[] = { "showInWindow:", "showInWindowWithBlock:" };
static const char * const pt_abusVoid0[] = { "loadAdData", "loadAd" };

static const char * const pt_ampsFailSels[] = { "ampsSplashAdLoadFail:error:", "ampsSplashAdShowFail:error:" };
static const char * const pt_ampsBoolNo[] = { "isReadyAd" };
static const char * const pt_ampsVoid0[] = { "loadSplashAd", "preloadAd" };
static const char * const pt_ampsVoid1[] = { "showSplashViewInWindow:" };

static const char * const pt_adprofFailSels[] = {
    "splashAd:didFailWithError:", "splashAdLoadFail:error:", "splashAdDidFailToLoad:error:", "splashAdFailWithError:"
};
static const char * const pt_adprofVoid0[] = { "loadAd" };
static const char * const pt_adprofVoid1[] = { "loadAdWithToken:" };
static const char * const pt_adprofVoid2[] = { "showAdToWindow:bottomView:" };

static const char * const pt_ubixFailSels[] = { "ubixSplashAdFailedToLoad:withError:", "ubixSplashAdFailedToShow:withError:" };
static const char * const pt_ubixBoolNo[] = { "isValid", "_isReady" };
static const char * const pt_ubixVoid0[] = { "loadAd" };
static const char * const pt_ubixVoid1[] = { "loadBiddingAd:" };
static const char * const pt_ubixVoid2[] = { "showAdToWindow:bottomView:" };

static const char * const pt_fancyFailSels[] = {
    "fancy_splashAd:didFailWithError:", "fancy_splashAdVisibleFail:error:", "splashAd:didFailWithError:"
};
static const char * const pt_fancyBoolNo[] = { "isReady", "isValidImp" };
static const char * const pt_fancyVoid0[] = { "loadAd" };
static const char * const pt_fancyVoid2[] = { "showAdFromRootViewController:bottomView:" };

static const char * const pt_ptgFailSels[] = {
    "ptg_splashAd:didFailWithError:", "ptg_splashAdVisibleError:error:", "splashAd:didFailWithError:"
};
static const char * const pt_ptgBoolNo[] = { "isReady" };
static const char * const pt_ptgVoid0[] = { "loadAd" };
static const char * const pt_ptgVoid1[] = { "loadAdWithAdm:", "showAdWithViewController:" };
static const char * const pt_ptgVoid2[] = { "showAdWithViewController:bottomView:" };

static const char * const pt_qumengFailSels[] = {
    "qumeng_splashAdLoadFail:error:", "qumeng_splashAdShowFail:error:", "qumeng_splashAdRenderFail:error:"
};
static const char * const pt_qumengBoolNo[] = { "isValid" };
static const char * const pt_qumengVoid0[] = { "loadAdData" };
static const char * const pt_qumengVoid1[] = { "showSplashWindow:", "showSplashViewController:" };
static const char * const pt_qumengVoid2[] = { "showSplashWindow:withBottomView:", "showSplashViewController:withBottomView:" };
static const char * const pt_qumengVoid3[] = { "showSplashAdWithController:bottomView:inWindow:" };

static const char * const pt_bezfFailSels[] = {
    "bezf_splashAd:didFailWithError:", "bezf_splashAdVisibleFail:error:", "splashAd:didFailWithError:"
};
static const char * const pt_bezfBoolNo[] = { "isReady", "isValidImp" };
static const char * const pt_bezfVoid0[] = { "loadAd" };
static const char * const pt_bezfVoid2[] = { "showAdFromRootViewController:bottomView:" };

static const char * const pt_mtgFailSels[] = {
    "splashADLoadFail:error:", "splashADPreloadFail:error:", "splashADShowFail:error:"
};
static const char * const pt_mtgBoolNo[] = { "isADReadyToShow", "isBiddingADReadyToShow" };
static const char * const pt_mtgVoid0[] = { "preload" };
static const char * const pt_mtgVoid1[] = { "preloadWithBidToken:" };
static const char * const pt_mtgVoid2[] = { "showInKeyWindow:customView:", "showBiddingADInKeyWindow:customView:" };

#define PT_COUNT(arr) (sizeof(arr) / sizeof((arr)[0]))

static PTSplashSDKSpec pt_splashSpecs[] = {
    { "CSJSplashAd", Nil, "CSJAdError", "BUAdError", pt_csjFailSels, PT_COUNT(pt_csjFailSels), NULL, 0, NULL, 0, NULL, 0,
      pt_csjVoid0, PT_COUNT(pt_csjVoid0), pt_csjVoid1, PT_COUNT(pt_csjVoid1), NULL, 0, NULL, 0, NULL, 0 },
    { "BUSplashAd", Nil, "BUAdError", "CSJAdError", pt_csjFailSels, PT_COUNT(pt_csjFailSels), NULL, 0, NULL, 0, NULL, 0,
      pt_csjVoid0, PT_COUNT(pt_csjVoid0), pt_csjVoid1, PT_COUNT(pt_csjVoid1), NULL, 0, NULL, 0, NULL, 0 },
    { "BUSplashAdView", Nil, "BUAdError", "CSJAdError", pt_buViewFailSels, PT_COUNT(pt_buViewFailSels), NULL, 0, NULL, 0, NULL, 0,
      pt_csjVoid0, PT_COUNT(pt_csjVoid0), NULL, 0, NULL, 0, NULL, 0, NULL, 0 },
    { "BUNativeExpressSplashView", Nil, "BUAdError", "CSJAdError", pt_buExpressFailSels, PT_COUNT(pt_buExpressFailSels), NULL, 0, NULL, 0, NULL, 0,
      pt_csjVoid0, PT_COUNT(pt_csjVoid0), NULL, 0, NULL, 0, NULL, 0, NULL, 0 },
    { "ABUVisualSplashAdManager", Nil, "BUAdError", "CSJAdError", pt_abuFailSels, PT_COUNT(pt_abuFailSels), NULL, 0, NULL, 0, NULL, 0,
      pt_abuVoid0, PT_COUNT(pt_abuVoid0), NULL, 0, NULL, 0, NULL, 0, NULL, 0 },
    { "ABUSplashAd", Nil, "BUAdError", "CSJAdError", pt_abusFailSels, PT_COUNT(pt_abusFailSels),
      pt_abusBoolNo, PT_COUNT(pt_abusBoolNo), pt_abusBoolNo1Fail, PT_COUNT(pt_abusBoolNo1Fail), NULL, 0,
      pt_abusVoid0, PT_COUNT(pt_abusVoid0), NULL, 0, NULL, 0, NULL, 0, NULL, 0 },
    { "GDTSplashAd", Nil, NULL, NULL, pt_gdtFailSels, PT_COUNT(pt_gdtFailSels), pt_gdtBoolNo, PT_COUNT(pt_gdtBoolNo), NULL, 0,
      pt_gdtNoop1, PT_COUNT(pt_gdtNoop1), pt_gdtVoid0, PT_COUNT(pt_gdtVoid0), pt_gdtVoid1, PT_COUNT(pt_gdtVoid1),
      NULL, 0, pt_gdtVoid2, PT_COUNT(pt_gdtVoid2), pt_gdtVoid3, PT_COUNT(pt_gdtVoid3) },
    { "BaiduMobAdSplash", Nil, NULL, NULL, pt_baiduFailSels, PT_COUNT(pt_baiduFailSels), pt_baiduBoolNo, PT_COUNT(pt_baiduBoolNo), NULL, 0,
      NULL, 0, pt_baiduVoid0, PT_COUNT(pt_baiduVoid0), pt_baiduVoid1, PT_COUNT(pt_baiduVoid1),
      pt_baiduVoid1Bool1, PT_COUNT(pt_baiduVoid1Bool1), NULL, 0, NULL, 0 },
    { "KSSplashAdView", Nil, NULL, NULL, pt_ksFailSels, PT_COUNT(pt_ksFailSels), NULL, 0, NULL, 0, NULL, 0,
      pt_ksVoid0, PT_COUNT(pt_ksVoid0), pt_ksVoid1, PT_COUNT(pt_ksVoid1), NULL, 0, NULL, 0, NULL, 0 },
    { "MSSplashAd", Nil, NULL, NULL, pt_msFailSels, PT_COUNT(pt_msFailSels), pt_msBoolNo, PT_COUNT(pt_msBoolNo), NULL, 0,
      NULL, 0, pt_msVoid0, PT_COUNT(pt_msVoid0), pt_msVoid1, PT_COUNT(pt_msVoid1),
      NULL, 0, pt_msVoid2, PT_COUNT(pt_msVoid2), pt_msVoid3, PT_COUNT(pt_msVoid3) },
    { "BeiZiSplash", Nil, NULL, NULL, pt_beiziFailSels, PT_COUNT(pt_beiziFailSels), pt_beiziBoolNo, PT_COUNT(pt_beiziBoolNo), NULL, 0,
      NULL, 0, pt_beiziVoid0, PT_COUNT(pt_beiziVoid0), pt_beiziVoid1, PT_COUNT(pt_beiziVoid1),
      NULL, 0, NULL, 0, NULL, 0 },
    { "JADSplashView", Nil, NULL, NULL, pt_jadFailSels, PT_COUNT(pt_jadFailSels), NULL, 0, NULL, 0, NULL, 0,
      pt_jadVoid0, PT_COUNT(pt_jadVoid0), NULL, 0, NULL, 0, NULL, 0, NULL, 0 },
    { "WindSplashAd", Nil, NULL, NULL, pt_windFailSels, PT_COUNT(pt_windFailSels), pt_windBoolNo, PT_COUNT(pt_windBoolNo), NULL, 0,
      NULL, 0, pt_windVoid0, PT_COUNT(pt_windVoid0), pt_windVoid1, PT_COUNT(pt_windVoid1),
      NULL, 0, NULL, 0, NULL, 0 },
    { "WindMillSplashAd", Nil, NULL, NULL, pt_windFailSels, PT_COUNT(pt_windFailSels), pt_windBoolNo, PT_COUNT(pt_windBoolNo), NULL, 0,
      NULL, 0, pt_windVoid0, PT_COUNT(pt_windVoid0), pt_windVoid1, PT_COUNT(pt_windVoid1),
      NULL, 0, NULL, 0, NULL, 0 },
    { "AMPSSplashAd", Nil, NULL, NULL, pt_ampsFailSels, PT_COUNT(pt_ampsFailSels), pt_ampsBoolNo, PT_COUNT(pt_ampsBoolNo), NULL, 0,
      NULL, 0, pt_ampsVoid0, PT_COUNT(pt_ampsVoid0), pt_ampsVoid1, PT_COUNT(pt_ampsVoid1), NULL, 0, NULL, 0, NULL, 0 },
    { "AdProfSplashAd", Nil, NULL, NULL, pt_adprofFailSels, PT_COUNT(pt_adprofFailSels), NULL, 0, NULL, 0,
      NULL, 0, pt_adprofVoid0, PT_COUNT(pt_adprofVoid0), pt_adprofVoid1, PT_COUNT(pt_adprofVoid1),
      NULL, 0, pt_adprofVoid2, PT_COUNT(pt_adprofVoid2), NULL, 0 },
    { "UBiXSplashAd", Nil, NULL, NULL, pt_ubixFailSels, PT_COUNT(pt_ubixFailSels), pt_ubixBoolNo, PT_COUNT(pt_ubixBoolNo), NULL, 0,
      NULL, 0, pt_ubixVoid0, PT_COUNT(pt_ubixVoid0), pt_ubixVoid1, PT_COUNT(pt_ubixVoid1),
      NULL, 0, pt_ubixVoid2, PT_COUNT(pt_ubixVoid2), NULL, 0 },
    { "FancySplashAd", Nil, NULL, NULL, pt_fancyFailSels, PT_COUNT(pt_fancyFailSels), pt_fancyBoolNo, PT_COUNT(pt_fancyBoolNo), NULL, 0,
      NULL, 0, pt_fancyVoid0, PT_COUNT(pt_fancyVoid0), NULL, 0, NULL, 0, pt_fancyVoid2, PT_COUNT(pt_fancyVoid2), NULL, 0 },
    { "PTGSplashAd", Nil, NULL, NULL, pt_ptgFailSels, PT_COUNT(pt_ptgFailSels), pt_ptgBoolNo, PT_COUNT(pt_ptgBoolNo), NULL, 0,
      NULL, 0, pt_ptgVoid0, PT_COUNT(pt_ptgVoid0), pt_ptgVoid1, PT_COUNT(pt_ptgVoid1),
      NULL, 0, pt_ptgVoid2, PT_COUNT(pt_ptgVoid2), NULL, 0 },
    { "QuMengSplashAd", Nil, NULL, NULL, pt_qumengFailSels, PT_COUNT(pt_qumengFailSels), pt_qumengBoolNo, PT_COUNT(pt_qumengBoolNo), NULL, 0,
      NULL, 0, pt_qumengVoid0, PT_COUNT(pt_qumengVoid0), pt_qumengVoid1, PT_COUNT(pt_qumengVoid1),
      NULL, 0, pt_qumengVoid2, PT_COUNT(pt_qumengVoid2), pt_qumengVoid3, PT_COUNT(pt_qumengVoid3) },
    { "BEZFSplashAd", Nil, NULL, NULL, pt_bezfFailSels, PT_COUNT(pt_bezfFailSels), pt_bezfBoolNo, PT_COUNT(pt_bezfBoolNo), NULL, 0,
      NULL, 0, pt_bezfVoid0, PT_COUNT(pt_bezfVoid0), NULL, 0, NULL, 0, pt_bezfVoid2, PT_COUNT(pt_bezfVoid2), NULL, 0 },
    { "MTGSplashAD", Nil, NULL, NULL, pt_mtgFailSels, PT_COUNT(pt_mtgFailSels), pt_mtgBoolNo, PT_COUNT(pt_mtgBoolNo), NULL, 0,
      NULL, 0, pt_mtgVoid0, PT_COUNT(pt_mtgVoid0), pt_mtgVoid1, PT_COUNT(pt_mtgVoid1),
      NULL, 0, pt_mtgVoid2, PT_COUNT(pt_mtgVoid2), NULL, 0 },
};

static NSError *pt_splashNoFillErrorForSpec(const PTSplashSDKSpec *spec) {
    Class errCls = [NSError class];
    if (spec) {
        const char *candidates[2] = { spec->errorClassName, spec->fallbackErrorClassName };
        for (int i = 0; i < 2; i++) {
            if (!candidates[i]) {
                continue;
            }
            Class candidate = objc_getClass(candidates[i]);
            if (candidate && [candidate isSubclassOfClass:[NSError class]]) {
                errCls = candidate;
                break;
            }
        }
    }
    NSError *err = [errCls errorWithDomain:@"com.playtools.splashblock"
                                      code:20001
                                  userInfo:@{NSLocalizedDescriptionKey: @"No splash ad available"}];
    SEL setErrCodeSel = sel_registerName("setErrorCode:");
    if (err && [err respondsToSelector:setErrCodeSel]) {
        Method m = class_getInstanceMethod(object_getClass(err), setErrCodeSel);
        if (m && method_getNumberOfArguments(m) == 3) {
            char argType[16] = {0};
            method_getArgumentType(m, 2, argType, sizeof(argType));
            if (argType[0] == 'q' || argType[0] == 'Q' || argType[0] == 'i' || argType[0] == 'I') {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(err, setErrCodeSel, 20001);
            }
        }
    }
    return err;
}

static NSError *pt_splashNoFillError(void) {
    return pt_splashNoFillErrorForSpec(NULL);
}

static id pt_splashDelegateForObject(id obj) {
    if (!obj) {
        return nil;
    }
    SEL delSel = @selector(delegate);
    if (![obj respondsToSelector:delSel]) {
        return nil;
    }
    Method m = class_getInstanceMethod(object_getClass(obj), delSel);
    if (!m) {
        return nil;
    }
    char retType[16] = {0};
    method_getReturnType(m, retType, sizeof(retType));
    if (retType[0] != '@') {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(obj, delSel);
}

static const PTSplashSDKSpec *pt_splashSpecForObject(id obj) {
    if (!obj) {
        return NULL;
    }
    size_t count = PT_COUNT(pt_splashSpecs);
    for (size_t i = 0; i < count; i++) {
        if (pt_splashSpecs[i].resolvedClass && [obj isMemberOfClass:pt_splashSpecs[i].resolvedClass]) {
            return &pt_splashSpecs[i];
        }
    }
    for (size_t i = 0; i < count; i++) {
        if (pt_splashSpecs[i].resolvedClass && [obj isKindOfClass:pt_splashSpecs[i].resolvedClass]) {
            return &pt_splashSpecs[i];
        }
    }
    return NULL;
}

static void pt_notifySplashDelegateFailure(id ad, const PTSplashSDKSpec *spec) {
    if (!ad || !spec || !spec->failSels || spec->failSelCount == 0) {
        return;
    }
    const char * const *selNames = spec->failSels;
    size_t selCount = spec->failSelCount;
    __strong id strongAd = ad;
    __weak id weakInitialDelegate = pt_splashDelegateForObject(strongAd);
    dispatch_async(dispatch_get_main_queue(), ^{
        id delegate = pt_splashDelegateForObject(strongAd) ?: weakInitialDelegate;
        if (!delegate) {
            return;
        }
        Class delClass = object_getClass(delegate);
        for (size_t i = 0; i < selCount; i++) {
            const char *selName = selNames[i];
            SEL sel = sel_registerName(selName);
            if (![delegate respondsToSelector:sel]) {
                continue;
            }
            Method m = class_getInstanceMethod(delClass, sel);
            if (!m) {
                continue;
            }
            unsigned int nargs = method_getNumberOfArguments(m);
            @try {
                if (nargs == 4) {
                    char argType[16] = {0};
                    method_getArgumentType(m, 3, argType, sizeof(argType));
                    if (argType[0] == 'i' || argType[0] == 'I' || argType[0] == 'q' || argType[0] == 'Q') {
                        ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(delegate, sel, strongAd, 0);
                    } else {
                        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, strongAd, pt_splashNoFillErrorForSpec(spec));
                    }
                    break;
                } else if (nargs == 3) {
                    char argType[16] = {0};
                    method_getArgumentType(m, 2, argType, sizeof(argType));
                    if (argType[0] == '@') {
                        id arg = (strstr(selName, "Error:") || strstr(selName, "error:"))
                            ? (id)pt_splashNoFillErrorForSpec(spec)
                            : strongAd;
                        ((void (*)(id, SEL, id))objc_msgSend)(delegate, sel, arg);
                    }
                    break;
                }
            } @catch (NSException *ex) {
                NSLog(@"[PlayTools] Splash delegate callback exception (%@): %@", NSStringFromSelector(sel), ex);
                break;
            }
        }
    });
}

static void pt_splashDispatchSpecFailure(id self) {
    const PTSplashSDKSpec *spec = pt_splashSpecForObject(self);
    if (spec) {
        pt_notifySplashDelegateFailure(self, spec);
    }
}

static void pt_splashLoadVoid0(id self, SEL _cmd) {
    (void)_cmd;
    pt_splashDispatchSpecFailure(self);
}

static void pt_splashLoadVoid1(id self, SEL _cmd, id a1) {
    (void)_cmd;
    (void)a1;
    pt_splashDispatchSpecFailure(self);
}

static void pt_splashLoadVoid1Bool1(id self, SEL _cmd, id a1, BOOL a2) {
    (void)_cmd;
    (void)a1;
    (void)a2;
    pt_splashDispatchSpecFailure(self);
}

static void pt_splashLoadVoid2(id self, SEL _cmd, id a1, id a2) {
    (void)_cmd;
    (void)a1;
    (void)a2;
    pt_splashDispatchSpecFailure(self);
}

static void pt_splashLoadVoid3(id self, SEL _cmd, id a1, id a2, id a3) {
    (void)_cmd;
    (void)a1;
    (void)a2;
    (void)a3;
    pt_splashDispatchSpecFailure(self);
}

static BOOL pt_splashBoolNO(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return NO;
}

static BOOL pt_splashBoolNo1(id self, SEL _cmd, id a1) {
    (void)self;
    (void)_cmd;
    (void)a1;
    return NO;
}

static BOOL pt_splashBoolNo1AndFail(id self, SEL _cmd, id a1) {
    (void)_cmd;
    (void)a1;
    pt_splashDispatchSpecFailure(self);
    return NO;
}

static void pt_splashLoadWindowViewTimeout(id self, SEL _cmd, id w, id v, NSInteger t) {
    (void)_cmd;
    (void)w;
    (void)v;
    (void)t;
    pt_splashDispatchSpecFailure(self);
}

static void pt_splashLoadWindowViewTokenTimeout(id self, SEL _cmd, id w, id v, id tok, NSInteger t) {
    (void)_cmd;
    (void)w;
    (void)v;
    (void)tok;
    (void)t;
    pt_splashDispatchSpecFailure(self);
}

static void pt_splashNoop1(id self, SEL _cmd, id a1) {
    (void)self;
    (void)_cmd;
    (void)a1;
}

static void pt_gadLoadWithAdUnitID(id self, SEL _cmd, id adUnitID, id request, void (^completionHandler)(id _Nullable, NSError * _Nullable)) {
    (void)self;
    (void)_cmd;
    (void)adUnitID;
    (void)request;
    if (completionHandler) {
        void (^copied)(id _Nullable, NSError * _Nullable) = [completionHandler copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            copied(nil, pt_splashNoFillError());
        });
    }
}

static void pt_gadLoadWithAdResponseString(id self, SEL _cmd, id adResponse, void (^completionHandler)(id _Nullable, NSError * _Nullable)) {
    (void)self;
    (void)_cmd;
    (void)adResponse;
    if (completionHandler) {
        void (^copied)(id _Nullable, NSError * _Nullable) = [completionHandler copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            copied(nil, pt_splashNoFillError());
        });
    }
}

static BOOL pt_gadIsPreloadedAdAvailable(id self, SEL _cmd, id adUnitID) {
    (void)self;
    (void)_cmd;
    (void)adUnitID;
    return NO;
}

static void pt_notifyAnyThinkLoadFail(id delegate, id placementID) {
    if (!delegate) {
        return;
    }
    __strong id strongDelegate = delegate;
    id pidCopy = [placementID copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL failSel = @selector(didFailToLoadADWithPlacementID:error:);
        if ([strongDelegate respondsToSelector:failSel]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(strongDelegate, failSel, pidCopy, pt_splashNoFillError());
        }
    });
}

static void pt_atLoadSplash4(id self, SEL _cmd, id placementID, id extra, id delegate, id containerView) {
    (void)self;
    (void)_cmd;
    (void)extra;
    (void)containerView;
    pt_notifyAnyThinkLoadFail(delegate, placementID);
}

static void pt_atLoadSplash6(id self, SEL _cmd, id placementID, id extra, id tkExtra, id adxFloorPrice, id delegate, id containerView) {
    (void)self;
    (void)_cmd;
    (void)extra;
    (void)tkExtra;
    (void)adxFloorPrice;
    (void)containerView;
    pt_notifyAnyThinkLoadFail(delegate, placementID);
}

static BOOL pt_atSplashReady1(id self, SEL _cmd, id placementID) {
    (void)self;
    (void)_cmd;
    (void)placementID;
    return NO;
}

static id pt_atSplashReady4(id self, SEL _cmd, id placementID, id showConfig, NSInteger caller, BOOL sendTK) {
    (void)self;
    (void)_cmd;
    (void)placementID;
    (void)showConfig;
    (void)caller;
    (void)sendTK;
    return nil;
}

static BOOL pt_atSplashReadyWithoutLog2(id self, SEL _cmd, id placementID, BOOL sendTK) {
    (void)self;
    (void)_cmd;
    (void)placementID;
    (void)sendTK;
    return NO;
}

static BOOL pt_replaceSplashMethod(Class cls, const char *selName, unsigned int expectedArgs, IMP replacement, BOOL isClassMethod) {
    if (!cls || !selName || !replacement) {
        return NO;
    }
    SEL sel = sel_registerName(selName);
    if (class_getInstanceMethod([NSObject class], sel) != NULL ||
        class_getInstanceMethod([UIView class], sel) != NULL) {
        return NO;
    }
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != expectedArgs || method_getImplementation(m) == replacement) {
        return NO;
    }
    Class targetClass = isClassMethod ? object_getClass(cls) : cls;
    if (!targetClass) {
        return NO;
    }
    class_replaceMethod(targetClass, sel, replacement, method_getTypeEncoding(m));
    return YES;
}

static BOOL pt_replaceSplashMethodList(Class cls, const char * const *sels, size_t count, unsigned int args, IMP replacement) {
    BOOL any = NO;
    for (size_t i = 0; i < count; i++) {
        if (pt_replaceSplashMethod(cls, sels[i], args, replacement, NO)) {
            any = YES;
        }
    }
    return any;
}

static BOOL pt_splashAdBlockerInstalled = NO;

static void pt_installSplashAdBlockerIfNeeded(void) {
    if (pt_splashAdBlockerInstalled) {
        return;
    }
    pt_splashAdBlockerInstalled = YES;

    const char *disable = getenv("PLAYTOOLS_DISABLE_SPLASH_AD_BLOCK");
    if ((disable && disable[0] == '1' && disable[1] == '\0') || ![[PlaySettings shared] blockSplashAds]) {
        return;
    }

    NSUInteger hookedClasses = 0;
    size_t count = PT_COUNT(pt_splashSpecs);
    for (size_t i = 0; i < count; i++) {
        PTSplashSDKSpec *spec = &pt_splashSpecs[i];
        Class cls = objc_getClass(spec->className);
        if (!cls) {
            continue;
        }
        spec->resolvedClass = cls;
        BOOL hooked = NO;
        hooked |= pt_replaceSplashMethodList(cls, spec->boolNoSels, spec->boolNoSelCount, 2, (IMP)pt_splashBoolNO);
        hooked |= pt_replaceSplashMethodList(cls, spec->boolNo1FailSels, spec->boolNo1FailSelCount, 3, (IMP)pt_splashBoolNo1AndFail);
        hooked |= pt_replaceSplashMethodList(cls, spec->noop1Sels, spec->noop1SelCount, 3, (IMP)pt_splashNoop1);
        hooked |= pt_replaceSplashMethodList(cls, spec->void0Sels, spec->void0SelCount, 2, (IMP)pt_splashLoadVoid0);
        hooked |= pt_replaceSplashMethodList(cls, spec->void1Sels, spec->void1SelCount, 3, (IMP)pt_splashLoadVoid1);
        hooked |= pt_replaceSplashMethodList(cls, spec->void1Bool1Sels, spec->void1Bool1SelCount, 4, (IMP)pt_splashLoadVoid1Bool1);
        hooked |= pt_replaceSplashMethodList(cls, spec->void2Sels, spec->void2SelCount, 4, (IMP)pt_splashLoadVoid2);
        hooked |= pt_replaceSplashMethodList(cls, spec->void3Sels, spec->void3SelCount, 5, (IMP)pt_splashLoadVoid3);
        if (strcmp(spec->className, "MTGSplashAD") == 0) {
            hooked |= pt_replaceSplashMethod(cls, "loadAndShowInKeyWindow:customView:timeout:", 5, (IMP)pt_splashLoadWindowViewTimeout, NO);
            hooked |= pt_replaceSplashMethod(cls, "loadAndShowInKeyWindow:customView:bidToken:timeout:", 6, (IMP)pt_splashLoadWindowViewTokenTimeout, NO);
        }
        if (hooked) {
            hookedClasses++;
        }
    }

    Class pagCls = objc_getClass("PAGLAppOpenAd");
    if (pagCls) {
        if (pt_replaceSplashMethod(pagCls, "loadAdWithSlotID:request:completionHandler:", 5, (IMP)pt_gadLoadWithAdUnitID, YES)) {
            hookedClasses++;
        }
    }

    Class bdaCls = objc_getClass("BDASplashManager");
    if (bdaCls) {
        BOOL hooked = NO;
        hooked |= pt_replaceSplashMethod(bdaCls, "hasPreloadOrRealtimeModel", 2, (IMP)pt_splashBoolNO, YES);
        hooked |= pt_replaceSplashMethod(bdaCls, "shouldShowSplashAccordingToUDPAndPreloadData:", 3, (IMP)pt_splashBoolNo1, NO);
        if (hooked) {
            hookedClasses++;
        }
    }

    Class gadCls = objc_getClass("GADAppOpenAd");
    if (gadCls) {
        BOOL hooked = NO;
        hooked |= pt_replaceSplashMethod(gadCls, "loadWithAdUnitID:request:completionHandler:", 5, (IMP)pt_gadLoadWithAdUnitID, YES);
        hooked |= pt_replaceSplashMethod(gadCls, "loadWithAdResponseString:completionHandler:", 4, (IMP)pt_gadLoadWithAdResponseString, YES);
        hooked |= pt_replaceSplashMethod(gadCls, "isPreloadedAdAvailable:", 3, (IMP)pt_gadIsPreloadedAdAvailable, YES);
        if (hooked) {
            hookedClasses++;
        }
    }

    Class atCls = objc_getClass("ATAdManager");
    if (atCls) {
        BOOL hooked = NO;
        hooked |= pt_replaceSplashMethod(atCls, "loadADWithPlacementID:extra:delegate:containerView:", 6, (IMP)pt_atLoadSplash4, NO);
        hooked |= pt_replaceSplashMethod(atCls, "loadADWithPlacementID:extra:tkExtra:adxFloorPrice:delegate:containerView:", 8, (IMP)pt_atLoadSplash6, NO);
        hooked |= pt_replaceSplashMethod(atCls, "splashReadyForPlacementID:", 3, (IMP)pt_atSplashReady1, NO);
        hooked |= pt_replaceSplashMethod(atCls, "splashReadyForPlacementID:showConfig:caller:sendTK:", 6, (IMP)pt_atSplashReady4, NO);
        hooked |= pt_replaceSplashMethod(atCls, "splashReadyWithoutLogForPlacementID:sendTK:", 4, (IMP)pt_atSplashReadyWithoutLog2, NO);
        if (hooked) {
            hookedClasses++;
        }
    }

    if (hookedClasses > 0) {
        NSLog(@"[PlayTools] Splash ad blocker hooked %lu SDK class(es)", (unsigned long)hookedClasses);
    }
}

static NSUInteger (*pt_origCellularDataRestrictedState)(id, SEL) = NULL;
static void (*pt_origCellularDataSetNotifier)(id, SEL, void (^)(NSUInteger)) = NULL;
static BOOL pt_cellularDataGuardInstalled = NO;
static os_unfair_lock pt_cellularDataLock = OS_UNFAIR_LOCK_INIT;
static const void *kPTCellularDataGenKey = &kPTCellularDataGenKey;

static NSUInteger pt_cellularDataRestrictedState(id self, SEL _cmd) {
    NSUInteger state = pt_origCellularDataRestrictedState ? pt_origCellularDataRestrictedState(self, _cmd) : 0;
    return (state == 0) ? 2 : state;
}

static void pt_cellularDataSetNotifier(id self, SEL _cmd, void (^notifier)(NSUInteger)) {
    uint64_t nextGen = 0;
    os_unfair_lock_lock(&pt_cellularDataLock);
    nextGen = [objc_getAssociatedObject(self, kPTCellularDataGenKey) unsignedLongLongValue] + 1;
    objc_setAssociatedObject(self, kPTCellularDataGenKey, @(nextGen), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    os_unfair_lock_unlock(&pt_cellularDataLock);

    if (pt_origCellularDataSetNotifier) {
        pt_origCellularDataSetNotifier(self, _cmd, notifier);
    }
    if (!notifier) {
        return;
    }

    NSUInteger origState = pt_origCellularDataRestrictedState
        ? pt_origCellularDataRestrictedState(self, @selector(restrictedState))
        : 0;
    if (origState != 0) {
        return;
    }

    void (^copiedNotifier)(NSUInteger) = [notifier copy];
    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        id strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        os_unfair_lock_lock(&pt_cellularDataLock);
        uint64_t curGen = [objc_getAssociatedObject(strongSelf, kPTCellularDataGenKey) unsignedLongLongValue];
        os_unfair_lock_unlock(&pt_cellularDataLock);
        if (curGen == nextGen) {
            copiedNotifier(2);
        }
    });
}

static void pt_installCellularDataCompatibilityGuard(void) {
    if (pt_cellularDataGuardInstalled) {
        return;
    }
    pt_cellularDataGuardInstalled = YES;

    Class ctCls = objc_getClass("CTCellularData");
    if (!ctCls) {
        return;
    }

    SEL stateSel = sel_registerName("restrictedState");
    Method stateM = class_getInstanceMethod(ctCls, stateSel);
    if (stateM) {
        IMP origImp = method_getImplementation(stateM);
        if (origImp != (IMP)pt_cellularDataRestrictedState) {
            pt_origCellularDataRestrictedState = (NSUInteger (*)(id, SEL))origImp;
            class_replaceMethod(ctCls, stateSel, (IMP)pt_cellularDataRestrictedState, method_getTypeEncoding(stateM));
        }
    }

    SEL notifierSel = sel_registerName("setCellularDataRestrictionDidUpdateNotifier:");
    Method notifierM = class_getInstanceMethod(ctCls, notifierSel);
    if (notifierM) {
        IMP origImp = method_getImplementation(notifierM);
        if (origImp != (IMP)pt_cellularDataSetNotifier) {
            pt_origCellularDataSetNotifier = (void (*)(id, SEL, void (^)(NSUInteger)))origImp;
            class_replaceMethod(ctCls, notifierSel, (IMP)pt_cellularDataSetNotifier, method_getTypeEncoding(notifierM));
        }
    }
}

static NSURL *pt_coerceNSURL(id maybeURL) {
    if (maybeURL == nil || [maybeURL isKindOfClass:[NSURL class]]) {
        return (NSURL *)maybeURL;
    }
    if ([maybeURL isKindOfClass:[NSString class]]) {
        NSString *str = (NSString *)maybeURL;
        if ([str containsString:@"://"]) {
            return [NSURL URLWithString:str];
        }
        return [NSURL fileURLWithPath:str];
    }
    return (NSURL *)maybeURL;
}

static BOOL pt_nsDataURLGuardInstalled = NO;

@interface NSData (PlayToolsURLGuard)
+ (instancetype)pt_dataWithContentsOfURL:(NSURL *)url options:(NSDataReadingOptions)options error:(NSError **)error;
- (instancetype)pt_initWithContentsOfURL:(NSURL *)url options:(NSDataReadingOptions)options error:(NSError **)error __attribute__((objc_method_family(init)));
@end

@implementation NSData (PlayToolsURLGuard)

+ (instancetype)pt_dataWithContentsOfURL:(NSURL *)url options:(NSDataReadingOptions)options error:(NSError **)error {
    return [self pt_dataWithContentsOfURL:pt_coerceNSURL(url) options:options error:error];
}

- (instancetype)pt_initWithContentsOfURL:(NSURL *)url options:(NSDataReadingOptions)options error:(NSError **)error {
    return [self pt_initWithContentsOfURL:pt_coerceNSURL(url) options:options error:error];
}

@end

static void pt_installNSDataURLTypeGuard(void) {
    if (pt_nsDataURLGuardInstalled) {
        return;
    }
    pt_nsDataURLGuardInstalled = YES;

    Class nsDataMeta = object_getClass(NSData.class);
    Method classOrigM = nsDataMeta ? class_getClassMethod(NSData.class, @selector(dataWithContentsOfURL:options:error:)) : NULL;
    Method classSwizM = nsDataMeta ? class_getClassMethod(NSData.class, @selector(pt_dataWithContentsOfURL:options:error:)) : NULL;
    if (classOrigM && classSwizM) {
        method_exchangeImplementations(classOrigM, classSwizM);
    }

    Method instOrigM = class_getInstanceMethod(NSData.class, @selector(initWithContentsOfURL:options:error:));
    Method instSwizM = class_getInstanceMethod(NSData.class, @selector(pt_initWithContentsOfURL:options:error:));
    if (instOrigM && instSwizM) {
        method_exchangeImplementations(instOrigM, instSwizM);
    }
}
#endif

static void pt_installUniversalCompatibilityGuards(void) {
    pt_ensure_device_settings_cached();
    (void)pt_should_block_sleep_spamming();

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Prevent AppKit's "unexpectedly quit while reopening windows" modal from blocking Catalyst launch.
    if (![defaults boolForKey:@"ApplePersistenceIgnoreState"]) {
        [defaults setBool:YES forKey:@"ApplePersistenceIgnoreState"];
    }
    pt_applyUIScaleFactor();

    pt_installAppGroupContainerGuard();
    pt_installOrphanWindowSceneGuard();
#if TARGET_OS_MACCATALYST
    pt_installStartupPresentationGuard();
    pt_installCellularDataCompatibilityGuard();
    pt_installNSDataURLTypeGuard();
    pt_installNearbyInteractionGuard();
    pt_installSplashAdBlockerIfNeeded();
#endif
    pt_installNavigationAppearanceBalanceGuard();
    pt_installGlassEffectCompatibilityGuard();
    pt_installFloatingTabBarCapsuleGuard();
    pt_installSafeAreaReentrantLayoutGuard();
    pt_installTerminationWatchdog();
    pt_installViewBridgeFaultGuard();
    pt_installCollectionViewInitialFrameGuard();

    if (!pt_fontNamesHookInstalled) {
        Class uiFont = objc_getClass("UIFont");
        Class meta = uiFont ? object_getClass(uiFont) : Nil;
        Method m = uiFont ? class_getClassMethod(uiFont, @selector(fontNamesForFamilyName:)) : NULL;
        if (meta && m) {
            IMP origImp = method_getImplementation(m);
            if (origImp != (IMP)pt_fontNamesForFamilyName) {
                pt_origFontNamesForFamilyName = (NSArray<NSString *> *(*)(id, SEL, NSString *))origImp;
                class_replaceMethod(meta, @selector(fontNamesForFamilyName:),
                                    (IMP)pt_fontNamesForFamilyName, method_getTypeEncoding(m));
            }
            pt_fontNamesHookInstalled = YES;
        }
    }

    pt_patchFirebaseInlineExits();
    pt_installRiskBannerHooks();
    pt_installJPushNotificationThrottleIfNeeded();

    dispatch_async(dispatch_get_main_queue(), ^{
        Class uiApp = objc_getClass("UIApplication");
        if (uiApp) {
            Method m = class_getInstanceMethod(uiApp, sel_registerName("registerForRemoteNotifications"));
            if (m) {
                pt_origRegisterForRemoteNotifications = method_getImplementation(m);
                class_replaceMethod(uiApp, sel_registerName("registerForRemoteNotifications"),
                                    (IMP)pt_registerForRemoteNotifications, method_getTypeEncoding(m));
            }
        }
        pt_installRiskBannerHooks();
        pt_installJPushNotificationThrottleIfNeeded();
        pt_installTerminationTimeoutHooks();
    });
}

static void (*pt_origLetBackgroundTasksCompleteWithTimeout)(id, SEL, double) = NULL;
static BOOL pt_terminationHookInstalled = NO;

static void pt_letBackgroundTasksCompleteWithTimeout(id self, SEL _cmd, double timeout) {
    // Cap UIKitMacHelper's post-Cmd+Q background-task grace window (default 35s) so SDK
    // tasks opened during applicationDidEnterBackground cannot trap apps in an invisible
    // background zombie state that resumes the old screen when clicked again.
    double cappedTimeout = (timeout > 0.35) ? 0.35 : timeout;
    if (pt_origLetBackgroundTasksCompleteWithTimeout) {
        pt_origLetBackgroundTasksCompleteWithTimeout(self, _cmd, cappedTimeout);
    }
}

static void pt_tryInstallTerminationTimeoutHookNow(void) {
    if (pt_terminationHookInstalled) {
        return;
    }
    Class termCtrl = objc_getClass("UINSUIKitTerminationController");
    if (!termCtrl) {
        return;
    }
    SEL sel = sel_registerName("letBackgroundTasksCompleteWithTimeout:");
    Method m = class_getInstanceMethod(termCtrl, sel);
    if (m) {
        pt_origLetBackgroundTasksCompleteWithTimeout = (void (*)(id, SEL, double))method_getImplementation(m);
        class_replaceMethod(termCtrl, sel, (IMP)pt_letBackgroundTasksCompleteWithTimeout, method_getTypeEncoding(m));
        pt_terminationHookInstalled = YES;
    }
}

static id pt_terminationLaunchObserver = nil;

static void pt_installTerminationTimeoutHooks(void) {
    pt_tryInstallTerminationTimeoutHookNow();
    if (!pt_terminationHookInstalled) {
        pt_terminationLaunchObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification * _Nonnull note) {
            pt_tryInstallTerminationTimeoutHookNow();
            if (pt_terminationLaunchObserver) {
                [[NSNotificationCenter defaultCenter] removeObserver:pt_terminationLaunchObserver];
                pt_terminationLaunchObserver = nil;
            }
        }];
    }
}

#pragma mark - CloudKit Compatibility Guard

static Class pt_CKContainerClass = Nil;
static Class pt_CKDatabaseClass = Nil;
static id (*pt_origCKDefaultContainer)(id, SEL) = NULL;
static id (*pt_origCKContainerWithIdentifier)(id, SEL, NSString *) = NULL;
static BOOL pt_cloudKitHooksInstalled = NO;

static NSError *pt_cloudKitMissingEntitlementError(void) {
    return [NSError errorWithDomain:@"CKErrorDomain"
                               code:8 /* CKErrorMissingEntitlement */
                           userInfo:@{NSLocalizedDescriptionKey: @"Missing CloudKit entitlement"}];
}

@interface PTStubCKDatabase : NSObject
@property (nonatomic, assign) NSInteger databaseScope;
@end

@implementation PTStubCKDatabase

- (BOOL)isKindOfClass:(Class)aClass {
    return [super isKindOfClass:aClass] || (pt_CKDatabaseClass && [pt_CKDatabaseClass isSubclassOfClass:aClass]);
}

- (void)pt_failCompletion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    if (!completion) return;
    NSError *err = pt_cloudKitMissingEntitlementError();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        completion(nil, err);
    });
}

- (void)fetchRecordWithID:(id)recordID completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:completionHandler];
}

- (void)saveRecord:(id)record completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:completionHandler];
}

- (void)deleteRecordWithID:(id)recordID completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:completionHandler];
}

- (void)performQuery:(id)query inZoneWithID:(id)zoneID completionHandler:(void (^)(NSArray * _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:(void (^)(id, NSError *))completionHandler];
}

- (void)fetchAllRecordZonesWithCompletionHandler:(void (^)(NSArray * _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:(void (^)(id, NSError *))completionHandler];
}

- (void)fetchRecordZoneWithID:(id)zoneID completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:completionHandler];
}

- (void)saveRecordZone:(id)zone completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:completionHandler];
}

- (void)deleteRecordZoneWithID:(id)zoneID completionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:completionHandler];
}

- (void)fetchAllSubscriptionsWithCompletionHandler:(void (^)(NSArray * _Nullable, NSError * _Nullable))completionHandler {
    [self pt_failCompletion:(void (^)(id, NSError *))completionHandler];
}

- (void)addOperation:(id)operation {
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature *sig = [super methodSignatureForSelector:aSelector];
    if (!sig && pt_CKDatabaseClass) {
        sig = [pt_CKDatabaseClass instanceMethodSignatureForSelector:aSelector];
    }
    return sig ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    // Zero-initialize any return buffer so callers receive nil/0/NO cleanly.
    NSUInteger retLen = anInvocation.methodSignature.methodReturnLength;
    if (retLen > 0) {
        uint8_t *zeroBuf = calloc(1, retLen);
        if (zeroBuf) {
            [anInvocation setReturnValue:zeroBuf];
            free(zeroBuf);
        }
    }
}

@end

@interface PTStubCKContainer : NSObject
@property (nonatomic, copy) NSString *containerIdentifier;
@property (nonatomic, strong) PTStubCKDatabase *privateCloudDatabase;
@property (nonatomic, strong) PTStubCKDatabase *publicCloudDatabase;
@property (nonatomic, strong) PTStubCKDatabase *sharedCloudDatabase;
@end

@implementation PTStubCKContainer

- (instancetype)initWithIdentifier:(NSString *)identifier {
    self = [super init];
    if (self) {
        _containerIdentifier = [identifier copy];
        _privateCloudDatabase = [[PTStubCKDatabase alloc] init];
        _privateCloudDatabase.databaseScope = 2;
        _publicCloudDatabase = [[PTStubCKDatabase alloc] init];
        _publicCloudDatabase.databaseScope = 1;
        _sharedCloudDatabase = [[PTStubCKDatabase alloc] init];
        _sharedCloudDatabase.databaseScope = 3;
    }
    return self;
}

- (BOOL)isKindOfClass:(Class)aClass {
    return [super isKindOfClass:aClass] || (pt_CKContainerClass && [pt_CKContainerClass isSubclassOfClass:aClass]);
}

- (id)databaseWithDatabaseScope:(NSInteger)scope {
    if (scope == 1) return self.publicCloudDatabase;
    if (scope == 3) return self.sharedCloudDatabase;
    return self.privateCloudDatabase;
}

- (void)accountStatusWithCompletionHandler:(void (^)(NSInteger, NSError * _Nullable))completionHandler {
    if (!completionHandler) return;
    NSError *err = pt_cloudKitMissingEntitlementError();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSLog(@"[PC] CloudKit accountStatus stub completion for %@", self.containerIdentifier);
        completionHandler(0 /* CKAccountStatusCouldNotDetermine */, err);
    });
}

- (void)fetchUserRecordIDWithCompletionHandler:(void (^)(id _Nullable, NSError * _Nullable))completionHandler {
    if (!completionHandler) return;
    NSError *err = pt_cloudKitMissingEntitlementError();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        completionHandler(nil, err);
    });
}

- (void)requestApplicationPermission:(NSUInteger)applicationPermission
                   completionHandler:(void (^)(NSInteger, NSError * _Nullable))completionHandler {
    if (!completionHandler) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        completionHandler(2 /* CKApplicationPermissionStatusDenied */, nil);
    });
}

- (void)statusForApplicationPermission:(NSUInteger)applicationPermission
                     completionHandler:(void (^)(NSInteger, NSError * _Nullable))completionHandler {
    if (!completionHandler) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        completionHandler(2 /* CKApplicationPermissionStatusDenied */, nil);
    });
}

- (void)addOperation:(id)operation {
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature *sig = [super methodSignatureForSelector:aSelector];
    if (!sig && pt_CKContainerClass) {
        sig = [pt_CKContainerClass instanceMethodSignatureForSelector:aSelector];
    }
    return sig ?: [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    NSUInteger retLen = anInvocation.methodSignature.methodReturnLength;
    if (retLen > 0) {
        uint8_t *zeroBuf = calloc(1, retLen);
        if (zeroBuf) {
            [anInvocation setReturnValue:zeroBuf];
            free(zeroBuf);
        }
    }
}

@end

static BOOL pt_hasCloudKitEntitlementForContainer(NSString * _Nullable containerID) {
    typedef CFTypeRef (*SecTaskCreateFromSelfFn)(CFAllocatorRef);
    typedef CFTypeRef (*SecTaskCopyValueForEntitlementFn)(CFTypeRef, CFStringRef, CFErrorRef *);
    static SecTaskCreateFromSelfFn createSelfFn = NULL;
    static SecTaskCopyValueForEntitlementFn copyEntitlementFn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createSelfFn = (SecTaskCreateFromSelfFn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
        copyEntitlementFn = (SecTaskCopyValueForEntitlementFn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    });
    if (!createSelfFn || !copyEntitlementFn) {
        return NO;
    }
    CFTypeRef task = createSelfFn(kCFAllocatorDefault);
    if (!task) {
        return NO;
    }

    BOOL hasService = NO;
    CFTypeRef services = copyEntitlementFn(task, CFSTR("com.apple.developer.icloud-services"), NULL);
    if (services) {
        if (CFGetTypeID(services) == CFArrayGetTypeID()) {
            for (id entry in (__bridge NSArray *)services) {
                if ([entry isKindOfClass:[NSString class]] &&
                    [(NSString *)entry caseInsensitiveCompare:@"CloudKit"] == NSOrderedSame) {
                    hasService = YES;
                    break;
                }
            }
        }
        CFRelease(services);
    }

    BOOL hasContainer = NO;
    if (hasService) {
        CFTypeRef containers = copyEntitlementFn(task, CFSTR("com.apple.developer.icloud-container-identifiers"), NULL);
        if (containers) {
            if (CFGetTypeID(containers) == CFArrayGetTypeID()) {
                NSArray *arr = (__bridge NSArray *)containers;
                if (containerID.length > 0) {
                    hasContainer = [arr containsObject:containerID] || [arr containsObject:@"*"];
                } else {
                    hasContainer = arr.count > 0;
                }
            }
            CFRelease(containers);
        }
    }

    CFRelease(task);
    return hasService && hasContainer;
}

static id pt_stubContainerForIdentifier(NSString * _Nullable identifier) {
    static NSMutableDictionary<NSString *, PTStubCKContainer *> *stubCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stubCache = [NSMutableDictionary dictionary];
    });
    NSString *key = identifier.length > 0
        ? identifier
        : ([[NSBundle mainBundle] bundleIdentifier] ?: @"iCloud.playcover.stub");
    @synchronized (stubCache) {
        PTStubCKContainer *stub = stubCache[key];
        if (!stub) {
            NSLog(@"[PC] Using CloudKit missing-entitlement stub container for %@", key);
            stub = [[PTStubCKContainer alloc] initWithIdentifier:key];
            stubCache[key] = stub;
        }
        return stub;
    }
}

static id pt_ckDefaultContainer(id self, SEL _cmd) {
    if (pt_hasCloudKitEntitlementForContainer(nil) && pt_origCKDefaultContainer) {
        return pt_origCKDefaultContainer(self, _cmd);
    }
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    NSString *fallbackID = bid.length > 0 ? [@"iCloud." stringByAppendingString:bid] : @"iCloud.playcover.stub";
    return pt_stubContainerForIdentifier(fallbackID);
}

static id pt_ckContainerWithIdentifier(id self, SEL _cmd, NSString *identifier) {
    if (identifier.length > 0 && pt_hasCloudKitEntitlementForContainer(identifier) && pt_origCKContainerWithIdentifier) {
        return pt_origCKContainerWithIdentifier(self, _cmd, identifier);
    }
    return pt_stubContainerForIdentifier(identifier);
}

static id pt_cloudKitBundleObserver = nil;

static void pt_tryInstallCloudKitHooksNow(void) {
    if (pt_cloudKitHooksInstalled) {
        if (pt_cloudKitBundleObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:pt_cloudKitBundleObserver];
            pt_cloudKitBundleObserver = nil;
        }
        return;
    }
    Class ckContainer = objc_getClass("CKContainer");
    if (!ckContainer) {
        return;
    }
    pt_CKContainerClass = ckContainer;
    pt_CKDatabaseClass = objc_getClass("CKDatabase");
    Class ckMeta = object_getClass(ckContainer);
    if (!ckMeta) {
        return;
    }

    SEL defaultSel = sel_registerName("defaultContainer");
    Method defaultM = class_getClassMethod(ckContainer, defaultSel);
    if (defaultM) {
        pt_origCKDefaultContainer = (id (*)(id, SEL))method_getImplementation(defaultM);
        class_replaceMethod(ckMeta, defaultSel, (IMP)pt_ckDefaultContainer, method_getTypeEncoding(defaultM));
    }

    SEL withIdSel = sel_registerName("containerWithIdentifier:");
    Method withIdM = class_getClassMethod(ckContainer, withIdSel);
    if (withIdM) {
        pt_origCKContainerWithIdentifier = (id (*)(id, SEL, NSString *))method_getImplementation(withIdM);
        class_replaceMethod(ckMeta, withIdSel, (IMP)pt_ckContainerWithIdentifier, method_getTypeEncoding(withIdM));
    }

    pt_cloudKitHooksInstalled = YES;
    if (pt_cloudKitBundleObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:pt_cloudKitBundleObserver];
        pt_cloudKitBundleObserver = nil;
    }
}

static void pt_installCloudKitCompatibilityHooks(void) {
    pt_tryInstallCloudKitHooksNow();
    if (!pt_cloudKitHooksInstalled) {
        pt_cloudKitBundleObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSBundleDidLoadNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification * _Nonnull note) {
            pt_tryInstallCloudKitHooksNow();
        }];
    }
}

typedef BOOL (*pt_processInfo_bool_fn)(id, SEL);
static pt_processInfo_bool_fn pt_origRuntimeIsMacCatalystApp = NULL;
static pt_processInfo_bool_fn pt_origRuntimeIsIOSAppOnMac = NULL;
static pt_processInfo_bool_fn pt_origBaseIsMacCatalystApp = NULL;
static pt_processInfo_bool_fn pt_origBaseIsIOSAppOnMac = NULL;

extern const struct mach_header __dso_handle;
enum { pt_callerCacheSlots = 32 };
static _Atomic(uintptr_t) pt_systemCallerCache[pt_callerCacheSlots];

static BOOL pt_isSystemFrameworkAddress(const void *addr) {
    if (!addr) {
        return NO;
    }
    // Store the address and result together. An odd address cannot share a slot with a result bit.
    const uintptr_t address = (uintptr_t)addr;
    const BOOL aligned = (address & 1) == 0;
    const size_t slot = ((address >> 2) ^ (address >> 11)) & (pt_callerCacheSlots - 1);
    if (aligned) {
        const uintptr_t cached = atomic_load_explicit(&pt_systemCallerCache[slot], memory_order_relaxed);
        if ((cached & ~(uintptr_t)1) == address) {
            return (cached & 1) != 0;
        }
    }

    Dl_info info;
    if (dladdr(addr, &info) == 0 || !info.dli_fname) {
        return NO;
    }
    const char *path = info.dli_fname;
    const BOOL isSystem = strncmp(path, "/System/", 8) == 0 ||
                          strncmp(path, "/usr/lib/", 9) == 0 ||
                          strncmp(path, "/Library/Apple/", 15) == 0;
    const struct mach_header *image = info.dli_fbase;
    // Unloadable dylibs can be remapped at the same address with a different path.
    if (aligned && image && (image == &__dso_handle || image->filetype == MH_EXECUTE ||
                             (image->flags & MH_DYLIB_IN_CACHE) != 0)) {
        atomic_store_explicit(&pt_systemCallerCache[slot], address | (uintptr_t)isSystem, memory_order_relaxed);
    }
    return isSystem;
}

static BOOL pt_runtimeProcessInfoIsMacCatalystApp(id self, SEL _cmd) {
    if (pt_isSystemFrameworkAddress(__builtin_return_address(0))) {
        return pt_origRuntimeIsMacCatalystApp ? pt_origRuntimeIsMacCatalystApp(self, _cmd) : YES;
    }
    return NO;
}

static BOOL pt_runtimeProcessInfoIsIOSAppOnMac(id self, SEL _cmd) {
    if (pt_isSystemFrameworkAddress(__builtin_return_address(0))) {
        return pt_origRuntimeIsIOSAppOnMac ? pt_origRuntimeIsIOSAppOnMac(self, _cmd) : NO;
    }
    return NO;
}

static BOOL pt_baseProcessInfoIsMacCatalystApp(id self, SEL _cmd) {
    if (pt_isSystemFrameworkAddress(__builtin_return_address(0))) {
        return pt_origBaseIsMacCatalystApp ? pt_origBaseIsMacCatalystApp(self, _cmd) : YES;
    }
    return NO;
}

static BOOL pt_baseProcessInfoIsIOSAppOnMac(id self, SEL _cmd) {
    if (pt_isSystemFrameworkAddress(__builtin_return_address(0))) {
        return pt_origBaseIsIOSAppOnMac ? pt_origBaseIsIOSAppOnMac(self, _cmd) : NO;
    }
    return NO;
}

static void pt_installIOSProcessIdentity(void) {

    SEL catSel = @selector(isMacCatalystApp);
    SEL iosOnMacSel = @selector(isiOSAppOnMac);
    Class baseCls = [NSProcessInfo class];
    Class runtimeCls = object_getClass([NSProcessInfo processInfo]);

    // Hook runtime concrete subclass (e.g. _NSSwiftProcessInfo) FIRST before base class
    // so we always capture the real Foundation IMPs.
    if (runtimeCls && runtimeCls != baseCls) {
        Method mCat = class_getInstanceMethod(runtimeCls, catSel);
        if (mCat && method_getImplementation(mCat) != (IMP)pt_runtimeProcessInfoIsMacCatalystApp) {
            pt_origRuntimeIsMacCatalystApp = (pt_processInfo_bool_fn)method_getImplementation(mCat);
            class_replaceMethod(runtimeCls, catSel, (IMP)pt_runtimeProcessInfoIsMacCatalystApp, method_getTypeEncoding(mCat));
        }
        Method mIos = class_getInstanceMethod(runtimeCls, iosOnMacSel);
        if (mIos && method_getImplementation(mIos) != (IMP)pt_runtimeProcessInfoIsIOSAppOnMac) {
            pt_origRuntimeIsIOSAppOnMac = (pt_processInfo_bool_fn)method_getImplementation(mIos);
            class_replaceMethod(runtimeCls, iosOnMacSel, (IMP)pt_runtimeProcessInfoIsIOSAppOnMac, method_getTypeEncoding(mIos));
        }
    }

    if (baseCls) {
        Method mCat = class_getInstanceMethod(baseCls, catSel);
        if (mCat && method_getImplementation(mCat) != (IMP)pt_baseProcessInfoIsMacCatalystApp) {
            pt_origBaseIsMacCatalystApp = (pt_processInfo_bool_fn)method_getImplementation(mCat);
            class_replaceMethod(baseCls, catSel, (IMP)pt_baseProcessInfoIsMacCatalystApp, method_getTypeEncoding(mCat));
        }
        Method mIos = class_getInstanceMethod(baseCls, iosOnMacSel);
        if (mIos && method_getImplementation(mIos) != (IMP)pt_baseProcessInfoIsIOSAppOnMac) {
            pt_origBaseIsIOSAppOnMac = (pt_processInfo_bool_fn)method_getImplementation(mIos);
            class_replaceMethod(baseCls, iosOnMacSel, (IMP)pt_baseProcessInfoIsIOSAppOnMac, method_getTypeEncoding(mIos));
        }
    }
}

void pt_initializePlatformIdentity(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {
            BOOL useNativePlatform = PlaySettings.shared.useNativePlatform;
            atomic_store_explicit(&pt_use_native_platform, useNativePlatform, memory_order_relaxed);
            pt_ensure_device_settings_cached();
            if (!useNativePlatform) {
                pt_installIOSProcessIdentity();
            }
        }
    });
}

@implementation PlayLoader

+ (void)load {
    pt_initializePlatformIdentity();
}

static void __attribute__((constructor)) initialize(void) {
    NSInteger layoutIdiom = PlaySettings.shared.layoutIdiom;
    BOOL isPhoneIdiom = layoutIdiom == 1 || layoutIdiom == 3;
    if (isPhoneIdiom) {
        pt_installTencentVideoPhoneNavigation();
    }
    // Install CloudKit entitlement guard synchronously before any background startup queue runs.
    pt_installCloudKitCompatibilityHooks();
    pt_installUniversalCompatibilityGuards();
    [PlayCover launch];
    
    if (ue_status == 0) {
        if (PlayInfo.isUnrealEngine) {
            ue_status = 2;
        }
    }
    
    if (ue_status == 2) {
        init_ue_pattern();
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"UnrealEngine Hooked"]];
    }

    if ([[PlaySettings shared] blockSleepSpamming]) {
        // Add an observer so we can unlock threads on app termination
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [thread_sleep_lock unlock];
        }];
    }
}

@end
