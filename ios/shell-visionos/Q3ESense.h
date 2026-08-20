#pragma once
// Q3ESense.h — PSVR2 Sense controllers on visionOS: buttons, sticks, haptics,
// and where the hands are.
//
// This file owns HARDWARE and nothing else: GameController discovery, the
// element inventory, ARKit accessory tracking, per-hand haptics. It reports each
// hand as a raw ARKit pose in TRACKING SPACE, in metres, and never converts
// anything into Quake's world — that conversion belongs to Q3EVR.m, which
// already owns the alignment, the recentre base and the world scale the eyes go
// through. One chain, one recentre, one place to be wrong.

#include <stdbool.h>
#ifdef __OBJC__
#import <simd/simd.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Button bits. Shared by every consumer: the VR gameplay binds, the UI pump and
// the flat-mode pad merge all read the SAME mask out of the SAME snapshot, so
// there is no second list to keep in step.
#define Q3E_SENSE_TRIGGER (1u << 0)
#define Q3E_SENSE_GRIP    (1u << 1)
#define Q3E_SENSE_A       (1u << 2)
#define Q3E_SENSE_B       (1u << 3)
#define Q3E_SENSE_STICK   (1u << 4)
#define Q3E_SENSE_MENU    (1u << 5)

#define Q3E_SENSE_LEFT  0
#define Q3E_SENSE_RIGHT 1

#ifdef __OBJC__
// One hand, as the hardware sees it. Everything in this struct is sampled in the
// same compositor frame, so a consumer never mixes a pose from one instant with
// a button from another.
typedef struct {
    int           posed;          // a tracked pose arrived this frame
    int           held;           // ARKit says it is in a hand (not on a table)
    int           present;        // a controller is assigned to this hand at all
    simd_float4x4 originFromHand; // tracking space, metres
    simd_float3   velocity;       // tracking space, metres/sec (from the anchor)
    unsigned      buttons;
    float         trigger, grip;
    float         stickX, stickY;
} Q3ESenseHand;

// Once per compositor frame, from the VR loop, immediately after the head anchor
// is queried — that is what makes hands and head coherent.
void Q3E_Sense_Poll(Q3ESenseHand out[2]);
#endif

// Idempotent. Installs the GameController observers and (on the first controller
// of any kind) requests accessory-tracking authorization. Safe to call from
// anywhere, any number of times.
void Q3E_Sense_Start(void);

// Buttons and sticks only, no ARKit — the path the flat modes and the menus take,
// none of which have a compositor frame, an alignment or a pose to speak of. A
// menu does not care where your hand is.
//
// It ALSO folds this sample into the shared edge accumulator (see
// Q3E_Sense_TakeEdges), so the one detector stays fed in the modes where no
// compositor loop is running. Returns how many hands answered, so a caller can
// drop its own held state rather than latch a phantom.
int Q3E_Sense_UISample(unsigned *btn, float *stick);

// THE ONE EDGE DETECTOR (charter D5). Edges are computed by whichever POLL ran —
// Q3E_Sense_Poll on the compositor thread in VR, Q3E_Sense_UISample on the
// engine thread everywhere else — and accumulated under this file's own lock, so
// a tap that begins and ends between two consumer frames is never lost and never
// counted twice. Draining is what clears them: one physical press produces
// exactly one press edge, whatever rate either loop runs at.
//
// `level` receives the buttons currently down. Returns how many hands answered.
// `stick` receives (leftX, leftY, rightX, rightY) from the same poll the
// levels came from, so a consumer never mixes a stick from one instant with
// a button from another.
int  Q3E_Sense_TakeEdges(unsigned down[2], unsigned up[2], unsigned level[2], float stick[4]);
// Forget every pending edge and treat whatever is held right now as the new
// baseline. Called by a consumer when the input CONTEXT changes (gameplay <->
// menu, VR entry/exit): a trigger held across that boundary must not read as a
// fresh press on the other side, and must not fire a release nobody made.
void Q3E_Sense_RebaseEdges(void);
// Read the level and sticks WITHOUT draining the edges. The dumps need the
// current state; draining it there would eat presses the game never saw.
int  Q3E_Sense_PeekLevel(unsigned level[2], float stick[4]);

// Short burst on one hand. Ignored if that hand has no haptics engine.
// `why` names the pulse in the diagnostics, so a device round can tell
// "never fired" from "fired and was too weak to feel".
void Q3E_Sense_Haptic(int hand, float strength, float duration, const char *why);
// The name the input layer calls it by, with the Controller Haptics setting in
// front of it. Kept as a thin forwarder so the rest of the port never learns
// about GameController.
void Q3E_VR_Haptic(int hand, float strength, float duration, const char *why);

// The pad layer's filter (charter D5 / guide 12.6). Non-zero when this
// GCController is a SPATIAL-category device, which is ours; every ordinary
// gamepad answers 0, which is the whole safety property. Takes the controller as
// an opaque pointer so ios_input.m does not have to bridge a type across the
// visionOS-only boundary.
int Q3E_Sense_ShouldIgnorePad(const void *controller);
// Is a Sense pair (or an injected one) driving right now? The flat-mode merge
// asks before it zeroes a real pad's axes.
int Q3E_Sense_Connected(void);

// Settings status rows / diagnostics (the no-console-only rule).
const char *Q3E_Sense_StatusControllers(void); // what enumerated, and as what
const char *Q3E_Sense_StatusTracking(void);    // auth, loads, anchors, L/R
const char *Q3E_Sense_InventoryText(void);     // the full element inventory

// --- simulator coverage -----------------------------------------------------
// The Vision Pro simulator has no controllers at all, so every consumer of a
// hand — aim, the weapon, the marker, movement rotation, snap turn, the menus —
// would be untestable without injection. Injected hands enter at the SAME
// boundary a real anchor does (Q3E_Sense_Poll's output), in the same tracking
// space, so the sim exercises the real transform chain and the real input code,
// not a parallel one.
void Q3E_Sense_SetSynthHand(int hand, int on, float yaw, float pitch, float roll,
                            float x, float y, float z);
void Q3E_Sense_SetSynthButtons(int hand, unsigned buttons);
void Q3E_Sense_SetSynthStick(int hand, float x, float y);
int  Q3E_Sense_SynthActive(void);
void Q3E_Sense_SynthDescribe(char *buf, int n);

#ifdef __cplusplus
}
#endif
