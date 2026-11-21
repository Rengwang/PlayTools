//
//  BatteryLevel.m
//  PlayTools
//
//  Created by Edoardo C. on 07/08/24.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <PlayTools/PlayTools-Swift.h>
#import "BatteryLevel.h"
#import "NSObject+Swizzle.h"

__attribute__((visibility("hidden")))
@interface BatteryLevelLoader : NSObject
@end

@implementation NSObject (SwizzleBattery)

- (bool) pm_return_true {
    return true;
}

- (float) pm_return_battery_full {
    return 1.0;
}

- (UIDeviceBatteryState) pm_return_fullCharging {
    return UIDeviceBatteryStateFull;
}
@end

@implementation BatteryLevelLoader
+ (void)load {
    if (![[PlaySettings shared] spoofPowerState]) {
        return;
    }
    Class uiDeviceCls = objc_getClass("UIDevice");
    pt_swizzleInstanceMethod(uiDeviceCls, @selector(isBatteryMonitoringEnabled), @selector(pm_return_true));
    pt_swizzleInstanceMethod(uiDeviceCls, @selector(batteryState), @selector(pm_return_fullCharging));
    pt_swizzleInstanceMethod(uiDeviceCls, @selector(batteryLevel), @selector(pm_return_battery_full));
    [PlayInfo installPowerStateHooksIfNeeded];
}
@end
