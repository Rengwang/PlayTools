//
//  MediaVolume.m
//  PlayTools
//
//  Created by Undefined on 2025/12/20.
//

#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <PlayTools/PlayTools-Swift.h>
#import "MediaVolume.h"
#import "NSObject+Swizzle.h"

__attribute__((visibility("hidden")))
@interface MediaVolumeLoader : NSObject
@end

@implementation NSObject (SwizzleVolume)

- (float)pm_get_volume {
    return 0.3f;
}

- (void)pm_set_volume:(float)value {
    return;
}

- (void)pm_set_volume:(float)value animated:(BOOL)animated {
    return;
}

@end

@implementation MediaVolumeLoader

+ (void)load {
    pt_swizzleInstanceMethod(objc_getClass("AVAudioSession"), @selector(outputVolume), @selector(pm_get_volume));
    
    pt_swizzleInstanceMethod(objc_getClass("MPVolumeSlider"), @selector(value), @selector(pm_get_volume));
    pt_swizzleInstanceMethod(objc_getClass("MPVolumeSlider"), @selector(setValue:), @selector(pm_set_volume:));
    pt_swizzleInstanceMethod(objc_getClass("MPVolumeSlider"), @selector(setValue:animated:), @selector(pm_set_volume:animated:));
    
    pt_swizzleInstanceMethod(objc_getClass("MPMusicPlayerController"), @selector(volume), @selector(pm_get_volume));
    pt_swizzleInstanceMethod(objc_getClass("MPMusicPlayerController"), @selector(setVolume:), @selector(pm_set_volume:));
}

@end
