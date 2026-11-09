// ios_mouse.h — hardware mouse (GameController GCMouse) for iPad, plus the
// hardware-keyboard presence test the touch layer uses to decide whether the
// player is sitting at a "desktop" setup. Implementation in ios_mouse.m; it is
// compiled for visionOS too but every entry point there is an inert stub.
// Included from C (ios_glue.c, engine headers) as well as Objective-C, so UIKit
// stays behind __OBJC__.
#ifdef __OBJC__
#import <UIKit/UIKit.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Lifecycle (main thread). The host is the window's root view controller — the
// one whose -prefersPointerLocked iPadOS asks.
#ifdef __OBJC__
void Q3E_Mouse_Start(UIViewController *host);
#endif
// Once per engine frame, main thread (from Q3E_Input_Frame).
void Q3E_Mouse_Frame(int menuMode);

int  Q3E_Mouse_Present(void);            // a GCMouse (or a q3e_fakemouse device) exists
int  Q3E_Mouse_HwKeyboardPresent(void);  // GCKeyboard.coalescedKeyboard (or forced)
int  Q3E_Mouse_DesktopMode(void);        // mouse AND keyboard: hide the touch controls
int  Q3E_Mouse_WantsPointerLock(void);   // -prefersPointerLocked answer

// Console surface (registered in ios_glue.c).
void Q3E_Mouse_Diag(void);                         // q3e_mouse
void Q3E_Mouse_Cmd(int argc, const char **argv);   // q3e_mouse <subcommand>
void Q3E_Mouse_Fake(int argc, const char **argv);  // q3e_fakemouse ...

// Test-only fault injection (q3e_hwfault). Each bit disables ONE protection so
// the simulator suite can watch the assertion guarding it go red.
enum {
    Q3E_FAULT_NOSUPPRESS  = 1 << 0,  // menu: GCMouse left click NOT suppressed
    Q3E_FAULT_RIGHTASLEFT = 1 << 1,  // right button reports MOUSE1 (the old bug)
    Q3E_FAULT_NOWHEEL     = 1 << 2,  // wheel events dropped
    Q3E_FAULT_NOMOVE      = 1 << 3,  // motion dropped
    Q3E_FAULT_NORELEASE   = 1 << 4,  // device removal releases nothing
    Q3E_FAULT_NOTAP       = 1 << 5,  // lone release not recovered as a click
    Q3E_FAULT_NODEDUPE    = 1 << 6,  // keyboard: press char + insertText both land
    Q3E_FAULT_NOCHARS     = 1 << 7,  // keyboard: presses generate no characters
    Q3E_FAULT_NOREPEAT    = 1 << 8,  // keyboard: no key repeat at all
    Q3E_FAULT_ANYREPEAT   = 1 << 9,  // keyboard: repeat outside text contexts too
    Q3E_FAULT_NOGUARD     = 1 << 10, // polled reconcile guard disabled
    Q3E_FAULT_NOFILTER    = 1 << 11, // touch layer takes every pointer touch
};
extern int q3e_hwfault;
void Q3E_HwFault_Cmd(int argc, const char **argv);  // q3e_hwfault <name> <0|1>

#ifdef __cplusplus
}
#endif
