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

void Q3E_FatalAlertAndExit(const char *text, const char *logpath) {
    NSString *msg = [NSString stringWithUTF8String:text ?: ""] ?: @"(unprintable)";
    NSLog(@"Q3E-FATAL: %@ (log: %s)", msg, logpath ?: "none");

    // Off the main thread there is no run loop to drive an alert; the file
    // already holds the message, so just go.
    if (!NSThread.isMainThread) exit(1);

    UIViewController *host = q3e_topViewController();
    if (!host) exit(1);

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
    [host presentViewController:alert animated:YES completion:nil];

    // Sys_Error is called from inside the engine, which runs on the main
    // thread (boot, or a display-link tick). Spin the run loop here so the
    // alert can draw and take the tap; the action handler exits.
    for (;;) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
    }
}
