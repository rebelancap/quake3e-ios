#pragma once
#import <UIKit/UIKit.h>

// The in-app settings sheet (ios_settings.m). Exposed so SwiftUI can host it in a
// `.sheet` — a UIKit modal presented over an open ImmersiveSpace silently fails, so on
// visionOS the ornament gear routes through a SwiftUI sheet instead.
@interface Q3ESettingsController : UIViewController
@end

// Present settings from the active window's root VC (used by the iOS touch gear).
void Q3E_OpenSettings(void);
void Q3E_PresentSettings(UIView *fromView);
