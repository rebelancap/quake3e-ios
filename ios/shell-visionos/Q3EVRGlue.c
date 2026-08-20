// Q3EVRGlue.c — the engine-side half of VR mode: published state, the console
// dump family, synthetic pose injection, and the present-mode sampler.
//
// Everything here is plain C compiled against the engine headers and registered
// with Cmd_AddCommand AFTER Com_Init (the same seam ios_glue.c uses for
// `touchedit`/`q3e_faketouch`), so none of it needs an engine patch.
//
// DUMP RULES, each one paid for on a sibling port:
//   * one flat single-line key=value record per dump, NEVER a raw newline
//     inside it — a multi-line record once let `grep '^MOVENOW '` match a
//     CONTINUATION line and read a stale value as fresh;
//   * publish identity, not just intent (what was actually drawn, not what was
//     meant to be);
//   * label every field with its unit, so `pending=2` can never be read as a
//     queue depth when it was a weapon id;
//   * a monotone `NOWSEQ n` is written LAST in every dump, and assertions
//     require it to ADVANCE. Counting matching lines does not work: the black
//     box rolls its tail and can delete 60 KB at once, so the count can FALL
//     with the app perfectly healthy.

#include <math.h>
#include <stdbool.h>    // the Swift @_cdecl entry points below take C `bool`
#include <stdlib.h>     // strtod: `q3evrgrip <fwd>` validates its one argument
#include "client/client.h"
#include "Q3EVR.h"
#include "Q3ESense.h"

void Q3E_BlackBox_Pin(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void Q3E_BlackBox(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void Q3E_BlackBox_Flush(void);

// Engine bridge (renderervk overlay patches 0006/0007).
extern int VK_Get3DPairs(void);
// Overlay patch 0015: the aim marker's size, and the sky diagnostics.
extern void VK_SetVRXhairScale(float s);
extern void VK_VRSkyString(char *buf, int size);
extern void VK_SetVRSkyToggles(int accOpen, int cullOpen);
extern void VK_GetVRSkyToggles(int *accOpen, int *cullOpen);
// R3.1 item 3: the sky's own GPU state, and the switch that takes the depth
// test out of the sky's way.
extern void VK_VRSkyDrawString(char *buf, int size, int eye);
// Overlay patch 0022 (R4.3 item 3): the Damage Flash gate and the count of
// blood-blend pics it has dropped.
extern void VK_SetVRDamageFlash(int on);
extern int  VK_GetVRDamageBlends(int *suppressed);
// Q3EVisionApp.swift (R4.3 item 1): the VR space's upper-limb visibility.
extern void Q3E_VR_SetShowHands(bool on);
extern void VK_SetVRSkyNoDepth(int on);
extern int  VK_GetVRSkyNoDepth(void);
extern int  cl_vr_xhair_valid, cl_vr_xhair_hit;
extern float cl_vr_xhair_range;
// Overlay patch 0023 (R4.5): the aim marker's two DIAGNOSTIC knobs. Read in
// every build so AIMNOW can state them (they are 0/0 in a public build, where
// the command that sets them is never registered); written only from the dev
// command below.
extern void VK_SetVRXhairProbe(float push, int depthTest);
extern void VK_GetVRXhairProbe(float *push, int *depthTest);

// R2.3 fix 5: the shell's mirror of the two sky diagnostic toggles, so EYENOW
// can report them in every build. They stay 0 in a public build, where the
// commands that set them are not registered at all.
static int q3e_sky_acc_open = 0, q3e_sky_cull_open = 0, q3e_sky_nodepth = 0;

// --- mode ------------------------------------------------------------------
// Written by AppShell_vision.m's Q3E_EnterMode (the single transition owner),
// read from everywhere.
volatile int q3e_mode = Q3E_MODE_2D;
// q3e_frame_owner is defined in the SHARED shell (ios_glue.c): code compiled
// into the iPhone app asks who owns the frame too, and only this build can ever
// answer anything but the display link.

int Q3E_GetMode(void) { return q3e_mode; }

const char *Q3E_ModeName(int mode) {
	switch (mode) {
		case Q3E_MODE_2D: return "2D";
		case Q3E_MODE_3D: return "3D";
		case Q3E_MODE_VR: return "VR";
		default:          return "?";
	}
}

// --- the VR cvar invariant, re-asserted on the engine thread ----------------
//
// R4.4. THE DEFECT: `game_restart` (the only shipped way to change `fs_game`,
// which is CVAR_INIT) left the VR eye path dead — `pairs=` frozen while
// `vrframes=` kept climbing — and `vid_restart` did not recover it; only a
// `q3evr 0` / `q3evr 1` bounce did.
//
// THE ROOT CAUSE is one line of Com_GameRestart: `Cvar_Restart( qtrue )`, which
// UNSETS every CVAR_USER_CREATED and CVAR_VM_CREATED cvar and resets the rest to
// their defaults. VR's per-eye delivery is gated by `r_stereo3d`, which no
// engine code ever registers — the shell CREATES it with `set r_stereo3d 1` on
// entry, so it is USER_CREATED, so the game restart deletes it outright. The
// renderer latches `vk_stereo3d_both` from that cvar once per frame; with the
// cvar gone the latch reads 0, the both-eyes-per-frame path stops running, and
// `vk_stereo3d_pairs` never increments again while the minimized render (which
// counts `vrframes`) carries on exactly as before. That is the whole symptom.
// `vid_restart` cannot recover it because a renderer restart re-reads a cvar
// that no longer exists; the `q3evr` bounce recovers it only because leaving and
// re-entering VR runs the entry path again, and the entry path sets the cvar.
// The same line takes VR's `cg_draw3dIcons 0` override with it — that cvar is
// CVAR_VM_CREATED by the cgame, so the restart unsets it and the freshly loaded
// cgame recreates it at its own default.
//
// THE FIX: the override is not a one-shot at entry, it is an INVARIANT of VR
// mode, so the mode machine asserts it every engine frame instead of assuming
// nothing else will ever clear it. Armed by the same line of q3e_enter_vr that
// establishes it and disarmed by the same line of the teardown that undoes it,
// so there is exactly one statement of when it holds. This is not a blind
// re-bounce of the space: nothing about the space, the compositor, the eye
// images or `vk_stereo3d_wanted` (a plain global, untouched by any cvar reset)
// is disturbed by a game restart — only the two cvars are, and only the two
// cvars are put back. The restore lands at the top of the frame AFTER the one
// that ran the restart, so at most one frame's pairs are missed.
int q3e_vrRearmHook = 1;              // fault injection: `q3evrrearm 0`
static int q3e_vrRearmArmed = 0;      // VR mode owns the two cvars right now
static int q3e_vrRearmLive = 0;       // ...and has established them at least once
static int q3e_vrRearmCount = 0;      // times something BROKE them afterwards

void Q3E_VR_ArmCvarInvariant(int on) {
	q3e_vrRearmArmed = on ? 1 : 0;
	// The count means "times VR's cvars were taken away from it", so the arming
	// window resets with the arming. Without this the ESTABLISHING write — the
	// entry's own first frame, which lands before the queued `set r_stereo3d 1`
	// has drained — would count as a break, and every VR entry in the session
	// would inflate a number whose whole job is to say a game restart happened.
	q3e_vrRearmLive = 0;
}

void Q3E_VR_RearmCvarInvariant(void) {
	int restored = 0;
	if (!q3e_vrRearmArmed || !q3e_vrRearmHook)
		return;
	// r_stereo3d is the eye path's gate. A missing cvar reads as 0 here, which is
	// exactly the state that has to be repaired, so "deleted" and "set to 0" need
	// no distinction.
	// Cvar_Set2(..., qfalse) and NOT Cvar_Set(): `set` — the console path the VR
	// entry has always used — is Cvar_Set2 with force=qfalse, and the difference
	// is not cosmetic. Creating a cvar with force=qtrue registers it with flags
	// ZERO, which makes it look to Cvar_Restart like an engine cvar: it survives
	// a game restart, which sounds like a better fix and is actually a worse one.
	// It would mean this build's r_stereo3d is a DIFFERENT cvar from the shipped
	// one, the defect could no longer be reproduced on demand (`q3evrrearm 0`
	// would have nothing to fail at), and the repair would rest on a flag
	// argument nobody would ever connect to it again. So the cvar keeps exactly
	// the shape it has always had — user-created, deleted by every game restart —
	// and the mode machine simply puts it back.
	if (Cvar_VariableIntegerValue("r_stereo3d") != 1) {
		Cvar_Set2("r_stereo3d", "1", qfalse);
		restored |= 1;
	}
	// cg_draw3dIcons belongs to the cgame. Its ABSENCE also reads as 0 — which is
	// the value VR wants — so this deliberately never CREATES it: writing it
	// before the cgame exists would hand the VM a user-created cvar of its own
	// name, and 0 with no cgame loaded is already the wanted state.
	if (Cvar_VariableIntegerValue("cg_draw3dIcons") != 0) {
		Cvar_Set2("cg_draw3dIcons", "0", qfalse);
		restored |= 2;
	}
	if (!restored) {
		q3e_vrRearmLive = 1;          // the invariant now holds; breaks from here count
	} else if (q3e_vrRearmLive) {
		q3e_vrRearmCount++;
		Q3E_BlackBox_Pin("vr: cvar invariant RESTORED (#%d) — %s%s had been cleared "
		                 "under VR (a game_restart's Cvar_Restart is the known cause)",
		                 q3e_vrRearmCount,
		                 (restored & 1) ? "r_stereo3d " : "",
		                 (restored & 2) ? "cg_draw3dIcons" : "");
	}
}

// --- state published by the VR loop ----------------------------------------
volatile int q3e_vrStop = 0;
volatile int q3e_vrRunning = 0;
volatile int q3e_vrFrameCount = 0;

volatile int q3e_vrUIQuadDrawn = 0;
volatile int q3e_vrPresentWorld = 0;
volatile int q3e_vrPresentReason = Q3E_VRP_NOT_VR;
volatile int q3e_vrClientReason = Q3E_VRP_NOT_VR;
volatile int q3e_vrViews = 0;
volatile int q3e_vrEyePhysW = 0, q3e_vrEyePhysH = 0;
volatile int q3e_vrEyeLogW = 0,  q3e_vrEyeLogH = 0;
volatile int q3e_vrEngineW = 0,  q3e_vrEngineH = 0;
volatile int q3e_vrDepthWanted = 0, q3e_vrDepthLive = 0;
volatile int q3e_vrDepthCopies = 0;
volatile int q3e_vrTracked = 0;
volatile int q3e_vrDropped = 0;
volatile int q3e_vrRepresents = 0;
volatile int q3e_vrEngineTimeouts = 0;
volatile long q3e_vrPubId = 0;
volatile long q3e_vrRenderedId = 0;
float q3e_vrHeadPos[3] = { 0.0f, 0.0f, 0.0f };
float q3e_vrHeadYaw = 0.0f, q3e_vrHeadPitch = 0.0f, q3e_vrHeadRoll = 0.0f;
float q3e_vrHeadOriginY = 0.0f;
float q3e_vrEyeOrigin[2][3];
float q3e_vrEyeTangents[2][4];
float q3e_vrEyeFwdUp = 0.0f;

float q3e_vrWorldScale = 32.0f;    // units per metre (Q3 standing eye 50 u ~ 1.56 m)
float q3e_vrRenderScale = 1.85f;   // R3.3: the device round's pick; range 1.0..2.0

volatile int q3e_vrSynthPose = 0;
float q3e_vrSynthYaw = 0.0f, q3e_vrSynthPitch = 0.0f;
float q3e_vrSynthPos[3] = { 0.0f, 1.60f, 0.0f };
float q3e_vrSynthIPD = 0.0f;
volatile int q3e_vrSynthTanOn = 0;
float q3e_vrSynthTurnAxis = 0.0f;
int   q3e_vrSynthTurnMs = 0;
// R4.6. Held, like the turn stick above and for the same measured reason.
float q3e_vrSynthPadX = 0.0f, q3e_vrSynthPadY = 0.0f;
int   q3e_vrSynthPadMs = 0;
int   q3e_vrSynthPadConn = -1;     // -1 = ask the real controllers
float q3e_vrSynthTan[4] = { -1.0f, 1.0f, -1.0f, 1.0f };

extern int VK_Get3DVRWanted(void);
extern void VK_GetVRCullTangents(int eye, float out[2]);
extern int VK_GetSampleCount(void);
extern int VK_GetVRActive(void);
// Who owns the render extent, and how many writes to it were refused — engine
// side (an archived render-size cvar trying to re-derive it) and shell side (a
// window/geometry path trying to re-size the renderer under VR). Both are
// counted because the failure they describe is invisible when it happens: the
// extent simply comes back wrong, with every step reporting success.
extern int VK_GetVRExtentRefusals(void);
// R1 (overlay patch 0010).
extern void VK_SetVRUIRedirect(int on);
extern int  VK_GetVRUIRedirect(void);
extern int  VK_GetVRUIFrames(void);
extern void VK_GetVREdgeNDC(int eye, float *out4);
extern int  VK_GetVRSwallowed2D(void);
extern void VK_SetVRUIStall(int on);
extern int  VK_GetVRUIStall(void);
extern void VK_GetVRUIAlpha(int *blended, int *additive);
// ios_input.m — the head gyro gate, reported so "no drift" is an observation
// rather than a hope.
extern volatile int q3e_gyro_suppressed;
extern const char *Q3E_RenderSizeOverrideOwner(void);
extern int Q3E_RenderSizeOverrideRefusals(void);
extern volatile int q3e_render_gen;   // ios_glue.c — bumps on every renderer teardown/init
extern int Q3E_VR_RestartSkips(void);
extern int Q3E_VR_BlindWorldFrames(void);

// The engine's CURRENT render extent. Two-phase VR entry polls this to find out
// whether the restart that resizes the per-eye targets has actually landed —
// committing the mode during that restart blits a dying texture.
int Q3E_VR_EngineRenderWidth(void)  { return cls.glconfig.vidWidth; }
int Q3E_VR_EngineRenderHeight(void) { return cls.glconfig.vidHeight; }

// --- present-mode arbitration ----------------------------------------------
const char *Q3E_VR_PresentReasonString(int reason) {
	switch (reason) {
		case Q3E_VRP_WORLD:      return "world";
		case Q3E_VRP_NOT_VR:     return "not-in-vr";
		case Q3E_VRP_NOT_ACTIVE: return "not-connected";
		case Q3E_VRP_UI:         return "menu-up";
		case Q3E_VRP_CONSOLE:    return "console-open";
		case Q3E_VRP_DEMO:       return "demo-playing";
		case Q3E_VRP_CINEMATIC:  return "cinematic";
		case Q3E_VRP_NO_EYES:    return "no-eye-pair-yet";
		case Q3E_VRP_NOT_ARMED:  return "vr-path-not-armed";
		default:                 return "?";
	}
}

// Evaluated on the engine thread, where reading client state is correct; the
// compositor loop consumes the published answer. The arbitration is a
// conjunction, so the ORDER here only decides which term gets NAMED — and the
// name is the whole point (a player who entered VR at the title screen and saw
// a panel needs to be told "this is the menu", not "not connected"). So the
// terms a person can act on are named first.
// R2.2 fix 5: everything the COMPOSITOR thread needs to know about client state,
// sampled on the engine thread and published as plain scalars.
//
// Q3E_VR_ScoreboardLikely and Q3E_VR_GetCrosshairCvars are called from the
// compositor's own render loop, three times a frame, and their first spelling
// read engine-thread-owned structures directly: cls.state/cl.snap (memset out
// from under them by CL_ClearState on any map or mod load) and an unlocked
// Cvar_VariableValue hash-chain walk (a chain the engine thread is inserting
// into, and whose strings it reallocs, during exactly that load). A partially
// linked node or a freed string is a crash in full immersion. Nothing about
// either answer needs to be fresher than the frame it belongs to, so both are
// now taken where every other piece of client state already is — once per
// engine frame, on the engine thread, at the top of the frame — and the
// compositor reads numbers.
static volatile int   q3e_vr_sampledScoreboard = 0;
static volatile float q3e_vr_sampledXhairSize = 24.0f;   // Quake's own defaults, so a
static volatile float q3e_vr_sampledXhairX = 0.0f;       // compositor frame that beats
static volatile float q3e_vr_sampledXhairY = 0.0f;       // the first sample is still sane

// R4.2 item 2: the interactive scoreboard is engine-visible now. Patch 0021
// records the +scores / -scores commands the engine dispatches to the cgame, so
// the case the R2.1 note called a documented residual — "no engine-visible
// signal for the hold-TAB scoreboard" — has one, still with no cgame syscall
// and no fork of the VM.
extern int cl_vr_scores_held;
volatile int q3e_vrScoresHeld = 0;
int q3e_vrScoresHoldHook = 1;

// The engine-thread half: reads the real client state. Static on purpose —
// calling this from anywhere but the sampler is the bug it was written to end.
static int q3e_vr_scoreboard_from_client(void) {
	// The RELEASE is not the end of the scoreboard: cgame fades it out over
	// FADE_TIME (200 ms) after -scores, and dropping the bands back in during
	// that fade is the same tear the hold was fixed to remove, just briefer.
	// So the hold is extended past its own release, by a margin over the fade.
	static int wasHeld = 0;
	static int releaseTime = -1;

	if (cls.state != CA_ACTIVE || !cl.snap.valid) {
		// A key held across a map change releases into a different cgame, and a
		// stale hold would then suppress the bands for a whole session.
		wasHeld = 0;
		releaseTime = -1;
		q3e_vrScoresHeld = 0;
		return 0;
	}

	{
		const int held = (q3e_vrScoresHoldHook && cl_vr_scores_held) ? 1 : 0;
		if (held) {
			releaseTime = -1;
		} else if (wasHeld) {
			releaseTime = cls.realtime;
		}
		wasHeld = held;
		q3e_vrScoresHeld = held;
		if (held) return 1;
		if (releaseTime >= 0 && (cls.realtime - releaseTime) < 350) return 1;
	}

	switch (cl.snap.ps.pm_type) {
		case PM_DEAD:
		case PM_INTERMISSION:
		case PM_SPINTERMISSION:
			return 1;
		default:
			return 0;
	}
}

static void q3e_vr_sample_crosshair_cvars(void) {
	float s = Cvar_VariableValue("cg_crosshairSize");
	float cx = Cvar_VariableValue("cg_crosshairX");
	float cy = Cvar_VariableValue("cg_crosshairY");
	if (!(s > 0.0f)) s = 24.0f;         // 0/negative/never-set: the stock default
	q3e_vr_sampledXhairSize = s;
	q3e_vr_sampledXhairX = isfinite(cx) ? cx : 0.0f;
	q3e_vr_sampledXhairY = isfinite(cy) ? cy : 0.0f;
}

// R3 item 10 — the body's own haptics, taken from client state on the engine
// thread because that is the only thread allowed to read it. Both are TRANSIENT
// taps (<= 40 ms), which is the event type these actuators actually render; a
// short "continuous" buzz is close to nothing on them.
//
// Both hands, deliberately: taking a rocket and hitting the floor are things
// that happen to the PLAYER, not to a hand, and a one-sided thump reads as a
// hit from that side.
static void q3e_vr_haptic_events(void) {
	static int   lastDamage = -1;
	static int   lastGround = -1;
	static float lastVelZ = 0.0f;
	float velZ;

	if (q3e_mode != Q3E_MODE_VR || !q3e_vrHaptics ||
	    cls.state != CA_ACTIVE || !cl.snap.valid) {
		// Forget the history rather than carry it across a map load or a mode
		// change: the first snapshot of a new life would otherwise read as a
		// damage event and a landing at once.
		lastDamage = -1;
		lastGround = -1;
		lastVelZ = 0.0f;
		return;
	}

	if (lastDamage >= 0 && cl.snap.ps.damageEvent != lastDamage)
		for (int h = 0; h < 2; h++)
			Q3E_VR_Haptic(h, 0.6f, 0.035f, "damage");
	lastDamage = cl.snap.ps.damageEvent;

	// Landing: airborne last snapshot, on the ground now, and coming DOWN hard
	// enough that the game itself would have played a land sound. Walking off a
	// step is not a landing.
	velZ = cl.snap.ps.velocity[2];
	if (lastGround == ENTITYNUM_NONE &&
	    cl.snap.ps.groundEntityNum != ENTITYNUM_NONE && lastVelZ < -280.0f)
		for (int h = 0; h < 2; h++)
			Q3E_VR_Haptic(h, 0.35f, 0.03f, "land");
	lastGround = cl.snap.ps.groundEntityNum;
	lastVelZ = velZ;
}

int Q3E_VR_SampleClientState(void) {
	int reason = Q3E_VRP_WORLD;
	int catcher = Key_GetCatcher();
	q3e_vr_haptic_events();
	// R2.2 fix 5: the compositor's copy of the client state, taken here because
	// here is the engine thread. See the block comment above.
	q3e_vr_sampledScoreboard = q3e_vr_scoreboard_from_client();
	q3e_vr_sample_crosshair_cvars();
	if (cls.state == CA_CINEMATIC)             reason = Q3E_VRP_CINEMATIC;
	else if (catcher & KEYCATCH_CONSOLE)       reason = Q3E_VRP_CONSOLE;
	else if (catcher & KEYCATCH_UI)            reason = Q3E_VRP_UI;
	else if (clc.demoplaying)                  reason = Q3E_VRP_DEMO;
	else if (cls.state != CA_ACTIVE)           reason = Q3E_VRP_NOT_ACTIVE;
	q3e_vrClientReason = reason;

	// The 2D redirect is armed from the SAME sample that decides the present
	// mode, and this runs at the TOP of the engine frame, before Com_Frame. That
	// ordering is the whole point: the redirect decides what the frame renders,
	// the arbitration decides how that frame is shown, and taking them from one
	// sample is what makes them agree by construction. Sampling after the frame
	// meant arbitrating this frame's imagery with next frame's answer.
	VK_SetVRUIRedirect((q3e_mode == Q3E_MODE_VR && reason == Q3E_VRP_WORLD) ? 1 : 0);

#ifdef Q3E_DEV_BUILD
	// R2.3 fix 5: one sky line a second while a VR world frame is being built.
	// Emitted from HERE because here is the engine thread — the numbers are
	// renderer state, and reading them from the compositor thread is the class
	// of unlocked cross-thread read a previous round already had to fix. It
	// goes to the ROLLING black-box tail rather than the pinned budget: a
	// once-a-second line over a long session would otherwise push out the
	// evidence the black box exists to keep.
	if (q3e_mode == Q3E_MODE_VR && reason == Q3E_VRP_WORLD) {
		static int lastSkyMs = 0;
		const int now = Sys_Milliseconds();
		if (now - lastSkyMs >= 1000 || now < lastSkyMs) {
			char line[1024];
			lastSkyMs = now;
			VK_VRSkyString(line, (int)sizeof(line));
			Q3E_BlackBox("%s | xhair valid=%d hit=%d range=%.0fu size=%.2fx",
			             line, cl_vr_xhair_valid, cl_vr_xhair_hit,
			             cl_vr_xhair_range, q3e_vrXhairSize);
			// R3.1 item 3: the state fingerprint rides the same 1 Hz tail,
			// LEFT eye only. It answers the half of the question the bounds
			// line cannot, and a device session that has to ask for it
			// separately is a device session that comes back with only one of
			// the two — but both eyes at 1 Hz would treble what this tail
			// costs, and the eyes' state differs in the matrix terms, which
			// `q3evrskydraw` prints for both on demand.
			VK_VRSkyDrawString(line, (int)sizeof(line), 0);
			Q3E_BlackBox("%s", line);
		}
	}
#endif
	return reason;
}

// --- the height gates -------------------------------------------------------
// ONE gate, written NaN-affirmatively: a value is acceptable only if it is
// finite AND inside the range. The obvious spelling — `if (m < LO || m > HI)
// refuse` — ACCEPTS NaN, because every comparison with NaN is false. That is not
// a theoretical concern here: an accepted NaN baseline is persisted, restored on
// the next launch, and turns the ceiling clamp's easing branch into an
// integrator that lifts the camera out of the map at 40 units a second, forever,
// on every launch, with no way for the player to undo it.
int Q3E_VR_HeightBaselineOK(float m) {
	return (isfinite(m) && m >= Q3E_VR_HEIGHT_MIN_M && m <= Q3E_VR_HEIGHT_MAX_M) ? 1 : 0;
}

int Q3E_VR_HeightTrimOK(float m) {
	return (isfinite(m) && m >= -Q3E_VR_TRIM_LIMIT_M && m <= Q3E_VR_TRIM_LIMIT_M) ? 1 : 0;
}

// --- movement basis, turn, height (R1) --------------------------------------
// Written here, consumed by the client seams in cl_input.c. Everything the
// player FEELS lives on this side: the engine half is only the injection point.
extern int   cl_vr_move_basis_active;
extern float cl_vr_move_basis_yaw;
extern float cl_vr_turn_pending;
extern float cl_vr_height_request;
extern float cl_vr_view_yaw;
extern int   cl_vr_move_pre_f, cl_vr_move_pre_r;
extern int   cl_vr_move_sent_f, cl_vr_move_sent_r;
extern float cl_vr_height_rise;

// --- head aim (R2) -----------------------------------------------------------
// cl_input.c's CL_VRApplyHeadAim reads these every client frame and writes the
// result into cl.viewangles; this side only ever publishes what the head is
// doing right now.
extern int   cl_vr_head_aim_active;
extern float cl_vr_head_yaw;
extern float cl_vr_head_pitch;
extern float cl_vr_body_yaw;
extern int   cl_vr_head_aim_hook_enabled;   // fault-injection: `q3evrheadaim 0`
// R2.2 fix 3: the EFFECTIVE pitch the hook is aiming at (head pitch, clamped to
// the engine's own limit) and the switch that drops the delta-angle
// compensation — fault injection for the identity below, `q3evrpitchcomp 0`.
extern float cl_vr_head_pitch_target;
extern int   cl_vr_head_pitch_delta_enabled;

// --- hands (R3) --------------------------------------------------------------
// cl_input.c's own R3 seam: one frame's amnesty for the pitch wrap-clamp when
// the aim moves between the head and a hand. That write is an intentional
// absolute jump from one source's pitch to the other's, and the clamp cannot
// tell it from a tracking spike on its own.
extern int cl_vr_aim_source_changed;
// The renderer's half of the viewmodel re-base (overlay patch 0016).
extern void VK_SetVRGun(int aimHand, float scale, const float grip[3], const float gripAngles[3]);
extern void VK_VRGunString(char *buf, int size);
// R3.5: the resting rear-plane anchor, and the switch that turns it off so the
// mechanism can be compared against its own absence on glass (overlay 0019).
extern void VK_SetVRGunAnchor(int on);
extern int  vk_vr_gun_anchor_on;

int   q3e_vrAimHand = Q3E_VR_HAND_RIGHT;
int   q3e_vrHandAimEnabled = 1;      // fault injection: `q3evrhandaim 0`
// Degrees, +/-10, HAND aim only. R3.6: Q3E_VR_AIM_PITCH_BIAS is zero again, so
// this trim's zero IS the raw controller axis — the aim two device rounds
// converged on from opposite sides. See the constant's own note.
float q3e_vrAimPitchTrim = 0.0f;
int   q3e_vrHaptics = 1;             // Controller Haptics settings row
float q3e_vrGunScale = 0.75f;        // Weapon Size settings row (R3.3 default)

// Session-only grip tuning. Console-driven (`q3evrgrip`) and deliberately not
// persisted: these are a calibration to be dialled in with the headset on, and a
// half-finished drag baked into a config file is worse than starting from the
// shipped guess every session.
//
// R3.4: right -3.0, up +4.0, pitch +2 are MEASURED — the numbers the maintainer read
// back off glass — and they replace the guess described below. Forward keeps its
// -8: the rear-plane anchor (tr_scene.c, patch 0018) is referenced to the
// machinegun, so a forward value tuned before the anchor still places the same
// weapon in the same spot, and what changed is only that every OTHER weapon now
// agrees with it.
//
// The original reasoning, kept because it is why the axes are shaped this way:
// the defaults were a REASONED first guess, not a measurement. Quake 3's cgame
// puts the viewmodel entity at the view origin and lets the `hand` model's own
// geometry place the gun down and to the right of it; re-basing that entity onto
// a controller therefore hangs the gun down-right of the fist by the same
// amount. These offsets pull it back to the hand: back along forward so the grip
// rather than the muzzle sits at the fist, left and up to undo the screen-space
// placement, and 20 degrees of nose-up because a controller is held at an angle
// a gun is not. The maintainer dials the final numbers on glass.
//
// R3.3: yaw and roll are HARDCODED to zero. Tuning never moved either off zero —
// a weapon turned or tilted relative to the hand reads as a bug, not a
// calibration — so their rows went first. The array keeps all three slots: the
// renderer's interface takes a full set of angles, and they are all zero now.
//
// R3.6: all three offsets are measured from the weapon's ANCHOR POINT now, not
// from the game view's origin, so all three defaults are restated. FORWARD runs
// 0..20 and means "how far forward of the fist the gun's rear plane sits" —
// zero puts that plane in the hand. Right and up carry the machinegun's own
// tag_weapon offsets at the shipped Weapon Size (-2.890625 and +7.171875 units
// x 0.75), which is what makes the out-of-box placement the same one 1.0.4.11
// drew from the old numbers.
//
// R3.7: RIGHT, UP and PITCH join yaw and roll as HARDCODES. The R3.6 anchor put
// the weapon's rear plane in the fist, and with that frame in place the three
// trims stopped earning their rows: right settles at -0.5, up and pitch at zero,
// and nothing on glass wanted them anywhere else. Grip Forward is the ONE value
// left to dial.
//
// R4.0: forward is hardcoded too, at -6.0. R3.7 widened the row to -20..+20 to
// find the useful span on glass and the answer came back as a single number
// rather than a span — "-6.0 is right for all situations" — so there is no row
// left to keep, no stored value to read, and nothing in the shipped path that
// can hold a second opinion about where the weapon sits. All six values are
// constants below; `q3evrgrip` is a session-only override for the next round
// that wants to move one (see its own comment).
float q3e_vrGrip[3] = { -6.0f, -0.5f, 0.0f };        // forward=-6, right=-0.5, up=0 (units)
float q3e_vrGripAngles[3] = { 0.0f, 0.0f, 0.0f };    // pitch=0, yaw=0, roll=0 (degrees)

volatile int q3e_vrHandTracked = 0;
volatile int q3e_vrHandHeld = 0;
volatile int q3e_vrHandPresent = 0;
volatile int q3e_vrAimSource = Q3E_VRAIM_HEAD;
volatile int q3e_vrAimSourceSwaps = 0;
float q3e_vrHandYaw[2] = { 0.0f, 0.0f };
float q3e_vrHandPitch[2] = { 0.0f, 0.0f };
float q3e_vrHandPos[2][3];
float q3e_vrAimYaw = 0.0f, q3e_vrAimPitch = 0.0f;

// --- gamepad aim (R4.6) ------------------------------------------------------
// The "Aiming" row, and the accumulator behind its Gamepad state. Written on the
// ENGINE thread only (Q3E_VR_ConsumePadAim runs inside Q3E_Input_Frame, which is
// inside Q3E_Frame), read by the compositor's aim arbitration one frame later at
// worst — the same shape, and the same one-writer rule, as the aim pitch trim.
int   q3e_vrAimMode = Q3E_VRAIMMODE_HEAD;
int   q3e_vrPadAimEnabled = 1;       // fault injection: `q3evrpadaim 0`
float q3e_vrPadAimYaw = 0.0f, q3e_vrPadAimPitch = 0.0f;
float q3e_vrPadAimTurn = 0.0f;
// Whether the pad aim is live yet. Read by the compositor's arbitration: an
// UNSEEDED state is not an aim of zero degrees, it is no aim at all (VR entry
// with the sheet open, before any gameplay input frame has run), and pointing
// the crosshair at the base frame's forward would be a visible lie for exactly
// as long as the player stayed in the menu.
int q3e_vrPadAimSeeded = 0;

// ios_input.m's VR consumer (contexts 1 and 2), reached from here only to drop
// what it is holding when the hands go away.
extern void Q3E_VR_SenseReleaseHeld(void);
extern void Q3E_VR_SenseHeldString(char *buf, int n);
extern int  q3e_vr_sense_ctx_handoff;

void Q3E_VR_ResetHands(void) {
    int h, i;
    q3e_vrHandTracked = q3e_vrHandHeld = q3e_vrHandPresent = 0;
    q3e_vrAimSource = Q3E_VRAIM_HEAD;
    q3e_vrAimYaw = q3e_vrAimPitch = 0.0f;
    for (h = 0; h < 2; h++) {
        q3e_vrHandYaw[h] = q3e_vrHandPitch[h] = 0.0f;
        for (i = 0; i < 3; i++)
            q3e_vrHandPos[h][i] = 0.0f;
    }
    // The consumer's held keys AND the detector's pending edges, together: a
    // session that ends with the trigger down must not leave +attack latched,
    // and the next session must not open by firing the release.
    Q3E_VR_SenseReleaseHeld();
    Q3E_Sense_RebaseEdges();
}

int   q3e_vrMoveBasis = Q3E_VRMOVE_HEAD;
int   q3e_vrTurnMode = Q3E_VRTURN_SMOOTH;
float q3e_vrTurnSpeed = 140.0f;      // degrees per second, smooth mode
float q3e_vrLastSnap = 0.0f;
int   q3e_vrSnapCount = 0;
float q3e_vrHeightBaseline = 0.0f;   // metres, the player's standing eye height
float q3e_vrHeightTrim = 0.0f;       // metres, +/- 0.5
int   q3e_vrHeightValid = 0;
float q3e_vrGammaInv = 1.0f;
float q3e_vrOverbright = 1.0f;

// R3.1 item 3 — the sky fix, as one number. The engine draws sky through
// DEPTH_RANGE_ONE, which under the renderer's reverse-Z is depth exactly 0, and
// 0 is also what the drawable's depth attachment is cleared to, because in
// reverse-Z 0 is infinity and infinity is how "nothing was rendered here" is
// spelled. A compositor that reprojects against depth therefore has nothing to
// reproject where the sky is, and hands back black — which is why the picture
// was only ever wrong on sky, why both R2.3 bypasses were no-ops (the kill is
// downstream of all geometry), why the correct rectangle is the HUD panel's
// footprint and follows its slider (the panel quads write real depth at 1.75 m
// across their whole extent, alpha or no alpha), and why no simulator run could
// ever reproduce it.
//
// 1/8192 at the engine's 0.1 m near plane is roughly 800 metres: past the far
// side of any Quake III map, so nothing sorts differently, and finite, so the
// sky is picture rather than absence. Zero restores the old behaviour exactly.
float q3e_vrEyeDepthFloor = 1.0f / 8192.0f;

// --- 2D-layer region quads (R2 item 4) ---------------------------------------
// The crosshair's own scale (independent of everything else the redirect
// draws) and the HUD's vertical anchor. Read by Q3EVR.m when it places the
// region quads; the values themselves are just numbers until item 4's
// geometry consumes them.
// R3.1 item 1: the marker's angular size, in the units the renderer consumes.
// The device round found the shipped 1.5 too large and settled on 0.5, so 0.5
// is the default and 1.5 is now the ceiling. The settings ROW shows this same
// value remapped to a 1x..5x travel (see ios_settings.m) purely so a fingertip
// drag moves it four times less far; nothing downstream of here sees that
// mapping, and the console keeps these native units.
// R3.4: 0.75 native — the row's 2.0x — after the wider travel let the device
// round place it properly. The range is unchanged, so 0.5 is still reachable.
float q3e_vrXhairSize = 0.75f;       // 0.5 .. 1.5 (R3.4 default: row 2.0x)
// R3.2 item 7 (donor parity): the donor ships a VR Crosshair on/off row beside
// the size one. The engine already refuses to draw the marker at a scale of
// zero, so "off" needs no engine change at all — it is the scale the renderer
// is handed, not a second gate that could disagree with the first.
int   q3e_vrXhairOn = 1;
// --- R4.3, the three donor-parity rows D-VR-R3.2 deferred -------------------
// R4.3 item 1: "Show Hands". Purely a SwiftUI scene property; the value lives
// here so that one statement owns it (settings row, console command and dump
// all read this) and the Swift side is only told when it changes.
int   q3e_vrShowHands = 0;
// R4.3 item 2: "Sharpen", 0..1 as a FRACTION of full CAS (the donor's row is a
// percentage; this is that percentage over 100). Zero is an exact pass-through
// in the shader — which is what made OFF the shippable default for the round
// that added the row, before anyone had seen it on glass.
// R4.5: 0.5, the maintainer's verdict off 1.0.4.15 and the donor's own shipped number.
// Must agree with Q3E_VR_SHARPEN_DEFAULT in ios_settings.m for the same reason
// the HUD height pair below does.
float q3e_vrSharpen = 0.5f;
// R4.3 item 3: "Damage Flash". 1 = draw it (every build so far); 0 = the
// engine drops the cgame's full-screen blood-blend pic. See patch 0022.
int   q3e_vrDamageFlash = 1;
int   q3e_vrHudPos = Q3E_VRHUD_ON;   // On / Off
// The head-locked 2D layer's two controls.
//
//   q3e_vrHudSize    scales each quad's own angular extent (element size)
//   q3e_vrHudHeight  offsets the whole cluster's pitch (where it sits)
//
// R3.1 shipped the second one as a "Panel Size" SPREAD multiplier over each
// quad's angular offset from view centre. The device round read that slider as
// a vertical position control and asked for it to be one, so R3.2 makes it one:
// the spread the 1.0.4.7 default drew is baked in as the layout's shape
// (Q3E_VR_HUD_SPREAD below), and the slider translates the whole cluster
// instead. R3.3 then retunes both on glass: the elements come down to 1.1 and
// the cluster sits two degrees below the layout's own centre. R4.5 returns the
// cluster to zero — the layout's own geometry — after the 1.0.4.15 round read
// the R3.3 trim as low against a HUD that has moved twice since it was dialled.
// This constant and Q3E_VR_HUDHEIGHT_DEFAULT in ios_settings.m are the same
// number stated twice (engine-side default and stored-row default); they have to
// agree, or a boot before the first apply draws a different HUD than after it.
float q3e_vrHudSize = 1.1f;          // 0.8 .. 2.0
float q3e_vrHudHeight = 0.0f;        // degrees, -15 .. +15

// R2.1 fix 7/11: published by Q3EVR.m's render loop each frame so the suite
// can assert what the 2D-layer placement actually decided rather than infer
// it from pixels (the sim's own "Playing in VR" ornament already blinds one
// pixel probe — see item 4's own history).
volatile int q3e_vrRegionsDrawn = 0;
volatile int q3e_vrExclCount = 0;
volatile int q3e_vrScoreboardUp = 0;
// R2.1 fix 7: the region source rects actually used this frame, in virtual
// 640x480 rows/px, so the overlap-margin sizing and the cvar-driven crosshair
// box are numbers the suite can assert instead of pixels it would have to
// guess the layout to interpret.
float q3e_vrNotifyRows = 0.0f;    // NOTIFY source rect height, virtual rows
float q3e_vrMessageRows = 0.0f;   // MESSAGE source rect height, virtual rows
float q3e_vrStatusRows = 0.0f;    // STATUSBAR source rect height, virtual rows
float q3e_vrStatusTopRow = 0.0f;  // STATUSBAR source rect top edge, virtual rows
float q3e_vrStatusPitch = 0.0f;   // STATUSBAR quad centre pitch, degrees
float q3e_vrXhairBoxCX = 0.0f, q3e_vrXhairBoxCY = 0.0f, q3e_vrXhairBoxHalf = 0.0f;   // px

// R2.1 fix 7: an honest, engine-visible signal for "the scoreboard/death
// overlay is probably covering the frame". PM_DEAD is the death-cam/obituary
// overlay; PM_INTERMISSION/PM_SPINTERMISSION are the automatic round/match-end
// scoreboard. R4.2 item 2 adds the third: the interactive hold-TAB scoreboard,
// which R2.1 recorded as a residual limitation because CG_ScoresDown_f's flag
// lives inside the cgame QVM. It still does — what changed is that the two
// commands that set it are dispatched BY the engine (patch 0021), so the state
// is observable without a syscall and without forking the VM (charter ground
// rule 1 intact).
//
// R2.2 fix 5: answers from the engine thread's own sample (above), so the
// compositor thread that asks this every frame never touches cl.snap.
int Q3E_VR_ScoreboardLikely(void) {
	return q3e_vr_sampledScoreboard;
}

// R2.1 fix 7: the crosshair region's source box, sized from the ACTUAL
// cg_crosshairSize/X/Y cvars rather than a fixed 64px guess. Generous, not
// pixel-exact — the pickup-pulse animation doubles cg_crosshairSize
// temporarily and this engine does not know the cgame QVM's exact draw math
// (it is data, never forked), so the box is sized to comfortably contain the
// pulse rather than to trace it. Falls back to Quake's own stock defaults
// (24 / 0 / 0) if the cvars have never been touched, matching the values
// ios_settings.m already applies at boot.
//
// R2.2 fix 5: hands back the engine thread's own sample (above) rather than
// walking the cvar hash chain from the compositor thread.
void Q3E_VR_GetCrosshairCvars(float *size, float *x, float *y) {
	if (size) *size = q3e_vr_sampledXhairSize;
	if (x) *x = q3e_vr_sampledXhairX;
	if (y) *y = q3e_vr_sampledXhairY;
}

// --- quiet setters (R2.1 fix 6/12) -------------------------------------------
// Same state the q3evr* console commands below change, without their console
// dispatch or their dump+NOWSEQ+black-box-flush tail. The commands stay the
// harness's and the console/ornament's entry point (and now, fix 6b, they
// write these same values back to NSUserDefaults — see Q3E_VR_PersistTuning);
// the settings sheet applies through these instead, so a slider drag does not
// pay for diagnostics nobody asked it for.
//
// R2.2 fix 7/12: a MAGNITUDE out of range is CLAMPED, never dropped. The
// dropped-value spelling had two costs that only look separate: the settings
// sheet's own slider ends were not always representable (its Height end
// positions computed 0.50038 m against a 0.50 m limit, so dragging to either
// end applied and persisted nothing at all), and every caller that assumed the
// value had landed — the sheet's last-applied cache, SETTINGSNOW, the one-shot
// settings migration — then recorded a number the engine had never taken. Now
// there is exactly one rule for every tunable, and it is the one the console
// commands already used: clamp into range, and the caller reads the live global
// back to learn what actually happened.
//
// NOT-A-NUMBER is still REFUSED rather than clamped, everywhere. It is not a
// magnitude out of range; a one-sided clamp pair passes it through untouched
// (every comparison with NaN is false), and one NaN inside this state is a
// permanently unusable session — see the height gates' own comment.
static float q3e_vr_clamp_range(float v, float lo, float hi) {
	return (v < lo) ? lo : (v > hi) ? hi : v;
}
void Q3E_VR_SetRenderScaleQuiet(float s) {
	if (!isfinite(s)) return;
	// R3.3: 1.00..2.00. R3.2 dropped the floor to 0.6 to make a genuinely softer
	// eye image reachable, and nobody wanted it — below native the headset reads
	// as broken rather than as economical. The ceiling comes down from 2.5 for
	// the opposite reason: past 2.0 the compositor halves cadence, so the top of
	// the old travel bought edge quality at half the frame rate. The sheet's own
	// slider spans exactly this pair, so no console value lands where the widget
	// cannot show it (the Snap Turn "Off" defect, R2.1 fix 6d).
	q3e_vrRenderScale = q3e_vr_clamp_range(s, 1.0f, 2.0f);
}
void Q3E_VR_SetXhairSizeQuiet(float s) {
	if (!isfinite(s)) return;
	// R3.1 item 1: the ceiling is 1.5, not 3.0 — the size the device round
	// called "much better" is 0.5 and 1.5 is already the largest anyone asked
	// for. Narrowing it here rather than only in the sheet keeps every legal
	// value representable BY the sheet: a range the widget cannot reach is how
	// a console-set value gets silently overwritten by the next unrelated
	// slider drag (the Snap Turn "Off" defect, R2.1 fix 6d).
	q3e_vrXhairSize = q3e_vr_clamp_range(s, 0.5f, 1.5f);
	// R2.3 fix 2: the marker is drawn by the engine now, so the value has to
	// reach it. Pushed from the ONE quiet setter every path already funnels
	// through (sheet, console command, boot apply), not from each of them.
	VK_SetVRXhairScale(q3e_vrXhairOn ? q3e_vrXhairSize : 0.0f);
}
void Q3E_VR_SetXhairOnQuiet(int on) {
	q3e_vrXhairOn = on ? 1 : 0;
	// Through the size setter, so there is exactly one statement in the program
	// that decides what scale the renderer is holding.
	Q3E_VR_SetXhairSizeQuiet(q3e_vrXhairSize);
}
// --- R4.3 ------------------------------------------------------------------
// Show Hands. The Swift side is told only on a CHANGE, and it re-checks the
// same equality itself: publishing an unchanged value on every settings apply
// would re-evaluate the whole scene (and with it the open ImmersiveSpace) for
// nothing, on a thread hop, dozens of times per slider drag.
void Q3E_VR_SetShowHandsQuiet(int on) {
	on = on ? 1 : 0;
	if (on == q3e_vrShowHands)
		return;
	q3e_vrShowHands = on;
	Q3E_VR_SetShowHands(on ? true : false);
}
// Sharpen. Stored as a fraction; clamped here rather than only in the sheet so
// that a console value and a row value cannot mean different things (the Snap
// Turn "Off" defect, R2.1 fix 6d).
void Q3E_VR_SetSharpenQuiet(float f) {
	if (!isfinite(f)) return;
	q3e_vrSharpen = q3e_vr_clamp_range(f, 0.0f, 1.0f);
}
// Damage Flash. The engine holds its own copy (patch 0022) because the draw it
// gates happens inside the renderer, which is compiled for the oracle and the
// iPhone too — the same reasoning VK_SetVRXhairScale was written with.
void Q3E_VR_SetDamageFlashQuiet(int on) {
	q3e_vrDamageFlash = on ? 1 : 0;
	VK_SetVRDamageFlash(q3e_vrDamageFlash);
}
void Q3E_VR_SetHudSizeQuiet(float s) {
	if (!isfinite(s)) return;
	q3e_vrHudSize = q3e_vr_clamp_range(s, 0.8f, 2.0f);
}
void Q3E_VR_SetHudHeightQuiet(float deg) {
	if (!isfinite(deg)) return;
	q3e_vrHudHeight = q3e_vr_clamp_range(deg, -15.0f, 15.0f);
}
// R4.0: THE WHOLE GRIP IS A CONSTANT. R3.3 hardcoded yaw and roll, R3.7 right,
// up and pitch, and this round takes the last one: the maintainer's verdict off the
// -20..+20 dialling row was "-6.0 is right for all situations", which is an
// answer to the question the row was asked, not a request for a narrower row.
//
// These six numbers ARE the shipped placement. Nothing reads a stored value to
// arrive at them — the settings sheet has no grip row, NSUserDefaults holds no
// grip key (the v11 migration deletes the last one), and the boot path is the
// initialiser on q3e_vrGrip/q3e_vrGripAngles above. The one way to move the
// grip is `q3evrgrip`, session-only, which exists so the next round that wants
// to re-open the question has an instrument for it.
#define Q3E_VR_GRIP_FWD_FIXED   (-6.0f)   // forward, game units
#define Q3E_VR_GRIP_RIGHT_FIXED (-0.5f)   // right, game units
#define Q3E_VR_GRIP_UP_FIXED    0.0f      // up, game units
#define Q3E_VR_GRIP_PITCH_FIXED 0.0f      // degrees
// The override's own limits. Wider than any value the shipped set uses, because
// this is the instrument for asking a new question — but still bounded, so a
// mistyped exponent cannot put the weapon in the next room where the player
// cannot see it to correct the number that sent it there (the R3.3 rule).
#define Q3E_VR_GRIP_OFF_LIMIT   20.0f     // units, each of forward/right/up
#define Q3E_VR_GRIP_ANG_LIMIT   20.0f     // degrees, each of pitch/yaw/roll

// Put the live grip back to the six constants. The initialiser's own statement,
// reachable at runtime — `q3evrgrip reset` and nothing else calls it.
static void Q3E_VR_GripToDefaults(void) {
	q3e_vrGrip[0] = Q3E_VR_GRIP_FWD_FIXED;
	q3e_vrGrip[1] = Q3E_VR_GRIP_RIGHT_FIXED;
	q3e_vrGrip[2] = Q3E_VR_GRIP_UP_FIXED;
	q3e_vrGripAngles[0] = Q3E_VR_GRIP_PITCH_FIXED;
	q3e_vrGripAngles[1] = 0.0f;
	q3e_vrGripAngles[2] = 0.0f;
}

// The session-only override behind `q3evrgrip`. Deliberately NOT called by the
// settings sheet or by any boot path: those used to run through a "quiet setter"
// that forced the hardcoded values, and with every value hardcoded that setter
// had become a function whose entire behaviour was to ignore its arguments. What
// replaces it is smaller and says what it does — a caller that passes six
// numbers gets six numbers, clamped, until the process ends.
void Q3E_VR_SetGripOverride(const float offsets[3], const float angles[3]) {
	int i;
	if (!offsets || !angles) return;
	for (i = 0; i < 6; i++) {
		const float v = (i < 3) ? offsets[i] : angles[i - 3];
		if (!isfinite(v)) return;   // all six or none: a half-applied grip is a lie
	}
	for (i = 0; i < 3; i++) {
		q3e_vrGrip[i] = q3e_vr_clamp_range(offsets[i], -Q3E_VR_GRIP_OFF_LIMIT,
		                                   Q3E_VR_GRIP_OFF_LIMIT);
		q3e_vrGripAngles[i] = q3e_vr_clamp_range(angles[i], -Q3E_VR_GRIP_ANG_LIMIT,
		                                         Q3E_VR_GRIP_ANG_LIMIT);
	}
	VK_SetVRGun((q3e_vrAimHand == Q3E_VR_HAND_LEFT) ? 0 : 1,
	            q3e_vrGunScale, q3e_vrGrip, q3e_vrGripAngles);
}
void Q3E_VR_SetHudPosQuiet(int pos) {
	// An ENUM, not a magnitude: there is no "nearest legal HUD position" to
	// clamp an unknown number to, so an unknown one is kept out and the live
	// value stands. Callers read that live value back, so nothing downstream
	// believes an unknown position was applied.
	if (pos < Q3E_VRHUD_ON || pos > Q3E_VRHUD_OFF) return;
	q3e_vrHudPos = pos;
}
void Q3E_VR_SetTurnQuiet(int mode, float speedDegPerSec) {
	if (mode >= Q3E_VRTURN_SMOOTH && mode <= Q3E_VRTURN_OFF)
		q3e_vrTurnMode = mode;      // enum: see the HUD position note above
	if (isfinite(speedDegPerSec))
		q3e_vrTurnSpeed = q3e_vr_clamp_range(speedDegPerSec, 60.0f, 260.0f);
}

// Push the finished basis into the client. Called once per engine frame from the
// VR loop, with the head pose that frame is being rendered with.
//
// The basis is expressed as an ABSOLUTE yaw rather than a delta so the client
// can compute the difference against its own authoritative accumulator — the
// value it will actually put in the packet — instead of against a copy of it
// that could be a frame out.
void Q3E_VR_PublishMoveBasis(void) {
	if (q3e_mode != Q3E_MODE_VR || q3e_vrMoveBasis == Q3E_VRMOVE_OFF) {
		cl_vr_move_basis_active = 0;
		return;
	}
	// HEAD is the only basis with a source this round; the hand bases arrive with
	// the hands. Naming them now and resolving them to the head is honest — an
	// option that silently does something else is worse than one that does not
	// exist yet.
	//
	// R2.1 fix 2: whether q3e_vrHeadYaw belongs in this sum depends ENTIRELY on
	// whether CL_VRApplyHeadAim actually folded it into cl.viewangles[YAW] this
	// frame. When the hook is enabled (the shipping state), cl_vr_view_yaw is
	// sampled in CL_FinishMove AFTER that write — it is already body_yaw +
	// head_yaw, i.e. the aim IS the gaze direction. Adding q3e_vrHeadYaw again
	// here double-counts the same turn: a 60-degree head yaw would move the
	// player at body+120 degrees, the exact R1 device bug patch 0013 was
	// written to fix, reintroduced by the basis math that never learned about
	// it. So in head-aim mode the basis is the aim yaw AS-IS — the movement
	// delta (basisyaw - aimyaw) is ~0 by construction, because movement IS
	// where the player is looking.
	//
	// When the hook is disabled (`q3evrheadaim 0` — the fault-injection /
	// pre-R2 comparison path), CL_VRApplyHeadAim never touches cl.viewangles,
	// so cl_vr_view_yaw stays body-only and the OLD (R1) formula — add the
	// head's yaw on top of a body-only aim — is what still points movement at
	// the head. Both paths are exercised by the suite (MOVENOW section 4b-v).
	//
	// R3: the basis is now a real choice, because the aim and the head are no
	// longer the same direction. cl_vr_view_yaw is body + AIM; the basis wanted
	// is body + CHOSEN, so the correction is (chosen - aim) — which is exactly
	// zero in the head/head case above and stays zero-cost there.
	//
	// A hand basis that is not tracked falls back to the HEAD rather than to
	// nothing: "Off hand" with the off hand on a table has to mean something,
	// and standing still is the one answer a movement setting must never give.
	{
		const int aimIdx = (q3e_vrAimHand == Q3E_VR_HAND_LEFT) ? 0 : 1;
		const int offIdx = aimIdx ^ 1;
		float chosen = q3e_vrHeadYaw;
		if (q3e_vrMoveBasis == Q3E_VRMOVE_AIM_HAND && (q3e_vrHandTracked & (1 << aimIdx)))
			chosen = q3e_vrHandYaw[aimIdx];
		// R4.6: with the stick aiming there IS no aim hand, and falling back to
		// the head would make "Aim" mean "Head" in the one mode where the two are
		// deliberately different directions. The aim is the aim: this resolves to
		// the live aim yaw, which makes Gamepad + Aim exactly the flat game's
		// controls (you walk where you point) and costs nothing — the correction
		// below is then zero by construction, same as the head/head case.
		// R4.7 makes that even more literal: the pad aim yaw IS the body's
		// forward, so "Aim" here is the body, which is what walking where you
		// point means once the stick turns the body rather than an offset.
		else if (q3e_vrMoveBasis == Q3E_VRMOVE_AIM_HAND && Q3E_VR_PadAimActive())
			chosen = q3e_vrAimYaw;
		else if (q3e_vrMoveBasis == Q3E_VRMOVE_OFF_HAND && (q3e_vrHandTracked & (1 << offIdx)))
			chosen = q3e_vrHandYaw[offIdx];
		cl_vr_move_basis_yaw = cl_vr_head_aim_hook_enabled
		                          ? AngleMod(cl_vr_view_yaw + (chosen - q3e_vrAimYaw))
		                          : AngleMod(cl_vr_view_yaw + chosen);
	}
	cl_vr_move_basis_active = 1;
}

// Push this frame's head yaw/pitch into the client so CL_VRApplyHeadAim can
// fold them into cl.viewangles. Called from the same place and at the same
// cadence as Q3E_VR_PublishMoveBasis — once per engine frame, with the head
// pose that frame is being rendered with, so the render and the aim are never
// a frame apart.
//
// Pitch is clamped here too, belt-and-braces: asinf()'s range already keeps
// q3e_vrHeadPitch inside +/-90, but the accumulator this feeds is the same one
// mouse/pad aim uses, and every write into it stays inside the bound the way
// every OTHER write into it does.
void Q3E_VR_PublishHeadAim(void) {
	if (q3e_mode != Q3E_MODE_VR) {
		cl_vr_head_aim_active = 0;
		return;
	}
	// R3: the ACTIVE AIM SOURCE's yaw/pitch, not the head's. The two are the
	// same number in Convenience Mode, and the arbitration that picks between
	// them happens once, on the compositor, in the same frame the eyes are
	// composed — so what the engine aims with and what the renderer removes from
	// the eye pose are one decision rather than two that have to agree.
	//
	// The engine-side symbols keep their R2 names (cl_vr_head_yaw/pitch): what
	// they have always meant to CL_VRApplyHeadAim is "the VR aim offset the body
	// accumulator rides on", and that is exactly what a hand supplies. Renaming
	// them would be churn in the one file whose behaviour must not change.
	cl_vr_head_yaw = q3e_vrAimYaw;
	// R2.1 fix 1: q3e_vrHeadPitch is ARKit's own convention — asinf(hf.y) in
	// Q3EVR.m is POSITIVE when the head tilts UP (hf.y > 0 in ARKit's Y-up
	// frame). Quake's pitch is the opposite sign: AngleVectors's forward[2] =
	// -sin(pitch), so a POSITIVE Quake pitch looks DOWN. Handing ARKit's
	// unconverted value to cl.viewangles[PITCH] therefore aimed every shot the
	// wrong way — look up 30 degrees and the aim (and the newly-visible
	// viewmodel) pitched DOWN 30 instead. This is the one seam where "head
	// telemetry" becomes "an aim value fed to the engine's own convention", so
	// the negation belongs exactly here, not at the ARKit-facing computation
	// in Q3EVR.m (which stays an honest, unconverted description of the
	// physical head pose for HEADNOW and any future ARKit-space consumer).
	//
	// R3: the same negation, applied to whichever source is aiming. A hand's
	// pitch comes out of the SAME ARKit-facing computation the head's does
	// (asinf of the pose's forward Y in the base frame), so it carries the same
	// convention and takes the same conversion. One rule, one place.
	{
		const float quakePitch = -q3e_vrAimPitch;
		cl_vr_head_pitch = (quakePitch > 90.0f) ? 90.0f
		                  : (quakePitch < -90.0f) ? -90.0f : quakePitch;
	}
	cl_vr_head_aim_active = 1;
}

// The camera rise the height calibration asks for, in game units. Deviation
// form: how much TALLER the player is than the character, times the world scale.
// A player of exactly the character's height asks for zero.
void Q3E_VR_PublishHeight(void) {
	if (q3e_mode != Q3E_MODE_VR || !q3e_vrHeightValid || q3e_vrWorldScale <= 0.0f) {
		cl_vr_height_request = 0.0f;
		return;
	}
	{
		const float characterEye_m = Q3E_VR_CHARACTER_EYE_U / q3e_vrWorldScale;
		float rise_m = (q3e_vrHeightBaseline + q3e_vrHeightTrim) - characterEye_m;
		cl_vr_height_request = rise_m * q3e_vrWorldScale;
	}
}

// Capture the standing eye height, ONCE, sanity-gated. Anything outside 0.6-2.6 m
// is not a person standing up — it is a tracking glitch, a headset on a table, or
// a session that started before world tracking settled — and accepting it would
// bury the camera in the floor or the ceiling with no way for the player to tell
// what happened.
int Q3E_VR_CaptureHeight(float metres) {
	if (!Q3E_VR_HeightBaselineOK(metres)) {
		Q3E_BlackBox_Pin("vr: height capture REFUSED — %.2f m is not a finite value inside "
		                 "%.2f-%.2f m (baseline kept: %s)", metres,
		                 Q3E_VR_HEIGHT_MIN_M, Q3E_VR_HEIGHT_MAX_M,
		                 q3e_vrHeightValid ? "yes" : "none yet");
		return 0;
	}
	q3e_vrHeightBaseline = metres;
	q3e_vrHeightValid = 1;
	Q3E_BlackBox_Pin("vr: height baseline captured at %.2f m (character eye is %.2f m at "
	                 "%.1f u/m, so the camera rises %.2f m)",
	                 metres, Q3E_VR_CHARACTER_EYE_U / q3e_vrWorldScale, q3e_vrWorldScale,
	                 metres - Q3E_VR_CHARACTER_EYE_U / q3e_vrWorldScale);
	return 1;
}

// The right stick's X axis, in VR, is the TURN. Returns 1 when it consumed the
// axis, so the caller can zero it and no second context emits for the same input.
//
// The snap hysteresis is deliberately wide (fire above 0.6, re-arm below 0.4):
// a single threshold makes a stick resting near it chatter, which in VR is the
// world flicking back and forth under a thumb the player thinks is still.
int Q3E_VR_ConsumeTurnAxis(float x, float dt) {
	static int armed = 1;
	if (q3e_mode != Q3E_MODE_VR)
		return 0;
	// OFF means the stick does NOT turn the player — which requires CONSUMING the
	// axis and discarding it. Returning "not consumed" hands it straight back to
	// the legacy mouse-look path, so the setting that switches turning off turns
	// the player anyway, through a different seam.
	if (q3e_vrTurnMode == Q3E_VRTURN_OFF)
		return 1;
	// A HELD synthetic deflection, for the simulator. It has to be a hold rather
	// than a one-shot because the pad layer calls this every frame with the real
	// stick — which reads 0.0 with no controller attached, and a 0.0 between two
	// injected deflections RE-ARMS the hysteresis, so a one-shot injection fires
	// on every single call and measures nothing. Holding the value is also the
	// only way to test the property that matters: a stick held past the threshold
	// must turn ONCE.
	if (q3e_vrSynthTurnMs > 0) {
		const int now = Sys_Milliseconds();
		if (now < q3e_vrSynthTurnMs) x = q3e_vrSynthTurnAxis;
		else q3e_vrSynthTurnMs = 0;
	}
	if (q3e_vrTurnMode == Q3E_VRTURN_SMOOTH) {
		cl_vr_turn_pending -= x * q3e_vrTurnSpeed * dt;
		return 1;
	}
	{
		const float mag = fabsf(x);
		float step = 45.0f;
		if (q3e_vrTurnMode == Q3E_VRTURN_SNAP30) step = 30.0f;
		else if (q3e_vrTurnMode == Q3E_VRTURN_SNAP60) step = 60.0f;
		if (armed && mag > 0.6f) {
			const float delta = (x > 0.0f) ? -step : step;
			cl_vr_turn_pending += delta;
			q3e_vrLastSnap = delta;
			q3e_vrSnapCount++;
			armed = 0;
			// R3 item 10: a tap on the hand that turned, so a snap has a
			// physical edge to it rather than only a visual one. On the AIM
			// hand because that is the stick that fired it.
			Q3E_VR_Haptic((q3e_vrAimHand == Q3E_VR_HAND_LEFT) ? 0 : 1,
			              0.4f, 0.03f, "snapturn");
		} else if (!armed && mag < 0.4f) {
			armed = 1;
		}
	}
	return 1;
}

// --- gamepad aim (R4.6, composition corrected in R4.7) -----------------------
//
// the maintainer's ask, restated after the 1.0.4.16 device round: classic stick aiming
// "like 2D or 3D stereo does" — the stick TURNS THE VIEW, continuously, and the
// crosshair stays pinned at the centre of the game's forward direction, for a
// player holding an ordinary pad with no Sense controllers in the room.
//
// R4.6 read that as a bounded aim OFFSET — a +/-40 degree cone around the head
// that the crosshair wandered inside, spilling into a body turn at the edge. On
// glass that is the wrong shape: "to aim right at an enemy you have to move your
// crosshair all the way right to PUSH your viewport to look right, then move the
// crosshair BACK to the enemy". The cone, the spill and the whole edge mechanism
// are GONE. What replaces them is smaller, not bigger:
//
//   - the stick's X goes straight into cl_vr_turn_pending, the accumulator the
//     turn stick has always used, at the flat game's own look rate. The body
//     turns; the render, the aim and the movement basis all turn with it because
//     they are all built out of the body yaw. That is "the world rotates right".
//   - the aim YAW is pinned at ZERO — the body's own forward. cl.viewangles is
//     body+aim (CL_VRApplyHeadAim), so an aim of zero means the game aims exactly
//     where the body points, which is what the flat game's centred crosshair
//     means. The marker (patch 0015) is placed along the effective aim and lands
//     there with no change of its own.
//   - the eye composition removes the aim yaw and re-applies the head's, so the
//     camera is still body+head: the player can glance around freely without
//     moving the aim. THAT is the VR part, and it is the R3 hand identity
//     unchanged.
//   - the aim PITCH is the stick's, through the delta-compensated write in patch
//     0014 like every other source, clamped to +/-85 — and R4.8 makes it the
//     WORLD's pitch as well. The maintainer, on 1.0.4.17: "keep my crosshair at the
//     center of the screen. THE VERY CENTER." So the compositor pitches the
//     published EYE POSE by this same angle (Q3EVR.m, `worldPitch`), which is
//     the only place a world pitch can enter — R_VRComposeEye's body basis is
//     yaw-only by design, so there is nothing to double-count it against. The
//     camera pitches like the flat game's, the head's own pitch stays additive
//     on top for glancing, and the crosshair sits at the view centre on BOTH
//     axes. Comfort is the maintainer's explicit call: no offset, no cone, no softening.
//
// The Turn row does NOT gate this. That row decides what the right stick does in
// HEAD aim; choosing Gamepad aim IS a decision about the same stick, and a "Turn:
// Off" that silently left the player unable to turn OR aim would be a mode with
// no yaw at all. Snap likewise cannot express a continuous look — in this mode
// the turn is always smooth. Both recorded in D-VR-R4.7 rather than approximated.
int Q3E_VR_PadAimActive(void) {
	const int aimIdx = (q3e_vrAimHand == Q3E_VR_HAND_LEFT) ? 0 : 1;
	if (q3e_mode != Q3E_MODE_VR)
		return 0;
	if (q3e_vrAimMode != Q3E_VRAIMMODE_PAD || !q3e_vrPadAimEnabled)
		return 0;
	// No pad, no stick aim — and the row that would say so is hidden in that
	// state, so a stored "Gamepad" with the pad since unpaired would otherwise
	// leave the player with a crosshair frozen at the gaze and no visible way
	// back. The fallback is head aim, which is what the hidden row means.
	if (!Q3E_VR_PlainPadConnected())
		return 0;
	// Hand aim precedence is UNCHANGED by this row: while the aim hand is
	// tracked it owns the aim exactly as it did before, whatever the row says.
	// (The compositor's own arbitration adds two frames of hysteresis on the way
	// down; this reads the published tracked mask, so the accumulator can start
	// running one frame before the compositor switches to it. It seeds from the
	// head either way, so the extra frame changes nothing anyone can see.)
	if ((q3e_vrHandTracked & (1 << aimIdx)) && q3e_vrHandAimEnabled)
		return 0;
	return 1;
}

void Q3E_VR_PadAimReseed(void) {
	q3e_vrPadAimSeeded = 0;
}

int Q3E_VR_ConsumePadAim(float ax, float ay, float dt) {
	float wantPitch;

	if (!Q3E_VR_PadAimActive()) {
		// Not ours: forget the accumulator so the next time this mode comes up
		// the crosshair starts at the gaze rather than wherever a previous
		// session's stick left it.
		q3e_vrPadAimSeeded = 0;
		q3e_vrPadAimTurn = 0.0f;
		return 0;
	}
	// A HELD synthetic deflection, for the simulator, which has no controllers —
	// same shape as q3evrturnstick, same reason (see its comment).
	if (q3e_vrSynthPadMs > 0) {
		const int now = Sys_Milliseconds();
		if (now < q3e_vrSynthPadMs) { ax = q3e_vrSynthPadX; ay = q3e_vrSynthPadY; }
		else q3e_vrSynthPadMs = 0;
	}
	// Consumed either way once we are the owner of this stick: refusing a bad
	// number back to the caller would hand the same axis to the turn seam, which
	// is the one outcome worse than ignoring the frame.
	if (!isfinite(ax) || !isfinite(ay) || !isfinite(dt) || dt <= 0.0f)
		return 1;
	if (!q3e_vrPadAimSeeded) {
		// The pitch adopts the gaze so switching rows does not jump the aim
		// vertically; the yaw has nothing to seed, because from R4.7 it is not
		// an accumulator at all — the aim is the body's forward and the STICK
		// moves the body.
		q3e_vrPadAimPitch = q3e_vrHeadPitch;
		if (q3e_vrPadAimPitch >  Q3E_VR_PADAIM_PITCH_LIMIT)
			q3e_vrPadAimPitch =  Q3E_VR_PADAIM_PITCH_LIMIT;
		else if (q3e_vrPadAimPitch < -Q3E_VR_PADAIM_PITCH_LIMIT)
			q3e_vrPadAimPitch = -Q3E_VR_PADAIM_PITCH_LIMIT;
		q3e_vrPadAimSeeded = 1;
	}
	// YAW: the stick turns the BODY, at the flat game's own look rate, through
	// the accumulator CL_VRTurn consumes and CL_VRApplyHeadAim folds into the
	// body yaw. Stick RIGHT is a DECREASING yaw — the ARKit/Quake convention the
	// head, the hands and the turn seam all already spell the same way.
	q3e_vrPadAimTurn = -ax * Q3E_VR_PADAIM_SPEED * dt;
	cl_vr_turn_pending += q3e_vrPadAimTurn;
	// ...and the aim itself is body forward, always. Written every frame rather
	// than once, so no recentre, mode switch or stale accumulator can leave an
	// offset in it: the crosshair sits at the centre of the game's forward
	// direction by construction, which is the whole correction R4.7 is.
	q3e_vrPadAimYaw = 0.0f;

	// PITCH is a real accumulator, and from R4.8 it is the WORLD's pitch: the
	// compositor rotates the published eye pose by this angle, so the camera
	// pitches with the aim exactly as the body turns with it. It stops short of
	// the engine's own ceiling.
	wantPitch = q3e_vrPadAimPitch + ay * Q3E_VR_PADAIM_SPEED * dt;
	if (wantPitch >  Q3E_VR_PADAIM_PITCH_LIMIT) wantPitch =  Q3E_VR_PADAIM_PITCH_LIMIT;
	else if (wantPitch < -Q3E_VR_PADAIM_PITCH_LIMIT) wantPitch = -Q3E_VR_PADAIM_PITCH_LIMIT;
	q3e_vrPadAimPitch = wantPitch;
	return 1;
}

void Q3E_VR_SetAimModeQuiet(int mode) {
	// An ENUM: an unknown value keeps the live one (the HUD position note).
	if (mode < Q3E_VRAIMMODE_HEAD || mode > Q3E_VRAIMMODE_PAD)
		return;
	if (mode != q3e_vrAimMode) {
		q3e_vrAimMode = mode;
		// The aim is about to change source. Start it where the player is
		// already looking rather than at a stale accumulator.
		q3e_vrPadAimSeeded = 0;
	}
}

// --- dump plumbing ----------------------------------------------------------
static int q3e_vr_seq = 0;

// One record. Goes to the console (so the remote bridge sees it) and to the
// black box's pinned region (so the headset user can send the file back —
// console-only diagnostics are a defect).
static void q3e_vr_emit(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void q3e_vr_emit(const char *fmt, ...) {
	char line[1024];
	va_list ap;
	va_start(ap, fmt);
	Q_vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	// Defensive: a record with an embedded newline is exactly the failure the
	// dump rules exist to prevent, so flatten rather than trust the callers.
	for (char *p = line; *p; p++) {
		if (*p == '\n' || *p == '\r') *p = ' ';
	}
	Com_Printf("%s\n", line);
	Q3E_BlackBox_Pin("%s", line);
}

// LAST line of every dump. Freshness a front-trim cannot eat.
static void q3e_vr_nowseq(void) {
	q3e_vr_seq++;
	Com_Printf("NOWSEQ %d\n", q3e_vr_seq);
	Q3E_BlackBox_Pin("NOWSEQ %d", q3e_vr_seq);
	Q3E_BlackBox_Flush();
}

static void q3e_dump_mode(void) {
	// R4.4: the cvar invariant rides the mode dump, because it IS mode state —
	// armed says VR claims the two cvars, rearms counts the times something
	// (a game restart) had actually taken them away, and stereo3d is the gate
	// itself read live, so a run can tell "never broke" from "broke and was put
	// back" from "broke and stayed broken".
	q3e_vr_emit("MODENOW mode=%s owner=%s present=%s reason=%d(%s) clientreason=%d(%s) "
	            "vrframes=%d stop=%d running=%d tracked=%d synthpose=%d "
	            "rearm=%s rearmhook=%d rearms=%d stereo3d=%d",
	            Q3E_ModeName(q3e_mode),
	            q3e_frame_owner == Q3E_FRAME_OWNER_VR ? "vr" : "link",
	            q3e_vrPresentWorld ? "world" : "panel",
	            q3e_vrPresentReason, Q3E_VR_PresentReasonString(q3e_vrPresentReason),
	            q3e_vrClientReason, Q3E_VR_PresentReasonString(q3e_vrClientReason),
	            q3e_vrFrameCount, q3e_vrStop, q3e_vrRunning,
	            q3e_vrTracked, q3e_vrSynthPose,
	            q3e_vrRearmArmed ? "armed" : "off", q3e_vrRearmHook, q3e_vrRearmCount,
	            Cvar_VariableIntegerValue("r_stereo3d"));
}

static void q3e_dump_eye(void) {
	// The physical/logical distinction is the single most expensive sizing
	// mistake available here: cp_view_texture_map_get_viewport() returns the
	// foveation-EXPANDED logical raster area, which the rate map compresses into
	// a much smaller physical texture. Engine targets are sized from the
	// PHYSICAL texture; the blit still rasterises into the logical viewport with
	// the rate map attached. Both numbers ride in the dump so the distinction
	// cannot quietly rot.
	int dmgSeen = 0, dmgDropped = 0;
	dmgSeen = VK_GetVRDamageBlends(&dmgDropped);
	float ratio = 1.0f;
	if (q3e_vrEyePhysW > 0 && q3e_vrEyePhysH > 0) {
		ratio = ((float)q3e_vrEyeLogW * (float)q3e_vrEyeLogH) /
		        ((float)q3e_vrEyePhysW * (float)q3e_vrEyePhysH);
	}
	// The engine extent is read LIVE here, not taken from what the VR loop last
	// sampled: this dump is also the 2D-mode answer, and a loop-published number
	// is stale (or zero) whenever no loop is running — which is exactly when the
	// question "did the extent come back?" is being asked.
	const char *owner = Q3E_RenderSizeOverrideOwner();
	const int engW = Q3E_VR_EngineRenderWidth(), engH = Q3E_VR_EngineRenderHeight();
	q3e_vr_emit("EYENOW vr=%s views=%d phys=%dx%dpx logical=%dx%dpx logical/phys=%.2fx "
	            "engine=%dx%dpx renderscale=%.2fx pairs=%d msaa=%dx rgen=%d "
	            "extentowner=%s cvarrefused=%d resizerefused=%d "
	            "skyacc=%d skycull=%d skynodepth=%d depthfloor=%.6f "
	            // R4.3: the two picture-affecting rows this round adds, read
	            // LIVE off the same globals the blit and the renderer consume —
	            // sharpen composes with the depth floor above in one shader, and
	            // dmgblends counts what the gate has actually seen and dropped,
	            // which is what makes an OFF that never fired distinguishable
	            // from an OFF that had nothing to drop.
	            "hands=%s sharpen=%.0f%% dmgflash=%s dmgblends=%d/%d",
	            VK_GetVRActive() ? "on" : "off",
	            q3e_vrViews, q3e_vrEyePhysW, q3e_vrEyePhysH,
	            q3e_vrEyeLogW, q3e_vrEyeLogH, ratio,
	            engW, engH, q3e_vrRenderScale, VK_Get3DPairs(),
	            VK_GetSampleCount(), q3e_render_gen,
	            owner ? owner : "window", VK_GetVRExtentRefusals(),
	            Q3E_RenderSizeOverrideRefusals(),
	            q3e_sky_acc_open, q3e_sky_cull_open, q3e_sky_nodepth,
	            q3e_vrEyeDepthFloor,
	            q3e_vrShowHands ? "on" : "off", q3e_vrSharpen * 100.0f,
	            q3e_vrDamageFlash ? "on" : "off",
	            dmgDropped, dmgSeen);
}

static void q3e_dump_head(void) {
	float cullL[2], cullR[2];
	VK_GetVRCullTangents(0, cullL);
	VK_GetVRCullTangents(1, cullR);
	// The tangents the CULL PLANES encode, measured from the finished planes —
	// not the tangents we asked for. They must match the requested bottom/top,
	// and a plane attached to the wrong edge shows up here as the pair swapped.
	// vr=off means the numbers below are stale by design (nothing has published a
	// pose), NOT that VR is broken — a 2D-time dump read as evidence once.
	q3e_vr_emit("FRUSTUMNOW vr=%s wantL=(b%.3f,t%.3f) cullL=(b%.3f,t%.3f) "
	            "wantR=(b%.3f,t%.3f) cullR=(b%.3f,t%.3f) synthtan=%d",
	            VK_GetVRActive() ? "on" : "off",
	            q3e_vrEyeTangents[0][2], q3e_vrEyeTangents[0][3], cullL[0], cullL[1],
	            q3e_vrEyeTangents[1][2], q3e_vrEyeTangents[1][3], cullR[0], cullR[1],
	            q3e_vrSynthTanOn);
	// MEASURED from the published eye offsets, not the synthetic-IPD knob — that
	// knob is zero whenever the drawable supplies real eye transforms, which read
	// as "no IPD" on exactly the hardware that has one.
	float dx = q3e_vrEyeOrigin[1][0] - q3e_vrEyeOrigin[0][0];
	float dy = q3e_vrEyeOrigin[1][1] - q3e_vrEyeOrigin[0][1];
	float dz = q3e_vrEyeOrigin[1][2] - q3e_vrEyeOrigin[0][2];
	float ipd_m = (q3e_vrWorldScale > 0.0f)
	                ? sqrtf(dx * dx + dy * dy + dz * dz) / q3e_vrWorldScale : 0.0f;
	// The height chain, all four numbers, because the interesting failures are
	// between them: a baseline that never got captured, a request the ceiling
	// trace cut to nothing, or a rise applied while the player is crouched.
	q3e_vr_emit("HEIGHTNOW vr=%s valid=%d baseline=%.2fm trim=%+.2fm charactereye=%.2fm "
	            "request=%.1fu applied=%.1fu clamped=%d",
	            VK_GetVRActive() ? "on" : "off",
	            q3e_vrHeightValid, q3e_vrHeightBaseline, q3e_vrHeightTrim,
	            (q3e_vrWorldScale > 0.0f) ? Q3E_VR_CHARACTER_EYE_U / q3e_vrWorldScale : 0.0f,
	            cl_vr_height_request, cl_vr_height_rise,
	            (cl_vr_height_rise + 0.05f < cl_vr_height_request) ? 1 : 0);
	q3e_vr_emit("HEADNOW vr=%s tracked=%d synth=%d headpos=(%.3f,%.3f,%.3f)m "
	            "yaw=%.1fdeg pitch=%.1fdeg roll=%.1fdeg worldscale=%.2fu/m ipdmeasured=%.4fm "
	            "eyeL=(%.1f,%.1f,%.1f)u eyeR=(%.1f,%.1f,%.1f)u "
	            "tanL=(%.3f,%.3f,%.3f,%.3f) tanR=(%.3f,%.3f,%.3f,%.3f)"
	            // R4.8, APPENDED at the very end of the record (the one insertion
	            // point nothing can span): the published eye forward's UP
	            // component. With a level head it is sin(the world pitch), which
	            // is how the suite can tell "the stick pitched the CAMERA" from
	            // "the stick moved the crosshair up the screen".
	            " eyefwdup=%.3f",
	            VK_GetVRActive() ? "on" : "off",
	            q3e_vrTracked, q3e_vrSynthPose,
	            q3e_vrHeadPos[0], q3e_vrHeadPos[1], q3e_vrHeadPos[2],
	            q3e_vrHeadYaw, q3e_vrHeadPitch, q3e_vrHeadRoll,
	            q3e_vrWorldScale, ipd_m,
	            q3e_vrEyeOrigin[0][0], q3e_vrEyeOrigin[0][1], q3e_vrEyeOrigin[0][2],
	            q3e_vrEyeOrigin[1][0], q3e_vrEyeOrigin[1][1], q3e_vrEyeOrigin[1][2],
	            q3e_vrEyeTangents[0][0], q3e_vrEyeTangents[0][1],
	            q3e_vrEyeTangents[0][2], q3e_vrEyeTangents[0][3],
	            q3e_vrEyeTangents[1][0], q3e_vrEyeTangents[1][1],
	            q3e_vrEyeTangents[1][2], q3e_vrEyeTangents[1][3],
	            q3e_vrEyeFwdUp);
}

static void q3e_dump_frame(void) {
	q3e_vr_emit("FRAMENOW pubid=%ld renderedid=%ld lag=%ld vrframes=%d dropped=%d "
	            "represents=%d enginetimeouts=%d restartskips=%d blindworld=%d owner=%s",
	            q3e_vrPubId, q3e_vrRenderedId, q3e_vrPubId - q3e_vrRenderedId,
	            q3e_vrFrameCount, q3e_vrDropped, q3e_vrRepresents,
	            q3e_vrEngineTimeouts, Q3E_VR_RestartSkips(), Q3E_VR_BlindWorldFrames(),
	            q3e_frame_owner == Q3E_FRAME_OWNER_VR ? "vr" : "link");
}

// R4.1 — the connection, in one record. Multiplayer is the first thing this
// port does whose interesting states are owned by SOMEONE ELSE: the server
// decides when the map changes, when the round ends, and how long the client
// sits on a loading screen. None of those states had a name in the dump family,
// so a VR frame taken during one could only be described as "the world did not
// draw" — which is also what a bug looks like.
//
// `snapnum` is the assertion surface for "the simulation is advancing": it is
// the server message the current snapshot came from, and it is monotone while a
// connection is healthy. Two dumps a few seconds apart that report the same
// number mean the client is connected and receiving nothing, which is a
// different failure from a client that never connected.
static const char *q3e_connstate_name(int s) {
	// q_shared.h connstate_t. Spelled out rather than printed as a bare number:
	// a reader who has to look up "6" gets the loading state wrong half the time
	// because CA_LOADING and CA_PRIMED are adjacent and mean opposite things
	// about whether the gamestate has arrived.
	switch (s) {
		case CA_UNINITIALIZED: return "uninitialized";
		case CA_DISCONNECTED:  return "disconnected";
		case CA_AUTHORIZING:   return "authorizing";
		case CA_CONNECTING:    return "connecting";
		case CA_CHALLENGING:   return "challenging";
		case CA_CONNECTED:     return "connected";
		case CA_LOADING:       return "loading";
		case CA_PRIMED:        return "primed";
		case CA_ACTIVE:        return "active";
		case CA_CINEMATIC:     return "cinematic";
		default:               return "?";
	}
}

// bg_public.h pmtype_t, reached through client.h — the same enum
// q3e_vr_scoreboard_from_client already switches on, NOT a restatement of its
// numeric values. PM_INTERMISSION is the one that carries a decision: it is how
// "the round ended and the scoreboard is up" reaches a shell that cannot ask
// cgame anything.
static const char *q3e_pmtype_name(int t) {
	switch (t) {
		case PM_NORMAL:         return "normal";
		case PM_NOCLIP:         return "noclip";
		case PM_SPECTATOR:      return "spectator";
		case PM_DEAD:           return "dead";
		case PM_FREEZE:         return "freeze";
		case PM_INTERMISSION:   return "intermission";
		case PM_SPINTERMISSION: return "spintermission";
		default:                return "?";
	}
}

static void q3e_dump_net(void) {
	const int state = (int)cls.state;
	const int connected = (state >= CA_CONNECTED);
	// The address is worth printing from the moment the client starts DIALLING,
	// not from the moment it succeeds: "stuck on the connect screen" is the
	// failure this record exists to diagnose, and the first question about it is
	// which address it is stuck on.
	const int dialling = (state >= CA_CONNECTING);
	// The playerstate is only meaningful once a snapshot has been received;
	// reading pm_type out of a stale snapshot after a disconnect would report an
	// intermission that ended minutes ago. `snapvalid` gates it, and pmtype
	// reports -1 when there is nothing to read rather than a plausible 0.
	const int snapvalid = (connected && cl.snap.valid) ? 1 : 0;
	const int pmtype = snapvalid ? cl.snap.ps.pm_type : -1;
	const int intermission = (pmtype == PM_INTERMISSION ||
	                          pmtype == PM_SPINTERMISSION) ? 1 : 0;
	q3e_vr_emit("NETNOW state=%s(%d) addr=%s map=%s snapvalid=%d snapnum=%d "
	            "snaptime=%dms ping=%dms serverdelta=%dms pmtype=%d(%s) "
	            "intermission=%d demo=%d pure=%d dl=%s dlbytes=%d/%d dlurl=%d "
	            "allowdl=%d",
	            q3e_connstate_name(state), state,
	            dialling ? NET_AdrToStringwPort(&clc.serverAddress) : "none",
	            cl.mapname[0] ? cl.mapname : "none",
	            snapvalid, snapvalid ? cl.snap.messageNum : -1,
	            snapvalid ? cl.snap.serverTime : -1,
	            snapvalid ? cl.snap.ping : -1,
	            connected ? cl.serverTimeDelta : 0,
	            pmtype, q3e_pmtype_name(pmtype),
	            intermission, clc.demoplaying ? 1 : 0,
	            cl_connectedToPureServer ? 1 : 0,
	            clc.downloadName[0] ? clc.downloadName : "none",
	            clc.downloadCount, clc.downloadSize,
	            clc.sv_dlURL[0] ? 1 : 0,
	            Cvar_VariableIntegerValue("cl_allowDownload"));
}

static void q3e_dump_depth(void) {
	// `wanted` comes from the RENDERER, not from a shell flag set beside the
	// thing it is supposed to describe: it is the value that actually decided
	// whether the depth attachment is memoryless.
	const int wanted = VK_Get3DVRWanted();
	q3e_vr_emit("DEPTHNOW vr=%s wanted=%d live=%d copies=%d znear=%.3fu(0.100m x %.2fu/m) "
	            "infinitefar=%d",
	            VK_GetVRActive() ? "on" : "off",
	            wanted, q3e_vrDepthLive, q3e_vrDepthCopies,
	            0.1f * q3e_vrWorldScale, q3e_vrWorldScale, wanted);
}

// The movement/turn/height record. Publishes the head basis, the aim yaw, the
// difference between them, and the move vector on BOTH sides of the rotation —
// a rotation that quietly does nothing reads identically to one that works if
// only the output is printed.
static const char *q3e_movebasis_name(int b) {
	switch (b) {
		case Q3E_VRMOVE_HEAD:     return "head";
		case Q3E_VRMOVE_AIM_HAND: return "aimhand";
		case Q3E_VRMOVE_OFF_HAND: return "offhand";
		default:                  return "off";
	}
}

// What the basis RESOLVED to this frame, which is not the same question as what
// it is set to: a hand basis with that hand untracked falls back to the head,
// and a setting that silently does something else is the defect this names.
static const char *q3e_movebasis_source(void) {
	const int aimIdx = (q3e_vrAimHand == Q3E_VR_HAND_LEFT) ? 0 : 1;
	switch (q3e_vrMoveBasis) {
		case Q3E_VRMOVE_AIM_HAND:
			if (q3e_vrHandTracked & (1 << aimIdx)) return "aimhand";
			return Q3E_VR_PadAimActive() ? "padaim" : "head(fallback)";
		case Q3E_VRMOVE_OFF_HAND:
			return (q3e_vrHandTracked & (1 << (aimIdx ^ 1))) ? "offhand" : "head(fallback)";
		case Q3E_VRMOVE_HEAD: return "head";
		default:              return "off";
	}
}

static const char *q3e_aimsource_name(int s) {
	return (s == Q3E_VRAIM_HAND) ? "hand" : (s == Q3E_VRAIM_PAD) ? "pad" : "head";
}

static const char *q3e_aimhand_name(int h) {
	return (h == Q3E_VR_HAND_LEFT) ? "left" : "right";
}

// R3 — the hands, in one record: what is tracked, where each one points, which
// one is aiming, and what the buttons and sticks read RIGHT NOW. The level is
// PEEKED, never drained: a dump that consumed input would eat presses the game
// was about to see, which is the one way a diagnostic can change the thing it
// measures.
static void q3e_dump_hand(void) {
	unsigned level[2] = { 0u, 0u };
	float stick[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
	char synth[256], consumer[256];
	const int hands = Q3E_Sense_PeekLevel(level, stick);
	const int aimIdx = (q3e_vrAimHand == Q3E_VR_HAND_LEFT) ? 0 : 1;
	Q3E_Sense_SynthDescribe(synth, (int)sizeof(synth));
	Q3E_VR_SenseHeldString(consumer, (int)sizeof(consumer));
	q3e_vr_emit("HANDNOW vr=%s aimhand=%s handaim=%d answered=%d "
	            "tracked=%d held=%d present=%d "
	            "L=(yaw%.1fdeg,pitch%.1fdeg,pos%.2f/%.2f/%.2fm,btn0x%02x,stick%.2f/%.2f) "
	            "R=(yaw%.1fdeg,pitch%.1fdeg,pos%.2f/%.2f/%.2fm,btn0x%02x,stick%.2f/%.2f) "
	            "aim=(src=%s,yaw%.1fdeg,pitch%.1fdeg,idx%d) trim=%.1fdeg swaps=%d "
	            "haptics=%d consumer=[%s] synth=[%s]",
	            VK_GetVRActive() ? "on" : "off",
	            q3e_aimhand_name(q3e_vrAimHand), q3e_vrHandAimEnabled, hands,
	            q3e_vrHandTracked, q3e_vrHandHeld, q3e_vrHandPresent,
	            q3e_vrHandYaw[0], q3e_vrHandPitch[0],
	            q3e_vrHandPos[0][0], q3e_vrHandPos[0][1], q3e_vrHandPos[0][2],
	            level[0], stick[0], stick[1],
	            q3e_vrHandYaw[1], q3e_vrHandPitch[1],
	            q3e_vrHandPos[1][0], q3e_vrHandPos[1][1], q3e_vrHandPos[1][2],
	            level[1], stick[2], stick[3],
	            q3e_aimsource_name(q3e_vrAimSource), q3e_vrAimYaw, q3e_vrAimPitch,
	            aimIdx, q3e_vrAimPitchTrim, q3e_vrAimSourceSwaps,
	            q3e_vrHaptics, consumer, synth);
}

// R3 — where the gun actually ended up. The renderer answers, because the
// renderer is what wrote it: reporting the values that went IN would pass on a
// build where the re-base never ran.
// Declared here because PANELNOW (above) names the HUD state in words and the
// command handler that owns the spelling lives further down with the rest of
// the console surface.
static const char *q3e_hudpos_name(int p);

static void q3e_dump_viewmodel(void) {
	char line[512];
	VK_VRGunString(line, (int)sizeof(line));
	q3e_vr_emit("VIEWMODELNOW vr=%s scale=%.2fx grip=(f%.1f,r%.1f,u%.1f)u "
	            "gripang=(p%.1f,y%.1f,r%.1f)deg %s",
	            VK_GetVRActive() ? "on" : "off", q3e_vrGunScale,
	            q3e_vrGrip[0], q3e_vrGrip[1], q3e_vrGrip[2],
	            q3e_vrGripAngles[0], q3e_vrGripAngles[1], q3e_vrGripAngles[2],
	            line);
}

static const char *q3e_turnmode_name(int m) {
	switch (m) {
		case Q3E_VRTURN_SMOOTH: return "smooth";
		case Q3E_VRTURN_SNAP30: return "snap30";
		case Q3E_VRTURN_SNAP45: return "snap45";
		case Q3E_VRTURN_SNAP60: return "snap60";
		default:                return "off";
	}
}

static void q3e_dump_move(void) {
	// R3: NORMALIZED. Both terms are AngleMod'd into [0,360), so their raw
	// difference is off by a full turn whenever the pair straddles zero — a
	// -60 degree rotation reads as +300 depending only on which way the player
	// happens to be facing. The quantity meant here is the SIGNED rotation, and
	// the assertions that read it are about its sign.
	const float delta = cl_vr_move_basis_active
	                      ? AngleNormalize180(cl_vr_move_basis_yaw - cl_vr_view_yaw) : 0.0f;
	q3e_vr_emit("MOVENOW vr=%s basis=%s basissrc=%s handtracked=%d active=%d "
	            "basisyaw=%.1fdeg aimyaw=%.1fdeg "
	            "delta=%.1fdeg headyaw=%.1fdeg pre=(f%d,r%d) sent=(f%d,r%d) "
	            "turn=%s speed=%.0fdeg/s lastsnap=%.0fdeg snaps=%d pending=%.2fdeg "
	            "gyrosuppressed=%d",
	            VK_GetVRActive() ? "on" : "off",
	            q3e_movebasis_name(q3e_vrMoveBasis), q3e_movebasis_source(),
	            q3e_vrHandTracked, cl_vr_move_basis_active,
	            cl_vr_move_basis_yaw, cl_vr_view_yaw, delta, q3e_vrHeadYaw,
	            cl_vr_move_pre_f, cl_vr_move_pre_r,
	            cl_vr_move_sent_f, cl_vr_move_sent_r,
	            q3e_turnmode_name(q3e_vrTurnMode), q3e_vrTurnSpeed,
	            q3e_vrLastSnap, q3e_vrSnapCount, cl_vr_turn_pending,
	            q3e_gyro_suppressed);
}

// R2.1 cut-list: this file and cl_input.c each carried their own hand-rolled
// degree-wrap loop. The engine already ships a bounded one (AngleNormalize360
// is a single integer-modulo computation, not a loop that can run away on a
// pathological input) via AngleDelta( a, b ) = AngleNormalize180( a - b ) —
// use it instead of a second copy of the same idea.

// R2 item 1 — the headline assertion. cl.viewangles is written by
// CL_VRApplyHeadAim as EXACTLY body+head (yaw) and head (pitch), so `delta`
// here is an identity check, not a measurement: it must read ~0 whenever
// head-aim is active, on every frame, including the one right after a spawn
// (a server-forced view snap is just this frame's turn-stick delta as far as
// CL_VRApplyHeadAim is concerned — see its own comment). A build with the
// hook disabled is what proves this assertion can fail (`q3evrheadaim 0`).
//
// R2.1 cut-list — LABELED, not fixed structurally: `q3evraim` (like every
// q3evr* command) is drained from Cbuf at a fixed point in Com_Frame, which
// is not guaranteed to be AFTER this same frame's CL_CreateCmd has run.
// Q3E_VR_PublishHeadAim updates cl_vr_head_yaw/head_pitch BEFORE Q3E_Frame
// is called; if the dump's own Cbuf slot lands before CL_CreateCmd inside
// that same Q3E_Frame, cl.viewangles here is still the PREVIOUS frame's
// value while cl_vr_body_yaw/head_yaw are already this frame's — a one-frame
// skew. Invisible at a HELD pose (nothing changed between frames, so last
// frame's value equals this frame's — every suite case here sets a pose,
// waits, THEN reads, which is exactly why none of them can see it) and only
// a live device session with the head in CONTINUOUS motion would ever
// observe a small transient nonzero delta from this cause. Restructuring
// Com_Frame's dispatch order to guarantee same-frame reads was judged not
// worth the risk to frame ordering for a sub-frame artifact with no
// gameplay effect (the ENGINE's own cl.viewangles is always correct; only
// this diagnostic snapshot can be one frame behind) — documented here so it
// is never mistaken for the identity itself being wrong.
// R2.2 fix 3: the PITCH half of this identity is now measured where the game
// actually reads it. cl.viewangles is only half of an aim: pmove computes the
// effective view as the usercmd's angles PLUS the playerstate's own
// delta_angles, which the server rewrites on every respawn and teleport. The
// old spelling compared cl.viewangles[PITCH] against the head pitch — an
// identity that held trivially, by construction, precisely BECAUSE the code
// wrote one into the other, and stayed green through the whole failure it was
// supposed to catch (aim 30 degrees off gaze for a full life after dying
// pitched). `eff` is what the server will use, `deltapitch` is the server's own
// offset in the units it sends (a case that never sees it move has not tested
// the fix), and the reported delta is now eff vs the clamped head target.
static void q3e_dump_aim(void) {
	const int   deltaPitchShort =
		(cls.state == CA_ACTIVE && cl.snap.valid) ? cl.snap.ps.delta_angles[PITCH] : 0;
	const float effPitch = cl.viewangles[PITCH] + (float)SHORT2ANGLE(deltaPitchShort);
	const float wantYaw = AngleNormalize360(cl_vr_body_yaw + cl_vr_head_yaw);
	const float sentYaw = AngleNormalize360(cl.viewangles[YAW]);
	const float yawDelta = AngleDelta(sentYaw, wantYaw);
	// The two halves can legitimately be a whole turn apart in raw degrees (the
	// pitch write lands in the +/-180 window a short maps to, the offset it
	// cancels does not have to), and 360 degrees apart is the same direction.
	const float pitchDelta = AngleNormalize180(effPitch - cl_vr_head_pitch_target);
	float probePush = 0.0f;
	int   probeDepth = 0;
	VK_GetVRXhairProbe(&probePush, &probeDepth);
	const float delta = fabsf(yawDelta) > fabsf(pitchDelta) ? yawDelta : pitchDelta;
	// R3: the offset field is `aimoff`, not `head`. cl_vr_head_yaw/pitch have
	// always meant "the VR aim offset the body accumulator rides on", and from
	// this round a HAND can supply it — a field labelled `head` that holds a
	// hand's angles is the kind of dump that reads as evidence and is not.
	q3e_vr_emit("AIMNOW vr=%s aimsrc=%s aimhand=%s handtracked=%d active=%d "
	            "sent=(p%.2f,y%.2f) eff=(p%.2f) "
	            "aimoff=(p%.2f,y%.2f) target=p%.2f body=%.2fdeg deltapitch=%d "
	            "delta=%.4fdeg hookenabled=%d pitchcomp=%d handaim=%d "
	            "marker=(valid%d,hit%d,range%.0fu,size%.2fx) "
	            "probe=(push%.0fu,depthtest%d) "
	            // R4.6, APPENDED at the end of the record: two rounds running, a
	            // new dump field landed on a junction some existing regex spanned
	            // (R4.2's PANELNOW pair, R4.3's SETTINGSNOW trio). The end of a
	            // line is the one insertion point nothing can span.
	            // R4.7 renames the third value IN PLACE: `spill` was the cone's
	            // overflow and there is no cone any more. `turn` is the degrees
	            // of BODY turn the last stick frame asked for, and `yaw` is now
	            // the invariant — pinned at 0, i.e. the aim is body forward.
	            // R4.8: `pitch` is the WORLD pitch the compositor applies to the
	            // eye pose, not an offset the crosshair rides on. Same field, same
	            // position, a value that now means the camera moved with it.
	            "padaim=(mode=%s,active=%d,yaw%.1fdeg,pitch%.1fdeg,turn%.2fdeg,"
	            "hook%d,conn%d)",
	            VK_GetVRActive() ? "on" : "off",
	            q3e_aimsource_name(q3e_vrAimSource), q3e_aimhand_name(q3e_vrAimHand),
	            q3e_vrHandTracked, cl_vr_head_aim_active,
	            cl.viewangles[PITCH], cl.viewangles[YAW], effPitch,
	            cl_vr_head_pitch, cl_vr_head_yaw, cl_vr_head_pitch_target,
	            cl_vr_body_yaw, deltaPitchShort, delta,
	            cl_vr_head_aim_hook_enabled, cl_vr_head_pitch_delta_enabled,
	            q3e_vrHandAimEnabled,
	            cl_vr_xhair_valid, cl_vr_xhair_hit, cl_vr_xhair_range,
	            q3e_vrXhairSize, probePush, probeDepth,
	            (q3e_vrAimMode == Q3E_VRAIMMODE_PAD) ? "gamepad" : "head",
	            Q3E_VR_PadAimActive(), q3e_vrPadAimYaw, q3e_vrPadAimPitch,
	            q3e_vrPadAimTurn, q3e_vrPadAimEnabled, Q3E_VR_PlainPadConnected());
}

// The projection the GPU actually got, stated as where it puts the four frustum
// edges that were asked for.
//
// Asserting the tangents that go IN proves nothing: the defect this exists to
// catch lived entirely in the OpenGL-to-Vulkan conversion downstream of them,
// where inverting Y negated the vertical scale but not the vertical off-centre
// term. That renders the world through a projection the compositor does not
// know about, which is invisible while the head is still and warps when it
// moves. A correct projection puts left at -1, right at +1, bottom at +1 and
// top at -1 (Vulkan's Y runs down).
static void q3e_dump_proj(void) {
	float l[4], r[4];
	VK_GetVREdgeNDC(0, l);
	VK_GetVREdgeNDC(1, r);
	q3e_vr_emit("PROJNOW vr=%s edgeL=(l%.3f,r%.3f,b%.3f,t%.3f) "
	            "edgeR=(l%.3f,r%.3f,b%.3f,t%.3f) want=(l-1.000,r1.000,b1.000,t-1.000) "
	            "gammainv=%.3f overbright=%.2fx",
	            VK_GetVRActive() ? "on" : "off",
	            l[0], l[1], l[2], l[3], r[0], r[1], r[2], r[3],
	            q3e_vrGammaInv, q3e_vrOverbright);
}

// The two quads and the layer that feeds one of them.
static void q3e_dump_panel(void) {
	float pd = 0, pw = 0, ph = 0, pa = 0, ud = 0, uw = 0, uh = 0;
	Q3E_VR_PanelGeometry(&pd, &pw, &ph, &pa);
	Q3E_VR_UIGeometry(&ud, &uw, &uh);
	// Angular size is what decides whether the whole composite is ON the display.
	// A panel wider than the field of view clips the menu at its own edges with
	// nothing to say it did.
	int blended[2], additive[2];
	VK_GetVRUIAlpha(blended, additive);
	// VK_BLEND_FACTOR: 0=ZERO 1=ONE 6=SRC_ALPHA 7=ONE_MINUS_SRC_ALPHA. The layer
	// is composited premultiplied, so coverage must accumulate as (ONE,
	// ONE_MINUS_SRC_ALPHA) for a normal blend and must NOT accumulate at all for
	// an additive one — an additive glow that gains alpha OCCLUDES the world it
	// was supposed to add light to.
	q3e_vr_emit("UIALPHANOW blended=(src%d,dst%d) additive=(src%d,dst%d) "
	            "want=(blended src1,dst7 | additive src0,dst1) swallowed2d=%d",
	            blended[0], blended[1], additive[0], additive[1],
	            VK_GetVRSwallowed2D());
	q3e_vr_emit("PANELNOW vr=%s redirect=%d uiframes=%d uicopies=%d verticallatch=%d "
	            "panel=(d%.2fm,hw%.3fm,hh%.3fm,aspect%.3f,h%.1fdeg,v%.1fdeg) "
	            "ui=(d%.2fm,hw%.3fm,hh%.3fm,h%.1fdeg,v%.1fdeg) staleanchor=%d "
	            "uiquad=%d uistall=%d regionsdrawn=%d exclcount=%d scoreboardup=%d "
	            "scoreshold=%d scoreholdhook=%d "
	            "notifyrows=%.0f messagerows=%.0f statusrows=%.0f statustop=%.0f "
	            "statuspitch=%+.2fdeg xhairbox=(cx%.0f,cy%.0f,half%.0f)px "
	            "hudsize=%.2fx hudheight=%+.1fdeg hud=%s xhair=%s xhairdrawn2d=0",
	            VK_GetVRActive() ? "on" : "off",
	            VK_GetVRUIRedirect(), VK_GetVRUIFrames(), Q3E_VR_UICopies(),
	            Q3E_VR_UIVerticalLatched(),
	            pd, pw, ph, pa,
	            (pd > 0.0f) ? 2.0f * atanf(pw / pd) * 180.0f / (float)M_PI : 0.0f,
	            (pd > 0.0f) ? 2.0f * atanf(ph / pd) * 180.0f / (float)M_PI : 0.0f,
	            ud, uw, uh,
	            (ud > 0.0f) ? 2.0f * atanf(uw / ud) * 180.0f / (float)M_PI : 0.0f,
	            (ud > 0.0f) ? 2.0f * atanf(uh / ud) * 180.0f / (float)M_PI : 0.0f,
	            Q3E_VR_StaleAnchorFrames(), q3e_vrUIQuadDrawn, VK_GetVRUIStall(),
	            q3e_vrRegionsDrawn, q3e_vrExclCount, q3e_vrScoreboardUp,
	            q3e_vrScoresHeld, q3e_vrScoresHoldHook,
	            q3e_vrNotifyRows, q3e_vrMessageRows,
	            q3e_vrStatusRows, q3e_vrStatusTopRow, q3e_vrStatusPitch,
	            q3e_vrXhairBoxCX, q3e_vrXhairBoxCY, q3e_vrXhairBoxHalf,
	            q3e_vrHudSize, q3e_vrHudHeight, q3e_hudpos_name(q3e_vrHudPos),
	            q3e_vrXhairOn ? "on" : "off");
}

// --- console commands -------------------------------------------------------
// The omnibus. BODYNOW / MSGNOW / XHAIRNOW remain deliberately unregistered:
// they need state that does not exist yet, and a dump that prints a placeholder
// is worse than no dump — it looks like evidence.
static void Q3E_Cmd_VRZones_f(void) {
	Q3E_VR_SampleClientState();
	q3e_dump_mode();
	q3e_dump_eye();
	q3e_dump_head();
	q3e_dump_frame();
	q3e_dump_net();
	q3e_dump_depth();
	q3e_dump_move();
	q3e_dump_aim();
	q3e_dump_hand();
	q3e_dump_viewmodel();
	q3e_dump_proj();
	q3e_dump_panel();
	q3e_vr_nowseq();
}

static void Q3E_Cmd_VRMode_f(void)  { Q3E_VR_SampleClientState(); q3e_dump_mode();  q3e_vr_nowseq(); }
static void Q3E_Cmd_VREye_f(void)   { q3e_dump_eye();   q3e_vr_nowseq(); }
static void Q3E_Cmd_VRHead_f(void)  { q3e_dump_head();  q3e_vr_nowseq(); }
static void Q3E_Cmd_VRFrame_f(void) { q3e_dump_frame(); q3e_vr_nowseq(); }
static void Q3E_Cmd_VRNet_f(void)   { q3e_dump_net();   q3e_vr_nowseq(); }
static void Q3E_Cmd_VRDepth_f(void) { q3e_dump_depth(); q3e_vr_nowseq(); }
static void Q3E_Cmd_VRMove_f(void)  { q3e_dump_move();  q3e_vr_nowseq(); }
static void Q3E_Cmd_VRAim_f(void)   { q3e_dump_aim();   q3e_vr_nowseq(); }
static void Q3E_Cmd_VRProj_f(void)  { q3e_dump_proj();  q3e_vr_nowseq(); }
static void Q3E_Cmd_VRPanel_f(void) { q3e_dump_panel(); q3e_vr_nowseq(); }
static void Q3E_Cmd_VRHandNow_f(void)  { q3e_dump_hand();      q3e_vr_nowseq(); }
static void Q3E_Cmd_VRViewmodel_f(void){ q3e_dump_viewmodel(); q3e_vr_nowseq(); }

// --- R3 injection + tuning ---------------------------------------------------
// `q3evrhand <l|r> off` / `q3evrhand <l|r> <yaw> <pitch> <roll> <x> <y> <z>`
//
// Injected at Q3E_Sense_Poll's OUTPUT, where a real ARKit anchor lands, so
// everything downstream of it is the shipping chain: the base-frame transform,
// the aim arbitration, the delta-compensated viewangle write, the movement
// basis, the viewmodel re-base and the marker. The simulator has no controllers
// at all, which is exactly why this exists.
static int q3e_hand_arg(const char *a) {
	if (!Q_stricmp(a, "l") || !Q_stricmp(a, "left"))  return 0;
	if (!Q_stricmp(a, "r") || !Q_stricmp(a, "right")) return 1;
	return -1;
}

static void Q3E_Cmd_VRHand_f(void) {
	int hand;
	if (Cmd_Argc() < 3) {
		Com_Printf("q3evrhand <l|r> off\n"
		           "q3evrhand <l|r> <yaw-deg> <pitch-deg> <roll-deg> <x-m> <y-m> <z-m>\n");
		q3e_dump_hand();
		q3e_vr_nowseq();
		return;
	}
	hand = q3e_hand_arg(Cmd_Argv(1));
	if (hand < 0) {
		Com_Printf("q3evrhand: first argument must be l or r\n");
		return;
	}
	if (Cmd_Argc() == 3 && !Q_stricmp(Cmd_Argv(2), "off")) {
		Q3E_Sense_SetSynthHand(hand, 0, 0, 0, 0, 0, 0, 0);
		Com_Printf("q3evrhand: %s OFF\n", hand ? "right" : "left");
		q3e_dump_hand();
		q3e_vr_nowseq();
		return;
	}
	if (Cmd_Argc() != 8) {
		Com_Printf("q3evrhand <l|r> <yaw> <pitch> <roll> <x> <y> <z> | <l|r> off\n");
		return;
	}
	Q3E_Sense_SetSynthHand(hand, 1,
	                       (float)atof(Cmd_Argv(2)), (float)atof(Cmd_Argv(3)),
	                       (float)atof(Cmd_Argv(4)), (float)atof(Cmd_Argv(5)),
	                       (float)atof(Cmd_Argv(6)), (float)atof(Cmd_Argv(7)));
	Com_Printf("q3evrhand: %s yaw=%s pitch=%s roll=%s pos=(%s,%s,%s)m\n",
	           hand ? "right" : "left", Cmd_Argv(2), Cmd_Argv(3), Cmd_Argv(4),
	           Cmd_Argv(5), Cmd_Argv(6), Cmd_Argv(7));
	q3e_dump_hand();
	q3e_vr_nowseq();
}

// `q3evrhandbtn <l|r> <mask>` — a LATCHED hold, not a tap. The consumer runs
// once per engine frame and the injection has to survive until it does; a
// one-shot would be a coin flip against the frame boundary. Clear with 0.
static void Q3E_Cmd_VRHandBtn_f(void) {
	int hand;
	if (Cmd_Argc() != 3) {
		Com_Printf("q3evrhandbtn <l|r> <mask>   (trigger1 grip2 A4 B8 stick16 menu32)\n");
		q3e_dump_hand();
		q3e_vr_nowseq();
		return;
	}
	hand = q3e_hand_arg(Cmd_Argv(1));
	if (hand < 0) {
		Com_Printf("q3evrhandbtn: first argument must be l or r\n");
		return;
	}
	Q3E_Sense_SetSynthButtons(hand, (unsigned)atoi(Cmd_Argv(2)));
	Com_Printf("q3evrhandbtn: %s = 0x%02x\n", hand ? "right" : "left",
	           (unsigned)atoi(Cmd_Argv(2)));
	q3e_dump_hand();
	q3e_vr_nowseq();
}

static void Q3E_Cmd_VRHandStick_f(void) {
	int hand;
	if (Cmd_Argc() != 4) {
		Com_Printf("q3evrhandstick <l|r> <x -1..1> <y -1..1>\n");
		q3e_dump_hand();
		q3e_vr_nowseq();
		return;
	}
	hand = q3e_hand_arg(Cmd_Argv(1));
	if (hand < 0) {
		Com_Printf("q3evrhandstick: first argument must be l or r\n");
		return;
	}
	Q3E_Sense_SetSynthStick(hand, (float)atof(Cmd_Argv(2)), (float)atof(Cmd_Argv(3)));
	Com_Printf("q3evrhandstick: %s = (%s,%s)\n", hand ? "right" : "left",
	           Cmd_Argv(2), Cmd_Argv(3));
	q3e_dump_hand();
	q3e_vr_nowseq();
}

// `q3evrhandaim <0|1>` — fault injection for the hand-aim identity. With it off
// the arbitration always answers HEAD, so an injected hand pose stops reaching
// cl.viewangles and the identity the suite asserts measurably opens. That is
// what proves the green one means something.
static void Q3E_Cmd_VRHandAim_f(void) {
	if (Cmd_Argc() >= 2)
		q3e_vrHandAimEnabled = atoi(Cmd_Argv(1)) ? 1 : 0;
	Com_Printf("q3evrhandaim: %s\n", q3e_vrHandAimEnabled ? "ON" : "off");
	q3e_dump_aim();
	q3e_dump_hand();
	q3e_vr_nowseq();
}

// `q3evraimhand <left|right>`
static void Q3E_Cmd_VRAimHand_f(void) {
	if (Cmd_Argc() >= 2) {
		const int h = q3e_hand_arg(Cmd_Argv(1));
		if (h < 0)
			Com_Printf("usage: q3evraimhand <left|right>\n");
		else
			q3e_vrAimHand = h ? Q3E_VR_HAND_RIGHT : Q3E_VR_HAND_LEFT;
		Q3E_VR_PersistTuning();
	}
	Com_Printf("q3evraimhand: %s\n", q3e_aimhand_name(q3e_vrAimHand));
	q3e_dump_hand();
	q3e_vr_nowseq();
}

// `q3evraimtrim <-10..10>` — the hand-aim pitch trim, in degrees. HAND aim only:
// on head aim the crosshair and the gaze are the same thing and an offset
// between them is a nausea machine.
//
// R3.6: zero is Q3E_VR_AIM_PITCH_BIAS, which is zero — the controller's own
// forward axis. R3.4 baked +2 in and the round that followed dialled -2 back
// out of it, which is the same aim reached twice; the bias goes, the row keeps
// its +/-10 of travel either side of it for a wrist that disagrees.
static void Q3E_Cmd_VRAimTrim_f(void) {
	if (Cmd_Argc() >= 2) {
		const float t = (float)atof(Cmd_Argv(1));
		if (!isfinite(t))
			Com_Printf("q3evraimtrim: must be a number — kept %.1fdeg\n", q3e_vrAimPitchTrim);
		else {
			q3e_vrAimPitchTrim = q3e_vr_clamp_range(t, -10.0f, 10.0f);
			if (t != q3e_vrAimPitchTrim)
				Com_Printf("q3evraimtrim: %.1f is outside +/-10 — clamped\n", t);
			Q3E_VR_PersistTuning();
		}
	}
	Com_Printf("q3evraimtrim: %.1fdeg\n", q3e_vrAimPitchTrim);
	q3e_dump_hand();
	q3e_vr_nowseq();
}

// `q3evrgunscale <0.375..1.875>` — the Weapon Size row's own value, reachable
// from the console so it can be dialled with the headset on.
//
// NATIVE units, and they stay native: R4.0 rescales what the settings ROW shows
// (displayed = native / 0.75, so the shipped default reads as 1.00x) and
// deliberately changes nothing here. A console command that started reporting a
// second unit for the same value is how the crosshair row's own comment says
// this goes wrong. The limits below ARE the row's ends expressed natively —
// displayed 0.50x..2.50x — so every value the slider can reach is one this
// command accepts and vice versa.
#define Q3E_VR_GUNSCALE_MIN 0.375f
#define Q3E_VR_GUNSCALE_MAX 1.875f
static void Q3E_Cmd_VRGunScale_f(void) {
	if (Cmd_Argc() >= 2) {
		const float s = (float)atof(Cmd_Argv(1));
		if (!isfinite(s))
			Com_Printf("q3evrgunscale: must be a number — kept %.2fx\n", q3e_vrGunScale);
		else {
			q3e_vrGunScale = q3e_vr_clamp_range(s, Q3E_VR_GUNSCALE_MIN,
			                                       Q3E_VR_GUNSCALE_MAX);
			if (s != q3e_vrGunScale)
				Com_Printf("q3evrgunscale: %.2f is outside %.3f..%.3f — clamped\n",
				           s, Q3E_VR_GUNSCALE_MIN, Q3E_VR_GUNSCALE_MAX);
			Q3E_VR_PersistTuning();
		}
	}
	VK_SetVRGun((q3e_vrAimHand == Q3E_VR_HAND_LEFT) ? 0 : 1,
	            q3e_vrGunScale, q3e_vrGrip, q3e_vrGripAngles);
	Com_Printf("q3evrgunscale: %.2fx\n", q3e_vrGunScale);
	q3e_dump_viewmodel();
	q3e_vr_nowseq();
}

// `q3evrgrip <fwd>` / `q3evrgrip <fwd> <right> <up> [pitch] [yaw] [roll]`
// `q3evrgrip reset` / `q3evrgrip` (report)
//
// R3.3 hardcoded yaw and roll; R3.7 right, up and pitch; R4.0 forward. Every
// value the shipped build draws with is now a constant, so what this command is
// FOR has changed: it is no longer the way a number gets dialled into the store,
// it is the way the question gets re-opened. It writes the live vector directly,
// for this process only, and nothing persists it or reads it back — the next
// launch is the six constants again.
//
// Kept rather than removed for two reasons. It is the only instrument a future
// round has for asking "is -6.0 still right" without a build, and — the reason
// it stays UNGATED, like `q3evranchor` next to it — it is what lets the
// simulator suite, which builds the app in its PUBLIC configuration, prove that
// the hardcoded set is what boots: a value the suite can move is a value whose
// absence of movement means something.
//
// Forms: `q3evrgrip <fwd>` (the one-handed form — forward only, the rest left
// where they are), `q3evrgrip <fwd> <right> <up> [pitch] [yaw] [roll]`,
// `q3evrgrip reset` (back to the constants) and bare `q3evrgrip` (report).

// One statement of what the command takes and what it costs, printed both by a
// malformed line and by a bare `q3evrgrip`.
static void Q3E_VR_GripUsage(void) {
	Com_Printf("q3evrgrip <fwd>                       forward only\n"
	           "q3evrgrip <fwd> <right> <up> [pitch] [yaw] [roll] | reset\n"
	           "          offsets clamp to +/-%.0fu, angles to +/-%.0fdeg\n"
	           "          SESSION ONLY — the shipped grip is f%.1f r%.1f u%.1f p%.0f y0 r0\n",
	           Q3E_VR_GRIP_OFF_LIMIT, Q3E_VR_GRIP_ANG_LIMIT,
	           Q3E_VR_GRIP_FWD_FIXED, Q3E_VR_GRIP_RIGHT_FIXED,
	           Q3E_VR_GRIP_UP_FIXED, Q3E_VR_GRIP_PITCH_FIXED);
}

static void Q3E_Cmd_VRGrip_f(void) {
	const int reportOnly = (Cmd_Argc() == 1);
	if (Cmd_Argc() == 2 && !Q_stricmp(Cmd_Argv(1), "reset")) {
		Q3E_VR_GripToDefaults();
	} else if (Cmd_Argc() == 2) {
		// The one-handed dialling form: forward only, everything else left where
		// it already is. Validated with strtod rather than atof
		// because a single mistyped argument here is the whole command — a typo
		// that silently reads as zero would move the weapon and look like a
		// setting that took.
		const char *s = Cmd_Argv(1);
		char *end = NULL;
		const double fwd = strtod(s, &end);
		if (end == s || *end != '\0' || !isfinite((float)fwd)) {
			Com_Printf("q3evrgrip: '%s' is not a number — nothing changed\n", s);
			return;
		}
		{
			const float off[3] = { (float)fwd, q3e_vrGrip[1], q3e_vrGrip[2] };
			Q3E_VR_SetGripOverride(off, q3e_vrGripAngles);
		}
	} else if (Cmd_Argc() >= 4) {
		int i;
		float v[6];
		for (i = 0; i < 3; i++)
			v[i] = (float)atof(Cmd_Argv(i + 1));
		for (i = 3; i < 6; i++)
			v[i] = (Cmd_Argc() > i + 1) ? (float)atof(Cmd_Argv(i + 1)) : q3e_vrGripAngles[i - 3];
		for (i = 0; i < 6; i++) {
			if (!isfinite(v[i])) {
				Com_Printf("q3evrgrip: every argument must be a number — nothing changed\n");
				return;
			}
		}
		// Clamped to the override's span (R3.3's rule, R4.0's limits): a mistyped
		// exponent must not put the weapon in the next room, where the player
		// cannot see it to correct the number that sent it there. Through the ONE
		// setter, so the limits have exactly one statement in the program.
		{
			const float off[3] = { v[0], v[1], v[2] };
			const float ang[3] = { v[3], v[4], v[5] };
			Q3E_VR_SetGripOverride(off, ang);
		}
	} else if (Cmd_Argc() != 1) {
		Q3E_VR_GripUsage();
		return;
	}
	VK_SetVRGun((q3e_vrAimHand == Q3E_VR_HAND_LEFT) ? 0 : 1,
	            q3e_vrGunScale, q3e_vrGrip, q3e_vrGripAngles);
	// R4.0: NOT persisted. R3.2 persisted the grip because that round's whole
	// purpose was that numbers dialled on glass survive to become defaults; they
	// have become defaults, they are constants in this file, and a store that
	// could still hold a grip would be a second opinion about a value nothing
	// consults it for.
	Com_Printf("q3evrgrip: offset=(f%.1f,r%.1f,u%.1f)u angles=(p%.1f,y%.1f,r%.1f)deg\n",
	           q3e_vrGrip[0], q3e_vrGrip[1], q3e_vrGrip[2],
	           q3e_vrGripAngles[0], q3e_vrGripAngles[1], q3e_vrGripAngles[2]);
	if (reportOnly)
		Q3E_VR_GripUsage();
	q3e_dump_viewmodel();
	q3e_vr_nowseq();
}

// `q3evranchor <0|1>` — the resting rear-plane anchor, on or off.
//
// R3.5's A/B instrument. Off is exactly the placement the cgame asked for, which
// is what every build before 1.0.4.10 drew; on slides the whole first-person
// assembly along the grip's forward axis so that every weapon's rear plane rests
// where the machinegun's does. Session-only and dev-gated on purpose: it is a
// question being asked of a headset, not a setting anyone should have to find.
//
// NOT dev-gated, unlike the sky probes it sits next to. Those are gated because
// they cost real frame time and because a public build that can be told to draw
// the sky over the world is a public build with a cheat in it; this one costs
// nothing, changes only where a cosmetic model is drawn, and moves it no further
// than `q3evrgrip` already can. Ungated it is also testable in the public
// configuration the simulator suite actually builds, which is where the A/B
// earns its keep as that case's own fault injection.
static void Q3E_Cmd_VRAnchor_f(void) {
	if (Cmd_Argc() >= 2)
		VK_SetVRGunAnchor(atoi(Cmd_Argv(1)) ? 1 : 0);
	Com_Printf("q3evranchor: %s — the rear-plane anchor is %s\n",
	           vk_vr_gun_anchor_on ? "1" : "0",
	           vk_vr_gun_anchor_on ? "applied" : "bypassed (the cgame's own placement stands)");
	q3e_dump_viewmodel();
	q3e_vr_nowseq();
}

// `q3evrrearm <0|1>` — whether VR re-asserts its cvar invariant every frame.
//
// R4.4's fault injection, and the only way to reproduce the defect it fixes: off
// makes the mode machine stop restoring `r_stereo3d` (and `cg_draw3dIcons`), so
// the next `game_restart` freezes the eye pairs exactly as every build before
// this one did. Ungated for the `q3evranchor` reason — the simulator suite
// builds the PUBLIC configuration, and a dev-gated toggle could not produce the
// red case at all. Session-only; nothing persists it. Turning it back ON does
// not itself repair anything: the next engine frame does, which is the point.
static void Q3E_Cmd_VRRearm_f(void) {
	if (Cmd_Argc() >= 2)
		q3e_vrRearmHook = atoi(Cmd_Argv(1)) ? 1 : 0;
	Com_Printf("q3evrrearm: %s — VR %s (restored %d time(s) so far)\n",
	           q3e_vrRearmHook ? "1" : "0",
	           q3e_vrRearmHook ? "re-asserts r_stereo3d/cg_draw3dIcons every engine frame"
	                           : "leaves them wherever the engine last put them "
	                             "(pre-R4.4 behaviour: a game_restart kills the eye path)",
	           q3e_vrRearmCount);
	q3e_dump_mode();
	q3e_vr_nowseq();
}

// `q3evrscorehold <0|1>` — whether the +scores hold counts as a scoreboard.
//
// R4.2 item 2's A/B instrument, and the fault injection its assertion needs: off
// is exactly the R4.1 behaviour, where only PM_DEAD and the two intermission
// states raised the scoreboard and an interactive scoreboard was therefore torn
// across the head-locked bands. Ungated for the same reason `q3evranchor` above
// is: the simulator suite builds the PUBLIC configuration, so a dev-gated toggle
// could not produce the red case at all. Session-only — nothing persists it.
static void Q3E_Cmd_VRScoreHold_f(void) {
	if (Cmd_Argc() >= 2)
		q3e_vrScoresHoldHook = atoi(Cmd_Argv(1)) ? 1 : 0;
	Q3E_VR_SampleClientState();
	Com_Printf("q3evrscorehold: %s — the +scores hold %s\n",
	           q3e_vrScoresHoldHook ? "1" : "0",
	           q3e_vrScoresHoldHook ? "raises the scoreboard"
	                                : "is ignored (R4.1 behaviour: death and intermission only)");
	q3e_dump_panel();
	q3e_vr_nowseq();
}

// `q3evrhaptics <0|1>` — the Controller Haptics row, from the console.
static void Q3E_Cmd_VRHaptics_f(void) {
	if (Cmd_Argc() >= 2) {
		q3e_vrHaptics = atoi(Cmd_Argv(1)) ? 1 : 0;
		Q3E_VR_PersistTuning();
	}
	Com_Printf("q3evrhaptics: %s\n", q3e_vrHaptics ? "on" : "off");
	// A pulse on both hands, so "on" is something the player can feel rather
	// than only read.
	if (q3e_vrHaptics) {
		Q3E_VR_Haptic(0, 0.5f, 0.03f, "haptics-test");
		Q3E_VR_Haptic(1, 0.5f, 0.03f, "haptics-test");
	}
	q3e_dump_hand();
	q3e_vr_nowseq();
}

// `q3evrhandctx <0|1>` — fault injection for the context-boundary rule. With it
// off the gameplay <-> menu boundary neither releases what the Sense pair is
// holding nor rebases the edge detector, so a trigger held across it stays
// latched on the far side. That is the state the suite watches the assertion
// FAIL in, so the green one means something.
static void Q3E_Cmd_VRHandCtx_f(void) {
	if (Cmd_Argc() >= 2)
		q3e_vr_sense_ctx_handoff = atoi(Cmd_Argv(1)) ? 1 : 0;
	Com_Printf("q3evrhandctx: %s\n", q3e_vr_sense_ctx_handoff ? "ON" : "off (FAULT INJECTION)");
	q3e_dump_hand();
	q3e_vr_nowseq();
}

// `q3evrsense` — what the hardware layer enumerated and what tracking says
// about it. The first line of any device round with the controllers in hand.
static void Q3E_Cmd_VRSense_f(void) {
	q3e_vr_emit("SENSENOW controllers=[%s] tracking=[%s]",
	            Q3E_Sense_StatusControllers(), Q3E_Sense_StatusTracking());
	Com_Printf("inventory:\n%s", Q3E_Sense_InventoryText());
	q3e_vr_nowseq();
}

// `q3evrheadaim <0|1>` — fault injection for the AIMNOW identity assertion
// (see q3e_dump_aim's comment): disable the engine hook and the sent angles
// stop tracking body+head, which is what proves the assertion can fail.
static void Q3E_Cmd_VRHeadAim_f(void) {
	if (Cmd_Argc() >= 2)
		cl_vr_head_aim_hook_enabled = atoi(Cmd_Argv(1)) ? 1 : 0;
	q3e_dump_aim();
	q3e_vr_nowseq();
}

// `q3evrpitchcomp <0|1>` — fault injection for the OTHER half of the aim
// identity (R2.2 fix 3). With it off, the hook writes the head pitch
// absolutely, exactly as it did before the fix, and the effective pitch the
// server computes walks off by the whole delta_angles[PITCH] the next respawn
// installs. That is the state the suite watches the assertion FAIL in, so the
// green one means something.
static void Q3E_Cmd_VRPitchComp_f(void) {
	if (Cmd_Argc() >= 2)
		cl_vr_head_pitch_delta_enabled = atoi(Cmd_Argv(1)) ? 1 : 0;
	q3e_dump_aim();
	q3e_vr_nowseq();
}

// `q3evruipixel <x> <y>` — one pixel of the UI layer, as the compositor samples
// it. ALPHA is the point: it is the half of the layer no screenshot can show,
// and a HUD composited at the wrong coverage looks perfect in a capture.
//
// Asynchronous by construction: the request is serviced by the compositor thread
// after it has finished the frame, so the command asks and the NEXT invocation
// reads. Reporting `ready=0` rather than a stale value is the difference between
// a dump and a guess.
// TEST HOOK: stop the 2D stream from being separated out, which is the state a
// frame with no 2D in it produces. Turning the HUD off does NOT produce it — the
// stream keeps coming from somewhere else in the frame — so the freshness gate
// is exercised at its own mechanism instead of through a premise that is false.
static void Q3E_Cmd_VRUIStall_f(void) {
	if (Cmd_Argc() >= 2)
		VK_SetVRUIStall(atoi(Cmd_Argv(1)));
	q3e_dump_panel();
	q3e_vr_nowseq();
}

static void Q3E_Cmd_VRUIPixel_f(void) {
	float rgba[4] = { -1, -1, -1, -1 };
	float maxA = -1.0f;
	int covered = -1, sampled = 0;
	const int ready = Q3E_VR_ReadUIPixel(rgba, &maxA, &covered, &sampled);
	if (Cmd_Argc() >= 3)
		Q3E_VR_RequestUIPixel(atoi(Cmd_Argv(1)), atoi(Cmd_Argv(2)),
		                      Cmd_Argc() >= 4 ? atoi(Cmd_Argv(3)) : 1);
	q3e_vr_emit("UIPIXELNOW ready=%d first=(%.3f,%.3f,%.3f,%.3f)rgba maxalpha=%.3f "
	            "covered=%d of=%d requested=(%s,%s,n%s)",
	            ready, rgba[0], rgba[1], rgba[2], rgba[3], maxA, covered, sampled,
	            Cmd_Argc() >= 3 ? Cmd_Argv(1) : "-", Cmd_Argc() >= 3 ? Cmd_Argv(2) : "-",
	            Cmd_Argc() >= 4 ? Cmd_Argv(3) : "1");
	q3e_vr_nowseq();
}

// `q3evrmovemode <head|aimhand|offhand|off>` — R3: all four now mean something,
// and an untracked hand basis falls back to the head rather than to nothing.
static void Q3E_Cmd_VRMoveMode_f(void) {
	if (Cmd_Argc() >= 2) {
		const char *a = Cmd_Argv(1);
		if (!Q_stricmp(a, "head"))         q3e_vrMoveBasis = Q3E_VRMOVE_HEAD;
		else if (!Q_stricmp(a, "aimhand")) q3e_vrMoveBasis = Q3E_VRMOVE_AIM_HAND;
		else if (!Q_stricmp(a, "offhand")) q3e_vrMoveBasis = Q3E_VRMOVE_OFF_HAND;
		else if (!Q_stricmp(a, "off"))     q3e_vrMoveBasis = Q3E_VRMOVE_OFF;
		else Com_Printf("usage: q3evrmovemode <head|aimhand|offhand|off>\n");
		// R2.1 fix 6b, now that this setting HAS a store: without the
		// write-back the sheet's stale stored value silently overwrites a live
		// console change the next time any row in it moves.
		Q3E_VR_PersistTuning();
	}
	q3e_dump_move();
	q3e_vr_nowseq();
}

// `q3evraimmode <head|gamepad>` — R4.6, the "Aiming" row's console spelling.
// Persisted through the same write-back every other row's command uses, so a
// console change and the sheet can never hold different opinions.
static void Q3E_Cmd_VRAimMode_f(void) {
	if (Cmd_Argc() >= 2) {
		const char *a = Cmd_Argv(1);
		if (!Q_stricmp(a, "head"))            Q3E_VR_SetAimModeQuiet(Q3E_VRAIMMODE_HEAD);
		else if (!Q_stricmp(a, "gamepad") ||
		         !Q_stricmp(a, "pad"))        Q3E_VR_SetAimModeQuiet(Q3E_VRAIMMODE_PAD);
		else Com_Printf("usage: q3evraimmode <head|gamepad>\n");
		Q3E_VR_PersistTuning();
	}
	q3e_dump_aim();
	q3e_vr_nowseq();
}

// `q3evrpadaim <0|1>` — the fault injection for everything above. NOT dev-gated,
// the `q3evranchor` precedent: the suite builds the PUBLIC configuration, and a
// switch it cannot reach cannot prove an assertion is able to fail.
static void Q3E_Cmd_VRPadAim_f(void) {
	if (Cmd_Argc() >= 2)
		q3e_vrPadAimEnabled = atoi(Cmd_Argv(1)) ? 1 : 0;
	q3e_dump_aim();
	q3e_vr_nowseq();
}

// `q3evrpadstick <x> <y> [hold seconds]` — a HELD synthetic right stick, and
// `q3evrpad <auto|0|1>` — whether a plain gamepad counts as connected. The
// simulator has no controllers at all, so without these two nothing about this
// mode is reachable from a test.
static void Q3E_Cmd_VRPadStick_f(void) {
	if (Cmd_Argc() < 3) {
		Com_Printf("usage: q3evrpadstick <x -1..1> <y -1..1> [hold seconds]\n");
		q3e_dump_aim();
		q3e_vr_nowseq();
		return;
	}
	{
		const float hold = (Cmd_Argc() >= 4) ? atof(Cmd_Argv(3)) : 0.5f;
		q3e_vrSynthPadX = atof(Cmd_Argv(1));
		q3e_vrSynthPadY = atof(Cmd_Argv(2));
		q3e_vrSynthPadMs = (hold > 0.0f) ? Sys_Milliseconds() + (int)(hold * 1000.0f) : 0;
	}
	q3e_dump_aim();
	q3e_vr_nowseq();
}

static void Q3E_Cmd_VRPad_f(void) {
	if (Cmd_Argc() >= 2) {
		const char *a = Cmd_Argv(1);
		if (!Q_stricmp(a, "auto")) q3e_vrSynthPadConn = -1;
		else                       q3e_vrSynthPadConn = atoi(a) ? 1 : 0;
	}
	q3e_dump_aim();
	q3e_vr_nowseq();
}

// `q3evrturn <smooth|30|45|60|off> [deg/s]`
static void Q3E_Cmd_VRTurn_f(void) {
	if (Cmd_Argc() >= 2) {
		const char *a = Cmd_Argv(1);
		if (!Q_stricmp(a, "smooth"))   q3e_vrTurnMode = Q3E_VRTURN_SMOOTH;
		else if (!strcmp(a, "30"))     q3e_vrTurnMode = Q3E_VRTURN_SNAP30;
		else if (!strcmp(a, "45"))     q3e_vrTurnMode = Q3E_VRTURN_SNAP45;
		else if (!strcmp(a, "60"))     q3e_vrTurnMode = Q3E_VRTURN_SNAP60;
		else if (!Q_stricmp(a, "off")) q3e_vrTurnMode = Q3E_VRTURN_OFF;
		else Com_Printf("usage: q3evrturn <smooth|30|45|60|off> [deg/s]\n");
	}
	if (Cmd_Argc() >= 3) {
		// R2.2 fix 7: through the SAME setter the settings sheet applies with,
		// so "what a legal range means" is one rule in one place rather than
		// two spellings that can drift.
		const float s = atof(Cmd_Argv(2));
		Q3E_VR_SetTurnQuiet(q3e_vrTurnMode, s);
		if (!isfinite(s))
			Com_Printf("turn speed must be a number — kept %g deg/s\n", q3e_vrTurnSpeed);
		else if (s != q3e_vrTurnSpeed)
			Com_Printf("turn speed %g is outside 60-260 deg/s — clamped to %g\n", s, q3e_vrTurnSpeed);
	}
	// R2.1 fix 6b: write back to NSUserDefaults so a console/ornament change
	// is what the settings sheet (and the next ApplyAll) sees too, instead of
	// a stale stored value clobbering it back on the next unrelated slider.
	if (Cmd_Argc() >= 2) Q3E_VR_PersistTuning();
	q3e_dump_move();
	q3e_vr_nowseq();
}

// `q3evrhudsize <0.8..2.0>` / `q3evrhudheight <-15..15>` — the two controls the
// head-locked 2D layout has. HUD Size is how big each quad is; HUD Height is
// where the whole cluster sits, in degrees above or below its default pitch.
// R3.2 item 2 renamed the second one from `q3evrpanelsize`, and it is a
// different quantity, not a relabelled one — see q3e_vrHudHeight's own comment.
// Both live while VR is running, so they can be dialled in from the console
// with the headset on.
static void Q3E_Cmd_VRHudSize_f(void) {
	if (Cmd_Argc() != 2) {
		Com_Printf("q3evrhudsize <0.8..2.0>   current: %.2fx\n", q3e_vrHudSize);
		return;
	}
	float s = (float)atof(Cmd_Argv(1));
	if (!isfinite(s)) {
		Com_Printf("q3evrhudsize: must be a number — kept %.2fx\n", q3e_vrHudSize);
		return;
	}
	Q3E_VR_SetHudSizeQuiet(s);
	if (s != q3e_vrHudSize)
		Com_Printf("q3evrhudsize: %.2f is outside 0.8..2.0 — clamped\n", s);
	Com_Printf("q3evrhudsize: %.2fx\n", q3e_vrHudSize);
	Q3E_VR_PersistTuning();   // R2.1 fix 6b
	q3e_vr_nowseq();
}

// `q3evrdepthfloor <0..0.01>` — R3.1 item 3, the sky fix with its own off
// switch. See q3e_vrEyeDepthFloor's comment for what the number does; 0 is the
// behaviour every build before this one had, so a device session can turn the
// fix off, watch the sky go black outside the HUD panel, turn it back on and
// watch it return. A fix that cannot be switched off is a fix nobody can prove.
//
// Registered in every build rather than behind the dev gate: it is a rendering
// tunable with a legitimate default, not a bypass that draws things a player is
// not supposed to see, and the one machine that can falsify it is a headset.
static void Q3E_Cmd_VRDepthFloor_f(void) {
	if (Cmd_Argc() != 2) {
		Com_Printf("q3evrdepthfloor <0..0.01>   current: %.6f\n", q3e_vrEyeDepthFloor);
		return;
	}
	float f = (float)atof(Cmd_Argv(1));
	if (!isfinite(f)) {
		Com_Printf("q3evrdepthfloor: must be a number — kept %.6f\n", q3e_vrEyeDepthFloor);
		return;
	}
	// The ceiling is deliberately tiny. This value is a REVERSE-Z depth, so it
	// grows as things come closer: 0.01 is already only 10 metres away, and a
	// floor any nearer than that would start hiding the far end of a map behind
	// its own sky. Anything larger is a typo, not an intention.
	q3e_vrEyeDepthFloor = q3e_vr_clamp_range(f, 0.0f, 0.01f);
	if (f != q3e_vrEyeDepthFloor)
		Com_Printf("q3evrdepthfloor: %.6f is outside 0..0.01 — clamped\n", f);
	Com_Printf("q3evrdepthfloor: %.6f\n", q3e_vrEyeDepthFloor);
	q3e_vr_nowseq();
}

static void Q3E_Cmd_VRHudHeight_f(void) {
	if (Cmd_Argc() != 2) {
		Com_Printf("q3evrhudheight <-15..15>   current: %+.1fdeg\n", q3e_vrHudHeight);
		return;
	}
	float s = (float)atof(Cmd_Argv(1));
	if (!isfinite(s)) {
		Com_Printf("q3evrhudheight: must be a number — kept %+.1fdeg\n", q3e_vrHudHeight);
		return;
	}
	Q3E_VR_SetHudHeightQuiet(s);
	if (s != q3e_vrHudHeight)
		Com_Printf("q3evrhudheight: %.1f is outside -15..15 — clamped\n", s);
	Com_Printf("q3evrhudheight: %+.1fdeg\n", q3e_vrHudHeight);
	Q3E_VR_PersistTuning();   // R2.1 fix 6b
	q3e_vr_nowseq();
}

// `q3evrxhair <0|1>` — R3.2 item 7, the donor's VR Crosshair row. Off keeps the
// stored SIZE untouched, so turning it back on restores the size that was
// dialled in rather than a default.
static void Q3E_Cmd_VRXhairOn_f(void) {
	if (Cmd_Argc() >= 2) {
		Q3E_VR_SetXhairOnQuiet(atoi(Cmd_Argv(1)) ? 1 : 0);
		Q3E_VR_PersistTuning();
	}
	Com_Printf("q3evrxhair: %s (size %.2fx)\n", q3e_vrXhairOn ? "on" : "off", q3e_vrXhairSize);
	q3e_vr_nowseq();
}

// `q3evrhands <0|1>` — R4.3 item 1, the donor's Show Hands row. NOT dev-gated
// (the `q3evranchor` precedent: the suite builds the PUBLIC configuration, so a
// gated command cannot be used to prove the shipped one).
static void Q3E_Cmd_VRShowHands_f(void) {
	if (Cmd_Argc() >= 2) {
		Q3E_VR_SetShowHandsQuiet(atoi(Cmd_Argv(1)) ? 1 : 0);
		Q3E_VR_PersistTuning();
	}
	Com_Printf("q3evrhands: %s\n", q3e_vrShowHands ? "on" : "off");
	q3e_vr_nowseq();
}

// `q3evrsharpen <0..100>` — R4.3 item 2, in the donor's own percent units. The
// stored and dumped value is the fraction; only this command and the row speak
// percent, and they agree because both go through this clamp.
static void Q3E_Cmd_VRSharpen_f(void) {
	if (Cmd_Argc() >= 2) {
		char *end = NULL;
		double v = strtod(Cmd_Argv(1), &end);
		if (end == Cmd_Argv(1) || *end != '\0') {
			Com_Printf("q3evrsharpen: must be a number — kept %.0f%%\n",
			           q3e_vrSharpen * 100.0f);
			return;
		}
		Q3E_VR_SetSharpenQuiet((float)v / 100.0f);
		if (fabs(v / 100.0 - (double)q3e_vrSharpen) > 0.0005)
			Com_Printf("q3evrsharpen: %.0f is outside 0..100 — clamped\n", v);
		Q3E_VR_PersistTuning();
	}
	Com_Printf("q3evrsharpen: %.0f%%\n", q3e_vrSharpen * 100.0f);
	q3e_vr_nowseq();
}

// `q3evrdamageflash <0|1>` — R4.3 item 3. Off drops the cgame's own blood-blend
// pic in the renderer, so it works for any cgame that draws one (see D-VR-R4.3).
static void Q3E_Cmd_VRDamageFlash_f(void) {
	int seen = 0, dropped = 0;
	if (Cmd_Argc() >= 2) {
		Q3E_VR_SetDamageFlashQuiet(atoi(Cmd_Argv(1)) ? 1 : 0);
		Q3E_VR_PersistTuning();
	}
	seen = VK_GetVRDamageBlends(&dropped);
	Com_Printf("q3evrdamageflash: %s (blends seen %d, dropped %d)\n",
	           q3e_vrDamageFlash ? "on" : "off", seen, dropped);
	q3e_vr_nowseq();
}

// `q3evrxhairsize <0.5..1.5>` — the world-space aim marker's angular size
// (R2.3 fix 2), independent of the HUD quads. R3.1 item 1 narrowed the range:
// these are still the marker's NATIVE units, which is what this command reads
// and prints; only the settings row remaps them to a 1x..5x travel.
static void Q3E_Cmd_VRXhairSize_f(void) {
	if (Cmd_Argc() != 2) {
		Com_Printf("q3evrxhairsize <0.5..1.5>   current: %.2fx\n", q3e_vrXhairSize);
		return;
	}
	float s = (float)atof(Cmd_Argv(1));
	if (!isfinite(s)) {
		Com_Printf("q3evrxhairsize: must be a number — kept %.2fx\n", q3e_vrXhairSize);
		return;
	}
	Q3E_VR_SetXhairSizeQuiet(s);   // R2.2 fix 7: one clamp, shared with the sheet
	if (s != q3e_vrXhairSize)
		Com_Printf("q3evrxhairsize: %.2f is outside 0.5..1.5 — clamped\n", s);
	Com_Printf("q3evrxhairsize: %.2fx\n", q3e_vrXhairSize);
	Q3E_VR_PersistTuning();   // R2.1 fix 6b
	q3e_vr_nowseq();
}

static const char *q3e_hudpos_name(int p) {
	switch (p) {
		case Q3E_VRHUD_ON:  return "on";
		case Q3E_VRHUD_OFF: return "off";
		default:            return "?";
	}
}

// `q3evrhud <on|off>` — R3.2 item 4. Off draws no head-locked HUD quad at all
// in a world frame (the scoreboard/death overlay still shows: that is not the
// HUD). The old high/low words are accepted and both mean ON, so a config, a
// script or a habit from the previous build keeps working instead of printing
// a usage line at somebody wearing a headset.
static void Q3E_Cmd_VRHud_f(void) {
	if (Cmd_Argc() >= 2) {
		const char *a = Cmd_Argv(1);
		if (!Q_stricmp(a, "on") || !Q_stricmp(a, "high") || !Q_stricmp(a, "low"))
			q3e_vrHudPos = Q3E_VRHUD_ON;
		else if (!Q_stricmp(a, "off"))
			q3e_vrHudPos = Q3E_VRHUD_OFF;
		else Com_Printf("usage: q3evrhud <on|off>\n");
		Q3E_VR_PersistTuning();   // R2.1 fix 6b
	}
	Com_Printf("q3evrhud: %s\n", q3e_hudpos_name(q3e_vrHudPos));
	q3e_vr_nowseq();
}

// TEST HOOK + real input path: inject a turn-stick deflection for one frame's
// worth of time, at the OUTPUT boundary of the pad layer, so the mode logic and
// the hysteresis under test are the ones that ship.
static void Q3E_Cmd_VRTurnStick_f(void) {
	if (Cmd_Argc() < 2) { Com_Printf("usage: q3evrturnstick <x -1..1> [hold seconds]\n"); return; }
	{
		const float x = atof(Cmd_Argv(1));
		const float hold = (Cmd_Argc() >= 3) ? atof(Cmd_Argv(2)) : 0.5f;
		q3e_vrSynthTurnAxis = x;
		q3e_vrSynthTurnMs = (hold > 0.0f) ? Sys_Milliseconds() + (int)(hold * 1000.0f) : 0;
	}
	q3e_dump_move();
	q3e_vr_nowseq();
}

// `q3evrcalibrate` — capture the standing eye height from the live head pose.
// `q3evrcalibrate <m>` forces a value, which is how the simulator (whose head is
// at whatever q3evrpose says) exercises the sanity gate in both directions.
static void Q3E_Cmd_VRCalibrate_f(void) {
	// ORIGIN space, not base space. q3e_vrHeadPos is the head relative to the
	// captured base, so for a player standing where they entered it is about
	// ZERO — and the sanity gate then refuses every real recalibration on the
	// device while the forced-value form used by the suite works perfectly. The
	// entry auto-capture reads the origin-space height; so does this.
	const float m = (Cmd_Argc() >= 2) ? atof(Cmd_Argv(1)) : q3e_vrHeadOriginY;
	if (!Q3E_VR_CaptureHeight(m))
		Com_Printf("height %.2f m REFUSED by the 0.60-2.60 m sanity gate\n", m);
	Q3E_VR_PublishHeight();
	Q3E_VR_PersistHeight();
	q3e_dump_head();
	q3e_vr_nowseq();
}

// `q3evrheight <+/-m>` — the player's own trim on top of the baseline.
static void Q3E_Cmd_VRHeight_f(void) {
	if (Cmd_Argc() >= 2) {
		const float t = atof(Cmd_Argv(1));
		// R2.2 fix 7: through Q3E_VR_SetPersistedHeightTrimMetres — the same
		// single setter the settings sheet and the settings migration use, so
		// the console cannot clamp where the sheet drops (which is what let a
		// sheet slider end, and a migrated value, apply nothing at all). It
		// publishes and persists too; both are idempotent with the calls below.
		// A one-sided clamp pair passes NaN through untouched; the setter
		// refuses it outright, and says so here.
		Q3E_VR_SetPersistedHeightTrimMetres(t);
		if (!isfinite(t))
			Com_Printf("height trim must be a number — kept %+.2f m\n", q3e_vrHeightTrim);
		else if (t != q3e_vrHeightTrim)
			Com_Printf("height trim %+.2f m is outside +/-%.2f m — clamped to %+.2f m\n",
			           t, Q3E_VR_TRIM_LIMIT_M, q3e_vrHeightTrim);
	}
	Q3E_VR_PublishHeight();
	Q3E_VR_PersistHeight();
	q3e_dump_head();
	q3e_vr_nowseq();
}

// Flush the black box on demand — the artifact channel when the bridge is quiet.
static void Q3E_Cmd_VRDiag_f(void) {
	Q3E_BlackBox_Flush();
	Com_Printf("black box flushed to Documents/blackbox.log\n");
	q3e_vr_nowseq();
}

// q3evrpose [off | yaw pitch x y z] — drive the head from the console.
// The values are injected where the tracked device anchor's pose lands, so the
// whole real transform chain downstream of it runs. The simulator has no head
// tracking at all (it answers with an identity pose), which is exactly why this
// exists: without it nothing in VR can be proved off a headset.
static void Q3E_Cmd_VRPose_f(void) {
	if (Cmd_Argc() == 2 && !Q_stricmp(Cmd_Argv(1), "off")) {
		q3e_vrSynthPose = 0;
		Com_Printf("q3evrpose: OFF (tracked pose)\n");
		q3e_vr_nowseq();
		return;
	}
	if (Cmd_Argc() != 6) {
		Com_Printf("q3evrpose <yaw-deg> <pitch-deg> <x-m> <y-m> <z-m> | off\n"
		           "   current: yaw=%.1f pitch=%.1f pos=(%.2f,%.2f,%.2f)m synth=%d\n",
		           q3e_vrSynthYaw, q3e_vrSynthPitch,
		           q3e_vrSynthPos[0], q3e_vrSynthPos[1], q3e_vrSynthPos[2],
		           q3e_vrSynthPose);
		return;
	}
	q3e_vrSynthYaw    = (float)atof(Cmd_Argv(1));
	q3e_vrSynthPitch  = (float)atof(Cmd_Argv(2));
	q3e_vrSynthPos[0] = (float)atof(Cmd_Argv(3));
	q3e_vrSynthPos[1] = (float)atof(Cmd_Argv(4));
	q3e_vrSynthPos[2] = (float)atof(Cmd_Argv(5));
	q3e_vrSynthPose   = 1;
	Com_Printf("q3evrpose: yaw=%.1fdeg pitch=%.1fdeg pos=(%.2f,%.2f,%.2f)m\n",
	           q3e_vrSynthYaw, q3e_vrSynthPitch,
	           q3e_vrSynthPos[0], q3e_vrSynthPos[1], q3e_vrSynthPos[2]);
	q3e_vr_nowseq();
}

// q3evripd [metres] — synthesise a stereo pair on a single-view drawable.
// The simulator vends ONE view with an identity transform, so without this the
// two eyes are numerically identical and no stereo assertion can fail.
static void Q3E_Cmd_VRIpd_f(void) {
	if (Cmd_Argc() != 2) {
		Com_Printf("q3evripd <metres>   (0 = use the drawable's own eye transforms)\n"
		           "   current: %.4f m\n", q3e_vrSynthIPD);
		return;
	}
	float m = (float)atof(Cmd_Argv(1));
	if (m < 0.0f) m = 0.0f;
	if (m > 0.5f) m = 0.5f;
	q3e_vrSynthIPD = m;
	Com_Printf("q3evripd: %.4f m\n", q3e_vrSynthIPD);
	q3e_vr_nowseq();
}

// q3evrscale [units/metre] — the console back door for world scale. No settings
// row by design: scale and player height must not both be knobs.
// q3evrtan [off | l r b t] — override the per-eye tangents at the point the
// compositor's own projection would be recovered, so the whole downstream chain
// (projection matrix AND cull planes) runs on an ASYMMETRIC frustum. The
// simulator's drawable has no projection to recover and would otherwise only
// ever exercise the symmetric case — which is exactly the case in which a
// wrongly-paired cull plane is invisible.
static void Q3E_Cmd_VRTan_f(void) {
	if (Cmd_Argc() == 2 && !Q_stricmp(Cmd_Argv(1), "off")) {
		q3e_vrSynthTanOn = 0;
		Com_Printf("q3evrtan: OFF (recovered tangents)\n");
		q3e_vr_nowseq();
		return;
	}
	if (Cmd_Argc() != 5) {
		Com_Printf("q3evrtan <left> <right> <bottom> <top> | off\n"
		           "   current: on=%d (%.3f %.3f %.3f %.3f)\n",
		           q3e_vrSynthTanOn, q3e_vrSynthTan[0], q3e_vrSynthTan[1],
		           q3e_vrSynthTan[2], q3e_vrSynthTan[3]);
		return;
	}
	float t[4];
	for (int i = 0; i < 4; i++) t[i] = (float)atof(Cmd_Argv(i + 1));
	if (!(t[1] > t[0]) || !(t[3] > t[2])) {
		Com_Printf("q3evrtan: degenerate (right must exceed left, top must exceed bottom) — ignored\n");
		return;
	}
	for (int i = 0; i < 4; i++) q3e_vrSynthTan[i] = t[i];
	q3e_vrSynthTanOn = 1;
	Com_Printf("q3evrtan: l=%.3f r=%.3f b=%.3f t=%.3f\n", t[0], t[1], t[2], t[3]);
	q3e_vr_nowseq();
}

static void Q3E_Cmd_VRScale_f(void) {
	if (Cmd_Argc() != 2) {
		Com_Printf("q3evrscale <units-per-metre>   current: %.2f u/m\n", q3e_vrWorldScale);
		return;
	}
	float s = (float)atof(Cmd_Argv(1));
	if (s < 8.0f || s > 128.0f) {
		Com_Printf("q3evrscale: %.2f is outside 8..128 u/m — ignored\n", s);
		return;
	}
	q3e_vrWorldScale = s;
	Com_Printf("q3evrscale: %.2f u/m\n", q3e_vrWorldScale);
	q3e_vr_nowseq();
}

// `q3evrsettingsdump` — the settings sheet's own values (ios_settings.m,
// TARGET_OS_VISION only), in the sheet's own units. No engine patch: this is
// the same shell-registers-after-Com_Init seam as every other q3evr* command.
extern void Q3E_VR_SettingsDumpString(char *buf, int n);
static void Q3E_Cmd_VRSettingsDump_f(void) {
	char buf[512];
	Q3E_VR_SettingsDumpString(buf, (int)sizeof(buf));
	q3e_vr_emit("%s", buf);
	q3e_vr_nowseq();
}

// `q3evruifallbackkill <0|1>` — R2.1 fix 11 fault injection: forces the
// fallback/scoreboard pipeline to be treated as missing (simulating a shader
// compile failure this session), so the degrade-to-region-pipeline path (the
// whole texture drawn through the pipeline that DID build, R1 behaviour) can
// be proven to actually show content rather than trusted on inspection.
static void Q3E_Cmd_VRUIFallbackKill_f(void) {
	if (Cmd_Argc() >= 2)
		Q3E_DebugKillFallbackPipeline(atoi(Cmd_Argv(1)));
	q3e_dump_panel();
	q3e_vr_nowseq();
}

static void Q3E_Cmd_VRRenderScale_f(void) {
	if (Cmd_Argc() != 2) {
		Com_Printf("q3evrrenderscale <1.0..2.0>   current: %.2fx\n", q3e_vrRenderScale);
		return;
	}
	float s = (float)atof(Cmd_Argv(1));
	if (!isfinite(s)) {
		Com_Printf("q3evrrenderscale: must be a number — kept %.2fx\n", q3e_vrRenderScale);
		return;
	}
	Q3E_VR_SetRenderScaleQuiet(s);   // R2.2 fix 7: one clamp, shared with the sheet
	if (s != q3e_vrRenderScale)
		Com_Printf("q3evrrenderscale: %.2f is outside 1.0..2.0 — clamped\n", s);
	// R3.2 item 5: live now, not "at the next VR entry" — the shell re-negotiates
	// the per-eye extent and restarts the renderer under the running session.
	Q3E_VR_PersistTuning();
	Q3E_VR_ReapplyRenderScale();
	Com_Printf("q3evrrenderscale: %.2fx\n", q3e_vrRenderScale);
	Q3E_VR_PersistTuning();   // R2.1 fix 6b
	q3e_vr_nowseq();
}

// --- R2.3 fix 5: sky diagnostics, DEV BUILDS ONLY ---------------------------
// The device renders the sky only inside a square that follows the view centre,
// with a stair-stepped border — the shape a SHORT sky-bounds accumulation makes,
// because DrawSkyBox quantizes those bounds to the subdivision grid. The R2.1
// probes cleared the projection, the frustum and the accumulation IN THE
// SIMULATOR and the symptom has never appeared there, so this round ships the
// two switches that split the remaining space instead of a third theory:
//
//   q3evrskyacc 1   — the sky box is drawn with fully open bounds. Sky whole
//                     => the accumulation is short; the fault is upstream of
//                     the draw, in what reached the batch.
//   q3evrskycull 1  — the world walk stops testing its frustum planes, so no
//                     sky face can be culled before it accumulates. Sky whole
//                     under THIS one and not the other => the front-end cull.
//   q3evrskynow     — the numbers either way: per-face bounds and drawn/skipped,
//                     the clipped triangle count, the eye tangents in use and
//                     the game's own fov.
//
// Registered only in a dev build: they are diagnostics with a real frame cost
// (the cull bypass draws the whole map), not shipped features.
// `q3evrxhairprobe <pushUnits> [depthtest 0|1]` — R4.5, the aim marker's
// occlusion probe. The marker is placed at a COLLISION trace hit, and on a
// curved surface the collision hull sits behind the drawn mesh (16 units of
// allowed chord error against the renderer's 1), so the marker used to land
// inside the wall and the depth test threw it away. The shipped fix is a
// marker that does not depth-test at all; this reproduces the old condition on
// demand — `1 60` puts the marker 60 units past the surface AND restores the
// depth test, which hides it, and `0 0` is the shipped state, which does not.
// A DIAGNOSTIC, but NOT dev-gated — for the same reason `q3evrpose` is not:
// the acceptance suite builds the app in its PUBLIC configuration, and an
// assertion that the marker survives being driven behind a surface is only
// worth having if the shipping build is the one it is asserted against. It
// reveals nothing and costs nothing: at its 0/0 default the renderer takes
// exactly the path it would with this code absent.
static void Q3E_Cmd_VRXhairProbe_f(void) {
	float push = 0.0f;
	int depthTest = 0;
	VK_GetVRXhairProbe(&push, &depthTest);
	if (Cmd_Argc() >= 2) {
		float p = (float)atof(Cmd_Argv(1));
		if (!isfinite(p)) {
			Com_Printf("q3evrxhairprobe: push must be a number — kept %.0fu\n", push);
			return;
		}
		push = p;
		if (Cmd_Argc() >= 3)
			depthTest = atoi(Cmd_Argv(2)) ? 1 : 0;
		VK_SetVRXhairProbe(push, depthTest);
		VK_GetVRXhairProbe(&push, &depthTest);
	}
	Com_Printf("q3evrxhairprobe: push=%.0fu depthtest=%d (DIAGNOSTIC — 0 0 is shipped)\n",
	           push, depthTest);
	q3e_vr_nowseq();
}

#ifdef Q3E_DEV_BUILD
static void Q3E_Cmd_VRSkyNow_f(void) {
	char line[1024];
	VK_VRSkyString(line, (int)sizeof(line));
	q3e_vr_emit("%s", line);
	q3e_vr_nowseq();
}

static void q3e_sky_toggle(const char *name, int *slot) {
	if (Cmd_Argc() >= 2)
		*slot = atoi(Cmd_Argv(1)) ? 1 : 0;
	VK_SetVRSkyToggles(q3e_sky_acc_open, q3e_sky_cull_open);
	// Read the engine's own values back, so the print and the EYENOW field
	// describe what the renderer took rather than what it was handed.
	VK_GetVRSkyToggles(&q3e_sky_acc_open, &q3e_sky_cull_open);
	Com_Printf("%s: %s (DIAGNOSTIC — acc=%d cull=%d)\n", name, *slot ? "ON" : "off",
	           q3e_sky_acc_open, q3e_sky_cull_open);
	q3e_vr_nowseq();
}

static void Q3E_Cmd_VRSkyAcc_f(void)  { q3e_sky_toggle("q3evrskyacc",  &q3e_sky_acc_open); }
static void Q3E_Cmd_VRSkyCull_f(void) { q3e_sky_toggle("q3evrskycull", &q3e_sky_cull_open); }

// R3.1 item 3. `q3evrskydraw` — the sky's GPU state at the draw, per eye:
// viewport, scissor (what is SET and what this view asks for), the push-constant
// matrix the GPU holds against the one this view's projection produces, the
// pipeline, the depth range, and whether anything had written depth. The 1.0.4.6
// device round retired the two toggles above (neither changed the picture, so
// the accumulation and the front-end cull are both innocent), which leaves this.
static void Q3E_Cmd_VRSkyDraw_f(void) {
	char line[1024];
	// One line per eye: the black box formats into an 800-byte record, and the
	// two eyes' matrix terms are the half most worth having intact.
	VK_VRSkyDrawString(line, (int)sizeof(line), 0);
	q3e_vr_emit("%s", line);
	VK_VRSkyDrawString(line, (int)sizeof(line), 1);
	q3e_vr_emit("%s", line);
	q3e_vr_nowseq();
}

// `q3evrskydepth 1` — the sky is drawn with nothing for the depth test to
// reject it: the outer skybox through a depth-test-disabled pipeline, the inner
// cloud box after an unconditional depth clear (its pipelines belong to the
// shader and cannot be rebuilt from here). Sky sorts ahead of the opaque world,
// so a clear at that point discards only what was in the buffer BEFORE the sky
// pass — which is the hypothesis. Whole sky under this switch means something
// pre-fills depth outside the square; no change means depth is not the gate.
static void Q3E_Cmd_VRSkyDepth_f(void) {
	if (Cmd_Argc() >= 2)
		q3e_sky_nodepth = atoi(Cmd_Argv(1)) ? 1 : 0;
	VK_SetVRSkyNoDepth(q3e_sky_nodepth);
	// Read back what the renderer took, same as the two toggles above.
	q3e_sky_nodepth = VK_GetVRSkyNoDepth();
	Com_Printf("q3evrskydepth: %s (DIAGNOSTIC - sky depth test %s)\n",
	           q3e_sky_nodepth ? "ON" : "off",
	           q3e_sky_nodepth ? "bypassed" : "normal");
	q3e_vr_nowseq();
}
#endif

void Q3E_VR_RegisterCommands(void) {
	Cmd_AddCommand("q3evrzones",       Q3E_Cmd_VRZones_f);
	Cmd_AddCommand("q3evrmode",        Q3E_Cmd_VRMode_f);
	Cmd_AddCommand("q3evreye",         Q3E_Cmd_VREye_f);
	Cmd_AddCommand("q3evrhead",        Q3E_Cmd_VRHead_f);
	Cmd_AddCommand("q3evrframe",       Q3E_Cmd_VRFrame_f);
	Cmd_AddCommand("q3evrnet",         Q3E_Cmd_VRNet_f);
	Cmd_AddCommand("q3evrdepth",       Q3E_Cmd_VRDepth_f);
	Cmd_AddCommand("q3evrmove",        Q3E_Cmd_VRMove_f);
	Cmd_AddCommand("q3evraim",         Q3E_Cmd_VRAim_f);
	Cmd_AddCommand("q3evrheadaim",     Q3E_Cmd_VRHeadAim_f);
	Cmd_AddCommand("q3evrpitchcomp",   Q3E_Cmd_VRPitchComp_f);
	Cmd_AddCommand("q3evrproj",        Q3E_Cmd_VRProj_f);
	Cmd_AddCommand("q3evrpanel",       Q3E_Cmd_VRPanel_f);
	Cmd_AddCommand("q3evruipixel",     Q3E_Cmd_VRUIPixel_f);
	Cmd_AddCommand("q3evruistall",     Q3E_Cmd_VRUIStall_f);
	Cmd_AddCommand("q3evrmovemode",    Q3E_Cmd_VRMoveMode_f);
	Cmd_AddCommand("q3evrturn",        Q3E_Cmd_VRTurn_f);
	Cmd_AddCommand("q3evrturnstick",   Q3E_Cmd_VRTurnStick_f);
	Cmd_AddCommand("q3evraimmode",     Q3E_Cmd_VRAimMode_f);
	Cmd_AddCommand("q3evrpadaim",      Q3E_Cmd_VRPadAim_f);
	Cmd_AddCommand("q3evrpadstick",    Q3E_Cmd_VRPadStick_f);
	Cmd_AddCommand("q3evrpad",         Q3E_Cmd_VRPad_f);
	Cmd_AddCommand("q3evrxhairsize",   Q3E_Cmd_VRXhairSize_f);
	Cmd_AddCommand("q3evrhud",         Q3E_Cmd_VRHud_f);
	Cmd_AddCommand("q3evrhudsize",     Q3E_Cmd_VRHudSize_f);
	Cmd_AddCommand("q3evrhudheight",   Q3E_Cmd_VRHudHeight_f);
	Cmd_AddCommand("q3evrxhair",       Q3E_Cmd_VRXhairOn_f);
	Cmd_AddCommand("q3evrhands",       Q3E_Cmd_VRShowHands_f);
	Cmd_AddCommand("q3evrsharpen",     Q3E_Cmd_VRSharpen_f);
	Cmd_AddCommand("q3evrdamageflash", Q3E_Cmd_VRDamageFlash_f);
	Cmd_AddCommand("q3evrdepthfloor",  Q3E_Cmd_VRDepthFloor_f);
	Cmd_AddCommand("q3evrhandnow",     Q3E_Cmd_VRHandNow_f);
	Cmd_AddCommand("q3evrviewmodel",   Q3E_Cmd_VRViewmodel_f);
	Cmd_AddCommand("q3evrhand",        Q3E_Cmd_VRHand_f);
	Cmd_AddCommand("q3evrhandbtn",     Q3E_Cmd_VRHandBtn_f);
	Cmd_AddCommand("q3evrhandstick",   Q3E_Cmd_VRHandStick_f);
	Cmd_AddCommand("q3evrhandaim",     Q3E_Cmd_VRHandAim_f);
	Cmd_AddCommand("q3evrhandctx",     Q3E_Cmd_VRHandCtx_f);
	Cmd_AddCommand("q3evraimhand",     Q3E_Cmd_VRAimHand_f);
	Cmd_AddCommand("q3evraimtrim",     Q3E_Cmd_VRAimTrim_f);
	Cmd_AddCommand("q3evrgunscale",    Q3E_Cmd_VRGunScale_f);
	Cmd_AddCommand("q3evrgrip",        Q3E_Cmd_VRGrip_f);
	Cmd_AddCommand("q3evrhaptics",     Q3E_Cmd_VRHaptics_f);
	Cmd_AddCommand("q3evrsense",       Q3E_Cmd_VRSense_f);
#ifdef Q3E_DEV_BUILD
	Cmd_AddCommand("q3evrskynow",      Q3E_Cmd_VRSkyNow_f);
	Cmd_AddCommand("q3evrskyacc",      Q3E_Cmd_VRSkyAcc_f);
	Cmd_AddCommand("q3evrskycull",     Q3E_Cmd_VRSkyCull_f);
	Cmd_AddCommand("q3evrskydraw",     Q3E_Cmd_VRSkyDraw_f);
	Cmd_AddCommand("q3evrskydepth",    Q3E_Cmd_VRSkyDepth_f);
#endif
	Cmd_AddCommand("q3evrxhairprobe",  Q3E_Cmd_VRXhairProbe_f);
	Cmd_AddCommand("q3evranchor",      Q3E_Cmd_VRAnchor_f);
	Cmd_AddCommand("q3evrscorehold",   Q3E_Cmd_VRScoreHold_f);
	Cmd_AddCommand("q3evrrearm",       Q3E_Cmd_VRRearm_f);
	Cmd_AddCommand("q3evruifallbackkill", Q3E_Cmd_VRUIFallbackKill_f);
	Cmd_AddCommand("q3evrcalibrate",   Q3E_Cmd_VRCalibrate_f);
	Cmd_AddCommand("q3evrheight",      Q3E_Cmd_VRHeight_f);
	Cmd_AddCommand("q3evrdiag",        Q3E_Cmd_VRDiag_f);
	Cmd_AddCommand("q3evrpose",        Q3E_Cmd_VRPose_f);
	Cmd_AddCommand("q3evripd",         Q3E_Cmd_VRIpd_f);
	Cmd_AddCommand("q3evrtan",         Q3E_Cmd_VRTan_f);
	Cmd_AddCommand("q3evrscale",       Q3E_Cmd_VRScale_f);
	Cmd_AddCommand("q3evrrenderscale", Q3E_Cmd_VRRenderScale_f);
	Cmd_AddCommand("q3evrsettingsdump", Q3E_Cmd_VRSettingsDump_f);
}
