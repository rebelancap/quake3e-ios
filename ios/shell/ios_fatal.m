// ios_fatal.m — the on-screen half of Sys_Error (see ios_glue.c, issue #1).
// Shows the fatal message in a UIAlertController and keeps the main run loop
// turning until the player dismisses it, then exits. Before this, a fatal
// engine error exited silently and was reported as "crashes on launch".
// No engine headers (ObjC 'id' vs engine identifiers); plain C entry point.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static UIViewController *q3e_topViewController(void) {
    UIWindow *win = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { win = w; break; }
            if (!win) win = w;
        }
        if (win) break;
    }
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// Non-zero once a fatal alert is up. Q3E_Frame (ios_glue.c) returns early
// while it is set, so display-link ticks firing inside the spin below do not
// re-enter the engine — which would fatal again and nest one more spin per
// tick. The re-entry guard in Q3E_FatalAlertAndExit covers any other caller.
volatile int q3e_fatal_active = 0;

static BOOL q3e_alertShown(UIAlertController *alert) {
    return alert.presentingViewController != nil && alert.viewIfLoaded.window != nil;
}

void Q3E_FatalAlertAndExit(const char *text, const char *logpath) {
    NSString *msg = [NSString stringWithUTF8String:text ?: ""] ?: @"(unprintable)";
    NSLog(@"Q3E-FATAL: %@ (log: %s)", msg, logpath ?: "none");

    // Off the main thread there is no run loop to drive an alert; the file
    // already holds the message, so just go.
    if (!NSThread.isMainThread) exit(1);

    // Re-entry while the first alert is up (something ran the engine from
    // inside our spin and it fataled again): do not stack a second alert and
    // do not exit, which would hide the first message. Keep the run loop
    // turning; the first alert's Quit (or its present timeout) exits.
    static int active = 0;
    if (active) {
        NSLog(@"Q3E-FATAL: re-entered while the alert is up; keeping the first message");
        for (;;) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
    }
    active = 1;
    q3e_fatal_active = 1;

    NSString *body = msg;
    if (logpath) {
        body = [msg stringByAppendingString:
                @"\n\nThis message was saved to q3e-fatal.log in the app's Documents folder "
                 "(Files app > On My iPhone / iPad > Quake3e). Please attach it when reporting."];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Quake3e stopped"
                                                                   message:body
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Quit" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { exit(1); }]];

    // Sys_Error is called from inside the engine, which runs on the main
    // thread (boot, or a display-link tick). Spin the run loop here so the
    // alert can draw and take the tap; the action handler exits.
    //
    // presentViewController is refused when the top view controller is
    // mid-transition (e.g. the onboarding screen still dismissing when boot
    // fatals) — so re-resolve the top VC and retry every 0.5 s until the
    // alert is really on screen. If it never gets there, exit after ~10 s:
    // q3e-fatal.log already holds the message, and a hung app is worse.
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent(), lastTry = 0;
    BOOL shown = NO;
    int attempts = 0;
    for (;;) {
        if (!shown) {
            if (q3e_alertShown(alert)) {
                shown = YES;
                NSLog(@"Q3E-FATAL: alert on screen (attempt %d)", attempts);
            } else if (CFAbsoluteTimeGetCurrent() - start > 10.0) {
                NSLog(@"Q3E-FATAL: alert could not be presented after %d attempts; exiting", attempts);
                exit(1);
            } else if (CFAbsoluteTimeGetCurrent() - lastTry >= 0.5) {
                lastTry = CFAbsoluteTimeGetCurrent();
                UIViewController *host = q3e_topViewController();
                if (host && host != alert && !alert.presentingViewController) {
                    attempts++;
                    [host presentViewController:alert animated:YES completion:nil];
                }
            }
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, shown ? 0.25 : 0.1, false);
    }
}
