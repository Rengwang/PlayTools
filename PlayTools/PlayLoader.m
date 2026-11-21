//
//  PlayLoader.m
//  PlayTools
//

#include <Foundation/Foundation.h>
#include <errno.h>
#include <stdatomic.h>
#include <sys/sysctl.h>

#import "PlayLoader.h"
#import <PlayTools/PlayTools-Swift.h>
#import <sys/utsname.h>
#import "NSObject+Swizzle.h"
#import <dlfcn.h>
#import <libkern/OSCacheControl.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <os/lock.h>

@import MachO;

// Cache device model / OEM ID / blockSleepSpamming once in C storage so hot
// libc interpose paths (sysctl/sysctlbyname/uname/usleep) avoid ObjC messaging.
#define PLATFORM_IOS 2

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

// Define dyld_get_active_platform function for interpose
int dyld_get_active_platform(void);
int pt_dyld_get_active_platform(void) { return PLATFORM_IOS; }

// Change the machine output by uname to match expected output on iOS
static int pt_uname(struct utsname *uts) {
    uname(uts);
    pt_ensure_device_settings_cached();
    strncpy(uts->machine, pt_cached_device_model_buf, sizeof(uts->machine) - 1);
    uts->machine[sizeof(uts->machine) - 1] = '\0';
    return 0;
}


// Update output of sysctl for key values hw.machine, hw.product and hw.target to match iOS output
// This spoofs the device type to apps allowing us to report as any iOS device
static int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
    if (name[0] == CTL_HW && (name[1] == HW_MACHINE || name[0] == HW_PRODUCT)) {
        pt_ensure_device_settings_cached();
        size_t needed = pt_cached_device_model_len + 1;
        if (NULL == buf) {
            *size = needed;
        } else {
            if (*size > needed) {
                memcpy(buf, pt_cached_device_model_buf, needed);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    } else if (name[0] == CTL_HW && (name[1] == HW_TARGET)) {
        pt_ensure_device_settings_cached();
        size_t needed = pt_cached_oem_id_len + 1;
        if (NULL == buf) {
            *size = needed;
        } else {
            if (*size > needed) {
                memcpy(buf, pt_cached_oem_id_buf, needed);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    }

    return sysctl(name, types, buf, size, arg0, arg1);
}

static int (* volatile pt_orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;

static int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int (*orig_fn)(const char *, void *, size_t *, void *, size_t) = pt_orig_sysctlbyname ? pt_orig_sysctlbyname : &sysctlbyname;
    if ((strcmp(name, "hw.machine") == 0) || (strcmp(name, "hw.product") == 0) || (strcmp(name, "hw.model") == 0)) {
        pt_ensure_device_settings_cached();
        size_t needed = pt_cached_device_model_len + 1;
        if (oldp == NULL) {
            *oldlenp = needed;
            return 0;
        }
        if (*oldlenp < needed) {
            return ENOMEM;
        }
        memcpy(oldp, pt_cached_device_model_buf, needed);
        *oldlenp = needed;
        return 0;
    } else if ((strcmp(name, "hw.target") == 0)) {
        pt_ensure_device_settings_cached();
        size_t needed = pt_cached_oem_id_len + 1;
        if (oldp == NULL) {
            *oldlenp = needed;
            return 0;
        }
        if (*oldlenp < needed) {
            return ENOMEM;
        }
        memcpy(oldp, pt_cached_oem_id_buf, needed);
        *oldlenp = needed;
        return 0;
    } else {
        return orig_fn(name, oldp, oldlenp, newp, newlen);
    }
}

// Interpose the functions create the wrapper
DYLD_INTERPOSE(pt_dyld_get_active_platform, dyld_get_active_platform)
DYLD_INTERPOSE(pt_uname, uname)
DYLD_INTERPOSE(pt_sysctlbyname, sysctlbyname)
DYLD_INTERPOSE(pt_sysctl, sysctl)

// Interpose Apple Keychain functions (SecItemCopyMatching, SecItemAdd, SecItemUpdate, SecItemDelete)
// This allows us to intercept keychain requests and return our own data

// Use the implementations from PlayKeychain
static OSStatus pt_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain copyMatching:(__bridge NSDictionary * _Nonnull)(query) result:result];
    } else {
        retval = SecItemCopyMatching(query, result);
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
        retval = SecItemAdd(attributes, result);
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
        retval = SecItemUpdate(query, attributesToUpdate);
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
        retval = SecItemDelete(query);
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
        result = SecKeyCreateRandomKey(parameters, (void *)error);
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
        retval = SecKeyGeneratePair(parameters, (void *)publicKey, (void *)privateKey);
    }
    
    if ([[PlaySettings shared] playChainDebugging]) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair: %@", parameters]];
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair public key result: %@", publicKey != NULL ? *publicKey : nil]];
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair private key result: %@", privateKey != NULL ? *privateKey : nil]];
    }
    
    return retval;
}

DYLD_INTERPOSE(pt_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(pt_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(pt_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(pt_SecItemDelete, SecItemDelete)
DYLD_INTERPOSE(pt_SecKeyCreateRandomKey, SecKeyCreateRandomKey)
DYLD_INTERPOSE(pt_SecKeyGeneratePair, SecKeyGeneratePair)

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

// Snapshot libc pointers at constructor time into writable globals (outside __got /
// __la_symbol_ptr) so clang cannot fold them back into symbol-stub calls and runtime
// fishhook/rebind_symbols hooks in apps (e.g. ByteDance Heimdallr) cannot create
// mutual recursion cycles (app_hook -> DYLD_INTERPOSE pt_* -> app_hook).
static int (* volatile pt_orig_open)(char const* restrict, int, ...) = NULL;
static int (* volatile pt_orig_stat)(char const* restrict, struct stat* restrict) = NULL;
static int (* volatile pt_orig_access)(char const*, int) = NULL;
static int (* volatile pt_orig_rename)(char const* restrict, char const* restrict) = NULL;
static int (* volatile pt_orig_unlink)(char const*) = NULL;
static int (* volatile pt_orig_usleep)(useconds_t) = NULL;

__attribute__((constructor(101))) static void pt_snapshot_libc_originals(void) {
    pt_orig_sysctlbyname = &sysctlbyname;
    pt_orig_open = &open;
    pt_orig_stat = &stat;
    pt_orig_access = &access;
    pt_orig_rename = &rename;
    pt_orig_unlink = &unlink;
    pt_orig_usleep = &usleep;
}

static int pt_open(char const* restrict filename, int oflag, ... ) {
    filename = ue_fix_filename(filename);
    int (*orig_fn)(char const* restrict, int, ...) = pt_orig_open ? pt_orig_open : &open;

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
    int (*orig_fn)(char const* restrict, struct stat* restrict) = pt_orig_stat ? pt_orig_stat : &stat;
    return orig_fn(ue_fix_filename(path), buf);
}

static int pt_access(char const* path, int mode) {
    int (*orig_fn)(char const*, int) = pt_orig_access ? pt_orig_access : &access;
    return orig_fn(ue_fix_filename(path), mode);
}

static int pt_rename(char const* restrict old_name, char const* restrict new_name) {
    int (*orig_fn)(char const* restrict, char const* restrict) = pt_orig_rename ? pt_orig_rename : &rename;
    return orig_fn(ue_fix_filename(old_name), ue_fix_filename(new_name));
}

static int pt_unlink(char const* path) {
    int (*orig_fn)(char const*) = pt_orig_unlink ? pt_orig_unlink : &unlink;
    return orig_fn(ue_fix_filename(path));
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
    
    int (*orig_fn)(useconds_t) = pt_orig_usleep ? pt_orig_usleep : &usleep;
    return orig_fn(time);
}


DYLD_INTERPOSE(pt_open, open)
DYLD_INTERPOSE(pt_stat, stat)
DYLD_INTERPOSE(pt_access, access)
DYLD_INTERPOSE(pt_rename, rename)
DYLD_INTERPOSE(pt_unlink, unlink)
DYLD_INTERPOSE(pt_usleep, usleep)

#pragma mark - Universal Catalyst Compatibility & Anti-Tamper Guards

// Neutralize raw inline `svc #0x80` exit stubs inside FirebaseNIMessInstallation
// when that module is loaded (no-op for apps that do not ship it).
static int pt_patchFirebaseInlineExits(void) {
    static const uint32_t exitRetPat[4] = { 0xd2800000, 0x52800030, 0xd4001001, 0xd65f03c0 };
    static const uint32_t exitClobberPat[4] = { 0xd2800000, 0x52800030, 0xd4001001, 0xd2800001 };

    int totalPatched = 0;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *imgName = _dyld_get_image_name(i);
        if (!imgName || strstr(imgName, "FirebaseNIMessInstallation") == NULL) continue;

        const struct mach_header *rawHdr = _dyld_get_image_header(i);
        if (!rawHdr || rawHdr->magic != MH_MAGIC_64) continue;
        const struct mach_header_64 *hdr = (const struct mach_header_64 *)rawHdr;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        const uint8_t *cursor = (const uint8_t *)(hdr + 1);
        for (uint32_t c = 0; c < hdr->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cursor;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                if ((seg->initprot & VM_PROT_EXECUTE) && seg->filesize >= 16) {
                    uintptr_t textStart = (uintptr_t)seg->vmaddr + (uintptr_t)slide;
                    uintptr_t textEnd = textStart + (uintptr_t)seg->vmsize;
                    vm_size_t pageSz = vm_page_size;
                    vm_address_t pageStart = textStart & ~(pageSz - 1);
                    vm_address_t pageEnd = (textEnd + pageSz - 1) & ~(pageSz - 1);
                    vm_size_t pageLen = pageEnd - pageStart;

                    kern_return_t kr = vm_protect(mach_task_self(), pageStart, pageLen, FALSE,
                                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                    if (kr == KERN_SUCCESS) {
                        for (uintptr_t addr = textStart; addr + 16 <= textEnd; addr += 4) {
                            const uint32_t *w = (const uint32_t *)addr;
                            if (w[0] == exitRetPat[0] && w[1] == exitRetPat[1] &&
                                w[2] == exitRetPat[2] && w[3] == exitRetPat[3]) {
                                *(uint32_t *)(addr + 8) = 0xd503201f; // nop svc #0x80 -> falls through to ret
                                totalPatched++;
                            } else if (w[0] == exitClobberPat[0] && w[1] == exitClobberPat[1] &&
                                       w[2] == exitClobberPat[2] && w[3] == exitClobberPat[3]) {
                                *(uint32_t *)(addr + 8) = 0xd65f03c0; // ret before mov sp, #0
                                totalPatched++;
                            }
                        }
                        vm_protect(mach_task_self(), pageStart, pageLen, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
                        sys_icache_invalidate((void *)textStart, (size_t)(textEnd - textStart));
                    }
                }
            }
            cursor += lc->cmdsize;
        }
    }
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

static void pt_installUniversalCompatibilityGuards(void) {
    pt_ensure_device_settings_cached();
    (void)pt_should_block_sleep_spamming();

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Prevent AppKit's "unexpectedly quit while reopening windows" modal from blocking Catalyst launch.
    [defaults setBool:YES forKey:@"ApplePersistenceIgnoreState"];
    pt_applyUIScaleFactor();

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
