#pragma once
#import <UIKit/UIKit.h>

// The visionOS 2D-window engine view controller (implemented in AppShell_vision.m).
// Hosted by the SwiftUI WindowGroup in Q3EVisionApp.swift.
@interface Q3EVisionViewController : UIViewController
@end

// Handle a quake3e:// deep-link / launch URL (mod launch). Called from SwiftUI
// onOpenURL. Safe to call with any string; non-matching URLs are ignored.
void Q3E_HandleURL(const char *url);

// Toggle the 3D immersive mode. Owns the gw_minimized-before-open ordering so the
// engine goes off-screen before the window hides (the freeze fix). Called by the
// Enter 3D button and the `stereo` command.
void Q3E_Enter3D(bool on);

// Called by the immersive render loop when the space is dismissed (Crown), to
// reconcile shell state + the SwiftUI model/button.
void Q3E_Immersive_Ended(void);

// The mode machine's single entry point (Q3E_MODE_2D / _3D / _VR). Marshals
// itself to the main thread, so it is safe to call from a console command that
// the engine thread is executing.
void Q3E_EnterMode(int mode);

// Re-assert the spatial-audio experience for the CURRENT mode. Called from the
// space dismissal completions, which can otherwise land after a newer mode has
// already set the one it wants.
void Q3E_AssertModePolicy(void);

// openImmersiveSpace refused to open the VR space — roll the entry back.
void Q3E_VR_OpenFailed(void);

// Test hooks (console-driven): emulate the device's dead display link, and force
// an entry to fail so the rollback path can be asserted.
void Q3E_DebugFreezeLink(int on);
void Q3E_DebugFailEntry(int on);

// Present the settings sheet from the active window's root VC (no source view needed).
// The ornament calls this so settings is reachable while immersive — the 3D sliders
// (distance / size / depth) update the floating panel live.
void Q3E_OpenSettings(void);
