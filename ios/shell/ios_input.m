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

// ---- shims (ios_glue.c) ----
void Q3E_QueueMouse(int dx, int dy);
void Q3E_QueueJoyAxis(int axis, int value); // 0=side, 1=forward
void Q3E_QueueNamedKey(const char *name, int down);
void Q3E_QueueChar(int ch);
void Q3E_QueueCommand(const char *cmd); // run a console command (e.g. centerview)
int  Q3E_MenuMode(void); // UI/console catcher active or not in-world
const char *Q3E_CurrentGame(void);

#define PAD_DEADZONE 0.15f

#define MOVE_ZONE_FRAC   0.42f
#define STICK_RADIUS     85.0f
#define NUB_RADIUS       30.0f
#define FIRE_RADIUS      54.0f
#define JUMP_RADIUS      42.0f
#define TAP_SLOP         12.0f
#define LOOK_SENS_DEFAULT 3.5f
#define PAD_LOOK_SPEED  11.0f    // gameplay look gain (was 16 — softened accel)
#define MENU_CURSOR_SPEED 13.0f  // right-stick → UI mouse cursor in menus

static float look_sens_x = LOOK_SENS_DEFAULT;
static float look_sens_y = LOOK_SENS_DEFAULT;
static float ctl_scale = 1.0f;   // control size multiplier
static float ctl_alpha = 1.0f;   // control opacity multiplier
static int   ctl_lefty = 0;      // mirrored layout
static char uimap_mode = 'c';               // Q3E_UIMAP env: c|p|l

// Cursor-delta multiplier (Q3E_UIDELTA env). Stock 1.32 UI: 1.0.
// Mod UIs may scale deltas themselves — the A51 mod's UI (which once
// hijacked baseq3 via auto-downloaded zzz-*.pk3 and halved deltas)
// needed 2.0. Field-calibrate per UI with the tap telemetry if menus
// ever misbehave again; first suspect: a downloaded pk3 overriding
// the stock ui.qvm.
static float uidelta_mult = 1.0f;

void Q3E_PresentSettings(UIView *fromView); // ios_settings.m

#define WPN_RADIUS       30.0f
#define CROUCH_RADIUS    38.0f

// Gyro aim: enabled by Q3E_GYRO=<scale> (e.g. 2.0). Landscape-right axis
// mapping/signs are a first guess — tune with hands-on feedback before
// promoting to a default-on setting.
static float gyro_scale = 0.0f;
static CMMotionManager *gyro_mgr;
static float gyro_accx, gyro_accy;
void Q3E_QueueMouse(int dx, int dy);

static void gyro_poll(int menuMode, float dt) {
    if (gyro_scale <= 0.0f || !gyro_mgr || menuMode) return;
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
static int crouch_toggled;                     // L3 toggle-crouch latch
static int l3_prev, r3_prev;                   // L3/R3 press-edge detect
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
    crouch_toggled = 0; l3_prev = 0; r3_prev = 0;
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

static void pad_poll(int menuMode, float dt) {
    GCController *pad = GCController.controllers.firstObject;
    if (!pad || !pad.extendedGamepad) {
        if (pad_side || pad_forward) {
            pad_side = pad_forward = 0;
            Q3E_QueueJoyAxis(0, 0);
            Q3E_QueueJoyAxis(1, 0);
        }
        return;
    }
    GCExtendedGamepad *g = pad.extendedGamepad;

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
        float lx = g.leftThumbstick.xAxis.value;
        float ly = g.leftThumbstick.yAxis.value;
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
        float rx = g.rightThumbstick.xAxis.value;
        float ry = g.rightThumbstick.yAxis.value;
        float rm = sqrtf(rx * rx + ry * ry);
        rx = pad_deadzone(rx, rm);
        ry = pad_deadzone(ry, rm);
        // dt-normalized to the 120 Hz reference so the 60 Hz refresh setting
        // doesn't change turn rate. Response is a linear+quadratic blend (was
        // pure |v|·v) so the slow->fast transition is gentler while small-stick
        // aim stays precise; gain trimmed to match (PAD_LOOK_SPEED).
        const float look_dt = dt * 120.0f;
        float cx = 0.25f * fabsf(rx) + 0.75f * rx * rx;
        float cy = 0.25f * fabsf(ry) + 0.75f * ry * ry;
        pad_lookx += copysignf(cx, rx) * PAD_LOOK_SPEED * look_dt;
        pad_looky += -copysignf(cy, ry) * PAD_LOOK_SPEED * look_dt;
        int dx = (int)pad_lookx, dy = (int)pad_looky;
        if (dx || dy) {
            pad_lookx -= dx; pad_looky -= dy;
            Q3E_QueueMouse(dx, dy);
        }

        // gameplay buttons
        pad_button(&pad_fire, g.rightTrigger.pressed, "MOUSE1");
        pad_button(&pad_zoom, g.leftTrigger.pressed, "MOUSE2");
        pad_button(&pad_jump, g.buttonA.pressed, "SPACE");
        pad_button(&pad_use,  g.buttonX.pressed, "ENTER");
        pad_button(&pad_wprev, g.leftShoulder.pressed, "[");
        pad_button(&pad_wnext, g.rightShoulder.pressed, "]");
        pad_button(&pad_esc,  g.buttonMenu.pressed, "ESCAPE"); // START opens the menu
        pad_button(&pad_scores, g.buttonOptions.pressed, "TAB"); // VIEW = show scores

        // L3 = TOGGLE crouch (latched); B = hold crouch. "c" (+movedown) is
        // held if either is active, so the two never fight over the key.
        BOOL l3 = g.leftThumbstickButton.pressed;
        if (l3 && !l3_prev) crouch_toggled = !crouch_toggled;
        l3_prev = l3;
        pad_button(&pad_crouch, (g.buttonB.pressed || crouch_toggled), "c");

        // R3 = center view (recenter pitch) — one-shot on press
        BOOL r3 = g.rightThumbstickButton.pressed;
        if (r3 && !r3_prev) Q3E_QueueCommand("centerview");
        r3_prev = r3;
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
        int dirY = g.dpad.up.pressed   ? -1 : g.dpad.down.pressed  ?  1 :
                   (g.leftThumbstick.yAxis.value >  0.5f ? -1 :
                    g.leftThumbstick.yAxis.value < -0.5f ?  1 : 0);
        int dirX = g.dpad.left.pressed ? -1 : g.dpad.right.pressed ?  1 :
                   (g.leftThumbstick.xAxis.value < -0.5f ? -1 :
                    g.leftThumbstick.xAxis.value >  0.5f ?  1 : 0);
        menu_axis(dirY, &menu_dir_y, &menu_rep_y, dt, "UPARROW", "DOWNARROW");
        menu_axis(dirX, &menu_dir_x, &menu_rep_x, dt, "LEFTARROW", "RIGHTARROW");

        // face buttons: A = Enter (activate), B = Esc (back / close), X = Space.
        // START stays unmapped in-menu — it opens the menu from gameplay, and
        // mapping it here would toggle the menu shut on the same press; B closes.
        pad_button(&menu_btnA, g.buttonA.pressed, "ENTER");
        pad_button(&menu_btnB, g.buttonB.pressed, "ESCAPE");
        pad_button(&menu_btnX, g.buttonX.pressed, "SPACE");

        // right stick → move the UI mouse cursor, RT = click. This reaches
        // mouse-only widgets the arrow keys can't — notably the server
        // browser's FIGHT button (the stock Q3 list joins on FIGHT / a
        // double-click, not on Enter). Complements the arrow-key nav above.
        float rx = g.rightThumbstick.xAxis.value;
        float ry = g.rightThumbstick.yAxis.value;
        float rm = sqrtf(rx * rx + ry * ry);
        rx = pad_deadzone(rx, rm);
        ry = pad_deadzone(ry, rm);
        const float cur_dt = dt * 120.0f;
        menu_curx += rx * fabsf(rx) * MENU_CURSOR_SPEED * cur_dt;
        menu_cury += -ry * fabsf(ry) * MENU_CURSOR_SPEED * cur_dt;
        int cdx = (int)menu_curx, cdy = (int)menu_cury;
        if (cdx || cdy) { menu_curx -= cdx; menu_cury -= cdy; Q3E_QueueMouse(cdx, cdy); }
        pad_button(&menu_click, g.rightTrigger.pressed, "MOUSE1");
    }
}

void Q3E_Input_Frame(void) {
    // real per-callback dt (seconds) for frame-rate-independent look accel
    static double lastT = 0.0;
    double now = CACurrentMediaTime();
    float dt = (lastT > 0.0) ? (float)(now - lastT) : (1.0f / 120.0f);
    lastT = now;
    if (dt <= 0.0f || dt > 0.1f) dt = 1.0f / 120.0f; // first-frame / hitch clamp

    const int menuMode = Q3E_MenuMode();
    tapstep_drain_one();
    pad_poll(menuMode, dt);
    gyro_poll(menuMode, dt);
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

void Q3E_Input_SetControlStyle(float scale, float alpha, int lefty) {
    ctl_scale = scale;
    ctl_alpha = alpha;
    ctl_lefty = lefty;
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
    NSTimer *_modeTimer;
    BOOL _menuMode;
    BOOL _padConnected;
    UIToolbar *_kbToolbar;
}

+ (Class)layerClass { return [CAMetalLayer class]; }

// ---- on-screen keyboard (UIKeyInput) ----
// 3-finger tap toggles it (q2repro-proven fallback until per-field focus
// detection exists); the view slides up by the keyboard height so the
// typed line stays visible; the accessory bar's Dismiss button is the
// reliable close path. Keys feed the engine as SE_CHAR/SE_KEY events.

- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeASCIICapable; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UITextSmartQuotesType)smartQuotesType { return UITextSmartQuotesTypeNo; }
- (UITextSmartDashesType)smartDashesType { return UITextSmartDashesTypeNo; }
- (UIKeyboardAppearance)keyboardAppearance { return UIKeyboardAppearanceDark; }

- (UIView *)inputAccessoryView {
    if (!_kbToolbar) {
        _kbToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 40)];
        _kbToolbar.barStyle = UIBarStyleBlack;
        UIBarButtonItem *flex = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        UIBarButtonItem *dismiss = [[UIBarButtonItem alloc]
            initWithTitle:@"Dismiss ⌨" style:UIBarButtonItemStyleDone
            target:self action:@selector(dismissKeyboard)];
        _kbToolbar.items = @[flex, dismiss];
        [_kbToolbar sizeToFit];
    }
    return _kbToolbar;
}

- (void)dismissKeyboard { [self resignFirstResponder]; }

- (void)insertText:(NSString *)text {
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\n') {
            Q3E_QueueNamedKey("ENTER", 1);
            Q3E_QueueNamedKey("ENTER", 0);
        } else if (c < 128) {
            Q3E_QueueChar((int)c);
        }
    }
}

- (void)deleteBackward {
    Q3E_QueueNamedKey("BACKSPACE", 1);
    Q3E_QueueNamedKey("BACKSPACE", 0);
}

- (void)keyboardWillShow:(NSNotification *)n {
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat h = [self.window convertRect:kb fromWindow:nil].size.height;
    [UIView animateWithDuration:0.25 animations:^{
        self.transform = CGAffineTransformMakeTranslation(0, -h);
    }];
}

- (void)keyboardWillHide:(NSNotification *)n {
    [UIView animateWithDuration:0.25 animations:^{
        self.transform = CGAffineTransformIdentity;
    }];
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
        _menuButton = [self circleLayer:26.0f alpha:0.16];
        [self addGlyph:@"≡" toLayer:_menuButton radius:26.0f size:40 dx:0 dy:-3];
        // ⚙ (top-left) = open the iOS settings sheet. Shown only while a menu is up (any
        // input); replaces the old, easily-forgotten long-press on ≡.
        _gearButton = [self circleLayer:26.0f alpha:0.16];
        [self addSymbol:@"gearshape.fill" toLayer:_gearButton size:26];
        _gearButton.hidden = YES;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardWillShow:)
            name:UIKeyboardWillShowNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardWillHide:)
            name:UIKeyboardWillHideNotification object:nil];
        _stickBase.hidden = _stickNub.hidden = YES;
        [self addLabel:@"FIRE" toLayer:_fireCircle radius:FIRE_RADIUS size:15];
        [self addLabel:@"JUMP" toLayer:_jumpCircle radius:JUMP_RADIUS size:15];
        [self addLabel:@"W+" toLayer:_wnextCircle radius:WPN_RADIUS size:15];
        [self addLabel:@"W-" toLayer:_wprevCircle radius:WPN_RADIUS size:15];
        [self addLabel:@"DUCK" toLayer:_crouchCircle radius:CROUCH_RADIUS size:15];
        _modeTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
            [self syncMode];
        }];
    }
    return self;
}

- (CAShapeLayer *)circleLayer:(CGFloat)r alpha:(CGFloat)a {
    CAShapeLayer *l = [CAShapeLayer layer];
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
    t.contentsScale = self.traitCollection.displayScale ?: 2.0; // UIScreen n/a on visionOS
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
    t.contentsScale = self.traitCollection.displayScale ?: 2.0;
    [layer addSublayer:t];
}

// A flat white SF Symbol centred in a button — crisper + monochrome vs. an emoji glyph.
- (void)addSymbol:(NSString *)name toLayer:(CALayer *)layer size:(CGFloat)pt {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightRegular];
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
    CALayer *l = [CALayer layer];
    l.contents = (id)flat.CGImage;
    l.contentsGravity = kCAGravityResizeAspect;
    l.frame = CGRectMake(-sym.size.width / 2, -sym.size.height / 2, sym.size.width, sym.size.height);
    l.contentsScale = flat.scale;
    [layer addSublayer:l];
}

- (void)applyControlStyle {
    // re-path at scaled radii + apply opacity multiplier
    void (^repath)(CAShapeLayer *, CGFloat, CGFloat) = ^(CAShapeLayer *l, CGFloat baseR, CGFloat baseA) {
        CGFloat r = baseR * ctl_scale;
        l.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-r, -r, 2 * r, 2 * r)].CGPath;
        l.fillColor = [UIColor colorWithWhite:1.0 alpha:MIN(baseA * ctl_alpha, 0.9)].CGColor;
        l.strokeColor = [UIColor colorWithWhite:1.0 alpha:MIN((baseA + 0.15) * ctl_alpha, 0.95)].CGColor;
    };
    repath(_fireCircle, FIRE_RADIUS, 0.20);
    repath(_jumpCircle, JUMP_RADIUS, 0.20);
    repath(_wnextCircle, WPN_RADIUS, 0.16);
    repath(_wprevCircle, WPN_RADIUS, 0.16);
    repath(_crouchCircle, CROUCH_RADIUS, 0.18);
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    CGFloat k = ctl_scale;
    // lefty mirrors the game-control cluster; ≡ stays top-left
    CGFloat (^mx)(CGFloat) = ^CGFloat(CGFloat fromRight) {
        return ctl_lefty ? fromRight : (s.width - fromRight);
    };
    _fireCircle.position = CGPointMake(mx(95 * k), s.height - 105 * k);
    _jumpCircle.position = CGPointMake(mx(95 * k), s.height - 215 * k);
    _wnextCircle.position = CGPointMake(mx(58 * k), s.height - 300 * k);
    _wprevCircle.position = CGPointMake(mx(132 * k), s.height - 300 * k);
    _crouchCircle.position = CGPointMake(mx(215 * k), s.height - 85 * k);
    _menuButton.position = CGPointMake(s.width - 48, 42); // top-right (≡ = ESC/Start)
    _gearButton.position = CGPointMake(48, 42);           // top-left  (⚙ = settings)
}

- (void)syncMode {
    BOOL menu = Q3E_MenuMode() != 0;
    BOOL pad = GCController.controllers.count > 0;
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

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (event.allTouches.count >= 3) {
        // 3-finger tap: toggle the on-screen keyboard
        if (self.isFirstResponder) {
            [self resignFirstResponder];
        } else {
            [self becomeFirstResponder];
        }
        return;
    }
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        if (!_gearButton.hidden && [self point:p inCircle:_gearButton radius:34.0f]) {
            _gearBtnTouch = t;              // ⚙ tap = open settings on release
            continue;
        }
        if (!_menuButton.hidden && [self point:p inCircle:_menuButton radius:34.0f]) {
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
        BOOL inMoveZone = ctl_lefty
            ? (p.x > self.bounds.size.width * (1.0f - MOVE_ZONE_FRAC))
            : (p.x < self.bounds.size.width * MOVE_ZONE_FRAC);
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
    [self endTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self endTouches:touches];
}

@end
