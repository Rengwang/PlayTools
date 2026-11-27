//
//  PlayEfficiencyHooks.h
//  PlayTools
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PTEfficiencyHooks : NSObject

+ (void)installIfNeeded;
+ (void)trimRegisteredNSCaches;

@end

NS_ASSUME_NONNULL_END
