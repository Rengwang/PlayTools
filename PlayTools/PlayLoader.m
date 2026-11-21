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

static int pt_uname(struct utsname *uts);
static int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1);
static int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static void *pt_dlsym(void *handle, const char *symbol);
static CFDictionaryRef pt_CFNetworkCopySystemProxySettings(void);
static CFArrayRef pt_CFNetworkCopyProxiesForURL(CFURLRef url, CFDictionaryRef proxySettings);
static int pt_getifaddrs(struct ifaddrs **ifap);
static void pt_freeifaddrs(struct ifaddrs *ifa);

typedef int (*pt_uname_fn)(struct utsname *);
typedef int (*pt_sysctl_fn)(int *, u_int, void *, size_t *, void *, size_t);
typedef int (*pt_sysctlbyname_fn)(const char *, void *, size_t *, void *, size_t);
typedef uint32_t (*pt_active_platform_fn)(void);
typedef void *(*pt_dlsym_fn)(void *, const char *);
typedef int (*pt_getifaddrs_fn)(struct ifaddrs **);
typedef void (*pt_freeifaddrs_fn)(struct ifaddrs *);
static uint32_t pt_active_platform(void);

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

static void *pt_dlsym(void *handle, const char *symbol) {
    pt_dlsym_fn orig_dlsym = DYLD_INTERPOSE_ORIG(pt_dlsym_fn, dlsym);
    static __thread BOOL pt_in_gles_dlsym = NO;
    if (!pt_in_gles_dlsym && handle == RTLD_DEFAULT && symbol != NULL &&
        symbol[0] == 'g' && symbol[1] == 'l' && symbol[2] >= 'A' && symbol[2] <= 'Z') {
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
    return orig_dlsym(handle, symbol);
}

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

static CFDictionaryRef pt_CFNetworkCopySystemProxySettings(void) {
    return CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                              &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static CFArrayRef pt_CFNetworkCopyProxiesForURL(CFURLRef url, CFDictionaryRef proxySettings) {
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

static int pt_getifaddrs(struct ifaddrs **ifap) {
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

static void pt_freeifaddrs(struct ifaddrs *ifa) {
    if (!ifa) return;
    struct ifaddrs *realHead = consumeRealIfaddrsHead(ifa);
    DYLD_INTERPOSE_ORIG(pt_freeifaddrs_fn, freeifaddrs)(realHead);
}

static uint32_t pt_active_platform(void) {
    if (atomic_load_explicit(&pt_use_native_platform, memory_order_relaxed)) {
        return DYLD_INTERPOSE_ORIG(pt_active_platform_fn, dyld_get_active_platform)();
    }
    return PLATFORM_IOS;
}
// Change the machine output by uname to match expected output on iOS
static int pt_uname(struct utsname *uts) {
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
static int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
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

static int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
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

// Interpose Apple Keychain functions (SecItemCopyMatching, SecItemAdd, SecItemUpdate, SecItemDelete)
// This allows us to intercept keychain requests and return our own data

typedef OSStatus (*pt_SecItemCopyMatching_fn)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*pt_SecItemAdd_fn)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*pt_SecItemUpdate_fn)(CFDictionaryRef, CFDictionaryRef);
typedef OSStatus (*pt_SecItemDelete_fn)(CFDictionaryRef);
typedef SecKeyRef (*pt_SecKeyCreateRandomKey_fn)(CFDictionaryRef, CFErrorRef *);
typedef OSStatus (*pt_SecKeyGeneratePair_fn)(CFDictionaryRef, SecKeyRef *, SecKeyRef *);

static OSStatus pt_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result);
static OSStatus pt_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus pt_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
static OSStatus pt_SecItemDelete(CFDictionaryRef query);
static SecKeyRef pt_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error);
static OSStatus pt_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey);

DYLD_INTERPOSE(pt_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(pt_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(pt_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(pt_SecItemDelete, SecItemDelete)
DYLD_INTERPOSE(pt_SecKeyCreateRandomKey, SecKeyCreateRandomKey)
DYLD_INTERPOSE(pt_SecKeyGeneratePair, SecKeyGeneratePair)

// Use the implementations from PlayKeychain
static OSStatus pt_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
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

static OSStatus pt_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
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

static OSStatus pt_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
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

static OSStatus pt_SecItemDelete(CFDictionaryRef query) {
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

static SecKeyRef pt_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
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
static OSStatus pt_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
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

static int pt_open(char const* restrict filename, int oflag, ...);
static int pt_stat(char const* restrict path, struct stat* restrict buf);
static int pt_access(char const* path, int mode);
static int pt_rename(char const* restrict old_name, char const* restrict new_name);
static int pt_unlink(char const* path);
static int pt_usleep(useconds_t time);

DYLD_INTERPOSE(pt_open, open)
DYLD_INTERPOSE(pt_stat, stat)
DYLD_INTERPOSE(pt_access, access)
DYLD_INTERPOSE(pt_rename, rename)
DYLD_INTERPOSE(pt_unlink, unlink)
DYLD_INTERPOSE(pt_usleep, usleep)

static int pt_open(char const* restrict filename, int oflag, ... ) {
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

static int pt_stat(char const* restrict path, struct stat* restrict buf) {
    return DYLD_INTERPOSE_ORIG(pt_stat_fn, stat)(ue_fix_filename(path), buf);
}

static int pt_access(char const* path, int mode) {
    return DYLD_INTERPOSE_ORIG(pt_access_fn, access)(ue_fix_filename(path), mode);
}

static int pt_rename(char const* restrict old_name, char const* restrict new_name) {
    return DYLD_INTERPOSE_ORIG(pt_rename_fn, rename)(ue_fix_filename(old_name), ue_fix_filename(new_name));
}

static int pt_unlink(char const* path) {
    return DYLD_INTERPOSE_ORIG(pt_unlink_fn, unlink)(ue_fix_filename(path));
}

static NSMutableDictionary *thread_sleep_counters = nil;
static NSMutableDictionary *last_sleep_attempts = nil;
static dispatch_once_t thread_sleep_once;
static NSLock *thread_sleep_lock = nil;

static int pt_usleep(useconds_t time) {
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
static CFAbsoluteTime pt_lastRemoteRegTime = 0;

// Rate-limit -[UIApplication registerForRemoteNotifications] so ad-hoc apps without
// APNs entitlements do not spin in a 200% CPU failure/retry loop (e.g. JPush/TIMPush).
static void pt_registerForRemoteNotifications(id self, SEL _cmd) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL allow = NO;
    os_unfair_lock_lock(&pt_remoteRegLock);
    if (pt_lastRemoteRegTime == 0 || (now - pt_lastRemoteRegTime) >= 30.0) {
        pt_lastRemoteRegTime = now;
        allow = YES;
    }
    os_unfair_lock_unlock(&pt_remoteRegLock);
    if (!allow) return;
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
        [defaults removeObjectForKey:@"iOSMacScaleFactor"];
        [defaults removeObjectForKey:@"UINSLastUsedWindowScaleFactor"];
    } else if (uiScale >= 0.5 && uiScale <= 3.0) {
        [defaults setDouble:uiScale forKey:@"iOSMacScaleFactor"];
        [defaults removeObjectForKey:@"UINSLastUsedWindowScaleFactor"];
    } else {
        [defaults setDouble:1.0 forKey:@"iOSMacScaleFactor"];
        [defaults removeObjectForKey:@"UINSLastUsedWindowScaleFactor"];
    }
    [defaults synchronize];
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
            if (primaryWindow.windowScene == nil) {
                primaryWindow.windowScene = scene;
            }
            primaryWindow.rootViewController = vc;
            if (!CGRectIsEmpty(scene.coordinateSpace.bounds) && CGRectIsEmpty(primaryWindow.bounds)) {
                primaryWindow.frame = scene.coordinateSpace.bounds;
            }
            [primaryWindow makeKeyAndVisible];
            NSLog(@"[PlayTools] Empty scene window recovery: attached %@ to %@",
                  NSStringFromClass([vc class]),
                  NSStringFromClass([primaryWindow class]));
        }
    } else if (primaryWindow.rootViewController != nil && (primaryWindow.windowScene == nil || primaryWindow.hidden)) {
        if (primaryWindow.windowScene == nil) {
            primaryWindow.windowScene = scene;
        }
        if (!CGRectIsEmpty(scene.coordinateSpace.bounds) && CGRectIsEmpty(primaryWindow.bounds)) {
            primaryWindow.frame = scene.coordinateSpace.bounds;
        }
        [primaryWindow makeKeyAndVisible];
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
static os_unfair_lock pt_appGroupCacheLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSURL *> *pt_appGroupURLCache = nil;

static NSURL *pt_containerURLForGroupIdentifier(NSFileManager *self, SEL _cmd, NSString *groupIdentifier) {
    NSURL *origURL = pt_origContainerURLForGroupIdentifier ? pt_origContainerURLForGroupIdentifier(self, _cmd, groupIdentifier) : nil;
    if (groupIdentifier.length == 0) {
        return origURL;
    }

    os_unfair_lock_lock(&pt_appGroupCacheLock);
    NSURL *cached = pt_appGroupURLCache[groupIdentifier];
    os_unfair_lock_unlock(&pt_appGroupCacheLock);
    if (cached) {
        return cached;
    }

    NSURL *resolvedURL = nil;
    if (origURL != nil) {
        const char *fsPath = origURL.path.fileSystemRepresentation;
        if (fsPath && fsPath[0] != '\0') {
            if (access(fsPath, W_OK) == 0) {
                resolvedURL = origURL;
            } else if ([self createDirectoryAtURL:origURL withIntermediateDirectories:YES attributes:nil error:nil] &&
                       access(fsPath, W_OK) == 0) {
                resolvedURL = origURL;
            }
        }
    }

    if (!resolvedURL) {
        NSString *sanitized = [[groupIdentifier stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
            stringByReplacingOccurrencesOfString:@".." withString:@"_"];
        if (sanitized.length == 0) {
            sanitized = @"default";
        }
        NSURL *appSupport = [self URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        if (appSupport) {
            NSURL *fallbackURL = [[appSupport URLByAppendingPathComponent:@"PlayCoverGroupContainers" isDirectory:YES]
                URLByAppendingPathComponent:sanitized isDirectory:YES];
            [self createDirectoryAtURL:fallbackURL withIntermediateDirectories:YES attributes:nil error:nil];
            resolvedURL = fallbackURL;
        }
    }

    if (resolvedURL) {
        os_unfair_lock_lock(&pt_appGroupCacheLock);
        if (!pt_appGroupURLCache) {
            pt_appGroupURLCache = [NSMutableDictionary new];
        }
        NSURL *existing = pt_appGroupURLCache[groupIdentifier];
        if (existing) {
            resolvedURL = existing;
        } else {
            pt_appGroupURLCache[groupIdentifier] = resolvedURL;
        }
        os_unfair_lock_unlock(&pt_appGroupCacheLock);
    }

    return resolvedURL;
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

static void (*pt_origVBLogTestedFaults)(id, SEL, const void *) = NULL;
static BOOL pt_vbFaultGuardInstalled = NO;

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
    }
}

static void pt_installViewBridgeFaultGuard(void) {
    pt_tryInstallViewBridgeFaultGuardNow();
    if (!pt_vbFaultGuardInstalled) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:NSBundleDidLoadNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification * _Nonnull note) {
            pt_tryInstallViewBridgeFaultGuardNow();
        }];
        [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification * _Nonnull note) {
            pt_tryInstallViewBridgeFaultGuardNow();
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

static void pt_installUniversalCompatibilityGuards(void) {
    pt_ensure_device_settings_cached();
    (void)pt_should_block_sleep_spamming();

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Prevent AppKit's "unexpectedly quit while reopening windows" modal from blocking Catalyst launch.
    [defaults setBool:YES forKey:@"ApplePersistenceIgnoreState"];
    pt_applyUIScaleFactor();

    pt_installAppGroupContainerGuard();
    pt_installOrphanWindowSceneGuard();
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

static void pt_installTerminationTimeoutHooks(void) {
    pt_tryInstallTerminationTimeoutHookNow();
    if (!pt_terminationHookInstalled) {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            pt_tryInstallTerminationTimeoutHookNow();
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

static void pt_tryInstallCloudKitHooksNow(void) {
    if (pt_cloudKitHooksInstalled) {
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
}

static void pt_installCloudKitCompatibilityHooks(void) {
    pt_tryInstallCloudKitHooksNow();
    if (!pt_cloudKitHooksInstalled) {
        [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            pt_tryInstallCloudKitHooksNow();
        }];
    }
}

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
    BOOL useNativePlatform = PlaySettings.shared.useNativePlatform;
    NSInteger layoutIdiom = PlaySettings.shared.layoutIdiom;
    BOOL isPhoneIdiom = layoutIdiom == 1 || layoutIdiom == 3;
    atomic_store_explicit(&pt_use_native_platform, useNativePlatform, memory_order_relaxed);
    [PlayInfo installPlatformIdentityWithUseNativePlatform:useNativePlatform isPhoneIdiom:isPhoneIdiom];
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
