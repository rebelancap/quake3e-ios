// ios_settings.m — the in-app iOS settings sheet (charter Phase 2 item,
// scoped deliberately: gyro aim, FPS counter, touch look
// sensitivity, refresh rate). Long-press the ≡ button to open.
//
// These are SHELL settings (NSUserDefaults), deliberately not engine
// cvars: they configure the iOS layer itself. Engine-side options keep
// living in the stock SETUP menus.

#import <UIKit/UIKit.h>
#import "ios_settings.h"
#import "ios_audio.h"

// appliers (ios_input.m / AppShell.m)
void Q3E_Input_SetGyro(int enabled, float scale);
void Q3E_Input_SetTouchSens(float sx, float sy);
void Q3E_Input_SetControlStyle(float scale, float alpha);
void Q3E_EnableConsoleBridge(void);   // ios_glue.c — opens the port AND arms the drain
void Q3E_Input_BeginLayoutEdit(void);
void Q3E_Shell_SetRefreshMode(int mode60);  // 0 = native/120, 1 = 60
void Q3E_Shell_SetFPSCounter(int enabled);
void Q3E_Input_SetFireHaptics(int on);       // haptic tap on fire (ios_input.m)
void Q3E_QueueCommand(const char *cmd);      // push a console command to the engine
#if TARGET_OS_VISION
void  VK_Set3DSeparation(float sep);         // stereo parallax divisor (renderervk 0006)
void  Q3E_Set3DPanel(float dist, float halfW); // 3D screen distance/size (Q3EImmersive.m)
void  Q3E_Set3DHeight(float h);              // 3D screen height + auto-tilt
void  Q3E_Set3DHideGun(int on);              // hide the weapon in 3D (AppShell_vision.m)
void  Q3E_Set3DHideHead(int on);             // flatten the HUD 3D head in 3D
void  Q3E_Set3DDim(float d);                 // surroundings dimming (Q3EImmersive.m)
void  Q3E_Set3DBrightness(float gamma);      // 3D panel brightness (Q3EImmersive.m shader)
// Vision Pro VR (R2 item 6) — mode switch and the height-baseline clear a
// Reset also performs. Q3E_VR_SettingsDumpString (the SETTINGSNOW builder) is
// DEFINED below in this file; Q3EVRGlue.c externs it directly for the
// `q3evrsettingsdump` command, the same lightweight cross-file pattern the
// rest of this dump family already uses (no header round-trip needed).
void  Q3E_EnterMode(int mode);               // AppShell_vision.h; 2=Q3E_MODE_VR
int   Q3E_GetMode(void);                     // Q3EVR.h; 2==Q3E_MODE_VR
void  Q3E_VR_ClearHeightBaseline(void);      // Q3EVR.h
// R2.2 fix 4: refresh an OPEN settings sheet's VR widgets from the store.
// Defined at the bottom of this file, next to the sheet it refreshes; declared
// here because Q3E_VR_PersistTuning (above the sheet's own @implementation)
// calls it, and because Q3EVR.m's height persist calls it too.
void  Q3E_VR_SettingsSheetSync(void);
// R2.1 fixes 6/9/12 — the quiet-setter / single-store / capture-check seam
// (Q3EVRGlue.c + Q3EVR.m), declared here rather than importing the whole of
// Q3EVR.h to keep this file's existing per-symbol extern style.
void  Q3E_VR_SetRenderScaleQuiet(float s);
void  Q3E_VR_SetXhairSizeQuiet(float s);
void  Q3E_VR_SetHudPosQuiet(int pos);
void  Q3E_VR_SetHudSizeQuiet(float s);
void  Q3E_VR_SetHudHeightQuiet(float deg);
void  Q3E_VR_SetXhairOnQuiet(int on);
// R4.3, the three donor-parity rows D-VR-R3.2 deferred.
void  Q3E_VR_SetShowHandsQuiet(int on);
void  Q3E_VR_SetSharpenQuiet(float f);
void  Q3E_VR_SetDamageFlashQuiet(int on);
void  Q3E_VR_SetTurnQuiet(int mode, float speedDegPerSec);
// R3 (hands). Plain globals rather than quiet setters: none of them is a
// magnitude the engine re-derives anything from, and each is read where it is
// used, so there is nothing for a setter to keep coherent.
extern int   q3e_vrAimHand;        // Q3E_VR_HAND_LEFT / _RIGHT
extern int   q3e_vrHaptics;
extern float q3e_vrAimPitchTrim;   // degrees, +/-15
extern float q3e_vrGunScale;       // 0.5 .. 2.0
extern float q3e_vrGrip[3];
extern float q3e_vrGripAngles[3];
extern int   q3e_vrMoveBasis;      // q3e_vr_movebasis_t
// R4.6 (gamepad aim). The row is an ENUM with a live consequence — switching it
// changes which source the compositor arbitrates to on the very next frame — so
// it applies through a quiet setter (which also forgets the stale accumulator),
// exactly like the HUD position and the turn mode.
extern int   q3e_vrAimMode;        // q3e_vr_aimmode_t
void  Q3E_VR_SetAimModeQuiet(int mode);
// Whether an ORDINARY (non-spatial) gamepad is connected — the one question this
// sheet asks to decide whether the Aiming row belongs on screen at all.
int   Q3E_VR_PlainPadConnected(void);
void  VK_SetVRGun(int aimHand, float scale, const float grip[3], const float gripAngles[3]);
// Q3ESense.h's hardware layer. R4.5 removed the sheet's INVENTORY line ("Sense:
// 2 Pads, 2 spatial ..."), which the maintainer read as clutter; what is left is the one
// question the sheet has to answer to lay itself out — is anything paired — which
// decides whether Aim Pitch Trim can mean anything. The inventory strings live on
// in `q3evrsense` / `q3evrhandnow`, where a diagnostic belongs.
int   Q3E_Sense_Connected(void);
float Q3E_VR_GetPersistedHeightTrimMetres(void);
void  Q3E_VR_SetPersistedHeightTrimMetres(float metres);
int   Q3E_VR_HasPersistedHeightTrim(void);
int   Q3E_VR_HeightBaselineOK(float metres);   // Q3EVR.h — the same sanity gate q3evrcalibrate uses
extern float q3e_vrHeadOriginY;                // Q3EVR.h — head height in ORIGIN space
// R2.2 fix 12: the LIVE engine values, read back after every apply so the
// sheet's cache and its store record what the engine actually took rather than
// what it was asked for — the two differ whenever a value had to be clamped.
extern float q3e_vrRenderScale, q3e_vrXhairSize, q3e_vrTurnSpeed, q3e_vrHeightTrim;
extern float q3e_vrHudSize, q3e_vrHudHeight;
extern int   q3e_vrTurnMode, q3e_vrHudPos, q3e_vrXhairOn;
extern int   q3e_vrShowHands, q3e_vrDamageFlash;
extern float q3e_vrSharpen;          // 0..1 fraction; the row reads percent
// R3.2 item 5: a Render Quality change now reaches the live session instead of
// waiting for the next VR entry (AppShell_vision.m).
void  Q3E_VR_ReapplyRenderScale(void);
#endif

#define DEF_GYRO_ON     @"q3e_gyro_on"
#define DEF_GYRO_SCALE  @"q3e_gyro_scale"
#define DEF_TOUCH_SENS  @"q3e_touch_sens" // legacy single-axis key
#define DEF_SENS_X      @"q3e_sens_x"
#define DEF_SENS_Y      @"q3e_sens_y"
#define DEF_CTL_SCALE   @"q3e_ctl_scale"
#define DEF_CTL_ALPHA   @"q3e_ctl_alpha"
#define DEF_LEFTY       @"q3e_lefty"
#define DEF_REFRESH_60  @"q3e_refresh_60"
#define DEF_FPS_COUNTER @"q3e_fps_counter"
#define DEF_REMOTE_CONSOLE @"q3e_remoteConsole"

// Read at boot by ios_glue.c. DEV BUILDS ONLY — a public release must never ship
// a way to open an unauthenticated engine command port from the UI. The gate is
// derived from the version scheme in publish-ota.sh, not set by hand.
int Q3E_RemoteConsoleEnabled(void) {
#ifdef Q3E_DEV_BUILD
    return [NSUserDefaults.standardUserDefaults boolForKey:DEF_REMOTE_CONSOLE] ? 1 : 0;
#else
    return 0;
#endif
}
#define DEF_INVERT      @"q3e_invert_look"
#define DEF_FIRE_HAPTIC @"q3e_fire_haptic"
#define DEF_SND_VOL     @"q3e_snd_vol"
#define DEF_MUS_VOL     @"q3e_mus_vol"
#define DEF_MSAA        @"q3e_msaa"
#define DEF_XHAIR_SIZE  @"q3e_xhair_size"
#define DEF_XHAIR_STYLE @"q3e_xhair_style"
#define DEF_FOV         @"q3e_fov"
#define DEF_BRIGHTNESS  @"q3e_brightness"
#define DEF_ALWAYS_RUN  @"q3e_always_run"
#define DEF_AUTOSWITCH  @"q3e_autoswitch"
#define DEF_SIMPLEITEMS @"q3e_simpleitems"
#define DEF_HIDEGUN_3D  @"q3e_hidegun_3d"
#define DEF_HIDEHEAD_3D @"q3e_hidehead_3d"
#define DEF_DEPTH_3D    @"q3e_depth_3d"     // depth multiplier (higher = more parallax)
#define DEF_DIST_3D     @"q3e_dist_3d"      // panel distance (m)
#define DEF_SIZE_3D     @"q3e_size_3d"      // panel half-width (m)
#define DEF_HEIGHT_3D   @"q3e_height_3d"    // panel height above eye (m, + auto-tilt)
#define DEF_UNITS_FT    @"q3e_units_ft"     // display panel measurements in feet
#define DEF_FOCUS_3D    @"q3e_focus_3d"     // stereo convergence plane (r_zproj, game units)
#define DEF_DIM_3D      @"q3e_dim_3d"       // surroundings dimming (0..1, perceptual curve)

// Vision Pro VR (R2 item 6). Keys prefixed q3e_vr_ per charter D11 — a
// DIFFERENT prefix from the q3e_*_3d keys above on purpose: VR and the 3D
// panel are separate modes with separate defaults, and a shared prefix would
// invite a future edit to touch the wrong section's row.
#define DEF_VR_HEIGHT       @"q3e_vr_height"        // RETIRED (see the v2 migration)
#define DEF_VR_RENDERSCALE  @"q3e_vr_renderscale"   // 1.0-2.5x
#define DEF_VR_SNAPTURN     @"q3e_vr_snapturn"      // 0=Smooth 1=30 2=45 3=60
#define DEF_VR_TURNSPEED    @"q3e_vr_turnspeed"     // 60-260 deg/s, smooth mode
#define DEF_VR_XHAIRSIZE    @"q3e_vr_xhairsize"     // 0.5-1.5x NATIVE (row shows 1-5x)
#define DEF_VR_XHAIRON      @"q3e_vr_xhairon"       // VR Crosshair row: 0/1
// R4.3 (donor parity, D-VR-R3.2's deferral table).
#define DEF_VR_SHOWHANDS    @"q3e_vr_showhands"     // Show Hands row: 0/1
#define DEF_VR_SHARPEN      @"q3e_vr_sharpen"       // 0..1 fraction (row: 0-100%)
#define DEF_VR_DAMAGEFLASH  @"q3e_vr_damageflash"   // Damage Flash row: 0/1
#define DEF_VR_HUD          @"q3e_vr_hud"           // 0=On 1=Off (see the v5 migration)
#define DEF_VR_HUDSCALE     @"q3e_vr_hudscale"      // RETIRED (see the v4 migration)
#define DEF_VR_HUDSIZE      @"q3e_vr_hudsize"       // 0.8-2.0x, head-locked ELEMENT size
#define DEF_VR_PANELSIZE    @"q3e_vr_panelsize"     // RETIRED (see the v5 migration)
#define DEF_VR_HUDHEIGHT    @"q3e_vr_hudheight"     // -15..+15 degrees, HUD cluster pitch
#define DEF_VR_MIGRATION    @"q3e_vr_mig"           // migration stamp (see Q3E_VR_MigrateSettings)
// R3 (hands).
#define DEF_VR_AIMHAND      @"q3e_vr_aimhand"       // 0=Left 1=Right
#define DEF_VR_MOVEBASIS    @"q3e_vr_movebasis"     // 0=Head 1=Aim hand 2=Off hand 3=Off
// R4.6. A brand-new key with no predecessor, so there is deliberately no
// migration step for it (the v3 precedent): def_float's own fallback IS the
// correct behaviour for every store that has never seen it, and the stamp is
// left where R4.5 put it rather than bumped to announce a step that would do
// nothing.
#define DEF_VR_AIMMODE      @"q3e_vr_aimmode"       // 0=Head 1=Gamepad
#define DEF_VR_AIMTRIM      @"q3e_vr_aimtrim"       // degrees, +/-10, hand aim only
#define DEF_VR_GUNSCALE     @"q3e_vr_gunscale"      // 0.5-2.0x
#define DEF_VR_HAPTICS      @"q3e_vr_haptics"       // 0/1
// R3.2 item 6 stored the six grip values so the numbers the maintainer dialled on glass
// would survive the relaunch and become the shipped defaults. They have: R4.0
// hardcodes all six in Q3EVRGlue.c. ALL SIX KEYS ARE RETIRED — nothing writes
// them and nothing reads them, and they survive here only as the names the v11
// migration deletes from stores that ran 1.0.4.8 through 1.0.4.13.
#define DEF_VR_GRIP_F       @"q3e_vr_grip_f"        // RETIRED (see the v11 migration)
#define DEF_VR_GRIP_R       @"q3e_vr_grip_r"        // RETIRED
#define DEF_VR_GRIP_U       @"q3e_vr_grip_u"        // RETIRED
#define DEF_VR_GRIPANG_P    @"q3e_vr_gripang_p"     // RETIRED
#define DEF_VR_GRIPANG_Y    @"q3e_vr_gripang_y"     // RETIRED
#define DEF_VR_GRIPANG_R    @"q3e_vr_gripang_r"     // RETIRED

#define Q3E_VR_HEIGHT_DEFAULT      0.0f
// R3.3: 1.85, the value the device round settled on — and the range narrows to
// 1.00..2.00 with it. Below 1.0 the eye image was soft enough that nobody chose
// it, and above 2.0 the cadence halves; a slider whose ends are values no one
// wants is travel spent on nothing.
#define Q3E_VR_RENDERSCALE_DEFAULT 1.85f
#define Q3E_VR_SNAPTURN_DEFAULT    0.0f    // Smooth
#define Q3E_VR_TURNSPEED_DEFAULT   140.0f
// R3.1 item 1. The 1.0.4.6 device round called 1.5 too big and settled on 0.5,
// so 0.5 is the default and 1.5 is the ceiling. This is the value in the
// marker's NATIVE units — the same units the console command and the engine
// use; the ROW displays it remapped to 1x..5x (see the two helpers below),
// which is a display change only and never reaches the store.
// R3.4: 0.75 native, which the row shows as 2.0x — the size the device round
// settled on once the 1x..5x travel made the row placeable. The stored units and
// the 0.5..1.5 clamp are unchanged; only where the untouched install starts.
#define Q3E_VR_XHAIRSIZE_DEFAULT   0.75f
#define Q3E_VR_HUD_DEFAULT         0.0f    // On
#define Q3E_VR_XHAIRON_DEFAULT     1.0f
// R4.3 shipped all three at WHAT THE LAST BUILD DID, because none of them had
// been seen on glass yet: hands hidden under full immersion (the compile-time
// constant they replaced), no sharpening at all (a bit-exact pass-through in
// the blit), and the damage blend drawn the way every cgame has drawn it since
// 1999.
//
// R4.5: Sharpen has now been seen on glass, and 50% is the maintainer's verdict off
// the 1.0.4.15 build — the same number the donor ships. So the unmeasured
// default becomes a measured one, and the v12 migration deletes the stored key
// so the installs that ran R4.3 with the row untouched (a stored 0) land on it
// rather than keeping a default they never chose. Show Hands stays OFF and
// Damage Flash stays on; neither verdict moved.
#define Q3E_VR_SHOWHANDS_DEFAULT   0.0f
#define Q3E_VR_SHARPEN_DEFAULT     0.5f
#define Q3E_VR_DAMAGEFLASH_DEFAULT 1.0f
// R3.2 item 2. Zero is "where the layout puts it", which is the geometry the
// 1.0.4.7 device round approved; the slider moves the whole cluster off that.
// R3.3: -2 degrees. The cluster sat a touch high on glass; two degrees down is
// the trim the maintainer read back, and zero remains a legal position the slider can
// return to.
// R4.5: back to 0. The R3.3 trim was measured against a HUD layout that has
// moved twice since (R3.4's bands, R4.2's held scores), and the 1.0.4.15 round
// read the cluster as sitting low. Zero is the layout's own geometry, which is
// what the -2 was a correction to; the v12 migration deletes the stored key so
// an install that never touched the slider gets the new default instead of the
// old one frozen in its store.
#define Q3E_VR_HUDHEIGHT_DEFAULT   0.0f
// R3.1 item 2. R2.3's single 1.25 scaled BOTH the element sizes and the
// layout spread; these are the two halves of it, and both default to that
// same 1.25 so the out-of-box geometry is bit-for-bit the layout the 1.0.4.6
// round approved. The v4 migration seeds both from a stored q3e_vr_hudscale
// for anyone who moved the combined slider.
// R3.3: 1.1, not 1.25 — the R3.2 elements read oversized on glass. The range
// (0.8..2.0) is unchanged, so both the old value and everything either side of
// it stay reachable.
#define Q3E_VR_HUDSIZE_DEFAULT     1.1f
// R3 defaults, straight from charter D11's row inventory: the right hand aims,
// movement follows the HEAD (the option a player never has to think about), no
// aim trim until someone asks for one, weapons at their authored size, haptics
// on. 1 = Q3E_VR_HAND_RIGHT; spelled as a number here because Q3EVR.h's own
// constant is not visible at preprocessor time in this file's header block.
#define Q3E_VR_AIMHAND_DEFAULT     1.0f
#define Q3E_VR_MOVEBASIS_DEFAULT   0.0f
// R4.6: Head, which is what every build so far has done. A row that changes the
// picture by default is indistinguishable from a regression (the R4.3 rule), and
// gaze aim is also the only thing that works for a player with no pad at all.
#define Q3E_VR_AIMMODE_DEFAULT     0.0f
// Still zero, and R3.6 makes zero mean the controller's own forward axis again:
// Q3E_VR_AIM_PITCH_BIAS is back to 0 because the round that trimmed around the
// R3.4 +2 kept arriving at -2, which is the same aim from the other side. The
// v9 migration deletes a stored trim so that agreement actually lands. The row
// keeps its +/-10.
#define Q3E_VR_AIMTRIM_DEFAULT     0.0f
// R3.3: 0.75. "Authored size" is authored for a 2D screen a metre wide; in the
// headset, at arm's length, the weapon is simply too big. Range unchanged.
#define Q3E_VR_GUNSCALE_DEFAULT    0.75f
#define Q3E_VR_HAPTICS_DEFAULT     1.0f
// R4.0: THE GRIP HAS NO CONSTANTS HERE ANY MORE, and no rows, and no stored
// keys. the maintainer's verdict off R3.7's wide dialling row was a single number rather
// than a span — "-6.0 is right for all situations" — so the whole six-value set
// became hardcoded in Q3EVRGlue.c, which is the one file that draws with them.
// This file keeps only the retired KEY names above, for the v11 migration to
// delete, and the temporary tuning rig that stood between Controller Haptics and
// Grip Forward is gone with the row.

// Stereo depth default/range (measured on-device): the old slider's 40% floor was the
// comfortable value and 140%+ was overbearing — and the numbers are an arbitrary
// parallax divisor, not calibrated to IPD (physical disparity also depends on the
// user-adjustable panel size/distance), so the scale is ours to define. The slider
// spans 0.1–1.0. Default 60%: after both-eyes-per-frame landed (D-022) on-device testing found
// higher depth comfortable — much of the old strain was alternation judder itself.
#define Q3E_DEPTH_DEFAULT 0.6f

// Crosshair distance (stereo convergence): r_zproj is the world depth that renders at
// ZERO parallax — i.e. exactly at the panel plane, where the 2D crosshair/HUD live. At
// the upstream 64 the crosshair's apparent depth matches objects only ~1.6 m into the
// scene, closer than most combat; raising it pushes the focus plane out to where
// enemies actually are (vkQuake ships the same control). The eye-separation divisor is
// normalized by (focus/64) so changing focus does NOT change perceived depth strength.
#define Q3E_FOCUS_DEFAULT 160.0f
#define Q3E_DIM_DEFAULT   0.8f
// Default brightness 1.2 (measured on-device): stock 1.0 reads dark on the
// headset panel and on phones. Deliberately NOT part of reset3DDefaults —
// that button restores only the 3D-section placement/depth values.
#define Q3E_BRIGHT_DEFAULT 1.2f

// Look-sensitivity display rescale (measured on-pad): sliders show a clean
// 0.5–10; the applied gain is displayed x 1.2, so the ceiling equals the old
// 12 he wanted headroom for and the default displayed 5.0 = actual 6.0 (his
// on-device pick, ~1.7x the old pad baseline). Stored values are in DISPLAYED
// units. The touch and pad paths both scale from the same sliders.
#define Q3E_SENS_DEFAULT 5.0f
#define Q3E_SENS_APPLY   1.2f

static float def_float(NSString *key, float fallback) {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? v.floatValue : fallback;
}

#if TARGET_OS_VISION
// One clamp for the migrations that compute a value instead of deleting one. A
// NaN answers false to both comparisons and would fall through unchanged, so it
// is caught here rather than written back into a store.
static float def_clampf(float v, float lo, float hi) {
    if (!isfinite(v)) return lo;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

// --- VR Crosshair Size: the row's units vs the value's units (R3.1 item 1) ---
// The marker's own scale runs 0.5..1.5 and that is what is stored, what the
// console prints and what the engine consumes. Across a settings-sheet slider
// that whole span is one centimetre of finger travel, which is why the device
// round could not place it. The ROW therefore spans 1x..5x — the identical
// range, stretched four-fold — and converts on the way in and out.
//
// Deliberately a DISPLAY mapping and not a stored one: a stored display value
// would need its own migration, would disagree with the console, and would put
// two different meanings behind one number the moment either range moved
// again. Nothing below the sheet knows this mapping exists.
#define Q3E_VR_XHAIR_NATIVE_MIN 0.5f
#define Q3E_VR_XHAIR_NATIVE_MAX 1.5f
#define Q3E_VR_XHAIR_ROW_MIN    1.0f
#define Q3E_VR_XHAIR_ROW_MAX    5.0f
static float q3e_vr_xhair_row(float native) {
    if (!isfinite(native)) native = Q3E_VR_XHAIRSIZE_DEFAULT;
    float row = Q3E_VR_XHAIR_ROW_MIN +
        (native - Q3E_VR_XHAIR_NATIVE_MIN) *
        ((Q3E_VR_XHAIR_ROW_MAX - Q3E_VR_XHAIR_ROW_MIN) /
         (Q3E_VR_XHAIR_NATIVE_MAX - Q3E_VR_XHAIR_NATIVE_MIN));
    // A store that arrived from an older build's wider range (the ceiling was
    // 3.0 before this round) maps past the slider's end; the widget cannot show
    // it, and the engine's own setter clamps the value itself, so the row shows
    // the end it clamps to rather than a position that does not exist.
    if (row < Q3E_VR_XHAIR_ROW_MIN) row = Q3E_VR_XHAIR_ROW_MIN;
    if (row > Q3E_VR_XHAIR_ROW_MAX) row = Q3E_VR_XHAIR_ROW_MAX;
    return row;
}
static float q3e_vr_xhair_native(float row) {
    if (!isfinite(row)) return Q3E_VR_XHAIRSIZE_DEFAULT;
    return Q3E_VR_XHAIR_NATIVE_MIN +
        (row - Q3E_VR_XHAIR_ROW_MIN) *
        ((Q3E_VR_XHAIR_NATIVE_MAX - Q3E_VR_XHAIR_NATIVE_MIN) /
         (Q3E_VR_XHAIR_ROW_MAX - Q3E_VR_XHAIR_ROW_MIN));
}

// --- Weapon Size: the same split, for the same reason (R4.0) ----------------
// The native unit is a multiplier on the model's authored size, and the shipped
// default is 0.75 of it — a number that reads as "three quarters" on a row whose
// job is to say "this is the size the game ships at". the maintainer's call: the default
// DISPLAYS as 1.00x. So the row divides by 0.75 and the stored value, the
// console command and the renderer keep the native units they have always had.
//
// Exactly the crosshair row's pattern and exactly its rules: a DISPLAY mapping,
// no value migration, nothing below the sheet knows it exists. A stored 0.75
// still means 0.75 to `q3evrgunscale` and to VK_SetVRGun; it just draws as 1.00x
// on the slider's label.
//
// The ends are the old row's 0.5..2.0 native span pushed through the same
// division (0.667..2.667) and then rounded to the nearest half a displayed unit,
// per the maintainer's rounding rule: 0.50x..2.50x displayed, 0.375..1.875 native. The
// low end is slightly SMALLER than the old row could reach and the high end
// slightly less large; both were accepted with the rounding.
#define Q3E_VR_GUNSCALE_NATIVE_REF 0.75f    // the native size that displays as 1.00x
#define Q3E_VR_GUNSCALE_ROW_MIN    0.50f
#define Q3E_VR_GUNSCALE_ROW_MAX    2.50f
// The native span the row's ends imply. Stated as its own pair rather than
// recomputed at each use, because the engine-side clamp in Q3E_Cmd_VRGunScale_f
// and the apply path below both have to agree with the row about what is legal.
#define Q3E_VR_GUNSCALE_NATIVE_MIN (Q3E_VR_GUNSCALE_ROW_MIN * Q3E_VR_GUNSCALE_NATIVE_REF)
#define Q3E_VR_GUNSCALE_NATIVE_MAX (Q3E_VR_GUNSCALE_ROW_MAX * Q3E_VR_GUNSCALE_NATIVE_REF)
static float q3e_vr_gunscale_row(float native) {
    if (!isfinite(native)) native = Q3E_VR_GUNSCALE_DEFAULT;
    float row = native / Q3E_VR_GUNSCALE_NATIVE_REF;
    // A store from a build whose native range was wider (0.5..2.0 was 0.667x to
    // 2.667x in these units) maps past an end the widget cannot show. The row
    // shows the end it clamps to rather than a position that does not exist —
    // the crosshair row's own reasoning, and the apply path clamps the value
    // itself on the next write.
    if (row < Q3E_VR_GUNSCALE_ROW_MIN) row = Q3E_VR_GUNSCALE_ROW_MIN;
    if (row > Q3E_VR_GUNSCALE_ROW_MAX) row = Q3E_VR_GUNSCALE_ROW_MAX;
    return row;
}
static float q3e_vr_gunscale_native(float row) {
    if (!isfinite(row)) return Q3E_VR_GUNSCALE_DEFAULT;
    return row * Q3E_VR_GUNSCALE_NATIVE_REF;
}

// --- Vision Pro VR settings migration (R2 item 6, charter D11) --------------
// Migrate-if-untouched: a STORED value equal to the OLD default takes the new
// one; anything else (a value the player actually changed, or a value already
// migrated) is left alone. A key with no stored value at all is not this
// function's problem — def_float()'s own fallback already reads as the
// current default, which is exactly what "never touched" should mean.
static BOOL q3e_vr_near(float a, float b) { return fabsf(a - b) < 0.0005f; }

// R2.1 cut-list: q3e_vr_migrate_default (the "migrate FROM an old default"
// helper the v1 comment below promised to a "next round") was never called —
// v1 has nothing to migrate from — and sat as a permanent unused-function
// warning. Removed rather than kept as decoration; a future round that
// actually changes a default can write the helper it needs then, informed by
// what that round's migration actually looks like rather than a guess made
// before either existed.

// Runs once per process, before any VR preference is read (called from the
// top of Q3E_Settings_ApplyAll's VR block, which IS "before any VR preference
// is read" — nothing above it in that block touches a q3e_vr_* key). v1 is
// the FIRST stamp: this round adds six brand-new rows, so there is no OLD
// default to migrate away from yet — what v1 establishes is the STAMP and the
// GUARD, so a v2 round (an actual default change) has both to build on rather
// than inventing the mechanism under a deadline. The guard itself is the
// property worth testing: called again with the stamp already set, this must
// be a no-op — a build that re-applied migration on every launch would keep
// stamping over a value the player deliberately changed back to what used to
// be the old default.
// R2.2 fix 2: the CURRENT stamp. A migration step is guarded by the stamp it
// was introduced at, and the guard at the top compares against this — the
// version-number discipline the v1 comment promised, now that there is a real
// second step to make it mean something.
#define Q3E_VR_MIGRATION_STAMP 12

// How many of the six retired grip keys a store still holds. Reported by
// SETTINGSNOW so the v11 delete is something a harness can read rather than
// infer — see that field's own comment.
static int q3e_vr_stored_grip_keys(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *const keys[6] = { DEF_VR_GRIP_F, DEF_VR_GRIP_R, DEF_VR_GRIP_U,
                                DEF_VR_GRIPANG_P, DEF_VR_GRIPANG_Y,
                                DEF_VR_GRIPANG_R };
    int n = 0;
    for (int i = 0; i < 6; i++)
        if ([d objectForKey:keys[i]] != nil) n++;
    return n;
}

void Q3E_VR_MigrateSettings(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    int stamp = (int)def_float(DEF_VR_MIGRATION, 0.0f);
    if (stamp >= Q3E_VR_MIGRATION_STAMP) return;

    // v2 — fold the retired DEF_VR_HEIGHT (inches) into Q3EVR.m's
    // kQ3EVRTrimKey (metres), the ONE persisted store for the height trim
    // (see Q3E_VR_GetPersistedHeightTrimMetres's own comment).
    //
    // This step arrived in R2.1 as a fold-in placed BELOW a `stamp >= 1`
    // guard the previous build had already satisfied — so it was dead code
    // for exactly the population it was written for: every install that ran
    // that build (the only builds that ever wrote DEF_VR_HEIGHT) carried
    // stamp 1, returned before reaching it, and lost the player's height trim
    // on upgrade — the data loss it was added to prevent. A migration that
    // runs for nobody is worse than none: it reads as done.
    //
    // The fold-in itself goes through Q3E_VR_SetPersistedHeightTrimMetres,
    // which CLAMPS (R2.2 fix 7). It used to REFUSE an out-of-range value, and
    // the removeObjectForKey below then deleted the only copy of it — a
    // legitimately saved trim at either end of the old slider's own range
    // computed 0.50038 m against a 0.50 m limit, so the most extreme values a
    // player could have stored were exactly the ones silently thrown away.
    if (stamp < 2) {
        if ([d objectForKey:DEF_VR_HEIGHT] != nil && !Q3E_VR_HasPersistedHeightTrim()) {
            float inches = [d floatForKey:DEF_VR_HEIGHT];
            Q3E_VR_SetPersistedHeightTrimMetres(inches / 39.3701f);
        }
        [d removeObjectForKey:DEF_VR_HEIGHT];
    }
    // v3 (R3, hands) adds five brand-new keys — Aim Hand, Movement Direction,
    // Aim Pitch Trim, Weapon Size, Controller Haptics — and there is deliberately
    // NO step for them: a key that never existed has nothing to migrate FROM,
    // and def_float's own fallback is the whole of the correct behaviour. What
    // the bump buys is the ability for a LATER round to tell a pre-R3 store from
    // a post-R3 one, which is the only thing a stamp is for. Inventing a step to
    // justify the number would be the decoration the v1 helper already had to be
    // cut for.
    //
    // v4 (R3.1, the HUD slider split) — the one key in this section that has a
    // real predecessor to migrate FROM. `q3e_vr_hudscale` scaled the element
    // sizes and the layout spread together; HUD Size and Panel Size are those
    // two halves. Seeding BOTH from the stored combined value reproduces the
    // player's exact previous geometry, which is the whole requirement: the
    // split must be invisible to anyone who had already dialled the old slider
    // in. An install with no stored value takes both defaults (1.25 each) from
    // def_float, which is the same layout the combined default drew.
    //
    // Guarded on the key's presence, not on a value comparison: a player who
    // had deliberately left it at 1.25 wants 1.25/1.25, and so does everyone
    // else, so "migrate only if untouched" would be the same arithmetic with an
    // extra way to get it wrong. The old key is removed afterwards so a later
    // round cannot find a third opinion about the layout lying around.
    //
    // The Crosshair Size row changes in this round too and deliberately has NO
    // step here: only the ROW's display units and the DEFAULT moved, the stored
    // value's own units did not, so every saved size still means the size it
    // meant. Migrating a stored 1.5 (the old default) to the new 0.5 would be
    // the one thing this must not do — silently shrinking a marker somebody
    // chose. A stored value above the new 1.5 ceiling is clamped by the setter
    // and written back by q3e_vr_apply_tuning, which is where every
    // out-of-range store is already repaired.
    if (stamp < 4) {
        if ([d objectForKey:DEF_VR_HUDSCALE] != nil) {
            float combined = [d floatForKey:DEF_VR_HUDSCALE];
            // Only HUD Size is seeded now. v4 seeded the spread half too, and
            // v5 below deletes that key in the same pass — writing it here just
            // to delete it two statements later would be a step that reads as
            // load-bearing and is not.
            if (isfinite(combined))
                [d setFloat:combined forKey:DEF_VR_HUDSIZE];
        }
        [d removeObjectForKey:DEF_VR_HUDSCALE];
    }
    // v5 (R3.2) — two rows change MEANING, which is the case a stamp is really
    // for: a stored number that still parses and now says something else.
    //
    // HUD Position was 0=High 1=Low 2=Off. It is HUD On/Off now (0=On 1=Off),
    // because WHERE the HUD sits became the HUD Height slider's job. Both of the
    // old positions were the HUD being shown, so both become On; only Off stays
    // Off. Without this step a store holding Low (1) would read as the new Off
    // and the HUD would simply disappear on upgrade for everyone who had ever
    // touched that row.
    //
    // Panel Size (0.8-2.0, a spread multiplier) is REPLACED by HUD Height
    // (-15..+15 degrees, a position), and the honest answer is that the old
    // value cannot be mapped onto the new one: 1.25 of spread does not name a
    // height, and the spread the player had is now the layout's fixed shape. So
    // the old key is deleted and the new one takes its default of 0, which draws
    // the cluster exactly where the shipped 1.25 spread drew it. A player who
    // had moved Panel Size away from 1.25 loses that adjustment and re-dials it
    // as a height — recorded here rather than approximated with arithmetic that
    // would have no meaning.
    if (stamp < 5) {
        if ([d objectForKey:DEF_VR_HUD] != nil) {
            const int oldPos = (int)[d floatForKey:DEF_VR_HUD];
            [d setFloat:(oldPos >= 2) ? 1.0f : 0.0f forKey:DEF_VR_HUD];
        }
        [d removeObjectForKey:DEF_VR_PANELSIZE];
    }
    // v6 (R3.3) — the DEFAULTS move, and the stored values have to get out of
    // the way. Render Quality, HUD Size, HUD Height, Weapon Size and the whole
    // grip rig were tuned on glass through 1.0.4.8, and those numbers ARE the
    // new defaults: an install that already has them stored would read its own
    // old tuning back and never see the change it was the source of.
    //
    // So this step DELETES rather than rewrites. The keys go, def_float's
    // fallback becomes the answer, and the new default lands on exactly the
    // devices the tuning came from. This is the one migration in this function
    // that discards a player's stored value on purpose — it is safe only
    // because these five rows are still live on the sheet, so a value somebody
    // preferred is one drag away rather than gone.
    //
    // The grip keys are deleted as a SET, all six: yaw and roll are hardcoded
    // to zero from this round on, and a store that kept a non-zero one would be
    // written back to zero by the setter on the next apply anyway.
    if (stamp < 6) {
        [d removeObjectForKey:DEF_VR_RENDERSCALE];
        [d removeObjectForKey:DEF_VR_HUDSIZE];
        [d removeObjectForKey:DEF_VR_HUDHEIGHT];
        [d removeObjectForKey:DEF_VR_GUNSCALE];
        [d removeObjectForKey:DEF_VR_GRIP_F];
        [d removeObjectForKey:DEF_VR_GRIP_R];
        [d removeObjectForKey:DEF_VR_GRIP_U];
        [d removeObjectForKey:DEF_VR_GRIPANG_P];
        [d removeObjectForKey:DEF_VR_GRIPANG_Y];
        [d removeObjectForKey:DEF_VR_GRIPANG_R];
    }
    // v7 (R3.4) — the same delete-so-the-new-default-lands step, for the five
    // rows this round moves, and for one of them the delete is not cosmetic:
    //
    //   Aim Pitch Trim now measures from a built-in +2 (Q3E_VR_AIM_PITCH_BIAS),
    //   so a stored +2 from the round that found that number would be applied
    //   ON TOP of it and aim four degrees high. The value has to go; zero in the
    //   new units is the same aim the stored +2 bought in the old ones.
    //
    //   Crosshair Size (0.75), Grip Right (-3), Grip Up (+4) and Grip Pitch (+2)
    //   are the numbers dialled on glass becoming the shipped defaults, and an
    //   install that already has the old ones stored would never see them.
    //
    // GRIP FORWARD IS DELIBERATELY NOT DELETED. It is the one grip value the
    // round did not settle, the rear-plane anchor was referenced to the
    // machinegun precisely so the number keeps its meaning across the change,
    // and a stored forward is a preference somebody arrived at by dragging.
    if (stamp < 7) {
        [d removeObjectForKey:DEF_VR_XHAIRSIZE];
        [d removeObjectForKey:DEF_VR_AIMTRIM];
        [d removeObjectForKey:DEF_VR_GRIP_R];
        [d removeObjectForKey:DEF_VR_GRIP_U];
        [d removeObjectForKey:DEF_VR_GRIPANG_P];
    }
    // v8 (R3.5) — Grip Right's travel narrows to +/-2.5 and its default comes
    // down to -2.5 with it. This delete is NOT cosmetic: v7 shipped -3.0 and
    // persisted it, so every install that ran 1.0.4.10 is holding a stored value
    // that is now outside the row's own range. The setter would clamp it on the
    // next apply, but only on the next apply — until then the slider would sit
    // pinned at its end showing a number it cannot represent, and Reset would be
    // the only way to reach the shipped default. Deleting it lands -2.5 at once.
    if (stamp < 8) {
        [d removeObjectForKey:DEF_VR_GRIP_R];
    }
    // v9 (R3.6) mapped the three grip offsets into the anchor-point frame — the
    // one MAPPING migration this function ever had, scale-dependent, reading the
    // store's own Weapon Size. R4.0 REMOVES the mapping half of it.
    //
    // Not because it was wrong, but because it can no longer run for anyone.
    // Every store this step fires for (stamp < 9) also satisfies v11 below
    // (stamp < 11), and v11 deletes all six grip keys — so the arithmetic maps
    // a value into a frame and the next step drops it, in the same launch,
    // every time. That is the R2.1 lesson in this file's own comments: a
    // migration that runs for nobody reads as done, and this one would read as
    // "the grip is carefully carried across" while carrying nothing.
    //
    // What SURVIVES from v9 is the Aim Pitch Trim delete, which has nothing to
    // do with the grip: Q3E_VR_AIM_PITCH_BIAS went +2 to 0, so the -2 the
    // 1.0.4.11 round dialled on top of that +2 would now be applied to a raw
    // axis and aim two degrees low. Zero in the new units is the aim the stored
    // -2 bought in the old ones.
    if (stamp < 9) {
        [d removeObjectForKey:DEF_VR_AIMTRIM];
    }
    // v10 (R3.7) — Grip Right, Grip Up and Grip Pitch become HARDCODES, so the
    // three stored values have to go. Not cosmetic: the setter forces -0.5 / 0 /
    // 0 on every apply, and a store still claiming -0.33 / -1.38 / +2 would be a
    // second opinion about a value nothing can change — the same disagreement
    // the R3.3 yaw/roll hardcode had to write zeros to prevent. Deleting them
    // lands the forced numbers as the stored ones on the first apply.
    //
    // GRIP FORWARD IS DELIBERATELY NOT DELETED, again. It is the one value this
    // round exists to let the maintainer dial, its range only WIDENS here (-20..+20, so
    // every previously storable number is still legal), and a stored forward is
    // the dialling in progress — the thing that must survive the relaunch.
    if (stamp < 10) {
        [d removeObjectForKey:DEF_VR_GRIP_R];
        [d removeObjectForKey:DEF_VR_GRIP_U];
        [d removeObjectForKey:DEF_VR_GRIPANG_P];
    }
    // v11 (R4.0) — GRIP FORWARD, the last one, and with it every grip key this
    // program has ever written.
    //
    // R3.7 widened the row to -20..+20 so a span could be found by dragging on
    // glass. What came back was not a span: "-6.0 is right for all situations".
    // So the value is a constant in Q3EVRGlue.c, the row is gone, and the store
    // must say so — a stored q3e_vr_grip_f would be the same disagreement every
    // previous grip hardcode had to delete its key to prevent, except worse,
    // because the value it holds is a real number somebody dialled and it would
    // read as authoritative to anyone who found it.
    //
    // Not just forward: the five already-hardcoded keys are deleted here too.
    // v10 removed right, up and pitch — and then Q3E_VR_PersistTuning wrote all
    // six back on the next console tuning command, so an install that ran
    // 1.0.4.13 is holding a full set again, and yaw and roll have been written
    // continuously since R3.2 and never deleted at all. Nothing reads any of
    // them from this build forward; what this step buys is that nothing FINDS
    // them either.
    //
    // A delete, not a map: there is no new frame to map into. The six numbers
    // that ship are the six that ship.
    if (stamp < 11) {
        [d removeObjectForKey:DEF_VR_GRIP_F];
        [d removeObjectForKey:DEF_VR_GRIP_R];
        [d removeObjectForKey:DEF_VR_GRIP_U];
        [d removeObjectForKey:DEF_VR_GRIPANG_P];
        [d removeObjectForKey:DEF_VR_GRIPANG_Y];
        [d removeObjectForKey:DEF_VR_GRIPANG_R];
    }
    // v12 (R4.5) — two DEFAULTS move to the numbers the 1.0.4.15 device round
    // returned: Sharpen 0 -> 50%, HUD Height -2 -> 0 degrees.
    //
    // A default change is exactly the case that needs a delete. Both rows have
    // been on the shipped sheet for at least one build, so every install is
    // holding a stored value for them — written on the first apply, not by the
    // player — and a stored value beats a default forever. Without this step the
    // new numbers would reach nobody who has already launched the app, which is
    // everybody, and the round would read as landed while changing nothing.
    //
    // A delete and not a map, for both: there is no old-units-to-new-units
    // arithmetic here. The old value is a number that was never chosen; the new
    // one is a number that was.
    //
    // The cost of the delete is the one thing worth naming: a player who
    // deliberately set Sharpen to 0 or HUD Height to something of their own
    // loses that once, on this upgrade. There is no way to tell that store from
    // the untouched one — same key, same value — and the round's whole purpose
    // is that the untouched majority land on the verdict.
    if (stamp < 12) {
        [d removeObjectForKey:DEF_VR_SHARPEN];
        [d removeObjectForKey:DEF_VR_HUDHEIGHT];
    }
    // The Weapon Size row changes in this round too and deliberately has NO step
    // here. Only the ROW's display units moved (native / 0.75, so the shipped
    // 0.75 reads as 1.00x); the stored value, the console command and the
    // renderer all keep the native units they have always had. Migrating it
    // would be the mistake the crosshair row's own comment names — a stored
    // display value that disagrees with the console the moment either range
    // moves again.
    //
    // One knock-on, recorded rather than papered over: the movement basis was
    // console-only before R3 (`q3evrmovemode`, unpersisted), so a player
    // who had set it to a hand at the console gets the row's Head default on the
    // first launch of that build. There is no stored value to recover — the
    // setting had no store — and the row is authoritative from here.
    [d setFloat:(float)Q3E_VR_MIGRATION_STAMP forKey:DEF_VR_MIGRATION];
}

// --- change-tracked apply + quiet setters (R2.1 fix 6/12) --------------------
// Q3E_Settings_ApplyAll runs on EVERY settings change (any slider anywhere in
// the sheet, not just a VR row) and on every boot. Before this fix each of
// the six VR rows re-issued its q3evr* console command unconditionally, and
// each of those commands ends in a black-box dump + unthrottled flush (the
// harness's own diagnostics, not meant for a per-drag-tick applier) — a
// slider drag fires -changed dozens of times a second, so dragging an
// UNRELATED row (Brightness, say) re-triggered all six VR commands' flushes
// on every tick, visibly hitching and, over one drag session, exhausting the
// black box's pinned budget. Two changes fix it together: (1) cache what was
// last actually applied and skip a value that has not moved, and (2) apply
// through the quiet setters (Q3EVRGlue.c / Q3EVR.m) instead of the console
// commands — same state, no console dispatch, no dump. The console commands
// stay the harness's and the console/ornament's entry point, and now write
// their own value back to NSUserDefaults (Q3E_VR_PersistTuning) so the sheet
// and the console never disagree about what is actually live.
static float q3e_vr_lastRenderScale = -1.0f;
static float q3e_vr_lastXhairSize   = -1.0f;
static float q3e_vr_lastHeightM     = 1e30f;   // sentinel: never a legal trim
static int   q3e_vr_lastSnap        = -1;
static float q3e_vr_lastTurnSpeed   = -1.0f;
static int   q3e_vr_lastHud         = -1;
static float q3e_vr_lastHudSize     = -1.0f;
static float q3e_vr_lastHudHeight   = 1e30f;   // sentinel: never a legal offset
static int   q3e_vr_lastXhairOn     = -1;
static int   q3e_vr_lastShowHands   = -1;
static float q3e_vr_lastSharpen     = -1.0f;
static int   q3e_vr_lastDmgFlash    = -1;
static int   q3e_vr_lastAimHand     = -1;
static int   q3e_vr_lastMoveBasis   = -1;
static int   q3e_vr_lastAimMode     = -1;
static float q3e_vr_lastAimTrim     = 1e30f;
static float q3e_vr_lastGunScale    = -1.0f;
static int   q3e_vr_lastHaptics     = -1;

// R2.2 fix 12: every apply below records the value the ENGINE ended up with,
// not the one it was handed, and writes that value back to the store when the
// two differ. The old spelling cached what it ASKED for — and because the
// setters could silently drop a value they did not like, the cache, SETTINGSNOW
// and the sheet then all reported a number the engine had never taken, with the
// cache equality guaranteeing no later pass would ever retry it. Reading the
// live global back is the only report that cannot drift: it is the state
// itself. (The setters now clamp rather than drop — R2.2 fix 7 — so the
// write-back is usually a no-op, but it is what repairs a store that arrived
// out of range from anywhere: an older build, an edited plist, a future round's
// changed limits.)
static void q3e_vr_apply_tuning(void) {
    Q3E_VR_MigrateSettings();
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;

    float rs = def_float(DEF_VR_RENDERSCALE, Q3E_VR_RENDERSCALE_DEFAULT);
    if (!q3e_vr_near(rs, q3e_vr_lastRenderScale)) {
        Q3E_VR_SetRenderScaleQuiet(rs);
        q3e_vr_lastRenderScale = q3e_vrRenderScale;
        if (!q3e_vr_near(rs, q3e_vrRenderScale))
            [d setFloat:q3e_vrRenderScale forKey:DEF_VR_RENDERSCALE];
        // R3.2 item 5. The value used to be read exactly once, at VR entry, so
        // dragging this row inside VR — which is where the only display that can
        // show the difference is — did nothing at all, for the whole session.
        // The shell re-negotiates the extent instead; a no-op if the pixel count
        // barely moves, and coalesced so a drag costs one restart, not thirty.
        Q3E_VR_ReapplyRenderScale();
    }

    float xs = def_float(DEF_VR_XHAIRSIZE, Q3E_VR_XHAIRSIZE_DEFAULT);
    if (!q3e_vr_near(xs, q3e_vr_lastXhairSize)) {
        Q3E_VR_SetXhairSizeQuiet(xs);
        q3e_vr_lastXhairSize = q3e_vrXhairSize;
        if (!q3e_vr_near(xs, q3e_vrXhairSize))
            [d setFloat:q3e_vrXhairSize forKey:DEF_VR_XHAIRSIZE];
    }

    int xon = ([d objectForKey:DEF_VR_XHAIRON] != nil)
                  ? ([d boolForKey:DEF_VR_XHAIRON] ? 1 : 0)
                  : (int)Q3E_VR_XHAIRON_DEFAULT;
    if (xon != q3e_vr_lastXhairOn) {
        Q3E_VR_SetXhairOnQuiet(xon);
        q3e_vr_lastXhairOn = q3e_vrXhairOn;
    }

    // R4.3 item 1. The setter hops to the main thread to republish a SwiftUI
    // value, so the unchanged-value skip above matters more here than anywhere
    // else on this path: an unrelated slider drag must not re-evaluate the open
    // immersive space thirty times a second.
    int hands = ([d objectForKey:DEF_VR_SHOWHANDS] != nil)
                    ? ([d boolForKey:DEF_VR_SHOWHANDS] ? 1 : 0)
                    : (int)Q3E_VR_SHOWHANDS_DEFAULT;
    if (hands != q3e_vr_lastShowHands) {
        Q3E_VR_SetShowHandsQuiet(hands);
        q3e_vr_lastShowHands = q3e_vrShowHands;
    }

    // R4.3 item 2. Stored as the fraction the shader consumes; the row and the
    // console command are the only two places that speak percent.
    float sharp = def_float(DEF_VR_SHARPEN, Q3E_VR_SHARPEN_DEFAULT);
    if (!q3e_vr_near(sharp, q3e_vr_lastSharpen)) {
        Q3E_VR_SetSharpenQuiet(sharp);
        q3e_vr_lastSharpen = q3e_vrSharpen;
        if (!q3e_vr_near(sharp, q3e_vrSharpen))
            [d setFloat:q3e_vrSharpen forKey:DEF_VR_SHARPEN];
    }

    // R4.3 item 3. The setter pushes the engine's own copy (patch 0022), which
    // is what the renderer reads — this store is only where the row remembers it.
    int dmg = ([d objectForKey:DEF_VR_DAMAGEFLASH] != nil)
                  ? ([d boolForKey:DEF_VR_DAMAGEFLASH] ? 1 : 0)
                  : (int)Q3E_VR_DAMAGEFLASH_DEFAULT;
    if (dmg != q3e_vr_lastDmgFlash) {
        Q3E_VR_SetDamageFlashQuiet(dmg);
        q3e_vr_lastDmgFlash = q3e_vrDamageFlash;
    }

    // R2.1 fix 6c: reads the ONE persisted store directly (metres) — see
    // Q3E_VR_GetPersistedHeightTrimMetres's own comment — not a second,
    // independent inches-based copy. The setter persists what it applied, so
    // there is no separate write-back to do here.
    float hM = Q3E_VR_GetPersistedHeightTrimMetres();
    if (!q3e_vr_near(hM, q3e_vr_lastHeightM)) {
        Q3E_VR_SetPersistedHeightTrimMetres(hM);
        q3e_vr_lastHeightM = q3e_vrHeightTrim;
    }

    // R2.1 fix 6d: five segments now (Smooth/30/45/60/Off) — Off has to be
    // REPRESENTABLE in the stored value, or a console/ornament switch to
    // "off" (which the sheet had no widget for) gets silently overwritten
    // back to whatever segment happens to be selected the next time any
    // slider anywhere in the sheet moves.
    int snap = (int)def_float(DEF_VR_SNAPTURN, Q3E_VR_SNAPTURN_DEFAULT);
    if (snap < 0 || snap > 4) snap = 0;
    float ts = def_float(DEF_VR_TURNSPEED, Q3E_VR_TURNSPEED_DEFAULT);
    if (snap != q3e_vr_lastSnap || !q3e_vr_near(ts, q3e_vr_lastTurnSpeed)) {
        Q3E_VR_SetTurnQuiet(snap, ts);
        q3e_vr_lastSnap = q3e_vrTurnMode;
        q3e_vr_lastTurnSpeed = q3e_vrTurnSpeed;
        if (snap != q3e_vrTurnMode)
            [d setFloat:(float)q3e_vrTurnMode forKey:DEF_VR_SNAPTURN];
        if (!q3e_vr_near(ts, q3e_vrTurnSpeed))
            [d setFloat:q3e_vrTurnSpeed forKey:DEF_VR_TURNSPEED];
    }

    int hud = (int)def_float(DEF_VR_HUD, Q3E_VR_HUD_DEFAULT);
    if (hud < 0 || hud > 2) hud = 1;
    if (hud != q3e_vr_lastHud) {
        Q3E_VR_SetHudPosQuiet(hud);
        q3e_vr_lastHud = q3e_vrHudPos;
        if (hud != q3e_vrHudPos)
            [d setFloat:(float)q3e_vrHudPos forKey:DEF_VR_HUD];
    }

    float hsz = def_float(DEF_VR_HUDSIZE, Q3E_VR_HUDSIZE_DEFAULT);
    if (!q3e_vr_near(hsz, q3e_vr_lastHudSize)) {
        Q3E_VR_SetHudSizeQuiet(hsz);
        q3e_vr_lastHudSize = q3e_vrHudSize;
        if (!q3e_vr_near(hsz, q3e_vrHudSize))
            [d setFloat:q3e_vrHudSize forKey:DEF_VR_HUDSIZE];
    }

    float hht = def_float(DEF_VR_HUDHEIGHT, Q3E_VR_HUDHEIGHT_DEFAULT);
    if (!q3e_vr_near(hht, q3e_vr_lastHudHeight)) {
        Q3E_VR_SetHudHeightQuiet(hht);
        q3e_vr_lastHudHeight = q3e_vrHudHeight;
        if (!q3e_vr_near(hht, q3e_vrHudHeight))
            [d setFloat:q3e_vrHudHeight forKey:DEF_VR_HUDHEIGHT];
    }

    // --- R3 (hands) --------------------------------------------------------
    // Same shape as every row above: skip a value that has not moved, then read
    // the live global back so the cache and the store record what the engine
    // ACTUALLY took rather than what it was handed.
    int aimHand = (int)def_float(DEF_VR_AIMHAND, Q3E_VR_AIMHAND_DEFAULT);
    if (aimHand < 0 || aimHand > 1) aimHand = 1;
    if (aimHand != q3e_vr_lastAimHand) {
        q3e_vrAimHand = aimHand;
        q3e_vr_lastAimHand = q3e_vrAimHand;
    }

    // The movement basis is an ENUM the engine already owns; four states, and
    // an unknown one keeps the live value rather than inventing a nearest.
    int basis = (int)def_float(DEF_VR_MOVEBASIS, Q3E_VR_MOVEBASIS_DEFAULT);
    if (basis < 0 || basis > 3) basis = 0;
    if (basis != q3e_vr_lastMoveBasis) {
        q3e_vrMoveBasis = basis;
        q3e_vr_lastMoveBasis = q3e_vrMoveBasis;
    }

    // R4.6. Through the quiet setter, not a plain assignment: switching the row
    // has to forget the stick accumulator as well, and that is the setter's job
    // rather than a second rule kept here (an unknown value keeps the live one,
    // same as every other enum row).
    int aimMode = (int)def_float(DEF_VR_AIMMODE, Q3E_VR_AIMMODE_DEFAULT);
    if (aimMode != q3e_vr_lastAimMode) {
        Q3E_VR_SetAimModeQuiet(aimMode);
        q3e_vr_lastAimMode = q3e_vrAimMode;
        if (aimMode != q3e_vrAimMode)
            [d setFloat:(float)q3e_vrAimMode forKey:DEF_VR_AIMMODE];
    }

    float trim = def_float(DEF_VR_AIMTRIM, Q3E_VR_AIMTRIM_DEFAULT);
    if (!q3e_vr_near(trim, q3e_vr_lastAimTrim)) {
        if (isfinite(trim))
            q3e_vrAimPitchTrim = (trim < -10.0f) ? -10.0f : (trim > 10.0f) ? 10.0f : trim;
        q3e_vr_lastAimTrim = q3e_vrAimPitchTrim;
        if (!q3e_vr_near(trim, q3e_vrAimPitchTrim))
            [d setFloat:q3e_vrAimPitchTrim forKey:DEF_VR_AIMTRIM];
    }

    float gs = def_float(DEF_VR_GUNSCALE, Q3E_VR_GUNSCALE_DEFAULT);
    if (!q3e_vr_near(gs, q3e_vr_lastGunScale)) {
        // R4.0: the native limits the row's displayed 0.50x..2.50x implies. Only
        // the row's units moved — this clamp is still in native units, and it is
        // the same statement of them the engine's own q3evrgunscale uses.
        if (isfinite(gs))
            q3e_vrGunScale = def_clampf(gs, Q3E_VR_GUNSCALE_NATIVE_MIN,
                                            Q3E_VR_GUNSCALE_NATIVE_MAX);
        q3e_vr_lastGunScale = q3e_vrGunScale;
        if (!q3e_vr_near(gs, q3e_vrGunScale))
            [d setFloat:q3e_vrGunScale forKey:DEF_VR_GUNSCALE];
    }

    int hap = ([d objectForKey:DEF_VR_HAPTICS] != nil)
                  ? ([d boolForKey:DEF_VR_HAPTICS] ? 1 : 0)
                  : (int)Q3E_VR_HAPTICS_DEFAULT;
    if (hap != q3e_vr_lastHaptics) {
        q3e_vrHaptics = hap;
        q3e_vr_lastHaptics = q3e_vrHaptics;
    }

    // R4.0: THE GRIP BLOCK IS GONE. It read six stored values, pushed them at a
    // setter that ignored five of them, and wrote back what the setter forced.
    // With all six hardcoded there is nothing for it to read: the live vector is
    // its own initialiser, this function no longer touches it, and that is what
    // makes `q3evrgrip`'s session override survive the next unrelated slider drag
    // instead of being clobbered by a store's opinion on the following tick.

    // The renderer's copy of the two values it draws the weapon with. Pushed
    // from HERE, the one place every path (sheet, console command, boot apply)
    // already funnels through, rather than from each of them.
    VK_SetVRGun(q3e_vrAimHand, q3e_vrGunScale, q3e_vrGrip, q3e_vrGripAngles);
}
#endif

// Current "other app audio" mode, clamped — shared by the picker and the summary
// on the row that opens it. The policy itself lives in ios_audio.m.
static int q3e_audio_mode_setting(void) {
    int m = (int)lroundf(def_float(Q3E_DEF_AUDIO_MODE, (float)Q3E_AUDIO_DUCK_OTHERS));
    if (m < 0 || m >= Q3E_AUDIO_MODE_COUNT) m = Q3E_AUDIO_DUCK_OTHERS;
    return m;
}

static void apply_cvar_f(const char *name, float v) {
    char cmd[96]; snprintf(cmd, sizeof(cmd), "%s %g", name, v); Q3E_QueueCommand(cmd);
}

// Called once at startup (AppShell) to push persisted settings into the
// live layers.
void Q3E_Settings_ApplyAll(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    // Legacy single-axis values were stored in applied units; convert to displayed.
    float legacy = def_float(DEF_TOUCH_SENS, Q3E_SENS_DEFAULT * Q3E_SENS_APPLY) / Q3E_SENS_APPLY;
    Q3E_Input_SetGyro([d boolForKey:DEF_GYRO_ON], def_float(DEF_GYRO_SCALE, 2.0f));
    Q3E_Input_SetTouchSens(def_float(DEF_SENS_X, legacy) * Q3E_SENS_APPLY,
                           def_float(DEF_SENS_Y, legacy) * Q3E_SENS_APPLY);
    Q3E_Input_SetControlStyle(def_float(DEF_CTL_SCALE, 1.0f),
                              def_float(DEF_CTL_ALPHA, 1.0f));
    Q3E_Shell_SetRefreshMode([d boolForKey:DEF_REFRESH_60]);
    Q3E_Shell_SetFPSCounter([d boolForKey:DEF_FPS_COUNTER]);

    // Engine cvars (aim / display / gameplay).
    apply_cvar_f("m_pitch", [d boolForKey:DEF_INVERT] ? -0.022f : 0.022f);
    apply_cvar_f("cg_fov", def_float(DEF_FOV, 90.0f));
    apply_cvar_f("r_gamma", def_float(DEF_BRIGHTNESS, Q3E_BRIGHT_DEFAULT));
    // cl_run 1 = always run; when off, default to walk (touch/pad have no +speed).
    apply_cvar_f("cl_run", [d objectForKey:DEF_ALWAYS_RUN] ? ([d boolForKey:DEF_ALWAYS_RUN] ? 1 : 0) : 1);
    apply_cvar_f("cg_autoswitch", [d objectForKey:DEF_AUTOSWITCH] ? ([d boolForKey:DEF_AUTOSWITCH] ? 1 : 0) : 1);
    apply_cvar_f("cg_simpleItems", [d boolForKey:DEF_SIMPLEITEMS] ? 1 : 0);
    Q3E_Input_SetFireHaptics([d boolForKey:DEF_FIRE_HAPTIC]);
    apply_cvar_f("s_volume", def_float(DEF_SND_VOL, 0.8f));
    apply_cvar_f("s_musicvolume", def_float(DEF_MUS_VOL, 0.8f));
    // Session category/options + the master gain target (the gain itself ramps
    // in Q3E_Audio_Tick). Safe before the engine has booted: no queue yet just
    // means the gain lands when SNDDMA_Init creates it.
    Q3E_Audio_Apply();
    apply_cvar_f("cg_crosshairSize", def_float(DEF_XHAIR_SIZE, 24.0f));
    apply_cvar_f("cg_drawCrosshair", def_float(DEF_XHAIR_STYLE, 1.0f));
    // r_ext_multisample is latched (needs vid_restart to take effect — the segmented
    // control's action does that); here we just keep the cvar in sync at boot.
    apply_cvar_f("r_ext_multisample", def_float(DEF_MSAA, 0.0f));

#if TARGET_OS_VISION
    // visionOS 3D screen: parallax depth (higher slider = more depth = smaller divisor),
    // convergence plane, panel distance + size, hide-gun, dimming. The divisor feeds
    // BOTH stereo paths: the legacy alternating offset (VK_Set3DSeparation) and the
    // native two-field path (r_stereoSeparation; separation = zProj / divisor), and is
    // normalized by (focus/64) so the crosshair-distance slider doesn't change depth.
    float depth3d = def_float(DEF_DEPTH_3D, Q3E_DEPTH_DEFAULT);
    float focus3d = def_float(DEF_FOCUS_3D, Q3E_FOCUS_DEFAULT);
    float divisor = (20.0f / depth3d) * (focus3d / 64.0f);
    apply_cvar_f("r_zproj", focus3d);
    VK_Set3DSeparation(divisor);
    apply_cvar_f("r_stereoSeparation", divisor);
    Q3E_Set3DPanel(def_float(DEF_DIST_3D, 3.6f), def_float(DEF_SIZE_3D, 2.75f));
    Q3E_Set3DHeight(def_float(DEF_HEIGHT_3D, 0.0f));
    Q3E_Set3DHideGun([d objectForKey:DEF_HIDEGUN_3D] ? [d boolForKey:DEF_HIDEGUN_3D] : 0);
    Q3E_Set3DHideHead([d objectForKey:DEF_HIDEHEAD_3D] ? [d boolForKey:DEF_HIDEHEAD_3D] : 1);
    Q3E_Set3DDim(def_float(DEF_DIM_3D, Q3E_DIM_DEFAULT));
    // 3D panel brightness: r_gamma's FBO gamma pass runs in the swapchain blit,
    // which never executes while the engine is minimized into the panel — so the
    // Brightness slider ALSO drives an equivalent pow() in the panel shader.
    // Exactly one of the two paths is ever active (2D window vs 3D panel).
    Q3E_Set3DBrightness(def_float(DEF_BRIGHTNESS, Q3E_BRIGHT_DEFAULT));

    // Vision Pro VR (R2 item 6 / R2.1 fix 6). Migration runs first — "before
    // any VR preference is read" (charter D11) — then every row applies
    // through the quiet setters (q3e_vr_apply_tuning, above), which cache
    // what was last actually pushed and skip a value that has not moved —
    // this function runs on EVERY settings change, not just a VR one, so an
    // unrelated slider drag must not re-hammer all six VR settings' worth of
    // harness diagnostics. The q3evr* console commands remain the harness's
    // and the console/ornament's own application path and now write back to
    // the same NSUserDefaults keys this reads, so the two never disagree.
    q3e_vr_apply_tuning();
#endif
}

#if TARGET_OS_VISION
// SETTINGSNOW (R2 item 6) — the sheet's own values, in the sheet's own units,
// from the SAME def_float() reads viewDidLoad and Q3E_Settings_ApplyAll use.
// Registered as the `q3evrsettingsdump` console command (Q3EVRGlue.c), so a
// dump that disagrees with what is on screen is a bug in ONE of two places,
// never three.
void Q3E_VR_SettingsDumpString(char *buf, int n) {
    // R2.1 fix 6d: five names now — Off is a real, selectable, storable
    // state (see q3e_vr_apply_tuning's own comment).
    static const char *kSnapNames[5] = { "Smooth", "30", "45", "60", "Off" };
    static const char *kHudNames[2]  = { "On", "Off" };
    int snap = (int)def_float(DEF_VR_SNAPTURN, Q3E_VR_SNAPTURN_DEFAULT);
    int hud  = (int)def_float(DEF_VR_HUD, Q3E_VR_HUD_DEFAULT);
    if (snap < 0 || snap > 4) snap = 0;
    if (hud  < 0 || hud  > 1) hud  = 0;
    // R2.1 fix 6c: height reads the ONE persisted store (metres), converted
    // to the sheet's own inches display unit — DEF_VR_HEIGHT no longer
    // exists as an independent value to read.
    static const char *kHandNames[2]  = { "Left", "Right" };
    static const char *kBasisNames[4] = { "Head", "AimHand", "OffHand", "Off" };
    int hand  = (int)def_float(DEF_VR_AIMHAND, Q3E_VR_AIMHAND_DEFAULT);
    int basis = (int)def_float(DEF_VR_MOVEBASIS, Q3E_VR_MOVEBASIS_DEFAULT);
    if (hand  < 0 || hand  > 1) hand  = 1;
    if (basis < 0 || basis > 3) basis = 0;
    snprintf(buf, (size_t)n,
             "SETTINGSNOW section='Vision Pro VR' height=%+.1fin renderscale=%.2fx "
             "snapturn=%s turnspeed=%.0fdeg/s xhairsize=%.2fx xhairrow=%.1fx xhair=%s hud=%s "
             "hudsize=%.2fx hudheight=%+.1fdeg "
             "aimhand=%s movebasis=%s aimtrim=%+.1fdeg gunscale=%.2fx gunrow=%.2fx "
             "grip=(f%.1f,r%.1f,u%.1f)u gripang=(p%.1f,y%.1f,r%.1f)deg gripkeys=%d "
             "haptics=%d hands=%s sharpen=%.0f%% dmgflash=%s mig=%d "
             // R4.6, APPENDED after mig= rather than placed beside movebasis=,
             // which is where it belongs semantically: twice now (R4.2's
             // PANELNOW pair, R4.3's trio here) a new field has landed on a
             // junction an existing regex spanned. The end of the record is the
             // one place nothing can span. `aimrow` is the row's VISIBILITY,
             // read from the same predicate the sheet lays itself out with —
             // UIKit is invisible to every instrument this port has, so the
             // predicate is the only thing a test can see.
             "aimmode=%s aimrow=%s",
             Q3E_VR_GetPersistedHeightTrimMetres() * 39.3701f,
             def_float(DEF_VR_RENDERSCALE, Q3E_VR_RENDERSCALE_DEFAULT),
             kSnapNames[snap],
             def_float(DEF_VR_TURNSPEED, Q3E_VR_TURNSPEED_DEFAULT),
             def_float(DEF_VR_XHAIRSIZE, Q3E_VR_XHAIRSIZE_DEFAULT),
             // Both units, so a dump can be read against the console (native)
             // and against what is on screen (the row) without doing the
             // arithmetic in the reader's head.
             q3e_vr_xhair_row(def_float(DEF_VR_XHAIRSIZE, Q3E_VR_XHAIRSIZE_DEFAULT)),
             (([NSUserDefaults.standardUserDefaults objectForKey:DEF_VR_XHAIRON] != nil)
                  ? [NSUserDefaults.standardUserDefaults boolForKey:DEF_VR_XHAIRON]
                  : (Q3E_VR_XHAIRON_DEFAULT != 0.0f)) ? "on" : "off",
             kHudNames[hud],
             def_float(DEF_VR_HUDSIZE, Q3E_VR_HUDSIZE_DEFAULT),
             def_float(DEF_VR_HUDHEIGHT, Q3E_VR_HUDHEIGHT_DEFAULT),
             kHandNames[hand], kBasisNames[basis],
             def_float(DEF_VR_AIMTRIM, Q3E_VR_AIMTRIM_DEFAULT),
             def_float(DEF_VR_GUNSCALE, Q3E_VR_GUNSCALE_DEFAULT),
             // Both units, exactly as the crosshair pair above: native for the
             // console, the row for what is on screen.
             q3e_vr_gunscale_row(def_float(DEF_VR_GUNSCALE, Q3E_VR_GUNSCALE_DEFAULT)),
             // R4.0: the LIVE grip, read off the engine's own globals rather than
             // out of NSUserDefaults — there is no stored grip any more, and a
             // dump that read the store would report nothing at all. This is what
             // makes "the hardcoded set is what boots, whatever a store says"
             // something a harness can read back.
             q3e_vrGrip[0], q3e_vrGrip[1], q3e_vrGrip[2],
             q3e_vrGripAngles[0], q3e_vrGripAngles[1], q3e_vrGripAngles[2],
             // ...and how many of the six RETIRED grip keys the store still
             // holds. The v11 migration deletes them, and a delete is otherwise
             // invisible from outside: nothing reads those keys any more, so a
             // step that quietly stopped running would change no behaviour and
             // no other dump field. This is the number that makes it readable —
             // 0 after an upgrade, and whatever was seeded when the stamp says
             // migration had nothing to do.
             q3e_vr_stored_grip_keys(),
             ([NSUserDefaults.standardUserDefaults objectForKey:DEF_VR_HAPTICS] != nil)
                 ? ([NSUserDefaults.standardUserDefaults boolForKey:DEF_VR_HAPTICS] ? 1 : 0)
                 : (int)Q3E_VR_HAPTICS_DEFAULT,
             // R4.3. Read from the STORE, like every other field here — the
             // live-engine reading of the same three is EYENOW's job, and the
             // pair disagreeing is exactly the bug worth being able to see.
             (([NSUserDefaults.standardUserDefaults objectForKey:DEF_VR_SHOWHANDS] != nil)
                  ? [NSUserDefaults.standardUserDefaults boolForKey:DEF_VR_SHOWHANDS]
                  : (Q3E_VR_SHOWHANDS_DEFAULT != 0.0f)) ? "on" : "off",
             def_float(DEF_VR_SHARPEN, Q3E_VR_SHARPEN_DEFAULT) * 100.0f,
             (([NSUserDefaults.standardUserDefaults objectForKey:DEF_VR_DAMAGEFLASH] != nil)
                  ? [NSUserDefaults.standardUserDefaults boolForKey:DEF_VR_DAMAGEFLASH]
                  : (Q3E_VR_DAMAGEFLASH_DEFAULT != 0.0f)) ? "on" : "off",
             (int)def_float(DEF_VR_MIGRATION, 0.0f),
             ((int)def_float(DEF_VR_AIMMODE, Q3E_VR_AIMMODE_DEFAULT) == 1) ? "gamepad" : "head",
             Q3E_VR_PlainPadConnected() ? "shown" : "hidden");
}

// R2.1 fix 6b: called by the q3evrturn/q3evrhud/q3evrrenderscale/
// q3evrxhairsize command handlers (Q3EVRGlue.c) so a console or ornament
// change writes back to the SAME NSUserDefaults keys the sheet reads —
// without this, the sheet's own stale stored value silently overwrote a
// live console/ornament change the next time ANY settings row changed
// (charter D11's "one application path" only held for VALUES flowing sheet
// -> engine; nothing closed the loop the other way). Height trim is not
// included here — it has its own single-function store/getter
// (Q3E_VR_SetPersistedHeightTrimMetres), written directly by
// Q3E_Cmd_VRHeight_f/VRCalibrate_f via Q3E_VR_PersistHeight, so there is
// nothing for this function to duplicate for that one value.
void Q3E_VR_PersistTuning(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setFloat:q3e_vrRenderScale forKey:DEF_VR_RENDERSCALE];
    [d setFloat:q3e_vrXhairSize forKey:DEF_VR_XHAIRSIZE];
    [d setFloat:(float)q3e_vrTurnMode forKey:DEF_VR_SNAPTURN];
    [d setFloat:q3e_vrTurnSpeed forKey:DEF_VR_TURNSPEED];
    [d setFloat:(float)q3e_vrHudPos forKey:DEF_VR_HUD];
    [d setFloat:q3e_vrHudSize forKey:DEF_VR_HUDSIZE];
    [d setFloat:q3e_vrHudHeight forKey:DEF_VR_HUDHEIGHT];
    [d setBool:(q3e_vrXhairOn != 0) forKey:DEF_VR_XHAIRON];
    [d setBool:(q3e_vrShowHands != 0) forKey:DEF_VR_SHOWHANDS];
    [d setFloat:q3e_vrSharpen forKey:DEF_VR_SHARPEN];
    [d setBool:(q3e_vrDamageFlash != 0) forKey:DEF_VR_DAMAGEFLASH];
    // R3.2 persisted the grip offsets so numbers dialled on glass would survive
    // the relaunch and become the shipped defaults. R4.0 is that round arriving:
    // all six ARE the shipped defaults, as constants, and nothing writes them to
    // a store any more. `q3evrgrip` is session-only by the same change.
    [d setFloat:(float)q3e_vrAimHand forKey:DEF_VR_AIMHAND];
    [d setFloat:(float)q3e_vrMoveBasis forKey:DEF_VR_MOVEBASIS];
    [d setFloat:(float)q3e_vrAimMode forKey:DEF_VR_AIMMODE];
    [d setFloat:q3e_vrAimPitchTrim forKey:DEF_VR_AIMTRIM];
    [d setFloat:q3e_vrGunScale forKey:DEF_VR_GUNSCALE];
    [d setBool:(q3e_vrHaptics != 0) forKey:DEF_VR_HAPTICS];
    // R2.2 fix 4: and tell the sheet, if one is open. Fix 6b closed the loop
    // from the console into the STORE; this closes it into the WIDGETS. Without
    // it the loop is only half shut while the sheet is on screen: its widgets
    // are built once in viewDidLoad and never re-read, and -changed writes ALL
    // of them on any change to any row — so a console or ornament change landed
    // in the store, and the next unrelated slider drag wrote the sheet's own
    // months-old widget value straight back over it and pushed it into the live
    // engine. Exactly the clobber fix 6b was written to end, entered from the
    // other side.
    Q3E_VR_SettingsSheetSync();
}
#endif

// One-of-N picker for the "Other app audio" row. Each option carries a sentence
// saying what it actually does — the whole point of the Audio section is that
// "duck" and "mix" mean nothing to a player, and a four-word label wouldn't help.
// Presented modally (this sheet has no navigation controller of its own).
@interface Q3EAudioModeController : UITableViewController
@property (nonatomic, copy) void (^onPick)(void);
@end

@implementation Q3EAudioModeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Other App Audio";
    self.tableView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(dismissSelf)];
}
- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return Q3E_AudioModeTitles().count;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    c.textLabel.text = Q3E_AudioModeTitles()[ip.row];
    c.textLabel.textColor = UIColor.whiteColor;
    c.detailTextLabel.text = Q3E_AudioModeDetails()[ip.row];
    c.detailTextLabel.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
    c.detailTextLabel.numberOfLines = 0; // let the explanation wrap rather than truncate
    c.accessoryType = (ip.row == q3e_audio_mode_setting()) ? UITableViewCellAccessoryCheckmark
                                                           : UITableViewCellAccessoryNone;
    c.tintColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:1.0];
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    [NSUserDefaults.standardUserDefaults setFloat:(float)ip.row forKey:Q3E_DEF_AUDIO_MODE];
    [t reloadData];
    if (self.onPick) self.onPick();
    // Let the checkmark land before backing out, so the choice is visibly taken.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self dismissSelf]; });
}
@end

#if TARGET_OS_VISION
// R2.2 fix 4: the sheet currently on screen, if there is one. Weak on purpose —
// this is a notification target, never an owner, and a dismissed sheet must be
// deallocated on schedule and simply stop being told about console changes.
static __weak Q3ESettingsController *q3e_vr_liveSheet = nil;
// Private to this file: the sheet's own refresh, implemented in the main
// @implementation below and messaged from the C entry point at the bottom.
@interface Q3ESettingsController ()
- (void)vrSyncFromStore;
@end
#endif

@implementation Q3ESettingsController {
    UISwitch *_gyroSwitch, *_fpsSwitch;
#ifdef Q3E_DEV_BUILD
    UISwitch *_remoteConsoleSwitch;
#endif
    UISwitch *_invertSwitch, *_alwaysRunSwitch, *_autoSwitchSwitch, *_simpleItemsSwitch, *_fireHapticSwitch;
    UISegmentedControl *_refreshSeg, *_msaaSeg;
    UISlider *_gyroSlider, *_sensXSlider, *_sensYSlider, *_sizeSlider, *_alphaSlider;
    UISlider *_fovSlider, *_brightSlider, *_sndVolSlider, *_musVolSlider, *_xhairSizeSlider, *_xhairStyleSlider;
    UILabel *_gyroValue, *_sensXValue, *_sensYValue, *_sizeValue, *_alphaValue;
    UILabel *_fovValue, *_brightValue, *_sndVolValue, *_musVolValue, *_xhairSizeValue, *_xhairStyleValue;
    UISlider *_masterVolSlider;
    UILabel *_masterVolValue;
    UIButton *_audioModeButton;
#if TARGET_OS_VISION
    UISwitch *_hideGunSwitch, *_hideHeadSwitch;
    UISlider *_depthSlider, *_distSlider, *_size3DSlider, *_height3DSlider;
    UISlider *_focusSlider, *_dimSlider;
    UILabel *_depthValue, *_distValue, *_size3DValue, *_height3DValue;
    UILabel *_focusValue, *_dimValue;
    UISegmentedControl *_unitsSeg;
    // Vision Pro VR (R2 item 6).
    UISlider *_vrHeightSlider, *_vrRenderScaleSlider, *_vrTurnSpeedSlider, *_vrXhairSlider;
    UISlider *_vrAimTrimSlider, *_vrGunScaleSlider;
    UILabel  *_vrAimTrimValue, *_vrGunScaleValue;
    UISwitch *_vrHapticsSwitch;
    UISlider *_vrHudSizeSlider;
    UISlider *_vrHudHeightSlider;
    UISwitch *_vrXhairOnSwitch;
    UISwitch *_vrShowHandsSwitch;
    UISwitch *_vrDamageFlashSwitch;
    UISlider *_vrSharpenSlider;
    UILabel  *_vrSharpenValue;
    UILabel *_vrHeightValue, *_vrRenderScaleValue, *_vrTurnSpeedValue, *_vrXhairValue, *_vrCadenceCaption;
    UILabel *_vrHudSizeValue;
    UILabel *_vrHudHeightValue;
    UISegmentedControl *_vrSnapSeg, *_vrHudSeg, *_vrAimHandSeg, *_vrMoveBasisSeg;
    UISegmentedControl *_vrAimModeSeg;
    UILabel *_vrRecalStatus;   // R2.1 fix 9: refusal detail text under Re-calibrate Height
    // R3.2 item 1: rows this sheet HIDES rather than greys out, following the
    // donor's convention — a row that cannot apply in the current context is not
    // a disabled control, it is not part of this screen. Held as the row views
    // themselves because a UIStackView's arranged subview leaves the layout
    // entirely when hidden, so nothing below it keeps a gap where it was.
    NSArray<UIView *> *_rows3DPanel;      // the whole 3D SCREEN section
    UIView *_vrHudSizeRow, *_vrHudHeightRow, *_vrXhairSizeRow, *_vrAimModeRow;
#endif
}

- (UILabel *)section:(NSString *)text {
    UILabel *l = [self label:text size:13 bold:YES];
    l.textColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:0.9];
    return l;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;

    UILabel *title = [self label:@"Quake3e iOS Settings" size:20 bold:YES];
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [done addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];

    float legacy = def_float(DEF_TOUCH_SENS, Q3E_SENS_DEFAULT * Q3E_SENS_APPLY) / Q3E_SENS_APPLY;
    _gyroSwitch = [self makeSwitch:[d boolForKey:DEF_GYRO_ON]];
    _gyroSlider = [self makeSlider:0.5 max:6.0 value:def_float(DEF_GYRO_SCALE, 2.0f)];
    _gyroValue = [self label:@"" size:14 bold:NO];
    _sensXSlider = [self makeSlider:0.5 max:10.0 value:def_float(DEF_SENS_X, legacy)];
    _sensXValue = [self label:@"" size:14 bold:NO];
    _sensYSlider = [self makeSlider:0.5 max:10.0 value:def_float(DEF_SENS_Y, legacy)];
    _sensYValue = [self label:@"" size:14 bold:NO];
    // Same 0.6–1.6 range as the layout editor's own slider (ios_input.m
    // CTL_SCALE_MIN/MAX) — two sliders driving one value must not disagree
    // about its limits, or the editor can set a size this sheet cannot show.
    _sizeSlider = [self makeSlider:0.6 max:1.6 value:def_float(DEF_CTL_SCALE, 1.0f)];
    _sizeValue = [self label:@"" size:14 bold:NO];
    _alphaSlider = [self makeSlider:0.4 max:1.6 value:def_float(DEF_CTL_ALPHA, 1.0f)];
    _alphaValue = [self label:@"" size:14 bold:NO];
#if TARGET_OS_VISION
    // No number: UIScreen (and the panel's max rate) isn't queryable on visionOS,
    // and hardcoding one misled — M5 Vision Pro runs 120 Hz, earlier panels 90.
    // "Native" = whatever the OS grants the display link (shell requests up to 120).
    NSString *nativeLabel = @"Native";
#else
    NSString *nativeLabel = [NSString stringWithFormat:@"Native (%ld Hz)",
                             (long)UIScreen.mainScreen.maximumFramesPerSecond];
#endif
    _refreshSeg = [[UISegmentedControl alloc] initWithItems:@[@"60 Hz", nativeLabel]];
    _refreshSeg.selectedSegmentIndex = [d boolForKey:DEF_REFRESH_60] ? 0 : 1;
    [_refreshSeg addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    _fpsSwitch = [self makeSwitch:[d boolForKey:DEF_FPS_COUNTER]];

    _invertSwitch = [self makeSwitch:[d boolForKey:DEF_INVERT]];
    _fovSlider = [self makeSlider:60 max:130 value:def_float(DEF_FOV, 90.0f)];
    _fovValue = [self label:@"" size:14 bold:NO];
    _brightSlider = [self makeSlider:0.5 max:3.0 value:def_float(DEF_BRIGHTNESS, Q3E_BRIGHT_DEFAULT)];
    _brightValue = [self label:@"" size:14 bold:NO];
    _alwaysRunSwitch = [self makeSwitch:([d objectForKey:DEF_ALWAYS_RUN] ? [d boolForKey:DEF_ALWAYS_RUN] : YES)];
    _autoSwitchSwitch = [self makeSwitch:([d objectForKey:DEF_AUTOSWITCH] ? [d boolForKey:DEF_AUTOSWITCH] : YES)];
    _simpleItemsSwitch = [self makeSwitch:[d boolForKey:DEF_SIMPLEITEMS]];
    _fireHapticSwitch = [self makeSwitch:[d boolForKey:DEF_FIRE_HAPTIC]];
    _sndVolSlider = [self makeSlider:0.0 max:1.0 value:def_float(DEF_SND_VOL, 0.8f)];
    _sndVolValue = [self label:@"" size:14 bold:NO];
    _musVolSlider = [self makeSlider:0.0 max:1.0 value:def_float(DEF_MUS_VOL, 0.8f)];
    _musVolValue = [self label:@"" size:14 bold:NO];
    // Master gain: sits ON TOP of the two engine cvars above (it is the
    // AudioQueue's own volume, not a cvar), so it can never be written into
    // config.cfg and can never fight the engine's own Sound Volume menu.
    _masterVolSlider = [self makeSlider:0.0 max:1.0 value:def_float(Q3E_DEF_MASTER_VOL, 1.0f)];
    _masterVolValue = [self label:@"" size:14 bold:NO];
    _audioModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _audioModeButton.titleLabel.font = [UIFont systemFontOfSize:16];
    [_audioModeButton setTitleColor:[UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1] forState:UIControlStateNormal];
    [_audioModeButton addTarget:self action:@selector(openAudioModePicker) forControlEvents:UIControlEventTouchUpInside];
    _xhairSizeSlider = [self makeSlider:8 max:48 value:def_float(DEF_XHAIR_SIZE, 24.0f)];
    _xhairSizeValue = [self label:@"" size:14 bold:NO];
    _xhairStyleSlider = [self makeSlider:1 max:10 value:def_float(DEF_XHAIR_STYLE, 1.0f)];
    _xhairStyleValue = [self label:@"" size:14 bold:NO];
    _msaaSeg = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"2×", @"4×", @"8×"]];
    {
        int msaa = (int)def_float(DEF_MSAA, 0.0f);
        _msaaSeg.selectedSegmentIndex = (msaa >= 8) ? 3 : (msaa >= 4) ? 2 : (msaa >= 2) ? 1 : 0;
    }
    [_msaaSeg addTarget:self action:@selector(msaaChanged) forControlEvents:UIControlEventValueChanged];
#if TARGET_OS_VISION
    _hideGunSwitch = [self makeSwitch:([d objectForKey:DEF_HIDEGUN_3D] ? [d boolForKey:DEF_HIDEGUN_3D] : NO)];
    _hideHeadSwitch = [self makeSwitch:([d objectForKey:DEF_HIDEHEAD_3D] ? [d boolForKey:DEF_HIDEHEAD_3D] : YES)];
    _depthSlider = [self makeSlider:0.1 max:1.0 value:MIN(def_float(DEF_DEPTH_3D, Q3E_DEPTH_DEFAULT), 1.0f)];
    _depthValue = [self label:@"" size:14 bold:NO];
    _focusSlider = [self makeSlider:64 max:400 value:def_float(DEF_FOCUS_3D, Q3E_FOCUS_DEFAULT)];
    _focusValue = [self label:@"" size:14 bold:NO];
    _dimSlider = [self makeSlider:0.0 max:1.0 value:def_float(DEF_DIM_3D, Q3E_DIM_DEFAULT)];
    _dimValue = [self label:@"" size:14 bold:NO];
    _unitsSeg = [[UISegmentedControl alloc] initWithItems:@[@"m", @"ft"]];
    // Feet by default; metric persists once the user picks it.
    _unitsSeg.selectedSegmentIndex = ([d objectForKey:DEF_UNITS_FT] ? [d boolForKey:DEF_UNITS_FT] : YES) ? 1 : 0;
    [_unitsSeg addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    _distSlider = [self makeSlider:1.5 max:6.0 value:def_float(DEF_DIST_3D, 3.6f)];
    _distValue = [self label:@"" size:14 bold:NO];
    _size3DSlider = [self makeSlider:1.0 max:4.0 value:def_float(DEF_SIZE_3D, 2.75f)];
    _size3DValue = [self label:@"" size:14 bold:NO];
    _height3DSlider = [self makeSlider:-1.5 max:10.0 value:def_float(DEF_HEIGHT_3D, 0.0f)];
    _height3DValue = [self label:@"" size:14 bold:NO];

    // R2.2 fix 4: from here on this sheet is the one a console/ornament change
    // has to be able to reach (see Q3E_VR_SettingsSheetSync).
    q3e_vr_liveSheet = self;

    // Vision Pro VR (R2 item 6, charter D11's exact row inventory for v1).
    // R2.1 fix 6c: sourced from the ONE persisted store (metres, Q3EVR.m),
    // not a second independent DEF_VR_HEIGHT default — see its own comment.
    // R2.2 fix 7: +/-19.6 in, not 19.7. The trim limit is 0.50 m and 19.7 in
    // is 0.50038 m — the slider's own end positions were outside the range the
    // setter accepts, so dragging to either end applied nothing while the sheet
    // displayed the number anyway. A slider whose extremes are unreachable is a
    // worse lie than a slightly shorter one: 19.6 in = 0.49784 m, inside.
    _vrHeightSlider = [self makeSlider:-19.6 max:19.6 value:Q3E_VR_GetPersistedHeightTrimMetres() * 39.3701f];
    _vrHeightValue = [self label:@"" size:14 bold:NO];
    // R3.3: 1.00..2.00 — see Q3E_VR_SetRenderScaleQuiet, which clamps to the
    // same pair so no console value can land outside what this widget can show.
    _vrRenderScaleSlider = [self makeSlider:1.0 max:2.0 value:def_float(DEF_VR_RENDERSCALE, Q3E_VR_RENDERSCALE_DEFAULT)];
    _vrRenderScaleValue = [self label:@"" size:14 bold:NO];
    _vrCadenceCaption = [self label:@"2.0x+ halves cadence to 60 Hz" size:12 bold:NO];
    _vrCadenceCaption.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    // R2.1 fix 6d: a fifth segment, Off — the engine already supports
    // q3evrturn off (Q3E_VRTURN_OFF); the sheet had no way to select or even
    // DISPLAY it, so a console/ornament switch to Off looked, from the
    // sheet's own perspective, like a value outside its five known states
    // and got silently coerced back to Smooth by the old range clamp the
    // next time anything in the sheet applied.
    _vrSnapSeg = [[UISegmentedControl alloc] initWithItems:@[@"Smooth", @"30°", @"45°", @"60°", @"Off"]];
    {
        int snap = (int)def_float(DEF_VR_SNAPTURN, Q3E_VR_SNAPTURN_DEFAULT);
        _vrSnapSeg.selectedSegmentIndex = (snap >= 0 && snap <= 4) ? snap : 0;
    }
    [_vrSnapSeg addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    _vrTurnSpeedSlider = [self makeSlider:60 max:260 value:def_float(DEF_VR_TURNSPEED, Q3E_VR_TURNSPEED_DEFAULT)];
    _vrTurnSpeedValue = [self label:@"" size:14 bold:NO];
    // R3.1 item 1: the row travels 1x..5x; the value under it is 0.5..1.5.
    _vrXhairSlider = [self makeSlider:Q3E_VR_XHAIR_ROW_MIN max:Q3E_VR_XHAIR_ROW_MAX
                                value:q3e_vr_xhair_row(def_float(DEF_VR_XHAIRSIZE, Q3E_VR_XHAIRSIZE_DEFAULT))];
    _vrXhairValue = [self label:@"" size:14 bold:NO];
    _vrHudSizeSlider = [self makeSlider:0.8 max:2.0 value:def_float(DEF_VR_HUDSIZE, Q3E_VR_HUDSIZE_DEFAULT)];
    _vrHudSizeValue = [self label:@"" size:14 bold:NO];
    // R3.2 item 2: degrees of pitch, not a multiplier. The travel is deliberately
    // wide enough to put the status row at the bottom of comfortable vision or
    // level with it, which is the span the device round was reaching for.
    _vrHudHeightSlider = [self makeSlider:-15.0 max:15.0
                                    value:def_float(DEF_VR_HUDHEIGHT, Q3E_VR_HUDHEIGHT_DEFAULT)];
    _vrHudHeightValue = [self label:@"" size:14 bold:NO];
    _vrXhairOnSwitch = [self makeSwitch:(([d objectForKey:DEF_VR_XHAIRON] != nil)
                                             ? [d boolForKey:DEF_VR_XHAIRON]
                                             : (Q3E_VR_XHAIRON_DEFAULT != 0.0f))];
    // R4.3. The two switches and the one slider this round adds. The sharpen
    // row travels 0..100 in the donor's percent units; the stored value is the
    // fraction, converted here and in -changed and nowhere else.
    _vrShowHandsSwitch = [self makeSwitch:(([d objectForKey:DEF_VR_SHOWHANDS] != nil)
                                               ? [d boolForKey:DEF_VR_SHOWHANDS]
                                               : (Q3E_VR_SHOWHANDS_DEFAULT != 0.0f))];
    _vrDamageFlashSwitch = [self makeSwitch:(([d objectForKey:DEF_VR_DAMAGEFLASH] != nil)
                                                 ? [d boolForKey:DEF_VR_DAMAGEFLASH]
                                                 : (Q3E_VR_DAMAGEFLASH_DEFAULT != 0.0f))];
    _vrSharpenSlider = [self makeSlider:0.0 max:100.0
                                  value:def_float(DEF_VR_SHARPEN, Q3E_VR_SHARPEN_DEFAULT) * 100.0f];
    _vrSharpenValue = [self label:@"" size:14 bold:NO];
    _vrHudSeg = [[UISegmentedControl alloc] initWithItems:@[@"On", @"Off"]];
    {
        int hud = (int)def_float(DEF_VR_HUD, Q3E_VR_HUD_DEFAULT);
        _vrHudSeg.selectedSegmentIndex = (hud >= 0 && hud <= 1) ? hud : 0;
    }
    [_vrHudSeg addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];

    // R3 (hands).
    _vrAimHandSeg = [[UISegmentedControl alloc] initWithItems:@[@"Left", @"Right"]];
    {
        int h = (int)def_float(DEF_VR_AIMHAND, Q3E_VR_AIMHAND_DEFAULT);
        _vrAimHandSeg.selectedSegmentIndex = (h >= 0 && h <= 1) ? h : 1;
    }
    [_vrAimHandSeg addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    // R4.6 (gamepad aim). Two states only: the gaze aim this port shipped with,
    // and the right stick. Shown only while an ordinary pad is connected — see
    // -applyContextualVisibility.
    _vrAimModeSeg = [[UISegmentedControl alloc] initWithItems:@[@"Head", @"Gamepad"]];
    {
        int am = (int)def_float(DEF_VR_AIMMODE, Q3E_VR_AIMMODE_DEFAULT);
        _vrAimModeSeg.selectedSegmentIndex = (am >= 0 && am <= 1) ? am : 0;
    }
    [_vrAimModeSeg addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    _vrMoveBasisSeg = [[UISegmentedControl alloc] initWithItems:@[@"Head", @"Aim", @"Off Hand", @"Off"]];
    {
        int b = (int)def_float(DEF_VR_MOVEBASIS, Q3E_VR_MOVEBASIS_DEFAULT);
        _vrMoveBasisSeg.selectedSegmentIndex = (b >= 0 && b <= 3) ? b : 0;
    }
    [_vrMoveBasisSeg addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    _vrAimTrimSlider = [self makeSlider:-10 max:10 value:def_float(DEF_VR_AIMTRIM, Q3E_VR_AIMTRIM_DEFAULT)];
    _vrAimTrimValue = [self label:@"" size:14 bold:NO];
    // R4.0: the row is in DISPLAYED units (native / 0.75, so the shipped 0.75
    // reads as 1.00x) — the crosshair row's pattern. Stored value stays native.
    _vrGunScaleSlider = [self makeSlider:Q3E_VR_GUNSCALE_ROW_MIN max:Q3E_VR_GUNSCALE_ROW_MAX
                                   value:q3e_vr_gunscale_row(def_float(DEF_VR_GUNSCALE, Q3E_VR_GUNSCALE_DEFAULT))];
    _vrGunScaleValue = [self label:@"" size:14 bold:NO];
    _vrHapticsSwitch = [[UISwitch alloc] init];
    _vrHapticsSwitch.on = ([NSUserDefaults.standardUserDefaults objectForKey:DEF_VR_HAPTICS] != nil)
                              ? [NSUserDefaults.standardUserDefaults boolForKey:DEF_VR_HAPTICS]
                              : (Q3E_VR_HAPTICS_DEFAULT != 0.0f);
    [_vrHapticsSwitch addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
#endif

    UIStackView *rows = [[UIStackView alloc] init];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 14;
    rows.translatesAutoresizingMaskIntoConstraints = NO;

    // The title + Done row is PINNED above the scroll view (not scroll content),
    // so Done stays reachable however far down the sheet is scrolled.
    UIStackView *header = [self row:@[title, done]];
    header.translatesAutoresizingMaskIntoConstraints = NO;

#if TARGET_OS_VISION
    UIButton *reset3D = [UIButton buttonWithType:UIButtonTypeSystem];
    [reset3D setTitle:@"Reset" forState:UIControlStateNormal];
    reset3D.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [reset3D addTarget:self action:@selector(reset3DDefaults) forControlEvents:UIControlEventTouchUpInside];
    // R3.2 item 1: every one of these configures the flat 3D SCREEN — where the
    // panel hangs, how wide it is, how much parallax it has. Inside the
    // immersive space there is no panel; the world is the display. The donor
    // hides context-inapplicable rows rather than greying them, and so does
    // this: collected here so the whole section can leave the sheet at once.
    _rows3DPanel = @[
        [self row:@[[self section:@"3D SCREEN (VISION PRO)"], reset3D]],
        [self row:@[[self label:@"Hide gun in 3D" size:16 bold:NO], _hideGunSwitch]],
        [self row:@[[self label:@"2D HUD" size:16 bold:NO], _hideHeadSwitch]],
        [self row:@[[self label:@"Stereo depth" size:16 bold:NO], _depthSlider, _depthValue]],
        [self row:@[[self label:@"Crosshair distance" size:16 bold:NO], _focusSlider, _focusValue]],
        [self row:@[[self label:@"Dim surroundings" size:16 bold:NO], _dimSlider, _dimValue]],
        [self row:@[[self label:@"Screen distance" size:16 bold:NO], _distSlider, _distValue]],
        [self row:@[[self label:@"Screen size" size:16 bold:NO], _size3DSlider, _size3DValue]],
        [self row:@[[self label:@"Screen position height" size:16 bold:NO], _height3DSlider, _height3DValue]],
        [self row:@[[self label:@"Units" size:16 bold:NO], _unitsSeg]],
    ];
    for (UIView *r in _rows3DPanel) [rows addArrangedSubview:r];

    // Vision Pro VR (R2 item 6). Its own Reset, keyed by the section TITLE
    // (charter D11) — the reset also clears the stored height baseline, not
    // just these six rows, so the next VR entry re-calibrates from scratch.
    UIButton *resetVR = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetVR setTitle:@"Reset" forState:UIControlStateNormal];
    resetVR.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [resetVR addTarget:self action:@selector(resetVRDefaults) forControlEvents:UIControlEventTouchUpInside];
    [rows addArrangedSubview:[self row:@[[self section:@"VISION PRO VR"], resetVR]]];

    UIButton *enterVRBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [enterVRBtn setTitle:@"Enter VR" forState:UIControlStateNormal];
    enterVRBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [enterVRBtn setTitleColor:[UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1] forState:UIControlStateNormal];
    enterVRBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [enterVRBtn addTarget:self action:@selector(enterVRTapped) forControlEvents:UIControlEventTouchUpInside];
    [rows addArrangedSubview:[self row:@[enterVRBtn]]];

    [rows addArrangedSubview:[self row:@[[self label:@"Height" size:16 bold:NO], _vrHeightSlider, _vrHeightValue]]];

    UIButton *recalBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [recalBtn setTitle:@"Re-calibrate Height" forState:UIControlStateNormal];
    recalBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [recalBtn setTitleColor:[UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1] forState:UIControlStateNormal];
    recalBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [recalBtn addTarget:self action:@selector(vrRecalibrateTapped) forControlEvents:UIControlEventTouchUpInside];
    [rows addArrangedSubview:[self row:@[recalBtn]]];
    // R2.1 fix 9: refusal detail text — a refused capture (outside VR, or a
    // head height the sanity gate rejects) is surfaced HERE, not only as a
    // console line nobody but a bridge session would see.
    _vrRecalStatus = [self label:@"" size:12 bold:NO];
    _vrRecalStatus.textColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.35 alpha:1.0];
    _vrRecalStatus.numberOfLines = 0;
    [rows addArrangedSubview:[self row:@[_vrRecalStatus]]];

    UIButton *recenterBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [recenterBtn setTitle:@"Recenter View" forState:UIControlStateNormal];
    recenterBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [recenterBtn setTitleColor:[UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1] forState:UIControlStateNormal];
    recenterBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [recenterBtn addTarget:self action:@selector(vrRecenterTapped) forControlEvents:UIControlEventTouchUpInside];
    [rows addArrangedSubview:[self row:@[recenterBtn]]];

    // R4.3 item 1: the donor puts Show Hands directly under Enter VR, because
    // it is the row a first-time player reaches for while still finding their
    // controllers.
    [rows addArrangedSubview:[self row:@[[self label:@"Show Hands" size:16 bold:NO], _vrShowHandsSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"VR Render Quality" size:16 bold:NO], _vrRenderScaleSlider, _vrRenderScaleValue]]];
    [rows addArrangedSubview:[self row:@[[UIView new], _vrCadenceCaption]]];
    // R4.3 item 2: under Render Quality, where the donor has it — both rows
    // trade the same thing (how the eye image is reconstructed) and reading
    // them together is the point.
    [rows addArrangedSubview:[self row:@[[self label:@"Sharpen" size:16 bold:NO], _vrSharpenSlider, _vrSharpenValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Snap Turn" size:16 bold:NO], _vrSnapSeg]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Turn Speed" size:16 bold:NO], _vrTurnSpeedSlider, _vrTurnSpeedValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"VR Crosshair" size:16 bold:NO], _vrXhairOnSwitch]]];
    _vrXhairSizeRow = [self row:@[[self label:@"VR Crosshair Size" size:16 bold:NO], _vrXhairSlider, _vrXhairValue]];
    [rows addArrangedSubview:_vrXhairSizeRow];
    [rows addArrangedSubview:[self row:@[[self label:@"HUD" size:16 bold:NO], _vrHudSeg]]];
    _vrHudSizeRow = [self row:@[[self label:@"HUD Size" size:16 bold:NO], _vrHudSizeSlider, _vrHudSizeValue]];
    [rows addArrangedSubview:_vrHudSizeRow];
    _vrHudHeightRow = [self row:@[[self label:@"HUD Height" size:16 bold:NO], _vrHudHeightSlider, _vrHudHeightValue]];
    [rows addArrangedSubview:_vrHudHeightRow];
    [rows addArrangedSubview:[self row:@[[self label:@"Aim Hand" size:16 bold:NO], _vrAimHandSeg]]];
    // Directly ABOVE Movement Direction (the maintainer's placement): the two rows are
    // read together — where you aim and where you walk — and this one is the
    // question the other one's "Aim" option now answers to.
    _vrAimModeRow = [self row:@[[self label:@"Aiming" size:16 bold:NO], _vrAimModeSeg]];
    [rows addArrangedSubview:_vrAimModeRow];
    [rows addArrangedSubview:[self row:@[[self label:@"Movement Direction" size:16 bold:NO], _vrMoveBasisSeg]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Aim Pitch Trim" size:16 bold:NO], _vrAimTrimSlider, _vrAimTrimValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Weapon Size" size:16 bold:NO], _vrGunScaleSlider, _vrGunScaleValue]]];
    // R4.3 item 3.
    [rows addArrangedSubview:[self row:@[[self label:@"Damage Flash" size:16 bold:NO], _vrDamageFlashSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Controller Haptics" size:16 bold:NO], _vrHapticsSwitch]]];
    // R4.0: the temporary tuning rig that stood here is GONE — the note, the
    // Grip Forward row and everything R3.2 put between Controller Haptics and it.
    // It was a dev-build instrument for finding one number on glass, the number
    // came back (-6.0, "right for all situations"), and an instrument kept past
    // its answer is a row that invites someone to move a value nothing reads.
#endif

    [rows addArrangedSubview:[self section:@"AIM"]];
    [rows addArrangedSubview:[self row:@[[self label:@"Look sensitivity X" size:16 bold:NO], _sensXSlider, _sensXValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Look sensitivity Y" size:16 bold:NO], _sensYSlider, _sensYValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Invert look" size:16 bold:NO], _invertSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Gyro aim" size:16 bold:NO], _gyroSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Gyro intensity" size:14 bold:NO], _gyroSlider, _gyroValue]]];

    [rows addArrangedSubview:[self section:@"DISPLAY"]];
    [rows addArrangedSubview:[self row:@[[self label:@"Field of view" size:16 bold:NO], _fovSlider, _fovValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Brightness" size:16 bold:NO], _brightSlider, _brightValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Refresh rate" size:16 bold:NO], _refreshSeg]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Anti-aliasing" size:16 bold:NO], _msaaSeg]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Crosshair size" size:16 bold:NO], _xhairSizeSlider, _xhairSizeValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Crosshair style" size:16 bold:NO], _xhairStyleSlider, _xhairStyleValue]]];

    [rows addArrangedSubview:[self section:@"AUDIO"]];
    [rows addArrangedSubview:[self row:@[[self label:@"Master volume" size:16 bold:NO], _masterVolSlider, _masterVolValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Sound volume" size:16 bold:NO], _sndVolSlider, _sndVolValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Music volume" size:16 bold:NO], _musVolSlider, _musVolValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Other app audio" size:16 bold:NO], _audioModeButton]]];

    [rows addArrangedSubview:[self section:@"TOUCH CONTROLS"]];
    [rows addArrangedSubview:[self row:@[[self label:@"Controls size" size:16 bold:NO], _sizeSlider, _sizeValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Controls opacity" size:16 bold:NO], _alphaSlider, _alphaValue]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Fire haptics" size:16 bold:NO], _fireHapticSwitch]]];
    // Replaces "Left-handed layout": the move stick's zone is draggable now, so
    // stick-on-the-right is one drag — and so is every position in between.
    UIButton *layoutBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [layoutBtn setTitle:@"Customize Touch Layout…" forState:UIControlStateNormal];
    layoutBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [layoutBtn setTitleColor:[UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1] forState:UIControlStateNormal];
    layoutBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [layoutBtn addTarget:self action:@selector(openLayoutEditor) forControlEvents:UIControlEventTouchUpInside];
    [rows addArrangedSubview:[self row:@[layoutBtn]]];

    [rows addArrangedSubview:[self section:@"GAMEPLAY"]];
    [rows addArrangedSubview:[self row:@[[self label:@"Always run" size:16 bold:NO], _alwaysRunSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Auto-switch weapons" size:16 bold:NO], _autoSwitchSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"Simple items" size:16 bold:NO], _simpleItemsSwitch]]];
    [rows addArrangedSubview:[self row:@[[self label:@"FPS counter" size:16 bold:NO], _fpsSwitch]]];
#ifdef Q3E_DEV_BUILD
    // DEV BUILDS ONLY — compiled out of anything with a public version number.
    // Opens the engine console on TCP 27999 to the local network and tailnet,
    // unauthenticated, so it must never ship publicly.
    _remoteConsoleSwitch = [self makeSwitch:[d boolForKey:DEF_REMOTE_CONSOLE]];
    [rows addArrangedSubview:[self row:@[[self label:@"Remote Console (port 27999)" size:16 bold:NO],
                                         _remoteConsoleSwitch]]];
#endif


    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];
    [self.view addSubview:scroll];
    [scroll addSubview:rows];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14],
        [header.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [header.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:6],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [rows.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:18],
        [rows.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-18],
        [rows.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [rows.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [rows.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
    ]];
    [self refreshValueLabels];
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.textColor = UIColor.whiteColor;
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    return l;
}

- (UISwitch *)makeSwitch:(BOOL)on {
    UISwitch *s = [[UISwitch alloc] init];
    s.on = on;
    [s addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    return s;
}

- (UISlider *)makeSlider:(float)min max:(float)max value:(float)v {
    UISlider *s = [[UISlider alloc] init];
    s.minimumValue = min;
    s.maximumValue = max;
    s.value = v;
    [s addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [s.widthAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;
    return s;
}

- (UIStackView *)row:(NSArray<UIView *> *)views {
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:views];
    r.axis = UILayoutConstraintAxisHorizontal;
    r.spacing = 16;
    r.distribution = UIStackViewDistributionEqualSpacing;
    r.alignment = UIStackViewAlignmentCenter;
    return r;
}

- (void)refreshValueLabels {
    _gyroValue.text = [NSString stringWithFormat:@"%.1f", _gyroSlider.value];
    _sensXValue.text = [NSString stringWithFormat:@"%.1f", _sensXSlider.value];
    _sensYValue.text = [NSString stringWithFormat:@"%.1f", _sensYSlider.value];
    _sizeValue.text = [NSString stringWithFormat:@"%.0f%%", _sizeSlider.value * 100];
    _alphaValue.text = [NSString stringWithFormat:@"%.0f%%", _alphaSlider.value * 100];
    _fovValue.text = [NSString stringWithFormat:@"%.0f", _fovSlider.value];
    _brightValue.text = [NSString stringWithFormat:@"%.1f", _brightSlider.value];
    _sndVolValue.text = [NSString stringWithFormat:@"%.0f%%", _sndVolSlider.value * 100];
    _musVolValue.text = [NSString stringWithFormat:@"%.0f%%", _musVolSlider.value * 100];
    _masterVolValue.text = [NSString stringWithFormat:@"%.0f%%", _masterVolSlider.value * 100];
    [_audioModeButton setTitle:Q3E_AudioModeTitles()[q3e_audio_mode_setting()] forState:UIControlStateNormal];
    _xhairSizeValue.text = [NSString stringWithFormat:@"%.0f", _xhairSizeSlider.value];
    _xhairStyleValue.text = [NSString stringWithFormat:@"%.0f", roundf(_xhairStyleSlider.value)];
#if TARGET_OS_VISION
    _depthValue.text = [NSString stringWithFormat:@"%.0f%%", _depthSlider.value * 100];
    _focusValue.text = (_focusSlider.value < 96)  ? @"near"
                     : (_focusSlider.value < 240) ? @"mid" : @"far";
    _dimValue.text = [NSString stringWithFormat:@"%.0f%%", _dimSlider.value * 100];
    // Panel measurements honor the m/ft toggle (screen size is the FULL width, 2x halfW).
    BOOL ft = (_unitsSeg.selectedSegmentIndex == 1);
    float k = ft ? 3.28084f : 1.0f;
    NSString *u = ft ? @"ft" : @"m";
    _distValue.text = [NSString stringWithFormat:@"%.1f %@", _distSlider.value * k, u];
    _size3DValue.text = [NSString stringWithFormat:@"%.1f %@ wide", _size3DSlider.value * 2.0f * k, u];
    _height3DValue.text = [NSString stringWithFormat:@"%+.1f %@", _height3DSlider.value * k, u];

    // Vision Pro VR.
    _vrHeightValue.text = [NSString stringWithFormat:@"%+.1f in", _vrHeightSlider.value];
    _vrRenderScaleValue.text = [NSString stringWithFormat:@"%.2fx", _vrRenderScaleSlider.value];
    _vrCadenceCaption.hidden = (_vrRenderScaleSlider.value < 2.0f);
    _vrTurnSpeedValue.text = [NSString stringWithFormat:@"%.0f°/s", _vrTurnSpeedSlider.value];
    // Smooth turn is the only mode Turn Speed affects — a snap angle is fixed
    // by the segment itself, so greying the row out (rather than hiding it,
    // which would jump every row below it) says so without a second label.
    _vrTurnSpeedSlider.enabled = (_vrSnapSeg.selectedSegmentIndex == 0);
    _vrTurnSpeedValue.alpha = _vrTurnSpeedSlider.enabled ? 1.0 : 0.4;
    _vrXhairValue.text = [NSString stringWithFormat:@"%.1fx", _vrXhairSlider.value];
    _vrHudSizeValue.text = [NSString stringWithFormat:@"%.2fx", _vrHudSizeSlider.value];
    _vrHudHeightValue.text = [NSString stringWithFormat:@"%+.0f°", _vrHudHeightSlider.value];
    _vrAimTrimValue.text = [NSString stringWithFormat:@"%+.0f°", _vrAimTrimSlider.value];
    _vrGunScaleValue.text = [NSString stringWithFormat:@"%.2fx", _vrGunScaleSlider.value];
    // R4.3 item 2. Zero is the shipped value and it is not "0%" of anything the
    // player can see — it is the row being off, so it says so.
    _vrSharpenValue.text = (_vrSharpenSlider.value < 0.5f)
        ? @"Off" : [NSString stringWithFormat:@"%.0f%%", _vrSharpenSlider.value];
    // Aim Pitch Trim only means anything while a HAND is aiming; with no
    // controllers the crosshair IS the gaze and an offset between them would be
    // a nausea machine, so the row says so rather than silently doing nothing.
    _vrAimTrimSlider.enabled = (Q3E_Sense_Connected() > 0);
    _vrAimTrimValue.alpha = _vrAimTrimSlider.enabled ? 1.0 : 0.4;
    [self applyContextualVisibility];
#endif
}

#if TARGET_OS_VISION
// R3.2 item 1 — which rows belong on this screen right now.
//
// Two contexts, one rule each, and both are "hide", not "grey out": a control
// that cannot mean anything here is not part of the screen (the donor's
// convention, VR-PORTING-GUIDE section 14).
//
//   IN VR   — the 3D SCREEN section is gone. Its rows place and shape a flat
//             panel that does not exist inside the immersive space.
//   HUD Off — HUD Size and HUD Height are gone. There is no HUD to size or
//             place (R3.2 item 4).
//   Crosshair off — VR Crosshair Size is gone, for the same reason.
//
// The VR section itself deliberately stays visible OUTSIDE VR: it is where
// "Enter VR" lives, and every value in it is one a player sets before putting
// the headset on. The two rows in it that genuinely need a live session — the
// height capture and the recentre — already report their own refusal in the
// sheet rather than pretending, which is the more honest answer than hiding the
// only affordance that explains what they are for.
- (void)applyContextualVisibility {
    const BOOL inVR = (Q3E_GetMode() == 2 /* Q3E_MODE_VR */);
    for (UIView *r in _rows3DPanel) r.hidden = inVR;
    const BOOL hudOff = (_vrHudSeg.selectedSegmentIndex == 1);
    _vrHudSizeRow.hidden = hudOff;
    _vrHudHeightRow.hidden = hudOff;
    _vrXhairSizeRow.hidden = !_vrXhairOnSwitch.on;
    // R4.6 — no ordinary pad, no Aiming row. With only a Sense pair (or nothing)
    // in the room the stick this row talks about does not exist, and hand aim
    // outranks the row anyway; the pad layer's own spatial filter is what
    // decides, so the row and the stick can never disagree about which device
    // is meant.
    _vrAimModeRow.hidden = !Q3E_VR_PlainPadConnected();
}
#endif

- (void)changed {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:_gyroSwitch.on forKey:DEF_GYRO_ON];
    [d setFloat:_gyroSlider.value forKey:DEF_GYRO_SCALE];
    [d setFloat:_sensXSlider.value forKey:DEF_SENS_X];
    [d setFloat:_sensYSlider.value forKey:DEF_SENS_Y];
    [d setFloat:_sizeSlider.value forKey:DEF_CTL_SCALE];
    [d setFloat:_alphaSlider.value forKey:DEF_CTL_ALPHA];
    [d setBool:(_refreshSeg.selectedSegmentIndex == 0) forKey:DEF_REFRESH_60];
    [d setBool:_fpsSwitch.on forKey:DEF_FPS_COUNTER];
#ifdef Q3E_DEV_BUILD
    [d setBool:_remoteConsoleSwitch.on forKey:DEF_REMOTE_CONSOLE];
    // Start it the moment it is switched on, so it needs no relaunch. Switching
    // off takes effect next launch (the listener is not torn down mid-session).
    if (_remoteConsoleSwitch.on) Q3E_EnableConsoleBridge();
#endif
    [d setBool:_invertSwitch.on forKey:DEF_INVERT];
    [d setFloat:_fovSlider.value forKey:DEF_FOV];
    [d setFloat:_brightSlider.value forKey:DEF_BRIGHTNESS];
    [d setBool:_alwaysRunSwitch.on forKey:DEF_ALWAYS_RUN];
    [d setBool:_autoSwitchSwitch.on forKey:DEF_AUTOSWITCH];
    [d setBool:_simpleItemsSwitch.on forKey:DEF_SIMPLEITEMS];
    [d setBool:_fireHapticSwitch.on forKey:DEF_FIRE_HAPTIC];
    [d setFloat:_sndVolSlider.value forKey:DEF_SND_VOL];
    [d setFloat:_musVolSlider.value forKey:DEF_MUS_VOL];
    [d setFloat:_masterVolSlider.value forKey:Q3E_DEF_MASTER_VOL];
    [d setFloat:_xhairSizeSlider.value forKey:DEF_XHAIR_SIZE];
    [d setFloat:roundf(_xhairStyleSlider.value) forKey:DEF_XHAIR_STYLE];
    { const int msaaVals[] = {0, 2, 4, 8};
      [d setFloat:msaaVals[_msaaSeg.selectedSegmentIndex] forKey:DEF_MSAA]; }
#if TARGET_OS_VISION
    [d setBool:_hideGunSwitch.on forKey:DEF_HIDEGUN_3D];
    [d setBool:_hideHeadSwitch.on forKey:DEF_HIDEHEAD_3D];
    [d setBool:(_unitsSeg.selectedSegmentIndex == 1) forKey:DEF_UNITS_FT];
    [d setFloat:_depthSlider.value forKey:DEF_DEPTH_3D];
    [d setFloat:_focusSlider.value forKey:DEF_FOCUS_3D];
    [d setFloat:_dimSlider.value forKey:DEF_DIM_3D];
    [d setFloat:_distSlider.value forKey:DEF_DIST_3D];
    [d setFloat:_size3DSlider.value forKey:DEF_SIZE_3D];
    [d setFloat:_height3DSlider.value forKey:DEF_HEIGHT_3D];
    // R2.1 fix 6c: written straight to the ONE persisted store (metres) —
    // no DEF_VR_HEIGHT copy to fight with it. Quiet: no console dispatch,
    // no dump — the sheet's own -changed already fires on every drag tick.
    Q3E_VR_SetPersistedHeightTrimMetres(_vrHeightSlider.value / 39.3701f);
    [d setFloat:_vrRenderScaleSlider.value forKey:DEF_VR_RENDERSCALE];
    [d setFloat:(float)_vrSnapSeg.selectedSegmentIndex forKey:DEF_VR_SNAPTURN];
    [d setFloat:_vrTurnSpeedSlider.value forKey:DEF_VR_TURNSPEED];
    [d setFloat:q3e_vr_xhair_native(_vrXhairSlider.value) forKey:DEF_VR_XHAIRSIZE];
    [d setFloat:(float)_vrHudSeg.selectedSegmentIndex forKey:DEF_VR_HUD];
    [d setFloat:_vrHudSizeSlider.value forKey:DEF_VR_HUDSIZE];
    [d setFloat:_vrHudHeightSlider.value forKey:DEF_VR_HUDHEIGHT];
    [d setBool:_vrXhairOnSwitch.on forKey:DEF_VR_XHAIRON];
    [d setBool:_vrShowHandsSwitch.on forKey:DEF_VR_SHOWHANDS];
    [d setFloat:_vrSharpenSlider.value / 100.0f forKey:DEF_VR_SHARPEN];
    [d setBool:_vrDamageFlashSwitch.on forKey:DEF_VR_DAMAGEFLASH];
    [d setFloat:(float)_vrAimHandSeg.selectedSegmentIndex forKey:DEF_VR_AIMHAND];
    [d setFloat:(float)_vrMoveBasisSeg.selectedSegmentIndex forKey:DEF_VR_MOVEBASIS];
    [d setFloat:(float)_vrAimModeSeg.selectedSegmentIndex forKey:DEF_VR_AIMMODE];
    [d setFloat:_vrAimTrimSlider.value forKey:DEF_VR_AIMTRIM];
    [d setFloat:q3e_vr_gunscale_native(_vrGunScaleSlider.value) forKey:DEF_VR_GUNSCALE];
    [d setBool:_vrHapticsSwitch.on forKey:DEF_VR_HAPTICS];
#endif
    [self refreshValueLabels];
    Q3E_Settings_ApplyAll();
}

#if TARGET_OS_VISION
// Restore the tuned 3D defaults (the values dialed in during bring-up).
- (void)reset3DDefaults {
    _hideGunSwitch.on = NO;       // gun visible by default (post-D-022)
    _hideHeadSwitch.on = YES;
    _depthSlider.value = Q3E_DEPTH_DEFAULT;   // 60% — comfort pick after both-eyes fix
    _focusSlider.value = Q3E_FOCUS_DEFAULT;   // convergence out where combat happens
    _dimSlider.value = Q3E_DIM_DEFAULT;       // 80% — perceptual-curve default
    _distSlider.value = 3.6f;     // metres
    _size3DSlider.value = 2.75f;  // half-width metres
    _height3DSlider.value = 0.0f; // eye level, no tilt
    [self changed];
}

// Vision Pro VR (R2 item 6).
- (void)enterVRTapped {
    [self dismissViewControllerAnimated:YES completion:^{
        Q3E_EnterMode(2);   // Q3E_MODE_VR — AppShell_vision.h
    }];
}

// R2.1 fix 9: `q3evrcalibrate` (no args) reads q3e_vrHeadOriginY, which only
// means anything while a VR session is actually tracking — outside VR it is
// 0.0 fresh, or stale from whatever the last session's final frame left it
// at. The OLD handler zeroed the Height trim and queued the command
// UNCONDITIONALLY, before knowing whether the capture would even be
// accepted — tapped from the 2D window (the sheet is reachable there; VR is
// not required to open it), it silently threw away a real trim the player
// had dialed in, for a capture that was refused a moment later with nothing
// to show for it but a console line nobody but a bridge session would see.
//
// `Q3E_QueueCommand` is asynchronous (the funnel drains on the engine
// thread), so this handler cannot wait for the ACTUAL capture's verdict —
// but it does not need to: q3e_vrHeadOriginY and the SAME sanity gate the
// engine itself uses (Q3E_VR_HeightBaselineOK) are both plain, synchronously
// readable state, so the refusal can be predicted here with the identical
// rule the command will apply a moment later, and surfaced in the sheet
// (not just the console) either way.
- (void)vrRecalibrateTapped {
    if (![self vrRecalibrateHeightNow])
        return;
    _vrRecalStatus.text = @"";
}

// R3.5: the ONE statement of what re-calibrating means, because Reset does it
// too and the two buttons disagreeing about it was the bug.
//
// It re-derives the baseline from the head pose the player is standing at right
// now, and it zeroes the trim — the trim is an offset from a baseline, so a
// number dialled against the OLD baseline means nothing against a fresh one.
// Net result either way: the player stands at their own measured eye height.
//
// Returns NO and leaves a reason in the status label when it cannot run, so the
// caller can decide what else to do about that; the status label is not cleared
// here, since a caller that succeeds may have more to say than this does.
- (BOOL)vrRecalibrateHeightNow {
    if (Q3E_GetMode() != 2 /* Q3E_MODE_VR */) {
        _vrRecalStatus.text = @"Only works while VR is open — enter VR, then try again.";
        return NO;
    }
    if (!Q3E_VR_HeightBaselineOK(q3e_vrHeadOriginY)) {
        _vrRecalStatus.text = [NSString stringWithFormat:
            @"Refused: %.2f m is outside 0.60–2.60 m — trim kept as-is.", q3e_vrHeadOriginY];
        return NO;
    }
    Q3E_QueueCommand("q3evrcalibrate");
    // "re-derives baseline, zeroes Height" (charter D11/§14) — the baseline
    // itself is derived live from the current head pose, but the TRIM is a
    // setting this sheet owns, so zeroing it is this sheet's job. Only
    // reachable now once the capture is already known to pass the gate.
    //
    // Idempotent by construction: run twice from the same standing pose, the
    // second capture measures the same metre and writes the same trim.
    _vrHeightSlider.value = 0.0f;
    [self changed];
    return YES;
}

- (void)vrRecenterTapped {
    Q3E_QueueCommand("q3evrrecenter");
}

// R2.2 fix 4: re-read the six VR rows from the store. Called whenever something
// OUTSIDE the sheet changes VR tuning (a console command, the ornament), so the
// widgets -changed writes back from are never older than the store they are
// about to overwrite. A control the player is actively dragging is left alone:
// it is the one widget that is authoritative at that instant, and yanking it
// out from under the finger would be its own bug.
- (void)vrSyncFromStore {
    if (!_vrHeightSlider.isTracking)
        _vrHeightSlider.value = Q3E_VR_GetPersistedHeightTrimMetres() * 39.3701f;
    if (!_vrRenderScaleSlider.isTracking)
        _vrRenderScaleSlider.value = def_float(DEF_VR_RENDERSCALE, Q3E_VR_RENDERSCALE_DEFAULT);
    if (!_vrTurnSpeedSlider.isTracking)
        _vrTurnSpeedSlider.value = def_float(DEF_VR_TURNSPEED, Q3E_VR_TURNSPEED_DEFAULT);
    if (!_vrXhairSlider.isTracking)
        _vrXhairSlider.value = q3e_vr_xhair_row(def_float(DEF_VR_XHAIRSIZE, Q3E_VR_XHAIRSIZE_DEFAULT));
    int snap = (int)def_float(DEF_VR_SNAPTURN, Q3E_VR_SNAPTURN_DEFAULT);
    if (snap >= 0 && snap <= 4) _vrSnapSeg.selectedSegmentIndex = snap;
    int hud = (int)def_float(DEF_VR_HUD, Q3E_VR_HUD_DEFAULT);
    if (hud >= 0 && hud <= 1) _vrHudSeg.selectedSegmentIndex = hud;
    if (!_vrHudSizeSlider.isTracking)
        _vrHudSizeSlider.value = def_float(DEF_VR_HUDSIZE, Q3E_VR_HUDSIZE_DEFAULT);
    if (!_vrHudHeightSlider.isTracking)
        _vrHudHeightSlider.value = def_float(DEF_VR_HUDHEIGHT, Q3E_VR_HUDHEIGHT_DEFAULT);
    _vrXhairOnSwitch.on = ([NSUserDefaults.standardUserDefaults objectForKey:DEF_VR_XHAIRON] != nil)
                              ? [NSUserDefaults.standardUserDefaults boolForKey:DEF_VR_XHAIRON]
                              : (Q3E_VR_XHAIRON_DEFAULT != 0.0f);
    _vrShowHandsSwitch.on = ([NSUserDefaults.standardUserDefaults objectForKey:DEF_VR_SHOWHANDS] != nil)
                                ? [NSUserDefaults.standardUserDefaults boolForKey:DEF_VR_SHOWHANDS]
                                : (Q3E_VR_SHOWHANDS_DEFAULT != 0.0f);
    _vrDamageFlashSwitch.on = ([NSUserDefaults.standardUserDefaults objectForKey:DEF_VR_DAMAGEFLASH] != nil)
                                  ? [NSUserDefaults.standardUserDefaults boolForKey:DEF_VR_DAMAGEFLASH]
                                  : (Q3E_VR_DAMAGEFLASH_DEFAULT != 0.0f);
    // Guarded like every other slider here: a sync that lands mid-drag must not
    // fight the finger holding the control.
    if (!_vrSharpenSlider.isTracking)
        _vrSharpenSlider.value = def_float(DEF_VR_SHARPEN, Q3E_VR_SHARPEN_DEFAULT) * 100.0f;
    int aimh = (int)def_float(DEF_VR_AIMHAND, Q3E_VR_AIMHAND_DEFAULT);
    if (aimh >= 0 && aimh <= 1) _vrAimHandSeg.selectedSegmentIndex = aimh;
    int mbasis = (int)def_float(DEF_VR_MOVEBASIS, Q3E_VR_MOVEBASIS_DEFAULT);
    if (mbasis >= 0 && mbasis <= 3) _vrMoveBasisSeg.selectedSegmentIndex = mbasis;
    int amode = (int)def_float(DEF_VR_AIMMODE, Q3E_VR_AIMMODE_DEFAULT);
    if (amode >= 0 && amode <= 1) _vrAimModeSeg.selectedSegmentIndex = amode;
    if (!_vrAimTrimSlider.isTracking)
        _vrAimTrimSlider.value = def_float(DEF_VR_AIMTRIM, Q3E_VR_AIMTRIM_DEFAULT);
    if (!_vrGunScaleSlider.isTracking)
        _vrGunScaleSlider.value = q3e_vr_gunscale_row(def_float(DEF_VR_GUNSCALE,
                                                                Q3E_VR_GUNSCALE_DEFAULT));
    _vrHapticsSwitch.on = ([NSUserDefaults.standardUserDefaults objectForKey:DEF_VR_HAPTICS] != nil)
                              ? [NSUserDefaults.standardUserDefaults boolForKey:DEF_VR_HAPTICS]
                              : (Q3E_VR_HAPTICS_DEFAULT != 0.0f);
    [self refreshValueLabels];
}

// Restores the six rows above AND re-establishes the height baseline, so that
// the player ends this button at exactly the height Re-calibrate would have put
// them at (charter D11: "also clears the height baseline" — the clearing is the
// mechanism, standing at the calibrated neutral height is the point).
//
// R3.5 — THE INVARIANT: Reset and Re-calibrate leave the player at the SAME
// height, and doing either twice changes nothing.
//
// Reported from glass on 1.0.4.10: Reset made the maintainer slightly shorter and
// Re-calibrate slightly taller. Both were doing what they said and the two
// things said different things. Reset cleared the baseline and stopped there;
// with no baseline the engine publishes no height request at all
// (Q3E_VR_PublishHeight's `!q3e_vrHeightValid` early-out), the player collapses
// onto Quake's own 50-unit eye — 1.5625 m at the default world scale — and
// nothing re-measures until the next VR entry, because the automatic capture
// only runs when the base frame is re-captured. Anyone taller than the marine
// therefore sank, and stayed sunk. Re-calibrate meanwhile measured the head
// where it actually was and lifted them back.
//
// So Reset now re-calibrates as part of what it does, through the same one
// statement of what re-calibrating means. Outside VR there is no head pose to
// measure, so it keeps the old behaviour — clear the baseline, and the automatic
// capture at the next VR entry supplies a fresh one with the trim already at
// zero, which lands on the same invariant one entry later.
- (void)resetVRDefaults {
    _vrHeightSlider.value = Q3E_VR_HEIGHT_DEFAULT;
    _vrRenderScaleSlider.value = Q3E_VR_RENDERSCALE_DEFAULT;
    _vrSnapSeg.selectedSegmentIndex = (NSInteger)Q3E_VR_SNAPTURN_DEFAULT;
    _vrTurnSpeedSlider.value = Q3E_VR_TURNSPEED_DEFAULT;
    _vrXhairSlider.value = q3e_vr_xhair_row(Q3E_VR_XHAIRSIZE_DEFAULT);
    _vrHudSeg.selectedSegmentIndex = (NSInteger)Q3E_VR_HUD_DEFAULT;
    _vrHudSizeSlider.value = Q3E_VR_HUDSIZE_DEFAULT;
    _vrHudHeightSlider.value = Q3E_VR_HUDHEIGHT_DEFAULT;
    _vrXhairOnSwitch.on = (Q3E_VR_XHAIRON_DEFAULT != 0.0f);
    _vrShowHandsSwitch.on = (Q3E_VR_SHOWHANDS_DEFAULT != 0.0f);
    _vrDamageFlashSwitch.on = (Q3E_VR_DAMAGEFLASH_DEFAULT != 0.0f);
    _vrSharpenSlider.value = Q3E_VR_SHARPEN_DEFAULT * 100.0f;
    _vrAimHandSeg.selectedSegmentIndex = (NSInteger)Q3E_VR_AIMHAND_DEFAULT;
    _vrMoveBasisSeg.selectedSegmentIndex = (NSInteger)Q3E_VR_MOVEBASIS_DEFAULT;
    _vrAimModeSeg.selectedSegmentIndex = (NSInteger)Q3E_VR_AIMMODE_DEFAULT;
    _vrAimTrimSlider.value = Q3E_VR_AIMTRIM_DEFAULT;
    _vrGunScaleSlider.value = q3e_vr_gunscale_row(Q3E_VR_GUNSCALE_DEFAULT);
    _vrHapticsSwitch.on = (Q3E_VR_HAPTICS_DEFAULT != 0.0f);
    // R4.0: nothing here for the grip. It has no row to restore and no key to
    // rewrite — the six values are constants, and the one thing that can move
    // them (`q3evrgrip`, session-only) has its own `reset`.
    _vrRecalStatus.text = @"";
    // The stale baseline goes first either way — it is the number this button
    // exists to forget. In VR the re-calibration immediately supplies a fresh
    // one; outside VR the next entry's automatic capture does.
    Q3E_VR_ClearHeightBaseline();
    [self changed];
    if (Q3E_GetMode() == 2 /* Q3E_MODE_VR */) {
        // Runs AFTER -changed, so the trim this writes (zero) is the last word
        // and cannot be overwritten by the row write-back above.
        if ([self vrRecalibrateHeightNow])
            _vrRecalStatus.text = @"";
    }
}
#endif

// Anti-aliasing (r_ext_multisample) is latched — save + apply the cvar, then vid_restart
// to make it take effect. (Kept out of the generic slider path so other tweaks don't
// trigger a renderer restart.)
- (void)msaaChanged {
    [self changed];
    Q3E_QueueCommand("vid_restart");
}

// "Other app audio" — a one-of-N list with a sentence per option. This sheet is
// presented bare (no navigation controller), so wrap and present rather than push.
- (void)openAudioModePicker {
    Q3EAudioModeController *pick =
        [[Q3EAudioModeController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    __weak Q3ESettingsController *weakSelf = self;
    pick.onPick = ^{
        Q3E_Audio_Apply();
        [weakSelf refreshValueLabels];  // update the summary on the row that opened this
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:pick];
    [self presentViewController:nav animated:YES completion:nil];
}

// Close the sheet first — it covers the screen you are about to arrange.
- (void)openLayoutEditor {
    [self dismissViewControllerAnimated:YES completion:^{
        Q3E_Input_BeginLayoutEdit();
    }];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showPaks {
    void Q3E_PresentPakList(UIViewController *from);
    Q3E_PresentPakList(self);
}

@end

// Open settings without a source view — finds the active window's root VC. Used by the
// visionOS ornament so settings is reachable while immersive (live 3D-panel tuning).
void Q3E_OpenSettings(void) {
    // Find any window-scene window with a root VC (prefer the key window). The strict
    // isKeyWindow + foregroundActive filter failed on the SwiftUI window, so be lenient.
    UIViewController *root = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *win in ((UIWindowScene *)s).windows) {
            if (!win.rootViewController) continue;
            if (!root) root = win.rootViewController;      // fallback: first with a root
            if (win.isKeyWindow) { root = win.rootViewController; break; }
        }
        if (root && root.view.window.isKeyWindow) break;
    }
    if (!root) return;
    while (root.presentedViewController) root = root.presentedViewController;   // topmost
    if ([root isKindOfClass:Q3ESettingsController.class]) return;               // already up
    Q3ESettingsController *vc = [Q3ESettingsController new];
    vc.modalPresentationStyle = UIModalPresentationFormSheet;
    [root presentViewController:vc animated:YES completion:nil];
}

void Q3E_PresentSettings(UIView *fromView) {
    UIViewController *root = fromView.window.rootViewController;
    if (!root || root.presentedViewController) return;
    Q3ESettingsController *vc = [Q3ESettingsController new];
    vc.modalPresentationStyle = UIModalPresentationFormSheet;
    [root presentViewController:vc animated:YES completion:nil];
}

#if TARGET_OS_VISION
// R2.2 fix 4: the console/ornament -> open-sheet direction of the one-value
// rule. Called from Q3E_VR_PersistTuning and from Q3EVR.m's height persist,
// both of which run on the ENGINE thread — so the hop to the main queue is not
// optional, and the weak reference means "no sheet on screen" costs one nil
// message send rather than needing its own guard everywhere.
void Q3E_VR_SettingsSheetSync(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [q3e_vr_liveSheet vrSyncFromStore];
    });
}
#endif
