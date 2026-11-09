// ios_mouse.m — hardware mouse on iPad, read natively through GameController.
//
// Without this file a mouse only ever reached the game as emulated touches: a
// drag turned the view until the pointer hit the screen edge, every button was
// a tap (= MOUSE1) and the wheel did nothing (GitHub issues #3 and #4).
//
// Routing, decided once per frame from the engine's key catcher:
//   * GAME (no UI/console catcher, connected): the scene asks iPadOS for pointer
//     lock; GCMouse motion drives the view as raw counts (the engine's
//     `sensitivity` cvar scales it, exactly as on desktop); buttons are
//     MOUSE1..MOUSE5; the wheel is MWHEELUP/MWHEELDOWN. The touch layer ignores
//     every indirect-pointer touch while a mouse exists.
//   * MENU (UI or console up, or not in a game): pointer unlocked and visible.
//     The LEFT click keeps travelling the touch layer's indirect-pointer tap
//     path, because that path is what warps the q3 cursor to where the system
//     pointer is before it clicks — a GCMouse left edge would click wherever the
//     q3 cursor happened to be. So a GCMouse left PRESS is suppressed here in
//     menus (one click, one MOUSE1). Right/middle/aux and the wheel come from
//     GCMouse in menus too; that is what lets the Controls menu bind MOUSE2.
//   * BLOCKED (a UIKit sheet over the game, or the scene inactive): nothing
//     reaches the engine; every held button is released.
//   Any change of route releases every mouse button the engine holds, so a
//   button held across ESC can never stick.
//
// Button state is ONE stream per button across every GCMouse object, newest
// edge wins. This is the field lesson from the same reporter on vkQuake-ios
// (issue #6, four rounds): one physical mouse can be two or more GCMouse
// objects (a Razer was two with the same name plus a nameless third that
// carried most left clicks), iPadOS tears them down and re-creates them during
// play, and a press can be released on a different object than the one that
// reported it. Hence also: a removed object releases the buttons whose latest
// press was its own; a polled guard releases a button nobody reports pressed
// for several frames; and a LONE release from an object that still believed
// the button was down (its press went to another object, so it sent nothing
// for the next real press) is played back as one short click.
//
// Handlers run on the main queue (GCMouse's default handlerQueue — never give
// it a private one: the state below is main-thread only) and feed the engine
// through the thread-safe producers in ios_glue.c.

#import "ios_mouse.h"
#import <GameController/GameController.h>
#import <QuartzCore/CABase.h>   // CACurrentMediaTime
#include <math.h>
#include <string.h>
#include <stdlib.h>

void Q3E_QueueMouse(int dx, int dy);
void Q3E_QueueNamedKey(const char *name, int down);
int  Q3E_KeyDownCount(const char *name);   // ios_glue.c: SE_KEY downs queued per key
void Com_Printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

int q3e_hwfault = 0;

static const struct { const char *name; int bit; } q3e_fault_names[] = {
    { "nosuppress",  Q3E_FAULT_NOSUPPRESS },
    { "rightasleft", Q3E_FAULT_RIGHTASLEFT },
    { "nowheel",     Q3E_FAULT_NOWHEEL },
    { "nomove",      Q3E_FAULT_NOMOVE },
    { "norelease",   Q3E_FAULT_NORELEASE },
    { "notap",       Q3E_FAULT_NOTAP },
    { "nodedupe",    Q3E_FAULT_NODEDUPE },
    { "nochars",     Q3E_FAULT_NOCHARS },
    { "norepeat",    Q3E_FAULT_NOREPEAT },
    { "anyrepeat",   Q3E_FAULT_ANYREPEAT },
    { "noguard",     Q3E_FAULT_NOGUARD },
    { "nofilter",    Q3E_FAULT_NOFILTER },
};

void Q3E_HwFault_Cmd(int argc, const char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "clear")) {
        q3e_hwfault = 0;
    } else if (argc >= 3) {
        int found = 0;
        for (size_t i = 0; i < sizeof(q3e_fault_names) / sizeof(q3e_fault_names[0]); i++) {
            if (strcmp(argv[1], q3e_fault_names[i].name)) continue;
            found = 1;
            if (atoi(argv[2])) q3e_hwfault |= q3e_fault_names[i].bit;
            else               q3e_hwfault &= ~q3e_fault_names[i].bit;
        }
        if (!found) Com_Printf("q3e_hwfault: unknown fault '%s'\n", argv[1]);
    } else if (argc != 1) {
        Com_Printf("usage: q3e_hwfault [<name> <0|1> | clear]\n");
        return;
    }
    Com_Printf("HWFAULT mask=0x%x\n", q3e_hwfault);
}

#if TARGET_OS_VISION
// visionOS: no pointer lock, no GCMouse layer. Inert stubs so the shared touch
// code links unchanged.
void Q3E_Mouse_Start(UIViewController *host) { (void)host; }
void Q3E_Mouse_Frame(int menuMode) { (void)menuMode; }
int  Q3E_Mouse_Present(void) { return 0; }
int  Q3E_Mouse_HwKeyboardPresent(void) { return 0; }
int  Q3E_Mouse_DesktopMode(void) { return 0; }
int  Q3E_Mouse_WantsPointerLock(void) { return 0; }
void Q3E_Mouse_Diag(void) { Com_Printf("q3e_mouse: no hardware mouse layer on visionOS\n"); }
void Q3E_Mouse_Cmd(int argc, const char **argv) { (void)argc; (void)argv; Q3E_Mouse_Diag(); }
void Q3E_Mouse_Fake(int argc, const char **argv) { (void)argc; (void)argv; Q3E_Mouse_Diag(); }
#else

void Q3E_Input_FakePointerClick(float nx, float ny, int buttonMask); // ios_input.m
void Q3E_Input_FakeHover(float nx, float ny, int began);           // ios_input.m
int  Q3E_Input_GameControlsHidden(void);                           // ios_input.m

#define NB            5      // MOUSE1..MOUSE5: left, right, middle, aux0, aux1
#define MAXDEV        8
#define LOGN          40
#define GUARD_FRAMES  6      // ~50 ms at 120 Hz, ~100 ms at 60 Hz
#define TAP_DELAY     0.02   // wait this long for evidence against a recovered click
#define TAP_WINDOW    0.03   // another button on the same object this close = catch-up
#define TAP_HOLD      0.05   // recovered click length: spans a frame at any refresh

enum { ROUTE_GAME = 0, ROUTE_MENU = 1, ROUTE_BLOCKED = 2 };
static const char *route_names[3] = { "game", "menu", "blocked" };

static const char *btn_key(int b) {
    static const char *k[NB] = { "MOUSE1", "MOUSE2", "MOUSE3", "MOUSE4", "MOUSE5" };
    if (b == 1 && (q3e_hwfault & Q3E_FAULT_RIGHTASLEFT)) return "MOUSE1";
    return k[b];
}

typedef struct {
    uintptr_t id;
    int  own;                // what THIS object last reported (bit b)
    double edge_t[NB];
    int  fake;
    int  poll;               // fake devices: what a poll would read
    char name[40];
} hwdev_t;

static hwdev_t devs[MAXDEV];
static int ndev;
static int gmask;                     // latest edge per button across every object
static uintptr_t gowner[NB];          // who delivered the latest PRESS
static int eng;                       // buttons this layer holds down in the engine
static int mismatch[NB];
static struct { int state; double t; uintptr_t dev; } taps[NB];
static int route = ROUTE_MENU;
static int scene_active = 1;
static int gc_count = -1;
static int kbd_force = -1;            // q3e_fakemouse kbd: -1 = real
static float wheel_unit = 1.0f;
static float wheel_acc;
static int wheel_dir;
static double wheel_t;
static int wheel_steps, motion_events;
static float move_accx, move_accy;
static __weak UIViewController *host_vc;
static int want_lock_last = -1;
static int lock_unlocked_ticks;
static double lock_next_t;
static int lock_hint_told;

static struct {
    double t;
    unsigned dev;
    char what;     // D U down/up edge, S press suppressed by route, R removed, A added,
                   // G guard release, T/t recovered click down/up, C GCMouse count,
                   // L pointer-lock state, M route change, X release on route change,
                   // W wheel step (b=+1 up / -1 down, v=raw)
    signed char b;
    char before, after;
    int tbl, poll;
    float v;
} hlog[LOGN];
static unsigned hlog_n;

static int polled_mask(void);

static void hlog_add(char what, uintptr_t dev, int b, int before, float v) {
    unsigned k = hlog_n++ % LOGN;
    hlog[k].t = CACurrentMediaTime();
    hlog[k].dev = (unsigned)(dev & 0xffff);
    hlog[k].what = what;
    hlog[k].b = (signed char)b;
    hlog[k].before = (char)before;
    hlog[k].after = (char)((b >= 1 && b <= NB) ? ((eng >> (b - 1)) & 1) : 0);
    hlog[k].tbl = gmask;
    hlog[k].poll = polled_mask();
    hlog[k].v = v;
}

static int real_gcmouse_count(void) { return (int)GCMouse.mice.count; }
static int fake_count(void) {
    int n = 0;
    for (int i = 0; i < ndev; i++) n += devs[i].fake;
    return n;
}

int Q3E_Mouse_Present(void) { return real_gcmouse_count() > 0 || fake_count() > 0; }

int Q3E_Mouse_HwKeyboardPresent(void) {
    if (kbd_force >= 0) return kbd_force;
    return GCKeyboard.coalescedKeyboard != nil;
}

int Q3E_Mouse_DesktopMode(void) { return Q3E_Mouse_Present() && Q3E_Mouse_HwKeyboardPresent(); }

int Q3E_Mouse_WantsPointerLock(void) { return Q3E_Mouse_Present() && route == ROUTE_GAME; }

// What every connected object reports held right now (engine button order).
static int gc_pressed(GCMouse *m) {
    GCMouseInput *in = m.mouseInput;
    if (!in) return 0;
    int held = 0;
    if (in.leftButton.pressed)   held |= 1 << 0;
    if (in.rightButton.pressed)  held |= 1 << 1;
    if (in.middleButton.pressed) held |= 1 << 2;
    NSArray<GCControllerButtonInput *> *aux = in.auxiliaryButtons;
    for (NSUInteger i = 0; i < aux.count && i < 2; i++)
        if (aux[i].pressed) held |= 1 << (3 + i);
    return held;
}

static int polled_mask(void) {
    int held = 0;
    for (GCMouse *m in GCMouse.mice) held |= gc_pressed(m);
    for (int i = 0; i < ndev; i++) if (devs[i].fake) held |= devs[i].poll;
    return held;
}

// The one place a mouse button reaches the engine. A press is refused when the
// route says so (menu left click belongs to the touch path; nothing while
// blocked); a release only ever undoes a press this layer made.
static void eng_key(int b, int down) {
    const int bit = 1 << b;
    if (down) {
        if (eng & bit) return;          // a second object reporting the same press
        if (route == ROUTE_BLOCKED ||
            (route == ROUTE_MENU && b == 0 && !(q3e_hwfault & Q3E_FAULT_NOSUPPRESS))) {
            hlog_add('S', 0, b + 1, 0, 0);
            return;
        }
        eng |= bit;
        Q3E_QueueNamedKey(btn_key(b), 1);
    } else {
        if (!(eng & bit)) return;
        eng &= ~bit;
        Q3E_QueueNamedKey(btn_key(b), 0);
    }
}

static void release_all(char why) {
    for (int b = 0; b < NB; b++) {
        taps[b].state = 0;
        mismatch[b] = 0;
        if (eng & (1 << b)) { eng_key(b, 0); hlog_add(why, 0, b + 1, 1, 0); }
    }
}

static int dev_slot(uintptr_t id, int fake, const char *name) {
    for (int i = 0; i < ndev; i++) if (devs[i].id == id) return i;
    if (ndev == MAXDEV) return -1;
    memset(&devs[ndev], 0, sizeof(devs[ndev]));
    devs[ndev].id = id;
    devs[ndev].fake = fake;
    strlcpy(devs[ndev].name, name ? name : "", sizeof(devs[ndev].name));
    hlog_add('A', id, 0, 0, 0);
    return ndev++;
}

static void hw_button(uintptr_t id, int b, int down, int fake) {
    if (b < 0 || b >= NB) return;
    const int bit = 1 << b;
    const int before = (eng >> b) & 1;
    const int slot = dev_slot(id, fake, NULL);
    const double now = CACurrentMediaTime();
    if (slot < 0) {                       // no row left: stateless pass-through
        eng_key(b, down);
        hlog_add('X', id, b + 1, before, 0);
        return;
    }
    hwdev_t *d = &devs[slot];
    // Another button changing on the same object at the same moment means the
    // object is only catching up with a full report, not clicking.
    for (int o = 0; o < NB; o++)
        if (o != b && taps[o].state == 1 && taps[o].dev == id && now - taps[o].t < TAP_WINDOW)
            taps[o].state = 0;
    if (down) {
        gmask |= bit;
        gowner[b] = id;
        d->own |= bit;
        if (taps[b].state == 1) taps[b].state = 0;   // a real press supersedes it
        eng_key(b, 1);
    } else {
        // The swallowed click: this object still believed the button down (its
        // release went to another object), so it reported nothing for the next
        // press and only this release. Nobody holds the button, yet it just
        // went up: there was a click. Play it back, unless it is a catch-up.
        int lone = 1;
        for (int o = 0; o < NB; o++)
            if (o != b && now - d->edge_t[o] < TAP_WINDOW) lone = 0;
        if ((d->own & bit) && !(gmask & bit) && !(eng & bit) && lone && !taps[b].state &&
            !(q3e_hwfault & Q3E_FAULT_NOTAP)) {
            taps[b].state = 1;
            taps[b].t = now;
            taps[b].dev = id;
        }
        d->own &= ~bit;
        gmask &= ~bit;              // newest edge wins, whichever object pressed
        eng_key(b, 0);
    }
    if (fake) d->poll = d->own;
    d->edge_t[b] = now;
    mismatch[b] = 0;
    hlog_add(down ? 'D' : 'U', id, b + 1, before, 0);
}

static void hw_removed(uintptr_t id) {
    int gone = 0, found = -1;
    for (int i = 0; i < ndev; i++) {
        if (devs[i].id != id) continue;
        found = i;
        break;
    }
    if (found < 0) return;
    devs[found] = devs[--ndev];
    if (!(q3e_hwfault & Q3E_FAULT_NORELEASE)) {
        for (int b = 0; b < NB; b++)
            if ((gmask & (1 << b)) && (gowner[b] == id || ndev == 0))
                gone |= 1 << b;
    }
    gmask &= ~gone;
    hlog_add('R', id, 0, 0, 0);
    for (int b = 0; b < NB; b++) {
        if (!(gone & (1 << b))) continue;
        const int before = (eng >> b) & 1;
        eng_key(b, 0);
        hlog_add('U', id, b + 1, before, 0);
    }
}

static void hw_motion(float dx, float dy) {
    motion_events++;
    if (route != ROUTE_GAME || (q3e_hwfault & Q3E_FAULT_NOMOVE)) {
        move_accx = move_accy = 0;
        return;
    }
    // Raw counts, no acceleration. GameController's deltaY is up-positive; the
    // engine's SE_MOUSE dy is down-positive (screen space), as SDL feeds it.
    move_accx += dx;
    move_accy -= dy;
    const int ix = (int)move_accx, iy = (int)move_accy;
    if (ix || iy) {
        move_accx -= ix; move_accy -= iy;
        Q3E_QueueMouse(ix, iy);
    }
}

// Wheel. GameController reports the scroll pad with the vertical axis inverted
// relative to the usual wheel convention (SDL negates it too): y < 0 is the
// wheel turned AWAY from the player = MWHEELUP (console scrolls back, weapnext
// on a stock config). Quantisation: a notched wheel delivers one isolated event
// per detent, while a trackpad / free-spinning wheel streams small values. So
// the first event after a pause (or a direction change) is always one step,
// and further steps need `wheel_unit` of accumulated travel each. Raw values
// are logged so a paste tells us what this player's hardware sends.
static void hw_scroll(float y) {
    if (y == 0.0f) return;
    if (route == ROUTE_BLOCKED || (q3e_hwfault & Q3E_FAULT_NOWHEEL)) return;
    const float s = -y;                   // + = away from the player = up
    const int dir = s > 0 ? 1 : -1;
    const double now = CACurrentMediaTime();
    int steps;
    if (now - wheel_t > 0.25 || dir != wheel_dir) {
        wheel_dir = dir;                  // a new gesture: one step, whatever its size
        wheel_acc = 0.0f;
        steps = 1;
    } else {
        wheel_acc += fabsf(s);
        steps = (int)(wheel_acc / wheel_unit);
        wheel_acc -= (float)steps * wheel_unit;
    }
    wheel_t = now;
    if (steps > 5) steps = 5;
    const char *key = s > 0 ? "MWHEELUP" : "MWHEELDOWN";
    for (int i = 0; i < steps; i++) {
        Q3E_QueueNamedKey(key, 1);
        Q3E_QueueNamedKey(key, 0);
        wheel_steps++;
        hlog_add('W', 0, s > 0 ? 1 : -1, 0, y);
    }
}

static void attach(GCMouse *m) {
    const uintptr_t id = (uintptr_t)(__bridge void *)m;
    dev_slot(id, 0, (m.vendorName ?: @"").UTF8String);
    GCMouseInput *in = m.mouseInput;
    if (!in) return;
    in.mouseMovedHandler = ^(GCMouseInput *mi, float dx, float dy) { hw_motion(dx, dy); };
    in.leftButton.pressedChangedHandler =
        ^(GCControllerButtonInput *bi, float v, BOOL p) { hw_button(id, 0, p, 0); };
    in.rightButton.pressedChangedHandler =
        ^(GCControllerButtonInput *bi, float v, BOOL p) { hw_button(id, 1, p, 0); };
    in.middleButton.pressedChangedHandler =
        ^(GCControllerButtonInput *bi, float v, BOOL p) { hw_button(id, 2, p, 0); };
    NSArray<GCControllerButtonInput *> *aux = in.auxiliaryButtons;
    for (NSUInteger i = 0; i < aux.count && i < 2; i++) {
        const int b = 3 + (int)i;
        aux[i].pressedChangedHandler =
            ^(GCControllerButtonInput *bi, float v, BOOL p) { hw_button(id, b, p, 0); };
    }
    in.scroll.valueChangedHandler =
        ^(GCControllerDirectionPad *dp, float x, float y) { hw_scroll(y); };
}

static UIWindowScene *host_scene(void) { return host_vc.view.window.windowScene; }

static const char *lock_desc(void) {
    UIWindowScene *ws = host_scene();
    UIPointerLockState *st = ws.pointerLockState;
    return st ? (st.locked ? "LOCKED" : "unlocked") : "unavailable";
}

static void ask_lock_update(void) {
    UIViewController *h = host_vc;
    if (h) [h setNeedsUpdateOfPrefersPointerLocked];
}

void Q3E_Mouse_Start(UIViewController *host) {
    static int started;
    host_vc = host;
    if (started) return;
    started = 1;
    for (GCMouse *m in GCMouse.mice) attach(m);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    NSOperationQueue *mq = NSOperationQueue.mainQueue;
    [nc addObserverForName:GCMouseDidConnectNotification object:nil queue:mq
                usingBlock:^(NSNotification *n) { attach(n.object); }];
    [nc addObserverForName:GCMouseDidDisconnectNotification object:nil queue:mq
                usingBlock:^(NSNotification *n) { hw_removed((uintptr_t)(__bridge void *)n.object); }];
    [nc addObserverForName:UISceneWillDeactivateNotification object:nil queue:mq
                usingBlock:^(NSNotification *n) {
        scene_active = 0;
        route = ROUTE_BLOCKED;
        release_all('X');
    }];
    [nc addObserverForName:UISceneDidActivateNotification object:nil queue:mq
                usingBlock:^(NSNotification *n) {
        scene_active = 1;
        // A lock request made before the scene was active is re-evaluated now.
        ask_lock_update();
    }];
    [nc addObserverForName:UIPointerLockStateDidChangeNotification object:nil queue:mq
                usingBlock:^(NSNotification *n) {
        UIWindowScene *ws = n.userInfo[UIPointerLockStateSceneUserInfoKey];
        UIPointerLockState *st = ws.pointerLockState;
        hlog_add('L', 0, st ? (st.locked ? 1 : 0) : 2, 0, 0);
        NSLog(@"Q3E mouse: pointer lock %s", st ? (st.locked ? "locked" : "unlocked") : "unavailable");
    }];
}

// Wanted-but-unlocked: re-ask about once a second (the first ask can land
// before the scene is active, and iPadOS only grants a full-screen foreground
// scene), and after three refusals tell the player once what iPadOS wants.
// Mouse look keeps working without the lock — GCMouse deltas do not stop at
// the screen edge — the pointer just stays visible.
static void lock_tick(void) {
    const int want = Q3E_Mouse_WantsPointerLock();
    if (want != want_lock_last) {
        want_lock_last = want;
        ask_lock_update();
        lock_unlocked_ticks = 0;
        lock_next_t = CACurrentMediaTime() + 1.0;
    }
    if (!want) return;
    const double now = CACurrentMediaTime();
    if (now < lock_next_t) return;
    lock_next_t = now + 1.0;
    UIPointerLockState *st = host_scene().pointerLockState;
    if (st.locked) { lock_unlocked_ticks = 0; return; }
    ask_lock_update();
    if (++lock_unlocked_ticks >= 3 && !lock_hint_told && real_gcmouse_count() > 0) {
        lock_hint_told = 1;
        Com_Printf("Quake3e: iPadOS did not lock the mouse pointer (%s).\n", lock_desc());
        Com_Printf("Mouse look still works, but for a hidden pointer the app must be FULL SCREEN:\n"
                   "no Stage Manager window, Split View or Slide Over. Type q3e_mouse for details.\n");
    }
}

void Q3E_Mouse_Frame(int menuMode) {
    // Route.
    int r;
    UIViewController *h = host_vc;
    if (!scene_active || h.presentedViewController) r = ROUTE_BLOCKED;
    else r = menuMode ? ROUTE_MENU : ROUTE_GAME;
    if (r != route) {
        hlog_add('M', 0, r, 0, 0);
        route = r;
        release_all('X');
        move_accx = move_accy = 0;
    }

    // Census: objects come and go on their own; a paste shows whether a lost
    // click fell into a gap.
    const int n = real_gcmouse_count();
    if (n != gc_count) {
        if (gc_count >= 0) hlog_add('C', 0, n > 9 ? 9 : n, 0, 0);
        gc_count = n;
    }

    lock_tick();

    // Recovered clicks.
    const double now = CACurrentMediaTime();
    for (int b = 0; b < NB; b++) {
        const int bit = 1 << b;
        if (taps[b].state == 1 && now - taps[b].t >= TAP_DELAY) {
            if (eng & bit) { taps[b].state = 0; continue; }
            eng_key(b, 1);
            taps[b].state = 2;
            taps[b].t = now;
            mismatch[b] = 0;
            hlog_add('T', taps[b].dev, b + 1, 0, 0);
        } else if (taps[b].state == 2 && now - taps[b].t >= TAP_HOLD) {
            taps[b].state = 0;
            if (!(gmask & bit)) {           // a real press arrived meanwhile: it owns the key
                const int before = (eng >> b) & 1;
                eng_key(b, 0);
                hlog_add('t', taps[b].dev, b + 1, before, 0);
            }
        }
    }

    // Guard: a button this layer holds that no object reports pressed (with the
    // table agreeing — a stale object polling "pressed" must not veto it) for
    // several frames is released.
    if (ndev == 0 && n == 0) {
        memset(mismatch, 0, sizeof(mismatch));
        release_all('G');
        return;
    }
    if (q3e_hwfault & Q3E_FAULT_NOGUARD) return;
    const int held = polled_mask();
    for (int b = 0; b < NB; b++) {
        const int bit = 1 << b;
        if (!(eng & bit) || taps[b].state == 2 || ((held & bit) && (gmask & bit))) {
            mismatch[b] = 0;
            continue;
        }
        if (++mismatch[b] < GUARD_FRAMES) continue;
        mismatch[b] = 0;
        gmask &= ~bit;
        eng_key(b, 0);
        hlog_add('G', 0, b + 1, 1, 0);
    }
}

static void print_history(void) {
    const unsigned n = hlog_n < LOGN ? hlog_n : LOGN;
    const double now = CACurrentMediaTime();
    Com_Printf("  history (%u events, oldest first; D/U edge S suppressed T/t recovered click "
               "G guard R removed A added C count L lock M route X released W wheel):\n", hlog_n);
    for (unsigned i = 0; i < n; i++) {
        const unsigned k = (hlog_n - n + i) % LOGN;
        if (hlog[k].what == 'W') {
            Com_Printf("  %8.3fs W %s raw=%.3f\n", hlog[k].t - now, hlog[k].b > 0 ? "up" : "down", hlog[k].v);
        } else if (hlog[k].what == 'M') {
            Com_Printf("  %8.3fs M %s\n", hlog[k].t - now, route_names[hlog[k].b % 3]);
        } else if (hlog[k].what == 'L') {
            Com_Printf("  %8.3fs L %s\n", hlog[k].t - now,
                       hlog[k].b == 1 ? "locked" : (hlog[k].b == 0 ? "unlocked" : "unavailable"));
        } else if (hlog[k].what == 'C') {
            Com_Printf("  %8.3fs C mice=%d\n", hlog[k].t - now, hlog[k].b);
        } else {
            Com_Printf("  %8.3fs %c b%d dev=%04x key %d>%d tbl=%02x poll=%02x\n", hlog[k].t - now,
                       hlog[k].what, hlog[k].b, hlog[k].dev, hlog[k].before, hlog[k].after,
                       hlog[k].tbl, hlog[k].poll);
        }
    }
}

void Q3E_Mouse_Diag(void) {
    UIViewController *h = host_vc;
    UIWindowScene *ws = host_scene();
    CGRect sb = ws.screen.bounds, wb = h.view.window.bounds;
    Com_Printf("q3e_mouse (iOS %s, %s): mice=%d fake=%d hwkeyboard=%d pointerlock=%s "
               "prefersPointerLocked=%d\n",
               UIDevice.currentDevice.systemVersion.UTF8String, UIDevice.currentDevice.model.UTF8String,
               real_gcmouse_count(), fake_count(), Q3E_Mouse_HwKeyboardPresent(), lock_desc(),
               h ? (int)h.prefersPointerLocked : -1);
    Com_Printf("  route=%s menu=%d sheet=%d sceneActive=%d desktop=%d touchControlsHidden=%d "
               "screen=%dx%d window=%dx%d\n",
               route_names[route], route == ROUTE_MENU, h.presentedViewController != nil, scene_active,
               Q3E_Mouse_DesktopMode(), Q3E_Input_GameControlsHidden(),
               (int)sb.size.width, (int)sb.size.height, (int)wb.size.width, (int)wb.size.height);
    for (GCMouse *m in GCMouse.mice) {
        GCMouseInput *in = m.mouseInput;
        const uintptr_t mid = (uintptr_t)(__bridge void *)m;
        Com_Printf("  mouse dev=%04x \"%s\" (%s) L=%d R=%d M=%d aux=%lu%s%s\n",
                   (unsigned)(mid & 0xffffu), (m.vendorName ?: @"?").UTF8String,
                   (m.productCategory ?: @"?").UTF8String, in.leftButton.pressed ? 1 : 0,
                   in.rightButton.pressed ? 1 : 0, in.middleButton.pressed ? 1 : 0,
                   (unsigned long)in.auxiliaryButtons.count,
                   in.auxiliaryButtons.count > 0 && in.auxiliaryButtons[0].pressed ? " aux0" : "",
                   in.auxiliaryButtons.count > 1 && in.auxiliaryButtons[1].pressed ? " aux1" : "");
    }
    for (int i = 0; i < ndev; i++)
        if (devs[i].fake)
            Com_Printf("  fake dev=%04x own=%02x poll=%02x\n", (unsigned)(devs[i].id & 0xffff), devs[i].own, devs[i].poll);
    Com_Printf("  buttons: engine=%02x table=%02x polled=%02x  sent M1=%d M2=%d M3=%d M4=%d M5=%d "
               "WU=%d WD=%d  motion=%d wheelunit=%.2f\n",
               eng, gmask, polled_mask(),
               Q3E_KeyDownCount("MOUSE1"), Q3E_KeyDownCount("MOUSE2"), Q3E_KeyDownCount("MOUSE3"),
               Q3E_KeyDownCount("MOUSE4"), Q3E_KeyDownCount("MOUSE5"),
               Q3E_KeyDownCount("MWHEELUP"), Q3E_KeyDownCount("MWHEELDOWN"), motion_events, wheel_unit);
    print_history();
}

// One machine-readable line for the simulator suite.
static void state_line(void) {
    UIViewController *h = host_vc;
    Com_Printf("MOUSENOW present=%d mice=%d fake=%d kbd=%d desktop=%d route=%s want=%d prefers=%d "
               "lock=%s eng=%02x tbl=%02x hide=%d M1=%d M2=%d M3=%d M4=%d M5=%d WU=%d WD=%d "
               "motion=%d events=%u\n",
               Q3E_Mouse_Present(), real_gcmouse_count(), fake_count(), Q3E_Mouse_HwKeyboardPresent(),
               Q3E_Mouse_DesktopMode(), route_names[route], Q3E_Mouse_WantsPointerLock(),
               h ? (int)h.prefersPointerLocked : -1, lock_desc(), eng, gmask,
               Q3E_Input_GameControlsHidden(),
               Q3E_KeyDownCount("MOUSE1"), Q3E_KeyDownCount("MOUSE2"), Q3E_KeyDownCount("MOUSE3"),
               Q3E_KeyDownCount("MOUSE4"), Q3E_KeyDownCount("MOUSE5"),
               Q3E_KeyDownCount("MWHEELUP"), Q3E_KeyDownCount("MWHEELDOWN"), motion_events, hlog_n);
}

void Q3E_Mouse_Cmd(int argc, const char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "state")) { state_line(); return; }
    if (argc >= 3 && !strcmp(argv[1], "wheelunit")) {
        const float u = (float)atof(argv[2]);
        if (u > 0.001f) wheel_unit = u;
        Com_Printf("q3e_mouse wheelunit %.3f\n", wheel_unit);
        return;
    }
    if (argc >= 2 && !strcmp(argv[1], "history")) { print_history(); return; }
    if (argc > 1) {
        Com_Printf("usage: q3e_mouse [state | history | wheelunit <travel per step>]\n");
        return;
    }
    Q3E_Mouse_Diag();
}

// The simulator cannot present a GCMouse (or any pointer at all), so this
// enters at exactly the internal points the GCMouse handlers call.
// Device ids here are small numbers; real devices are object pointers.
void Q3E_Mouse_Fake(int argc, const char **argv) {
    const char *c = argc >= 2 ? argv[1] : "";
    if (!strcmp(c, "add") && argc >= 3) {
        dev_slot((uintptr_t)atoi(argv[2]), 1, argc >= 4 ? argv[3] : "fake");
    } else if (!strcmp(c, "remove") && argc >= 3) {
        hw_removed((uintptr_t)atoi(argv[2]));
    } else if (!strcmp(c, "clear")) {
        for (int i = ndev - 1; i >= 0; i--) if (devs[i].fake) hw_removed(devs[i].id);
        kbd_force = -1;
    } else if (!strcmp(c, "button") && argc >= 5) {
        hw_button((uintptr_t)atoi(argv[2]), atoi(argv[3]) - 1, atoi(argv[4]) != 0, 1);
    } else if (!strcmp(c, "click") && argc >= 4) {
        hw_button((uintptr_t)atoi(argv[2]), atoi(argv[3]) - 1, 1, 1);
        hw_button((uintptr_t)atoi(argv[2]), atoi(argv[3]) - 1, 0, 1);
    } else if (!strcmp(c, "poll") && argc >= 4) {
        const int s = dev_slot((uintptr_t)atoi(argv[2]), 1, NULL);
        if (s >= 0) devs[s].poll = (int)strtol(argv[3], NULL, 16);
    } else if (!strcmp(c, "move") && argc >= 4) {
        hw_motion((float)atof(argv[2]), (float)atof(argv[3]));
    } else if (!strcmp(c, "scroll") && argc >= 3) {
        hw_scroll((float)atof(argv[2]));
    } else if (!strcmp(c, "kbd") && argc >= 3) {
        kbd_force = atoi(argv[2]);
        if (kbd_force > 1) kbd_force = 1;
    } else if (!strcmp(c, "pointerclick") && argc >= 5) {
        // An indirect-pointer click as the touch layer sees one: nx ny buttonMask
        // (1 = primary, 2 = secondary).
        Q3E_Input_FakePointerClick((float)atof(argv[2]), (float)atof(argv[3]), atoi(argv[4]));
    } else if (!strcmp(c, "hover") && argc >= 4) {
        Q3E_Input_FakeHover((float)atof(argv[2]), (float)atof(argv[3]), argc >= 5 ? atoi(argv[4]) : 0);
    } else {
        Com_Printf("usage: q3e_fakemouse add <dev> [name] | remove <dev> | clear |\n"
                   "  button <dev> <1-5> <0|1> | click <dev> <1-5> | poll <dev> <hexmask> |\n"
                   "  move <dx> <dy-up> | scroll <y> | kbd <0|1|-1> |\n"
                   "  pointerclick <nx> <ny> <buttonMask> | hover <nx> <ny> [began]\n");
        return;
    }
    state_line();
}

#endif // !TARGET_OS_VISION
