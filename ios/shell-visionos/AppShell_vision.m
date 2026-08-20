// AppShell_vision.m — native visionOS shell for Quake3e. A 2D-window variant
// of the iOS AppShell.m: UIScene + UIWindow + CAMetalLayer view + CADisplayLink
// driving Com_Frame. Differences from iOS: NO orientation locking (visionOS
// windows are free-aspect and resizable), boot gated only on a valid non-zero
// window size, display link paced to the visionOS compositor, and drawable
// resize tracked so the renderer's own OUT_OF_DATE swapchain recreation kicks
// in. ALL other shell code (input, glue, metal, snd, settings, onboarding, pak
// manager, console) is shared with iOS unchanged — this file is the only
// visionOS-specific source, kept out of the iOS target so that stays clean.

#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#import "ios_input.h"
#import "AppShell_vision.h"
#import "Q3EBlackBox.h"
#import "Q3EVR.h"

extern CAMetalLayer *q3e_layer;              // ios_metal.m
void Q3E_SetDocumentsPath(const char *path); // ios_glue.c
void Q3E_BootEngine(void);
void Q3E_Frame(void);
void Q3E_OnResignActive(void);
void Q3E_SND_Pause(void);
void Q3E_SND_Resume(void);
void Q3E_Settings_ApplyAll(void);            // ios_settings.m
void Q3E_QueueCommand(const char *cmd);      // ios_glue.c (vid_restart on resize)

// Bridge to Swift (Q3EVisionApp.swift @_cdecl) + the engine.
extern void Q3E_SetImmersiveMode(bool on);
extern void Q3E_SetVRSpace(bool on);        // opens/dismisses the VR ImmersiveSpace
extern void Q3E_SetSpatialAudioMode(int mode);   // 0 = window, 1 = 3D panel, 2 = VR
extern volatile int q3e_gyro_suppressed;         // ios_input.m — head gyro off in VR
// Q3EVR.m
extern void Q3E_NoteRenderRestart(void);   // ios_glue.c
extern int  Q3E_CancelQueuedCommands(const char *substr);
extern int  Q3E_LayerWidth(void);          // ios_metal.m
extern int  Q3E_LayerHeight(void);
extern int  Q3E_ProducerPending(void);
extern unsigned Q3E_CommandSeq(void);
extern unsigned Q3E_CommandDone(void);
extern void Q3E_VR_RequestedRenderSize(int *w, int *h);
extern int  Q3E_VR_SizeRequested(void);
extern void Q3E_VR_ClearSizeRequest(void);
extern void Q3E_VR_Recenter(void);
// Q3EVRGlue.c
extern int  Q3E_VR_EngineRenderWidth(void);
extern int  Q3E_VR_EngineRenderHeight(void);
// renderervk patch 0009
extern void VK_Set3DVRWanted(int on);
extern void VK_SetVRActive(int on);
// ios_glue.c — the render extent and its ownership
extern int  Q3E_SetRenderSizeOverride(const char *caller, int w, int h);
extern int  Q3E_ClaimRenderSizeOverride(const char *who);
extern void Q3E_ReleaseRenderSizeOverride(const char *who);
extern const char *Q3E_RenderSizeOverrideOwner(void);
extern int  Q3E_RenderSizeOverrideRefusals(void);
extern void Q3E_NoteRenderSizeOverrideRefusal(void);
extern void Q3E_SetRenderOverrideReporter(void (*fn)(const char *));
void Cmd_AddCommand(const char *cmd_name, void (*function)(void));
int  Cmd_Argc(void);
char *Cmd_Argv(int arg);
void Com_Printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
extern int gw_minimized;   // engine "don't touch the window swapchain" switch (qboolean)
extern int q3e_immFrameCount;   // Q3EImmersive.m — immersive frames presented (watchdog)
extern void VK_Set3DEye(int eye);   // renderervk patch 0006: 0=off(2D), 1=left, 2=right
extern void VK_Set3DWanted(int on); // renderervk patch 0007: create per-eye images at init
extern volatile int q3e_immStop;    // Q3EImmersive.m — graceful-shutdown handshake
extern volatile int q3e_immRunning;

static bool q3e_immersive_on = false;
static bool q3e_booted = false;
static int  q3e_resume_gen = 0;   // cancels in-flight window-probe work
static CADisplayLink *q3e_link;   // the engine's pacer in 2D and 3D; PAUSED in VR

// Parked-window plumbing (vkQuake recipe 1). In 3D the 2D window is only a control
// card (ornament + Exit + settings), so shrink it out of the way and restore on exit.
// Engine render resolution is already decoupled from the window (patch 0004 fixed-FBO
// + gw_minimized never touches the window swapchain in 3D), so traps (a)/(b) of the
// recipe don't apply here; trap (c) — resize animations racing renderer work — is
// handled by gating the shell's own resize->vid_resize path while in 3D and re-syncing
// once after presents resume.
@interface Q3EVisionViewController (Q3EPark)
- (void)applyResize;
@end
static __weak Q3EVisionViewController *q3e_vc;
static CGSize q3e_savedWindowSize;
static bool   q3e_windowParked = false;
static UIView *q3e_curtain;   // "Playing in 3D" cover over the parked card

// THE ONE GATE every window/geometry/scene path goes through before it re-sizes
// the renderer. While VR owns the render extent, a window resize is not merely
// unhelpful: opening the VR space is itself a geometry event on the device, so
// the window path fires DURING entry, and whichever restart lands last decides
// the extent. Refusals are pinned by name — a gate whose refusals are invisible
// is indistinguishable from a gate that is not there.
static int q3e_render_resize_refused(const char *caller) {
    const char *owner = Q3E_RenderSizeOverrideOwner();
    if (!owner) return 0;
    Q3E_NoteRenderSizeOverrideRefusal();
    Q3E_BlackBox_Pin("window: resize from '%s' REFUSED — '%s' owns the render extent",
                     caller, owner);
    return 1;
}

// The parked card would otherwise show the FROZEN last 2D frame (gw_minimized) —
// confusing floating next to the live panel (vkQuake note, found in testing). Cover
// the window with a black curtain + label while parked.
static void q3e_set_curtain(bool show) {
    [q3e_curtain removeFromSuperview];
    q3e_curtain = nil;
    if (!show) {
        Q3E_BlackBox_Pin("curtain: DOWN (the window card shows the game again)");
        return;
    }
    UIWindow *win = q3e_vc.view.window;
    if (!win) {
        Q3E_BlackBox_Pin("curtain: NOT RAISED — the window has no scene to cover");
        return;
    }
    UIView *cover = [[UIView alloc] initWithFrame:win.bounds];
    cover.backgroundColor = UIColor.blackColor;
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UILabel *l = [[UILabel alloc] init];
    // Refresh the label from the CURRENT mode every time the curtain is raised.
    // A parked card that reads "Playing in 3D" during a VR session is how a
    // sibling port's user concluded VR and the 3D panel were the same thing.
    l.text = (q3e_mode == Q3E_MODE_VR) ? @"Playing in VR" : @"Playing in 3D";
    l.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    l.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [cover addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [l.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor],
    ]];
    [win addSubview:cover];
    q3e_curtain = cover;
    Q3E_BlackBox_Pin("curtain: UP over the window card, reading \"%s\" (mode=%s)",
                     l.text.UTF8String, Q3E_ModeName(q3e_mode));
}

// NB: q3e_savedWindowSize is NOT captured here — opening the ImmersiveSpace can make
// visionOS resize the main window itself, so reading bounds at (+1.5 s) park time saved
// the SYSTEM-modified size and the window never restored to the user's own (vkQuake
// root-cause). It's captured at the very top of Q3E_Enter3D(true), pre-transition.
// The park is REPORTED IN THE PINNED REGION, request and outcome separately. On
// the first device round the window never parked at all and the only way to know
// was that the user could still see it: a request nobody confirms is not
// evidence, and "park(1)" in a rolling tail that had already scrolled away was
// not even that. The geometry error handler fires only on failure, so the
// outcome is read back from the window itself a beat later.
static void q3e_park_window(bool park) {
    UIWindowScene *ws = q3e_vc.view.window.windowScene;
    if (!ws) { Q3E_BlackBox_Pin("park(%d): NOT RUN — no window scene", park); return; }
    if (park == q3e_windowParked) {
        Q3E_BlackBox("park(%d): already in that state", park);
        return;
    }
    q3e_windowParked = park;
    q3e_set_curtain(park);
    CGSize target = park ? CGSizeMake(480, 270) : q3e_savedWindowSize;
    if (target.width < 100 || target.height < 60) {
        Q3E_BlackBox_Pin("park(%d): NOT RUN — target %.0fx%.0f is degenerate",
                         park, target.width, target.height);
        return;
    }
    UIWindowSceneGeometryPreferencesVision *geo =
        [[UIWindowSceneGeometryPreferencesVision alloc] init];
    geo.size = target;
    [ws requestGeometryUpdateWithPreferences:geo errorHandler:^(NSError *e) {
        Q3E_BlackBox_Pin("park(%d) geometry error: %s", park,
                         e.localizedDescription.UTF8String ?: "?");
    }];
    Q3E_BlackBox_Pin("park(%d) RUNNING: window -> %.0fx%.0f requested", park,
                     target.width, target.height);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CGSize now = q3e_vc.view.window.bounds.size;
        Q3E_BlackBox_Pin("park(%d) SETTLED: window is %.0fx%.0f (asked %.0fx%.0f, curtain=%d)",
                         park, now.width, now.height, target.width, target.height,
                         q3e_curtain != nil);
    });
}

// The single owner of the 2D<->3D transition (per the 3D design notes). Flip the engine
// OFF-SCREEN (gw_minimized) BEFORE the immersive space opens and the 2D window hides,
// so no frame ever acquires the now-detaching window swapchain — that acquire is the
// freeze (MoltenVK spins on nextDrawable forever on a hidden layer). The game keeps
// running into its FBO: sound, sim, and the console bridge all stay alive. Main-thread
// serialization makes the ordering airtight. gw_minimized is CLEARED only when the
// window scene reactivates (below), never here, so a Crown-dismissed frame can't
// acquire a still-hidden layer.
// Exiting 3D: resume rendering to the 2D window. The engine ran off-screen
// (gw_minimized) during 3D; clear that so it draws to the window again — but only after
// the window layer PROVABLY vends a drawable (Bug B), else the first tick acquires a
// dead layer and wedges in MoltenVK nextDrawable. Called on BOTH exit paths (button and
// Crown); scene reactivation does NOT fire on exit (the window stayed active in mixed
// immersion), so we can't rely on the DidActivate handler for this.
void Q3E_Resume2DWindow(void) {
    if (!gw_minimized) return;
    // These probes can take seconds, and the mode can change while they run. A
    // 3D->VR switch's late probe would otherwise clear gw_minimized DURING the
    // VR session, and the VR engine thread would then acquire the hidden parked
    // window's swapchain and wedge in MoltenVK's nextDrawable retry. Every
    // completion re-checks the generation AND the mode it was started for.
    const int gen = ++q3e_resume_gen;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < 6; i++) {
            @autoreleasepool {
                if (gen != q3e_resume_gen) {
                    Q3E_BlackBox("exit 3D: window probe cancelled (mode moved on)");
                    return;
                }
                id<CAMetalDrawable> d = [q3e_layer nextDrawable];
                if (d) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (gen != q3e_resume_gen || q3e_mode != Q3E_MODE_2D ||
                            q3e_frame_owner != Q3E_FRAME_OWNER_LINK) {
                            Q3E_BlackBox_Pin("window probe landed in mode %s (owner=%d) — "
                                             "NOT re-enabling presents",
                                             Q3E_ModeName(q3e_mode), q3e_frame_owner);
                            return;
                        }
                        gw_minimized = 0;
                        Q3E_BlackBox("exit 3D: window layer live -> 2D presents re-enabled");
                        NSLog(@"Q3E-VISION: 2D presents re-enabled after exiting 3D");
                        // The window was just un-parked; the normal resize->vid_resize
                        // path was gated during 3D, so re-sync the swapchain to the
                        // restored size once the animation has had time to settle.
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            // Never resize into a VR render-size override.
                            if (gen == q3e_resume_gen && q3e_mode == Q3E_MODE_2D)
                                [q3e_vc applyResize];
                        });
                    });
                    return;
                }
                Q3E_BlackBox("exit 3D: nextDrawable probe %d nil", i);
            }
        }
        Q3E_BlackBox("exit 3D: LOUD FAILURE — window layer never vended a drawable");
    });
}

// Hide the weapon viewmodel in 3D (settings toggle). The viewmodel is drawn right at
// the camera, so in stereo it gets extreme parallax — the single biggest eye-strain
// source. cg_drawGun is an engine cvar; apply it on entering/leaving 3D.
static bool q3e_fpsEnabled = false;   // FPS counter setting (mirrored to cg_drawFPS in 3D)

static bool q3e_hideGun3D = false;
void Q3E_Set3DHideGun(int on) {
    q3e_hideGun3D = on;
    if (q3e_immersive_on) Q3E_QueueCommand(on ? "cg_drawGun 0" : "cg_drawGun 1");
}

// Hide the "head in your face": the HUD status-bar 3D player-model head pops toward you
// in stereo. cg_draw3dIcons 0 flattens the HUD's 3D models to 2D (no pop-out).
static bool q3e_hideHead3D = false;
void Q3E_Set3DHideHead(int on) {
    q3e_hideHead3D = on;
    if (q3e_immersive_on) Q3E_QueueCommand(on ? "cg_draw3dIcons 0" : "cg_draw3dIcons 1");
}

void Q3E_Enter3D(bool on) {
    if (!q3e_booted) { Q3E_BlackBox("Enter3D(%d) IGNORED pre-boot", on); return; }
    q3e_immersive_on = on;
    if (on) q3e_mode = Q3E_MODE_3D;
    else if (q3e_mode == Q3E_MODE_3D) q3e_mode = Q3E_MODE_2D;
    Q3E_AssertModePolicy();   // reachable directly from the settings toggle too
    if (on) {
        // Capture the user's TRUE window size FIRST — before the space opens, before
        // any delay (opening the ImmersiveSpace can itself resize the main window, and
        // a quick exit->re-enter would otherwise capture a mid-restore-animation size).
        // Never re-capture while parked.
        if (!q3e_windowParked && q3e_vc.view.window) {
            q3e_savedWindowSize = q3e_vc.view.window.bounds.size;
            Q3E_BlackBox("Enter3D: saved window size %.0fx%.0f",
                         q3e_savedWindowSize.width, q3e_savedWindowSize.height);
        }
        gw_minimized = 1;                // enter: stop touching the swapchain first
        // Both-eyes-per-frame stereo (patch 0007): the client renders LEFT+RIGHT
        // fields every host frame — full rate per eye, both eyes the same game time.
        Q3E_QueueCommand("set r_stereo3d 1");
        if (q3e_hideGun3D)  Q3E_QueueCommand("cg_drawGun 0");
        if (q3e_hideHead3D) Q3E_QueueCommand("cg_draw3dIcons 0");
        // (FPS on the panel is drawn by the immersive compositor overlay, not cg_drawFPS)
        // Park the 2D window into a small control card AFTER the space has opened
        // (recipe trap c: never run the resize animation concurrently with the mode
        // transition). Users place the card once; the system remembers its spot.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (q3e_immersive_on) q3e_park_window(true);
        });
    } else {
        Q3E_QueueCommand("set r_stereo3d 0");
        q3e_park_window(false);          // restore the window first (recipe trap c)...
        VK_Set3DEye(0);                  // exit: back to normal 2D rendering (no offset)
        Q3E_QueueCommand("cg_drawGun 1");     // restore the gun...
        Q3E_QueueCommand("cg_draw3dIcons 1"); // ...and 3D HUD icons in 2D
        // Stop the immersive render thread and WAIT for it to finish BEFORE the space is
        // dismissed, so it can't touch the layerRenderer while SwiftUI tears it down
        // (that mid-frame race crashed the app on exit). Typically clears in ~1 frame.
        q3e_immStop = 1;
        for (int i = 0; i < 120 && q3e_immRunning; i++) usleep(2000);  // up to ~240 ms
        Q3E_BlackBox("Enter3D(0): render thread stopped=%d", !q3e_immRunning);
        Q3E_Resume2DWindow();            // and resume drawing to the 2D window
    }
    Q3E_SetImmersiveMode(on);            // then open/close the immersive space (Swift)
    Q3E_BlackBox_Pin("Enter3D(%d) gw_minimized=%d", on, gw_minimized);
    NSLog(@"Q3E-VISION: 3D -> %d (gw_minimized=%d)", on, gw_minimized);
}

// Called from the immersive render loop when the space is dismissed (e.g. Digital
// Crown), to reconcile our state + the SwiftUI model/button however it closed.
void Q3E_Immersive_Ended(void) {
    Q3E_BlackBox_Pin("Immersive_Ended (loop saw invalidated)");
    dispatch_async(dispatch_get_main_queue(), ^{
        q3e_immersive_on = false;
        // Only if 3D is still the mode: a 3D->VR switch dismisses the panel
        // space while VR is opening, and its dismissal must not drag the
        // tri-state back to 2D underneath the entry.
        if (q3e_mode == Q3E_MODE_3D) q3e_mode = Q3E_MODE_2D;
        Q3E_AssertModePolicy();          // the mode decides, at the moment it is true
        Q3E_QueueCommand("set r_stereo3d 0");   // back to single-field frames
        VK_Set3DEye(0);                  // back to normal 2D rendering
        q3e_park_window(false);          // restore the parked control card
        Q3E_SetImmersiveMode(false);
        Q3E_Resume2DWindow();            // resume drawing to the 2D window
        NSLog(@"Q3E-VISION: 3D ended (space dismissed)");
    });
}

// --- VR mode -----------------------------------------------------------------
//
// One immersive space is open at a time (a visionOS constraint), so the mode is
// a tri-state and Q3E_EnterMode is its only owner — and it always runs on the
// MAIN thread, because the console commands that call it are drained by whatever
// thread owns the engine, and in VR that is the very thread the exit has to stop.
//
// Entry is TWO-PHASE. Entering VR restarts the render target (the per-eye extent
// comes from the drawable, which does not exist until the space is open), and
// committing the mode DURING that restart blits a dying texture and wedges
// swapchain recreation. So: open the space, let the loop report the per-eye
// size, issue the restart, POLL until the engine's render extent has actually
// changed, and only then commit. A phase-2 that never gets there ABORTS the
// entry and rolls back — committing anyway would leave the player parked behind
// a curtain looking at their own room with no way back.
//
// Exit is staged the same way, for the same reason: nothing may block the main
// thread, and the display link must never be handed back while the engine thread
// still lives.
// The name VR claims the render extent under. One spelling, used by the claim,
// every write and the release, so a typo cannot quietly turn a write into a
// refusal.
#define Q3E_VR_EXTENT_OWNER "vr"

static int  q3e_vr_requested = 0;      // the mode the machine is heading for
static int  q3e_vr_restartIssued = 0;
static int  q3e_vr_reqW = 0, q3e_vr_reqH = 0;
static int  q3e_vr_committed = 0;
// A teardown runs asynchronously (drain barrier, loop stop, dismissal, window
// probe), so a quick VR -> 2D -> VR can arrive while the previous one is still
// unwinding. Entering then would find the old engine thread still alive, refuse
// to start a new one, and leave the frame with NO owner at all: link paused, old
// thread exiting, nothing ticking Com_Frame.
static int  q3e_vr_teardownActive = 0;
static int  q3e_vr_finalizing = 0;

extern char *Cvar_VariableString(const char *var_name);
extern void  Cbuf_ExecuteText(int exec_when, const char *text);
#define Q3E_EXEC_NOW 0

// Run a command RIGHT NOW. Only legal while the display link owns the engine —
// i.e. on the main thread with no VR engine thread running, which is true at
// every call site below (they are all after the engine thread has stopped).
static void q3e_exec_now(const char *cmd) {
    if (q3e_frame_owner != Q3E_FRAME_OWNER_LINK) {
        Q3E_BlackBox_Pin("exec_now(%s) REFUSED — the engine thread owns the frame", cmd);
        return;
    }
    char line[192];
    snprintf(line, sizeof(line), "%s\n", cmd);
    Cbuf_ExecuteText(Q3E_EXEC_NOW, line);
}

// --- crash-safe cvar stash ---------------------------------------------------
//
// VR overrides ARCHIVED cvars, and the engine writes its config on a resign, a
// clean exit, or any of a dozen other moments. A crash or a swipe-kill inside VR
// therefore bakes the overrides into the player's own config permanently: a 2D
// player left with no anti-aliasing (or worse, once a future round overrides
// something else), with no idea why. The pre-override values go into the
// settings store (NOT a static, which dies with the process), and a leftover
// stash found at launch is restored and written back immediately.
static NSString *const kQ3EStashMark = @"q3e.vrStashActive";
// r_ext_multisample is deliberately NOT here: VR forces single-sample inside the
// renderer instead of overriding the cvar. It is archived AND latched, so its
// live value is not the value the player chose, and stashing what Cvar_
// VariableString returns would restore the wrong number.
// cg_drawGun is deliberately NOT here either (R2 item 3): VR no longer
// overrides it — the gun stays visible head-attached — so there is nothing
// for the stash to protect for that cvar. The machinery stays for the one
// override VR still makes.
static NSString *const kQ3EStashCvars[] = {
    @"cg_draw3dIcons"
};
static const int kQ3EStashCount = 1;

static void q3e_vr_stash_cvars(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d boolForKey:kQ3EStashMark]) return;      // already stashed; never re-stash
                                                   // our own override values
    for (int i = 0; i < kQ3EStashCount; i++) {
        const char *name = kQ3EStashCvars[i].UTF8String;
        const char *val = Cvar_VariableString(name);
        [d setObject:[NSString stringWithUTF8String:val ?: ""]
              forKey:[@"q3e.vrStash." stringByAppendingString:kQ3EStashCvars[i]]];
    }
    [d setBool:YES forKey:kQ3EStashMark];
    [d synchronize];
    Q3E_BlackBox_Pin("VR: stashed %d archived cvars before overriding them", kQ3EStashCount);
}

// A stashed cvar NAME goes into a console command, so it is checked against the
// charset a cvar name can actually have before it is interpolated into one.
// Nothing but this app writes these keys today — but the store is a file on
// disk that outlives every build, and "the only writer is us" is exactly the
// assumption that turns a settings store into a command injection: a key named
// `q3e.vrStash.x; quit` would otherwise execute as two commands.
static BOOL q3e_stash_name_ok(NSString *name) {
    if (name.length == 0 || name.length > 64) return NO;
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        BOOL ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '_';
        if (!ok) return NO;
    }
    return YES;
}

// The VALUE is quoted inside the command, so the characters that matter are the
// ones that can END the quoting or start something else: a double quote, a
// newline (a second command line), a backslash, and `$` (the console's own
// variable substitution). Spaces are fine and deliberately allowed — plenty of
// legitimate cvar values have them.
static BOOL q3e_stash_value_ok(NSString *v) {
    if (v.length == 0 || v.length > 96) return NO;
    for (NSUInteger i = 0; i < v.length; i++) {
        unichar c = [v characterAtIndex:i];
        if (c < 0x20 || c > 0x7e) return NO;
        if (c == '"' || c == '\\' || c == '$') return NO;
    }
    return YES;
}

// Ordered before every config write. A restore that is merely queued has not
// happened when the config is written a line later, so every caller either runs
// on the engine thread's own drain order or waits on the drain barrier.
//
// R2.1 fix 4: sweeps EVERY "q3e.vrStash.*" key actually present in
// NSUserDefaults, not just the CURRENT kQ3EStashCvars array — an entry written
// by a PREVIOUS build whose list included a cvar this build's list no longer
// does (R1 shipped {cg_drawGun, cg_draw3dIcons}; this build's list is just
// cg_draw3dIcons) must not be silently ignored on a player who upgrades
// mid-crash-recovery, or the override it was protecting against stays baked
// into q3config.cfg forever.
//
// R2.2 fixes 1 + 13 — WHAT THE SWEEP IS ALLOWED TO DO WITH WHAT IT FINDS:
//
//  * The MARK is the whole authority. A value key found with NO active mark is
//    the residue of a stash cycle that already COMPLETED (R1's restore removed
//    only the mark, so every clean R1 session left both of its value keys
//    behind) and its contents are months stale. Applying those is not recovery,
//    it is silently reverting the player's current settings to an old backup
//    and then writing the config. They are DELETED, never applied.
//  * A value stored as a NUMBER is coerced like the old stringForKey read did,
//    rather than skipped — skipping it while clearing the mark stranded the key
//    forever, unrestorable and unswept.
//  * Names and values are validated before going anywhere near a command
//    string, and the snprintf result is CHECKED: a truncated command is a
//    malformed one, and it used to be issued silently.
//  * Every key the sweep looks at is REMOVED whichever way it goes, so nothing
//    it has already decided about can be found again by a later sweep.
//
// Returns how many restores it actually QUEUED, so a caller that only wants to
// write the config when something changed can tell (the launch recovery does).
static int q3e_vr_restore_cvars(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *prefix = @"q3e.vrStash.";
    const BOOL markActive = [d boolForKey:kQ3EStashMark];
    NSDictionary<NSString *, id> *all = [d dictionaryRepresentation];
    int restored = 0, dropped = 0;
    for (NSString *key in all) {
        if (![key hasPrefix:prefix]) continue;
        NSString *name = [key substringFromIndex:prefix.length];
        id raw = all[key];
        [d removeObjectForKey:key];
        if (!markActive) {
            // Stale: the session that wrote it ended cleanly and restored from
            // it already. Cleared so it can never be mistaken for a live stash.
            dropped++;
            continue;
        }
        NSString *v = nil;
        if ([raw isKindOfClass:NSString.class])      v = (NSString *)raw;
        else if ([raw isKindOfClass:NSNumber.class]) v = ((NSNumber *)raw).stringValue;
        if (!q3e_stash_name_ok(name) || !q3e_stash_value_ok(v)) {
            dropped++;
            Q3E_BlackBox_Pin("VR: stash entry REFUSED — a key or value that cannot be a cvar "
                             "assignment was found in the stash and was dropped, not executed");
            continue;
        }
        char cmd[192];
        int n = snprintf(cmd, sizeof(cmd), "set %s \"%s\"", name.UTF8String, v.UTF8String);
        if (n < 0 || n >= (int)sizeof(cmd)) {
            dropped++;
            Q3E_BlackBox_Pin("VR: stash entry DROPPED — the restore command did not fit in %d "
                             "bytes, and half a command is worse than none", (int)sizeof(cmd));
            continue;
        }
        // Through the FUNNEL, not EXEC_NOW: while VR is being torn down the
        // engine thread owns the frame, and the queue is FIFO so the config
        // write that follows cannot overtake these.
        Q3E_QueueCommand(cmd);
        restored++;
    }
    if (markActive) [d removeObjectForKey:kQ3EStashMark];
    [d synchronize];
    Q3E_BlackBox_Pin("VR: stash sweep of q3e.vrStash.* — mark=%d restored=%d dropped=%d "
                     "(the current build's own list has %d entries; restored>list means an "
                     "orphaned stash from a different build's list was honoured, and "
                     "dropped>0 with mark=0 means stale keys were cleared, never applied)",
                     markActive ? 1 : 0, restored, dropped, kQ3EStashCount);
    return restored;
}

// A stash still present at launch means the last session died inside VR.
//
// R2.2 fix 1: the sweep runs whether or not the mark is set, because clearing
// the stale keys a previous BUILD left behind is half of what it is now for —
// but the config is only rewritten when a restore was actually queued. A launch
// that merely tidies up dead keys has changed nothing the config knows about.
static void q3e_vr_recover_stash_on_launch(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d boolForKey:kQ3EStashMark])
        Q3E_BlackBox_Pin("VR: a cvar stash survived the last session — it ended inside VR. Restoring.");
    if (q3e_vr_restore_cvars() > 0)
        Q3E_QueueCommand("writeconfig q3config.cfg");   // FIFO: after the restores
}

// Everything the MODE owns, asserted in one place.
//
// It is one place because these are decided by which mode is true, not by
// whichever dismissal completion happens to run last: a 3D->VR switch has the
// old space's completion racing the new space's entry, and losing that race left
// the whole VR session double-panned (head-tracked spatialisation stacked on the
// engine's own head listener). Every path that changes the mode calls this, and
// the paths that change it ASYNCHRONOUSLY call it when the change lands rather
// than when it is requested.
void Q3E_AssertModePolicy(void) {
    Q3E_SetSpatialAudioMode(q3e_mode == Q3E_MODE_VR ? 2 : (q3e_mode == Q3E_MODE_3D ? 1 : 0));

    // The same argument applies to the head gyro, so it is asserted from the same
    // place rather than from a second set of transition sites that would have to
    // agree with these forever.
    //
    // In VR the head drives the CAMERA. The gyro feed turns head rotation into
    // aim deltas, which in VR means the aim walks away on its own the moment the
    // player looks around — no input, drifting crosshair. In the 2D window and on
    // the 3D panel the head drives nothing, and gyro aim is exactly the feature.
    q3e_gyro_suppressed = (q3e_mode == Q3E_MODE_VR) ? 1 : 0;
}

// TEST HOOK. On the device, opening a `.full` immersive space deactivates the
// 2D window's scene and visionOS stops delivering its CADisplayLink callbacks —
// the link is simply dead for the rest of the session. The simulator's window
// scene does not deactivate under its simulated `.full` space, so nothing in the
// suite could reach the failure that produced a frozen world and a starved audio
// ring on the first device round. `q3evrlinkfreeze 1` makes the simulator behave
// like the device: the link is paused and REFUSES to resume.
static int q3e_link_frozen = 0;

// The only writer of q3e_link.paused, so the hook cannot be bypassed by a path
// that sets it directly.
static void q3e_link_set_paused(BOOL paused) {
    if (!q3e_link) return;
    if (!paused && q3e_link_frozen) {
        Q3E_BlackBox_Pin("link: resume SUPPRESSED (freeze hook active — emulating the "
                         "device's dead display link)");
        return;
    }
    q3e_link.paused = paused;
}

// ARMS the suppression; it does not pause anything by itself. On the device the
// link is alive until the space opens and dies there, so entry's own pause is
// what should stop it — and arming it by pausing here would also stop the engine
// that has to receive the "enter VR" command in the first place, which is a
// different failure from the one being emulated.
void Q3E_DebugFreezeLink(int on) {
    q3e_link_frozen = on ? 1 : 0;
    Q3E_BlackBox_Pin("link: freeze hook %s — from the next pause, the link will not resume",
                     on ? "ARMED" : "off");
    if (!q3e_link_frozen && q3e_frame_owner == Q3E_FRAME_OWNER_LINK)
        q3e_link_set_paused(NO);
}

// TEST HOOK: force phase 2 to never settle, so the abort/rollback path can be
// asserted rather than argued about.
static int q3e_vr_forceEntryFail = 0;
void Q3E_DebugFailEntry(int on) {
    q3e_vr_forceEntryFail = on ? 1 : 0;
    Q3E_BlackBox_Pin("VR: force-entry-fail hook %s", on ? "ON" : "off");
}

// TEST HOOK: window-geometry churn during a VR entry. On the device, opening a
// `.full` space fires real scene-geometry events at the 2D window — deactivation
// and one or more resizes — so the window's OWN resize path runs while entry is
// in flight, and on the first device round it re-sized the renderer on top of
// VR's every time. The simulator delivers none of that, which is why the suite
// could not reach it.
//
// This drives the SHELL'S OWN handlers, never a stand-in: a real geometry
// request (so UIKit delivers viewDidLayoutSubviews exactly as it always does)
// plus the settled-resize handler the debounce would have called. What it proves
// is what the ownership gate does with them.
void Q3E_DebugWindowChurn(int times) {
    if (times < 1) times = 1;
    if (times > 8) times = 8;
    Q3E_BlackBox_Pin("window churn: driving the shell's own resize handlers %d time(s) "
                     "(extent owner=%s)", times, Q3E_RenderSizeOverrideOwner() ?: "none");
    for (int i = 0; i < times; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.4 * i) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIWindowScene *ws = q3e_vc.view.window.windowScene;
            CGSize sz = q3e_vc.view.window.bounds.size;
            if (ws && sz.width > 240.0 && sz.height > 160.0) {
                const CGFloat d = (i % 2) ? -40.0 : 40.0;
                UIWindowSceneGeometryPreferencesVision *geo =
                    [[UIWindowSceneGeometryPreferencesVision alloc] init];
                geo.size = CGSizeMake(sz.width + d, sz.height + d * (sz.height / sz.width));
                [ws requestGeometryUpdateWithPreferences:geo errorHandler:^(NSError *e) {
                    Q3E_BlackBox("window churn geometry error: %s",
                                 e.localizedDescription.UTF8String ?: "?");
                }];
            }
            [q3e_vc applyResize];
            Q3E_BlackBox_Pin("window churn %d/%d delivered (extent owner=%s, refusals=%d)",
                             i + 1, times, Q3E_RenderSizeOverrideOwner() ?: "none",
                             Q3E_RenderSizeOverrideRefusals());
        });
    }
}

static void q3e_vr_commit(void) {
    if (q3e_vr_committed) return;
    q3e_vr_committed = 1;
    // The frame owner moved to the engine thread back at the START of entry (see
    // q3e_enter_vr) — by the time we get here it has already been running the
    // game, draining the entry commands and feeding the audio mixer for a second
    // or so. All that is left to do is arm the pose-locked path.
    VK_SetVRActive(1);
    Q3E_AssertModePolicy();
    Q3E_BlackBox_Pin("VR: committed (engine %dx%dpx per eye, display link paused, owner=vr)",
                     Q3E_VR_EngineRenderWidth(), Q3E_VR_EngineRenderHeight());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (q3e_mode == Q3E_MODE_VR) q3e_park_window(true);
    });
}

static void q3e_vr_abort_entry(const char *why);

static void q3e_vr_phase2(int tries) {
    if (q3e_vr_requested != Q3E_MODE_VR) {
        Q3E_BlackBox_Pin("VR: phase 2 abandoned (mode changed under it)");
        return;
    }
    if (!q3e_vr_restartIssued) {
        if (Q3E_VR_SizeRequested()) {
            Q3E_VR_RequestedRenderSize(&q3e_vr_reqW, &q3e_vr_reqH);
            if (!Q3E_SetRenderSizeOverride(Q3E_VR_EXTENT_OWNER, q3e_vr_reqW, q3e_vr_reqH)) {
                q3e_vr_abort_entry("the render extent could not be claimed for VR");
                return;
            }
            Q3E_NoteRenderRestart();
            Q3E_QueueCommand("vid_restart");
            q3e_vr_restartIssued = 1;
            Q3E_BlackBox_Pin("VR: phase 2 — restarting the renderer at %dx%dpx per eye "
                             "(requested at poll %d; the engine thread drains it)",
                             q3e_vr_reqW, q3e_vr_reqH, tries);
        }
    } else if (!q3e_vr_forceEntryFail &&
               Q3E_VR_EngineRenderWidth() == q3e_vr_reqW &&
               Q3E_VR_EngineRenderHeight() == q3e_vr_reqH) {
        Q3E_BlackBox_Pin("VR: phase 2 settled after %d poll(s)", tries);
        q3e_vr_commit();
        return;
    }
    if (tries >= 60) {          // 6 s
        q3e_vr_abort_entry("phase 2 never saw the render extent change");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ q3e_vr_phase2(tries + 1); });
}

// --- R3.2 item 5: VR Render Quality, applied to the LIVE session -------------
//
// The device round reported the row as doing nothing, and it very nearly was:
// the scale was read exactly once, in q3e_vr_phase2, on the way INTO VR. Every
// later change sat in the store until the next entry — and the only display
// that can show the difference is the one the player is wearing, which they
// would have had to leave and re-enter to see it. (The console command even said
// so; a caption nobody in a headset reads is not a working control.)
//
// Re-negotiating is the same three steps entry does, in the same order, on the
// same thread, with the same owner string: clear the compositor loop's one-shot
// size latch, let it recompute the target from the live scale, claim it, restart
// the renderer. The generation counter (Q3E_NoteRenderRestart) is what keeps the
// compositor thread off the textures while they are rebuilt, and it is the
// mechanism entry already relies on with the loop running.
//
// Coalesced by a generation of its own: a slider drag fires this dozens of times
// a second and each one would otherwise queue a full RE_Shutdown/R_Init.
static int q3e_vr_rescaleGen = 0;

static void q3e_vr_rescale_poll(int tries, int gen) {
    if (gen != q3e_vr_rescaleGen) return;              // superseded by a later drag
    if (q3e_mode != Q3E_MODE_VR || q3e_vr_teardownActive || q3e_vr_finalizing) return;
    if (Q3E_VR_SizeRequested()) {
        int w = 0, h = 0;
        Q3E_VR_RequestedRenderSize(&w, &h);
        if (w > 0 && h > 0) {
            q3e_vr_reqW = w; q3e_vr_reqH = h;
            if (!Q3E_SetRenderSizeOverride(Q3E_VR_EXTENT_OWNER, w, h)) {
                Q3E_BlackBox_Pin("VR: render quality %.2fx REFUSED — '%s' owns the extent",
                                 q3e_vrRenderScale, Q3E_RenderSizeOverrideOwner() ?: "none");
                return;
            }
            Q3E_NoteRenderRestart();
            Q3E_QueueCommand("vid_restart");
            Q3E_BlackBox_Pin("VR: render quality %.2fx — restarting at %dx%dpx per eye "
                             "(was %dx%d)", q3e_vrRenderScale, w, h,
                             Q3E_VR_EngineRenderWidth(), Q3E_VR_EngineRenderHeight());
        }
        return;
    }
    if (tries >= 40) {   // 4 s — the loop runs at display rate, so this is not a race
        // Not a failure: the loop only raises a request when the target moves by
        // more than 8 px, so a small change legitimately has nothing to do. Said
        // out loud either way, because "nothing happened" is exactly the report
        // this item exists to stop being a mystery.
        Q3E_BlackBox_Pin("VR: render quality %.2fx — the per-eye target did not move "
                         "more than 8px from %dx%d; no restart", q3e_vrRenderScale,
                         Q3E_VR_EngineRenderWidth(), Q3E_VR_EngineRenderHeight());
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ q3e_vr_rescale_poll(tries + 1, gen); });
}

void Q3E_VR_ReapplyRenderScale(void) {
    // Called from the settings sheet (main thread) AND from the console command
    // handler (engine thread), so the hop is not optional.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (q3e_mode != Q3E_MODE_VR || !q3e_vr_committed ||
            q3e_vr_teardownActive || q3e_vr_finalizing)
            return;                       // outside VR the entry path applies it
        const int gen = ++q3e_vr_rescaleGen;
        // Settle first: the restart is expensive and a drag is continuous.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gen != q3e_vr_rescaleGen) return;
            if (q3e_mode != Q3E_MODE_VR || q3e_vr_teardownActive || q3e_vr_finalizing) return;
            Q3E_VR_ClearSizeRequest();
            q3e_vr_rescale_poll(0, gen);
        });
    });
}

static void q3e_enter_vr(void) {
    if (!q3e_windowParked && q3e_vc.view.window) {
        q3e_savedWindowSize = q3e_vc.view.window.bounds.size;
    }
    q3e_resume_gen++;                       // cancel any in-flight window probe
    q3e_vr_requested = Q3E_MODE_VR;
    q3e_vr_restartIssued = 0;
    q3e_vr_committed = 0;
    q3e_vr_finalizing = 0;
    Q3E_VR_ClearSizeRequest();
    gw_minimized = 1;                       // stop touching the window swapchain first
    VK_Set3DVRWanted(1);                    // depth stops being memoryless at the restart
    q3e_vr_stash_cvars();                   // BEFORE the first override

    // CLAIM THE RENDER EXTENT BEFORE THE SPACE OPENS. Opening a `.full` space is
    // a geometry event on the device: the window deactivates and resizes, and
    // the window's own resize path would then queue its own re-size of the
    // renderer on top of VR's — last writer wins, and on the first device round
    // the window won every time. From here until the 2D restore has EXECUTED,
    // every other writer is refused by name.
    Q3E_ClaimRenderSizeOverride(Q3E_VR_EXTENT_OWNER);

    // THE FRAME OWNER MOVES FIRST — before the space is opened, not after the
    // entry has settled.
    //
    // Opening a `.full` immersive space deactivates the 2D window's scene, and
    // the system then stops delivering that window's CADisplayLink callbacks. An
    // entry that still depends on the link is therefore an entry whose engine
    // FREEZES the instant the space opens: the queued r_stereo3d never drains
    // (so the renderer's minimized path skips the backend and every surface
    // sticks on the entry frame), the queued vid_restart never drains (so phase
    // 2 polls for an extent change that cannot happen and aborts by design), and
    // the audio mixer stops being ticked (so the ring starves and loops its last
    // notes). All three of those were one bug, and this is where it is fixed.
    //
    // VR ACTIVE IS NOT ARMED YET: no pose has been published, so the engine
    // renders its ordinary view until commit. Pre-poses the engine thread paces
    // itself on the rendezvous timeout, which is exactly what that timeout is
    // for — render again rather than stall the game loop.
    q3e_link_set_paused(YES);
    Q3E_VR_StartEngineThread();
    Q3E_BlackBox_Pin("VR: frame owner -> engine thread BEFORE opening the space "
                     "(link paused; entry no longer depends on the window's scene)");

    Q3E_QueueCommand("set r_stereo3d 1");   // both eyes every host frame
    // (MSAA is forced off inside the renderer while VR is wanted — see patch
    // 0009. It is not overridden here, because it is an archived latched cvar.)
    // R2 item 3: the viewmodel STAYS visible. It renders head-attached (classic
    // first-person, correct for Convenience Mode — there is no hand to re-base
    // it onto yet) and at REAL depth (RF_DEPTHHACK's viewport squash is already
    // disabled in VR by patch 0009, so nothing lies to the compositor about
    // where it sits). The HUD's 3D icons still pop toward the face in stereo
    // the same way the 3D panel's do, so that override stays.
    Q3E_QueueCommand("cg_draw3dIcons 0");
    // R4.4: and from here those two are an INVARIANT, not a pair of queued
    // commands that ran once. `game_restart` — the only shipped way to change
    // fs_game — runs Cvar_Restart(qtrue), which UNSETS r_stereo3d (the shell
    // created it, so it is CVAR_USER_CREATED) and cg_draw3dIcons (the cgame
    // created it, so it is CVAR_VM_CREATED). The eye path is gated on the first
    // of those, so before this line a mod switch taken from inside VR froze
    // `pairs=` for the rest of the session with the engine still rendering.
    // Armed HERE and disarmed in the teardown, next to the line that undoes it.
    Q3E_VR_ArmCvarInvariant(1);
    Q3E_AssertModePolicy();
    Q3E_SetVRSpace(true);
    q3e_vr_phase2(0);
}

// Entry has to wait for any teardown still unwinding: it needs to be the one
// that starts the engine thread, and there must never be a moment with no owner.
static void q3e_enter_vr_when_idle(int tries) {
    if (q3e_mode != Q3E_MODE_VR) return;            // the player changed their mind
    if (q3e_vr_teardownActive || Q3E_VR_EngineThreadRunning()) {
        if (tries >= 250) {                          // 5 s
            Q3E_BlackBox_Pin("VR: LOUD FAILURE — a previous teardown never finished; refusing "
                             "to enter VR on top of it (teardownActive=%d engineRunning=%d)",
                             q3e_vr_teardownActive, Q3E_VR_EngineThreadRunning());
            q3e_mode = Q3E_MODE_2D;
            // This return is a mode change like any other, and it is the one path
            // that reaches 2D without ever passing the handback. Without this the
            // session continues with the gyro suppressed and the audio still
            // bypassed — for the rest of the app's life.
            Q3E_AssertModePolicy();
            return;
        }
        if (tries == 0)
            Q3E_BlackBox_Pin("VR: entry waiting for the previous teardown to finish");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ q3e_enter_vr_when_idle(tries + 1); });
        return;
    }
    if (tries) Q3E_BlackBox_Pin("VR: previous teardown finished after %d poll(s) — entering", tries);
    q3e_enter_vr();
}

// --- leaving VR: one teardown, for the abort and for the exit ---------------
//
// Both paths arrive here with the ENGINE THREAD still running and the display
// link paused, and both must leave with the link running and the engine thread
// gone. The invariant that matters throughout is that SOMETHING is always
// ticking Com_Frame: the moment neither owner is live, the audio ring starves
// and the mixer loops its last notes, which is what a player hears as the game
// tearing itself apart.
//
// Order:
//   1. cancel entry work that never drained, and clear the render override
//   2. queue the restores and (only if the extent actually moved) one restart
//   3. wait for the queue to DRAIN — queued is not done
//   4. stop the compositor loop, then dismiss the space
//   5. probe the window until it provably vends a drawable
//   6. only then: stop the engine thread and hand the frame back to the link
static int q3e_vr_teardownPause = 0;
static unsigned q3e_vr_teardownSeq = 0;   // the command sequence the barrier waits for

static void q3e_vr_handback_stop(int tries);
static void q3e_vr_handback_probe(void);
static void q3e_vr_teardown_step(int stage, int tries);

static void q3e_vr_teardown(int autoPause, const char *why) {
    Q3E_BlackBox_Pin("VR: teardown — %s", why);
    q3e_vr_requested = Q3E_MODE_2D;
    q3e_vr_committed = 0;
    q3e_vr_teardownPause = autoPause;
    q3e_vr_teardownActive = 1;
    q3e_resume_gen++;

    // 1. The entry's own vid_restart may still be sitting in the queue: on the
    //    device it could not drain while the window's link was dead, and it then
    //    ran AFTER the rollback had put the size back — a full renderer restart
    //    to the VR extent, in 2D, immediately undone by a second one.
    const int cancelled = Q3E_CancelQueuedCommands("vid_restart");
    // The SIZE goes back to "follow the window" here, but OWNERSHIP does not:
    // the 2D restore restart below has not run yet, and a geometry event landing
    // between the two would size the renderer to a window that is still mid-
    // transition. Ownership is released once that restart has EXECUTED.
    Q3E_SetRenderSizeOverride(Q3E_VR_EXTENT_OWNER, 0, 0);
    Q3E_BlackBox_Pin("VR: cancelled %d queued restart(s) from the entry", cancelled);

    // 2. Restores go through the funnel because the ENGINE THREAD owns the frame
    //    here; the queue is FIFO, so the config write that follows cannot
    //    overtake them and bake an override into the player's own settings.
    if (autoPause && q3e_vrClientReason == Q3E_VRP_WORLD)
        Q3E_QueueCommand("togglemenu");     // a local game pauses on the menu
    q3e_vr_restore_cvars();
    // R4.4: disarmed BEFORE the restore is queued, so the invariant can never
    // race the teardown and put back an override the exit is in the middle of
    // taking away. Disarming early is safe in the other direction — nothing but
    // this teardown clears the two cvars on purpose.
    Q3E_VR_ArmCvarInvariant(0);
    Q3E_QueueCommand("set r_stereo3d 0");
    VK_Set3DVRWanted(0);

    // Only restart if the extent ACTUALLY moved. When the entry aborted without
    // its restart ever running, the engine is still at the window's own size and
    // a restart here would be a second pointless RE_Shutdown/R_Init cycle.
    const int winW = Q3E_LayerWidth(), winH = Q3E_LayerHeight();
    const int engW = Q3E_VR_EngineRenderWidth(), engH = Q3E_VR_EngineRenderHeight();
    if (engW != winW || engH != winH) {
        Q3E_NoteRenderRestart();
        Q3E_QueueCommand("vid_restart");
        Q3E_BlackBox_Pin("VR: engine is %dx%d and the window is %dx%d — one restart queued",
                         engW, engH, winW, winH);
    } else {
        Q3E_BlackBox_Pin("VR: engine already at the window extent %dx%d — NO restart needed",
                         engW, engH);
    }
    q3e_vr_teardownSeq = Q3E_CommandSeq();   // everything above must have RUN
    q3e_vr_teardown_step(0, 0);
}

static void q3e_vr_teardown_step(int stage, int tries) {
    if (stage == 0) {                        // 3. drain barrier
        // EXECUTED, not merely dequeued: the drain takes the whole list at once,
        // so waiting for an empty queue waves through while the vid_restart it
        // just picked up is still running — and the next step would then be a
        // second thread inside the engine.
        if (Q3E_CommandDone() >= q3e_vr_teardownSeq || tries >= 250) {   // <= 5 s
            if (tries >= 250)
                Q3E_BlackBox_Pin("VR: LOUD FAILURE — the restores had not finished after 5 s "
                                 "(done=%u wanted=%u); continuing the teardown anyway",
                                 Q3E_CommandDone(), q3e_vr_teardownSeq);
            else
                Q3E_BlackBox_Pin("VR: restores EXECUTED after %d poll(s)", tries);
            // The 2D restore has RUN (or provably will not): the window may own
            // its own size again. Released even on the timeout arm — an extent
            // nobody can ever re-size is a worse failure than a late resize.
            Q3E_ReleaseRenderSizeOverride(Q3E_VR_EXTENT_OWNER);
            q3e_vrStop = 1;                  // 4. stop the compositor loop
            q3e_vr_teardown_step(1, 0);
            return;
        }
    } else if (stage == 1) {                 // wait for the loop
        if (!q3e_vrRunning || tries >= 50) { // <= 1 s
            Q3E_BlackBox_Pin("VR: compositor loop stopped=%d — dismissing the space",
                             !q3e_vrRunning);
            Q3E_SetVRSpace(false);           // 5. dismiss; the engine thread keeps ticking
            q3e_vr_handback_probe();
            return;
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ q3e_vr_teardown_step(stage, tries + 1); });
}

// 5. The window layer has to PROVE it is alive before the engine is pointed back
//    at it; clearing gw_minimized early is how a tick acquires a dead layer and
//    wedges in MoltenVK's nextDrawable retry.
static void q3e_vr_handback_probe(void) {
    const int gen = ++q3e_resume_gen;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < 6; i++) {
            @autoreleasepool {
                if (gen != q3e_resume_gen) return;
                id<CAMetalDrawable> d = [q3e_layer nextDrawable];
                if (d) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (gen != q3e_resume_gen) return;
                        Q3E_BlackBox_Pin("VR: window layer is live again — handing the frame back");
                        q3e_vr_handback_stop(0);
                    });
                    return;
                }
                Q3E_BlackBox("VR handback: nextDrawable probe %d nil", i);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != q3e_resume_gen) return;
            Q3E_BlackBox_Pin("VR: LOUD FAILURE — the window layer never vended a drawable after "
                             "leaving VR; handing the frame back anyway (the engine thread "
                             "cannot be left owning a dismissed space)");
            q3e_vr_handback_stop(0);
        });
    });
}

// 6. Stop the engine thread and resume the link, in that order and as close
//    together as a bounded poll allows.
static void q3e_vr_handback_stop(int tries) {
    if (tries == 0) Q3E_VR_RequestEngineStop();
    if (Q3E_VR_EngineThreadRunning()) {
        if (tries >= 100) {
            Q3E_BlackBox_Pin("VR: LOUD FAILURE — the engine thread did not stop in 2 s. Keeping "
                             "owner=vr and the link paused; retrying.");
            Q3E_VR_RequestEngineStop();
            tries = 0;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ q3e_vr_handback_stop(tries + 1); });
        return;
    }
    Q3E_VR_FinishEngineStop();               // owner -> display link, listener off
    q3e_vr_teardownActive = 0;
    VK_SetVRActive(0);                       // after the last VR frame, never mid-frame
    // The config write happens HERE, and only here: main provably owns the frame
    // now, so EXEC_NOW is legal. Doing it while the engine thread was still alive
    // meant two threads in the engine at once, which aborted the process inside
    // MoltenVK during the restart. The restores ran before the engine stopped, so
    // the ordering this write depends on still holds.
    Q3E_OnResignActive();
    gw_minimized = 0;
    q3e_link_set_paused(NO);
    q3e_park_window(false);
    Q3E_AssertModePolicy();
    Q3E_BlackBox_Pin("VR: handback complete (owner=link, gw_minimized=0, engine %dx%d)",
                     Q3E_VR_EngineRenderWidth(), Q3E_VR_EngineRenderHeight());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (q3e_mode == Q3E_MODE_2D) [q3e_vc applyResize];
    });
}

// An entry that never became a VR session. Same teardown — the state it has to
// undo is the same state, and two teardowns that drift is how the gun stayed
// hidden on one exit path and not the other.
static void q3e_vr_abort_entry(const char *why) {
    Q3E_BlackBox_Pin("VR: ENTRY ABORTED — %s. Rolling back to the 2D window.", why);
    q3e_mode = Q3E_MODE_2D;
    q3e_vr_finalizing = 1;
    q3e_vr_teardown(0, "entry aborted");
}

// Called from Swift when openImmersiveSpace did not return .opened.
void Q3E_VR_OpenFailed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (q3e_mode != Q3E_MODE_VR) return;
        q3e_vr_abort_entry("the system refused to open the VR space");
    });
}

// Idempotent and unconditional. Called from the dismissal completion on both
// exit paths — the button and the system's own (Crown, a space we were not told
// closed). The heavy lifting is in the teardown; this is what SwiftUI can tell
// us happened, and it must be harmless to run twice.
void Q3E_ExitVRFinalize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        q3e_park_window(false);
        Q3E_AssertModePolicy();
        Q3E_BlackBox_Pin("VR: finalize (gw_minimized=%d parked=%d owner=%d)",
                         gw_minimized, q3e_windowParked, q3e_frame_owner);
    });
}

static void q3e_leave_vr(void) {
    // Claim the finalize before dismissing: the loop is stopped and waited for
    // inside the teardown, so it normally exits without ever seeing the layer
    // invalidated — but if it were wedged past its grace period the dismissal
    // WOULD invalidate the layer, and the system-dismissal path would then run a
    // second exit on top of this one.
    q3e_vr_finalizing = 1;
    q3e_vr_teardown(0, "leaving VR (player asked)");
}

// The system took the space away (Digital Crown, a system alert, a dismissal
// nobody told us about). It is not an exit we control, so it gets its own entry
// point: idempotent, unconditional, and it pauses the game — a player yanked out
// of VR is being shot at by a world they cannot see.
void Q3E_VR_Ended(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (q3e_vr_finalizing) return;
        q3e_vr_finalizing = 1;
        Q3E_BlackBox_Pin("VR: ENDED by the system (mode was %s)", Q3E_ModeName(q3e_mode));
        q3e_mode = Q3E_MODE_2D;
        q3e_vr_teardown(1, "system dismissal");
    });
}

// The single owner of every mode transition. ALWAYS main-thread: `q3evr` and
// `stereo` are console commands, and console commands are executed by whichever
// thread owns the engine — which in VR is the thread this function has to stop.
void Q3E_EnterMode(int mode) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ Q3E_EnterMode(mode); });
        return;
    }
    if (!q3e_booted) { Q3E_BlackBox_Pin("EnterMode(%d) IGNORED pre-boot", mode); return; }
    if (mode < Q3E_MODE_2D || mode > Q3E_MODE_VR) return;
    if (mode == q3e_mode) return;
    const int from = q3e_mode;
    Q3E_BlackBox_Pin("mode: %s -> %s", Q3E_ModeName(from), Q3E_ModeName(mode));

    if (from == Q3E_MODE_3D)      Q3E_Enter3D(false);
    else if (from == Q3E_MODE_VR) q3e_leave_vr();

    q3e_mode = mode;
    // Assert the mode-owned policy here for every transition EXCEPT leaving VR.
    //
    // Leaving VR is asynchronous: the tri-state flips immediately, but the VR
    // space keeps presenting and the engine thread keeps rendering for as long as
    // the teardown takes to unwind. Asserting 2D policy at the flip un-suppresses
    // the head gyro while the head is still driving the camera — so the crosshair
    // walks away for the whole exit, every exit — and puts the audio back on the
    // window while the sound is still coming from a VR world. The handback, where
    // the display link actually takes the frame back, is the moment the mode is
    // TRUE; q3e_vr_handback_stop asserts it there.
    if (from != Q3E_MODE_VR)
        Q3E_AssertModePolicy();
    if (mode == Q3E_MODE_2D)
        return;

    // One space at a time: a direct 3D<->VR switch has to let the first one
    // finish dismissing before the second opens, with the engine running
    // throughout.
    const int gap = (from == Q3E_MODE_2D) ? 0 : 1;
    void (^open)(void) = ^{
        if (q3e_mode != mode) return;       // the player changed their mind
        if (mode == Q3E_MODE_3D) Q3E_Enter3D(true);
        else                     q3e_enter_vr_when_idle(0);
    };
    if (gap)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), open);
    else
        open();
}

// `stereo` console command toggles the 3D panel; `q3evr [0|1]` toggles VR.
static void Q3E_Cmd_Stereo(void) {
    Q3E_EnterMode(q3e_mode == Q3E_MODE_3D ? Q3E_MODE_2D : Q3E_MODE_3D);
}

static void Q3E_Cmd_VR(void) {
    int on = (q3e_mode != Q3E_MODE_VR);
    if (Cmd_Argc() == 2) on = atoi(Cmd_Argv(1)) ? 1 : 0;
    Q3E_EnterMode(on ? Q3E_MODE_VR : Q3E_MODE_2D);
}

static void Q3E_Cmd_VRRecenter(void) { Q3E_VR_Recenter(); }

// Test hooks. `q3evrlinkfreeze 1` makes the simulator behave like the device,
// where opening a full immersive space kills the 2D window's display link;
// `q3evrfailentry 1` forces phase 2 never to settle so the rollback can be
// asserted instead of argued about.
static void Q3E_Cmd_VRLinkFreeze(void) {
    if (Cmd_Argc() != 2) { Com_Printf("q3evrlinkfreeze <0|1>\n"); return; }
    Q3E_DebugFreezeLink(atoi(Cmd_Argv(1)));
    Com_Printf("q3evrlinkfreeze: %s\n", atoi(Cmd_Argv(1)) ? "ON" : "off");
}

static void Q3E_Cmd_VRFailEntry(void) {
    if (Cmd_Argc() != 2) { Com_Printf("q3evrfailentry <0|1>\n"); return; }
    Q3E_DebugFailEntry(atoi(Cmd_Argv(1)));
    Com_Printf("q3evrfailentry: %s\n", atoi(Cmd_Argv(1)) ? "ON" : "off");
}

// `q3evrwindowchurn <n>` — fire the window's own geometry/resize handlers n
// times, the way the device's scene events do during a VR entry.
static void Q3E_Cmd_VRWindowChurn(void) {
    const int n = (Cmd_Argc() == 2) ? atoi(Cmd_Argv(1)) : 3;
    Q3E_DebugWindowChurn(n);
    Com_Printf("q3evrwindowchurn: %d pass(es) queued; extent owner=%s refusals=%d\n",
               n, Q3E_RenderSizeOverrideOwner() ? Q3E_RenderSizeOverrideOwner() : "none",
               Q3E_RenderSizeOverrideRefusals());
}

static UILabel *q3e_fpsLabel;
static NSTimer *q3e_fpsTimer;
static int q3e_frameCount;

// The settings "60/native" toggle maps to the display-link range exactly as on
// iOS. Native REQUESTS up to 120: the M5 Vision Pro compositor runs 120 Hz;
// earlier panels grant 90 — the OS clamps the range to what the display does,
// so asking high never harms (the old hardcoded 90 handicapped the M5).
void Q3E_Shell_SetRefreshMode(int mode60) {
    if (!q3e_link) return;
    if (mode60) q3e_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    else        q3e_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
}

// Engine frame rate, published for the immersive compositor's own FPS overlay (the
// panel's counter — a bare number, drawn by us, not the cgame QVM's "###fps" HUD).
volatile int q3e_engineFPS = 0;
int Q3E_FPSCounterEnabled(void) { return q3e_fpsEnabled ? 1 : 0; }

void Q3E_Shell_SetFPSCounter(int enabled) {
    q3e_fpsEnabled = enabled;
    q3e_fpsLabel.hidden = !enabled;
    if (enabled && !q3e_fpsTimer) {
        q3e_fpsTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            static int last;
            int now = q3e_frameCount;
            q3e_engineFPS = (now - last) * 2;
            q3e_fpsLabel.text = [NSString stringWithFormat:@"%d", q3e_engineFPS];
            last = now;
        }];
    } else if (!enabled && q3e_fpsTimer) {
        [q3e_fpsTimer invalidate];
        q3e_fpsTimer = nil;
    }
}

// Public interface is in AppShell_vision.h (so Swift can host it); private state
// here as a class extension.
@interface Q3EVisionViewController ()
@property (nonatomic) BOOL booted;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) CGSize lastSize;   // last applied window size (resize detect)
@property (nonatomic) NSInteger resizeGen; // debounce token for resize -> vid_restart
@property (nonatomic) BOOL aspectLocked;
@end

@implementation Q3EVisionViewController
- (void)loadView {
    self.view = [[Q3EInputView alloc] init];
    self.view.backgroundColor = [UIColor blackColor];
    q3e_vc = self;   // parked-window plumbing reaches the VC from C callbacks
    // Claim the gamepad from the system. visionOS by default converts controller
    // presses into gaze-pinch UI events (A = tap where you look) and withholds
    // them from GCController; this interaction declares the view handles the
    // pad via the GameController framework, so ios_input.m's polling gets real input.
    if (@available(visionOS 2.0, *)) {
        GCEventInteraction *padIntent = [[GCEventInteraction alloc] init];
        padIntent.handledEventTypes = GCUIEventTypeGamepad;
        [self.view addInteraction:padIntent];
    }
}
- (BOOL)prefersStatusBarHidden { return YES; }

// Lock the window's aspect ratio (uniform resizing) once the window/scene exists.
// Moved here from the old scene delegate now that SwiftUI hosts this VC. See D-018:
// scale-only resizing means the fixed-aspect render always fills, no bars/distortion.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.aspectLocked) return;
    UIWindowScene *ws = self.view.window.windowScene;
    if (!ws) return;
    self.aspectLocked = YES;
    UIWindowSceneGeometryPreferencesVision *geo =
        [[UIWindowSceneGeometryPreferencesVision alloc] init];
    geo.resizingRestrictions = UIWindowSceneResizingRestrictionsUniform;
    [ws requestGeometryUpdateWithPreferences:geo errorHandler:^(NSError *error) {
        NSLog(@"Q3E-VISION geometry lock error: %@", error.localizedDescription);
    }];
    NSLog(@"Q3E-VISION aspect locked");
}

- (void)updateDrawableSize {
    CGSize sz = self.view.bounds.size;
    CGFloat scale = self.traitCollection.displayScale;
    if (scale <= 0) scale = 2.0;
    // Push the drawable's long edge toward 4K. The engine fixes its render resolution
    // at this initial FBO size (overlay patch 0004), and the visionOS 3D panel samples
    // that FBO per eye — so a ~4K FBO means ~4K per eye. Supersamples the 2D window too;
    // Vision Pro handles Quake at this resolution easily.
    CGFloat longEdge = MAX(sz.width, sz.height) * scale;
    const CGFloat kTargetLongEdge = 3840.0;
    if (longEdge > 0 && longEdge < kTargetLongEdge)
        scale *= kTargetLongEdge / longEdge;
    CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
    layer.contentsScale = scale;
    layer.drawableSize = CGSizeMake(sz.width * scale, sz.height * scale);
    NSLog(@"Q3E-VISION drawable -> %.0fx%.0f (scale %.2f)",
          layer.drawableSize.width, layer.drawableSize.height, scale);
}

// A settled window resize: update the drawable and tell the engine the new
// window size via `vid_resize` (overlay patch 0004). The engine keeps its render
// resolution FIXED (so the QVM cgame's cached glconfig stays valid — no crop, no
// black, no re-init) and scales that fixed-res render to fill the new window via
// its built-in render-scale blit. Cheap: a swapchain recreate, no VM/map/texture
// reload, no vid_restart hitch.
- (void)applyResize {
    // The gate comes FIRST, before the drawable is touched: updateDrawableSize
    // moves the layer's own size, which is what the swapchain's currentExtent is
    // derived from, so "only" skipping the vid_resize would still move the
    // renderer under VR.
    if (q3e_render_resize_refused("applyResize")) return;
    [self updateDrawableSize];
    CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
    int w = (int)layer.drawableSize.width, h = (int)layer.drawableSize.height;
    char cmd[64];
    snprintf(cmd, sizeof(cmd), "vid_resize %d %d", w, h);
    Q3E_QueueCommand(cmd);
    NSLog(@"Q3E-VISION resized -> %dx%d (vid_resize)", w, h);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize sz = self.view.bounds.size;

    if (self.booted) {
        // In 3D (or while presents are disabled) the window is only a control card:
        // its park/restore animations must NOT drive vid_resize (recipe trap c — a
        // resize racing renderer work wedges swapchain recreation). Track the size so
        // later diffing stays sane; the exit path re-syncs once presents resume.
        if (q3e_immersive_on || gw_minimized) { self.lastSize = sz; return; }
        // ...and the same for a VR session that has not minimized the window yet
        // (entry claims the extent before the space opens, which is exactly the
        // window that the device's scene-geometry churn lands in).
        if (q3e_render_resize_refused("viewDidLayoutSubviews")) { self.lastSize = sz; return; }
        // Window resize. Don't grow the drawable mid-drag — the layer stretches
        // the current drawable to fill the new bounds (blurry but full, no black
        // gap). Debounce, then vid_resize (patch 0004) so the engine recreates
        // its FBO + swapchain at the new resolution and fills the window crisply.
        if (fabs(sz.width - self.lastSize.width) < 1.0 &&
            fabs(sz.height - self.lastSize.height) < 1.0) return;
        self.lastSize = sz;
        NSInteger gen = ++self.resizeGen;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s && gen == s.resizeGen && s.booted) [s applyResize];
        });
        return;
    }
    // no orientation gate on visionOS — just wait for a real window size
    if (sz.width < 16 || sz.height < 16) {
        NSLog(@"Q3E-VISION gate: window has no size yet (%.0fx%.0f)", sz.width, sz.height);
        return;
    }

    [self updateDrawableSize];
    CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
    q3e_layer = layer;

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    Q3E_SetDocumentsPath(docs.fileSystemRepresentation);
    Q3E_BlackBox_Init(docs.fileSystemRepresentation);

    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *quake3Home = [appSupport stringByAppendingPathComponent:@"Quake3"];
    [NSFileManager.defaultManager createDirectoryAtPath:quake3Home
                            withIntermediateDirectories:YES attributes:nil error:nil];

    NSLog(@"Q3E-VISION boot: drawable %.0fx%.0f scale %.2f docs %@",
          layer.drawableSize.width, layer.drawableSize.height, self.traitCollection.displayScale, docs);
    self.lastSize = sz;
    self.booted = YES;

    int Q3E_HasGameData(void);
    void Q3E_PresentOnboarding(UIViewController *host, void (^onReady)(void));
    if (!Q3E_HasGameData()) {
        NSLog(@"Q3E-VISION: no game data — presenting onboarding");
        dispatch_async(dispatch_get_main_queue(), ^{
            Q3E_PresentOnboarding(self, ^{ [self bootEngineNow]; });
        });
        return;
    }
    [self bootEngineNow];
}

// The render extent's owner lives in the shared shell (ios_glue.c), which the
// iPhone target compiles without a black box; on visionOS its claims, releases
// and refusals belong in the pinned region like every other transition.
static void q3e_render_override_reporter(const char *line) {
    Q3E_BlackBox_PinStr(line);
}

- (void)bootEngineNow {
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    Q3E_SetRenderOverrideReporter(q3e_render_override_reporter);

    void Q3E_PakMan_Startup(void);
    Q3E_PakMan_Startup();

    // Before renderer init: ask the renderer to create the per-eye stereo snapshot
    // images alongside its other attachments (patch 0007 — they ride the pooled
    // attachment allocation, so this can't happen lazily after init).
    VK_Set3DWanted(1);
    Q3E_BootEngine();
    q3e_booted = true;
    Cmd_AddCommand("stereo", Q3E_Cmd_Stereo);   // toggle 3D immersive space
    q3e_vr_recover_stash_on_launch();           // repair a config left overridden
    Cmd_AddCommand("q3evr", Q3E_Cmd_VR);        // enter/leave VR
    Cmd_AddCommand("q3evrrecenter", Q3E_Cmd_VRRecenter);
    Cmd_AddCommand("q3evrlinkfreeze", Q3E_Cmd_VRLinkFreeze);
    Cmd_AddCommand("q3evrfailentry", Q3E_Cmd_VRFailEntry);
    Cmd_AddCommand("q3evrwindowchurn", Q3E_Cmd_VRWindowChurn);
    Q3E_VR_RegisterCommands();                  // VR dumps + synthetic injection
    // In 3D the engine is "minimized" (window hidden, rendering off-screen) but must
    // keep playing sound — disable the minimized/unfocused mute (3D design notes).
    Q3E_QueueCommand("set s_muteWhenMinimized 0");
    Q3E_QueueCommand("set s_muteWhenUnfocused 0");
    Q3E_BlackBox_Pin("engine booted");
    // Black-box watchdog: post-mortem this timestamps exactly when the main and
    // immersive threads stop (wedge vs suspension vs kill), from one file (design notes §3).
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        for (;;) {
            Q3E_BlackBox("watchdog main=%d imm=%d gw_min=%d immersive=%d",
                         q3e_frameCount, q3e_immFrameCount, gw_minimized, q3e_immersive_on);
            sleep(2);
        }
    });

    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    self.link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);  // M5 AVP = 120 Hz; OS clamps on 90 Hz panels
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    q3e_link = self.link;
    NSLog(@"Q3E-VISION display link started");

    q3e_fpsLabel = [[UILabel alloc] init];
    q3e_fpsLabel.textColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:0.9];
    q3e_fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightBold];
    q3e_fpsLabel.hidden = YES;
    q3e_fpsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:q3e_fpsLabel];
    [NSLayoutConstraint activateConstraints:@[
        [q3e_fpsLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        // Anchor to the view's true leading edge (not the safe-area inset, which pads it
        // rightward on visionOS) so the FPS counter sits further left — nudged another
        // 12 pt in (was +14) alongside the same request on the phone.
        [q3e_fpsLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:2],
    ]];

    Q3E_Settings_ApplyAll();

    // NOTE: filter by the WINDOW's scene. object:nil fires for ANY scene, including the
    // immersive space's — which would un-pause/re-pause the engine at the wrong time
    // (3D design notes). We only react to the 2D window scene's own transitions.
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillDeactivateNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        UIScene *sc = n.object;
        BOOL isWindow = (sc == self.view.window.windowScene);
        Q3E_BlackBox("WillDeactivate scene=%p isWindow=%d state=%ld immersive=%d",
                     sc, isWindow, (long)sc.activationState, q3e_immersive_on);
        if (!isWindow) return;
        Q3E_OnResignActive();                    // flush config (cheap, still correct)
        Q3E_BlackBox_Flush();                    // ...and the black box, unthrottled:
                                                 // a resign is frequently the first half
                                                 // of a swipe-kill, and that is SIGKILL
        if (q3e_mode != Q3E_MODE_2D || q3e_frame_owner != Q3E_FRAME_OWNER_LINK) {
            // 3D or VR: the window hides but the game keeps running — in an
            // immersive space it IS the presentation. Pausing here silenced the
            // whole VR session, because there is no window activation to resume
            // it, and paused the display link during VR entry so the queued
            // vid_restart never drained.
            Q3E_BlackBox("WillDeactivate: mode=%s owner=%d — engine keeps running",
                         Q3E_ModeName(q3e_mode), q3e_frame_owner);
            return;
        }
        q3e_link_set_paused(YES);
        Q3E_SND_Pause();
        NSLog(@"Q3E-VISION: deactivated");
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        UIScene *sc = n.object;
        BOOL isWindow = (sc == self.view.window.windowScene);
        Q3E_BlackBox("DidActivate scene=%p isWindow=%d state=%ld gw_min=%d",
                     sc, isWindow, (long)sc.activationState, gw_minimized);
        if (!isWindow || !self.booted) return;
        if (q3e_mode != Q3E_MODE_2D || q3e_frame_owner != Q3E_FRAME_OWNER_LINK) {
            // The window came back while an immersive space owns the engine.
            // Resuming the display link here would put a SECOND caller into
            // Q3E_Frame alongside the VR engine thread, and clearing
            // gw_minimized would hand the engine a parked, hidden swapchain.
            Q3E_BlackBox_Pin("DidActivate ignored: mode=%s owner=%d owns the frame",
                             Q3E_ModeName(q3e_mode), q3e_frame_owner);
            return;
        }
        // Resume link+sound immediately — ticks are safe while gw_minimized=1. But
        // re-enable presents ONLY once the layer PROVABLY vends a drawable (design-notes Bug B):
        // scene activation precedes layer re-attach, and clearing gw_minimized too early
        // lets a tick acquire a dead layer -> MoltenVK nextDrawable infinite retry -> wedge.
        q3e_link_set_paused(NO);
        Q3E_SND_Resume();
        if (gw_minimized) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                for (int i = 0; i < 6; i++) {            // ~6 s worst case (1 s timeout each)
                    @autoreleasepool {
                        id<CAMetalDrawable> d = [q3e_layer nextDrawable];
                        if (d) {                          // released unpresented -> back to pool
                            dispatch_async(dispatch_get_main_queue(), ^{
                                gw_minimized = 0;
                                Q3E_BlackBox("window layer live -> presents re-enabled");
                                NSLog(@"Q3E-VISION: presents re-enabled (layer live)");
                            });
                            return;
                        }
                        Q3E_BlackBox("nextDrawable probe %d: nil", i);
                    }
                }
                Q3E_BlackBox("LOUD FAILURE: window layer never vended a drawable; staying off-screen");
                NSLog(@"Q3E-VISION: LOUD FAILURE — window layer never vended a drawable");
            });
        }
        NSLog(@"Q3E-VISION: reactivated");
    }];

    // Exit-bug diagnostics: catch exactly why the app closes on leaving 3D — is the
    // window scene torn down, is the app backgrounded, or terminated? Each logs to the
    // (now append-mode) black box with whether we were immersive at the time.
    // Remember the 2D window's scene: after a disconnect, self.view.window is nil, so
    // the guard below compares against this captured reference.
    __block __weak UIScene *windowScene = self.view.window.windowScene;
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidDisconnectNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        BOOL isWindow = (n.object == windowScene);
        Q3E_BlackBox("SceneDidDisconnect scene=%p isWindow=%d immersive=%d",
                     n.object, (int)isWindow, q3e_immersive_on);
        // vkQuake recipe 1 guard: if the (parked) control card is closed outright
        // during 3D, losing the last regular scene also kills the audio session —
        // ask the system to bring the window back.
        if (isWindow && q3e_immersive_on) {
            q3e_windowParked = false;    // its geometry died with the scene
            [q3e_curtain removeFromSuperview];
            q3e_curtain = nil;           // ...and so did the curtain
            [UIApplication.sharedApplication requestSceneSessionActivation:nil
                userActivity:nil options:nil errorHandler:nil];
            Q3E_BlackBox("card closed during 3D -> requested window reactivation");
        }
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidEnterBackgroundNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        Q3E_BlackBox("SceneDidEnterBackground scene=%p isWindow=%d immersive=%d",
                     n.object, (int)(n.object == self.view.window.windowScene), q3e_immersive_on);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        Q3E_BlackBox("AppWillTerminate immersive=%d", q3e_immersive_on);
    }];
}
- (void)tick:(CADisplayLink *)link {
    // 3D mode (patch 0007): both eyes render every frame via the engine's native
    // stereo fields (r_stereo3d, set on enter) — no per-frame eye alternation here.
    if (q3e_immersive_on && (q3e_frameCount % 240) == 0)
        Q3E_BlackBox("tick: immersive_on=1 frame=%d (both-eyes mode)", q3e_frameCount);
    Q3E_Frame();
    q3e_frameCount++;
}
@end

// quake3e:// deep-link / launch URL handling. Called from SwiftUI onOpenURL
// (Q3EVisionApp.swift) — the SwiftUI app entry replaced the old UIKit scene
// delegate that used to parse UIOpenURLContexts.
void Q3E_HandleURL(const char *urlStr) {
    void Q3E_RequestMod(const char *mod);
    if (!urlStr) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:urlStr]];
    if (![url.scheme isEqualToString:@"quake3e"]) return;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *game = @"baseq3";
    for (NSURLQueryItem *q in c.queryItems)
        if ([q.name isEqualToString:@"game"] && q.value.length) game = q.value;
    NSLog(@"Q3E-VISION URL -> mod '%@'", game);
    Q3E_RequestMod(game.UTF8String);
}
