//
//  PlayShadow.m
//  PlayTools
//
//  Created by Venti on 08/03/2023.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <PlayTools/PlayTools-Swift.h>
#import "NSObject+Swizzle.h"

__attribute__((visibility("hidden")))
@interface PlayShadowLoader : NSObject
@end

@implementation NSObject (ShadowSwizzle)

// Instance methods

- (NSInteger) pm_hook_deviceType {
    return 1;
}

- (bool) pm_return_false {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return false;
}

- (bool) pm_return_true {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return true;
}

- (BOOL) pm_return_yes {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return YES;
}

- (BOOL) pm_return_no {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return NO;
}

- (int) pm_return_0 {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return 0;
}

- (int) pm_return_1 {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return 1;
}

- (NSString *) pm_return_empty {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return @"";
}

- (NSDictionary *) pm_return_empty_dictionary {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return @{};
}

// Endfield UIAlertController hook
- (void)pm_endfield_presentViewController:(UIViewController *)viewControllerToPresent
                                 animated:(BOOL)flag
                               completion:(void (^)(void))completion {
    // If it's a UIAlertController, silently ignore it
    if ([viewControllerToPresent isKindOfClass:[UIAlertController class]]) {
        NSLog(@"PC-DEBUG: [PlayShadow] Blocked UIAlertController for Endfield");
        if (completion) {
            completion();
        }
        return;
    }
    
    // Otherwise, present normally
    [self pm_endfield_presentViewController:viewControllerToPresent animated:flag completion:completion];
}

// Class methods

+ (void) pm_return_2_with_completion_handler:(void (^)(NSInteger))completionHandler {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    completionHandler(2);
}

+ (NSInteger) pm_return_2 {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return 2;
}

+ (bool) pm_clsm_return_false {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return false;
}

+ (bool) pm_clsm_return_true {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return true;
}

+ (BOOL) pm_clsm_return_yes {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return YES;
}

+ (BOOL) pm_clsm_return_no {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return NO;
}

+ (int) pm_clsm_do_nothing_with_callback:(void (^)(int))callback {
    // NSLog(@"PC-DEBUG: [PlayMask] Jailbreak Detection Attempted");
    return 0;
}

@end

@implementation PlayShadowLoader

+ (void) load {
    [self debugLogger:@"PlayShadow is now loading"];
    // Gate this behind an environment variable
    if ([[NSProcessInfo processInfo].environment[@"USE_EXTRA_ANTIJB"] isEqualToString:@"1"]) {
        [self loadJailbreakBypass];
    }
    // if ([[PlaySettings shared] bypass]) [self loadEnvironmentBypass]; # disabled as it might be too powerful

    // Swizzle ATTrackingManager
    pt_swizzleClassMethod(objc_getClass("ATTrackingManager"), @selector(requestTrackingAuthorizationWithCompletionHandler:), @selector(pm_return_2_with_completion_handler:));
    pt_swizzleClassMethod(objc_getClass("ATTrackingManager"), @selector(trackingAuthorizationStatus), @selector(pm_return_2));
    
    
    // canResizeToFitContent
    // [objc_getClass("UIWindow") swizzleInstanceMethod:@selector(canResizeToFitContent) withMethod:@selector(pm_return_true)];
    
    // Block UIAlertController presentation to bypass Endfield jailbreak message
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.gryphline.endfield.ios"] || 
    [bundleID isEqualToString:@"com.hypergryph.endfield"]) {
        [self debugLogger:@"loading UIAlertController bypass"];
        pt_swizzleInstanceMethod(objc_getClass("UIViewController"), @selector(presentViewController:animated:completion:), @selector(pm_endfield_presentViewController:animated:completion:));
    }
    
    if ([bundleID isEqualToString:@"com.kurogame.wutheringwaves.global"] || [bundleID isEqualToString:@"com.kurogame.mingchao"]) {
        pt_swizzleInstanceMethod(objc_getClass("KRDeclaredAgeRangeService"), @selector(isAgeRangeRequestAvailable), @selector(pm_return_false));
    }
   
}

+ (void) loadJailbreakBypass {
    [self debugLogger:@"Jailbreak bypass loading"];
    // Swizzle NSProcessInfo to troll every app that tries to detect macCatalyst
    // [objc_getClass("NSProcessInfo") swizzleInstanceMethod:@selector(isMacCatalystApp) withMethod:@selector(pm_return_false)];
    // [objc_getClass("NSProcessInfo") swizzleInstanceMethod:@selector(isiOSAppOnMac) withMethod:@selector(pm_return_true)];

    // Some device info class
    pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(platform), @selector(pm_return_empty));
    pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(hwModel), @selector(pm_return_empty));
    pt_swizzleInstanceMethod(objc_getClass("RNDeviceInfo"), @selector(getDeviceType), @selector(pm_hook_deviceType));
        
    // Class: UIDevice
    pt_swizzleClassMethod(objc_getClass("UIDevice"), @selector(isJailbroken), @selector(pm_clsm_return_no));
    pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(isJailBreak), @selector(pm_return_no));
    pt_swizzleInstanceMethod(objc_getClass("UIDevice"), @selector(isJailBroken), @selector(pm_return_no));

    // Class: JailbreakDetectionVC
    pt_swizzleInstanceMethod(objc_getClass("JailbreakDetectionVC"), @selector(isJailbroken), @selector(pm_return_no));

    // Class: DTTJailbreakDetection
    pt_swizzleClassMethod(objc_getClass("DTTJailbreakDetection"), @selector(isJailbroken), @selector(pm_clsm_return_no));

    // Class: ANSMetadata
    pt_swizzleInstanceMethod(objc_getClass("ANSMetadata"), @selector(computeIsJailbroken), @selector(pm_return_no));
    pt_swizzleInstanceMethod(objc_getClass("ANSMetadata"), @selector(isJailbroken), @selector(pm_return_no));

    // Class: AppsFlyerUtils
    pt_swizzleClassMethod(objc_getClass("AppsFlyerUtils"), @selector(isJailBreakon), @selector(pm_clsm_return_no));
    pt_swizzleClassMethod(objc_getClass("AppsFlyerUtils"), @selector(isJailbroken), @selector(pm_clsm_return_no));
    pt_swizzleClassMethod(objc_getClass("AppsFlyerUtils"), @selector(isJailbrokenWithSkipAdvancedJailbreakValidation:), @selector(pm_clsm_return_false));

    // Class: jailBreak
    pt_swizzleClassMethod(objc_getClass("jailBreak"), @selector(isJailBreak), @selector(pm_clsm_return_false));

    // Class: GBDeviceInfo
    pt_swizzleInstanceMethod(objc_getClass("GBDeviceInfo"), @selector(isJailbroken), @selector(pm_return_no));

    // Class: CMARAppRestrictionsDelegate
    pt_swizzleInstanceMethod(objc_getClass("CMARAppRestrictionsDelegate"), @selector(isDeviceNonCompliant), @selector(pm_return_false));

    // Class: ADYSecurityChecks
    pt_swizzleClassMethod(objc_getClass("ADYSecurityChecks"), @selector(isDeviceJailbroken), @selector(pm_clsm_return_false));

    // Class: UBReportMetadataDevice
    pt_swizzleInstanceMethod(objc_getClass("UBReportMetadataDevice"), @selector(is_rooted), @selector(pm_return_null));

    // Class: UtilitySystem
    pt_swizzleClassMethod(objc_getClass("UtilitySystem"), @selector(isJailbreak), @selector(pm_clsm_return_false));

    // Class: GemaltoConfiguration
    pt_swizzleClassMethod(objc_getClass("GemaltoConfiguration"), @selector(isJailbreak), @selector(pm_clsm_return_false));

    // Class: CPWRDeviceInfo
    pt_swizzleInstanceMethod(objc_getClass("CPWRDeviceInfo"), @selector(isJailbroken), @selector(pm_return_false));

    // Class: CPWRSessionInfo
    pt_swizzleInstanceMethod(objc_getClass("CPWRSessionInfo"), @selector(isJailbroken), @selector(pm_return_false));

    // Class: KSSystemInfo
    pt_swizzleClassMethod(objc_getClass("KSSystemInfo"), @selector(isJailbroken), @selector(pm_clsm_return_false));

    // Class: EMDSKPPConfiguration
    pt_swizzleInstanceMethod(objc_getClass("EMDSKPPConfiguration"), @selector(jailBroken), @selector(pm_return_false));

    // Class: EnrollParameters
    pt_swizzleInstanceMethod(objc_getClass("EnrollParameters"), @selector(jailbroken), @selector(pm_return_null));

    // Class: EMDskppConfigurationBuilder
    pt_swizzleInstanceMethod(objc_getClass("EMDskppConfigurationBuilder"), @selector(jailbreakStatus), @selector(pm_return_false));

    // Class: FCRSystemMetadata
    pt_swizzleInstanceMethod(objc_getClass("FCRSystemMetadata"), @selector(isJailbroken), @selector(pm_return_false));

    // Class: v_VDMap
    pt_swizzleInstanceMethod(objc_getClass("v_VDMap"), @selector(isJailbrokenDetected), @selector(pm_return_false));
    pt_swizzleInstanceMethod(objc_getClass("v_VDMap"), @selector(isJailBrokenDetectedByVOS), @selector(pm_return_false));
    pt_swizzleInstanceMethod(objc_getClass("v_VDMap"), @selector(isDFPHookedDetecedByVOS), @selector(pm_return_false));
    pt_swizzleInstanceMethod(objc_getClass("v_VDMap"), @selector(isCodeInjectionDetectedByVOS), @selector(pm_return_false));
    pt_swizzleInstanceMethod(objc_getClass("v_VDMap"), @selector(isDebuggerCheckDetectedByVOS), @selector(pm_return_false));
    pt_swizzleInstanceMethod(objc_getClass("v_VDMap"), @selector(isAppSignerCheckDetectedByVOS), @selector(pm_return_false));
    pt_swizzleInstanceMethod(objc_getClass("v_VDMap"), @selector(v_checkAModified), @selector(pm_return_false));
    pt_swizzleInstanceMethod(objc_getClass("v_VDMap"), @selector(isRuntimeTamperingDetected), @selector(pm_return_false));

    // Class: SDMUtils
    pt_swizzleInstanceMethod(objc_getClass("SDMUtils"), @selector(isJailBroken), @selector(pm_return_no));

    // Class: OneSignalJailbreakDetection
    pt_swizzleClassMethod(objc_getClass("OneSignalJailbreakDetection"), @selector(isJailbroken), @selector(pm_clsm_return_no));

    // Class: DigiPassHandler
    pt_swizzleInstanceMethod(objc_getClass("DigiPassHandler"), @selector(rootedDeviceTestResult), @selector(pm_return_no));

    // Class: AWMyDeviceGeneralInfo
    pt_swizzleInstanceMethod(objc_getClass("AWMyDeviceGeneralInfo"), @selector(isCompliant), @selector(pm_return_true));

    // Class: DTXSessionInfo
    pt_swizzleInstanceMethod(objc_getClass("DTXSessionInfo"), @selector(isJailbroken), @selector(pm_return_false));

    // Class: DTXDeviceInfo
    pt_swizzleInstanceMethod(objc_getClass("DTXDeviceInfo"), @selector(isJailbroken), @selector(pm_return_false));

    // Class: JailbreakDetection
    pt_swizzleInstanceMethod(objc_getClass("JailbreakDetection"), @selector(jailbroken), @selector(pm_return_false));

    // Class: jailBrokenJudge
    pt_swizzleInstanceMethod(objc_getClass("jailBrokenJudge"), @selector(isJailBreak), @selector(pm_return_false));
    pt_swizzleInstanceMethod(objc_getClass("jailBrokenJudge"), @selector(isCydiaJailBreak), @selector(pm_return_false));
    pt_swizzleInstanceMethod(objc_getClass("jailBrokenJudge"), @selector(isApplicationsJailBreak), @selector(pm_return_false));
    pt_swizzleInstanceMethod(objc_getClass("jailBrokenJudge"), @selector(ischeckCydiaJailBreak), @selector(pm_return_false));
    pt_swizzleInstanceMethod(objc_getClass("jailBrokenJudge"), @selector(isPathJailBreak), @selector(pm_return_false));
    pt_swizzleInstanceMethod(objc_getClass("jailBrokenJudge"), @selector(boolIsjailbreak), @selector(pm_return_false));

    // Class: FBAdBotDetector
    pt_swizzleInstanceMethod(objc_getClass("FBAdBotDetector"), @selector(isJailBrokenDevice), @selector(pm_return_false));

    // Class: TNGDeviceTool
    pt_swizzleClassMethod(objc_getClass("TNGDeviceTool"), @selector(isJailBreak), @selector(pm_clsm_return_false));
    pt_swizzleClassMethod(objc_getClass("TNGDeviceTool"), @selector(isJailBreak_file), @selector(pm_clsm_return_false));
    pt_swizzleClassMethod(objc_getClass("TNGDeviceTool"), @selector(isJailBreak_cydia), @selector(pm_clsm_return_false));
    pt_swizzleClassMethod(objc_getClass("TNGDeviceTool"), @selector(isJailBreak_appList), @selector(pm_clsm_return_false));
    pt_swizzleClassMethod(objc_getClass("TNGDeviceTool"), @selector(isJailBreak_env), @selector(pm_clsm_return_false));

    // Class: DTDeviceInfo
    pt_swizzleClassMethod(objc_getClass("DTDeviceInfo"), @selector(isJailbreak), @selector(pm_clsm_return_false));

    // Class: SecVIDeviceUtil
    pt_swizzleClassMethod(objc_getClass("SecVIDeviceUtil"), @selector(isJailbreak), @selector(pm_clsm_return_false));

    // Class: RVPBridgeExtension4Jailbroken
    pt_swizzleInstanceMethod(objc_getClass("RVPBridgeExtension4Jailbroken"), @selector(isJailbroken), @selector(pm_return_false));

    // Class: ZDetection
    pt_swizzleClassMethod(objc_getClass("ZDetection"), @selector(isRootedOrJailbroken), @selector(pm_clsm_return_false));
}

+ (void) loadEnvironmentBypass {
    [self debugLogger:@"Environment bypass loading"];
    // Completely nuke everything in the environment variables
    pt_swizzleInstanceMethod(objc_getClass("NSProcessInfo"), @selector(environment), @selector(pm_return_empty_dictionary));
}

+ (void) debugLogger: (NSString *) message {
    NSLog(@"PC-DEBUG: %@", message);
}

@end
