// Q3EVR.m — the visionOS VR compositor loop.
//
// The 3D panel mode (Q3EImmersive.m) lets the compositor free-run and sample
// whatever the engine last drew. VR cannot: if the pose the engine rendered with
// is not the pose the compositor reprojects against, the world shakes with head
// sway. So this loop and the engine thread meet at a rendezvous — the compositor
// publishes both eyes' pose and projection with a monotonic frame id, the engine
// renders exactly those matrices and releases the id, and the compositor
// presents the pair it asked for or re-presents the previous pair against the
// anchor THAT pair was rendered with.
//
// Shape of one frame (the two failure points are marked; both invalidate the
// frame object, and calling anything on an invalidated frame aborts the app):
//
//   frame    = cp_layer_renderer_query_next_frame()
//   timing   = cp_frame_predict_timing()                 // MAY FAIL
//   start_update / end_update
//   cp_time_wait_until(optimal_input_time)
//   start_submission
//   drawable = cp_frame_query_drawable()                 // MAY FAIL
//     device anchor at PRESENTATION time
//     compose both eyes -> publish -> wait for the engine to render it
//     per-view blit of colour AND depth -> encode_present
//   end_submission

#import <CompositorServices/CompositorServices.h>
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <simd/simd.h>
#import <pthread.h>
#import "Q3EBlackBox.h"
#import "Q3EVR.h"
#import "Q3ESense.h"

// --- engine bridge ----------------------------------------------------------
extern void *VK_Get3DColorMTLTexture(void);
extern void *VK_Get3DEyeMTLTexture(int idx);
extern void *VK_Get3DEyeDepthMTLTexture(int idx);
extern int   VK_Get3DPairs(void);
extern int   VK_Get3DDepthCopies(void);
extern int   VK_Get3DDepthLive(void);
extern void *VK_GetVRUIMTLTexture(void);
extern int   VK_GetVRUIFrames(void);
extern void  VK_SetVRUIRedirect(int on);
extern int   VK_GetVRUIRedirect(void);
extern void  VK_GetGammaOverbright(float *invGamma, float *obScale);
extern void  VK_GetVREdgeNDC(int eye, float *out4);
extern void  VK_SetVRActive(int on);
extern int   VK_GetVRActive(void);
extern void  VK_SetVRZNear(float z);
extern void  VK_SetVREye(int eye, const float offset[3], const float axis[9], const float tangents[4]);
// Overlay patch 0016: the hand pose the viewmodel re-base rides on, in exactly
// the frame VK_SetVREye publishes the eyes in — one composition function serves
// both, so the gun and the eyes can never disagree about where the body is.
extern void  VK_SetVRHand(int hand, int valid, const float offset[3], const float axis[9]);
extern void  VK_SetVRGun(int aimHand, float scale, const float grip[3], const float gripAngles[3]);
// cl_input.c (overlay patch 0016): one frame's amnesty for the pitch wrap-clamp
// when the aim moves between the head and a hand.
extern int   cl_vr_aim_source_changed;
extern void  S_SetVRListenerAxis(int active, const float axis[9]);
extern void  VK_WaitLastFrameGPU(void);
extern volatile int q3e_render_gen;     // ios_glue.c — bumped around every vid_restart
extern volatile int q3e_render_live;    // ios_glue.c — 1 between renderer init and teardown
extern int   Q3E_VR_EngineRenderWidth(void);
extern int   Q3E_VR_EngineRenderHeight(void);
extern void  Q3E_Frame(void);

// --- rendezvous -------------------------------------------------------------
// One mutex, one condvar, one monotonic id. Nothing on this path is smoothed:
// damping belongs in the base placement, never in the submitted anchor.
typedef struct {
    float offset[2][3];      // body-frame eye offset, game units
    float axis[2][9];        // body-frame eye basis, Q3 convention, row-major
    float tangents[2][4];    // left, right, bottom, top
    float listener[9];       // head basis for the sound listener
    float znear;             // game units
    // R2.1 fix 8: the head's yaw/pitch, carried INSIDE the mutex-protected
    // pair rather than as free globals the compositor thread wrote directly
    // and the engine thread read directly with no lock between them. That was
    // a formal data race — on the engine's 20 ms timeout path, exactly when
    // the compositor is stalled mid-frame, the engine could read a yaw from
    // one frame's computation and a pitch from the next (or a torn single
    // value), a one-frame shear CL_VRApplyHeadAim has no way to detect. Now
    // they ride the SAME atomic snapshot every other per-eye field already
    // does.
    float headYawDeg;
    float headPitchDeg;
    // R3: the hands ride the SAME atomic snapshot, for the same reason — the
    // aim, the viewmodel and the eyes must all describe one instant, and a hand
    // read a frame apart from the eye it is drawn against is a gun that swims.
    int   handPosed[2], handHeld[2], handPresent[2];
    float handYawDeg[2], handPitchDeg[2];   // BASE frame, ARKit convention
    float handOffset[2][3];                 // body frame, game units (fwd,left,up)
    float handAxis[2][9];                   // body frame, Q3 convention, row-major
    // The aim the ENGINE will write into cl.viewangles from this snapshot, and
    // the source it came from. Decided HERE, on the compositor, because the same
    // number also has to come out of the eye pose below (`yawRemove`): deciding
    // it once and using it twice is what makes the render and the aim agree by
    // construction instead of by two pieces of arithmetic staying in step.
    float aimYawDeg, aimPitchDeg;
    int   aimSource;
} q3e_vr_pose_t;

static pthread_mutex_t q3e_vr_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  q3e_vr_cv  = PTHREAD_COND_INITIALIZER;
static q3e_vr_pose_t   q3e_vr_pub;         // guarded by q3e_vr_mtx
static long q3e_vr_pubId = 0;              // published by the compositor
static long q3e_vr_renderedId = 0;         // released by the engine
static long q3e_vr_takenId = 0;            // id the engine is rendering now
static volatile int q3e_vr_rendezvousLive = 0;

static const long kEngineWaitNs = 20 * NSEC_PER_MSEC;   // engine -> pose
static const long kShellWaitNs  = 14 * NSEC_PER_MSEC;   // shell  -> rendered

// RELATIVE waits, deliberately. pthread_cond_timedwait takes an absolute
// CLOCK_REALTIME deadline, and a wall-clock step (NTP, a timezone-driven
// adjustment, the user changing the clock) turns a 14 ms deadline into a wait of
// arbitrary length or none at all. Apple does not implement
// pthread_condattr_setclock, but it does provide the relative form, which is
// monotonic by construction.
static void q3e_vr_reltime(struct timespec *ts, long ns) {
    ts->tv_sec  = ns / 1000000000L;
    ts->tv_nsec = ns % 1000000000L;
}

// Publish this frame's pair. Returns its id.
static long q3e_vr_publish(const q3e_vr_pose_t *pose) {
    long poseId;
    pthread_mutex_lock(&q3e_vr_mtx);
    q3e_vr_pub = *pose;
    poseId = ++q3e_vr_pubId;
    q3e_vrPubId = poseId;
    pthread_cond_broadcast(&q3e_vr_cv);
    pthread_mutex_unlock(&q3e_vr_mtx);
    return poseId;
}

// Wait for the engine to have rendered `id`. Returns 1 on success, 0 on timeout
// — on timeout the caller re-presents the PREVIOUS pair against the anchor that
// pair was rendered with. A dropped frame then costs latency, never a jolt.
static int q3e_vr_wait_rendered(long wantId) {
    int ok = 1;
    struct timespec ts;
    q3e_vr_reltime(&ts, kShellWaitNs);
    pthread_mutex_lock(&q3e_vr_mtx);
    while (q3e_vr_renderedId < wantId && q3e_vr_rendezvousLive) {
        if (pthread_cond_timedwait_relative_np(&q3e_vr_cv, &q3e_vr_mtx, &ts) != 0) {
            ok = (q3e_vr_renderedId >= wantId);
            break;
        }
    }
    if (!q3e_vr_rendezvousLive) ok = 0;
    pthread_mutex_unlock(&q3e_vr_mtx);
    return ok;
}

// Engine side: take the freshest pair (waiting up to 20 ms for a new one) and
// push it into the engine. On timeout the previous pair is used again — better
// to render a repeat than to stall the game loop.
static void q3e_vr_engine_acquire(void) {
    q3e_vr_pose_t pose;
    long poseId;
    struct timespec ts;
    q3e_vr_reltime(&ts, kEngineWaitNs);
    pthread_mutex_lock(&q3e_vr_mtx);
    while (q3e_vr_pubId <= q3e_vr_takenId && q3e_vr_rendezvousLive) {
        if (pthread_cond_timedwait_relative_np(&q3e_vr_cv, &q3e_vr_mtx, &ts) != 0) {
            q3e_vrEngineTimeouts++;
            break;
        }
    }
    pose = q3e_vr_pub;               // private copy under the lock: a render can
    poseId = q3e_vr_pubId;           // never read a pair mid-rewrite
    q3e_vr_takenId = poseId;
    pthread_mutex_unlock(&q3e_vr_mtx);

    VK_SetVRZNear(pose.znear);
    VK_SetVREye(0, pose.offset[0], pose.axis[0], pose.tangents[0]);
    VK_SetVREye(1, pose.offset[1], pose.axis[1], pose.tangents[1]);
    S_SetVRListenerAxis(1, pose.listener);
    // R2.1 fix 8: q3e_vrHeadYaw/q3e_vrHeadPitch (the C globals
    // Q3E_VR_PublishHeadAim/PublishMoveBasis read on THIS thread, every
    // engine frame) are now written EXCLUSIVELY here, from the snapshot this
    // function just took under the lock — the compositor thread no longer
    // touches them at all (it uses its own frame-local variables for the
    // same computation; see the per-eye loop below). One writer, one reader,
    // both the engine thread: no race, even on the timeout path, where
    // `pose` is simply the previous frame's already-consistent pair.
    q3e_vrHeadYaw = pose.headYawDeg;
    q3e_vrHeadPitch = pose.headPitchDeg;
    // R3: the hands come out of the SAME snapshot, on the same thread, for the
    // same reason. The renderer gets its copy here too, beside the eyes, so the
    // viewmodel's frame and the eye frames are the pair the compositor built and
    // never one of each from two frames.
    for (int h = 0; h < 2; h++) {
        q3e_vrHandYaw[h] = pose.handYawDeg[h];
        q3e_vrHandPitch[h] = pose.handPitchDeg[h];
        VK_SetVRHand(h, pose.handPosed[h], pose.handOffset[h], pose.handAxis[h]);
    }
    VK_SetVRGun((q3e_vrAimHand == Q3E_VR_HAND_LEFT) ? 0 : 1,
                q3e_vrGunScale, q3e_vrGrip, q3e_vrGripAngles);
    q3e_vrAimYaw = pose.aimYawDeg;
    q3e_vrAimPitch = pose.aimPitchDeg;
    if (pose.aimSource != q3e_vrAimSource) {
        q3e_vrAimSource = pose.aimSource;
        q3e_vrAimSourceSwaps++;
        // The pitch write on the swap frame is an intentional absolute jump from
        // one source's pitch to the other's, which CL_CreateCmd's wrap-clamp
        // cannot tell from a tracking spike on its own. Told, for one frame,
        // through the flag the first-activation case already uses.
        cl_vr_aim_source_changed = 1;
        Q3E_BlackBox_Pin("vr: aim source -> %s (hand tracked L%d R%d, swap #%d)",
                         pose.aimSource == Q3E_VRAIM_HAND ? "AIM HAND"
                             : pose.aimSource == Q3E_VRAIM_PAD ? "GAMEPAD stick"
                             : "head (Convenience)",
                         pose.handPosed[0], pose.handPosed[1], q3e_vrAimSourceSwaps);
    }
}

static void q3e_vr_engine_release(void) {
    // The compositor copies the per-eye snapshots on ITS queue, which is not
    // synchronised with the engine's. "Com_Frame returned" only means the work
    // was submitted, so releasing here without waiting lets the copy read images
    // the GPU is still writing: torn eyes, or colour and depth from two
    // different frames. The wait mostly replaces idle time the next frame's
    // begin_frame would have spent on the same fence.
    VK_WaitLastFrameGPU();
    pthread_mutex_lock(&q3e_vr_mtx);
    q3e_vr_renderedId = q3e_vr_takenId;
    q3e_vrRenderedId = q3e_vr_renderedId;
    pthread_cond_broadcast(&q3e_vr_cv);
    pthread_mutex_unlock(&q3e_vr_mtx);
}

// --- the engine thread ------------------------------------------------------
// While in VR the main-thread CADisplayLink is PAUSED and this thread is the
// only caller of Q3E_Frame. It is a dedicated thread rather than a tick inside
// the compositor loop because a blocking map load inside Com_Frame would starve
// compositor submissions for seconds; with the rendezvous, a load costs latency
// and the compositor keeps presenting.
static NSThread *q3e_vr_engineThread = nil;
static volatile int q3e_vr_engineStop = 0;
static volatile int q3e_vr_engineRunning = 0;

static void q3e_vr_engine_loop(void) {
    Q3E_BlackBox_Pin("vr: engine thread started (owner=vr)");
    q3e_vr_engineRunning = 1;
    while (!q3e_vr_engineStop) {
        @autoreleasepool {
            q3e_vr_engine_acquire();
            // Sampled HERE — on the engine thread (reading client state from the
            // compositor thread would be a race) and BEFORE the frame, because
            // this one sample now decides two things that have to agree: whether
            // the frame RENDERS its 2D into the eyes or onto the UI layer, and
            // whether the compositor PRESENTS that frame as the world. Taking
            // them from separate samples is how a frame gets rendered one way and
            // shown the other.
            Q3E_VR_SampleClientState();
            // R4.4: VR's two cvar overrides are an INVARIANT of the mode, not a
            // one-shot at entry — a `game_restart` inside VR unsets both (its
            // Cvar_Restart drops user- and VM-created cvars) and the eye path
            // dies silently. Re-asserted here, on the engine thread, at the top
            // of the frame after the one that ran the restart.
            Q3E_VR_RearmCvarInvariant();
            // The head basis and the calibrated height, published from the pose
            // this frame is about to be rendered with.
            Q3E_VR_PublishMoveBasis();
            Q3E_VR_PublishHeadAim();
            Q3E_VR_PublishHeight();
            Q3E_Frame();
            q3e_vr_engine_release();
        }
    }
    q3e_vr_engineRunning = 0;
    Q3E_BlackBox_Pin("vr: engine thread ended");
}

void Q3E_VR_StartEngineThread(void) {
    if (q3e_vr_engineThread) {
        Q3E_BlackBox_Pin("vr: START IGNORED — an engine thread already exists "
                         "(running=%d). Two engine owners is the failure this guards.",
                         q3e_vr_engineRunning);
        return;
    }
    pthread_mutex_lock(&q3e_vr_mtx);
    q3e_vr_rendezvousLive = 1;
    q3e_vr_engineStop = 0;
    pthread_mutex_unlock(&q3e_vr_mtx);
    q3e_frame_owner = Q3E_FRAME_OWNER_VR;
    Q3E_BlackBox_Pin("vr: frame owner -> VR engine thread");
    q3e_vr_engineThread = [[NSThread alloc] initWithBlock:^{ q3e_vr_engine_loop(); }];
    q3e_vr_engineThread.name = @"Q3E-VR-Engine";
    q3e_vr_engineThread.stackSize = 4 << 20;
    q3e_vr_engineThread.qualityOfService = NSQualityOfServiceUserInteractive;
    [q3e_vr_engineThread start];
}

// Stopping is a REQUEST plus a POLL, never a join.
//
// The `q3evr 0` and `stereo` console commands are executed by the engine thread
// itself (they are drained inside Q3E_Frame), so a stop that waits inline for
// that thread to finish is a thread waiting for itself: the wait is guaranteed
// to time out. Treating that timeout as success is what makes it dangerous — it
// hands the display link back while the engine thread is still inside
// Com_Frame, and the app then has two engine owners.
//
// So: the request is safe from any thread, the poll happens on the main thread
// between runloop turns, and a stop that does not complete is a FAILURE that
// keeps the owner where it is.
void Q3E_VR_RequestEngineStop(void) {
    if (!q3e_vr_engineThread) return;
    q3e_vr_engineStop = 1;
    pthread_mutex_lock(&q3e_vr_mtx);
    q3e_vr_rendezvousLive = 0;
    pthread_cond_broadcast(&q3e_vr_cv);   // unconditionally: never leave either
    pthread_mutex_unlock(&q3e_vr_mtx);    // side of the rendezvous blocked
}

// Call ONLY once Q3E_VR_EngineThreadRunning() has gone to 0, and only on main.
void Q3E_VR_FinishEngineStop(void) {
    if (q3e_vr_engineRunning) {
        Q3E_BlackBox_Pin("vr: FinishEngineStop called while the engine thread is STILL "
                         "RUNNING — refusing to hand the frame back");
        return;
    }
    q3e_vr_engineThread = nil;
    q3e_frame_owner = Q3E_FRAME_OWNER_LINK;
    S_SetVRListenerAxis(0, NULL);
    Q3E_BlackBox_Pin("vr: engine thread stopped, frame owner -> display link");
}

int Q3E_VR_EngineThreadRunning(void) { return q3e_vr_engineRunning; }
int Q3E_VR_OnEngineThread(void) {
    return (q3e_vr_engineThread != nil && [NSThread currentThread] == q3e_vr_engineThread) ? 1 : 0;
}

// --- alignment --------------------------------------------------------------
// ARKit tracking space is Y-up right-handed metres; Quake III is Z-up
// right-handed units. The bridge is one map, applied to vectors already
// expressed in the recentred base frame:
//
//     Q3 (forward, left, up) = ( -v.z, -v.x, v.y )
//
// The base frame is captured ONCE per entry (position and yaw only — pitch and
// roll belong to the head) and is what recentre re-captures.
//
// The height baseline is the player's standing eye height, captured once and
// kept across sessions; the camera sits at the game's own eye height plus the
// difference between the two, cut to whatever fits under the ceiling. See
// Q3E_VR_PublishHeight and CL_VRHeightClamp.
static NSString *const kQ3EVRHeightKey = @"Q3EVRHeightBaselineMetres";
static NSString *const kQ3EVRTrimKey   = @"Q3EVRHeightTrimMetres";

static bool          q3e_vr_haveBase = false;
static simd_float3   q3e_vr_basePos = { 0.0f, 0.0f, 0.0f };
static float         q3e_vr_baseYaw = 0.0f;

void Q3E_VR_Recenter(void) {
    q3e_vr_haveBase = false;
    // R4.6: the stick aim is an angle in the BASE frame, and a recentre replaces
    // that frame. Keeping the old number would put the crosshair wherever the
    // old base happened to map to; forgetting it starts the next frame's aim at
    // the gaze, which is what recentring means for every other pose here.
    Q3E_VR_PadAimReseed();
    Q3E_BlackBox_Pin("vr: recentre requested — base will be re-captured");
}

static simd_float4x4 q3e_vr_rotY(float radians) {
    simd_float4x4 m = matrix_identity_float4x4;
    float c = cosf(radians), s = sinf(radians);
    m.columns[0] = simd_make_float4(c, 0.0f, -s, 0.0f);
    m.columns[2] = simd_make_float4(s, 0.0f,  c, 0.0f);
    return m;
}

static simd_float4x4 q3e_vr_rotX(float radians) {
    simd_float4x4 m = matrix_identity_float4x4;
    float c = cosf(radians), s = sinf(radians);
    m.columns[1] = simd_make_float4(0.0f, c, s, 0.0f);
    m.columns[2] = simd_make_float4(0.0f, -s, c, 0.0f);
    return m;
}

static simd_float4x4 q3e_vr_translate(simd_float3 t) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = simd_make_float4(t.x, t.y, t.z, 1.0f);
    return m;
}

// ARKit vector -> Q3 body-frame components.
static void q3e_vr_map_axis(simd_float3 v, float *out) {
    out[0] = -v.z;   // forward
    out[1] = -v.x;   // left
    out[2] =  v.y;   // up
}

// --- Metal ------------------------------------------------------------------
// Deliberately self-contained rather than shared with Q3EImmersive.m: the panel
// path is SHIPPED code and VR must not be able to regress it. The cost is one
// small duplicated shader.
static id<MTLRenderPipelineState> q3e_vr_eyePipeline = nil;      // colour + depth
static id<MTLRenderPipelineState> q3e_vr_eyePipelineNoDepth = nil;
// R2 item 4: independent region quads (statusbar/chat/message/crosshair,
// alpha-blended) and the fallback/scoreboard quad (same blend, with the
// exclusion-masking fragment) — replace the single R1 UI quad. R2 item 5: the
// letterboxed menu panel (opaque) replaces the R1 content-aspect panel quad.
static id<MTLRenderPipelineState> q3e_vr_regionPipeline = nil;
static id<MTLRenderPipelineState> q3e_vr_fallbackPipeline = nil;
static id<MTLRenderPipelineState> q3e_vr_letterboxPipeline = nil;
static id<MTLDepthStencilState>   q3e_vr_depthWrite = nil;
// R2.1 fix 11 fault injection: `q3evruifallbackkill 1` makes the render loop
// treat the fallback/scoreboard pipeline as missing (simulating a shader
// compile failure this session) without actually breaking the shader, so the
// degrade path below can be proven to still show content.
static int q3e_vr_forceFallbackNil = 0;
void Q3E_DebugKillFallbackPipeline(int on) {
    q3e_vr_forceFallbackNil = on ? 1 : 0;
    Q3E_BlackBox_Pin("vr: fallback-pipeline-kill hook %s", on ? "ARMED" : "off");
}

static NSString *const kQ3EVRShader =
@"#include <metal_stdlib>\n"
 "using namespace metal;\n"
 "struct VOut { float4 pos [[position]]; float2 uv; };\n"
 "struct FOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };\n"
 // Fullscreen quad in clip space for the eye blit; mvp'd quad for the panel.
 "vertex VOut q3evr_vs_full(uint vid [[vertex_id]]) {\n"
 "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
 "  VOut o; o.pos = float4(p[vid], 0.0, 1.0);\n"
 "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
 "  return o;\n"
 "}\n"
 "vertex VOut q3evr_vs_quad(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
 "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
 "  VOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
 "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
 "  return o;\n"
 "}\n"
 // The eye blit writes REAL depth through: the compositor reprojects against
 // depth, and a frame that hands over colour alone is reprojected as if it were
 // flat. The engine's projection is reverse-Z with an infinite far plane and a
 // near of 0.1 m x worldScale, which is exactly the compositor's own — so the
 // value passes through unconverted.
// params = (srgbDecode, 1/r_gamma, overbrightScale). The engine's own gamma pass
// — pow(colour, 1/r_gamma) * (1 << overbrightBits) — lives in the FBO-to-swapchain
// blit, and that blit NEVER RUNS while the engine renders off-screen for a
// compositor. So everything sampled straight out of the FBO has to reproduce it,
// or the player gets a picture that is missing their brightness setting AND is
// darker than the flat window by the whole overbright factor, which is 2x by
// default. Overbright is not optional decoration: the renderer deliberately
// scales vertex lighting DOWN by 1/overbright (tr.identityLight) on the way in,
// expecting this pass to scale it back up.
//
// Order is the engine's order: brightness on the display-encoded values first,
// then the sRGB linearisation the drawable's format asks for. Doing it the other
// way round applies the curve to linear light and washes the image out.
 "static inline float3 q3evr_grade(float3 c, constant float3& params) {\n"
 "  if (params.y != 1.0) c = pow(c, params.y);\n"
 "  c *= params.z;\n"
 "  if (params.x > 0.5) c = pow(c, 2.2);\n"
 "  return c;\n"
 "}\n"
// R3.1 item 3 — THE SKY. `floor` is the smallest depth this blit will hand the
// compositor for a pixel that has colour, and it is the whole fix.
//
// The engine draws sky through DEPTH_RANGE_ONE, which under USE_REVERSED_DEPTH
// is minDepth = maxDepth = 0.0 — every sky pixel writes depth EXACTLY zero. The
// drawable's depth attachment is cleared to exactly zero as well, because in
// reverse-Z zero is infinity and infinity is what "nothing was rendered here"
// means. So the sky arrives at the compositor byte-identical to empty space,
// and a compositor that reprojects against depth has nothing to reproject:
// those pixels come back black.
//
// That is the entire device symptom, and it explains every measurement taken
// against it. Emission was always healthy (the device dump's 61-69 triangles an
// eye); both bypass toggles were no-ops because the kill happens long after
// geometry; only SKY is affected because sky is the only thing drawn at
// infinity; and the correctly-rendered rectangle is the HUD panel's footprint
// and scales with its slider because the region and fallback quads write REAL
// depth at 1.75 m across their whole quad — including where their alpha is zero
// — which locally gives the compositor a depth it can work with. The simulator
// could never reproduce it: there is no reprojection there, and the suite reads
// the drawable's colour directly.
//
// Clamping the passed-through depth up to a small positive value makes the sky
// "very far away" instead of "not there". At the engine's 0.1 m near plane a
// floor of 1/8192 puts it about 800 m out — past anything a Quake III map
// contains, so nothing sorts differently, and finite, so the compositor treats
// it as picture. max() means no pixel that already had a depth is touched.
// R4.3 item 2 — SHARPEN, the donor's row, as AMD's contrast-adaptive sharpening.
// `sh` is (amount 0..1, 1/srcWidth, 1/srcHeight, unused).
//
// CAS reconstructs a pixel as (c + w*(l+r+u+d)) / (1 + 4w) with w negative, and
// the donor's own bug catalogue (#23) records what happens when the amount is
// let out past where that denominator stays sane: 100% looked measurably LESS
// sharp than 50%, because AMD's sharpness range is a stability bound and not a
// taste range. So the amount does two bounded things at once — it interpolates w
// across AMD's own [-1/8, -1/5] and it cross-fades the result against the
// untouched pixel — which makes 0 a bit-exact pass-through (the shipped default:
// every build before this one drew exactly this) and 1 the strongest setting
// that is still inside the math. There is no value of the row at which the
// denominator can reach zero.
 "static inline float3 q3evr_sharpen(texture2d<float> tex, sampler s, float2 uv,\n"
 "                                   float3 c, constant float4& sh) {\n"
 "  if (sh.x <= 0.0) return c;\n"
 "  float3 l = tex.sample(s, uv + float2(-sh.y, 0.0)).rgb;\n"
 "  float3 r = tex.sample(s, uv + float2( sh.y, 0.0)).rgb;\n"
 "  float3 u = tex.sample(s, uv + float2(0.0, -sh.z)).rgb;\n"
 "  float3 d = tex.sample(s, uv + float2(0.0,  sh.z)).rgb;\n"
 "  float3 mn = min(min(min(l, r), min(u, d)), c);\n"
 "  float3 mx = max(max(max(l, r), max(u, d)), c);\n"
 "  float3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-5)));\n"
 "  float3 w = amp * mix(-0.125, -0.2, sh.x);\n"
 "  float3 sharp = (c + w * (l + r + u + d)) / (1.0 + 4.0 * w);\n"
 "  return mix(c, clamp(sharp, 0.0, 1.0), sh.x);\n"
 "}\n"
 "fragment FOut q3evr_fs_eye(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
 "                           depth2d<float> dep [[texture(1)]],\n"
 "                           constant float3& params [[buffer(0)]],\n"
 "                           constant float& depthFloor [[buffer(1)]],\n"
 "                           constant float4& sharpen [[buffer(2)]]) {\n"
 "  constexpr sampler s(filter::linear);\n"
 "  constexpr sampler ds(filter::nearest);\n"
 "  FOut o;\n"
 "  float4 c = tex.sample(s, in.uv);\n"
 // Sharpen operates on the DISPLAY-encoded pixels the engine produced, before
 // the grade — the same place the donor's blit does it, and the only place
 // where a neighbourhood comparison means what CAS assumes it means. The depth
 // floor below is untouched by any of it: colour and depth are two independent
 // outputs of this one shader, and the sky fix lives entirely in the second.
 "  float3 rgb = q3evr_sharpen(tex, s, in.uv, c.rgb, sharpen);\n"
 "  o.color = float4(q3evr_grade(rgb, params), 1.0);\n"
 "  o.depth = max(dep.sample(ds, in.uv), depthFloor);\n"
 "  return o;\n"
 "}\n"
 "fragment float4 q3evr_fs_plain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
 "                               constant float3& params [[buffer(0)]]) {\n"
 "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16));\n"
 "  float4 c = tex.sample(s, in.uv);\n"
 "  return float4(q3evr_grade(c.rgb, params), 1.0);\n"
 "}\n"
 // The head-locked UI layer: the engine's 2D stream on a transparent ground.
 // Alpha is REAL here — the world has to show around and through the HUD — and
 // the RGB arrives premultiplied, because the engine blended it over transparent
 // black. So the composite is the premultiplied form (One, 1-SrcAlpha) and the
 // grade applies to the premultiplied value: exact wherever the source was
 // opaque, which is every pixel of a HUD glyph that is not its own antialiased
 // edge.
 "fragment float4 q3evr_fs_ui(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
 "                            constant float3& params [[buffer(0)]]) {\n"
 "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16));\n"
 "  float4 c = tex.sample(s, in.uv);\n"
 "  return float4(q3evr_grade(c.rgb, params), c.a);\n"
 "}\n"
 // --- R2 item 4: independent 2D-layer region quads ---------------------------
 // One texture (the same q3e_vr_uiCopy the old single quad sampled), many
 // quads: each region quad sizes and places itself independently, but the UV
 // it samples is a SUB-RECT of the one shared texture — a virtual-640x480
 // rect turned into a 0..1 UV rect shell-side (SCR_AdjustFrom640 is a uniform
 // stretch across the whole texture, so a virtual rect maps to a UV rect with
 // no further correction needed). uv = (u0,v0,u1,v1).
 "vertex VOut q3evr_vs_region(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]],\n"
 "                             constant float4& uv [[buffer(1)]]) {\n"
 "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
 "  VOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
 "  float2 t = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
 "  o.uv = mix(uv.xy, uv.zw, t);\n"
 "  return o;\n"
 "}\n"
 // The fallback/scoreboard quad shows the FULL texture (mods and any HUD
 // content this round does not know the shape of must never lose their UI —
 // charter D6) MINUS the rectangles the dedicated region quads already show
 // bigger and repositioned elsewhere, so a player is not reading the same
 // crosshair or statusbar twice at two sizes. Up to 4 exclusion rects in the
 // SAME 0..1 UV space; alpha 0 inside any of them lets the world (or nothing,
 // over the panel) show through instead.
 "fragment float4 q3evr_fs_ui_excl(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
 "                                  constant float3& params [[buffer(0)]],\n"
 "                                  constant float4* excl [[buffer(1)]],\n"
 "                                  constant int& nExcl [[buffer(2)]]) {\n"
 "  for (int i = 0; i < nExcl; i++) {\n"
 "    float4 r = excl[i];\n"
 "    if (in.uv.x >= r.x && in.uv.x <= r.z && in.uv.y >= r.y && in.uv.y <= r.w) return float4(0.0);\n"
 "  }\n"
 "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16));\n"
 "  float4 c = tex.sample(s, in.uv);\n"
 "  return float4(q3evr_grade(c.rgb, params), c.a);\n"
 "}\n"
 // --- R2 item 5: the menu panel, letterboxed inside a widescreen frame -------
 // `mvp` carries a WIDE (16:9-ish) frame; `fit` (<=1 on whichever axis the
 // near-square source composite is relatively narrower on) shrinks the drawn
 // rectangle to the texture's OWN aspect before the frame's transform is
 // applied, so the whole composite shows undistorted, centred, with empty
 // margin rather than being stretched to fill a shape it was never drawn for.
 // UV stays full 0..1 — this is geometry, not sampling.
 "vertex VOut q3evr_vs_letterbox(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]],\n"
 "                                constant float2& fit [[buffer(1)]]) {\n"
 "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
 "  VOut o; o.pos = mvp * float4(p[vid] * fit, 0.0, 1.0);\n"
 "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
 "  return o;\n"
 "}\n";

static bool q3e_vr_drawableLinear = false;

static void q3e_vr_build_pipelines(id<MTLDevice> dev, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt) {
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kQ3EVRShader options:nil error:&err];
    if (!lib) {
        Q3E_BlackBox_Pin("vr: SHADER COMPILE FAILED: %s", err.localizedDescription.UTF8String ?: "?");
        return;
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"q3evr_vs_full"];
    pd.fragmentFunction = [lib newFunctionWithName:@"q3evr_fs_eye"];
    pd.colorAttachments[0].pixelFormat = colorFmt;
    pd.depthAttachmentPixelFormat = depthFmt;
    q3e_vr_eyePipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!q3e_vr_eyePipeline)
        Q3E_BlackBox_Pin("vr: eye+depth pipeline FAILED: %s — depth handoff is OFF this session: %s",
                         err.localizedDescription.UTF8String ?: "?", "colour still presents");

    pd.fragmentFunction = [lib newFunctionWithName:@"q3evr_fs_plain"];
    q3e_vr_eyePipelineNoDepth = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!q3e_vr_eyePipelineNoDepth)
        Q3E_BlackBox_Pin("vr: eye pipeline FAILED: %s", err.localizedDescription.UTF8String ?: "?");

    // R2 item 4: the head-locked 2D layer's region quads — real alpha,
    // premultiplied blending so the world shows through everywhere the source
    // stream did not draw (the engine blended its 2D over transparent black).
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.vertexFunction = [lib newFunctionWithName:@"q3evr_vs_region"];
    pd.fragmentFunction = [lib newFunctionWithName:@"q3evr_fs_ui"];
    q3e_vr_regionPipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!q3e_vr_regionPipeline)
        Q3E_BlackBox_Pin("vr: region pipeline FAILED: %s", err.localizedDescription.UTF8String ?: "?");

    // The fallback/scoreboard quad: same region UV machinery, exclusion-masked
    // fragment so it does not double-show what the dedicated quads already
    // draw bigger elsewhere.
    pd.fragmentFunction = [lib newFunctionWithName:@"q3evr_fs_ui_excl"];
    q3e_vr_fallbackPipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!q3e_vr_fallbackPipeline)
        Q3E_BlackBox_Pin("vr: fallback pipeline FAILED: %s", err.localizedDescription.UTF8String ?: "?");

    pd.colorAttachments[0].blendingEnabled = NO;

    // R2 item 5: the menu panel, letterboxed inside a widescreen frame — opaque,
    // like the plain panel pipeline it replaces for that draw.
    pd.vertexFunction = [lib newFunctionWithName:@"q3evr_vs_letterbox"];
    pd.fragmentFunction = [lib newFunctionWithName:@"q3evr_fs_plain"];
    q3e_vr_letterboxPipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!q3e_vr_letterboxPipeline)
        Q3E_BlackBox_Pin("vr: letterbox pipeline FAILED: %s", err.localizedDescription.UTF8String ?: "?");

    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.depthWriteEnabled = YES;
    q3e_vr_depthWrite = [dev newDepthStencilStateWithDescriptor:dd];

    q3e_vr_drawableLinear = (colorFmt == MTLPixelFormatBGRA8Unorm_sRGB ||
                             colorFmt == MTLPixelFormatRGBA8Unorm_sRGB ||
                             colorFmt == MTLPixelFormatRGBA16Float);
    Q3E_BlackBox_Pin("vr: pipelines built (colorFmt=%lu depthFmt=%lu drawableLinear=%d eyeDepth=%d)",
                     (unsigned long)colorFmt, (unsigned long)depthFmt,
                     (int)q3e_vr_drawableLinear, (int)(q3e_vr_eyePipeline != nil));
}

// --- per-eye copies ---------------------------------------------------------
// The engine overwrites its snapshot images on the next frame, so a presented
// pair is copied into persistent textures on this queue. Depth rides along, or
// the pair is colour of one frame and depth of another.
static id<MTLTexture> q3e_vr_eyeCopy[2]  = { nil, nil };
static id<MTLTexture> q3e_vr_depthCopy[2] = { nil, nil };
static id<MTLTexture> q3e_vr_panelCopy = nil;
static id<MTLTexture> q3e_vr_uiCopy = nil;     // the separated 2D stream
static int q3e_vr_lastUIFrames = -1;
static int q3e_vr_lastPairs = 0;
static int q3e_vr_restartSkips = 0;
static int q3e_vr_blindWorld = 0;   // WORLD frames presented with no eye copy to show
// Frames whose device anchor did NOT match the pose the presented imagery was
// rendered against. Counted rather than assumed: an anchor that disagrees with
// its frame by one frame of head motion is invisible while the head is still and
// is exactly the warp a player reports as swimming.
static int q3e_vr_staleAnchor = 0;
static int q3e_vr_uiCopies = 0;
int Q3E_VR_StaleAnchorFrames(void) { return q3e_vr_staleAnchor; }
int Q3E_VR_UICopies(void) { return q3e_vr_uiCopies; }

// Read by the FRAMENOW dump: both are properties that should be zero, and both
// are counted rather than assumed precisely because they are invisible when they
// happen (a skipped copy looks like a repeated frame, a blind world frame looks
// like a black screen).
int Q3E_VR_RestartSkips(void) { return q3e_vr_restartSkips; }
int Q3E_VR_BlindWorldFrames(void) { return q3e_vr_blindWorld; }

static id<MTLTexture> q3e_vr_ensure_copy(id<MTLTexture> src, id<MTLTexture> dst) {
    if (dst != nil && dst.width == src.width && dst.height == src.height &&
        dst.pixelFormat == src.pixelFormat)
        return dst;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:src.pixelFormat
        width:src.width height:src.height mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    return [src.device newTextureWithDescriptor:td];
}

// --- drawable contract ------------------------------------------------------
// STRUCTURAL is diffed and flagged on change; VOLATILE is dumped and NEVER
// diffed. Hashing everything into one fingerprint fires an alarm every frame,
// because the eye tracker refines the eye transform at the fifth decimal — and
// the spam then truncates the evidence the dump exists to preserve.
static NSString *q3e_vr_contractPrev = nil;

static void q3e_vr_dump_contract(cp_layer_renderer_t lr, cp_drawable_t drawable) {
    size_t views = cp_drawable_get_view_count(drawable);
    size_t texCount = cp_drawable_get_texture_count(drawable);
    size_t rateMaps = cp_drawable_get_rasterization_rate_map_count(drawable);
    id<MTLTexture> c0 = cp_drawable_get_color_texture(drawable, 0);
    id<MTLTexture> d0 = cp_drawable_get_depth_texture(drawable, 0);

    NSMutableString *structural = [NSMutableString string];
    [structural appendFormat:@"views=%zu textures=%zu rateMaps=%zu colorFmt=%lu depthFmt=%lu",
        views, texCount, rateMaps, (unsigned long)c0.pixelFormat, (unsigned long)d0.pixelFormat];
    for (size_t v = 0; v < views; v++) {
        cp_view_t view = cp_drawable_get_view(drawable, v);
        cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
        size_t texIdx = cp_view_texture_map_get_texture_index(tmap);
        size_t slice = cp_view_texture_map_get_slice_index(tmap);
        MTLViewport vp = cp_view_texture_map_get_viewport(tmap);
        id<MTLTexture> ct = cp_drawable_get_color_texture(drawable, texIdx);
        [structural appendFormat:@" | view%zu texIdx=%zu slice=%zu logical=%dx%dpx physical=%dx%dpx",
            v, texIdx, slice, (int)vp.width, (int)vp.height, (int)ct.width, (int)ct.height];
    }
    if (q3e_vr_contractPrev == nil) {
        Q3E_BlackBox_Pin("vr CONTRACT STRUCTURAL: %s", structural.UTF8String);
    } else if (![q3e_vr_contractPrev isEqualToString:structural]) {
        Q3E_BlackBox_Pin("vr CONTRACT STRUCTURAL *** CHANGED ***: %s", structural.UTF8String);
    }
    q3e_vr_contractPrev = [structural copy];

    for (size_t v = 0; v < views && v < 2; v++) {
        cp_view_t view = cp_drawable_get_view(drawable, v);
        simd_float4x4 dfe = cp_view_get_transform(view);
        Q3E_BlackBox_Pin("vr CONTRACT VOLATILE view%zu deviceFromEye_t=(%.4f,%.4f,%.4f)m (never diffed)",
                         v, dfe.columns[3].x, dfe.columns[3].y, dfe.columns[3].z);
    }
    (void)lr;
}

// --- render-size negotiation ------------------------------------------------
// Sized from the view's PHYSICAL colour texture, never its logical viewport:
// with foveation the viewport is the EXPANDED logical raster area that the rate
// map compresses into a much smaller texture, and sizing the engine from it asks
// for many times the pixels that exist. The blit still rasterises into the
// logical viewport with the rate map attached — that IS the foveation contract.
static volatile int q3e_vr_wantW = 0, q3e_vr_wantH = 0;
static volatile int q3e_vr_sizeRequested = 0;

// R2.3 fix 4 — THE MENU CROP, and why it was never a panel-geometry bug.
//
// Quake III's menus are drawn by the ui QVM, which is DATA: it ships inside
// pak0.pk3 and this project never forks it. Its `UI_AdjustFrom640` scales the
// virtual 640x480 layout by vidHeight/480 on BOTH axes (to keep the menu's own
// 4:3 proportions) and then adds a horizontal bias to re-centre it — but that
// bias is only computed for a screen WIDER than 4:3. On a screen NARROWER than
// 4:3 the bias is zero, so the menu is drawn 640*vidHeight/480 pixels wide from
// x = 0, and everything past vidWidth is simply clipped away. The pixels are
// never rendered, so nothing the compositor does downstream can bring them back.
//
// A visionOS per-eye target is nearly square (the device round's was about
// 2560x2480, aspect 1.03), so the stock menu lost the rightmost ~22% of itself:
// the level-select thumbnails cut in half, map names truncated mid-word. The
// simulator's drawable is wider than 4:3, which is exactly why the sim's
// panel-corner assertion could pass on a build the device showed cropped — that
// assertion measures the PANEL, and the panel was never the problem.
//
// So the extent itself takes a shape Quake III can draw into. The per-eye
// texture's aspect is free to choose: the projection maps the eye's frustum to
// NDC and the compositor stretches the whole texture over the whole viewport,
// so the mapping from frustum to viewport is identical whatever WxH sits in
// between — only the sampling density changes. The PIXEL BUDGET is preserved
// exactly (same area, 4:3 shape) rather than clamping one axis, so this costs
// no frame time in either direction; it trades about 12% of vertical sampling
// for about 13% of horizontal.
static void q3e_vr_fit_ui_aspect(int *w, int *h) {
    if (!w || !h || *w <= 0 || *h <= 0) return;
    if ((long)(*h) * 4 <= (long)(*w) * 3) return;    // already 4:3 or wider
    const double area = (double)(*w) * (double)(*h);
    int nh = (int)(sqrt(area * 3.0 / 4.0) + 0.5);
    int nw = (int)(nh * 4.0 / 3.0 + 0.5);
    if (nw < 64) nw = 64;
    if (nh < 48) nh = 48;
    *w = nw;
    *h = nh;
}

// R3.2 item 5 follow-up: the SCALE being in range does not make the EXTENT
// legal. The render-quality clamp bounds a multiplier (0.6..2.5x at the time,
// 1.0..2.0x since R3.3); what the
// renderer actually allocates is that multiplier times whatever per-eye
// drawable the compositor handed us, and the second number is not ours to
// choose. The simulator's drawable is 3840x2160 — far larger than the device's
// ~1920x1824 — so 2.5x asked for a 9600x5400 colour attachment, and
// vk_create_attachments walked straight into MTLTextureDescriptor validation
// and aborted the process inside vid_restart (1.85x, at 7104x3996, was fine).
// A clamped slider that kills the app is worse than one that does nothing.
//
// So the extent is capped too, at the smallest maximum any Metal device is
// documented to accept. Both axes are divided by the same factor, because the
// aspect above was chosen deliberately and a one-axis clamp would undo it; the
// result is simply less supersampling than was asked for, which is the honest
// answer when the drawable is already enormous. Nothing on the device reaches
// this — 2.5x there is 4800x4560 — so it costs the headset nothing.
//
// R3.3 narrows the multiplier to 1.0..2.0, which puts even the simulator's
// worst case (7680x4320) under the cap. The cap stays: it is a property of the
// TEXTURE, not of the slider, and the next round that widens the range or the
// next drawable that grows would find it missing rather than find it wrong.
#define Q3E_VR_MAX_EYE_DIM 8192
static void q3e_vr_cap_eye_extent(int *w, int *h) {
    if (!w || !h || *w <= 0 || *h <= 0) return;
    const int big = (*w > *h) ? *w : *h;
    if (big <= Q3E_VR_MAX_EYE_DIM) return;
    const double k = (double)Q3E_VR_MAX_EYE_DIM / (double)big;
    int nw = (int)(*w * k), nh = (int)(*h * k);
    if (nw < 64) nw = 64;
    if (nh < 48) nh = 48;
    // This runs in the per-frame compositor loop, so the line is pinned only
    // when the capped answer MOVES — otherwise one oversized setting would
    // push every other pinned line out of the box at ninety a second.
    static int lastW = -1, lastH = -1;
    if (nw != lastW || nh != lastH) {
        lastW = nw; lastH = nh;
        Q3E_BlackBox_Pin("vr: per-eye target %dx%d exceeds the %dpx texture limit — "
                         "capped to %dx%d (the scale was in range; the drawable is "
                         "what made it too big)", *w, *h, Q3E_VR_MAX_EYE_DIM, nw, nh);
    }
    *w = nw;
    *h = nh;
}

void Q3E_VR_RequestedRenderSize(int *w, int *h) {
    if (w) *w = q3e_vr_wantW;
    if (h) *h = q3e_vr_wantH;
}
int Q3E_VR_SizeRequested(void) { return q3e_vr_sizeRequested; }
void Q3E_VR_ClearSizeRequest(void) { q3e_vr_sizeRequested = 0; q3e_vr_wantW = q3e_vr_wantH = 0; }

// --- panel placement --------------------------------------------------------
static bool          q3e_vr_havePanel = false;
static simd_float4x4 q3e_vr_panelHead;
// The source extent the PANELQUAD line last reported. The line is pinned again
// only when this moves, so a session costs one line and a vid_restart costs a
// second — a per-frame dump of the same numbers would push the evidence it
// exists to preserve out of the black box's pinned budget.
static int           q3e_vr_panelDumpW = -1, q3e_vr_panelDumpH = -1;

// R2.1 cut-list: `dist * tanf(X * M_PI/180.0f)` — a half-extent at `dist`
// metres for a half-angle of X degrees — was spelled out inline eight times
// across the region/panel placement code below. One helper, one spelling.
static inline float q3e_vr_tan_deg(float dist, float deg) {
    return dist * tanf(deg * (float)M_PI / 180.0f);
}

// R2.3 fix 3: the HUD panel size multiplies every angle the head-locked layer
// uses, and tan() runs away to infinity at 90 degrees. Nothing this layer
// places has any business past 70 degrees off-axis or 70 degrees wide — the
// eye cannot read it there — so the multiplied angle is clamped before it ever
// reaches a tangent. Signed, because half of these angles are offsets that go
// either way.
static inline float q3e_vr_clamp_deg(float deg) {
    return (deg > 70.0f) ? 70.0f : (deg < -70.0f) ? -70.0f : deg;
}

// Size a quad by the ANGLE it is allowed to subtend, not by a fixed width.
//
// The engine composite is whatever aspect the current render extent happens to
// be, and in VR that extent is the PER-EYE target — 2560x2480 on the device, a
// near-square that has nothing to do with the 16:9 window the panel was first
// sized for. A fixed 4 m width then puts a 3.9 m tall panel 3 m from the face:
// its edges fall outside the field of view and the menu is clipped on the sides
// and along the bottom, with no clue that anything is missing.
//
// So both angular limits are honoured and the SMALLER wins. The panel is then
// guaranteed to fit whatever aspect the engine hands over — which is a property,
// not a measurement of one configuration.
static float q3e_vr_quad_half_width(float dist, float aspect, float maxHalfH, float maxHalfV) {
    const float byH = dist * tanf(maxHalfH);
    const float byV = (aspect > 1e-3f) ? (dist * tanf(maxHalfV) / aspect) : byH;
    return (byH < byV) ? byH : byV;
}

// Published for the dumps: what the last placed panel actually subtends.
static float q3e_vr_panelHalfW = 0.0f, q3e_vr_panelHalfH = 0.0f;
static float q3e_vr_panelDist = 0.0f, q3e_vr_panelAspect = 0.0f;
static float q3e_vr_uiHalfW = 0.0f, q3e_vr_uiHalfH = 0.0f, q3e_vr_uiDist = 0.0f;
// Only the head-locked UI quad can reach the vertical singularity; the panel is
// flattened, so its normal is horizontal by construction and it passes NULL.
static int q3e_vr_uiVerticalLatch = 0;
int Q3E_VR_UIVerticalLatched(void) { return q3e_vr_uiVerticalLatch; }

// --- UI layer readback ------------------------------------------------------
// One pixel of the UI layer, as the compositor sees it: the copy it actually
// samples, alpha included. This exists because the alpha channel is the half of
// the layer that no screenshot can show — a HUD that is present but composited
// at the wrong coverage looks fine in a capture and wrong on a face.
// A horizontal RUN of pixels, not one pixel.
//
// One pixel was a layout guess dressed as a measurement: Quake 3's scoreboard is
// sparse text on nothing, so a probe aimed between two rows reads transparent
// and reports it as missing coverage. A run crosses whatever is actually there,
// and reporting the MAXIMUM alpha and the count of covered samples says both
// "the layer has content here" and "the layer is empty here" without either
// answer depending on where a glyph happens to land.
#define Q3E_VR_PIXEL_MAX_RUN 2048
static volatile int   q3e_vr_pixelWant = 0;
static volatile int   q3e_vr_pixelX = 0, q3e_vr_pixelY = 0, q3e_vr_pixelN = 1;
static volatile int   q3e_vr_pixelReady = 0;
static float          q3e_vr_pixelRGBA[4] = { -1.0f, -1.0f, -1.0f, -1.0f };
static float          q3e_vr_pixelMaxA = -1.0f;
static int            q3e_vr_pixelCovered = -1, q3e_vr_pixelSampled = 0;
static id<MTLBuffer>  q3e_vr_pixelBuf = nil;

void Q3E_VR_RequestUIPixel(int x, int y, int count) {
    if (count < 1) count = 1;
    if (count > Q3E_VR_PIXEL_MAX_RUN) count = Q3E_VR_PIXEL_MAX_RUN;
    q3e_vr_pixelX = x; q3e_vr_pixelY = y; q3e_vr_pixelN = count;
    q3e_vr_pixelReady = 0;
    q3e_vr_pixelWant = 1;
}

int Q3E_VR_ReadUIPixel(float out[4], float *maxAlpha, int *covered, int *sampled) {
    int i;
    if (!q3e_vr_pixelReady) return 0;
    for (i = 0; i < 4; i++) out[i] = q3e_vr_pixelRGBA[i];
    if (maxAlpha) *maxAlpha = q3e_vr_pixelMaxA;
    if (covered)  *covered  = q3e_vr_pixelCovered;
    if (sampled)  *sampled  = q3e_vr_pixelSampled;
    return 1;
}

// Serviced on the compositor thread, from the copy, after it has been committed.
static void q3e_vr_service_pixel(id<MTLCommandQueue> queue, id<MTLTexture> src) {
    if (!q3e_vr_pixelWant || src == nil) return;
    int x = q3e_vr_pixelX, y = q3e_vr_pixelY, n = q3e_vr_pixelN, i;
    if (x < 0 || y < 0 || x >= (int)src.width || y >= (int)src.height) {
        q3e_vr_pixelWant = 0;
        return;
    }
    if (x + n > (int)src.width) n = (int)src.width - x;
    if (q3e_vr_pixelBuf == nil)
        q3e_vr_pixelBuf = [src.device newBufferWithLength:Q3E_VR_PIXEL_MAX_RUN * 4
                                                  options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:src sourceSlice:0 sourceLevel:0
          sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(n, 1, 1)
              toBuffer:q3e_vr_pixelBuf destinationOffset:0
     destinationBytesPerRow:n * 4 destinationBytesPerImage:n * 4];
    [b endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    {
        const uint8_t *p = (const uint8_t *)q3e_vr_pixelBuf.contents;
        float maxA = 0.0f;
        int covered = 0;
        // BGRA8 is what the engine's colour format resolves to on this target;
        // the channel order is stated here so a format change cannot silently
        // turn blue into red.
        q3e_vr_pixelRGBA[2] = p[0] / 255.0f;
        q3e_vr_pixelRGBA[1] = p[1] / 255.0f;
        q3e_vr_pixelRGBA[0] = p[2] / 255.0f;
        q3e_vr_pixelRGBA[3] = p[3] / 255.0f;
        for (i = 0; i < n; i++) {
            const float a = p[i * 4 + 3] / 255.0f;
            if (a > maxA) maxA = a;
            if (a > 0.02f) covered++;
        }
        q3e_vr_pixelMaxA = maxA;
        q3e_vr_pixelCovered = covered;
        q3e_vr_pixelSampled = n;
    }
    q3e_vr_pixelReady = 1;
    q3e_vr_pixelWant = 0;
}

// The height calibration is a property of the PLAYER, so it outlives the app.
// Written from the console commands that change it (plain C, no Foundation) via
// this one bridge.
void Q3E_VR_PersistHeight(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (q3e_vrHeightValid) [d setFloat:q3e_vrHeightBaseline forKey:kQ3EVRHeightKey];
    [d setFloat:q3e_vrHeightTrim forKey:kQ3EVRTrimKey];
    // R2.2 fix 4: the height trim has a widget in the settings sheet too, and
    // `q3evrheight`/`q3evrcalibrate` (console or ornament) change it from
    // outside the sheet — so an open sheet is told, exactly like the other five
    // rows are told by Q3E_VR_PersistTuning.
    Q3E_VR_SettingsSheetSync();
}

// R2.1 fix 6c: the ONE persisted store for the height trim — kQ3EVRTrimKey,
// the same key Q3E_VR_Run restores from at every VR entry. Before this fix
// the settings sheet kept a SECOND, independent copy (ios_settings.m's
// DEF_VR_HEIGHT, in inches) that Q3E_Settings_ApplyAll re-pushed at every
// boot and every unrelated slider change — since that key defaulted to 0 on
// a fresh install of THIS round (it is brand new) while a real trim already
// sat in kQ3EVRTrimKey from ordinary play, the boot-time push silently
// zeroed it out from under the player. Exposed here (rather than duplicating
// the "Q3EVRHeightTrimMetres" string in ios_settings.m) so both files agree
// on the storage by construction, not by two literals staying in sync.
float Q3E_VR_GetPersistedHeightTrimMetres(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:kQ3EVRTrimKey] == nil) return 0.0f;
    float v = [d floatForKey:kQ3EVRTrimKey];
    // R2.2 fix 7: an out-of-range STORED value is clamped to the nearest legal
    // one, not thrown away for a 0 — a value a build with slightly different
    // limits wrote (or the +/-19.7 in slider ends this round retired) is still
    // the player's own choice, and answering 0 for it is a silent reset of a
    // setting they can see on screen. NaN is the one answer with no nearest
    // legal value, and it reads as "no trim".
    if (!isfinite(v)) return 0.0f;
    return (v < -Q3E_VR_TRIM_LIMIT_M) ? -Q3E_VR_TRIM_LIMIT_M
         : (v >  Q3E_VR_TRIM_LIMIT_M) ?  Q3E_VR_TRIM_LIMIT_M : v;
}

int Q3E_VR_HasPersistedHeightTrim(void) {
    return ([NSUserDefaults.standardUserDefaults objectForKey:kQ3EVRTrimKey] != nil) ? 1 : 0;
}

// The quiet setter for the trim (R2.1 fix 6/12): updates the live engine
// value, publishes it (Q3E_VR_PublishHeight is a no-op outside VR — the
// value still lands the moment a session starts, same as any other
// mid-session console/settings change), and persists it — with no console
// dispatch and no dump, so a settings-sheet slider drag does not pay for
// harness diagnostics.
//
// R2.2 fix 7: CLAMPS an out-of-range trim instead of dropping it. Dropping was
// a silent data loss on three paths at once — the settings sheet's Height
// slider ends compute 0.50038 m against a 0.50 m limit (so the ends applied
// nothing and the sheet showed a number the engine had never taken), the
// settings migration folded a retired key through here and then deleted its
// only copy, and the console command clamped, so the same input meant two
// different things depending on who typed it. NaN is still refused outright:
// it is not a magnitude out of range, and one of them in this state lifts the
// camera out of the map on every launch, forever (see the height gates).
void Q3E_VR_SetPersistedHeightTrimMetres(float metres) {
    if (!isfinite(metres)) return;
    q3e_vrHeightTrim = (metres < -Q3E_VR_TRIM_LIMIT_M) ? -Q3E_VR_TRIM_LIMIT_M
                     : (metres >  Q3E_VR_TRIM_LIMIT_M) ?  Q3E_VR_TRIM_LIMIT_M : metres;
    Q3E_VR_PublishHeight();
    Q3E_VR_PersistHeight();
}

// R2 item 6: the settings sheet's VR Reset button clears the height baseline
// too (charter D11/§14), so the NEXT VR entry re-calibrates from scratch
// rather than keeping a number the player never asked to see again. In-memory
// state is cleared here as well — a Reset pressed while VR is already running
// (from the ornament) must not have to wait for a re-entry to take effect.
void Q3E_VR_ClearHeightBaseline(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d removeObjectForKey:kQ3EVRHeightKey];
    [d removeObjectForKey:kQ3EVRTrimKey];
    q3e_vrHeightValid = 0;
    q3e_vrHeightTrim = 0.0f;
    Q3E_BlackBox_Pin("vr: height baseline CLEARED (settings reset) — the next VR entry re-calibrates");
}

void Q3E_VR_PanelGeometry(float *dist, float *halfW, float *halfH, float *aspect) {
    if (dist)   *dist   = q3e_vr_panelDist;
    if (halfW)  *halfW  = q3e_vr_panelHalfW;
    if (halfH)  *halfH  = q3e_vr_panelHalfH;
    if (aspect) *aspect = q3e_vr_panelAspect;
}
void Q3E_VR_UIGeometry(float *dist, float *halfW, float *halfH) {
    if (dist)  *dist  = q3e_vr_uiDist;
    if (halfW) *halfW = q3e_vr_uiHalfW;
    if (halfH) *halfH = q3e_vr_uiHalfH;
}

// `flatten` decides whether the quad ignores head pitch. The non-world PANEL
// does (it is a screen in the room: level, and it stays where it was put), the
// head-locked UI layer does not (a HUD the player can look away from is not a
// HUD). Both keep roll out of it — a HUD that rolls with the head is the fastest
// way to make someone ill.
static simd_float4x4 q3e_vr_panel_anchor(simd_float4x4 originFromDevice, float dist, float halfW,
                                         float aspect, bool flatten, int *verticalLatch) {
    simd_float3 headPos = originFromDevice.columns[3].xyz;
    simd_float3 fwd = -originFromDevice.columns[2].xyz;
    if (flatten) fwd.y = 0.0f;
    float len = simd_length(fwd);
    fwd = (len < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / len;
    simd_float3 pos = headPos + fwd * dist;
    simd_float3 normal = simd_normalize(headPos - pos);
    simd_float3 worldUp = simd_make_float3(0, 1, 0);

    // Building the quad's right axis from cross(worldUp, normal) fails exactly
    // when the player looks straight up or straight down — which in Quake 3 is
    // not an edge case, it is a rocket jump and every ledge in the game. The
    // cross product goes to zero, normalize(0) is NaN, and a NaN model matrix
    // turns the HUD into garbage or nothing at all. Just short of vertical it is
    // worse than useless in a different way: the quad's yaw is then decided by a
    // vanishing component, so it spins on tracking noise.
    //
    // Near vertical the head's OWN right axis is the meaningful one — it is what
    // the player's ears are level with. The latch (enter at ~10 degrees from
    // vertical, leave at ~16) keeps the changeover from chattering back and forth
    // while someone holds their view near the boundary.
    const float verticality = fabsf(simd_dot(normal, worldUp));
    const float kEnter = 0.985f, kLeave = 0.960f;
    int latched = verticalLatch ? *verticalLatch : 0;
    if (!latched && verticality > kEnter)      latched = 1;
    else if (latched && verticality < kLeave)  latched = 0;
    if (verticalLatch) *verticalLatch = latched;

    simd_float3 right;
    if (latched) {
        simd_float3 headRight = originFromDevice.columns[0].xyz;
        headRight -= normal * simd_dot(headRight, normal);
        float rl = simd_length(headRight);
        right = (rl > 1e-4f) ? headRight / rl : simd_make_float3(1, 0, 0);
    } else {
        right = simd_normalize(simd_cross(worldUp, normal));
    }
    simd_float3 up = simd_cross(normal, right);
    simd_float4x4 place;
    place.columns[0] = simd_make_float4(right * halfW, 0.0f);
    place.columns[1] = simd_make_float4(up * (halfW * aspect), 0.0f);
    place.columns[2] = simd_make_float4(normal, 0.0f);
    place.columns[3] = simd_make_float4(pos, 1.0f);
    return place;
}

// --- R2 item 4: independent 2D-layer region quads ---------------------------
//
// Virtual 640x480 rects (Q3's own HUD coordinate space, y=0 at top — the same
// space every trap_R_DrawStretchPic call already lives in; SCR_AdjustFrom640
// is a uniform stretch across the WHOLE render target, so a virtual rect maps
// straight onto a 0..1 UV rect of the redirect texture with no further
// correction needed). Coordinates are vanilla baseq3's own cg_draw.c layout;
// a mod that places things elsewhere still gets full, undiminished coverage
// from the fallback quad below (charter D6: mods must never lose UI).
static simd_float4 q3e_vr_uv(float x, float y, float w, float h) {
    return simd_make_float4(x / 640.0f, y / 480.0f, (x + w) / 640.0f, (y + h) / 480.0f);
}

// R2.3 fix 1: every 2D quad — the dedicated regions AND the fallback — now
// carries its own list of rectangles to LEAVE OUT, in the shared 0..1 texture
// UV space. Before this round only the fallback had one, which quietly assumed
// the region rects never overlapped each other. They did: the MESSAGE band
// (virtual rows 64..244) contains row 240, and row 240 is where Quake 3 draws
// the crosshair — so the crosshair was painted a second time, bigger, on the
// message quad, ~4 degrees above the real one. The scoreboard block straddled
// the statusbar band's top edge the same way. Overlap has to be answered where
// it happens (per quad), not once at the end.
#define Q3E_VR_EXCL_MAX 6

typedef struct {
    simd_float4x4 model;
    simd_float4   uv;
    simd_float4   excl[Q3E_VR_EXCL_MAX];
    int           exclN;
    bool          draw;
} q3e_vr_region_t;

enum {
    Q3E_VR_RGN_STATUSBAR = 0,
    Q3E_VR_RGN_NOTIFY,
    Q3E_VR_RGN_MESSAGE,
    Q3E_VR_RGN_COUNT
};

// --- the head-locked layout's fixed shape (R3.2 item 2) ----------------------
// R3.1's Panel Size multiplied every angular OFFSET in this layout, and the
// device round read that slider as "where the HUD is" and asked for it to be
// exactly that. So the spread it was left at — its 1.25 default, the geometry
// 1.0.4.7 shipped and the round approved — becomes the layout's shape, and the
// slider that replaces it TRANSLATES the whole cluster instead
// (q3e_vrHudHeight, degrees). Spelled as a multiplier over the same base angles
// rather than folded into them so the arithmetic that produced today's numbers
// is still readable next to them.
#define Q3E_VR_HUD_SPREAD       1.25f

// R3.2 item 3 — WHY THE STATUSBAR BAND IS 108 ROWS AND NOT 52.
//
// The band was the bottom 52 virtual rows (428..480), and the device screenshot
// showed three consequences of that boundary at once: the status face icon
// clipped flat across the top, the score box sitting at a different height from
// the health/ammo row it belongs with, and a thin bright sliver adrift below the
// face. All three are the same defect — baseq3's lower HUD does not live inside
// 428..480:
//
//   CG_DrawWeaponSelect   the weapon bar,            around row 380
//   CG_DrawLowerRight     the score box,             rows 404..428
//   CG_DrawStatusBar      the team background strip, rows 420..480
//   CG_DrawStatusBarHead  the face,  480 - 60 = row 420 at rest, and up to
//                         480 - 90 = row 390 while the damage kick enlarges it
//   CG_DrawStatusBar      the digits and icons,      rows 432..480
//
// Anything above the band's top edge was left on the fallback quad, which is
// centred on the view and does not take the layout's placement — hence a face
// with its crown somewhere else, a score box that stayed behind, and the top
// eight rows of the team strip as a free-floating sliver.
//
// R4.2 item 1 — 372 WAS STILL TWO ROWS TOO LOW, and the device round found the
// two elements it cut. CG_DrawWeaponSelect draws its icon row at y = 380 and
// the SELECTED WEAPON'S NAME above it, at y - 22 = row 358, in BIGCHARs 16 rows
// tall — so the name spans rows 358..374 and the old boundary sliced it three
// rows from the bottom: an almost-whole "Machinegun" left on the centred
// fallback quad, and the last three rows of it repeated a quarter of the way
// down the view in the statusbar band. That is exactly the maintainer's screenshot (the
// name twice, the lower copy clipped). The same boundary also cut the first
// powerup icon, which CG_DrawPowerups draws at ICON_SIZE * 0.75 = 36 rows tall
// immediately above the score box, i.e. rows 368..404.
//
// The band therefore starts at row 356 — two rows of margin above the name's
// own top row, and above every element in the table:
//
//   CG_DrawWeaponSelect   the selected weapon's NAME, rows 358..374
//   CG_DrawPowerups       the first powerup icon,     rows 368..404
//   CG_DrawWeaponSelect   the icon row (select marker rows 376..416)
//   CG_DrawLowerRight     the score box,              rows 404..428
//   CG_DrawStatusBar      the team background strip,  rows 420..480
//   CG_DrawStatusBarHead  the face,  480 - 60 = row 420 at rest, and up to
//                         480 - 90 = row 390 while the damage kick enlarges it
//   CG_DrawStatusBar      the digits and icons,       rows 432..480
//
// Nothing in baseq3 starts between 244 (the message band's bottom) and 356, so
// the whole lower cluster is captured by ONE quad and moves as one thing.
//
// The one element no fixed boundary can contain is a SECOND powerup: they stack
// upward 36 rows at a time from 404, so three of them reach row 296. That is a
// known residual (D-VR-R4.2) rather than a reason to give the band a third of
// the screen — a band that tall would drag the ordinary HUD's placement with it.
#define Q3E_VR_HUD_STATUS_TOP   356.0f

// The band is anchored by its BOTTOM edge, not its centre: it grew upward, and
// the health/ammo row along its bottom is the part the device round already had
// where it wanted it. -23.65 degrees is exactly where the 1.0.4.7 band's bottom
// edge sat (its -21.25 degree centre less its own 2.4 degree half-height at the
// default HUD Size), so at HUD Height 0 the status row does not move at all —
// only the content that used to be missing from it arrives.
#define Q3E_VR_HUD_STATUS_BOTTOM_DEG (-23.65f)

// Centre pitch, in degrees, of a band whose bottom edge sits at `bottomDeg` and
// whose half-height is `halfH` metres at `dist`. The quads are placed by TANGENT
// offset on a plane at `dist` (see q3e_vr_region_anchor), so the conversion has
// to go through the plane, not through angles directly.
static inline float q3e_vr_band_pitch(float dist, float bottomDeg, float halfH) {
    const float centreY = q3e_vr_tan_deg(dist, bottomDeg) + halfH;
    return atan2f(centreY, dist) * 180.0f / (float)M_PI;
}

// Add `carve` to `dst`'s exclusion list, but only if the two actually overlap —
// an exclusion rect that touches nothing costs a shader iteration on every
// fragment of the quad and makes the published exclusion count a lie about what
// the frame was really masking.
static void q3e_vr_carve(simd_float4 *excl, int *n, simd_float4 dst, simd_float4 carve) {
    if (*n >= Q3E_VR_EXCL_MAX) return;
    if (carve.z <= dst.x || carve.x >= dst.z || carve.w <= dst.y || carve.y >= dst.w) return;
    excl[(*n)++] = carve;
}

// Head-locked at a yaw/pitch offset from straight-ahead (degrees), FULL head
// lock — pitch and roll included, unlike the flattened menu panel below —
// exactly the donor HUD/message panel shape (VR-PORTING-GUIDE.md's
// vkq_vr_hud_anchor/vkq_vr_msg_anchor), generalized to an arbitrary offset
// instead of one fixed Low/High/message slot.
static simd_float4x4 q3e_vr_region_anchor(simd_float4x4 originFromDevice, float dist,
                                          float yawDeg, float pitchDeg,
                                          float halfW, float halfH) {
    simd_float4x4 t = matrix_identity_float4x4;
    simd_float4x4 sc = matrix_identity_float4x4;
    t.columns[3] = simd_make_float4(q3e_vr_tan_deg(dist, yawDeg),
                                    q3e_vr_tan_deg(dist, pitchDeg),
                                    -dist, 1.0f);
    sc.columns[0].x = halfW;
    sc.columns[1].y = halfH;
    return simd_mul(originFromDevice, simd_mul(t, sc));
}

// --- the loop ---------------------------------------------------------------
void Q3E_VR_Ended(void);

void Q3E_VR_Run(cp_layer_renderer_t layer_renderer)
{
    q3e_vrStop = 0;
    q3e_vrRunning = 1;
    q3e_vrFrameCount = 0;
    q3e_vrDropped = 0;
    q3e_vrRepresents = 0;
    // Reset the ARBITRATION too, not just the counters. Re-entering VR during a
    // live game otherwise inherits the previous session's WORLD verdict, and the
    // loop presents eye copies it does not have yet — pure black, in full
    // immersion, for the whole pre-commit window.
    q3e_vrClientReason = Q3E_VRP_NOT_VR;
    q3e_vrPresentReason = Q3E_VRP_NOT_VR;
    q3e_vrPresentWorld = 0;
    q3e_vrEngineTimeouts = 0;
    q3e_vr_haveBase = false;
    q3e_vr_havePanel = false;
    q3e_vr_panelDumpW = q3e_vr_panelDumpH = -1;
    q3e_vr_contractPrev = nil;
    q3e_vr_eyeCopy[0] = q3e_vr_eyeCopy[1] = nil;
    q3e_vr_depthCopy[0] = q3e_vr_depthCopy[1] = nil;
    q3e_vr_panelCopy = nil;
    q3e_vr_uiCopy = nil;
    q3e_vr_lastUIFrames = -1;
    q3e_vr_uiCopies = 0;
    q3e_vrUIQuadDrawn = 0;
    q3e_vr_pixelWant = q3e_vr_pixelReady = 0;
    q3e_vr_uiVerticalLatch = 0;
    // R2.1 fix 8: a clean slate for the head pose too — unlike the height
    // baseline just below (a property of the PLAYER that deliberately
    // outlives the session), the head's yaw/pitch is a property of the LAST
    // FRAME and must not leak into a new one. Without this, the first frames
    // of a fresh entry (before this session's own base capture completes,
    // `q3e_vr_haveBase` above) publish/consume whatever the PREVIOUS
    // session's final head orientation happened to be, and the aim visibly
    // slews from it toward the real value instead of starting there.
    pthread_mutex_lock(&q3e_vr_mtx);
    q3e_vr_pub.headYawDeg = 0.0f;
    q3e_vr_pub.headPitchDeg = 0.0f;
    memset(q3e_vr_pub.handPosed, 0, sizeof(q3e_vr_pub.handPosed));
    memset(q3e_vr_pub.handHeld, 0, sizeof(q3e_vr_pub.handHeld));
    memset(q3e_vr_pub.handPresent, 0, sizeof(q3e_vr_pub.handPresent));
    pthread_mutex_unlock(&q3e_vr_mtx);
    q3e_vrHeadYaw = 0.0f;
    q3e_vrHeadPitch = 0.0f;
    q3e_vrHeadRoll = 0.0f;
    // R3: hands never survive a session boundary either. A stale pose would draw
    // the weapon wherever the controller was when VR closed, and a stale button
    // would leave +attack held — the same rule tracking loss follows.
    Q3E_VR_ResetHands();
    // The height baseline outlives the session (it is a property of the PLAYER,
    // not of this VR entry), so it is restored before the first pose lands and a
    // re-entry does not silently re-measure someone who happens to be sitting.
    {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        // Validated on the way IN, not only on the way out. A stored NaN (which
        // a one-sided clamp will happily have written) otherwise comes back
        // unchecked and drives the ceiling clamp's integrator forever.
        q3e_vrHeightValid = 0;
        if ([d objectForKey:kQ3EVRHeightKey] != nil) {
            const float stored = [d floatForKey:kQ3EVRHeightKey];
            if (Q3E_VR_HeightBaselineOK(stored)) {
                q3e_vrHeightBaseline = stored;
                q3e_vrHeightValid = 1;
            } else {
                Q3E_BlackBox_Pin("vr: stored height baseline %.3f m is not usable — discarded, "
                                 "the next entry will re-capture", stored);
            }
        }
        if ([d objectForKey:kQ3EVRTrimKey] != nil) {
            const float storedTrim = [d floatForKey:kQ3EVRTrimKey];
            q3e_vrHeightTrim = Q3E_VR_HeightTrimOK(storedTrim) ? storedTrim : 0.0f;
        }
        Q3E_BlackBox_Pin("vr: height baseline %s (%.2f m, trim %+.2f m)",
                         q3e_vrHeightValid ? "restored" : "NOT SET — will capture on first pose",
                         q3e_vrHeightBaseline, q3e_vrHeightTrim);
    }
    q3e_vr_staleAnchor = 0;
    q3e_vr_restartSkips = 0;
    q3e_vr_blindWorld = 0;
    q3e_vr_lastPairs = VK_Get3DPairs();
    int notifyEnded = 0;
    int lastReason = -1;
    int engineRedirectPrev = 0;
    double uiFreshAt = 0.0;      // when the UI layer last actually advanced
    id<MTLCommandQueue> queue = nil;

    ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create();
    ar_world_tracking_provider_t wtp = ar_world_tracking_provider_create(wtc);
    ar_session_t arSession = ar_session_create();
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(wtp, NULL);
    ar_session_run(arSession, providers);

    Q3E_BlackBox_Pin("vr: loop started (worldscale=%.2f u/m, render scale %.2fx)",
                     q3e_vrWorldScale, q3e_vrRenderScale);

    simd_float4x4 prevAnchorTransform = matrix_identity_float4x4;
    ar_device_anchor_t prevAnchor = ar_device_anchor_create();
    int havePrevAnchor = 0;

    int running = 1;
    while (running) {
        if (q3e_vrStop) {
            Q3E_BlackBox_Pin("vr: stop requested, exiting cleanly (frames=%d)", q3e_vrFrameCount);
            running = 0; continue;
        }
        switch (cp_layer_renderer_get_state(layer_renderer)) {
            case cp_layer_renderer_state_paused: {
                // POLLED, not blocked. cp_layer_renderer_wait_until_running has
                // no timeout, and in the wedge this guards against — a layer
                // parked in `paused` whose invalidation never arrives — it never
                // returns, so a check placed after it never runs. Polling the
                // state with a short sleep is the only shape that actually
                // bounds, and it re-reads the stop flag every iteration.
                const CFTimeInterval pausedAt = CACurrentMediaTime();
                enum cp_layer_renderer_state st = cp_layer_renderer_state_paused;
                Q3E_BlackBox("vr: state=paused, polling (frames=%d)", q3e_vrFrameCount);
                while (!q3e_vrStop) {
                    usleep(10000);
                    st = cp_layer_renderer_get_state(layer_renderer);
                    if (st != cp_layer_renderer_state_paused) break;
                    if (CACurrentMediaTime() - pausedAt > 2.0) break;
                }
                if (q3e_vrStop) continue;
                if (st == cp_layer_renderer_state_paused) {
                    Q3E_BlackBox_Pin("vr: LAYER paused >2 s and did not resume — treating it as a "
                                     "system dismissal and running the normal exit");
                    notifyEnded = 1; running = 0;
                }
                continue;
            }
            case cp_layer_renderer_state_invalidated:
                Q3E_BlackBox_Pin("vr: layer INVALIDATED, exiting (frames=%d)", q3e_vrFrameCount);
                notifyEnded = 1; running = 0; continue;
            case cp_layer_renderer_state_running:
            default:
                break;
        }

        @autoreleasepool {

        cp_frame_t frame = cp_layer_renderer_query_next_frame(layer_renderer);
        if (frame == NULL)
            continue;

        // Both of these failures INVALIDATE the frame. Abandon it — no
        // end_submission, no cleanup call of any kind; every later call on an
        // invalidated frame is API misuse and CompositorServices answers misuse
        // with an abort.
        cp_frame_timing_t timing = cp_frame_predict_timing(frame);
        if (timing == NULL) {
            q3e_vrDropped++;
            if (q3e_vrDropped == 1)
                Q3E_BlackBox_Pin("vr: COMPOSITOR withheld frame timing at frame %d — abandoned",
                                 q3e_vrFrameCount);
            continue;
        }
        cp_frame_start_update(frame);
        cp_frame_end_update(frame);
        cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
        cp_frame_start_submission(frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        cp_drawable_t drawable = cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
        if (drawable == NULL) {
            q3e_vrDropped++;
            if (q3e_vrDropped == 1)
                Q3E_BlackBox_Pin("vr: COMPOSITOR withheld a drawable at frame %d — abandoned",
                                 q3e_vrFrameCount);
            continue;
        }

        if (queue == nil) {
            id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
            queue = [t0.device newCommandQueue];
            q3e_vr_build_pipelines(t0.device, t0.pixelFormat,
                                   cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
        }
        if (q3e_vrFrameCount == 0)
            q3e_vr_dump_contract(layer_renderer, drawable);

        size_t views = cp_drawable_get_view_count(drawable);
        q3e_vrViews = (int)views;

        // Sizing, published every frame so the dump can never disagree with what
        // is on screen.
        {
            cp_view_t v0 = cp_drawable_get_view(drawable, 0);
            cp_view_texture_map_t tmap0 = cp_view_get_view_texture_map(v0);
            MTLViewport vp0 = cp_view_texture_map_get_viewport(tmap0);
            id<MTLTexture> ct0 = cp_drawable_get_color_texture(drawable,
                                    cp_view_texture_map_get_texture_index(tmap0));
            q3e_vrEyePhysW = (int)ct0.width;  q3e_vrEyePhysH = (int)ct0.height;
            q3e_vrEyeLogW = (int)vp0.width;   q3e_vrEyeLogH = (int)vp0.height;
            q3e_vrEngineW = Q3E_VR_EngineRenderWidth();
            q3e_vrEngineH = Q3E_VR_EngineRenderHeight();

            int wantW = (int)(ct0.width * q3e_vrRenderScale);
            int wantH = (int)(ct0.height * q3e_vrRenderScale);
            q3e_vr_fit_ui_aspect(&wantW, &wantH);
            q3e_vr_cap_eye_extent(&wantW, &wantH);
            if (!q3e_vr_sizeRequested && wantW > 0 && wantH > 0 &&
                (abs(wantW - q3e_vrEngineW) > 8 || abs(wantH - q3e_vrEngineH) > 8)) {
                q3e_vr_wantW = wantW; q3e_vr_wantH = wantH;
                q3e_vr_sizeRequested = 1;
                Q3E_BlackBox_Pin("vr: per-eye target %dx%dpx requested (physical %dx%d x %.2f; "
                                 "logical viewport %dx%d — NOT what the engine is sized from); "
                                 "engine currently %dx%d",
                                 wantW, wantH, (int)ct0.width, (int)ct0.height, q3e_vrRenderScale,
                                 (int)vp0.width, (int)vp0.height, q3e_vrEngineW, q3e_vrEngineH);
            }
        }

        // Device anchor at PRESENTATION time — the frame-timing header is
        // explicit that trackable-anchor time is for TRACKABLE anchors (hands and
        // accessories), and presentation time is what an ARKit device anchor is
        // predicted for.
        CFTimeInterval presTime = cp_time_to_cf_time_interval(
            cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
        ar_device_anchor_t anchor = ar_device_anchor_create();
        ar_device_anchor_query_status_t anchorStatus =
            ar_world_tracking_provider_query_device_anchor_at_timestamp(wtp, presTime, anchor);
        int tracked = (anchorStatus == ar_device_anchor_query_status_success);
        q3e_vrTracked = tracked;

        simd_float4x4 originFromDevice = ar_device_anchor_get_origin_from_anchor_transform(anchor);
        if (q3e_vrSynthPose) {
            // Injected where the tracked pose lands, so everything downstream of
            // here — base capture, eye composition, tangents, the engine's own
            // view maths — is the real chain.
            simd_float3 p = simd_make_float3(q3e_vrSynthPos[0], q3e_vrSynthPos[1], q3e_vrSynthPos[2]);
            originFromDevice = simd_mul(q3e_vr_translate(p),
                                simd_mul(q3e_vr_rotY(q3e_vrSynthYaw * (float)M_PI / 180.0f),
                                         q3e_vr_rotX(q3e_vrSynthPitch * (float)M_PI / 180.0f)));
        }

        if (!q3e_vr_haveBase && (tracked || q3e_vrSynthPose) && q3e_vrFrameCount > 10) {
            simd_float3 fwd = -originFromDevice.columns[2].xyz;
            q3e_vr_basePos = originFromDevice.columns[3].xyz;
            q3e_vr_baseYaw = atan2f(-fwd.x, -fwd.z);
            q3e_vr_haveBase = true;
            // First entry ever: this IS the calibration. Every later entry keeps
            // the stored baseline — re-measuring on each entry would make the
            // player's height depend on whether they happened to be standing when
            // the space opened.
            if (!q3e_vrHeightValid && !q3e_vrSynthPose) {
                if (Q3E_VR_CaptureHeight(q3e_vr_basePos.y))
                    Q3E_VR_PersistHeight();
            }
            Q3E_BlackBox_Pin("vr: base captured at (%.2f,%.2f,%.2f)m yaw=%.1fdeg (standing eye "
                             "height %.2f m maps to the game's own eye height)",
                             q3e_vr_basePos.x, q3e_vr_basePos.y, q3e_vr_basePos.z,
                             q3e_vr_baseYaw * 180.0f / (float)M_PI, q3e_vr_basePos.y);
        }

        simd_float4x4 baseFromOrigin = simd_mul(q3e_vr_rotY(-q3e_vr_baseYaw),
                                                q3e_vr_translate(-q3e_vr_basePos));

        // Compose both eyes and publish the pair.
        q3e_vr_pose_t pose;
        memset(&pose, 0, sizeof(pose));
        pose.znear = 0.1f * q3e_vrWorldScale;

        // --- hands (R3) -----------------------------------------------------
        // Polled HERE — one statement after the device anchor, before anything
        // is composed — because that is what makes the hands and the head one
        // instant. Everything below reads this frame's answer; nothing re-polls.
        Q3ESenseHand hands[2];
        Q3E_Sense_Poll(hands);
        for (int h = 0; h < 2; h++) {
            simd_float4x4 handInBase;
            simd_float3 hf, hp;
            pose.handPosed[h] = hands[h].posed;
            pose.handHeld[h] = hands[h].held;
            pose.handPresent[h] = hands[h].present;
            if (!hands[h].posed)
                continue;
            handInBase = simd_mul(baseFromOrigin, hands[h].originFromHand);
            // -Z is forward for an ARKit pose (right-up-back), same as the head.
            hf = -handInBase.columns[2].xyz;
            pose.handYawDeg[h] = atan2f(-hf.x, -hf.z) * 180.0f / (float)M_PI;
            pose.handPitchDeg[h] = asinf(simd_clamp(hf.y, -1.0f, 1.0f)) * 180.0f / (float)M_PI;
            hp = handInBase.columns[3].xyz;
            q3e_vrHandPos[h][0] = hp.x;
            q3e_vrHandPos[h][1] = hp.y;
            q3e_vrHandPos[h][2] = hp.z;
        }
        q3e_vrHandTracked = (hands[0].posed ? 1 : 0) | (hands[1].posed ? 2 : 0);
        q3e_vrHandHeld    = (hands[0].held  ? 1 : 0) | (hands[1].held  ? 2 : 0);
        q3e_vrHandPresent = (hands[0].present ? 1 : 0) | (hands[1].present ? 2 : 0);

        {
            simd_float4x4 headInBase = simd_mul(baseFromOrigin, originFromDevice);
            float la[9];
            q3e_vr_map_axis(-headInBase.columns[2].xyz, &la[0]);
            q3e_vr_map_axis(-headInBase.columns[0].xyz, &la[3]);
            q3e_vr_map_axis( headInBase.columns[1].xyz, &la[6]);
            memcpy(pose.listener, la, sizeof(la));

            q3e_vrHeadOriginY = originFromDevice.columns[3].y;
            simd_float3 hp = headInBase.columns[3].xyz;
            q3e_vrHeadPos[0] = hp.x; q3e_vrHeadPos[1] = hp.y; q3e_vrHeadPos[2] = hp.z;
            simd_float3 hf = -headInBase.columns[2].xyz;
            // R2.1 fix 8: LOCAL variables, not the q3e_vrHeadYaw/Pitch globals
            // directly — those are now engine-thread-owned (written only from
            // q3e_vr_engine_acquire's synchronized snapshot). This thread's own
            // use of the head yaw below (the rotation/translation correction)
            // reads these locals, and the value crosses to the engine thread
            // ONLY via pose.headYawDeg/headPitchDeg under the mutex, same as
            // every other per-eye field.
            const float headYawDeg = atan2f(-hf.x, -hf.z) * 180.0f / (float)M_PI;
            const float headPitchDeg = asinf(simd_clamp(hf.y, -1.0f, 1.0f)) * 180.0f / (float)M_PI;
            q3e_vrHeadRoll = 0.0f;   // never a race: always zero, nothing to shear
            pose.headYawDeg = headYawDeg;
            pose.headPitchDeg = headPitchDeg;

            // --- aim arbitration (R3 item 3) --------------------------------
            // The aim hand owns the aim while it is tracked; the head owns it
            // otherwise, with NO transition state to get wrong: both write the
            // same two numbers, and the body accumulator CL_VRApplyHeadAim keeps
            // is untouched by the swap, so the world does not turn when the aim
            // moves to the hand. Only the crosshair moves — to where the hand is
            // pointing, which is the whole point of picking the controllers up.
            //
            // Two-frame hysteresis on the way DOWN only. A single dropped anchor
            // is common and momentary; snapping the aim back to the gaze for one
            // frame because of it would read as a flick, and a flick during a
            // rocket jump is a death. Acquiring is immediate — there is nothing
            // to protect against on that side.
            {
                static int handMiss = 0;
                const int aimHand = (q3e_vrAimHand == Q3E_VR_HAND_LEFT) ? 0 : 1;
                const int posed = pose.handPosed[aimHand] && q3e_vrHandAimEnabled;
                int useHand;
                if (posed) {
                    handMiss = 0;
                    useHand = 1;
                } else {
                    if (handMiss < 3)
                        handMiss++;
                    useHand = (q3e_vrAimSource == Q3E_VRAIM_HAND && handMiss < 3);
                }
                if (useHand) {
                    pose.aimSource = Q3E_VRAIM_HAND;
                    pose.aimYawDeg = pose.handYawDeg[aimHand];
                    // The trim is an AIM correction and belongs only here: a
                    // controller's tracked forward axis is not where a player
                    // feels they are pointing, and the difference is personal.
                    // It is deliberately NOT applied to head aim, where the
                    // crosshair and the gaze are the same thing and an offset
                    // between them is a nausea machine.
                    // R3.6: Q3E_VR_AIM_PITCH_BIAS is ZERO — the controller's
                    // own forward axis. R3.4 baked +2 in and the round that
                    // trimmed around it kept dialling -2 back out, which is the
                    // same aim reached from both sides. The constant stays as
                    // the ONE place this path could acquire an offset.
                    pose.aimPitchDeg = pose.handPitchDeg[aimHand] +
                                       Q3E_VR_AIM_PITCH_BIAS + q3e_vrAimPitchTrim;
                } else if (q3e_vrAimMode == Q3E_VRAIMMODE_PAD && q3e_vrPadAimEnabled &&
                           q3e_vrPadAimSeeded) {
                    // R4.6 — the "Aiming: Gamepad" row. THIRD source, same two
                    // numbers, maintained on the engine thread
                    // (Q3E_VR_ConsumePadAim) in this same base frame and the same
                    // ARKit convention, so everything below — the yaw the eye
                    // composition removes, the delta-compensated viewangle write,
                    // the movement basis, the marker — is the shipping chain
                    // unchanged. The head still owns the camera: the eye pose
                    // removes THIS yaw and re-applies the head's, so the net is
                    // body+head exactly as it is for a hand.
                    // R4.7: that yaw is now always ZERO — the stick turns the
                    // BODY and the aim is the body's forward, so the crosshair
                    // sits at the centre of the game's forward direction (the
                    // flat game's centred crosshair) while the head still glances
                    // freely. The R4.6 cone this used to carry is gone.
                    pose.aimSource = Q3E_VRAIM_PAD;
                    pose.aimYawDeg = q3e_vrPadAimYaw;
                    pose.aimPitchDeg = q3e_vrPadAimPitch;
                } else {
                    pose.aimSource = Q3E_VRAIM_HEAD;
                    pose.aimYawDeg = headYawDeg;
                    pose.aimPitchDeg = headPitchDeg;
                }
            }

            // --- the WORLD PITCH (R4.8) -------------------------------------
            // The maintainer, on 1.0.4.17: "keep my crosshair at the center of the
            // screen. THE VERY CENTER." R4.7 did that for yaw by turning the
            // BODY; pitch was still an aim offset the crosshair rode up and down
            // on, because nothing pitched the camera. This is the missing half:
            // in Gamepad aim the stick's pitch rotates the WORLD, exactly as its
            // yaw rotates the body, and the aim then sits at the view's own
            // centre on both axes.
            //
            // It has to be applied HERE, in the published eye pose, and nowhere
            // else. The engine composes each eye against a YAW-ONLY body basis
            // built from cl.viewangles (R_VRComposeEye) — pitch is deliberately
            // not lifted out of the game view, so the published pose is the ONLY
            // place a world pitch can enter and there is nothing to double-count
            // it against. The R2.1 orbit scar is the rule that keeps it honest:
            // the eye ROTATION and the eye TRANSLATION must be pre-rotated by the
            // same matrix, or the head's positional offset resolves in a frame
            // its own rotation does not share and the world orbits the player.
            // The third consumer, the movement basis, is yaw-only and takes no
            // pitch term at all — walking is not affected by where you look up.
            //
            // Zero outside Gamepad aim, so head aim and hand aim compose exactly
            // as they did: this is a mode's rotation, not a new global.
            //
            // Sign: ARKit convention here (positive = up), the same one
            // pose.aimPitchDeg is published in; Q3E_VR_PublishHeadAim is the one
            // seam that flips it into Quake's (positive = down).
            const float bodyPitchDeg =
                (pose.aimSource == Q3E_VRAIM_PAD) ? pose.aimPitchDeg : 0.0f;
            const simd_float4x4 worldPitch =
                q3e_vr_rotX(bodyPitchDeg * (float)M_PI / 180.0f);

            // --- hand pose -> body frame ------------------------------------
            // The SAME undo the eyes get (see `yawRemove` below), for the same
            // reason: the engine has exactly one basis to resolve anything
            // against — the yaw-only body basis it builds out of cl.viewangles,
            // which already carries the aim offset — so every published offset
            // and rotation must have that offset taken back out first. R4.8: and
            // the same world pitch, so a hand that IS tracked stays in the world
            // the player is looking at rather than in an unpitched one (zero in
            // every mode a hand can aim in, so nothing changes there).
            {
                simd_float4x4 handYawRemove =
                    simd_mul(worldPitch,
                             q3e_vr_rotY(-pose.aimYawDeg * (float)M_PI / 180.0f));
                for (int h = 0; h < 2; h++) {
                    simd_float4x4 handInBase, rotOnly;
                    simd_float3 t, tRot;
                    if (!pose.handPosed[h])
                        continue;
                    handInBase = simd_mul(baseFromOrigin, hands[h].originFromHand);
                    t = handInBase.columns[3].xyz;
                    tRot = simd_mul(handYawRemove, simd_make_float4(t, 0.0f)).xyz;
                    pose.handOffset[h][0] = -tRot.z * q3e_vrWorldScale;   // forward
                    pose.handOffset[h][1] = -tRot.x * q3e_vrWorldScale;   // left
                    pose.handOffset[h][2] =  tRot.y * q3e_vrWorldScale;   // up
                    rotOnly = simd_mul(handYawRemove, handInBase);
                    q3e_vr_map_axis(-rotOnly.columns[2].xyz, &pose.handAxis[h][0]);
                    q3e_vr_map_axis(-rotOnly.columns[0].xyz, &pose.handAxis[h][3]);
                    q3e_vr_map_axis( rotOnly.columns[1].xyz, &pose.handAxis[h][6]);
                }
            }

            for (int e = 0; e < 2; e++) {
                size_t vIdx = (views > 1) ? (size_t)e : 0;
                cp_view_t view = cp_drawable_get_view(drawable, vIdx);
                simd_float4x4 deviceFromEye = cp_view_get_transform(view);
                if (q3e_vrSynthIPD > 0.0f) {
                    // The simulator vends ONE view with an identity transform, so
                    // without this the two eyes are numerically identical and no
                    // stereo assertion could ever fail.
                    float dx = (e == 0) ? -q3e_vrSynthIPD * 0.5f : q3e_vrSynthIPD * 0.5f;
                    deviceFromEye = q3e_vr_translate(simd_make_float3(dx, 0.0f, 0.0f));
                }
                simd_float4x4 eyeInBase = simd_mul(headInBase, deviceFromEye);
                // R2 item 1b / R2.1 fix 3: head-aim now writes this frame's head
                // yaw into cl.viewangles, and the engine's render composes a
                // YAW-ONLY body basis FROM cl.viewangles (R_VRComposeEye) — so
                // that basis already contains headYawDeg. Publishing the eye's
                // full absolute rotation OR translation on top of it would apply
                // the same yaw a second time. `yawRemove` undoes exactly the
                // rotation head-aim folded into cl.viewangles, and now applies to
                // BOTH the rotation AND the translation — a prior version of this
                // comment argued the offset should be left unrotated ("roomscale
                // drift should track where I'm looking"), which was wrong: the
                // offset is captured in BASE-frame axes (headYaw==0 at the moment
                // of recentre), and the engine only ever has ONE basis (the full
                // body+head yaw from cl.viewangles) to resolve ANYTHING against —
                // rotation or translation. Leaving the translation un-rotated
                // meant it got the head's yaw applied on top of the render's own
                // head-yaw-inclusive basis: standing off the recentre point and
                // turning the head alone — no body turn, no footstep — spun the
                // eye's position around the player like a camera on a boom arm,
                // which is what a device report would read as "the world orbits
                // when I turn my head". Pre-rotating BOTH by the same undo makes
                // the offset resolve against the BODY-only yaw, exactly like the
                // rotation already did, so drift correctly tracks where the
                // player's FEET are facing (the body), not a head turn that moved
                // nothing.
                //
                // R3: the yaw being undone is the AIM yaw, not the head's. They
                // are the same number in Convenience Mode and are not the moment
                // a hand owns the aim — and it is the AIM that CL_VRApplyHeadAim
                // folds into cl.viewangles, so the aim is what has to come back
                // out. Getting this wrong is not subtle: the camera would follow
                // the hand instead of the head. Net camera yaw works out to
                // (body + aim) + (head - aim) = body + head, whichever source
                // aim came from, which is the property that makes hand aim and
                // head-locked vision coexist at all.
                //
                // R4.8: the world pitch is pre-multiplied onto that same undo,
                // so ONE matrix carries both and the rotation and the translation
                // below cannot come apart — which is the R2.1 orbit lesson
                // restated for a second angle. In Gamepad aim this is what makes
                // the stick pitch the world instead of walking the crosshair up
                // the screen; in every other mode it is the identity.
                simd_float4x4 yawRemove =
                    simd_mul(worldPitch,
                             q3e_vr_rotY(-pose.aimYawDeg * (float)M_PI / 180.0f));
                {
                    simd_float3 t = eyeInBase.columns[3].xyz;
                    simd_float3 tRot = simd_mul(yawRemove, simd_make_float4(t, 0.0f)).xyz;
                    pose.offset[e][0] = -tRot.z * q3e_vrWorldScale;   // forward
                    pose.offset[e][1] = -tRot.x * q3e_vrWorldScale;   // left
                    pose.offset[e][2] =  tRot.y * q3e_vrWorldScale;   // up (the
                                                                       // pitch is
                                                                       // in here
                                                                       // too now)
                }
                {
                    simd_float4x4 rotOnly = simd_mul(yawRemove, eyeInBase);
                    q3e_vr_map_axis(-rotOnly.columns[2].xyz, &pose.axis[e][0]);
                    q3e_vr_map_axis(-rotOnly.columns[0].xyz, &pose.axis[e][3]);
                    q3e_vr_map_axis( rotOnly.columns[1].xyz, &pose.axis[e][6]);
                }
                memcpy(q3e_vrEyeOrigin[e], pose.offset[e], sizeof(float) * 3);
                // R4.8: the left eye's forward, UP component — the only
                // published number that can say the CAMERA pitched (HEADNOW
                // reads it back).
                if (e == 0)
                    q3e_vrEyeFwdUp = pose.axis[e][2];

                // Tangents, recovered from the compositor's projection. Never an
                // FOV: a per-eye frustum is asymmetric and an FOV cannot say so.
                simd_float4x4 proj = matrix_identity_float4x4;
                if (__builtin_available(visionOS 2.0, *))
                    proj = cp_drawable_compute_projection(drawable,
                               cp_axis_direction_convention_right_up_back, vIdx);
                float m00 = proj.columns[0].x, m11 = proj.columns[1].y;
                float m02 = proj.columns[2].x, m12 = proj.columns[2].y;
                if (fabsf(m00) > 1e-6f && fabsf(m11) > 1e-6f) {
                    pose.tangents[e][0] = (m02 - 1.0f) / m00;   // left
                    pose.tangents[e][1] = (m02 + 1.0f) / m00;   // right
                    pose.tangents[e][2] = (m12 - 1.0f) / m11;   // bottom
                    pose.tangents[e][3] = (m12 + 1.0f) / m11;   // top
                } else {
                    // No projection to recover (simulator identity): a plain 90-
                    // degree symmetric frustum, stated rather than silently zero.
                    pose.tangents[e][0] = -1.0f; pose.tangents[e][1] = 1.0f;
                    pose.tangents[e][2] = -1.0f; pose.tangents[e][3] = 1.0f;
                }
                if (q3e_vrSynthTanOn)
                    memcpy(pose.tangents[e], q3e_vrSynthTan, sizeof(float) * 4);
                memcpy(q3e_vrEyeTangents[e], pose.tangents[e], sizeof(float) * 4);
            }
        }

        long poseId = q3e_vr_publish(&pose);
        int fresh = q3e_vr_wait_rendered(poseId);

        // Present-mode arbitration. Recording WHICH term failed is the whole
        // point: a panel shown for an unnamed reason is indistinguishable from a
        // broken world view, and that cost a sibling port an entire round.
        int pairs = VK_Get3DPairs();
        // "Do I have per-eye imagery to present?" — and nothing else. Asking
        // whether the engine has ADVANCED its pair counter is a different
        // question with the same answer only when the rendezvous is fresh: on a
        // timeout the counter moves while no copy is taken, and a WORLD verdict
        // then presents a texture that does not exist yet.
        int worldReady = (q3e_vr_eyeCopy[0] != nil && q3e_vr_eyeCopy[1] != nil);
        // THE HARD INVARIANT: a WORLD frame requires the ENGINE'S VR PATH to be
        // ARMED — pose composition, external tangents, VR frustum and near plane
        // — and imagery that was rendered against a published pose. Not merely
        // "imagery exists". r_stereo3d is armed from the first moment of entry,
        // so the engine fills the same per-eye snapshot images with its ordinary
        // FLAT view for the whole pre-commit second; presenting that as the world
        // is what a device round saw as a doubled, head-locked image (two
        // panel-convergence views mistaken for eye buffers). This is the second
        // too-loose readiness predicate in this loop, so it is stated as an
        // invariant and asserted by the suite on every dump it reads:
        // present=world implies vr=on.
        const int vrArmed = VK_GetVRActive();
        const int posed = (q3e_vr_haveBase && q3e_vrRenderedId > 0);
        int reason = q3e_vrClientReason;
        if (reason == Q3E_VRP_WORLD && !worldReady)
            reason = Q3E_VRP_NO_EYES;
        else if (reason == Q3E_VRP_WORLD && !(vrArmed && posed))
            reason = Q3E_VRP_NOT_ARMED;
        int world = (reason == Q3E_VRP_WORLD);
        q3e_vrPresentReason = reason;
        q3e_vrPresentWorld = world;
        if (reason != lastReason) {
            Q3E_BlackBox_Pin("vr: present mode -> %s (%s) at frame %d",
                             world ? "WORLD" : "PANEL",
                             Q3E_VR_PresentReasonString(reason), q3e_vrFrameCount);
            lastReason = reason;
        }

        id<MTLCommandBuffer> command_buffer = [queue commandBuffer];

        // Copy the finished pair — colour AND depth together, and the panel
        // source with them, into textures WE own.
        //
        // The engine's images are MoltenVK-backed and a vid_restart destroys
        // them while this thread runs: during VR entry (phase 2 restarts the
        // renderer at the per-eye size), on any video-settings change, and on
        // the way out. So every resolve is bracketed by the renderer's
        // generation counter, the copy rides its OWN command buffer, and that
        // buffer is only committed if the generation held still across it —
        // an abandoned command buffer costs a frame, a committed one that
        // references freed textures costs the app.
        const int genBefore = q3e_render_gen;
        const int renderLive = q3e_render_live;
        int copied = 0;
        int uiCopied = -1;      // the UI frame counter this copy captured, if any
        // What the ENGINE decided this frame's 2D would go into. Read once so
        // every consumer below sees the same answer.
        const int engineRedirect = VK_GetVRUIRedirect();
        if (renderLive && ((fresh && pairs != q3e_vr_lastPairs) || q3e_vr_panelCopy == nil)) {
            id<MTLCommandBuffer> copyBuf = [queue commandBuffer];
            id<MTLBlitCommandEncoder> blit = nil;
            if (fresh && pairs != q3e_vr_lastPairs) {
                for (int e = 0; e < 2; e++) {
                    id<MTLTexture> src = (__bridge id<MTLTexture>)VK_Get3DEyeMTLTexture(e);
                    if (!src) continue;
                    q3e_vr_eyeCopy[e] = q3e_vr_ensure_copy(src, q3e_vr_eyeCopy[e]);
                    if (!blit) blit = [copyBuf blitCommandEncoder];
                    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0
                             sourceOrigin:MTLOriginMake(0, 0, 0)
                               sourceSize:MTLSizeMake(src.width, src.height, 1)
                                toTexture:q3e_vr_eyeCopy[e] destinationSlice:0 destinationLevel:0
                        destinationOrigin:MTLOriginMake(0, 0, 0)];
                    id<MTLTexture> dsrc = (__bridge id<MTLTexture>)VK_Get3DEyeDepthMTLTexture(e);
                    if (dsrc) {
                        q3e_vr_depthCopy[e] = q3e_vr_ensure_copy(dsrc, q3e_vr_depthCopy[e]);
                        [blit copyFromTexture:dsrc sourceSlice:0 sourceLevel:0
                                 sourceOrigin:MTLOriginMake(0, 0, 0)
                                   sourceSize:MTLSizeMake(dsrc.width, dsrc.height, 1)
                                    toTexture:q3e_vr_depthCopy[e] destinationSlice:0 destinationLevel:0
                            destinationOrigin:MTLOriginMake(0, 0, 0)];
                    }
                }
            }
            // The UI layer: the 2D stream the engine separated out of the eyes,
            // on a transparent ground. Copied on the same buffer as the eyes so
            // the HUD a frame shows is the HUD that frame drew.
            // The UI layer rides the SAME condition as the eyes — a fresh
            // rendezvous — for two reasons that both matter. It is the fresh
            // path that has passed through VK_WaitLastFrameGPU, so copying
            // outside it can read the layer while the engine's GPU is still
            // writing it (a torn HUD). And without it, entering VR mid-match
            // re-blits the same full-extent texture on every compositor frame
            // forever, because the counter has moved but the copy is never
            // acknowledged.
            if (fresh && pairs != q3e_vr_lastPairs && VK_GetVRUIRedirect()) {
                int uif = VK_GetVRUIFrames();
                if (uif != q3e_vr_lastUIFrames) {
                    id<MTLTexture> usrc = (__bridge id<MTLTexture>)VK_GetVRUIMTLTexture();
                    if (usrc) {
                        q3e_vr_uiCopy = q3e_vr_ensure_copy(usrc, q3e_vr_uiCopy);
                        if (!blit) blit = [copyBuf blitCommandEncoder];
                        [blit copyFromTexture:usrc sourceSlice:0 sourceLevel:0
                                 sourceOrigin:MTLOriginMake(0, 0, 0)
                                   sourceSize:MTLSizeMake(usrc.width, usrc.height, 1)
                                    toTexture:q3e_vr_uiCopy destinationSlice:0 destinationLevel:0
                            destinationOrigin:MTLOriginMake(0, 0, 0)];
                        uiCopied = uif;
                    }
                }
            }
            // The panel's source is the mono framebuffer, resolved the same way
            // and therefore fragile the same way; the render pass only ever
            // samples our own copies.
            //
            // Skipped while presenting the world: with the 2D redirect armed the
            // mono framebuffer holds the SEPARATED 2D, not a composite, and
            // copying it would leave the panel holding a HUD-on-black image for
            // the first frame after the player opens a menu.
            // Gated on the ENGINE's redirect state, which is the thing that
            // decides what the mono framebuffer CONTAINS — not on the
            // compositor's world/panel verdict, which is a different question
            // sampled at a different moment. They disagree during VR entry
            // warm-up and across menu transitions on a !fresh frame, and in
            // those windows the old gate either copied HUD-on-transparent into
            // the panel or refused to refresh it at all, so pressing ESC could
            // show a minutes-old image of the game.
            id<MTLTexture> mono = engineRedirect ? nil : (__bridge id<MTLTexture>)VK_Get3DColorMTLTexture();
            if (mono) {
                q3e_vr_panelCopy = q3e_vr_ensure_copy(mono, q3e_vr_panelCopy);
                if (!blit) blit = [copyBuf blitCommandEncoder];
                [blit copyFromTexture:mono sourceSlice:0 sourceLevel:0
                         sourceOrigin:MTLOriginMake(0, 0, 0)
                           sourceSize:MTLSizeMake(mono.width, mono.height, 1)
                            toTexture:q3e_vr_panelCopy destinationSlice:0 destinationLevel:0
                    destinationOrigin:MTLOriginMake(0, 0, 0)];
            }
            if (blit) [blit endEncoding];
            if (q3e_render_gen == genBefore && q3e_render_live) {
                [copyBuf commit];
                copied = 1;
                // Acknowledged HERE, where the copy was actually committed. Under
                // the old placement an abandoned command buffer still advanced
                // the counter, so a copy that never happened was recorded as one
                // that had, and the next real change was skipped.
                if (uiCopied >= 0) { q3e_vr_lastUIFrames = uiCopied; q3e_vr_uiCopies++; }
            } else {
                uiCopied = -1;
                q3e_vr_restartSkips++;   // abandoned, never committed
                if (q3e_vr_restartSkips == 1)
                    Q3E_BlackBox_Pin("vr: renderer restarted mid-copy at frame %d — copy "
                                     "abandoned rather than committed against freed images",
                                     q3e_vrFrameCount);
            }
        }
        // Did the imagery this frame will PRESENT get taken this frame? That —
        // not "was the rendezvous fresh" — is what decides which anchor is the
        // truthful one to submit.
        //
        // The two questions differ whenever the rendezvous came back fresh but no
        // copy was taken: the engine restarted the renderer mid-copy, or the pair
        // counter did not move. The old code submitted THIS frame's anchor in
        // those cases while presenting the PREVIOUS frame's eyes, and the
        // compositor then reprojects a frame from a pose it was never rendered
        // at. Depth-dependent error, invisible while the head is still, warping
        // during motion, worst at the depth discontinuities where it changes
        // fastest. Exactly the report.
        // A panel copy taken while the redirect was armed is not a panel; drop
        // it at the transition rather than show it once.
        if (engineRedirectPrev != engineRedirect) {
            engineRedirectPrev = engineRedirect;
            if (engineRedirect) q3e_vr_panelCopy = nil;
        }

        const int freshImagery = (copied && fresh && pairs != q3e_vr_lastPairs);
        if (freshImagery) {
            q3e_vr_lastPairs = pairs;
            prevAnchorTransform = originFromDevice;
            havePrevAnchor = 1;
            prevAnchor = anchor;
        } else {
            // Re-present the previous pair against ITS anchor. A dropped frame
            // costs latency, never a jolt.
            if (!fresh) q3e_vrRepresents++;
            else if (havePrevAnchor) q3e_vr_staleAnchor++;
        }

        // The engine's live brightness treatment, re-read every frame so a change
        // in the menu reaches the compositor without a renderer restart.
        float gradeInvGamma = 1.0f, gradeOb = 1.0f;
        VK_GetGammaOverbright(&gradeInvGamma, &gradeOb);
        q3e_vrGammaInv = gradeInvGamma;
        q3e_vrOverbright = gradeOb;

        q3e_vrDepthWanted = 1;
        q3e_vrDepthLive = VK_Get3DDepthLive();
        q3e_vrDepthCopies = VK_Get3DDepthCopies();

        // THE INVARIANT: the anchor submitted with a drawable is the anchor the
        // imagery on it was rendered against. Never a fresher re-query.
        ar_device_anchor_t anchorToPresent = (freshImagery || !havePrevAnchor) ? anchor : prevAnchor;
        cp_drawable_set_device_anchor(drawable, anchorToPresent);
        // Everything placed in this frame is placed against the SAME head
        // transform the anchor above names, for the same reason.
        const simd_float4x4 headForPresent =
            (freshImagery || !havePrevAnchor) ? originFromDevice : prevAnchorTransform;

        id<MTLTexture> monoTex = q3e_vr_panelCopy;
        simd_float4x4 panelModel = matrix_identity_float4x4;
        simd_float2   panelFit = simd_make_float2(1.0f, 1.0f);
        // The freshness contract, enforced rather than promised. `cg_draw2D 0`,
        // a mod that draws no 2D, or any stall in the redirect otherwise leaves
        // the last HUD hanging head-locked in the world forever — which looks
        // exactly like a working HUD, and is the one failure a screenshot cannot
        // tell from success. The tolerance is generous (half a second) so a
        // legitimately static HUD never flickers; what it catches is a layer that
        // has STOPPED.
        if (uiCopied >= 0) uiFreshAt = CACurrentMediaTime();
        const int uiFresh = (uiFreshAt > 0.0 && (CACurrentMediaTime() - uiFreshAt) < 0.5);
        // R2.1 fix 11: deliberately requires only the REGION pipeline, not the
        // fallback one too — the fallback pipeline's own draw call degrades
        // gracefully (full texture through the region pipeline) when it is
        // missing, so gating this on BOTH would black out the dedicated HUD
        // quads over a failure that only affects the fallback/scoreboard
        // quad, which is exactly backwards.
        const int uiReady = (world && uiFresh && q3e_vr_uiCopy != nil && q3e_vr_regionPipeline != nil);
        // Published so the gate can be asserted directly. "The counter stopped"
        // and "the quad stopped being drawn" are two different claims, and only
        // the second one is the thing a player would see.
        q3e_vrUIQuadDrawn = uiReady;

        // R2 item 4: the single UI quad becomes several independent, angularly
        // placed region quads sampling sub-rects of the SAME redirect texture,
        // plus one fallback/scoreboard quad carrying everything else (mods
        // included) at a size bigger than the old whole-HUD box, masked so it
        // does not double-show what the dedicated quads already draw. All
        // distances share 1.75 m so the eyes never re-focus moving between
        // them, same as the donor's HUD/message panels.
        q3e_vr_region_t regions[Q3E_VR_RGN_COUNT];
        memset(regions, 0, sizeof(regions));
        simd_float4x4 fallbackModel = matrix_identity_float4x4;
        // R2.2 fix 6: zero-initialised and ALWAYS bound at its full size. The
        // count is what the shader loops to, and a frame with nothing to
        // exclude — every PM_DEAD and intermission frame, which fix 7's
        // carve-suppression made reachable for the first time — used to bind
        // this with length 0, which Metal API validation rejects outright. A
        // crash on the player's first death, in exactly the Debug/Instruments
        // builds the feel work is verified in.
        simd_float4   fallbackExcl[Q3E_VR_EXCL_MAX] = {0};
        int           fallbackExclN = 0;
        // R2.2 fix 14b: the published region telemetry is cleared HERE, before
        // the carve block that may or may not run. It used to be written only
        // inside that block, so a scoreboard/dead/!uiReady frame published
        // regionsdrawn=0 next to the LAST HUD frame's row counts and crosshair
        // box — a dump that contradicts itself, and row assertions that could
        // certify a frame in which the row sizing code never ran.
        q3e_vrNotifyRows = 0.0f;
        q3e_vrMessageRows = 0.0f;
        q3e_vrStatusRows = 0.0f;
        q3e_vrStatusTopRow = 0.0f;
        q3e_vrStatusPitch = 0.0f;
        q3e_vrXhairBoxCX = 0.0f;
        q3e_vrXhairBoxCY = 0.0f;
        q3e_vrXhairBoxHalf = 0.0f;
        // R2.1 fix 7: an honest, engine-visible signal that the frame is
        // probably a scoreboard/death overlay (PM_DEAD, or either
        // intermission state — see Q3E_VR_ScoreboardLikely's own comment for
        // what this does NOT catch: the interactive hold-TAB scoreboard has
        // no engine-visible signal without a cgame syscall this project never
        // adds). The four fixed 640x480 boxes below are tuned for the
        // ORDINARY HUD layout and tear exactly this kind of full-screen
        // content across them — the honest fix for THIS round is to stop
        // carving when the frame is not the ordinary HUD, and show the whole
        // texture on the center/fallback quad instead.
        const int scoreboardUp = Q3E_VR_ScoreboardLikely();
        q3e_vrScoreboardUp = scoreboardUp;
        // The crosshair's source box. The engine's 2D crosshair is NEVER drawn
        // in a VR world frame any more (R2.3 fix 1): it is placed by the flat
        // screen's geometry and is wrong in a headset by construction — the
        // world-space aim marker is the only crosshair. The box is still
        // MEASURED, because every quad that would otherwise show it has to
        // carve it out, and because the box is the assertion surface. Measured
        // OUTSIDE the region block below, so a scoreboard/death frame — where
        // no region draws and the whole texture goes on the fallback quad —
        // still carves it.
        simd_float4 xhairCarve = simd_make_float4(0.0f, 0.0f, 0.0f, 0.0f);
        int         xhairCarved = 0;
        if (uiReady) {
            {
                float chSize = 24.0f, chX = 0.0f, chY = 0.0f;
                Q3E_VR_GetCrosshairCvars(&chSize, &chX, &chY);
                if (chSize < 4.0f) chSize = 4.0f;
                if (chSize > 128.0f) chSize = 128.0f;
                // R2.2 fix 14a: the box is CLAMPED TO THE CANVAS. Legal cvar
                // values push it off the 640x480 virtual screen on their own —
                // cg_crosshairSize 128 (this code's own accepted ceiling) asks
                // for a 264 px half-size around row 240, which starts 24 rows
                // above the top edge — and a UV rect outside [0,1] does not
                // sample nothing: a clamp-to-edge sampler replicates the
                // texture's border rows across the quad. The same out-of-range
                // rect was also handed to the exclusion mask, carving a hole in
                // the wrong place.
                float chHalfPx = chSize * 2.0f + 8.0f;   // contains the 2x pulse + slop
                float chCenterX = 320.0f + chX;
                float chCenterY = 240.0f + chY;
                chCenterX = fminf(fmaxf(chCenterX, 4.0f), 636.0f);
                chCenterY = fminf(fmaxf(chCenterY, 4.0f), 476.0f);
                chHalfPx = fminf(chHalfPx, fminf(fminf(chCenterX, 640.0f - chCenterX),
                                                 fminf(chCenterY, 480.0f - chCenterY)));
                if (chHalfPx < 4.0f) chHalfPx = 4.0f;
                xhairCarve = q3e_vr_uv(chCenterX - chHalfPx, chCenterY - chHalfPx,
                                       chHalfPx * 2.0f, chHalfPx * 2.0f);
                q3e_vrXhairBoxCX = chCenterX; q3e_vrXhairBoxCY = chCenterY; q3e_vrXhairBoxHalf = chHalfPx;
            }
            xhairCarved = 1;
        }
        if (uiReady && !scoreboardUp && q3e_vrHudPos != Q3E_VRHUD_OFF) {
            const float dist = 1.75f;
            // `hs` scales each quad's own angular EXTENT — how much of the view
            // the element covers (R3.1 item 2). Angles are scaled (not the
            // linear half-extents) so "1.5x" means 1.5x as wide, which is what
            // the eye reads, and each result is clamped short of the tangent
            // singularity so a large setting cannot produce an infinite quad.
            //
            // `hh` translates the whole cluster up or down (R3.2 item 2), in
            // degrees, added to every band's pitch and to no band's extent —
            // that is what makes the HUD move as ONE thing rather than three
            // that drift apart. The spread between the bands is fixed
            // (Q3E_VR_HUD_SPREAD), so their relative layout, and therefore the
            // proof that they never overlap, is independent of the slider.
            const float hs = q3e_vrHudSize;
            const float hh = q3e_vrHudHeight;
            const float ps = Q3E_VR_HUD_SPREAD;
            // Statusbar: the bottom 52 virtual rows, low (donor 'Low') or high
            // anchor per q3evrhud, off hides the quad AND its fallback hole.
            // R2.1 fix 10: High was 14 degrees, which put its ~2.7 degree
            // half-height band at [11.3,16.7] — overlapping BOTH the message
            // band below it ([9.2,14.8] at the time) and, marginally, the
            // notify band above it. Re-anchored to 24 degrees, clear of both.
            //
            // The band's TOP edge has moved three times as the device rounds
            // found the elements it was cutting — 416, then 428 (R2.3 fix 1,
            // the lower-right score boxes), then 372 (R3.2 item 3, the status
            // face and the team strip), and now 356 (R4.2 item 1, the weapon
            // name and the first powerup icon). The reasoning and the full row
            // table live with Q3E_VR_HUD_STATUS_TOP; the rule they all share is
            // that a boundary through the middle of an element draws that
            // element twice, at two scales, a quarter of the view apart.
            {
                const float rows = 480.0f - Q3E_VR_HUD_STATUS_TOP;
                const float halfW = q3e_vr_tan_deg(dist, q3e_vr_clamp_deg(25.0f * hs));
                const float halfH = halfW * (rows / 640.0f);
                // Bottom-edge anchored, then translated by the height slider —
                // see Q3E_VR_HUD_STATUS_BOTTOM_DEG for why the bottom and not
                // the centre.
                const float pitchDeg =
                    q3e_vr_band_pitch(dist, Q3E_VR_HUD_STATUS_BOTTOM_DEG, halfH) + hh;
                regions[Q3E_VR_RGN_STATUSBAR].uv =
                    q3e_vr_uv(0.0f, Q3E_VR_HUD_STATUS_TOP, 640.0f, rows);
                regions[Q3E_VR_RGN_STATUSBAR].model =
                    q3e_vr_region_anchor(headForPresent, dist, 0.0f, q3e_vr_clamp_deg(pitchDeg),
                                         halfW, halfH);
                regions[Q3E_VR_RGN_STATUSBAR].draw = true;
                q3e_vrStatusRows = rows;
                q3e_vrStatusTopRow = Q3E_VR_HUD_STATUS_TOP;
                q3e_vrStatusPitch = q3e_vr_clamp_deg(pitchDeg);
            }
            // Chat/notify: top rows, pushed upper-LEFT (spread wide — eyes
            // prefer widescreen, donor ~34-40 degrees) and higher than the R1
            // single-box placement ever put it.
            // R2.1 fix 7: the source rect grows from 64 to 80 virtual rows —
            // a 16-row overlap margin past the old hard edge — because
            // callvote text (drawn around row 58) sits close enough to the
            // old boundary that a multi-line vote could be guillotined at
            // exactly row 64. Placement (yaw/pitch) is unchanged; only the
            // sampled rect and its matching angular height grow.
            {
                const float halfW = q3e_vr_tan_deg(dist, q3e_vr_clamp_deg(15.0f * hs));
                regions[Q3E_VR_RGN_NOTIFY].uv = q3e_vr_uv(0.0f, 0.0f, 640.0f, 80.0f);
                regions[Q3E_VR_RGN_NOTIFY].model =
                    q3e_vr_region_anchor(headForPresent, dist,
                                         q3e_vr_clamp_deg(-20.0f * ps),
                                         q3e_vr_clamp_deg(18.0f * ps + hh),
                                         halfW, halfW * (80.0f / 640.0f));
                regions[Q3E_VR_RGN_NOTIFY].draw = true;
                q3e_vrNotifyRows = 80.0f;
            }
            // Frag/obituary/centreprint band, upper-centre.
            // R2.1 fix 7: the source rect's bottom edge grows from row 160 —
            // named by the review as a row a 3-line centerprint can straddle
            // — to row 244, an 84-row margin. Growing a box symmetrically
            // around its old anchor would have pushed its TOP edge up into
            // the notify band above it, so the anchor also moves down (12 ->
            // 9 degrees) to keep the enlarged box clear of both neighbours —
            // verified below, not just moved and hoped.
            //
            // R2.3 fix 1: the band starts at row 80, not row 64. Rows 64..80
            // are inside the NOTIFY rect above, and every one of them was
            // therefore being drawn twice — once in the chat quad up and to
            // the left, once again in the centre band. Region rects are a
            // PARTITION of the source now, not four boxes that happen to be
            // near the right places.
            {
                const float halfW = q3e_vr_tan_deg(dist, q3e_vr_clamp_deg(18.0f * hs));
                regions[Q3E_VR_RGN_MESSAGE].uv = q3e_vr_uv(0.0f, 80.0f, 640.0f, 164.0f);
                regions[Q3E_VR_RGN_MESSAGE].model =
                    q3e_vr_region_anchor(headForPresent, dist, 0.0f,
                                         q3e_vr_clamp_deg(9.0f * ps + hh),
                                         halfW, halfW * (164.0f / 640.0f));
                regions[Q3E_VR_RGN_MESSAGE].draw = true;
                q3e_vrMessageRows = 164.0f;
            }
            // The crosshair box is carved out of every region that reaches it
            // (the message band does, at its bottom edge) as well as out of
            // the fallback quad below.
            for (int r = 0; r < Q3E_VR_RGN_COUNT; r++) {
                if (!regions[r].draw) continue;
                q3e_vr_carve(regions[r].excl, &regions[r].exclN, regions[r].uv, xhairCarve);
            }
        }
        // R3.2 item 4: HUD Off means no head-locked HUD, and the fallback quad
        // is head-locked HUD too whenever it is carrying the ordinary layer —
        // leaving it up would have moved the whole HUD to the centre of the
        // view rather than removed it, which is what the old "Off" (the
        // statusbar quad alone) effectively did. The scoreboard and death
        // overlay are NOT the HUD and still draw: they are the frames the
        // fallback quad exists for.
        const int drawFallback = (q3e_vrHudPos != Q3E_VRHUD_OFF) || scoreboardUp;
        if (uiReady && drawFallback) {
            // Fallback/scoreboard: the WHOLE texture, centred and bigger than
            // the old box (28/22 degrees vs 18/15), scaled by the same HUD
            // SIZE the region quads use — and by that one only: this quad is
            // centred on the view by construction, so there is no offset for
            // Panel Size to scale and applying it here would silently make
            // "spread the corners out" also mean "grow the scoreboard".
            //
            // Minus the rects above when they are actually drawing something
            // to exclude (R2.1 fix 5 — see below),
            // and minus the crosshair box (R2.3 fix 1) whether or not any
            // region drew; with nothing else drawn (HUD Off, or the
            // scoreboard/death-overlay carve-suppression above) it carries
            // everything except the crosshair.
            const float dist = 1.75f;
            const float fbAspect = (q3e_vr_uiCopy.width > 0)
                                     ? (float)q3e_vr_uiCopy.height / (float)q3e_vr_uiCopy.width
                                     : (9.0f / 16.0f);
            const float fbHalfW = q3e_vr_quad_half_width(dist, fbAspect,
                                     q3e_vr_clamp_deg(28.0f * q3e_vrHudSize) * (float)M_PI / 180.0f,
                                     q3e_vr_clamp_deg(22.0f * q3e_vrHudSize) * (float)M_PI / 180.0f);
            q3e_vr_uiDist = dist;
            q3e_vr_uiHalfW = fbHalfW;
            q3e_vr_uiHalfH = fbHalfW * fbAspect;
            fallbackModel = q3e_vr_panel_anchor(headForPresent, dist, fbHalfW, fbAspect,
                                                false, &q3e_vr_uiVerticalLatch);
            // R2.1 fix 5: EXCLUDE a region only when it is actually DRAWING —
            // the statusbar used to be excluded unconditionally ("Off hides
            // it too"), which meant the bottom 64 virtual rows rendered
            // NOWHERE with HUD Off: the spectator banner, team chat rows,
            // scoreboard rows and any mod HUD element living down there
            // vanished along with the statusbar, carved out of the fallback
            // quad by a hole nothing was filling.
            int rd = 0;
            for (int r = 0; r < Q3E_VR_RGN_COUNT; r++) {
                if (!regions[r].draw) continue;
                if (fallbackExclN < Q3E_VR_EXCL_MAX)
                    fallbackExcl[fallbackExclN++] = regions[r].uv;
                rd++;
            }
            // The crosshair is carved even on a scoreboard/death frame, where
            // no region drew at all: "the engine's 2D crosshair is never
            // visible in a VR world frame" is a property of the mode, not of
            // whichever quads happen to be up.
            if (xhairCarved && fallbackExclN < Q3E_VR_EXCL_MAX)
                fallbackExcl[fallbackExclN++] = xhairCarve;
            q3e_vrRegionsDrawn = rd;
            q3e_vrExclCount = fallbackExclN;
        } else {
            q3e_vrRegionsDrawn = 0;
            q3e_vrExclCount = 0;
        }

        if (!world) {
            simd_float4x4 headNow = headForPresent;
            float contentAspect = (monoTex && monoTex.width > 0)
                             ? (float)monoTex.height / (float)monoTex.width : (9.0f / 16.0f);
            if (!q3e_vr_havePanel && q3e_vrFrameCount > 10) {
                q3e_vr_panelHead = headNow;
                q3e_vr_havePanel = true;
                Q3E_BlackBox_Pin("vr: panel anchored (non-world frames are shown on it)");
            }
            // R2 item 5: a WIDESCREEN frame (68 x 48 degrees at 2.6 m) with the
            // near-square composite LETTERBOXED inside it at its own aspect,
            // rather than a quad shaped to match the composite (which is what
            // R1 shipped, and what the R2 device round reported as still
            // cropping — content sized to reach the very edge of its own
            // quad, no margin at all). `fit` (<=1 on whichever axis the
            // composite is relatively narrower on) shrinks the drawn geometry
            // to the content's own shape before the frame's transform lands,
            // so the WHOLE composite shows undistorted, centred, with a
            // deliberate ~4% margin rather than touching the frame's edges.
            const float dist = 2.6f;
            const float outerHalfW = q3e_vr_tan_deg(dist, 34.0f);
            const float outerHalfH = q3e_vr_tan_deg(dist, 24.0f);
            const float outerAspect = outerHalfH / outerHalfW;
            const float kSafetyShrink = 0.96f;
            if (contentAspect > outerAspect) {
                panelFit.x = (outerAspect / contentAspect) * kSafetyShrink;
                panelFit.y = kSafetyShrink;
            } else {
                panelFit.x = kSafetyShrink;
                panelFit.y = (contentAspect / outerAspect) * kSafetyShrink;
            }
            q3e_vr_panelDist = dist; q3e_vr_panelAspect = contentAspect;
            q3e_vr_panelHalfW = outerHalfW * panelFit.x;
            q3e_vr_panelHalfH = outerHalfH * panelFit.y;
            panelModel = q3e_vr_panel_anchor(q3e_vr_havePanel ? q3e_vr_panelHead : headNow,
                                             dist, outerHalfW, outerAspect, true, NULL);
            // R2.3 fix 4: ONE line, on entry to the panel and again whenever
            // the source extent moves, carrying every number the placement was
            // computed from — the quad the player is looking at, the texture
            // rect it samples, the engine extent that texture came from, and
            // the widest 4:3 box Quake III's own menu code can draw inside
            // that extent. If an eye and this line ever disagree again, the
            // next report can say WHICH of them is wrong instead of "cropped".
            {
                const int srcW = (monoTex ? (int)monoTex.width : 0);
                const int srcH = (monoTex ? (int)monoTex.height : 0);
                if (srcW != q3e_vr_panelDumpW || srcH != q3e_vr_panelDumpH) {
                    q3e_vr_panelDumpW = srcW; q3e_vr_panelDumpH = srcH;
                    // What the ui QVM can actually reach: it scales by
                    // height/480 on both axes, so it draws a box of
                    // 640*srcH/480 x srcH from the left edge. Anything past
                    // srcW of that box is clipped by the engine and lost.
                    const float uiDrawnW = (srcH > 0) ? (640.0f * (float)srcH / 480.0f) : 0.0f;
                    const float uiVisible = (uiDrawnW > 1.0f)
                                              ? fminf(1.0f, (float)srcW / uiDrawnW) : 0.0f;
                    Q3E_BlackBox_Pin("vr PANELQUAD: src=%dx%dpx aspect=%.4f engine=%dx%dpx | "
                                     "quad d=%.2fm outer=(hw%.3f,hh%.3f)m fit=(%.3f,%.3f) "
                                     "drawn=(hw%.3f,hh%.3f)m = %.1fx%.1fdeg | uv=(0,0,1,1) | "
                                     "menu drawn %0.f px wide, %.1f%% of it fits (100%% = whole menu)",
                                     srcW, srcH, (srcW > 0) ? (float)srcH / (float)srcW : 0.0f,
                                     q3e_vrEngineW, q3e_vrEngineH,
                                     dist, outerHalfW, outerHalfH, panelFit.x, panelFit.y,
                                     q3e_vr_panelHalfW, q3e_vr_panelHalfH,
                                     2.0f * atanf(q3e_vr_panelHalfW / dist) * 180.0f / (float)M_PI,
                                     2.0f * atanf(q3e_vr_panelHalfH / dist) * 180.0f / (float)M_PI,
                                     uiDrawnW, uiVisible * 100.0f);
                }
            }
        }

        size_t nRateMaps = cp_drawable_get_rasterization_rate_map_count(drawable);
        for (size_t v = 0; v < views; v++) {
            cp_view_t view = cp_drawable_get_view(drawable, v);
            cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
            size_t texIdx = cp_view_texture_map_get_texture_index(tmap);
            size_t slice  = cp_view_texture_map_get_slice_index(tmap);
            MTLViewport vp = cp_view_texture_map_get_viewport(tmap);

            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = cp_drawable_get_color_texture(drawable, texIdx);
            pass.colorAttachments[0].slice = slice;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
            id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, texIdx);
            if (depth) {
                pass.depthAttachment.texture = depth;
                pass.depthAttachment.slice = slice;
                pass.depthAttachment.loadAction = MTLLoadActionClear;
                pass.depthAttachment.storeAction = MTLStoreActionStore;
                pass.depthAttachment.clearDepth = 0.0;   // reverse-Z: 0 is infinity
            }
            if (nRateMaps > 0)
                pass.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(
                    drawable, texIdx < nRateMaps ? texIdx : 0);

            id<MTLRenderCommandEncoder> enc = [command_buffer renderCommandEncoderWithDescriptor:pass];
            [enc setViewport:vp];      // the LOGICAL viewport: that is the contract

            int eye = (v < 2) ? (int)v : 1;
            id<MTLTexture> src = world ? q3e_vr_eyeCopy[eye] : monoTex;
            // A WORLD verdict with nothing to draw is a black frame in full
            // immersion. It cannot happen while the arbitration resets on entry,
            // which is exactly why it is COUNTED rather than assumed.
            if (world && !src) q3e_vr_blindWorld++;
            if (src) {
                float decode = (q3e_vr_drawableLinear &&
                                (src.pixelFormat == MTLPixelFormatBGRA8Unorm ||
                                 src.pixelFormat == MTLPixelFormatRGBA8Unorm)) ? 1.0f : 0.0f;
                // The engine's own gamma pass, reproduced: it lives in the blit to
                // the swapchain, and nothing here goes through the swapchain.
                simd_float3 grade = simd_make_float3(decode, gradeInvGamma, gradeOb);
                if (world) {
                    id<MTLTexture> dep = q3e_vr_depthCopy[eye];
                    if (dep && q3e_vr_eyePipeline) {
                        [enc setRenderPipelineState:q3e_vr_eyePipeline];
                        [enc setDepthStencilState:q3e_vr_depthWrite];
                        [enc setFragmentTexture:src atIndex:0];
                        [enc setFragmentTexture:dep atIndex:1];
                        // R3.1 item 3: the sky's depth floor (see the shader's
                        // own comment). Bound per draw rather than baked into
                        // the shader so `q3evrdepthfloor 0` can put the old
                        // behaviour back on glass and prove the causality
                        // instead of asserting it.
                        [enc setFragmentBytes:&q3e_vrEyeDepthFloor
                                       length:sizeof(q3e_vrEyeDepthFloor) atIndex:1];
                        // R4.3 item 2: the sharpen amount and the SOURCE
                        // texel size — the engine's eye image, not the
                        // drawable's, because that is the grid the kernel
                        // steps across. Bound per draw for the same reason
                        // the depth floor is: a row that can be moved from
                        // the console can be A/B'd on glass in one command.
                        simd_float4 sharpen = simd_make_float4(
                            q3e_vrSharpen,
                            (src.width  > 0) ? 1.0f / (float)src.width  : 0.0f,
                            (src.height > 0) ? 1.0f / (float)src.height : 0.0f,
                            0.0f);
                        [enc setFragmentBytes:&sharpen length:sizeof(sharpen) atIndex:2];
                    } else if (q3e_vr_eyePipelineNoDepth) {
                        [enc setRenderPipelineState:q3e_vr_eyePipelineNoDepth];
                        [enc setFragmentTexture:src atIndex:0];
                    }
                    [enc setFragmentBytes:&grade length:sizeof(grade) atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                } else if (q3e_vr_letterboxPipeline) {
                    // R2 item 5: the letterboxed menu panel — mvp carries the
                    // WIDE frame, `panelFit` shrinks the drawn geometry to the
                    // composite's own aspect inside it.
                    simd_float4x4 deviceFromEye = cp_view_get_transform(view);
                    simd_float4x4 eyeFromOrigin =
                        simd_inverse(simd_mul(headForPresent, deviceFromEye));
                    simd_float4x4 proj = matrix_identity_float4x4;
                    if (__builtin_available(visionOS 2.0, *))
                        proj = cp_drawable_compute_projection(drawable,
                                   cp_axis_direction_convention_right_up_back, v);
                    simd_float4x4 mvp = simd_mul(proj, simd_mul(eyeFromOrigin, panelModel));
                    [enc setRenderPipelineState:q3e_vr_letterboxPipeline];
                    [enc setDepthStencilState:q3e_vr_depthWrite];
                    [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
                    [enc setVertexBytes:&panelFit length:sizeof(panelFit) atIndex:1];
                    [enc setFragmentTexture:src atIndex:0];
                    [enc setFragmentBytes:&grade length:sizeof(grade) atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                }
            }

            // R2 item 4: the head-locked 2D layer, over the world, in the same
            // pass — one texture (the engine's own separated 2D stream), many
            // quads. Each writes REAL depth at ITS OWN 1.75 m convergence (so
            // the compositor reprojects it as an object at arm's length) and
            // compares ALWAYS (so a HUD element is never lost inside a wall).
            // This is the whole in-VR UI: HUD, scoreboard, chat, centreprints
            // and any mod HUD, because it is the engine's own 2D stream and
            // the engine does not know or care which of those drew it — the
            // fallback quad below is what guarantees that.
            if (uiReady) {
                simd_float4x4 deviceFromEye = cp_view_get_transform(view);
                simd_float4x4 eyeFromOrigin =
                    simd_inverse(simd_mul(headForPresent, deviceFromEye));
                simd_float4x4 proj = matrix_identity_float4x4;
                if (__builtin_available(visionOS 2.0, *))
                    proj = cp_drawable_compute_projection(drawable,
                               cp_axis_direction_convention_right_up_back, v);
                float uiDecode = (q3e_vr_drawableLinear &&
                                  (q3e_vr_uiCopy.pixelFormat == MTLPixelFormatBGRA8Unorm ||
                                   q3e_vr_uiCopy.pixelFormat == MTLPixelFormatRGBA8Unorm)) ? 1.0f : 0.0f;
                simd_float3 uiGrade = simd_make_float3(uiDecode, gradeInvGamma, gradeOb);

                // R2.1 fix 11: `uiReady` only ever required the REGION
                // pipeline (it is what draws the dedicated quads, which is why
                // HUD content keeps working even when the masking pipeline is
                // unavailable). Before that fix a missing masking pipeline
                // meant the fallback block was skipped silently — mods and the
                // scoreboard would vanish from the world while `uiquad=1`
                // stayed green. It now degrades to drawing through the
                // unmasked region pipeline instead (the R1 behaviour: no
                // exclusion masking, so content shown elsewhere is duplicated
                // underneath) — worse to look at than a clean composite, never
                // as bad as content silently missing.
                //
                // R2.3 fix 1: the masking pipeline is what EVERY 2D quad draws
                // through now, not just the fallback, because the region rects
                // have exclusions of their own (the crosshair box, and any
                // future overlap). Same degrade, same one gate.
                id<MTLRenderPipelineState> maskPipeline =
                    q3e_vr_forceFallbackNil ? nil : q3e_vr_fallbackPipeline;
                [enc setDepthStencilState:q3e_vr_depthWrite];
                [enc setFragmentTexture:q3e_vr_uiCopy atIndex:0];
                [enc setFragmentBytes:&uiGrade length:sizeof(uiGrade) atIndex:0];
                for (int r = 0; r < Q3E_VR_RGN_COUNT; r++) {
                    if (!regions[r].draw) continue;
                    simd_float4x4 mvp = simd_mul(proj, simd_mul(eyeFromOrigin, regions[r].model));
                    simd_float4 uv = regions[r].uv;
                    [enc setRenderPipelineState:maskPipeline ?: q3e_vr_regionPipeline];
                    [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
                    [enc setVertexBytes:&uv length:sizeof(uv) atIndex:1];
                    if (maskPipeline) {
                        // R2.2 fix 6: the WHOLE array, always — never a
                        // zero-length bind. The count is what the shader
                        // actually reads to.
                        [enc setFragmentBytes:regions[r].excl length:sizeof(regions[r].excl) atIndex:1];
                        [enc setFragmentBytes:&regions[r].exclN length:sizeof(regions[r].exclN) atIndex:2];
                    }
                    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                }

                // R3.2 item 4: skipped entirely with the HUD switched off (see
                // drawFallback's own comment) — the model matrix was never
                // computed for such a frame either, so drawing it would place
                // an identity-transformed quad across the face.
                if (drawFallback) {
                    simd_float4x4 mvp = simd_mul(proj, simd_mul(eyeFromOrigin, fallbackModel));
                    simd_float4 fullUV = simd_make_float4(0.0f, 0.0f, 1.0f, 1.0f);
                    [enc setRenderPipelineState:maskPipeline ?: q3e_vr_regionPipeline];
                    [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
                    [enc setVertexBytes:&fullUV length:sizeof(fullUV) atIndex:1];
                    if (maskPipeline) {
                        [enc setFragmentBytes:fallbackExcl length:sizeof(fallbackExcl) atIndex:1];
                        [enc setFragmentBytes:&fallbackExclN length:sizeof(fallbackExclN) atIndex:2];
                    }
                    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                }
            }
            [enc endEncoding];
        }

        cp_drawable_encode_present(drawable, command_buffer);
        [command_buffer commit];

        // After the frame is on its way, never inside it: this one blocks.
        q3e_vr_service_pixel(queue, q3e_vr_uiCopy);

        q3e_vrFrameCount++;
        if (q3e_vrFrameCount <= 3 || (q3e_vrFrameCount % 240) == 0)
            Q3E_BlackBox("vr: frame %d | %s reason=%s | pairs=%d represents=%d dropped=%d "
                         "enginetimeouts=%d depth(live=%d copies=%d) engine=%dx%d "
                         "restartskips=%d blindworld=%d",
                         q3e_vrFrameCount, world ? "world" : "panel",
                         Q3E_VR_PresentReasonString(reason), pairs, q3e_vrRepresents,
                         q3e_vrDropped, q3e_vrEngineTimeouts, q3e_vrDepthLive,
                         q3e_vrDepthCopies, q3e_vrEngineW, q3e_vrEngineH,
                         q3e_vr_restartSkips, q3e_vr_blindWorld);

        cp_frame_end_submission(frame);
        } // @autoreleasepool
    }

    // Never leave the engine blocked on a rendezvous nobody will publish to.
    pthread_mutex_lock(&q3e_vr_mtx);
    q3e_vr_rendezvousLive = 0;
    pthread_cond_broadcast(&q3e_vr_cv);
    pthread_mutex_unlock(&q3e_vr_mtx);

    // The published present state describes a loop that no longer exists; leave
    // it saying so rather than leaving the last world frame's verdict standing.
    q3e_vrPresentWorld = 0;
    q3e_vrPresentReason = Q3E_VRP_NOT_VR;
    // R2.1 fix 8: zero the head pose on the way OUT too (not only on the way
    // in — see the entry reset above), so anything that reads it between this
    // session ending and the next one starting (there IS a reader: the
    // HEADNOW dump works in 2D/3D too) reports a clean zero rather than a
    // stale VR pose from a session that no longer exists.
    pthread_mutex_lock(&q3e_vr_mtx);
    q3e_vr_pub.headYawDeg = 0.0f;
    q3e_vr_pub.headPitchDeg = 0.0f;
    memset(q3e_vr_pub.handPosed, 0, sizeof(q3e_vr_pub.handPosed));
    memset(q3e_vr_pub.handHeld, 0, sizeof(q3e_vr_pub.handHeld));
    memset(q3e_vr_pub.handPresent, 0, sizeof(q3e_vr_pub.handPresent));
    pthread_mutex_unlock(&q3e_vr_mtx);
    q3e_vrHeadYaw = 0.0f;
    q3e_vrHeadPitch = 0.0f;
    q3e_vrHeadRoll = 0.0f;
    // R3: hands never survive a session boundary either. A stale pose would draw
    // the weapon wherever the controller was when VR closed, and a stale button
    // would leave +attack held — the same rule tracking loss follows.
    Q3E_VR_ResetHands();
    Q3E_BlackBox_Pin("vr: loop ended (frames=%d dropped=%d represents=%d notifyEnded=%d)",
                     q3e_vrFrameCount, q3e_vrDropped, q3e_vrRepresents, notifyEnded);
    Q3E_BlackBox_Flush();
    if (notifyEnded) Q3E_VR_Ended();
    q3e_vrRunning = 0;
}
