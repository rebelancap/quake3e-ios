// ios_metal.m — the Metal/Vulkan boundary. Deliberately includes NO
// engine headers (ObjC 'id' keyword vs engine identifiers) and uses
// MoltenVK's own Vulkan headers. The engine side (ios_glue.c) talks to
// this file through plain C functions and void pointers.

#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>

#define VK_USE_PLATFORM_METAL_EXT 1
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan.h>

// Exported by the statically linked MoltenVK.
extern PFN_vkVoidFunction vkGetInstanceProcAddr(VkInstance instance, const char *pName);

CAMetalLayer *q3e_layer = NULL;

// AVAudioSession policy, the interruption/route observers and the master mix
// gain all moved to ios_audio.m when the Audio settings section landed — the
// session's category is now a user choice, so it needs somewhere of its own.

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
