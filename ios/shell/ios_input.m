// ios_input.m — touch controls v1 + GCController gamepad.
//
// Touch scheme (q2repro-ios proven design, adapted):
//   * left ~42% of screen: floating move stick — anchor where the finger
//     lands (zero deadzone: the stick's center IS the touch point),
//     response curve 0.4*m + 0.6*m^3, analog via SE_JOYSTICK_AXIS.
//   * elsewhere: look drag — relative deltas as mouse events.
//   * FIRE / JUMP circles bottom-right (claim their touches).
//   * 3-finger tap: ESC (open/close menu).
//   * menu mode (UI/console catcher): taps click — each tap runs a
//     3-tick sequence (corner-reset delta → target delta + button down →
//     button up) because the engine coalesces consecutive same-frame
//     mouse events, making single-shot absolute warps unsafe.
//
// Gamepad (GCController, no SDL). Gameplay: left stick → move axes (same
// curve), right stick → look, A=jump, B=crouch(hold), X=enter/use, RT=fire,
// LT=zoom, LB/RB=weapon prev/next, START=menu, VIEW=scores(TAB),
// L3=toggle-crouch, R3=center view. In menus (whenever a menu/console is up —
// base game AND mods): dpad + left stick = arrow nav (up/down items, left/
// right sliders), A=Enter, B=Esc, X=Space, right stick = cursor + RT = click.
//
// No engine headers here (ObjC 'id' vs engine identifiers) — everything
// engine-facing goes through ios_glue.c shims.

#import "ios_input.h"
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CABase.h>   // CACurrentMediaTime
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#if TARGET_OS_VISION
#import "../shell-visionos/Q3ESense.h"
#import "../shell-visionos/Q3EVR.h"
// The VR gameplay/menu consumer of the merged Sense snapshot (Q3EVRGlue.c). It
// owns context 1 and context 2; the pad layer below owns context 3, and the two
// are mutually exclusive on the mode.
void Q3E_VR_SenseInputFrame(float dt);
// Set by that consumer each frame: 1 when a tracked hand answered and the hands
// therefore own the turn axis this frame.
extern int q3e_vr_sense_drives;
extern int Q3E_VR_ConsumeTurnAxis(float x, float dt);
#endif

// ---- shims (ios_glue.c) ----
void Q3E_QueueMouse(int dx, int dy);
void Q3E_QueueJoyAxis(int axis, int value); // 0=side, 1=forward
void Q3E_QueueNamedKey(const char *name, int down);
void Q3E_QueueChar(int ch);
// (No Q3E_QueueCommand here on purpose: project law is that a pad button
// synthesizes a distinct engine KEY and nothing else — the action always comes
// from a bind, never from a command this layer runs behind the player's back.)
int  Q3E_MenuMode(void); // UI/console catcher active or not in-world
void Com_Printf(const char *fmt, ...) __attribute__((format(printf, 1, 2))); // engine console out
const char *Q3E_CurrentGame(void);

#define PAD_DEADZONE 0.15f

#define MOVE_ZONE_FRAC   0.42f
#define STICK_RADIUS     85.0f
#define NUB_RADIUS       30.0f
#define FIRE_RADIUS      50.0f
#define JUMP_RADIUS      39.0f
#define TAP_SLOP         12.0f
#define LOOK_SENS_DEFAULT 3.5f
#define PAD_LOOK_SPEED  11.0f    // gameplay look gain (was 16 — softened accel)
#define MENU_CURSOR_SPEED 13.0f  // right-stick → UI mouse cursor in menus

static float look_sens_x = LOOK_SENS_DEFAULT;
static float look_sens_y = LOOK_SENS_DEFAULT;
static float ctl_scale = 1.0f;   // control size multiplier
static float ctl_alpha = 1.0f;   // control opacity multiplier
static char uimap_mode = 'c';               // Q3E_UIMAP env: c|p|l

// Cursor-delta multiplier (Q3E_UIDELTA env). Stock 1.32 UI: 1.0.
// Mod UIs may scale deltas themselves — the A51 mod's UI (which once
// hijacked baseq3 via auto-downloaded zzz-*.pk3 and halved deltas)
// needed 2.0. Field-calibrate per UI with the tap telemetry if menus
// ever misbehave again; first suspect: a downloaded pk3 overriding
// the stock ui.qvm.
static float uidelta_mult = 1.0f;

void Q3E_PresentSettings(UIView *fromView); // ios_settings.m

#define WPN_RADIUS       28.0f
// Crouch is deliberately smaller than jump, independent of the rest: it is used
// far less often and does not need jump's target size.
#define CROUCH_RADIUS    30.0f
#define STICK_ZONE_R    150.0f   // move-stick activation zone (editor-draggable)
#define MENU_BTN_RADIUS  24.0f   // ≡ and ⚙
#define MENU_BTN_HIT     34.0f   // ...with a deliberately larger touch target
// Top of the size slider, in both the settings sheet and the layout editor. Also
// the resolution SF Symbol glyphs are rasterized at, so they stay sharp there.
#define CTL_SCALE_MAX     1.6f
#define CTL_SCALE_MIN     0.6f

// A placeable on-screen control. Position is stored as a UNIT fraction of the
// view once the player has customised it; until then the shipped default block
// runs, which keeps the original edge-anchored, scale-aware placement exactly.
@interface Q3EControl : NSObject
@property (nonatomic) CAShapeLayer *layer;
@property (nonatomic, copy) NSString *ident;   // save key — renaming resets that
                                               // control for everyone
@property (nonatomic) CGFloat baseRadius;
@property (nonatomic) CGPoint unit;
@property (nonatomic) BOOL hasSaved;
@property (nonatomic) BOOL zoneOnly;           // move zone: never pressable
@property (nonatomic, copy) CGPoint (^defaultPos)(CGSize sz, CGFloat k);
@end
@implementation Q3EControl @end

static NSString *q3e_pos_key(NSString *ident, const char *axis) {
    return [NSString stringWithFormat:@"q3e_btn_%@_%s", ident, axis];
}
#define DEF_LAYOUT_SET @"q3e_layoutSet"

// Gyro aim: enabled by Q3E_GYRO=<scale> (e.g. 2.0). Landscape-right axis
// mapping/signs are a first guess — tune with hands-on feedback before
// promoting to a default-on setting.
static float gyro_scale = 0.0f;
static CMMotionManager *gyro_mgr;
static float gyro_accx, gyro_accy;
void Q3E_QueueMouse(int dx, int dy);

// Set by the visionOS shell while VR is active. In VR the head already drives
// the camera; feeding head rotation into the aim accumulator as well makes the
// crosshair crawl away on its own with no input at all — the head is moving, and
// the gyro is reporting it. The feed stays exactly as it is for the 2D window
// and the 3D panel, where the head does NOT drive the camera and gyro aim is the
// point. Defined unconditionally so both targets link; only visionOS writes it.
volatile int q3e_gyro_suppressed = 0;

static void gyro_poll(int menuMode, float dt) {
    if (gyro_scale <= 0.0f || !gyro_mgr || menuMode || q3e_gyro_suppressed) return;
    CMDeviceMotion *m = gyro_mgr.deviceMotion;
    if (!m) return;
    // rotationRate is a per-SECOND rate, so scale by real dt (normalized to
    // the 120 Hz reference) — otherwise 120 Hz samples twice as often as
    // 60 Hz and doubles gyro sensitivity.
    const float look_dt = dt * 120.0f;
    const float g = gyro_scale * 8.0f * look_dt;
#if TARGET_OS_VISION
    // Vision Pro headset frame: rotation about device Y ≈ head yaw (screen-
    // horizontal), about device X ≈ head pitch (screen-vertical) — the OPPOSITE
    // pairing from the handheld phone. Verified on-device 2026-07-12: the
    // handheld mapping produced a 90° cross-axis (look left → aim up, look up →
    // aim left). Swap the components so head yaw drives view yaw and head pitch
    // drives view pitch (mirror-aim). Signs kept negative so left→left, up→up.
    gyro_accx += (float)(-m.rotationRate.y) * g;   // yaw
    gyro_accy += (float)(-m.rotationRate.x) * g;   // pitch
#else
    // landscape-right handheld: rotation about device X ≈ screen-vertical (yaw),
    // about device Y ≈ screen-horizontal (pitch); rad/s → mouse counts.
    gyro_accx += (float)(-m.rotationRate.x) * g;
    gyro_accy += (float)(-m.rotationRate.y) * g;
#endif
    int dx = (int)gyro_accx, dy = (int)gyro_accy;
    if (dx || dy) {
        gyro_accx -= dx; gyro_accy -= dy;
        Q3E_QueueMouse(dx, dy);
    }
}

// ---- menu tap sequencer ----
typedef struct {
    int kind; // 0 = reset delta, 1 = target delta + M1 down, 2 = M1 up
    int tx, ty;
} tapstep_t;

#define MAX_TAPSTEPS 64
static tapstep_t tapsteps[MAX_TAPSTEPS];
static int tapstep_head, tapstep_tail;

static void tapstep_push(int kind, int tx, int ty) {
    if (tapstep_head - tapstep_tail >= MAX_TAPSTEPS) return;
    tapsteps[tapstep_head % MAX_TAPSTEPS] = (tapstep_t){kind, tx, ty};
    tapstep_head++;
}

static void tapstep_drain_one(void) {
    if (tapstep_tail >= tapstep_head) return;
    tapstep_t s = tapsteps[tapstep_tail % MAX_TAPSTEPS];
    tapstep_tail++;
    switch (s.kind) {
        case 0: Q3E_QueueMouse(-4000, -4000); break;
        case 1: Q3E_QueueMouse(s.tx, s.ty); Q3E_QueueNamedKey("MOUSE1", 1); break;
        case 2: Q3E_QueueNamedKey("MOUSE1", 0); break;
    }
}

// ---- gamepad ----
static int pad_side, pad_forward;              // last sent axis values
static float pad_lookx, pad_looky;             // sub-pixel accumulators
static int pad_fire, pad_jump, pad_zoom, pad_wprev, pad_wnext, pad_esc, pad_use;
static int pad_crouch, pad_scores;             // gameplay crouch ("c") + scores (TAB)
// Y + d-pad + B + R3: no hardcoded action, they emit AUX1..AUX7 for binding
static int pad_aux1, pad_aux2, pad_aux3, pad_aux4, pad_aux5, pad_aux6, pad_aux7;
static int crouch_toggled;                     // L3 toggle-crouch latch
static int l3_prev;                            // L3 press-edge detect (crouch latch)
// menu-mode controller navigation state (separate from the gameplay button
// states so a mode switch can't leave a key stuck)
static int   menu_dir_x, menu_dir_y;          // discrete nav direction (-1/0/1)
static float menu_rep_x, menu_rep_y;          // auto-repeat countdown (seconds)
static int   menu_btnA, menu_btnB, menu_btnX; // A/B/X held states in menu mode
static float menu_curx, menu_cury;            // right-stick UI-cursor sub-pixel accum
static int   menu_click;                       // RT → MOUSE1 (click) state in menus

static float apply_curve(float m) {
    return 0.4f * m + 0.6f * m * m * m;
}

static void pad_button(int *state, BOOL pressed, const char *key) {
    if (pressed != *state) {
        *state = pressed;
        Q3E_QueueNamedKey(key, pressed);
    }
}

// One discrete menu axis: fire an arrow key on a direction change, then
// auto-repeat while held (initial delay, then a faster cadence). A controller
// gets no OS key-repeat, so the shell supplies it. down+up per step = one
// navigation move (SE_KEY events are queued/processed individually).
static void menu_axis(int dir, int *state, float *rep, float dt,
                      const char *neg, const char *pos) {
    if (dir != *state) {
        *state = dir;
        *rep = 0.40f; // initial delay before the first repeat
        if (dir) { const char *k = dir < 0 ? neg : pos; Q3E_QueueNamedKey(k, 1); Q3E_QueueNamedKey(k, 0); }
    } else if (dir) {
        *rep -= dt;
        if (*rep <= 0.0f) {
            *rep = 0.13f; // repeat cadence
            const char *k = dir < 0 ? neg : pos;
            Q3E_QueueNamedKey(k, 1); Q3E_QueueNamedKey(k, 0);
        }
    }
}

// Release every held pad key and clear edge/repeat state — called on a
// menu<->gameplay transition so nothing sticks and no in-flight press
// re-fires under the other mode's mapping.
static void pad_reset_all(void) {
    pad_button(&pad_fire,  NO, "MOUSE1");
    pad_button(&pad_zoom,  NO, "MOUSE2");
    pad_button(&pad_jump,  NO, "SPACE");
    pad_button(&pad_use,   NO, "ENTER");
    pad_button(&pad_wprev, NO, "[");
    pad_button(&pad_wnext, NO, "]");
    pad_button(&pad_esc,   NO, "ESCAPE");
    pad_button(&pad_crouch, NO, "c");
    pad_button(&pad_scores, NO, "TAB");
    pad_button(&pad_aux1, NO, "AUX1");
    pad_button(&pad_aux2, NO, "AUX2");
    pad_button(&pad_aux3, NO, "AUX3");
    pad_button(&pad_aux4, NO, "AUX4");
    pad_button(&pad_aux5, NO, "AUX5");
    pad_button(&pad_aux6, NO, "AUX6");
    pad_button(&pad_aux7, NO, "AUX7");
    crouch_toggled = 0; l3_prev = 0;
    pad_button(&menu_btnA, NO, "ENTER");
    pad_button(&menu_btnB, NO, "ESCAPE");
    pad_button(&menu_btnX, NO, "SPACE");
    pad_button(&menu_click, NO, "MOUSE1");
    menu_dir_x = menu_dir_y = 0;
    menu_rep_x = menu_rep_y = 0.0f;
    menu_curx = menu_cury = 0.0f;
}

// Radial deadzone with rescale: resting-stick noise (0.05-0.1 on real
// pads) must map to EXACTLY zero — squared-curve drift dragged the UI
// cursor to the (0,0) clamp corner and corrupted menu tap sequences
// (field-reported as taps registering "way north west").
static float pad_deadzone(float v, float m) {
    if (m < PAD_DEADZONE) return 0.0f;
    return v * (m - PAD_DEADZONE) / ((1.0f - PAD_DEADZONE) * m);
}

// ONE PAD SNAPSHOT PER FRAME, from every source that is driving it (charter D5).
//
// The pad used to be read straight out of GCExtendedGamepad and into the button
// states below. It is now assembled into this snapshot first, so a second source
// — the PSVR2 Sense pair in 2D/3D mode — can OR its own contribution in and the
// SINGLE edge detector (pad_button) runs once over the result. Two independent
// blocks would each emit their own key-down/key-up for one press, and one
// source's cleanup would cancel the other's held trigger.
//
// The structural property that matters: a source that stops contributing simply
// loses its bits from the snapshot, and pad_button emits the release for free —
// while a source still holding the key keeps it down. That is what makes a mode
// boundary safe without an explicit release hook.
typedef struct {
    int   have;                 // at least one source answered
    float lx, ly, rx, ry;       // sticks, GameController convention (Y up-positive)
    BOOL  fire, zoom, jump, use, wprev, wnext, esc, scores, crouch, l3, r3;
    BOOL  aux;                  // Y / triangle — no default action, bindable (AUX1)
    BOOL  dpadU, dpadD, dpadL, dpadR;
    BOOL  menuClick;            // the menu-mode click button (RT on a pad)
} q3e_padsnap_t;

// The ordinary gamepad, if there is one. On visionOS a SPATIAL controller is
// skipped: the Sense pair has its own path, and letting it enumerate as "the
// gamepad" would make GCController.controllers.firstObject answer with a device
// that has no extendedGamepad at all — which is how a real pad plugged in
// alongside a Sense pair goes silently dead.
static GCController *pad_pick(void) {
#if TARGET_OS_VISION
    // Unconditionally, not only when a controller is present: the backend's
    // start line is what reports whether the SpatialGamepad declaration survived
    // plist processing into the BUILT product, and the simulator — which has no
    // controllers at all — is the only place that claim can be checked cheaply.
    Q3E_Sense_Start();
    for (GCController *c in GCController.controllers)
        if (!Q3E_Sense_ShouldIgnorePad((__bridge const void *)c))
            return c;
    return nil;
#else
    return GCController.controllers.firstObject;
#endif
}

#if TARGET_OS_VISION
// R4.6 — is an ORDINARY gamepad connected? Answered by the SAME scan that
// decides which device drives the pad, so "the Aiming row is shown" and "the
// stick this row talks about is the one the pad layer reads" cannot come apart:
// a spatial controller is filtered out of both by Q3E_Sense_ShouldIgnorePad, so
// a Sense pair alone never shows the row and never drives this aim.
//
// `q3evrpad 0|1` forces the answer, because the simulator has no controllers at
// all and the row's whole behaviour is its visibility.
int Q3E_VR_PlainPadConnected(void) {
    if (q3e_vrSynthPadConn >= 0)
        return q3e_vrSynthPadConn ? 1 : 0;
    return pad_pick() != nil;
}

// Context 3 (charter D5): outside VR the Sense pair presents as a gamepad, so
// the controllers are never dead in the 2D window or on the 3D panel. It writes
// nothing but the same snapshot fields an ordinary pad writes, so everything
// downstream — the response curve, the deadzone, the sensitivity sliders, the
// menu navigation, the binds — is inherited rather than re-implemented.
//
// The BUTTON MAP IS THE SAME ONE VR USES, deliberately: one layout to learn, and
// one line on a device checklist instead of two.
static void sense_flat_merge(q3e_padsnap_t *s) {
    unsigned btn[2];
    float st[4];
    if (Q3E_GetMode() == Q3E_MODE_VR)
        return;                     // VR owns the pair; its own consumer has it
    if (!Q3E_Sense_UISample(btn, st))
        return;                     // nothing answered: never zero a real pad's axes
    s->have = 1;
    s->lx += st[0];  s->ly += st[1];        // left hand moves
    s->rx += st[2];  s->ry += st[3];        // right hand looks
    if (btn[Q3E_SENSE_RIGHT] & Q3E_SENSE_TRIGGER) s->fire = YES;
    if (btn[Q3E_SENSE_LEFT]  & Q3E_SENSE_TRIGGER) s->zoom = YES;
    if (btn[Q3E_SENSE_RIGHT] & Q3E_SENSE_A)       s->jump = YES;
    if (btn[Q3E_SENSE_RIGHT] & Q3E_SENSE_B)       s->use = YES;
    if (btn[Q3E_SENSE_LEFT]  & Q3E_SENSE_A)       s->wprev = YES;
    if (btn[Q3E_SENSE_LEFT]  & Q3E_SENSE_B)       s->wnext = YES;
    if (btn[Q3E_SENSE_LEFT]  & Q3E_SENSE_GRIP)    s->crouch = YES;
    if (btn[Q3E_SENSE_RIGHT] & Q3E_SENSE_GRIP)    s->scores = YES;
    if ((btn[0] | btn[1]) & Q3E_SENSE_MENU)       s->esc = YES;
    if (btn[Q3E_SENSE_LEFT]  & Q3E_SENSE_STICK)   s->l3 = YES;
    if (btn[Q3E_SENSE_RIGHT] & Q3E_SENSE_STICK)   s->r3 = YES;
    // In menus the right trigger clicks, exactly as it does on a pad.
    if (btn[Q3E_SENSE_RIGHT] & Q3E_SENSE_TRIGGER) s->menuClick = YES;
}
#endif

static void pad_poll(int menuMode, float dt) {
    GCController *pad = pad_pick();
    GCExtendedGamepad *gp = pad ? pad.extendedGamepad : nil;

#if TARGET_OS_VISION
    // The VR turn seam runs whether or not a controller is attached, and BEFORE
    // the no-controller early-out below.
    //
    // It used to sit further down, past that return, which made the entire turn
    // mechanism — and the synthetic injection the suite drives it with — depend
    // on a physical gamepad being paired to the host. On a controllerless
    // simulator it was simply dead code that no test could reach, and the test
    // that appeared to cover it was actually measuring the host's peripherals.
    int vrTurnConsumed = 0;
    int vrPadAimConsumed = 0;
    if (!menuMode) {
        // The Sense pair's own consumer (Q3E_VR_SenseInputFrame) already ran
        // this frame and, if a hand answered, already fed the turn seam its
        // right-stick deflection. Calling it a SECOND time with the pad's stick
        // — which reads 0.0 with no pad attached — would re-arm the snap
        // hysteresis on every frame, so a stick held past the threshold would
        // snap-turn continuously instead of once. Exactly one context feeds this
        // axis, and the pad's own stick is zeroed below when the hands own it.
        if (q3e_vr_sense_drives) {
            vrTurnConsumed = 1;
        } else {
            float trx = 0.0f, try_ = 0.0f;
            if (gp) {
                const float x = gp.rightThumbstick.xAxis.value;
                const float y = gp.rightThumbstick.yAxis.value;
                const float m = sqrtf(x * x + y * y);
                trx = pad_deadzone(x, m);
                try_ = pad_deadzone(y, m);
            }
            // R4.6 — "Aiming: Gamepad". The stick is EITHER the aim or the turn,
            // never both: two consumers of one axis is how a port turns twice as
            // fast as its own settings say (the note below, learned the hard
            // way). The aim seam answers first because it is the mode the player
            // explicitly chose, and since R4.7 it IS the turn — it pushes the
            // stick straight into cl_vr_turn_pending — so turning is not lost by
            // taking this branch, whatever the Turn row says.
            //
            // Same curve and the same sensitivity scaling the flat look path
            // uses below, so a stick that aims in VR feels like the stick that
            // looks everywhere else.
            {
                const float cx = 0.25f * fabsf(trx) + 0.75f * trx * trx;
                const float cy = 0.25f * fabsf(try_) + 0.75f * try_ * try_;
                vrPadAimConsumed =
                    Q3E_VR_ConsumePadAim(copysignf(cx, trx) * (look_sens_x * (1.0f / 3.5f)),
                                         copysignf(cy, try_) * (look_sens_y * (1.0f / 3.5f)),
                                         dt);
            }
            vrTurnConsumed = vrPadAimConsumed ? 1 : Q3E_VR_ConsumeTurnAxis(trx, dt);
        }
    }
#endif

    // ---- the merged snapshot (see q3e_padsnap_t) ----
    q3e_padsnap_t s;
    memset(&s, 0, sizeof(s));
    if (gp) {
        GCExtendedGamepad *g = gp;
        s.have = 1;
        s.lx = g.leftThumbstick.xAxis.value;
        s.ly = g.leftThumbstick.yAxis.value;
        s.rx = g.rightThumbstick.xAxis.value;
        s.ry = g.rightThumbstick.yAxis.value;
        s.fire   = g.rightTrigger.pressed;
        s.zoom   = g.leftTrigger.pressed;
        s.jump   = g.buttonA.pressed;
        s.use    = g.buttonX.pressed;
        s.wprev  = g.leftShoulder.pressed;
        s.wnext  = g.rightShoulder.pressed;
        s.esc    = g.buttonMenu.pressed;
        s.scores = g.buttonOptions.pressed;
        s.crouch = g.buttonB.pressed;
        s.aux    = g.buttonY.pressed;
        s.l3     = g.leftThumbstickButton.pressed;
        s.r3     = g.rightThumbstickButton.pressed;
        s.dpadU  = g.dpad.up.pressed;
        s.dpadD  = g.dpad.down.pressed;
        s.dpadL  = g.dpad.left.pressed;
        s.dpadR  = g.dpad.right.pressed;
        s.menuClick = g.rightTrigger.pressed;
    }
#if TARGET_OS_VISION
    sense_flat_merge(&s);
#endif
    // NO early return on "nothing connected". An all-zero snapshot is exactly
    // what releases whatever a just-disconnected controller left held, and the
    // loops below are a dozen comparisons against nothing.

    // release all held pad keys on a menu<->gameplay switch so nothing sticks
    // and no in-flight press re-fires under the other mode's mapping
    static int pad_was_menu = -1;
    if (menuMode != pad_was_menu) {
        pad_was_menu = menuMode;
        pad_reset_all();
    }

    if (!menuMode) {
        // ---- GAMEPLAY ----
        // left stick → movement axes with the shared response curve
        float lx = s.lx;
        float ly = s.ly;
        float m = sqrtf(lx * lx + ly * ly);
        if (m > 1.0f) { lx /= m; ly /= m; m = 1.0f; }
        lx = pad_deadzone(lx, m);
        ly = pad_deadzone(ly, m);
        m = sqrtf(lx * lx + ly * ly);
        float scale = (m > 0.001f) ? (apply_curve(m) / m) : 0.0f;
        int side = (int)lroundf(127.0f * lx * scale);
        int forward = (int)lroundf(127.0f * ly * scale);
        if (side != pad_side)       { pad_side = side;       Q3E_QueueJoyAxis(0, side); }
        if (forward != pad_forward) { pad_forward = forward; Q3E_QueueJoyAxis(1, forward); }

        // right stick → look deltas (mouse), cubic-accelerated
        float rx = s.rx;
        float ry = s.ry;
        float rm = sqrtf(rx * rx + ry * ry);
        rx = pad_deadzone(rx, rm);
        ry = pad_deadzone(ry, rm);
#if TARGET_OS_VISION
        // Consumed above, before the no-controller early-out. Zero it here so
        // exactly one context emits for this axis — two consumers of one stick is
        // how a port turns twice as fast as its own settings say. Y (pitch) is
        // untouched.
        if (vrTurnConsumed) rx = 0.0f;
        // R4.6: when the stick is AIMING, its Y is spoken for as well — the
        // mouse-look pitch it would otherwise queue is overwritten by the aim
        // write every frame, but it is still an input the player did not ask
        // for, and leaving it in would be a second opinion about the same axis.
        if (vrPadAimConsumed) ry = 0.0f;
#endif
        // dt-normalized to the 120 Hz reference so the 60 Hz refresh setting
        // doesn't change turn rate. Response is a linear+quadratic blend (was
        // pure |v|·v) so the slow->fast transition is gentler while small-stick
        // aim stays precise; gain trimmed to match (PAD_LOOK_SPEED).
        const float look_dt = dt * 120.0f;
        float cx = 0.25f * fabsf(rx) + 0.75f * rx * rx;
        float cy = 0.25f * fabsf(ry) + 0.75f * ry * ry;
        // The settings Look-sensitivity sliders scale pad look too (they were
        // touch-only — the pad silently ignored them). Slider 3.5 (the default)
        // = the tuned PAD_LOOK_SPEED baseline, so the 0.5–8 range spans
        // ~0.14x–2.3x of the original gain, per axis.
        const float pad_sx = look_sens_x * (1.0f / 3.5f);
        const float pad_sy = look_sens_y * (1.0f / 3.5f);
        pad_lookx += copysignf(cx, rx) * PAD_LOOK_SPEED * pad_sx * look_dt;
        pad_looky += -copysignf(cy, ry) * PAD_LOOK_SPEED * pad_sy * look_dt;
        int dx = (int)pad_lookx, dy = (int)pad_looky;
        if (dx || dy) {
            pad_lookx -= dx; pad_looky -= dy;
            Q3E_QueueMouse(dx, dy);
        }

        // gameplay buttons
        pad_button(&pad_fire, s.fire, "MOUSE1");
        pad_button(&pad_zoom, s.zoom, "MOUSE2");
        pad_button(&pad_jump, s.jump, "SPACE");
        pad_button(&pad_use,  s.use, "ENTER");
        pad_button(&pad_wprev, s.wprev, "[");
        pad_button(&pad_wnext, s.wnext, "]");
        pad_button(&pad_esc,  s.esc, "ESCAPE"); // START opens the menu
        pad_button(&pad_scores, s.scores, "TAB"); // VIEW = show scores

        // L3 = TOGGLE crouch (latched), and it alone holds "c" (+movedown) now.
        // B used to be OR-ed in here; it is a bindable key (AUX6) since it left
        // this line, seeded to +movedown by the boot migration so a player who
        // never opens the console still gets hold-to-crouch on B.
        BOOL l3 = s.l3;
        if (l3 && !l3_prev) crouch_toggled = !crouch_toggled;
        l3_prev = l3;
        pad_button(&pad_crouch, crouch_toggled, "c");

        // Y and the d-pad carry NO built-in action: they emit the engine's
        // AUX1..AUX5 key names so the player can `bind` them to anything (mod
        // commands — Urban Terror's stance/weapon menus — voice chat, gestures).
        // Gameplay only: in menus the d-pad is the arrow-key navigation below,
        // which is also why the in-game bindings screen cannot capture them.
        pad_button(&pad_aux1, s.aux,   "AUX1");
        pad_button(&pad_aux2, s.dpadU, "AUX2");
        pad_button(&pad_aux3, s.dpadD, "AUX3");
        pad_button(&pad_aux4, s.dpadL, "AUX4");
        pad_button(&pad_aux5, s.dpadR, "AUX5");

        // B and R3 are bindable too, so a player can reproduce a PC layout
        // exactly. Their old hardcoded behaviour survives as a DEFAULT BIND
        // seeded once by the boot migration (AUX6 = +movedown, AUX7 =
        // centerview) — rebinding either simply overwrites it.
        pad_button(&pad_aux6, s.crouch, "AUX6");
        pad_button(&pad_aux7, s.r3,     "AUX7");
    } else {
        // ---- MENU NAVIGATION (only while a menu / console is up) ----
        // no player movement in menus — zero the move axes (the left stick
        // drives item nav below; the right stick drives the UI cursor)
        if (pad_side || pad_forward) {
            pad_side = pad_forward = 0;
            Q3E_QueueJoyAxis(0, 0);
            Q3E_QueueJoyAxis(1, 0);
        }
        pad_lookx = pad_looky = 0;

        // dpad + left stick → arrow keys: up/down move between items,
        // left/right adjust sliders and spin-controls (the horizontal menus).
        int dirY = s.dpadU ? -1 : s.dpadD ?  1 :
                   (s.ly >  0.5f ? -1 : s.ly < -0.5f ?  1 : 0);
        int dirX = s.dpadL ? -1 : s.dpadR ?  1 :
                   (s.lx < -0.5f ? -1 : s.lx >  0.5f ?  1 : 0);
        menu_axis(dirY, &menu_dir_y, &menu_rep_y, dt, "UPARROW", "DOWNARROW");
        menu_axis(dirX, &menu_dir_x, &menu_rep_x, dt, "LEFTARROW", "RIGHTARROW");

        // face buttons: A = Enter (activate), B = Esc (back / close), X = Space.
        // START stays unmapped in-menu — it opens the menu from gameplay, and
        // mapping it here would toggle the menu shut on the same press; B closes.
        pad_button(&menu_btnA, s.jump, "ENTER");
        pad_button(&menu_btnB, s.crouch, "ESCAPE");
        pad_button(&menu_btnX, s.use, "SPACE");

        // right stick → move the UI mouse cursor, RT = click. This reaches
        // mouse-only widgets the arrow keys can't — notably the server
        // browser's FIGHT button (the stock Q3 list joins on FIGHT / a
        // double-click, not on Enter). Complements the arrow-key nav above.
        float rx = s.rx;
        float ry = s.ry;
        float rm = sqrtf(rx * rx + ry * ry);
        rx = pad_deadzone(rx, rm);
        ry = pad_deadzone(ry, rm);
        const float cur_dt = dt * 120.0f;
        menu_curx += rx * fabsf(rx) * MENU_CURSOR_SPEED * cur_dt;
        menu_cury += -ry * fabsf(ry) * MENU_CURSOR_SPEED * cur_dt;
        int cdx = (int)menu_curx, cdy = (int)menu_cury;
        if (cdx || cdy) { menu_curx -= cdx; menu_cury -= cdy; Q3E_QueueMouse(cdx, cdy); }
        pad_button(&menu_click, s.menuClick, "MOUSE1");
    }
}

#if TARGET_OS_VISION
// ---------------------------------------------------------------------------
// The Sense pair in VR — contexts 1 and 2 of charter D5.
//
// It lives HERE, next to the pad layer, and not in the engine-side glue, because
// everything it needs already exists here and having a second copy of any of it
// is how two input paths drift: the response curve, the radial deadzone, the
// edge detector (pad_button) and the menu auto-repeat (menu_axis) are the SAME
// ones an ordinary gamepad goes through. What it does NOT share is the held
// state: contexts 1/2 and context 3 are mutually exclusive on the mode, and one
// context's release must never cancel the other's hold.
//
// THE PARTITION, stated so it can be checked: this function returns immediately
// unless the mode is VR; the flat merge (sense_flat_merge) returns immediately
// unless it is not. Exactly one of them emits for a given input at a given
// moment, and the button LAYOUT is identical either way.
//
// The BINDS are the shipped key names, not a private table: MOUSE1/SPACE/ENTER/
// [ / ] / c / TAB / ESCAPE go through Q3E_QueueNamedKey exactly as the pad's do,
// so every one of them follows whatever the player has bound in Quake's own
// bind system. There is no new bind machinery to learn or to break.
int q3e_vr_sense_drives = 0;

static int vr_fire, vr_zoom, vr_jump, vr_use, vr_wprev, vr_wnext;
static int vr_crouch, vr_scores, vr_esc;
static int vr_crouch_toggled;
static int vr_side, vr_forward;
static int vr_menu_dir_x, vr_menu_dir_y;
static float vr_menu_rep_x, vr_menu_rep_y;
static int vr_ctx = -1;            // -1 = not ours, 0 = gameplay, 1 = menu/console
// One-shots emitted by the MENU context, counted so the partition rule is a
// number rather than an inspection: exactly one context may emit for a given
// input at a given moment, and a gameplay trigger that also opened a menu item
// would show up here as a count that moved when it should not have.
static int vr_ui_enter, vr_ui_esc;
// Fault injection (`q3evrhandctx 0`): make the context boundary do NOTHING —
// no release of what is held, no rebase of the edge detector. That is the
// donor's own bug #25 reproduced deliberately, and it is what proves the
// assertion "a button held across a context switch does not stick" is testing
// something rather than describing code nobody has watched fail.
int q3e_vr_sense_ctx_handoff = 1;

// What this consumer is holding right now, for HANDNOW. Publishing the held
// state is what turns "no key sticks across a context switch" from something
// read in the code into something a suite can watch fail.
void Q3E_VR_SenseHeldString(char *buf, int n) {
    snprintf(buf, (size_t)n,
             "ctx=%s held=(fire%d,zoom%d,jump%d,use%d,wprev%d,wnext%d,crouch%d,scores%d,esc%d) "
             "crouchtoggle=%d move=(%d,%d) uienter=%d uiesc=%d drives=%d handoff=%d",
             (vr_ctx < 0) ? "none" : (vr_ctx ? "menu" : "play"),
             vr_fire, vr_zoom, vr_jump, vr_use, vr_wprev, vr_wnext,
             vr_crouch, vr_scores, vr_esc, vr_crouch_toggled,
             vr_side, vr_forward, vr_ui_enter, vr_ui_esc, q3e_vr_sense_drives,
             q3e_vr_sense_ctx_handoff);
}

void Q3E_VR_SenseReleaseHeld(void) {
    pad_button(&vr_fire,   NO, "MOUSE1");
    pad_button(&vr_zoom,   NO, "MOUSE2");
    pad_button(&vr_jump,   NO, "SPACE");
    pad_button(&vr_use,    NO, "ENTER");
    pad_button(&vr_wprev,  NO, "[");
    pad_button(&vr_wnext,  NO, "]");
    pad_button(&vr_crouch, NO, "c");
    pad_button(&vr_scores, NO, "TAB");
    pad_button(&vr_esc,    NO, "ESCAPE");
    if (vr_side || vr_forward) {
        vr_side = vr_forward = 0;
        Q3E_QueueJoyAxis(0, 0);
        Q3E_QueueJoyAxis(1, 0);
    }
    vr_crouch_toggled = 0;
    vr_menu_dir_x = vr_menu_dir_y = 0;
    vr_menu_rep_x = vr_menu_rep_y = 0.0f;
}

void Q3E_VR_SenseInputFrame(float dt) {
    unsigned down[2], up[2], level[2];
    float stick[4];
    int hands, ctx, aim, off;

    q3e_vr_sense_drives = 0;

    if (Q3E_GetMode() != Q3E_MODE_VR) {
        // Context 3 has the pair now. Drop everything this consumer was holding
        // so no key crosses the boundary latched, and forget the pending edges
        // so the far side does not read a held button as a fresh press.
        if (vr_ctx != -1) {
            if (q3e_vr_sense_ctx_handoff) {
                Q3E_VR_SenseReleaseHeld();
                Q3E_Sense_RebaseEdges();
            }
            vr_ctx = -1;
        }
        return;
    }

    ctx = Q3E_MenuMode() ? 1 : 0;
    if (ctx != vr_ctx) {
        // Same discipline at the gameplay <-> menu boundary. RebaseEdges keeps
        // whatever is physically held as the new baseline, so a trigger held
        // through the transition neither fires ENTER on the menu side nor emits
        // a release nobody made.
        if (q3e_vr_sense_ctx_handoff) {
            Q3E_VR_SenseReleaseHeld();
            Q3E_Sense_RebaseEdges();
        }
        vr_ctx = ctx;
    }

    hands = Q3E_Sense_TakeEdges(down, up, level, stick);
    if (hands <= 0) {
        // Release-on-doff: both controllers gone (or the headset off, which
        // stops the poll that feeds them). Everything held goes with them —
        // never leave a doffed player firing.
        Q3E_VR_SenseReleaseHeld();
        return;
    }
    q3e_vr_sense_drives = 1;

    aim = (q3e_vrAimHand == Q3E_VR_HAND_LEFT) ? Q3E_SENSE_LEFT : Q3E_SENSE_RIGHT;
    off = aim ^ 1;

    if (ctx == 0) {
        // ---- VR GAMEPLAY ----
        // The OFF hand moves and the AIM hand turns, so a left-handed player who
        // switches the Aim Hand row gets a layout that mirrors rather than one
        // that fights them.
        float lx = stick[off * 2 + 0], ly = stick[off * 2 + 1], m, scale;
        int side, forward;
        m = sqrtf(lx * lx + ly * ly);
        if (m > 1.0f) { lx /= m; ly /= m; m = 1.0f; }
        lx = pad_deadzone(lx, m);
        ly = pad_deadzone(ly, m);
        m = sqrtf(lx * lx + ly * ly);
        scale = (m > 0.001f) ? (apply_curve(m) / m) : 0.0f;
        side = (int)lroundf(127.0f * lx * scale);
        forward = (int)lroundf(127.0f * ly * scale);
        if (side != vr_side)       { vr_side = side;       Q3E_QueueJoyAxis(0, side); }
        if (forward != vr_forward) { vr_forward = forward; Q3E_QueueJoyAxis(1, forward); }

        // The aim hand's X is the TURN, through the one seam that owns snap and
        // smooth (Q3E_VR_ConsumeTurnAxis). Y is deliberately unused: pitch comes
        // from where the hand is pointing, and a stick that also pitched would be
        // two aim sources for one axis.
        {
            const float tx = stick[aim * 2 + 0];
            Q3E_VR_ConsumeTurnAxis(pad_deadzone(tx, fabsf(tx)), dt);
        }

        pad_button(&vr_fire,  (level[aim] & Q3E_SENSE_TRIGGER) != 0, "MOUSE1");
        pad_button(&vr_zoom,  (level[off] & Q3E_SENSE_TRIGGER) != 0, "MOUSE2");
        pad_button(&vr_jump,  (level[aim] & Q3E_SENSE_A) != 0, "SPACE");
        pad_button(&vr_use,   (level[aim] & Q3E_SENSE_B) != 0, "ENTER");
        pad_button(&vr_wprev, (level[off] & Q3E_SENSE_A) != 0, "[");
        pad_button(&vr_wnext, (level[off] & Q3E_SENSE_B) != 0, "]");
        pad_button(&vr_scores,(level[aim] & Q3E_SENSE_GRIP) != 0, "TAB");
        pad_button(&vr_esc,   ((level[0] | level[1]) & Q3E_SENSE_MENU) != 0, "ESCAPE");

        // Off-hand stick click TOGGLES crouch; the off grip HOLDS it. "c"
        // (+movedown) is down if either is active, so the two never fight.
        if (down[off] & Q3E_SENSE_STICK)
            vr_crouch_toggled = !vr_crouch_toggled;
        pad_button(&vr_crouch, ((level[off] & Q3E_SENSE_GRIP) || vr_crouch_toggled) != 0, "c");

        // Aim-hand stick click recentres the VR view — the one action that has no
        // flat equivalent, on the one button flat mode gives to something
        // standard instead.
        if (down[aim] & Q3E_SENSE_STICK)
            Q3E_VR_Recenter();

        // Haptics: a transient tap the instant the shot leaves, on the hand that
        // fired. The trigger EDGE, not the level — a held trigger buzzing at
        // frame rate is what the throttle in the log exists to catch.
        if (down[aim] & Q3E_SENSE_TRIGGER)
            Q3E_VR_Haptic(aim, 0.7f, 0.035f, "fire");
    } else {
        // ---- VR MENUS / CONSOLE (context 2) ----
        // Q3 has no blocking modal pumps, so a per-frame pump is sufficient.
        // Movement stops dead here: the sticks navigate.
        int dirX, dirY;
        float lx, ly;
        if (vr_side || vr_forward) {
            vr_side = vr_forward = 0;
            Q3E_QueueJoyAxis(0, 0);
            Q3E_QueueJoyAxis(1, 0);
        }
        // Either hand navigates: summed, then thresholded, so a player holding
        // one controller can still drive the whole menu.
        lx = stick[0] + stick[2];
        ly = stick[1] + stick[3];
        dirY = (ly >  0.5f) ? -1 : (ly < -0.5f) ?  1 : 0;
        dirX = (lx < -0.5f) ? -1 : (lx >  0.5f) ?  1 : 0;
        menu_axis(dirY, &vr_menu_dir_y, &vr_menu_rep_y, dt, "UPARROW", "DOWNARROW");
        menu_axis(dirX, &vr_menu_dir_x, &vr_menu_rep_x, dt, "LEFTARROW", "RIGHTARROW");

        // Buttons are ONE-SHOT here, off the edge rather than the level: a menu
        // press is an event, and holding A must not re-activate an item sixty
        // times a second. Hand-agnostic — a menu does not care which hand.
        if ((down[0] | down[1]) & (Q3E_SENSE_TRIGGER | Q3E_SENSE_A)) {
            Q3E_QueueNamedKey("ENTER", 1);
            Q3E_QueueNamedKey("ENTER", 0);
            vr_ui_enter++;
        }
        if ((down[0] | down[1]) & (Q3E_SENSE_B | Q3E_SENSE_MENU)) {
            Q3E_QueueNamedKey("ESCAPE", 1);
            Q3E_QueueNamedKey("ESCAPE", 0);
            vr_ui_esc++;
        }
    }
    (void)up;
}
#endif // TARGET_OS_VISION

void Q3E_Input_Frame(void) {
    // real per-callback dt (seconds) for frame-rate-independent look accel
    static double lastT = 0.0;
    double now = CACurrentMediaTime();
    float dt = (lastT > 0.0) ? (float)(now - lastT) : (1.0f / 120.0f);
    lastT = now;
    if (dt <= 0.0f || dt > 0.1f) dt = 1.0f / 120.0f; // first-frame / hitch clamp

    const int menuMode = Q3E_MenuMode();
    tapstep_drain_one();
#if TARGET_OS_VISION
    // BEFORE the pad layer, always: it is the consumer that owns the turn seam
    // while the hands are driving, and pad_poll asks whether that happened.
    Q3E_VR_SenseInputFrame(dt);
#endif
    pad_poll(menuMode, dt);
    gyro_poll(menuMode, dt);
}

// Layout editor entry points (settings sheet calls these; the env var opens it
// at launch so the simulator can screenshot it without a finger).
@interface Q3EInputView (LayoutEditor)
- (void)beginEditingLayout;
- (void)endEditingLayout;
- (BOOL)isEditingLayout;
- (void)fakeTouchAt:(CGPoint)nrm phase:(int)phase;
- (void)printLayout;
@end

static __weak Q3EInputView *q3e_input_view = nil;
void Q3E_Input_BeginLayoutEdit(void) {
    [q3e_input_view beginEditingLayout];
}

void Q3E_Input_ToggleLayoutEdit(void) {
    Q3EInputView *v = q3e_input_view;
    if (!v) return;
    if ([v isEditingLayout]) [v endEditingLayout]; else [v beginEditingLayout];
}

// Synthetic finger for the layout editor — drives the SAME drag path the real
// touch handlers use, not a parallel copy.
void Q3E_Input_FakeTouch(float nx, float ny, int phase) {
    [q3e_input_view fakeTouchAt:CGPointMake(nx, ny) phase:phase];
}

void Q3E_Input_PrintLayout(void) {
    [q3e_input_view printLayout];
}

// live setters driven by the iOS settings sheet
void Q3E_Input_SetTouchSens(float sx, float sy) {
    look_sens_x = sx;
    look_sens_y = sy;
}

static int fire_haptics = 0;
#if !TARGET_OS_VISION
static UIImpactFeedbackGenerator *fire_haptic_gen = nil;   // no touch haptics on visionOS
#endif
void Q3E_Input_SetFireHaptics(int on) {
    fire_haptics = on;
#if !TARGET_OS_VISION
    if (on && !fire_haptic_gen) {
        fire_haptic_gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [fire_haptic_gen prepare];
    }
#endif
}

// Clamped at every entry point. The scale is now a divisor (lineWidth = 2/k) and
// a transform factor, so a zero — from a corrupt default, or an older build's
// value — would mean invisible AND untappable controls with no way back.
static float q3e_clamp_scale(float s) {
    if (!(s > 0.0f)) return 1.0f;   // catches 0 and NaN
    return s < CTL_SCALE_MIN ? CTL_SCALE_MIN : (s > CTL_SCALE_MAX ? CTL_SCALE_MAX : s);
}

void Q3E_Input_SetControlStyle(float scale, float alpha) {
    ctl_scale = q3e_clamp_scale(scale);
    ctl_alpha = alpha;
    [NSNotificationCenter.defaultCenter postNotificationName:@"Q3EControlStyleChanged" object:nil];
}

void Q3E_Input_SetGyro(int enabled, float scale) {
    if (enabled) {
        gyro_scale = scale;
        if (!gyro_mgr) {
            gyro_mgr = [[CMMotionManager alloc] init];
            gyro_mgr.deviceMotionUpdateInterval = 1.0 / 120.0;
        }
        if (!gyro_mgr.deviceMotionActive) {
            [gyro_mgr startDeviceMotionUpdates];
        }
    } else {
        gyro_scale = 0.0f;
        if (gyro_mgr && gyro_mgr.deviceMotionActive) {
            [gyro_mgr stopDeviceMotionUpdates];
        }
    }
}

// ---- the view ----

// ---- hardware keyboard ------------------------------------------------------
// visionOS delivers a paired keyboard (including the Mac Virtual Display's) as
// UIPress events with a UIKey — but ONLY to the responder chain, and only when
// something in it is first responder. The engine wants two independent streams
// out of that, exactly as SDL feeds it on desktop: SE_KEY down/up for binds and
// menu navigation, SE_CHAR for text. -insertText: supplies the characters (it is
// what both a hardware keystroke and a virtual-keyboard tap arrive as), the
// press handler below supplies the key events; a printable key legitimately
// produces one of each, and the engine's text fields consume only the char.

typedef struct {
    UIKeyboardHIDUsage code;
    const char *name;           // engine keyname (Key_StringToKeynum)
} q3e_keymap_t;

// Only the keys whose engine name is NOT simply the character they type.
static const q3e_keymap_t q3e_keymap[] = {
    { UIKeyboardHIDUsageKeyboardReturnOrEnter, "ENTER" },
    { UIKeyboardHIDUsageKeypadEnter,           "ENTER" },
    { UIKeyboardHIDUsageKeyboardEscape,        "ESCAPE" },
    { UIKeyboardHIDUsageKeyboardDeleteOrBackspace, "BACKSPACE" },
    { UIKeyboardHIDUsageKeyboardDeleteForward, "DEL" },
    { UIKeyboardHIDUsageKeyboardTab,           "TAB" },
    { UIKeyboardHIDUsageKeyboardSpacebar,      "SPACE" },
    { UIKeyboardHIDUsageKeyboardUpArrow,       "UPARROW" },
    { UIKeyboardHIDUsageKeyboardDownArrow,     "DOWNARROW" },
    { UIKeyboardHIDUsageKeyboardLeftArrow,     "LEFTARROW" },
    { UIKeyboardHIDUsageKeyboardRightArrow,    "RIGHTARROW" },
    { UIKeyboardHIDUsageKeyboardInsert,        "INS" },
    { UIKeyboardHIDUsageKeyboardHome,          "HOME" },
    { UIKeyboardHIDUsageKeyboardEnd,           "END" },
    { UIKeyboardHIDUsageKeyboardPageUp,        "PGUP" },
    { UIKeyboardHIDUsageKeyboardPageDown,      "PGDN" },
    { UIKeyboardHIDUsageKeyboardCapsLock,      "CAPSLOCK" },
    { UIKeyboardHIDUsageKeyboardLeftShift,     "SHIFT" },
    { UIKeyboardHIDUsageKeyboardRightShift,    "SHIFT" },
    { UIKeyboardHIDUsageKeyboardLeftControl,   "CTRL" },
    { UIKeyboardHIDUsageKeyboardRightControl,  "CTRL" },
    { UIKeyboardHIDUsageKeyboardLeftAlt,       "ALT" },
    { UIKeyboardHIDUsageKeyboardRightAlt,      "ALT" },
    { UIKeyboardHIDUsageKeyboardLeftGUI,       "COMMAND" },
    { UIKeyboardHIDUsageKeyboardRightGUI,      "COMMAND" },
    { UIKeyboardHIDUsageKeyboardSemicolon,     "SEMICOLON" },
    // ` opens the console on desktop and has no bindable name of its own.
    { UIKeyboardHIDUsageKeyboardGraveAccentAndTilde, "CONSOLE" },
    { UIKeyboardHIDUsageKeyboardF1,  "F1" },  { UIKeyboardHIDUsageKeyboardF2,  "F2" },
    { UIKeyboardHIDUsageKeyboardF3,  "F3" },  { UIKeyboardHIDUsageKeyboardF4,  "F4" },
    { UIKeyboardHIDUsageKeyboardF5,  "F5" },  { UIKeyboardHIDUsageKeyboardF6,  "F6" },
    { UIKeyboardHIDUsageKeyboardF7,  "F7" },  { UIKeyboardHIDUsageKeyboardF8,  "F8" },
    { UIKeyboardHIDUsageKeyboardF9,  "F9" },  { UIKeyboardHIDUsageKeyboardF10, "F10" },
    { UIKeyboardHIDUsageKeyboardF11, "F11" }, { UIKeyboardHIDUsageKeyboardF12, "F12" },
};

// 0 = auto (follow the engine), 1 = forced on, 2 = forced off (fault injection:
// with the responder held down the virtual keyboard can never appear and typed
// characters can never reach a field, which is what makes the green case mean
// something).
static int  kbd_mode = 0;
static BOOL kbd_textMode = NO;        // the system keyboard is the input view
static BOOL kbd_responder = NO;       // the view holds first responder
static int  kbd_keyEvents = 0;        // SE_KEY pairs queued from the key path
static int  kbd_charEvents = 0;       // SE_CHAR events queued from the text path
static char kbd_last[64] = "none";    // last routed key/char, human readable
static int  kbd_seq = 0;              // monotone: a dump is fresh or it is stale
// Dismiss has to STICK. The auto-summon is a 4 Hz poll of an engine-side hint
// that stays true for as long as the field keeps painting its cursor — so
// without this, tapping "Dismiss ⌨" bought a quarter of a second before the
// same focus raised the keyboard again. The flag says "this focus already had
// its keyboard and the user closed it".
//
// What re-arms it is a TOUCH in the game view, not a change of engine state:
// both the focus hint and the key catcher stay constant across a whole menu
// screen, so "the focus went away" is invisible to the poll — with only that
// test, dismissing on one field left every other field on the same menu unable
// to raise the keyboard until the user backed out of the menu entirely. A tap
// is the honest signal: land it on nothing and the field defocuses, the hint
// goes stale within a frame and the poll leaves the keyboard down; land it on a
// field (the same one or another) and the hint refreshes and the keyboard comes
// back. That is exactly the "click off and back on" the UX asks for.
static BOOL kbd_dismissed = NO;
static int  kbd_lastCatcher = 0;

int  Q3E_TextInputWanted(void);       // ios_glue.c
int  Q3E_KeyCatcher(void);            // ios_glue.c

static const char *q3e_keyname_for(UIKeyboardHIDUsage code, NSString *chars,
                                   char *buf, size_t buflen) {
    for (size_t i = 0; i < sizeof(q3e_keymap) / sizeof(q3e_keymap[0]); i++) {
        if (q3e_keymap[i].code == code) return q3e_keymap[i].name;
    }
    if (chars.length >= 1) {
        unichar c = [chars characterAtIndex:0];
        if (c >= 32 && c < 127) {
            // The engine's keynames are the UNSHIFTED characters; a keyboard that
            // reports the shifted glyph would otherwise miss its own binds.
            if (c >= 'A' && c <= 'Z') c = (unichar)(c - 'A' + 'a');
            if (c == ' ') return "SPACE";
            if (c == ';') return "SEMICOLON";
            buf[0] = (char)c; buf[1] = '\0';
            return buf;
        }
    }
    return NULL;
}

@interface Q3EInputView () <UIKeyInput>
@end

@implementation Q3EInputView {
    UITouch *_moveTouch, *_lookTouch, *_fireTouch, *_jumpTouch, *_crouchTouch;
    UITouch *_menuBtnTouch, *_gearBtnTouch;
    CGPoint _lookPredicted;
    BOOL _lookHavePrediction;
    float _lookAccX, _lookAccY;
    NSMutableSet<UITouch *> *_oneShotTouches;
    CGPoint _moveAnchor, _lookLast;
    CGPoint _tapStart;
    CAShapeLayer *_stickBase, *_stickNub, *_fireCircle, *_jumpCircle;
    CAShapeLayer *_wnextCircle, *_wprevCircle, *_crouchCircle, *_menuButton, *_gearButton;
    CAShapeLayer *_stickZone;                   // drawn only while editing
    NSMutableArray<Q3EControl *> *_controls;
    BOOL _editing;
    Q3EControl *_dragCtl;
    CGSize _dragOffset;
    UIView *_editBar;
    UISlider *_editSlider;
    UILabel *_editPct;
    NSTimer *_modeTimer;
    BOOL _menuMode;
    BOOL _padConnected;
    UIToolbar *_kbToolbar;
    UIView *_kbSuppressView;   // zero-size stand-in input view: first responder, no keyboard
}

+ (Class)layerClass { return [CAMetalLayer class]; }

// ---- keyboard (UIKeyInput) ----
// The view is first responder WHENEVER it can be, because that is the only way
// hardware key events reach the app at all — but first responder normally means
// a keyboard on screen, which is wrong for 99% of a game. So the input view is
// a zero-size stand-in until the engine actually wants text, at which point it
// becomes nil (= the system keyboard) and -reloadInputViews raises it. That is
// what turns "the menu cursor moved onto the player-name field" into a keyboard
// on visionOS, with no tap-a-button ritual.
// The view slides up by the keyboard height so the typed line stays visible;
// the accessory bar's Dismiss button is the reliable close path. Keys feed the
// engine as SE_CHAR/SE_KEY events.

- (BOOL)canBecomeFirstResponder { return YES; }

- (UIView *)inputView {
    if (kbd_textMode) return nil;      // the system keyboard
    if (!_kbSuppressView) {
        _kbSuppressView = [[UIView alloc] initWithFrame:CGRectZero];
        _kbSuppressView.backgroundColor = UIColor.clearColor;
    }
    return _kbSuppressView;            // first responder, nothing on screen
}

// Follow the engine's text-entry state. Called from the 4 Hz mode timer — a
// person moving a menu cursor cannot outrun 250 ms, and polling keeps the whole
// mechanism on one thread with no engine callback into UIKit.
- (void)syncKeyboard {
    BOOL want;
    if (kbd_mode == 1)      want = YES;
    else if (kbd_mode == 2) want = NO;
    else                    want = Q3E_TextInputWanted() != 0;

#if !TARGET_OS_VISION
    // Dismiss sticks for the life of ONE focus. visionOS is deliberately not in
    // here: there the keyboard is a floating panel that covers nothing, there is
    // no Dismiss button on the accessory bar at all (see -inputAccessoryView),
    // and the flag can therefore never be set — the follow-the-focus behaviour
    // stays exactly as it was.
    {
        const int catcher = Q3E_KeyCatcher();
        // Secondary re-arm, for the cases a touch is not involved at all: the
        // hint went stale on its own (a bind closed the field, a map loaded) or
        // the engine handed keys to something else — console, chat, the game.
        // The primary re-arm is -touchesBegan: above; neither of these two tests
        // fires while the user is simply moving between fields of one menu.
        if (kbd_dismissed && (!want || catcher != kbd_lastCatcher)) {
            kbd_dismissed = NO;
            kbd_seq++;
            Com_Printf("KBDMODE rearm (want=%d catcher=0x%x)\n", (int)want, catcher);
        }
        kbd_lastCatcher = catcher;
        // "q3ekbd on" is an explicit request for the keyboard and outranks it.
        if (kbd_dismissed && kbd_mode != 1) want = NO;
    }
#endif

    if (kbd_mode == 2) {
        // Forced off: give up first responder entirely, so no key and no
        // character can reach the engine through this view.
        if (self.isFirstResponder) [self resignFirstResponder];
        kbd_responder = NO;
        kbd_textMode = NO;
        return;
    }
    // Never take first responder back from something in front of us: the iOS
    // settings sheet, the onboarding flow and the Files picker all present over
    // this view and some of them own text fields. Claiming it every 250 ms would
    // dismiss their keyboard mid-word.
    UIViewController *root = self.window.rootViewController;
    const BOOL blocked = (root.presentedViewController != nil);
    if (!self.isFirstResponder && self.window && !blocked) {
        [self becomeFirstResponder];
    }
    kbd_responder = self.isFirstResponder;
    if (want != kbd_textMode) {
        kbd_textMode = want;
        kbd_seq++;
        [self reloadInputViews];
        Com_Printf("KBDMODE textMode=%d (responder=%d)\n", (int)kbd_textMode, (int)kbd_responder);
    }
}

// ---- hardware keys ----

- (BOOL)routePresses:(NSSet<UIPress *> *)presses down:(BOOL)down {
    BOOL handled = NO;
    for (UIPress *p in presses) {
        UIKey *k = p.key;
        if (!k) continue;
        char one[2];
        const char *name = q3e_keyname_for(k.keyCode, k.charactersIgnoringModifiers, one, sizeof(one));
        if (!name) continue;
        Q3E_QueueNamedKey(name, down ? 1 : 0);
        kbd_keyEvents++;
        kbd_seq++;
        snprintf(kbd_last, sizeof(kbd_last), "key:%s:%s", name, down ? "down" : "up");
        // BACKSPACE is a CHARACTER to this engine, not a key: Field_KeyDownEvent
        // has no K_BACKSPACE case at all, and Field_CharEvent does the deleting
        // when it sees ctrl-h (8) — which is what SDL delivers on desktop. The
        // key event still goes out for binds and for menu code that reads it.
        if (down && !strcmp(name, "BACKSPACE")) {
            Q3E_QueueChar(8);
            kbd_charEvents++;
        }
        handled = YES;
    }
    return handled;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (![self routePresses:presses down:YES]) [super pressesBegan:presses withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (![self routePresses:presses down:NO]) [super pressesEnded:presses withEvent:event];
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (![self routePresses:presses down:NO]) [super pressesCancelled:presses withEvent:event];
}
- (BOOL)hasText { return YES; }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeASCIICapable; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UITextSmartQuotesType)smartQuotesType { return UITextSmartQuotesTypeNo; }
- (UITextSmartDashesType)smartDashesType { return UITextSmartDashesTypeNo; }
- (UIKeyboardAppearance)keyboardAppearance { return UIKeyboardAppearanceDark; }

- (UIView *)inputAccessoryView {
    // Only alongside a real keyboard. The view is first responder almost all the
    // time now, and an accessory bar is drawn for a first responder whatever its
    // input view is — which would park a toolbar across the bottom of the game.
    if (!kbd_textMode) return nil;
#if TARGET_OS_VISION
    // No Dismiss button here. On visionOS the keyboard is a floating panel that
    // covers nothing, and dismissing it does not stick: the 4 Hz poll sees the
    // same field still focused and raises it again a quarter-second later. The
    // keyboard leaves when the focus does, which is the whole design.
    return nil;
#else
    if (!_kbToolbar) {
        _kbToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 40)];
        _kbToolbar.barStyle = UIBarStyleBlack;
        UIBarButtonItem *flex = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        UIBarButtonItem *dismiss = [[UIBarButtonItem alloc]
            initWithTitle:@"Dismiss ⌨" style:UIBarButtonItemStyleDone
            target:self action:@selector(dismissKeyboard)];
        // Paste. There is no text field to long-press on — the engine draws its
        // own fields — so the only way to get a clipboard string (a Urban Terror
        // auth key, a server address) into the game is a button of our own.
        UIBarButtonItem *paste = [[UIBarButtonItem alloc]
            initWithTitle:@"Paste" style:UIBarButtonItemStylePlain
            target:self action:@selector(pasteFromClipboard)];
        _kbToolbar.items = @[flex, paste, dismiss];
        [_kbToolbar sizeToFit];
    }
    return _kbToolbar;
#endif
}

- (void)dismissKeyboard {
    // Do NOT resign first responder: this view is first responder essentially
    // all the time so that hardware keys reach the engine, and giving that up
    // would only be undone by the next poll anyway. Lowering the keyboard is
    // swapping the input view back to the zero-size stand-in — and the flag is
    // what stops the poll from swapping it straight back.
    kbd_dismissed = YES;
    if (kbd_textMode) {
        kbd_textMode = NO;
        [self reloadInputViews];
    }
    kbd_seq++;
    Com_Printf("KBDMODE dismissed (sticks until focus changes)\n");
}

// Everything the Paste button does once it HAS a string. Split out because the
// clipboard read is the one part of the job that cannot be driven headlessly.
- (void)insertPastedString:(NSString *)s {
    if (!s.length) { Com_Printf("KBDPASTE nothing to paste\n"); return; }
    // Newlines would submit the field mid-paste (insertText: turns them into
    // ENTER), so a clipboard string that ends in one — the common case when it
    // was copied out of a text file or a web page — must lose them here rather
    // than close the menu the user is typing into.
    s = [[s stringByReplacingOccurrencesOfString:@"\r" withString:@""]
             stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    // The engine's fields are short; a runaway clipboard is not worth pumping
    // through the 512-event input funnel (512 slots) one character at a time.
    if (s.length > 256) s = [s substringToIndex:256];
    if (!s.length) { Com_Printf("KBDPASTE nothing to paste\n"); return; }
    [self insertText:s];   // the printable-ASCII filter lives there
    Com_Printf("KBDPASTE %lu char(s)\n", (unsigned long)s.length);
}

- (void)pasteFromClipboard {
    // -hasStrings answers without asking the user for anything; -string is the
    // call that raises iOS's "Allow Paste?" alert, and it BLOCKS its thread
    // until the alert is answered. On the main thread that would freeze the
    // display link — and the game with it — for as long as the alert is up, so
    // the read happens off-main and only the insertion comes back.
    if (!UIPasteboard.generalPasteboard.hasStrings) {
        Com_Printf("KBDPASTE clipboard has no text\n");
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *s = UIPasteboard.generalPasteboard.string;
        dispatch_async(dispatch_get_main_queue(), ^{ [self insertPastedString:s]; });
    });
}

- (void)insertText:(NSString *)text {
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\n' || c == '\r') {
            Q3E_QueueNamedKey("ENTER", 1);
            Q3E_QueueNamedKey("ENTER", 0);
            kbd_keyEvents++;
            snprintf(kbd_last, sizeof(kbd_last), "key:ENTER:tap");
        } else if (c >= 32 && c < 128) {
            Q3E_QueueChar((int)c);
            kbd_charEvents++;
            snprintf(kbd_last, sizeof(kbd_last), "char:%c", (char)c);
        }
        kbd_seq++;
    }
}

- (void)deleteBackward {
    Q3E_QueueNamedKey("BACKSPACE", 1);
    Q3E_QueueChar(8);   // the char is what actually deletes — see routePresses
    Q3E_QueueNamedKey("BACKSPACE", 0);
    kbd_keyEvents++;
    kbd_charEvents++;
    kbd_seq++;
    snprintf(kbd_last, sizeof(kbd_last), "key:BACKSPACE:tap");
}

- (void)keyboardWillShow:(NSNotification *)n {
#if TARGET_OS_VISION
    // The visionOS keyboard is its own floating panel in front of the window, not
    // a slab glued to the bottom of it — and in VR this view hosts a parked
    // window behind a curtain, where sliding it anywhere is at best pointless.
    (void)n;
#else
    // Scale to fit, do not slide. Sliding the view up by the keyboard height
    // pushed the top of the game off-screen — and the top is exactly where the
    // fields being typed into live (q3_ui Player Settings "Name", the Urban
    // Terror auth key). Shrinking the whole view into the strip above the
    // keyboard keeps every pixel of the game visible while the keyboard is up.
    UIWindow *win = self.window;
    if (!win) return;
    CGRect kb = [win convertRect:[n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue]
                      fromWindow:nil];
    CGFloat winW = win.bounds.size.width, winH = win.bounds.size.height;
    CGFloat viewW = self.bounds.size.width, viewH = self.bounds.size.height;
    if (viewH <= 0 || viewW <= 0 || winH <= 0) return;

    CGFloat visibleH = winH - kb.size.height;
    CGFloat s = visibleH / viewH;
    if (s > 1) s = 1;         // keyboard taller than the window is nonsense
    if (s < 0.2) s = 0.2;     // never scale the game into a postage stamp

    // center is in superview coords and is untouched by self.transform, so this
    // stays correct however many times the notification fires.
    CGPoint c = [self.superview convertPoint:self.center toView:nil];
    // After a scale about the anchor point the centre does not move, so place
    // the shrunken view by translating in window coords: top edge to the window
    // top, centred horizontally.
    CGFloat tx = winW * 0.5 - c.x;
    CGFloat ty = (s * viewH * 0.5) - c.y;
    CGAffineTransform t = CGAffineTransformConcat(CGAffineTransformMakeScale(s, s),
                                                  CGAffineTransformMakeTranslation(tx, ty));
    // UIKit geometry is invisible to an engine screenshot, so the view reports
    // its own placement to the console — that is how this gets verified from a
    // Mac (charter §6).
    Com_Printf("KBDFIT win %.0fx%.0f kbh %.0f visible %.0f view %.0fx%.0f "
               "scale %.4f t(%.1f,%.1f) top=%.1f bottom=%.1f\n",
               winW, winH, kb.size.height, visibleH, viewW, viewH, s, tx, ty,
               c.y + ty - s * viewH * 0.5, c.y + ty + s * viewH * 0.5);
    [UIView animateWithDuration:0.25 animations:^{
        self.transform = t;
    }];
#endif
}

- (void)keyboardWillHide:(NSNotification *)n {
#if !TARGET_OS_VISION
    [UIView animateWithDuration:0.25 animations:^{
        self.transform = CGAffineTransformIdentity;
    }];
#endif
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        const char *sens = getenv("Q3E_TOUCH_SENS");
        if (sens && atof(sens) > 0.1) look_sens_x = look_sens_y = (float)atof(sens);
        [NSNotificationCenter.defaultCenter addObserverForName:@"Q3EControlStyleChanged"
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            [self applyControlStyle];
        }];
        const char *um = getenv("Q3E_UIMAP");
        if (um && (*um == 'c' || *um == 'p' || *um == 'l')) uimap_mode = *um;
        const char *ud = getenv("Q3E_UIDELTA");
        if (ud && atof(ud) > 0.1) uidelta_mult = (float)atof(ud);
        const char *gyro = getenv("Q3E_GYRO");
        if (gyro && atof(gyro) > 0.01) {
            gyro_scale = (float)atof(gyro);
            gyro_mgr = [[CMMotionManager alloc] init];
            gyro_mgr.deviceMotionUpdateInterval = 1.0 / 120.0;
            [gyro_mgr startDeviceMotionUpdates];
            NSLog(@"Q3E gyro aim enabled, scale %.2f", gyro_scale);
        }
        _oneShotTouches = [NSMutableSet set];
        _stickBase = [self circleLayer:STICK_RADIUS alpha:0.14];
        _stickNub = [self circleLayer:NUB_RADIUS alpha:0.28];
        _fireCircle = [self circleLayer:FIRE_RADIUS alpha:0.20];
        _jumpCircle = [self circleLayer:JUMP_RADIUS alpha:0.20];
        _wnextCircle = [self circleLayer:WPN_RADIUS alpha:0.16];
        _wprevCircle = [self circleLayer:WPN_RADIUS alpha:0.16];
        _crouchCircle = [self circleLayer:CROUCH_RADIUS alpha:0.18];
        // ≡ (top-right) = ESC / "Start". Bigger glyph, centered to fill the button.
        _menuButton = [self circleLayer:MENU_BTN_RADIUS alpha:0.16];
        [self addGlyph:@"≡" toLayer:_menuButton radius:MENU_BTN_RADIUS size:37 dx:0 dy:-3];
        // ⚙ (top-left) = open the iOS settings sheet. Shown only while a menu is up (any
        // input); replaces the old, easily-forgotten long-press on ≡.
        _gearButton = [self circleLayer:MENU_BTN_RADIUS alpha:0.16];
        [self addSymbol:@"gearshape.fill" toLayer:_gearButton size:24];
        _gearButton.hidden = YES;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardWillShow:)
            name:UIKeyboardWillShowNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardWillHide:)
            name:UIKeyboardWillHideNotification object:nil];
        _stickBase.hidden = _stickNub.hidden = YES;
        // Glyphs, not words (matching vkQuake 1.0.4): a crosshair reads as fire
        // instantly, "FIRE" does not.
        [self addSymbol:@"scope" toLayer:_fireCircle size:31 fallback:@"FIRE" radius:FIRE_RADIUS];
        [self addSymbol:@"arrow.up" toLayer:_jumpCircle size:24 fallback:@"JUMP" radius:JUMP_RADIUS];
        [self addSymbol:@"arrowtriangle.forward.fill" toLayer:_wnextCircle size:17 fallback:@"W+" radius:WPN_RADIUS];
        [self addSymbol:@"arrowtriangle.backward.fill" toLayer:_wprevCircle size:17 fallback:@"W-" radius:WPN_RADIUS];
        [self addSymbol:@"arrow.down" toLayer:_crouchCircle size:19 fallback:@"DUCK" radius:CROUCH_RADIUS];

        // Move-stick activation zone. The stick FLOATS to the thumb, so it has no
        // position of its own — what it has is this zone, which is placeable like
        // everything else. Invisible in play, drawn in the editor at its true
        // radius. Replaces the old lefty mirror: stick-on-the-right is now a drag.
        _stickZone = [self circleLayer:STICK_ZONE_R alpha:0.05];
        _stickZone.hidden = YES;

        [self buildControlRegistry];
        q3e_input_view = self;
        ctl_scale = q3e_clamp_scale([NSUserDefaults.standardUserDefaults objectForKey:@"q3e_ctl_scale"]
                        ? [NSUserDefaults.standardUserDefaults floatForKey:@"q3e_ctl_scale"] : ctl_scale);
        // Size the layers from the saved scale right here rather than relying on
        // Q3E_Settings_ApplyAll's notification arriving after this view exists —
        // the controls must never be drawn at 100% while hit-tested at ctl_scale.
        [self applyControlStyle];
        if (getenv("Q3E_TOUCHEDIT")) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self beginEditingLayout]; });
        }
        _modeTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
            [self syncMode];
            [self syncKeyboard];
        }];
    }
    return self;
}

// A manually-created CALayer animates EVERY property change implicitly (~0.25 s
// ease-in-out). UIView's own backing layer suppresses that; a raw sublayer does
// not — so every position assignment here was being animated. That is why the
// editor felt laggy to drag, and, worse, why the floating move stick's nub
// trailed the thumb by a quarter second during play (touchesMoved sets
// _stickNub.position every frame). Nulling the actions makes all of it instant.
static void q3e_no_implicit_actions(CALayer *l) {
    l.actions = @{
        @"position": [NSNull null], @"bounds": [NSNull null], @"path": [NSNull null],
        @"hidden": [NSNull null],   @"opacity": [NSNull null], @"contents": [NSNull null],
        @"fillColor": [NSNull null], @"strokeColor": [NSNull null], @"transform": [NSNull null],
    };
}

- (CAShapeLayer *)circleLayer:(CGFloat)r alpha:(CGFloat)a {
    CAShapeLayer *l = [CAShapeLayer layer];
    q3e_no_implicit_actions(l);
    l.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-r, -r, 2 * r, 2 * r)].CGPath;
    l.fillColor = [UIColor colorWithWhite:1.0 alpha:a].CGColor;
    l.strokeColor = [UIColor colorWithWhite:1.0 alpha:a + 0.15].CGColor;
    l.lineWidth = 2;
    [self.layer addSublayer:l];
    return l;
}

- (void)addLabel:(NSString *)text toLayer:(CALayer *)layer radius:(CGFloat)r size:(CGFloat)size {
    CATextLayer *t = [CATextLayer layer];
    t.string = text;
    t.fontSize = size;
    t.alignmentMode = kCAAlignmentCenter;
    t.foregroundColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
    t.frame = CGRectMake(-r, -size * 0.6f, 2 * r, size * 1.33f);
    // Rendered at the TOP of the size slider's range: the button is scaled by a
    // layer transform, so text rasterized at 1x would be resampled up and blur at
    // 160%. (UIScreen is unavailable on visionOS — hence the traitCollection.)
    t.contentsScale = (self.traitCollection.displayScale ?: 2.0) * CTL_SCALE_MAX;
    q3e_no_implicit_actions(t);
    [layer addSublayer:t];
}

// Like addLabel but with per-glyph nudges (dx/dy) — icon glyphs (≡, ⚙) don't sit on
// the same optical centre as word labels, so the menu buttons tune their placement.
- (void)addGlyph:(NSString *)text toLayer:(CALayer *)layer radius:(CGFloat)r
            size:(CGFloat)size dx:(CGFloat)dx dy:(CGFloat)dy {
    CATextLayer *t = [CATextLayer layer];
    t.string = text;
    t.fontSize = size;
    t.alignmentMode = kCAAlignmentCenter;
    t.foregroundColor = [UIColor colorWithWhite:1.0 alpha:0.72].CGColor;
    t.frame = CGRectMake(-r + dx, -size * 0.6f + dy, 2 * r, size * 1.33f);
    t.contentsScale = (self.traitCollection.displayScale ?: 2.0) * CTL_SCALE_MAX;
    q3e_no_implicit_actions(t);
    [layer addSublayer:t];
}

// A flat white SF Symbol centred in a button — crisper + monochrome vs. an emoji glyph.
// Glyph with a WORD fallback: if the symbol name is unknown on this OS the
// label stays, rather than leaving a blank circle.
- (void)addSymbol:(NSString *)name toLayer:(CALayer *)layer size:(CGFloat)pt
         fallback:(NSString *)word radius:(CGFloat)r {
    UIImage *probe = [UIImage systemImageNamed:name];
    if (!probe) {
        NSLog(@"Q3E SF Symbol '%@' unavailable — keeping text label '%@'", name, word);
        [self addLabel:word toLayer:layer radius:r size:15];
        return;
    }
    [self addSymbol:name toLayer:layer size:pt];
}

- (void)addSymbol:(NSString *)name toLayer:(CALayer *)layer size:(CGFloat)pt {
    // Rasterized at the TOP of the size slider's range and displayed at nominal
    // size (resizeAspect does the fit): the whole button is scaled by a layer
    // transform, so a glyph rendered at 100% would be resampled up to 160% and go
    // soft exactly where someone who enlarged the controls is looking hardest.
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:pt * CTL_SCALE_MAX
                                                        weight:UIImageSymbolWeightRegular];
    UIImage *sym = [[UIImage systemImageNamed:name withConfiguration:cfg]
                    imageWithTintColor:[UIColor colorWithWhite:1.0 alpha:0.9]
                    renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (!sym) return;
    // Rasterize into a bitmap — a symbol image's raw CGImage is the template MASK (shows
    // as black when set as layer.contents); drawing it bakes the white tint into pixels.
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sym.size];
    UIImage *flat = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [sym drawInRect:CGRectMake(0, 0, sym.size.width, sym.size.height)];
    }];
    CGSize nominal = CGSizeMake(sym.size.width / CTL_SCALE_MAX, sym.size.height / CTL_SCALE_MAX);
    CALayer *l = [CALayer layer];
    l.contents = (id)flat.CGImage;
    l.contentsGravity = kCAGravityResizeAspect;
    l.frame = CGRectMake(-nominal.width / 2, -nominal.height / 2, nominal.width, nominal.height);
    l.contentsScale = flat.scale;
    q3e_no_implicit_actions(l);
    [layer addSublayer:l];
}

// Everything the player sees as a control scales from ONE number, the size
// slider. Scaling the layer's TRANSFORM rather than re-pathing its circle is what
// makes the CONTENTS scale with it — the crosshair, the arrows, the ≡ glyph all
// live as sublayers, and re-pathing could never touch them, so cranking the
// slider used to grow the rings and leave the icons stranded at 100%. The stick,
// its nub, its activation zone and the two menu buttons were not in the old list
// at all and never scaled by any amount.
- (void)applyControlStyle {
    const CGFloat k = ctl_scale;
    void (^style)(CAShapeLayer *, CGFloat) = ^(CAShapeLayer *l, CGFloat baseA) {
        l.transform = CATransform3DMakeScale(k, k, 1.0);
        l.lineWidth = 2.0 / k;   // the transform scales the stroke too — keep ring weight constant
        l.fillColor = [UIColor colorWithWhite:1.0 alpha:MIN(baseA * ctl_alpha, 0.9)].CGColor;
        // Don't stomp the editor's highlight: the scale slider lives IN the editor,
        // so this runs on every drag of it while the outlines are meant to be yellow.
        l.strokeColor = self->_editing
            ? [UIColor colorWithRed:1 green:0.85 blue:0.4 alpha:0.95].CGColor
            : [UIColor colorWithWhite:1.0 alpha:MIN((baseA + 0.15) * ctl_alpha, 0.95)].CGColor;
    };
    style(_fireCircle, 0.20);
    style(_jumpCircle, 0.20);
    style(_wnextCircle, 0.16);
    style(_wprevCircle, 0.16);
    style(_crouchCircle, 0.18);
    style(_stickBase, 0.14);
    style(_stickNub, 0.28);
    style(_stickZone, 0.05);
    style(_menuButton, 0.16);
    style(_gearButton, 0.16);
    [self setNeedsLayout];
}

// Register every placeable control with its ident and its ORIGINAL placement
// rule. Keeping the default as a block (rather than converting to unit numbers)
// means the shipped layout is pixel-identical to before on every screen size —
// only a customised control switches to unit coordinates.
- (void)buildControlRegistry {
    _controls = [NSMutableArray array];
    void (^reg)(CAShapeLayer *, NSString *, CGFloat, BOOL, CGPoint (^)(CGSize, CGFloat)) =
        ^(CAShapeLayer *layer, NSString *ident, CGFloat r, BOOL zoneOnly, CGPoint (^def)(CGSize, CGFloat)) {
        Q3EControl *c = [Q3EControl new];
        c.layer = layer; c.ident = ident; c.baseRadius = r; c.zoneOnly = zoneOnly; c.defaultPos = def;
        [self->_controls addObject:c];
    };
    // Positions below marked "arranged on device" were dragged into place on a
    // phone and read back with `touchedit print`, then promoted to defaults.
    reg(_stickZone, @"stick", STICK_ZONE_R, YES,
        ^CGPoint(CGSize sz, CGFloat k) { return CGPointMake(sz.width * 0.220f, sz.height * 0.641f); }); // arranged on device
    reg(_fireCircle,   @"fire",   FIRE_RADIUS,   NO, ^CGPoint(CGSize sz, CGFloat k) { return CGPointMake(sz.width * 0.822f, sz.height * 0.714f); }); // arranged on device
    reg(_jumpCircle,   @"jump",   JUMP_RADIUS,   NO, ^CGPoint(CGSize sz, CGFloat k) { return CGPointMake(sz.width * 0.913f, sz.height * 0.530f); }); // arranged on device
    reg(_wnextCircle,  @"wnext",  WPN_RADIUS,    NO, ^CGPoint(CGSize sz, CGFloat k) { return CGPointMake(sz.width - 58 * k,  sz.height - 300 * k); });
    reg(_wprevCircle,  @"wprev",  WPN_RADIUS,    NO, ^CGPoint(CGSize sz, CGFloat k) { return CGPointMake(sz.width - 132 * k, sz.height - 300 * k); });
    reg(_crouchCircle, @"crouch", CROUCH_RADIUS, NO, ^CGPoint(CGSize sz, CGFloat k) { return CGPointMake(sz.width * 0.923f, sz.height * 0.859f); }); // arranged on device
    reg(_menuButton,   @"menu",   MENU_BTN_RADIUS, NO, ^CGPoint(CGSize sz, CGFloat k) { return CGPointMake(sz.width - 48, 42); });
    reg(_gearButton,   @"gear",   MENU_BTN_RADIUS, NO, ^CGPoint(CGSize sz, CGFloat k) { return CGPointMake(48, 42); });
    [self loadControlPositions];
}

- (void)loadControlPositions {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL custom = [d boolForKey:DEF_LAYOUT_SET];
    for (Q3EControl *c in _controls) {
        c.hasSaved = custom && [d objectForKey:q3e_pos_key(c.ident, "x")] != nil;
        if (c.hasSaved)
            c.unit = CGPointMake([d floatForKey:q3e_pos_key(c.ident, "x")],
                                 [d floatForKey:q3e_pos_key(c.ident, "y")]);
    }
    [self setNeedsLayout];
}

- (void)resetControlPositions {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (Q3EControl *c in _controls) {
        [d removeObjectForKey:q3e_pos_key(c.ident, "x")];
        [d removeObjectForKey:q3e_pos_key(c.ident, "y")];
    }
    [d setBool:NO forKey:DEF_LAYOUT_SET];
    [d setFloat:1.0f forKey:@"q3e_ctl_scale"];
    ctl_scale = 1.0f;
    [self applyControlStyle];
    [self loadControlPositions];
    _editSlider.value = 1.0f;
    [self updateScaleLabel];
    NSLog(@"Q3E touch layout reset to defaults");
}

- (Q3EControl *)placeableAt:(CGPoint)p {
    Q3EControl *best = nil;   // smallest wins, so a button inside the stick circle stays grabbable
    for (Q3EControl *c in _controls) {
        CGFloat r = c.baseRadius * ctl_scale;   // == what the editor draws
        CGFloat dx = p.x - c.layer.position.x, dy = p.y - c.layer.position.y;
        if (dx * dx + dy * dy <= r * r && (!best || c.baseRadius < best.baseRadius))
            best = c;
    }
    return best;
}

// The move zone scales with everything else: the stick's own throw radius already
// did (STICK_RADIUS * ctl_scale in touchesMoved), so a fixed zone meant the
// activation area and the stick it activates disagreed at any scale but 100%.
// The editor draws this circle at exactly this radius.
- (BOOL)pointInMoveZone:(CGPoint)p {
    const CGFloat r = STICK_ZONE_R * ctl_scale;
    CGFloat dx = p.x - _stickZone.position.x, dy = p.y - _stickZone.position.y;
    return dx * dx + dy * dy <= r * r;
}

// ≡ / ⚙ touch target. Scales like everything else, but never below the ~44 pt
// diameter a fingertip needs — shrinking the controls must not make Esc unhittable.
static CGFloat q3e_menu_hit_radius(void) {
    CGFloat r = MENU_BTN_HIT * ctl_scale;
    return r < 26.0f ? 26.0f : r;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    CGFloat k = ctl_scale;
    for (Q3EControl *c in _controls) {
        // NEVER reposition the control under the finger. layoutSubviews runs for
        // all sorts of reasons mid-drag (the editor chrome's own Auto Layout, a
        // bounds change, setNeedsLayout from applyControlStyle) and would snap the
        // dragged control back to its saved/default spot for a frame — the
        // "duplicate flashing nearby" — and worse, if it landed between the last
        // touchesMoved and touchesEnded, commitDrag would then SAVE that reset
        // position instead of where the finger let go.
        if (c == _dragCtl) continue;
        c.layer.position = c.hasSaved ? CGPointMake(c.unit.x * s.width, c.unit.y * s.height)
                                      : c.defaultPos(s, k);
    }
    if (_editing) _stickBase.position = _stickNub.position = _stickZone.position;
}

- (void)syncMode {
    BOOL menu = Q3E_MenuMode() != 0;
    // Q3E_IGNORE_PAD: the Simulator forwards any controller paired to the MAC into
    // the guest, which hides the whole touch overlay — so no sim screenshot could
    // ever show the on-screen controls. Env-only, so it cannot fire on a device.
    static int ignore_pad = -1;
    if (ignore_pad < 0) ignore_pad = getenv("Q3E_IGNORE_PAD") ? 1 : 0;
    BOOL pad = !ignore_pad && GCController.controllers.count > 0;
    if (menu != _menuMode || pad != _padConnected) {
        _menuMode = menu;
        _padConnected = pad;
        // touch game controls vanish in menus AND while a controller is
        // connected (menu taps stay active either way)
        BOOL hideGameControls = menu || pad;
        _fireCircle.hidden = _jumpCircle.hidden = hideGameControls;
        _wnextCircle.hidden = _wprevCircle.hidden = _crouchCircle.hidden = hideGameControls;
        // ≡ (ESC/Start): hide when a controller is connected — it has its own menu
        // button — EXCEPT keep it in menus as a pinch-to-Esc escape hatch (so a flaky
        // controller can't strand you in a menu).
        _menuButton.hidden = pad && !menu;
        // ⚙ (settings): visible whenever a menu is up, for every input.
        _gearButton.hidden = !menu;
        if (hideGameControls) {
            [self releaseAllTouches];
        }
    }
}

- (void)releaseAllTouches {
    if (_moveTouch) { _moveTouch = nil; Q3E_QueueJoyAxis(0, 0); Q3E_QueueJoyAxis(1, 0); _stickBase.hidden = _stickNub.hidden = YES; }
    if (_fireTouch) { _fireTouch = nil; Q3E_QueueNamedKey("MOUSE1", 0); }
    if (_jumpTouch) { _jumpTouch = nil; Q3E_QueueNamedKey("SPACE", 0); }
    if (_crouchTouch) { _crouchTouch = nil; Q3E_QueueNamedKey("c", 0); }
    [_oneShotTouches removeAllObjects];
    _lookTouch = nil;
}

- (BOOL)point:(CGPoint)p inCircle:(CAShapeLayer *)c radius:(CGFloat)r {
    CGFloat dx = p.x - c.position.x, dy = p.y - c.position.y;
    return dx * dx + dy * dy <= r * r;
}

// A new touch in the game view re-arms the auto-summon after a Dismiss. See the
// kbd_dismissed comment: this is the only signal that distinguishes "still
// looking at the field I closed the keyboard on" from "poking at the menu
// again", because the engine's focus hint and key catcher do not change within
// one menu screen. Cheap and unconditional — the flag is almost always already
// clear.
static void q3e_kbd_note_touch(void) {
#if !TARGET_OS_VISION
    if (!kbd_dismissed) return;
    kbd_dismissed = NO;
    kbd_seq++;
    Com_Printf("KBDMODE rearm (touch)\n");
#endif
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    q3e_kbd_note_touch();
    if (_editing) {
        CGPoint p = [touches.anyObject locationInView:self];
        _dragCtl = [self placeableAt:p];
        if (_dragCtl) {
            _dragOffset = CGSizeMake(_dragCtl.layer.position.x - p.x, _dragCtl.layer.position.y - p.y);
            NSLog(@"Q3E edit: grabbed %@", _dragCtl.ident);
        }
        return;
    }
    if (event.allTouches.count >= 3) {
        // 3-finger tap: force the on-screen keyboard up (and back to following
        // the engine on the next tap). The automatic path covers the console,
        // chat and any focused menu field; this stays as the manual override for
        // a mod UI whose fields the engine cannot see.
        kbd_mode = (kbd_mode == 1) ? 0 : 1;
        [self syncKeyboard];
        return;
    }
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        if (!_gearButton.hidden && [self point:p inCircle:_gearButton radius:q3e_menu_hit_radius()]) {
            _gearBtnTouch = t;              // ⚙ tap = open settings on release
            continue;
        }
        if (!_menuButton.hidden && [self point:p inCircle:_menuButton radius:q3e_menu_hit_radius()]) {
            _menuBtnTouch = t;              // ≡ tap = ESC on release
            continue;
        }
        if (_menuMode) {
            _tapStart = p;
            continue;
        }
        if (_padConnected) {
            continue; // controller owns gameplay input; touch stays menu-only
        }
        BOOL inMoveZone = [self pointInMoveZone:p];
        if (!_fireTouch && [self point:p inCircle:_fireCircle radius:FIRE_RADIUS * ctl_scale]) {
            _fireTouch = t;
            Q3E_QueueNamedKey("MOUSE1", 1);
#if !TARGET_OS_VISION
            if (fire_haptics && fire_haptic_gen) { [fire_haptic_gen impactOccurred]; [fire_haptic_gen prepare]; }
#endif
        } else if (!_jumpTouch && [self point:p inCircle:_jumpCircle radius:JUMP_RADIUS * ctl_scale]) {
            _jumpTouch = t;
            Q3E_QueueNamedKey("SPACE", 1);
        } else if (!_crouchTouch && [self point:p inCircle:_crouchCircle radius:CROUCH_RADIUS * ctl_scale]) {
            _crouchTouch = t;
            Q3E_QueueNamedKey("c", 1); // default bind: +movedown (hold to crouch)
        } else if ([self point:p inCircle:_wnextCircle radius:WPN_RADIUS * ctl_scale]) {
            [_oneShotTouches addObject:t]; // impulse: wheel keys are momentary
            Q3E_QueueNamedKey("MWHEELDOWN", 1);
            Q3E_QueueNamedKey("MWHEELDOWN", 0);
        } else if ([self point:p inCircle:_wprevCircle radius:WPN_RADIUS * ctl_scale]) {
            [_oneShotTouches addObject:t];
            Q3E_QueueNamedKey("MWHEELUP", 1);
            Q3E_QueueNamedKey("MWHEELUP", 0);
        } else if (!_moveTouch && inMoveZone) {
            _moveTouch = t;
            _moveAnchor = p;
            _stickBase.position = p;
            _stickNub.position = p;
            _stickBase.hidden = _stickNub.hidden = NO;
        } else if (!_lookTouch) {
            _lookTouch = t;
            _lookLast = p;
            _lookHavePrediction = NO; // stale prediction from a prior swipe must not seed this one
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editing) {
        if (_dragCtl) {
            CGPoint p = [touches.anyObject locationInView:self];
            // Only constraint: the centre stays on screen, so anything placed can be
            // grabbed again. No safe-rect/radius clamp — that proved far too strict
            // on vkQuake, refusing positions controls already ship at.
            CGFloat cx = MAX(0, MIN(self.bounds.size.width,  p.x + _dragOffset.width));
            CGFloat cy = MAX(0, MIN(self.bounds.size.height, p.y + _dragOffset.height));
            _dragCtl.layer.position = CGPointMake(cx, cy);
            if (_dragCtl.zoneOnly) _stickBase.position = _stickNub.position = _dragCtl.layer.position;
        }
        return;
    }
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        if (t == _moveTouch) {
            const float stickR = STICK_RADIUS * ctl_scale;
            float dx = (p.x - _moveAnchor.x) / stickR;
            float dy = (p.y - _moveAnchor.y) / stickR;
            float m = sqrtf(dx * dx + dy * dy);
            if (m > 1.0f) { dx /= m; dy /= m; m = 1.0f; }
            float scale = (m > 0.001f) ? (apply_curve(m) / m) : 0.0f;
            Q3E_QueueJoyAxis(0, (int)lroundf(127.0f * dx * scale));
            Q3E_QueueJoyAxis(1, (int)lroundf(-127.0f * dy * scale));
            _stickNub.position = CGPointMake(_moveAnchor.x + dx * stickR * m,
                                             _moveAnchor.y + dy * stickR * m);
        } else if (t == _lookTouch) {
            // Predicted touches (charter: kills the trailing-finger feel).
            // Drift-free scheme: send (correction to reality) + (new
            // prediction). Corrections replace last frame's guess with
            // truth, so long-term the path is exact; latency drops by
            // roughly one frame.
            CGPoint basis = _lookHavePrediction ? _lookPredicted : _lookLast;
            _lookLast = p;
            CGPoint target = p;
            UITouch *pred = [event predictedTouchesForTouch:t].lastObject;
            if (pred) {
                target = [pred locationInView:self];
                _lookPredicted = target;
                _lookHavePrediction = YES;
            } else {
                _lookHavePrediction = NO;
            }
            _lookAccX += (target.x - basis.x) * look_sens_x;
            _lookAccY += (target.y - basis.y) * look_sens_y;
            int mx = (int)_lookAccX, my = (int)_lookAccY;
            if (mx || my) {
                _lookAccX -= mx; _lookAccY -= my;
                Q3E_QueueMouse(mx, my);
            }
        }
    }
}

- (void)endTouches:(NSSet<UITouch *> *)touches {
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        if (t == _gearBtnTouch) {
            _gearBtnTouch = nil;
            Q3E_PresentSettings(self);
            continue;
        }
        if (t == _menuBtnTouch) {
            _menuBtnTouch = nil;
            Q3E_QueueNamedKey("ESCAPE", 1);
            Q3E_QueueNamedKey("ESCAPE", 0);
            continue;
        }
        if (_menuMode) {
            if ([_oneShotTouches containsObject:t]) {
                [_oneShotTouches removeObject:t];
                continue;
            }
            CGFloat dx = p.x - _tapStart.x, dy = p.y - _tapStart.y;
            if (dx * dx + dy * dy < TAP_SLOP * TAP_SLOP) {
                // Candidate inverse transforms for the stock UI's virtual
                // 640x480 cursor space, runtime-selectable via Q3E_UIMAP:
                //   'c' centered 4:3 (ui_atoms.c widescreen bias — default)
                //   'p' pure full-width stretch
                //   'l' left-anchored 4:3 (bias applied to draw but not
                //       cursor, or engine-side variants)
                // Field calibration decides; theory has missed twice.
                CGSize s = self.bounds.size;
                CGFloat yscale = s.height / 480.0f;
                CGFloat bias = 0.5f * (s.width - 640.0f * yscale);
                if (bias < 0) bias = 0;
                // Per-mod transform: each UI decides its own widescreen
                // handling. id-lineage UIs (baseq3/TA/CPMA) center a 4:3
                // region; UrT's TA-derived-but-forked UI stretches full
                // width (field report: center-accurate, edge drift).
                // Env Q3E_UIMAP > per-game default > 'c'.
                char mode = uimap_mode;
                if (!getenv("Q3E_UIMAP")) {
                    const char *game = Q3E_CurrentGame();
                    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:
                        [NSString stringWithFormat:@"q3e_uimap_%s", game]];
                    if (saved.length) {
                        mode = (char)[saved characterAtIndex:0];
                    } else if (!strcmp(game, "q3ut4")) {
                        mode = 'p';
                    }
                }
                int tx;
                switch (mode) {
                    case 'p': tx = (int)(p.x / s.width * 640.0f); break;
                    case 'l': tx = (int)(p.x / yscale); break;
                    default:  tx = (int)((p.x - bias) / yscale); break;
                }
                int ty = (int)(p.y / s.height * 480.0f);
                if (tx < 0) tx = 0;
                if (tx > 640) tx = 640;
                tapstep_push(0, 0, 0);
                tapstep_push(1, (int)(tx * uidelta_mult), (int)(ty * uidelta_mult));
                tapstep_push(2, 0, 0);
                NSLog(@"Q3E tap[%c x%.1f] (%.0f,%.0f)pt -> ui(%d,%d) view %.0fx%.0f pad=%d",
                      uimap_mode, uidelta_mult, p.x, p.y, tx, ty, s.width, s.height, (int)_padConnected);
            }
            continue;
        }
        if (t == _moveTouch) {
            _moveTouch = nil;
            Q3E_QueueJoyAxis(0, 0);
            Q3E_QueueJoyAxis(1, 0);
            _stickBase.hidden = _stickNub.hidden = YES;
        } else if (t == _lookTouch) {
            // settle the last prediction against reality so swipes end
            // with zero accumulated error
            if (_lookHavePrediction) {
                _lookAccX += (p.x - _lookPredicted.x) * look_sens_x;
                _lookAccY += (p.y - _lookPredicted.y) * look_sens_y;
                int mx = (int)_lookAccX, my = (int)_lookAccY;
                if (mx || my) {
                    _lookAccX -= mx; _lookAccY -= my;
                    Q3E_QueueMouse(mx, my);
                }
                _lookHavePrediction = NO;
            }
            _lookTouch = nil;
        } else if (t == _fireTouch) {
            _fireTouch = nil;
            Q3E_QueueNamedKey("MOUSE1", 0);
        } else if (t == _jumpTouch) {
            _jumpTouch = nil;
            Q3E_QueueNamedKey("SPACE", 0);
        } else if (t == _crouchTouch) {
            _crouchTouch = nil;
            Q3E_QueueNamedKey("c", 0);
        } else {
            [_oneShotTouches removeObject:t];
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editing) {
        // UIKit can deliver a final location in touchesEnded that the last
        // touchesMoved never carried; without this the control commits a few
        // points behind where the finger actually let go.
        if (_dragCtl) {
            CGPoint p = [touches.anyObject locationInView:self];
            CGFloat cx = MAX(0, MIN(self.bounds.size.width,  p.x + _dragOffset.width));
            CGFloat cy = MAX(0, MIN(self.bounds.size.height, p.y + _dragOffset.height));
            _dragCtl.layer.position = CGPointMake(cx, cy);
        }
        [self commitDrag];
        return;
    }
    [self endTouches:touches];
}

- (void)commitDrag {
    if (!_dragCtl) return;
    CGSize sz = self.bounds.size;
    if (sz.width > 0 && sz.height > 0) {
        CGPoint u = CGPointMake(_dragCtl.layer.position.x / sz.width,
                                _dragCtl.layer.position.y / sz.height);
        _dragCtl.unit = u;
        _dragCtl.hasSaved = YES;
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setFloat:u.x forKey:q3e_pos_key(_dragCtl.ident, "x")];
        [d setFloat:u.y forKey:q3e_pos_key(_dragCtl.ident, "y")];
        [d setBool:YES forKey:DEF_LAYOUT_SET];
        NSLog(@"Q3E layout: %@ -> (%.3f, %.3f)", _dragCtl.ident, u.x, u.y);
    }
    _dragCtl = nil;
}

// ---- layout editor --------------------------------------------------------
// Chrome copied from Shipwright (the reference UX) and matching vkQuake
// 1.0.4: reset · live scale slider with a percentage · done, bottom-left. No
// instruction text — dragging is self-evident once you are in here.
// x/y are 0..1 of the view. Mirrors what a finger does, via the same methods.
- (void)fakeTouchAt:(CGPoint)nrm phase:(int)phase {
    CGSize sz = self.bounds.size;
    CGPoint p = CGPointMake(nrm.x * sz.width, nrm.y * sz.height);
    if (phase == 0) {
        // Deliberately shared with the real -touchesBegan:: this seam is how the
        // keyboard's touch re-arm is proven on a device driven over a socket,
        // where nothing can put a finger on the glass.
        q3e_kbd_note_touch();
        _dragCtl = [self placeableAt:p];
        if (_dragCtl)
            _dragOffset = CGSizeMake(_dragCtl.layer.position.x - p.x, _dragCtl.layer.position.y - p.y);
        NSLog(@"Q3E faketouch down (%.0f,%.0f) grabbed=%@", p.x, p.y, _dragCtl.ident ?: @"none");
    } else if (phase == 1) {
        if (!_dragCtl) return;
        CGFloat cx = MAX(0, MIN(sz.width, p.x + _dragOffset.width));
        CGFloat cy = MAX(0, MIN(sz.height, p.y + _dragOffset.height));
        _dragCtl.layer.position = CGPointMake(cx, cy);
        if (_dragCtl.zoneOnly) _stickBase.position = _stickNub.position = _dragCtl.layer.position;
    } else if (phase == 3) {
        // Test seam: force a layout pass mid-drag. This is the exact race that
        // produced the "duplicate flashing nearby" and the snap-on-release, and
        // without it the bug cannot be reproduced off-device at all.
        [self setNeedsLayout];
        [self layoutIfNeeded];
        NSLog(@"Q3E faketouch: forced layout pass mid-drag");
    } else {
        [self commitDrag];
    }
}

// Dump the live layout in the form the defaults table takes, so a layout
// arranged on glass can be promoted without transcribing numbers by eye.
- (void)printLayout {
    CGSize sz = self.bounds.size;
    Com_Printf("touch layout — scale %.2f\n", ctl_scale);
    for (Q3EControl *c in _controls) {
        CGPoint pos = c.layer.position;
        Com_Printf("  %-7s %s at unit (%.3f, %.3f)\n", c.ident.UTF8String,
                   c.hasSaved ? "saved " : "default",
                   sz.width > 0 ? pos.x / sz.width : 0, sz.height > 0 ? pos.y / sz.height : 0);
    }
}

- (void)updateScaleLabel { _editPct.text = [NSString stringWithFormat:@"%.0f%%", ctl_scale * 100.0f]; }

- (BOOL)isEditingLayout { return _editing; }

- (void)beginEditingLayout {
    if (_editing) return;
    _editing = YES;
    [self releaseAllTouches];
    for (Q3EControl *c in _controls) {
        c.layer.hidden = NO;
        c.layer.strokeColor = [UIColor colorWithRed:1 green:0.85 blue:0.4 alpha:0.95].CGColor;
    }
    _stickZone.hidden = NO;
    _stickBase.hidden = _stickNub.hidden = NO;   // park the stick inside its zone
    [self setNeedsLayout];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:bar];
    _editBar = bar;

    UIButton *(^pill)(NSString *, UIColor *, SEL) = ^UIButton *(NSString *sym, UIColor *bg, SEL act) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.backgroundColor = bg;
        [b setImage:[[UIImage systemImageNamed:sym] imageWithConfiguration:
                     [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold]]
           forState:UIControlStateNormal];
        b.tintColor = UIColor.whiteColor;
        b.layer.cornerRadius = 21;
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b addTarget:self action:act forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:b];
        return b;
    };
    UIButton *reset = pill(@"arrow.uturn.backward", [UIColor colorWithRed:0.85 green:0.20 blue:0.22 alpha:0.95], @selector(resetControlPositions));
    UIButton *done  = pill(@"checkmark", [UIColor colorWithRed:0.18 green:0.78 blue:0.34 alpha:0.95], @selector(endEditingLayout));

    UISlider *sl = [UISlider new];
    sl.minimumValue = CTL_SCALE_MIN; sl.maximumValue = CTL_SCALE_MAX; sl.value = ctl_scale;
    sl.minimumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.9];
    sl.translatesAutoresizingMaskIntoConstraints = NO;
    [sl addTarget:self action:@selector(editScaleChanged:) forControlEvents:UIControlEventValueChanged];
    [bar addSubview:sl];
    _editSlider = sl;

    UILabel *pct = [UILabel new];
    pct.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    pct.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    pct.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:pct];
    _editPct = pct;
    [self updateScaleLabel];

    UILayoutGuide *safe = self.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:14],
        [bar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-14],
        [bar.heightAnchor constraintEqualToConstant:42],
        [bar.trailingAnchor constraintEqualToAnchor:done.trailingAnchor],
        [reset.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [reset.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [reset.widthAnchor constraintEqualToConstant:42],
        [reset.heightAnchor constraintEqualToConstant:42],
        [sl.leadingAnchor constraintEqualToAnchor:reset.trailingAnchor constant:16],
        [sl.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [sl.widthAnchor constraintEqualToConstant:220],
        [pct.centerXAnchor constraintEqualToAnchor:sl.centerXAnchor],
        [pct.bottomAnchor constraintEqualToAnchor:sl.topAnchor constant:-2],
        [done.leadingAnchor constraintEqualToAnchor:sl.trailingAnchor constant:16],
        [done.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [done.widthAnchor constraintEqualToConstant:42],
        [done.heightAnchor constraintEqualToConstant:42],
    ]];
    NSLog(@"Q3E touch layout editor entered");
}

- (void)editScaleChanged:(UISlider *)sl {
    ctl_scale = q3e_clamp_scale(sl.value);
    [NSUserDefaults.standardUserDefaults setFloat:ctl_scale forKey:@"q3e_ctl_scale"];
    [self applyControlStyle];
    [self updateScaleLabel];
}

- (void)endEditingLayout {
    if (!_editing) return;
    [self commitDrag];
    _editing = NO;
    [self applyControlStyle];   // back to the per-control stroke/opacity
    _stickZone.hidden = YES;
    _stickBase.hidden = _stickNub.hidden = YES;
    [_editBar removeFromSuperview];
    _editBar = nil; _editSlider = nil; _editPct = nil;
    _menuMode = !_menuMode; [self syncMode];   // force a re-sync of control visibility
    NSLog(@"Q3E touch layout editor exited");
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editing) { [self commitDrag]; return; }
    [self endTouches:touches];
}

@end

// ---- keyboard: the C surface ios_glue.c registers as console commands --------
// Injection exists because a headless simulator can deliver neither a hardware
// keystroke nor a tap on the virtual keyboard to the guest, so the only way to
// PROVE the path is to enter it where UIKit does: -insertText: for characters,
// the press router for key events (via the same HID table, looked up backwards).

@interface Q3EInputView (Keyboard) <UIKeyInput>
- (void)syncKeyboard;
- (void)pasteFromClipboard;
- (void)insertPastedString:(NSString *)s;
- (void)dismissKeyboard;
@end

void Q3E_Keyboard_SetMode(int mode) {
    kbd_mode = (mode < 0 || mode > 2) ? 0 : mode;
    // Asking for the keyboard by name is explicit and clears a stuck dismiss.
    kbd_dismissed = NO;
    kbd_seq++;
    Q3EInputView *v = q3e_input_view;
    if (v) dispatch_async(dispatch_get_main_queue(), ^{ [v syncKeyboard]; });
}

int Q3E_Keyboard_GetMode(void) { return kbd_mode; }

void Q3E_Keyboard_DumpLine(char *out, int len) {
    snprintf(out, (size_t)len,
             "resp=%d text=%d mode=%s dismissed=%d keys=%d chars=%d last=%s seq=%d",
             (int)kbd_responder, (int)kbd_textMode,
             kbd_mode == 0 ? "auto" : (kbd_mode == 1 ? "on" : "off"),
             (int)kbd_dismissed,
             kbd_keyEvents, kbd_charEvents, kbd_last, kbd_seq);
}

// Tap the accessory bar's "Dismiss ⌨" button from the console — the only way to
// exercise the sticky-dismiss path headlessly, since nothing can tap a UIToolbar
// item on a device we are driving over a socket.
void Q3E_Keyboard_Dismiss(void) {
    Q3EInputView *v = q3e_input_view;
    if (!v) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [v dismissKeyboard]; });
}

// Fire the accessory bar's Paste button from the console. A headless simulator
// cannot tap a UIToolbar item, so this enters at the button's own action — the
// clipboard read, the newline strip and the length cap are all under test.
void Q3E_Keyboard_Paste(const char *literal) {
    Q3EInputView *v = q3e_input_view;
    if (!v) return;
    if (literal && literal[0]) {
        // Everything after the clipboard read, driven from the console: the
        // newline strip, the length cap and the insertText: filter.
        NSString *s = [NSString stringWithUTF8String:literal];
        if (!s) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [v insertPastedString:s]; });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [v pasteFromClipboard]; });
}

void Q3E_Keyboard_InjectText(const char *utf8) {
    if (!utf8 || !utf8[0]) return;
    NSString *s = [NSString stringWithUTF8String:utf8];
    if (!s) return;
    Q3EInputView *v = q3e_input_view;
    if (!v) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        // The mode gate is the point of the fault injection: with the responder
        // forced down, UIKit would never call -insertText: either.
        if (kbd_mode == 2 || !v.isFirstResponder) {
            Com_Printf("KBDTYPE REFUSED (responder=%d mode=%d)\n",
                       (int)v.isFirstResponder, kbd_mode);
            return;
        }
        [v insertText:s];
    });
}

void Q3E_Keyboard_InjectKey(const char *name, int down) {
    if (!name || !name[0]) return;
    Q3EInputView *v = q3e_input_view;
    if (!v) return;
    // Reverse the SAME table the press router reads forwards; a printable key
    // has no entry and travels as its own character, exactly as UIKey reports it.
    UIKeyboardHIDUsage code = 0;
    for (size_t i = 0; i < sizeof(q3e_keymap) / sizeof(q3e_keymap[0]); i++) {
        if (!strcasecmp(q3e_keymap[i].name, name)) { code = q3e_keymap[i].code; break; }
    }
    // Cmd_Argv hands back a rotating engine buffer — copy before the hop.
    NSString *nsname = [NSString stringWithUTF8String:name];
    if (!nsname) return;
    NSString *chars = code ? @"" : nsname;
    UIKeyboardHIDUsage useCode = code;
    BOOL isDown = down ? YES : NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (kbd_mode == 2 || !v.isFirstResponder) {
            Com_Printf("KBDKEY REFUSED (responder=%d mode=%d)\n",
                       (int)v.isFirstResponder, kbd_mode);
            return;
        }
        char one[2];
        const char *resolved = q3e_keyname_for(useCode, chars, one, sizeof(one));
        if (!resolved) { Com_Printf("KBDKEY unknown key '%s'\n", nsname.UTF8String); return; }
        Q3E_QueueNamedKey(resolved, isDown ? 1 : 0);
        kbd_keyEvents++;
        kbd_seq++;
        snprintf(kbd_last, sizeof(kbd_last), "key:%s:%s", resolved, isDown ? "down" : "up");
        // The companion character -routePresses: emits for BACKSPACE. An
        // injector that skips it is not simulating a keyboard: deletion lives
        // in Field_CharEvent (ctrl-h), so without this the suite could type but
        // never delete, and the case written to catch R4.9's backspace bug
        // failed against a correct engine.
        if (isDown && !strcmp(resolved, "BACKSPACE")) {
            Q3E_QueueChar(8);
            kbd_charEvents++;
        }
    });
}
