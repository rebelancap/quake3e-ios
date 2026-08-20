#pragma once
// Q3EVR.h — the public contract of the visionOS VR mode.
//
// Three files share it:
//   Q3EVRGlue.c  — engine-side C: console dumps, synthetic injection, the
//                  client-state sampler, and the definitions of the published
//                  state below.
//   Q3EVR.m      — the VR compositor loop (Metal/ARKit/CompositorServices).
//   AppShell_vision.m / Q3EVisionApp.swift — the mode machine and the spaces.

#ifdef __OBJC__
#import <CompositorServices/CompositorServices.h>
// Runs the VR compositor loop until the layer is invalidated or the shell stops
// it. Invoked from the ImmersiveSpace(id:"Q3EVR") CompositorLayer closure on its
// own dedicated thread.
void Q3E_VR_Run(cp_layer_renderer_t layer_renderer);
#endif

#ifdef __cplusplus
extern "C" {
#endif

// --- modes -----------------------------------------------------------------
// One immersive space is open at a time, so the mode is a tri-state, not a pair
// of bools. Q3E_EnterMode is the single owner of every transition.
typedef enum {
    Q3E_MODE_2D = 0,
    Q3E_MODE_3D = 1,
    Q3E_MODE_VR = 2
} q3e_mode_t;

extern volatile int q3e_mode;
int  Q3E_GetMode(void);
void Q3E_EnterMode(int mode);
const char *Q3E_ModeName(int mode);

// Which side is calling Q3E_Frame right now. Exactly one owner at any moment;
// asserted in the black box on every transition.
typedef enum {
    Q3E_FRAME_OWNER_LINK = 0,   // the main-thread CADisplayLink
    Q3E_FRAME_OWNER_VR   = 1    // the dedicated VR engine thread
} q3e_frame_owner_t;
extern volatile int q3e_frame_owner;

// --- VR loop handshake ------------------------------------------------------
extern volatile int q3e_vrStop;      // shell -> loop: stop at the next iteration
extern volatile int q3e_vrRunning;   // loop -> shell: the loop still owns the layer
extern volatile int q3e_vrFrameCount;

void Q3E_VR_Ended(void);             // system/Crown dismissal (idempotent)
void Q3E_ExitVRFinalize(void);       // unconditional finalize (idempotent)

// Engine-thread lifecycle. Stopping is a request plus a poll, never a join:
// the console commands that ask for it run ON the engine thread.
void Q3E_VR_StartEngineThread(void);
void Q3E_VR_RequestEngineStop(void);
void Q3E_VR_FinishEngineStop(void);
int  Q3E_VR_EngineThreadRunning(void);
int  Q3E_VR_OnEngineThread(void);

// --- tunables ---------------------------------------------------------------
// Game units per metre. Console-only (`q3evrscale`) by design: world scale and
// player height must not both be knobs. Quake 3's standing eye is 50 units
// (DEFAULT_VIEWHEIGHT 26 + |MINS_Z| 24), so 32 u/m puts the camera at ~1.56 m.
extern float q3e_vrWorldScale;
extern float q3e_vrRenderScale;      // per-eye supersample of the physical texture

// --- present-mode arbitration ----------------------------------------------
// A VR world frame is only correct while the player is IN the world. Everything
// else (menus, console, loading, demos, cinematics) goes to the flat panel shown
// inside the VR space. Which TERM failed is recorded, because "working as
// designed and indistinguishable from broken is a defect".
typedef enum {
    Q3E_VRP_WORLD = 0,          // a real per-eye world frame
    Q3E_VRP_NOT_VR,             // not in VR mode at all
    Q3E_VRP_NOT_ACTIVE,         // cls.state != CA_ACTIVE
    Q3E_VRP_UI,                 // KEYCATCH_UI — a menu is up
    Q3E_VRP_CONSOLE,            // KEYCATCH_CONSOLE
    Q3E_VRP_DEMO,               // clc.demoplaying
    Q3E_VRP_CINEMATIC,          // CA_CINEMATIC (RoQ)
    Q3E_VRP_NO_EYES,            // the engine has not produced an eye pair yet
    Q3E_VRP_NOT_ARMED,          // eye imagery exists, but the engine's VR path is
                                // not armed yet (no pose composition / VR frustum),
                                // so it is flat stereo and must never be the world
    Q3E_VRP_COUNT
} q3e_vr_reason_t;
const char *Q3E_VR_PresentReasonString(int reason);

// Sampled on the engine thread (where reading client state is correct) and
// published for the compositor loop. Returns the reason code.
int  Q3E_VR_SampleClientState(void);

// R4.4 — the VR cvar invariant. `r_stereo3d 1` (the eye path's gate, a cvar the
// SHELL creates, so CVAR_USER_CREATED) and `cg_draw3dIcons 0` are not one-shot
// entry commands: `game_restart` runs Cvar_Restart(qtrue), which unsets exactly
// those two classes of cvar, and the eye pairs then stop for the rest of the
// session. Armed by the entry, disarmed by the teardown, re-asserted at the top
// of every engine frame in between. Both calls are engine-thread work.
void Q3E_VR_ArmCvarInvariant(int on);
void Q3E_VR_RearmCvarInvariant(void);
extern int q3e_vrRearmHook;                // 0 = pre-R4.4 behaviour (`q3evrrearm 0`)

// --- state published by the VR loop, read by the dumps ----------------------
extern volatile int q3e_vrPresentWorld;    // 1 = per-eye world frame, 0 = panel
extern volatile int q3e_vrPresentReason;   // q3e_vr_reason_t — the loop's verdict
extern volatile int q3e_vrClientReason;    // q3e_vr_reason_t — the engine's terms only
extern volatile int q3e_vrViews;           // drawable view count (1 in the sim)
extern volatile int q3e_vrEyePhysW,  q3e_vrEyePhysH;   // PHYSICAL colour texture
extern volatile int q3e_vrEyeLogW,   q3e_vrEyeLogH;    // LOGICAL viewport
extern volatile int q3e_vrEngineW,   q3e_vrEngineH;    // engine per-eye extent
extern volatile int q3e_vrDepthWanted, q3e_vrDepthLive; // depth export state
extern volatile int q3e_vrDepthCopies;
extern volatile int q3e_vrTracked;         // the device anchor answered
extern volatile int q3e_vrDropped;         // frames the compositor withheld
extern volatile int q3e_vrRepresents;      // previous pair re-presented (shell timeout)
extern volatile int q3e_vrEngineTimeouts;  // engine waited out its 20 ms
extern volatile long q3e_vrPubId;          // pose pair published by the compositor
extern volatile long q3e_vrRenderedId;     // pose pair the engine last rendered
extern float q3e_vrHeadPos[3];             // metres, tracking space
extern float q3e_vrHeadYaw, q3e_vrHeadPitch, q3e_vrHeadRoll;   // degrees
// Head height in ORIGIN space (metres). q3e_vrHeadPos is relative to the
// captured base and is therefore ~0 for a player standing where they entered —
// useless as a height to calibrate FROM.
extern float q3e_vrHeadOriginY;
extern float q3e_vrEyeOrigin[2][3];        // per-eye game-space origin (units)
extern float q3e_vrEyeTangents[2][4];      // l, r, b, t per eye
// R4.8: the LEFT eye's forward, UP component, as published to the renderer. The
// one number that says whether the CAMERA pitched — the eye axes are otherwise
// invisible to every dump, and "the world pitches with the stick" was a claim no
// instrument in this port could state. sin(world pitch) with a level head.
extern float q3e_vrEyeFwdUp;

// --- movement, turn, height (R1) --------------------------------------------
// Which yaw the stick's forward means. AIM_HAND / OFF_HAND are named but resolve
// to HEAD until there are hands to read them from — see Q3E_VR_PublishMoveBasis.
typedef enum {
    Q3E_VRMOVE_HEAD = 0,
    Q3E_VRMOVE_AIM_HAND,
    Q3E_VRMOVE_OFF_HAND,
    Q3E_VRMOVE_OFF
} q3e_vr_movebasis_t;

typedef enum {
    Q3E_VRTURN_SMOOTH = 0,
    Q3E_VRTURN_SNAP30,
    Q3E_VRTURN_SNAP45,
    Q3E_VRTURN_SNAP60,
    Q3E_VRTURN_OFF
} q3e_vr_turnmode_t;

// --- 2D layer (R2 item 4) ----------------------------------------------------
// Whether the head-locked HUD is drawn at all. R3.2 item 4 replaces the old
// High/Low pair: WHERE the HUD sits is the HUD Height slider's job now, so the
// row that used to choose between two fixed anchors has nothing left to say
// except on or off. Off means no head-locked HUD quad draws in a world frame —
// the scoreboard/death overlay still shows, because that is not the HUD.
typedef enum {
    Q3E_VRHUD_ON = 0,
    Q3E_VRHUD_OFF
} q3e_vr_hudpos_t;

// Quake 3's standing eye above the floor, derived rather than spelled: the game
// QVM's DEFAULT_VIEWHEIGHT (26) above the origin, with the player box's MINS_Z
// (-24) below it. bg_public.h carries both.
#define Q3E_VR_CHARACTER_EYE_U  (26.0f + 24.0f)
#define Q3E_VR_HEIGHT_MIN_M     0.60f
#define Q3E_VR_HEIGHT_MAX_M     2.60f
#define Q3E_VR_TRIM_LIMIT_M     0.50f

// The one gate for each. NaN-affirmative: only finite, in-range values pass.
int  Q3E_VR_HeightBaselineOK(float metres);
int  Q3E_VR_HeightTrimOK(float metres);

extern int   q3e_vrMoveBasis;
extern int   q3e_vrTurnMode;
extern float q3e_vrTurnSpeed;        // degrees per second, smooth mode
extern float q3e_vrLastSnap;         // degrees of the last snap that fired
extern int   q3e_vrSnapCount;
extern float q3e_vrHeightBaseline;   // metres, standing eye height, captured once
extern float q3e_vrHeightTrim;       // metres, player trim, +/- 0.5
extern int   q3e_vrHeightValid;
extern float q3e_vrGammaInv;         // the engine's live 1/r_gamma
extern float q3e_vrOverbright;       // the engine's live 1 << overbrightBits
// R3.1 item 3: the smallest depth the eye blit hands the compositor for a pixel
// that has colour. Sky is drawn at exactly 0 under reverse-Z, which is the same
// value as "nothing rendered here" — see the eye fragment shader's comment for
// the whole mechanism. Live-tunable so the fix can be switched off on glass.
extern float q3e_vrEyeDepthFloor;
extern float q3e_vrXhairSize;        // aim marker angular size, NATIVE units 0.5..1.5
extern int   q3e_vrXhairOn;          // VR Crosshair row: 0 hides the marker entirely
// R4.3, the three donor-parity rows deferred in D-VR-R3.2. Show Hands is a
// SwiftUI scene property, Sharpen is a fraction consumed by the per-eye blit,
// and Damage Flash gates a draw inside the renderer (overlay patch 0022).
extern int   q3e_vrShowHands;        // Show Hands row: 1 = real forearms visible
extern float q3e_vrSharpen;          // Sharpen row: 0..1 fraction (the row shows %)
extern int   q3e_vrDamageFlash;      // Damage Flash row: 1 = draw the blood blend
extern int   q3e_vrHudPos;           // q3e_vr_hudpos_t
// The head-locked 2D layout's two independent controls. Size is each quad's own
// angular extent (R3.1 item 2); Height is how far up or down the whole cluster
// is placed (R3.2 item 2 — it replaces R3.1's Panel Size spread multiplier,
// which the device round read as a position control and wanted to be one).
extern float q3e_vrHudSize;          // 0.8 .. 2.0, element size
extern float q3e_vrHudHeight;        // degrees, -15 .. +15, cluster pitch offset

// --- hands (R3) --------------------------------------------------------------
// Which hand aims. The other is the off hand; both are named by the settings row
// and by every dump, so "aim hand" is never a guess about handedness.
#define Q3E_VR_HAND_LEFT  0
#define Q3E_VR_HAND_RIGHT 1

// Where the aim came from THIS frame. Head aim (Convenience Mode) is the
// automatic fallback whenever the aim hand is not tracked — arbitration is
// continuous, and both sides of it are published so the sim can assert which one
// ran rather than infer it.
typedef enum {
    Q3E_VRAIM_HEAD = 0,
    Q3E_VRAIM_HAND,
    Q3E_VRAIM_PAD
} q3e_vr_aimsource_t;

// --- gamepad aim (R4.6, corrected in R4.7) -----------------------------------
// The "Aiming" settings row: whether the aim follows the GAZE (the R2
// Convenience Mode this port shipped with) or an ordinary gamepad's right
// stick. Only the row's two states — the aim SOURCE that actually runs is
// q3e_vr_aimsource_t above, and a tracked aim hand still outranks both.
//
// R4.7: "Gamepad" means what it means in the flat game — the stick TURNS THE
// VIEW, and the crosshair sits at the centre of the game's forward direction.
// R4.6 shipped a ±40 degree cone the aim wandered inside instead, which made
// aiming at a thing a two-step move (push the crosshair to the edge to turn,
// then bring it back); that design is SUPERSEDED, see D-VR-R4.7.
typedef enum {
    Q3E_VRAIMMODE_HEAD = 0,
    Q3E_VRAIMMODE_PAD
} q3e_vr_aimmode_t;

extern int   q3e_vrAimMode;          // q3e_vr_aimmode_t, the "Aiming" row
extern int   q3e_vrPadAimEnabled;    // fault injection: `q3evrpadaim 0`
// The stick's own aim, in the recentred BASE frame and the same ARKit
// convention the head and the hands use (degrees, pitch positive = up), so the
// arbitration in Q3EVR.m can hand it to the eye composition and to
// Q3E_VR_PublishHeadAim without a second set of rules.
// R4.7: the YAW is pinned to ZERO — the aim is the BODY's forward direction,
// and the stick moves the body itself (cl_vr_turn_pending) rather than an offset
// from it. Published all the same, because "the stick aim is body forward" is an
// invariant a dump can state and the suite can watch fail.
// R4.8: the PITCH is the WORLD's, not an offset either — the compositor applies
// this exact angle to the published eye pose (Q3EVR.m, `worldPitch`), so the
// camera pitches with the aim and the crosshair is at the view centre on both
// axes. Still ARKit convention here (positive = up); Q3E_VR_PublishHeadAim is
// the one seam that flips it into Quake's.
extern float q3e_vrPadAimYaw, q3e_vrPadAimPitch;
extern float q3e_vrPadAimTurn;       // degrees of body turn the last frame asked for
extern int   q3e_vrPadAimSeeded;     // 0 = no aim yet, fall back to the head
// The pitch the stick may reach. Yaw has no bound at all in R4.7 — turning the
// body is continuous and wraps, exactly as it does in the flat game. Pitch stops
// short of the engine's own +/-87.89 limit for the same reason the flat game
// does: the last couple of degrees are angles nothing can aim at.
#define Q3E_VR_PADAIM_PITCH_LIMIT  85.0f
// Degrees per second at full stick deflection, before the Look sensitivity rows
// scale it (the pad layer applies those, exactly as it does for flat look).
#define Q3E_VR_PADAIM_SPEED      140.0f

extern int   q3e_vrAimHand;          // Q3E_VR_HAND_LEFT / _RIGHT, settings row
extern int   q3e_vrHandAimEnabled;   // fault injection: `q3evrhandaim 0`
extern float q3e_vrAimPitchTrim;     // degrees, +/-10, hand aim only
// The built-in neutral, and R3.6 takes it back to ZERO. R3.4 baked in +2 because
// the device round kept dialling that in; the round after it, with the trim
// measured from that +2, kept arriving at -2 — the same aim, reached from the
// other side. Two rounds agreeing that the answer is the raw controller axis is
// the answer: the bias is 0, the trim's zero is the hardware's own forward, and
// the row still travels +/-10 either side of it for anyone whose wrist disagrees.
// Kept as a named constant rather than deleted so the ONE place the aim path
// could acquire an offset stays one place with a number in it.
#define Q3E_VR_AIM_PITCH_BIAS 0.0f
extern int   q3e_vrHaptics;          // Controller Haptics settings row
// Weapon Size settings row, NATIVE units 0.375 .. 1.875 (the row displays these
// divided by the shipped 0.75, so 0.50x .. 2.50x — R4.0, display mapping only).
extern float q3e_vrGunScale;
// Where the weapon sits in the hand. Offsets in game units along the hand's own
// forward/right/up; angles in degrees. R4.0: all six are HARDCODED — no sheet
// row, no stored key, no migration path into them. The shipped values are the
// initialisers in Q3EVRGlue.c (f-6.0 r-0.5 u0, p0 y0 r0); `q3evrgrip` overrides
// them for the current session only.
extern float q3e_vrGrip[3];          // forward, right, up
extern float q3e_vrGripAngles[3];    // pitch, yaw, roll — all zero as shipped

// Published by the compositor each frame, read by the dumps and the engine-side
// consumers. Angles are in the recentred BASE frame, degrees, ARKit convention
// (pitch positive = pointing up) — exactly like q3e_vrHeadYaw/Pitch, and
// converted into Quake's convention at the one seam that hands them to the
// engine (Q3E_VR_PublishHeadAim).
extern volatile int q3e_vrHandTracked;    // bit 0 = left posed, bit 1 = right posed
extern volatile int q3e_vrHandHeld;       // same bits, ARKit "in a hand"
extern volatile int q3e_vrHandPresent;    // same bits, a controller is assigned
extern volatile int q3e_vrAimSource;      // q3e_vr_aimsource_t, this frame
extern volatile int q3e_vrAimSourceSwaps; // how many times it has changed
extern float q3e_vrHandYaw[2], q3e_vrHandPitch[2];
extern float q3e_vrHandPos[2][3];         // body-frame position, game units
extern float q3e_vrAimYaw, q3e_vrAimPitch;

// Compositor -> engine, once per rendezvous frame. `buttons` is the level;
// edges are accumulated by Q3ESense.m's single detector, never here.
void Q3E_VR_PublishHands(void);
// Everything the hands own, dropped: called at VR exit and on the doff path so
// no pose, button or latch survives a session boundary.
void Q3E_VR_ResetHands(void);

// Re-capture the yaw-only base the whole alignment hangs off, without moving
// the calibrated height. The aim-hand stick click asks for this in VR.
void Q3E_VR_Recenter(void);

void Q3E_VR_PublishMoveBasis(void);
void Q3E_VR_PublishHeadAim(void);    // R2/R3: writes the ACTIVE aim source's
                                     // yaw/pitch for CL_VRApplyHeadAim
void Q3E_VR_PublishHeight(void);
int  Q3E_VR_CaptureHeight(float metres);   // 0 = refused by the sanity gate
int  Q3E_VR_ConsumeTurnAxis(float x, float dt);
// R4.6/R4.7 — the gamepad-aim seam, called from the pad layer with the SAME
// curved, sensitivity-scaled axis pair the flat look path builds. X turns the
// BODY (through the same cl_vr_turn_pending accumulator the turn stick uses), Y
// pitches the aim; the aim yaw itself stays at the body's forward. Returns 1
// when it took the stick, which is how the pad layer knows not to hand the same
// axis to the turn seam or to the mouse-look path as well.
int  Q3E_VR_ConsumePadAim(float ax, float ay, float dt);
// Whether the stick is aiming RIGHT NOW: in VR, the row set to Gamepad, the hook
// enabled, and no tracked aim hand (hand aim outranks the row, unchanged).
int  Q3E_VR_PadAimActive(void);
// Forget the accumulator, so the next active frame starts the aim at the gaze.
void Q3E_VR_PadAimReseed(void);
// Is an ORDINARY (non-spatial) gamepad connected? The "Aiming" row is only shown
// when it is — the pad layer's own spatial filter is the discriminator, so this
// answers from the same GCController scan that decides which device drives the
// pad (ios_input.m), and `q3evrpad` can force an answer where the simulator has
// no controllers at all.
int  Q3E_VR_PlainPadConnected(void);

// --- quiet setters (R2.1 fix 6/12) ------------------------------------------
// Same underlying state the q3evr* console commands change, reached WITHOUT
// their console dispatch or their dump+NOWSEQ+black-box-flush tail — that
// tail is harness overhead a settings-sheet slider drag never asked for (a
// drag fires its `-changed` handler dozens of times a second). The q3evr*
// commands stay the harness's and the console/ornament's entry point and
// keep their diagnostics; the sheet applies through these instead.
void Q3E_VR_SetRenderScaleQuiet(float s);    // R3.3: 1.0 .. 2.0
void Q3E_VR_SetXhairSizeQuiet(float s);
void Q3E_VR_SetXhairOnQuiet(int on);         // R3.2 item 7: donor's VR Crosshair row
void Q3E_VR_SetShowHandsQuiet(int on);       // R4.3 item 1
void Q3E_VR_SetSharpenQuiet(float f);        // R4.3 item 2: 0 .. 1
void Q3E_VR_SetDamageFlashQuiet(int on);     // R4.3 item 3
void Q3E_VR_SetHudPosQuiet(int pos);         // q3e_vr_hudpos_t
void Q3E_VR_SetHudSizeQuiet(float s);        // R3.1: 0.8 .. 2.0, element size
void Q3E_VR_SetHudHeightQuiet(float deg);    // R3.2: -15 .. +15 degrees
// R4.0: the grip is six constants and the settings sheet has no row for it, so
// the quiet setter this line used to declare had no caller left that was not
// passing values it ignored. What replaces it is the SESSION-ONLY override
// behind `q3evrgrip` — clamped, never persisted, never consulted by a boot or
// sheet path. See its definition in Q3EVRGlue.c.
void Q3E_VR_SetGripOverride(const float offsets[3], const float angles[3]);
void Q3E_VR_SetTurnQuiet(int mode, float speedDegPerSec);   // q3e_vr_turnmode_t
void Q3E_VR_SetAimModeQuiet(int mode);       // R4.6: q3e_vr_aimmode_t, the "Aiming" row
// The ONE persisted store for the height trim (metres) — also readable before
// VR has ever been entered this process (the sheet needs a value to show;
// the engine's own restore-at-entry only runs once VR opens). The setter IS
// the quiet path for this value: it updates the live engine global, publishes
// it (a no-op outside VR) and persists it, with no console dispatch and no
// dump.
float Q3E_VR_GetPersistedHeightTrimMetres(void);
void  Q3E_VR_SetPersistedHeightTrimMetres(float metres);
int   Q3E_VR_HasPersistedHeightTrim(void);   // for the one-time DEF_VR_HEIGHT migration
// Console/ornament write-back (R2.1 fix 6b): called by the q3evrturn/
// q3evrhud/q3evrrenderscale/q3evrxhairsize command handlers so a live console
// or ornament change is reflected in NSUserDefaults — otherwise the sheet's
// own stale stored value clobbers it back on the next ApplyAll. Implemented
// in ios_settings.m (Foundation-side); declared here as the shared contract.
void Q3E_VR_PersistTuning(void);
// R3.2 item 5: re-negotiate the per-eye render extent for the LIVE VR session
// (AppShell_vision.m). A no-op outside VR — the entry path applies the scale
// there — and coalesced, so a slider drag costs one renderer restart.
void Q3E_VR_ReapplyRenderScale(void);
// R2.2 fix 4: the same write-back carried one step further, into an OPEN
// settings sheet's widgets. Without it the store and the widgets disagree for
// as long as the sheet stays up, and the next change to ANY row writes the
// stale widget values back over the console's. Also in ios_settings.m; safe to
// call from any thread (it hops to the main queue) and a no-op when no sheet is
// on screen.
void Q3E_VR_SettingsSheetSync(void);

// Geometry of the two quads the loop places, for the dumps.
void Q3E_VR_PanelGeometry(float *dist, float *halfW, float *halfH, float *aspect);
void Q3E_VR_UIGeometry(float *dist, float *halfW, float *halfH);
int  Q3E_VR_StaleAnchorFrames(void);
int  Q3E_VR_UICopies(void);
int  Q3E_VR_UIVerticalLatched(void);
extern volatile int q3e_vrUIQuadDrawn;     // the head-locked UI quad was drawn
// R2.1 fix 7/11: what the last frame's 2D-layer placement actually decided,
// published so the suite can assert it rather than infer it from pixels.
extern volatile int q3e_vrRegionsDrawn;    // how many of the 4 dedicated region quads drew
extern volatile int q3e_vrExclCount;       // exclusion rects fed to the fallback quad
extern volatile int q3e_vrScoreboardUp;    // Q3E_VR_ScoreboardLikely(), sampled this frame
extern float q3e_vrNotifyRows;             // NOTIFY source rect height, virtual rows
extern float q3e_vrMessageRows;            // MESSAGE source rect height, virtual rows
// R3.2 item 3: the STATUSBAR band grew upward to take in the whole lower HUD
// cluster, and its pitch is derived rather than fixed — both are published so
// the suite asserts the geometry the loop used instead of re-deriving it.
extern float q3e_vrStatusRows;             // STATUSBAR source rect height, virtual rows
extern float q3e_vrStatusTopRow;           // ...and its top edge, virtual rows
extern float q3e_vrStatusPitch;            // STATUSBAR quad centre pitch, degrees
extern float q3e_vrXhairBoxCX, q3e_vrXhairBoxCY, q3e_vrXhairBoxHalf;   // crosshair source box, px
// PM_DEAD / PM_INTERMISSION / PM_SPINTERMISSION, and — since R4.2 item 2 — the
// interactive hold-TAB scoreboard as well, via the +scores/-scores commands the
// engine itself dispatches to the cgame (patch 0021).
int  Q3E_VR_ScoreboardLikely(void);
extern volatile int q3e_vrScoresHeld;      // the +scores hold, as the sampler saw it
// Fault injection for the hold (R4.2 item 3), NOT dev-gated: the suite runs the
// PUBLIC build, and a toggle the public build does not carry cannot produce the
// red case for the assertion that depends on it (the q3evranchor precedent).
extern int q3e_vrScoresHoldHook;           // 1 = the hold counts, 0 = R4.1 behaviour
// The crosshair region's source box, read from the ACTUAL cg_crosshairSize/X/Y
// cvars rather than a fixed 64px guess (R2.1 fix 7) — sized generously (the
// pickup-pulse doubles cg_crosshairSize) rather than pixel-exactly, since the
// exact QVM draw math is not this engine's to know.
void Q3E_VR_GetCrosshairCvars(float *size, float *x, float *y);
// Test-only fault injection (R2.1 fix 11): force the fallback/scoreboard
// pipeline to be treated as missing, so the degrade-to-region-pipeline path
// can be proven to actually show content rather than trusted on inspection.
void Q3E_DebugKillFallbackPipeline(int on);
void Q3E_VR_PersistHeight(void);
void Q3E_VR_ClearHeightBaseline(void);     // settings Reset (R2 item 6)
// One pixel of the UI layer as the compositor samples it, alpha included.
void Q3E_VR_RequestUIPixel(int x, int y, int count);
int  Q3E_VR_ReadUIPixel(float out[4], float *maxAlpha, int *covered, int *sampled);

// --- synthetic injection (simulator) ---------------------------------------
// Injected at the OUTPUT boundary of the real pose path, so the real transform
// chain runs. `q3evrhand`/`q3evrhandbtn`/`q3evrhandstick` are reserved for the
// Sense round and deliberately not registered yet.
// `q3evrhand`/`q3evrhandbtn`/`q3evrhandstick` inject at Q3E_Sense_Poll's OUTPUT
// (Q3ESense.m), so the real transform chain and the real input code run.
extern volatile int q3e_vrSynthPose;       // 1 = q3evrpose is driving the head
extern float q3e_vrSynthYaw, q3e_vrSynthPitch;
extern float q3e_vrSynthPos[3];
extern float q3e_vrSynthIPD;               // metres; synthesises a stereo pair on
                                           // the simulator's single-view drawable
extern float q3e_vrSynthTurnAxis;          // held turn-stick deflection (simulator)
extern int   q3e_vrSynthTurnMs;            // Sys_Milliseconds deadline for that hold
// R4.6. The simulator has no controllers, so both halves of gamepad aim need an
// injection point: the STICK (held, for the same reason the turn stick is held —
// a zero between two one-shots re-arms everything downstream) and the mere fact
// that a plain pad is CONNECTED, which is what the settings row's visibility
// hangs off.
extern float q3e_vrSynthPadX, q3e_vrSynthPadY;
extern int   q3e_vrSynthPadMs;             // Sys_Milliseconds deadline for that hold
extern int   q3e_vrSynthPadConn;           // -1 = ask the real controllers, 0/1 = forced
extern volatile int q3e_vrSynthTanOn;      // override the recovered eye tangents
extern float q3e_vrSynthTan[4];            // left, right, bottom, top

// --- diagnostics ------------------------------------------------------------
// Registered after Com_Init, from the shell — no engine patch is involved.
void Q3E_VR_RegisterCommands(void);

#ifdef __cplusplus
}
#endif
