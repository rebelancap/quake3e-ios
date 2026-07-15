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
void Cmd_AddCommand(const char *cmd_name, void (*function)(void));
extern int gw_minimized;   // engine "don't touch the window swapchain" switch (qboolean)
extern int q3e_immFrameCount;   // Q3EImmersive.m — immersive frames presented (watchdog)
extern void VK_Set3DEye(int eye);   // renderervk patch 0006: 0=off(2D), 1=left, 2=right
extern void VK_Set3DWanted(int on); // renderervk patch 0007: create per-eye images at init
extern volatile int q3e_immStop;    // Q3EImmersive.m — graceful-shutdown handshake
extern volatile int q3e_immRunning;

static bool q3e_immersive_on = false;
static bool q3e_booted = false;

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

// The parked card would otherwise show the FROZEN last 2D frame (gw_minimized) —
// confusing floating next to the live panel (vkQuake note; Austin flagged it). Cover
// the window with a black curtain + label while parked.
static void q3e_set_curtain(bool show) {
    [q3e_curtain removeFromSuperview];
    q3e_curtain = nil;
    if (!show) return;
    UIWindow *win = q3e_vc.view.window;
    if (!win) return;
    UIView *cover = [[UIView alloc] initWithFrame:win.bounds];
    cover.backgroundColor = UIColor.blackColor;
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UILabel *l = [[UILabel alloc] init];
    l.text = @"Playing in 3D";
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
}

// NB: q3e_savedWindowSize is NOT captured here — opening the ImmersiveSpace can make
// visionOS resize the main window itself, so reading bounds at (+1.5 s) park time saved
// the SYSTEM-modified size and the window never restored to the user's own (vkQuake
// root-cause). It's captured at the very top of Q3E_Enter3D(true), pre-transition.
static void q3e_park_window(bool park) {
    UIWindowScene *ws = q3e_vc.view.window.windowScene;
    if (!ws) { Q3E_BlackBox("park(%d): no window scene", park); return; }
    if (park == q3e_windowParked) return;
    q3e_windowParked = park;
    q3e_set_curtain(park);
    CGSize target = park ? CGSizeMake(480, 270) : q3e_savedWindowSize;
    if (target.width < 100 || target.height < 60) return;   // never a degenerate size
    UIWindowSceneGeometryPreferencesVision *geo =
        [[UIWindowSceneGeometryPreferencesVision alloc] init];
    geo.size = target;
    [ws requestGeometryUpdateWithPreferences:geo errorHandler:^(NSError *e) {
        Q3E_BlackBox("park(%d) geometry error: %s", park,
                     e.localizedDescription.UTF8String ?: "?");
    }];
    Q3E_BlackBox("park(%d): window -> %.0fx%.0f", park, target.width, target.height);
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < 6; i++) {
            @autoreleasepool {
                id<CAMetalDrawable> d = [q3e_layer nextDrawable];
                if (d) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        gw_minimized = 0;
                        Q3E_BlackBox("exit 3D: window layer live -> 2D presents re-enabled");
                        NSLog(@"Q3E-VISION: 2D presents re-enabled after exiting 3D");
                        // The window was just un-parked; the normal resize->vid_resize
                        // path was gated during 3D, so re-sync the swapchain to the
                        // restored size once the animation has had time to settle.
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{ [q3e_vc applyResize]; });
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
    Q3E_BlackBox("Enter3D(%d) gw_minimized=%d", on, gw_minimized);
    NSLog(@"Q3E-VISION: 3D -> %d (gw_minimized=%d)", on, gw_minimized);
}

// Called from the immersive render loop when the space is dismissed (e.g. Digital
// Crown), to reconcile our state + the SwiftUI model/button however it closed.
void Q3E_Immersive_Ended(void) {
    Q3E_BlackBox("Immersive_Ended (loop saw invalidated)");
    dispatch_async(dispatch_get_main_queue(), ^{
        q3e_immersive_on = false;
        Q3E_QueueCommand("set r_stereo3d 0");   // back to single-field frames
        VK_Set3DEye(0);                  // back to normal 2D rendering
        q3e_park_window(false);          // restore the parked control card
        Q3E_SetImmersiveMode(false);
        Q3E_Resume2DWindow();            // resume drawing to the 2D window
        NSLog(@"Q3E-VISION: 3D ended (space dismissed)");
    });
}

// `stereo` console command toggles 3D (M3 -> real in-game settings toggle).
static void Q3E_Cmd_Stereo(void) {
    Q3E_Enter3D(!q3e_immersive_on);
}

static CADisplayLink *q3e_link;
static UILabel *q3e_fpsLabel;
static NSTimer *q3e_fpsTimer;
static int q3e_frameCount;

// visionOS composits at ~90 Hz; the settings "60/native" toggle maps to the
// display-link range exactly as on iOS (native = up to 90 here).
void Q3E_Shell_SetRefreshMode(int mode60) {
    if (!q3e_link) return;
    if (mode60) q3e_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    else        q3e_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 90, 90);
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

- (void)bootEngineNow {
    [UIApplication sharedApplication].idleTimerDisabled = YES;

    void Q3E_PakMan_Startup(void);
    Q3E_PakMan_Startup();

    // Before renderer init: ask the renderer to create the per-eye stereo snapshot
    // images alongside its other attachments (patch 0007 — they ride the pooled
    // attachment allocation, so this can't happen lazily after init).
    VK_Set3DWanted(1);
    Q3E_BootEngine();
    q3e_booted = true;
    Cmd_AddCommand("stereo", Q3E_Cmd_Stereo);   // toggle 3D immersive space
    // In 3D the engine is "minimized" (window hidden, rendering off-screen) but must
    // keep playing sound — disable the minimized/unfocused mute (3D design notes).
    Q3E_QueueCommand("set s_muteWhenMinimized 0");
    Q3E_QueueCommand("set s_muteWhenUnfocused 0");
    Q3E_BlackBox("engine booted");
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
    self.link.preferredFrameRateRange = CAFrameRateRangeMake(60, 90, 90);
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
        // rightward on visionOS) so the FPS counter sits further left.
        [q3e_fpsLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:14],
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
        if (q3e_immersive_on) {
            // 3D: the window hides but the game keeps running off-screen — don't pause.
            NSLog(@"Q3E-VISION: window deactivated (3D active) — engine keeps running");
            return;
        }
        self.link.paused = YES;
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
        // Resume link+sound immediately — ticks are safe while gw_minimized=1. But
        // re-enable presents ONLY once the layer PROVABLY vends a drawable (design-notes Bug B):
        // scene activation precedes layer re-attach, and clearing gw_minimized too early
        // lets a tick acquire a dead layer -> MoltenVK nextDrawable infinite retry -> wedge.
        self.link.paused = NO;
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
