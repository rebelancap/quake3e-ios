// ios_metal.m — the Metal/Vulkan boundary. Deliberately includes NO
// engine headers (ObjC 'id' keyword vs engine identifiers) and uses
// MoltenVK's own Vulkan headers. The engine side (ios_glue.c) talks to
// this file through plain C functions and void pointers.

#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#define VK_USE_PLATFORM_METAL_EXT 1
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan.h>

// Exported by the statically linked MoltenVK.
extern PFN_vkVoidFunction vkGetInstanceProcAddr(VkInstance instance, const char *pName);

CAMetalLayer *q3e_layer = NULL;

// AudioQueue control lives in ios_snd.c (pure C).
extern void Q3E_SND_Pause(void);
extern void Q3E_SND_Resume(void);

static void q3e_reactivate_session(void) {
    NSError *err = nil;
    if (![AVAudioSession.sharedInstance setActive:YES error:&err]) {
        NSLog(@"Q3E: audio reactivate error: %@", err);
    }
}

void Q3E_ActivateAudioSession(void) {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *err = nil;

    // Ambient (the old default) is silenced by the hardware Ring/Silent
    // switch — a game played with the ringer off would be mute, the
    // single most likely field report. .playback ignores the mute switch;
    // .mixWithOthers keeps the user's own Music/podcast audio alive
    // underneath the game. No UIBackgroundModes=audio, so iOS still
    // deactivates us on background (scene-resign already pauses audio).
    if (![session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&err]) {
        NSLog(@"Q3E: audio category error: %@", err);
    }
    if (![session setActive:YES error:&err]) {
        NSLog(@"Q3E: audio activate error: %@", err);
    }

    static BOOL observing = NO;
    if (observing) return;
    observing = YES;

    // A phone call / Siri / alarm interrupts and stops the AudioQueue; the
    // engine keeps mixing into a stalled queue and the game is silent
    // forever after. Pause on Began; reactivate the session and restart
    // the queue on Ended (D-007's still-open interruption item).
    [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification
        object:session queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
        if (type == AVAudioSessionInterruptionTypeBegan) {
            Q3E_SND_Pause();
            NSLog(@"Q3E: audio interruption began — queue paused");
        } else if (type == AVAudioSessionInterruptionTypeEnded) {
            q3e_reactivate_session();
            Q3E_SND_Resume();
            NSLog(@"Q3E: audio interruption ended — session reactivated, queue resumed");
        }
    }];

    // Route change (headphones/BT unplug, dock): the AudioQueue follows the
    // new route automatically; re-assert the session so a system
    // deactivation on the transition can't leave us silently muted.
    [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionRouteChangeNotification
        object:session queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSInteger reason = [n.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue];
        if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
            q3e_reactivate_session();
        }
        NSLog(@"Q3E: audio route change (reason %ld)", (long)reason);
    }];
}

int Q3E_LayerWidth(void)  { return (int)q3e_layer.drawableSize.width; }
int Q3E_LayerHeight(void) { return (int)q3e_layer.drawableSize.height; }
int Q3E_DisplayMaxFPS(void) {
#if TARGET_OS_VISION
    // UIScreen (and the panel's true max) is unqueryable on visionOS. Report the
    // ceiling the shell requests from CADisplayLink: 120 on the M5 Vision Pro,
    // clamped to 90 by the OS on earlier panels. (Feeds glconfig.displayFrequency.)
    return 120;
#else
    return (int)UIScreen.mainScreen.maximumFramesPerSecond;
#endif
}

int Q3E_ThermalState(void) { return (int)NSProcessInfo.processInfo.thermalState; }

// Clipboard read for Sys_GetClipboardData (paste a server address/password
// into the console or connect field). Returns an autoreleased UTF-8 string
// valid for the current runloop turn; the C caller copies it immediately.
const char *Q3E_ClipboardText(void) {
    NSString *s = UIPasteboard.generalPasteboard.string;
    return s.length ? s.UTF8String : NULL;
}

void *Q3E_GetInstanceProcAddr(void *instance, const char *name) {
    return (void *)vkGetInstanceProcAddr((VkInstance)instance, name);
}

int Q3E_CreateMetalSurface(void *instance, void **surfaceOut) {
    PFN_vkCreateMetalSurfaceEXT createSurface =
        (PFN_vkCreateMetalSurfaceEXT)vkGetInstanceProcAddr((VkInstance)instance, "vkCreateMetalSurfaceEXT");
    if (!createSurface) {
        NSLog(@"Q3E-SPIKE: vkCreateMetalSurfaceEXT not available");
        return 0;
    }
    VkMetalSurfaceCreateInfoEXT info = {
        .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
        .pLayer = q3e_layer,
    };
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    VkResult r = createSurface((VkInstance)instance, &info, NULL, &surface);
    if (r != VK_SUCCESS) {
        NSLog(@"Q3E-SPIKE: vkCreateMetalSurfaceEXT failed: %d", (int)r);
        return 0;
    }
    *surfaceOut = (void *)surface;
    NSLog(@"Q3E-SPIKE: Metal surface created on layer %@ (%.0fx%.0f)",
          q3e_layer, q3e_layer.drawableSize.width, q3e_layer.drawableSize.height);
    return 1;
}
