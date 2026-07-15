// Q3EImmersive.m — visionOS "3D screen" stereoscopic mode (CompositorServices).
//
// visionOS can't show real-time stereo in a normal 2D window; stereo/immersive
// rendering goes through CompositorServices, which vends per-eye Metal drawable
// textures and the ARKit head pose each frame. This file owns that render loop.
//
// ARCHITECTURE (the "3D screen" Austin chose — a world-locked stereoscopic
// display, controller-aimed, head-stable):
//   1. The game renders its scene STEREO (Quake3e's built-in two-eye path, with
//      an IPD horizontal offset) into two offscreen Vulkan images. Because our
//      renderer is MoltenVK, those VkImages are Metal textures underneath
//      (vkGetMTLTextureMVK) — no copy needed.
//   2. This loop composites those two eye textures onto a world-locked quad (the
//      "screen") positioned in front of the user: the left eye samples the left
//      render, the right eye the right render → real stereoscopic depth on a
//      comfortable, head-stable panel. The game camera stays controller-driven;
//      the head pose only places/updates the screen, it does NOT drive aim.
//
// This is wired from Q3EVisionApp.swift's ImmersiveSpace { CompositorLayer } which
// hands us the cp_layer_renderer. The 2D window path (AppShell_vision.m) is
// untouched; a settings toggle opens/closes this immersive space.
//
// MILESTONE 0 (this file, current): stand up the loop and clear the per-eye
// drawables to a color, to de-risk the immersive space + build wiring + present
// path end to end on-device. The stereo game-screen compositing (steps 1-2) lands
// in M1/M2 once this renders.

#import <CompositorServices/CompositorServices.h>
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <CoreText/CoreText.h>
#import <simd/simd.h>
#import "Q3EBlackBox.h"

// --- world-lock math (M2b) ---------------------------------------------------
// The screen is a quad placed at a fixed world position; each eye draws it with
// projection * (world->eye) * model, so it stays put in the room as the head moves.
static simd_float4x4 q3e_translate(float x, float y, float z) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = simd_make_float4(x, y, z, 1.0f);
    return m;
}
static simd_float4x4 q3e_scale(float x, float y, float z) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = x; m.columns[1].y = y; m.columns[2].z = z;
    return m;
}
// Screen placement: a 16:9 panel ~1.6 m wide, this far in front of the head. The
// tracking origin's height/heading isn't reliably eye-level, so instead of a fixed
// world position we capture the head pose on the first tracked frame and place the
// screen along the initial gaze, at eye height — then world-lock it there.
// Runtime-adjustable from the settings sheet (Q3E_Set3DPanel). Distance in metres from
// the captured head position; half-width in metres. Height derives from the game aspect.
float q3e_screenDist   = 3.6f;
float q3e_screenHalfW  = 2.75f;
float q3e_screenHeight = 0.0f;   // metres above eye level; raising it also tilts the panel
void Q3E_Set3DPanel(float dist, float halfW) {
    if (dist  >= 1.0f && dist  <= 8.0f) q3e_screenDist  = dist;
    if (halfW >= 0.6f && halfW <= 4.0f) q3e_screenHalfW = halfW;
}
void Q3E_Set3DHeight(float h) {
    if (h >= -1.5f && h <= 10.0f) q3e_screenHeight = h;   // up to overhead/ceiling
}

static bool          q3e_haveScreenAnchor = false;
static simd_float4x4 q3e_frozenHead;     // head pose captured on entry (world-locked);
                                         // placement is recomputed from it each frame so
                                         // the live distance slider actually moves the panel

// Surroundings dimming (vkQuake recipe 3): the space runs MIXED immersion, and a
// fullscreen black layer under the panel dims the passthrough continuously — 0% is the
// real room, 100% a void. The 0–1 control maps through a perceptual curve
// (1-(1-d)^2.2) because linear alpha "doesn't get dark until 80%".
static volatile float q3e_dimLevel = 0.8f;
void Q3E_Set3DDim(float d) {
    if (d < 0.0f) d = 0.0f;
    if (d > 1.0f) d = 1.0f;
    q3e_dimLevel = d;
}

// Build a vertical, head-facing screen transform 2 m along the head's horizontal gaze
// at the head's height. originFromDevice = the head pose in world space (device -Z is
// forward, +Z points back toward the user).
static simd_float4x4 q3e_make_screen_anchor(simd_float4x4 originFromDevice) {
    simd_float3 headPos = originFromDevice.columns[3].xyz;
    simd_float3 fwd = -originFromDevice.columns[2].xyz;   // gaze forward
    fwd.y = 0.0f;                                          // level (no pitch/roll)
    float len = simd_length(fwd);
    fwd = (len < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / len;

    simd_float3 pos = headPos + fwd * q3e_screenDist;
    pos.y += q3e_screenHeight;                             // raise/lower the panel
    // Face the head: at eye level the normal is horizontal (upright, no tilt); raising
    // the panel makes it pitch down toward you, approaching horizontal when high overhead
    // (watch it lying down). The vertical part drops out of cross(worldUp, normal), so
    // 'right' stays horizontal (no roll) and never degenerates.
    simd_float3 normal = simd_normalize(headPos - pos);
    simd_float3 up     = simd_make_float3(0, 1, 0);
    simd_float3 right  = simd_normalize(simd_cross(up, normal));
    up = simd_cross(normal, right);

    simd_float4x4 m;
    m.columns[0] = simd_make_float4(right,  0.0f);
    m.columns[1] = simd_make_float4(up,     0.0f);
    m.columns[2] = simd_make_float4(normal, 0.0f);
    m.columns[3] = simd_make_float4(pos,    1.0f);
    return m;
}

// Entry point invoked from the SwiftUI CompositorLayer render closure on its own
// dedicated thread. Blocks, running the frame loop until the layer is invalidated
// (the immersive space is dismissed), then returns so the thread can end.
void Q3E_Immersive_Ended(void);   // AppShell_vision.m — reconcile state on dismissal
int q3e_immFrameCount = 0;         // immersive frames presented (watchdog reads this)

// Graceful-shutdown handshake with the shell. On the button-exit path the shell sets
// q3e_immStop and WAITS for q3e_immRunning to clear BEFORE dismissing the immersive
// space — so the render thread can never touch the layerRenderer while SwiftUI tears it
// down (that race crashed the app on exit).
volatile int q3e_immStop = 0;
volatile int q3e_immRunning = 0;

// Engine bridge (renderervk overlay patches 0005/0006/0007): the off-screen FBO color
// image as a MTLTexture (aspect + mono fallback), and the both-eyes-per-frame stereo
// state — the engine renders BOTH stereo fields every host frame and snapshots each
// into its own per-eye VkImage in-order on the render queue; VK_Get3DPairs counts
// completed L+R sets. The MTLTexture accessors re-resolve the bridge every call, so a
// vid_restart (which recreates the images) can never hand us a stale pointer.
extern void *VK_Get3DColorMTLTexture(void);
extern void *VK_Get3DEyeMTLTexture(int idx);  // 0=left, 1=right; NULL until created
extern int   VK_Get3DPairs(void);     // completed L+R eye sets (both-eyes mode)
extern int   VK_Get3DFrames(void);    // minimized renders so far (color_image liveness)

// Engine FPS for the panel overlay (AppShell_vision.m publishes it; a bare number).
extern volatile int q3e_engineFPS;
extern int Q3E_FPSCounterEnabled(void);

// Persistent per-eye copies, blitted from the engine's per-eye snapshot images on THIS
// (immersive) Metal queue whenever a new L+R pair completes — decouples compositor
// sampling from the engine overwriting its snapshots on the next frame. Gated on the
// pair counter ADVANCING after entry: the snapshot images are undefined garbage until
// the first both-eyes frame lands (the vkQuake port's undefined-image trap).
static id<MTLTexture> q3e_eyeCopy[2] = { nil, nil };
static int q3e_lastPairs = 0;

// M2 game-screen draw: a textured quad sampling the engine's frame. Built once from
// the drawable's color+depth formats (compiled at runtime — no .metal build step).
// A second, alpha-blended pipeline draws the FPS overlay (premultiplied CG text).
static id<MTLRenderPipelineState> q3e_pipeline = nil;
static id<MTLRenderPipelineState> q3e_textPipeline = nil;
static id<MTLRenderPipelineState> q3e_dimPipeline = nil;   // fullscreen dim fill (blended)
static id<MTLDepthStencilState>   q3e_depthState = nil;
static id<MTLDepthStencilState>   q3e_dimDepthState = nil; // no depth write: the dim layer
                                                           // is "background", panel wins
static bool q3e_drawableLinear = false;   // drawable is float/sRGB -> compositor expects
                                          // LINEAR values (set at pipeline build)

static NSString *const kQ3EQuadShader =
@"#include <metal_stdlib>\n"
 "using namespace metal;\n"
 "struct VOut { float4 pos [[position]]; float2 uv; };\n"
 "vertex VOut q3e_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
 "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
 "  VOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
 "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"  // flip Y: tex top-left
 "  return o;\n"
 "}\n"
 // Panel sample: trilinear + 16x aniso (the #1 crispness lever at >1:1 supersample —
 // without a mip chain the 3840-wide game texture aliases/shimmers on the ~1400 px
 // panel footprint; vkQuake fidelity notes). srgbDecode linearizes display-encoded
 // (UNORM) game pixels when the drawable is float/sRGB, else the compositor shows
 // gamma values as linear -> washed out.
 "fragment float4 q3e_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
 "                       constant float& srgbDecode [[buffer(0)]]) {\n"
 "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16));\n"
 "  float4 c = tex.sample(s, in.uv);\n"
 "  if (srgbDecode > 0.5) c.rgb = pow(c.rgb, 2.2);\n"
 "  return c;\n"
 "}\n"
 "fragment float4 q3e_fill_fs(VOut in [[stage_in]], constant float4& c [[buffer(0)]]) {\n"
 "  return c;\n"
 "}\n";

static void q3e_build_pipeline(id<MTLDevice> dev, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt) {
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kQ3EQuadShader options:nil error:&err];
    if (!lib) { Q3E_BlackBox("imm: shader compile FAILED: %s",
                             err.localizedDescription.UTF8String ?: "?"); return; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction   = [lib newFunctionWithName:@"q3e_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"q3e_fs"];
    pd.colorAttachments[0].pixelFormat = colorFmt;
    pd.depthAttachmentPixelFormat = depthFmt;   // render pass has depth; must match
    q3e_pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!q3e_pipeline) { Q3E_BlackBox("imm: pipeline FAILED: %s",
                                      err.localizedDescription.UTF8String ?: "?"); return; }
    // FPS overlay: same shaders, alpha blending on (CG text is premultiplied).
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    q3e_textPipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!q3e_textPipeline) Q3E_BlackBox("imm: text pipeline FAILED: %s",
                                        err.localizedDescription.UTF8String ?: "?");
    // Surroundings dim: same blended state, solid-fill fragment (no texture).
    pd.fragmentFunction = [lib newFunctionWithName:@"q3e_fill_fs"];
    q3e_dimPipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!q3e_dimPipeline) Q3E_BlackBox("imm: dim pipeline FAILED: %s",
                                       err.localizedDescription.UTF8String ?: "?");
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;  // only the screen quad is drawn
    dd.depthWriteEnabled = YES;   // write real depth so the compositor reprojects the
                                  // panel at its true 2 m distance (else shimmer)
    q3e_depthState = [dev newDepthStencilStateWithDescriptor:dd];
    dd.depthWriteEnabled = NO;    // dim layer leaves depth at "empty" (like the old void)
    q3e_dimDepthState = [dev newDepthStencilStateWithDescriptor:dd];
    // Does the drawable want LINEAR values? (_sRGB formats re-encode on store; float
    // formats are linear by contract.) Paired with a display-encoded UNORM game
    // texture this decides the shader's srgbDecode (vkQuake's gate — never both).
    q3e_drawableLinear = (colorFmt == MTLPixelFormatBGRA8Unorm_sRGB ||
                          colorFmt == MTLPixelFormatRGBA8Unorm_sRGB ||
                          colorFmt == MTLPixelFormatRGBA16Float);
    Q3E_BlackBox("imm: game-quad pipeline built (colorFmt=%lu depthFmt=%lu drawableLinear=%d)",
                 (unsigned long)colorFmt, (unsigned long)depthFmt, (int)q3e_drawableLinear);
}

// FPS overlay texture: the current engine FPS as a bare number ("120", no "fps"
// suffix), CoreGraphics-rendered into a small shared-storage texture. Rebuilt only
// when the value changes (the shell updates it 2x/sec); CG + CoreText are
// thread-safe, so this is fine on the render thread.
static id<MTLTexture> q3e_fpsTex = nil;
static int q3e_fpsTexValue = -1;
#define Q3E_FPS_TEX_W 192
#define Q3E_FPS_TEX_H 80

static void q3e_update_fps_texture(id<MTLDevice> dev) {
    int fps = q3e_engineFPS;
    if (fps == q3e_fpsTexValue && q3e_fpsTex) return;
    q3e_fpsTexValue = fps;
    if (!q3e_fpsTex) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:Q3E_FPS_TEX_W height:Q3E_FPS_TEX_H mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        q3e_fpsTex = [dev newTextureWithDescriptor:td];
    }
    static uint8_t bytes[Q3E_FPS_TEX_W * Q3E_FPS_TEX_H * 4];
    memset(bytes, 0, sizeof(bytes));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(bytes, Q3E_FPS_TEX_W, Q3E_FPS_TEX_H, 8,
        Q3E_FPS_TEX_W * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (ctx) {
        char txt[8]; snprintf(txt, sizeof(txt), "%d", fps);
        CTFontRef font = CTFontCreateWithName(CFSTR("HelveticaNeue-Bold"), 56, NULL);
        CGColorRef gold = CGColorCreateGenericRGB(1.0, 0.85, 0.2, 0.9);
        CFStringRef str = CFStringCreateWithCString(NULL, txt, kCFStringEncodingUTF8);
        const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
        const void *vals[] = { font, gold };
        CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFAttributedStringRef astr = CFAttributedStringCreate(NULL, str, attrs);
        CTLineRef line = CTLineCreateWithAttributedString(astr);
        CGContextSetTextPosition(ctx, 8, 16);
        CTLineDraw(line, ctx);
        CFRelease(line); CFRelease(astr); CFRelease(attrs); CFRelease(str);
        CGColorRelease(gold); CFRelease(font);
        CGContextRelease(ctx);
        [q3e_fpsTex replaceRegion:MTLRegionMake2D(0, 0, Q3E_FPS_TEX_W, Q3E_FPS_TEX_H)
                      mipmapLevel:0 withBytes:bytes bytesPerRow:Q3E_FPS_TEX_W * 4];
    }
    CGColorSpaceRelease(cs);
}

void Q3E_Immersive_Run(cp_layer_renderer_t layer_renderer)
{
    // The command queue must be created from the SAME MTLDevice that owns the
    // drawable textures (the compositor's device), not MTLCreateSystemDefaultDevice
    // — a mismatch aborts. Create it lazily from the first drawable's texture.
    // cp_layer_renderer_t is ARC-managed, so this strong parameter keeps the layer alive
    // for the whole function — no manual retain needed. The graceful-shutdown handshake
    // (q3e_immStop / q3e_immRunning) is what prevents the crash: the shell stops us before
    // it dismisses the space, so we never run a frame against a torn-down session.
    q3e_immStop = 0;
    q3e_immRunning = 1;
    int notifyEnded = 0;            // only a system/Crown dismissal reconciles via Ended

    id<MTLCommandQueue> queue = nil;
    q3e_immFrameCount = 0;
    q3e_haveScreenAnchor = false;   // re-center the screen each time 3D is entered
    q3e_eyeCopy[0] = q3e_eyeCopy[1] = nil;   // fresh per-eye copies each entry
    q3e_lastPairs = VK_Get3DPairs();  // only accept pairs completed AFTER entry
                                      // (pre-entry snapshot images are undefined)

    // ARKit world tracking for the head pose. The compositor reprojects each frame
    // with the device anchor; on this visionOS build a frame presented WITHOUT one may
    // not display at all (design notes §6). Set it on the drawable before present each frame.
    ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create();
    ar_world_tracking_provider_t wtp = ar_world_tracking_provider_create(wtc);
    ar_session_t arSession = ar_session_create();
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(wtp, NULL);
    ar_session_run(arSession, providers);

    Q3E_BlackBox("imm: render loop started (ARKit world tracking running)");
    NSLog(@"Q3E-VISION immersive: render loop started");

    int running = 1;
    while (running) {
        if (q3e_immStop) {   // button-exit: the shell already reconciled state + is
            Q3E_BlackBox("imm: stop requested, exiting cleanly (frames=%d)", q3e_immFrameCount);
            running = 0; continue;   // waiting for us before it dismisses the space
        }
        switch (cp_layer_renderer_get_state(layer_renderer)) {
            case cp_layer_renderer_state_paused:
                Q3E_BlackBox("imm: state=paused, waiting (frames so far=%d)", q3e_immFrameCount);
                cp_layer_renderer_wait_until_running(layer_renderer);
                Q3E_BlackBox("imm: resumed from paused");
                continue;
            case cp_layer_renderer_state_invalidated:
                Q3E_BlackBox("imm: INVALIDATED, exiting (frames=%d)", q3e_immFrameCount);
                NSLog(@"Q3E-VISION immersive: layer invalidated, exiting loop");
                notifyEnded = 1;         // Crown dismiss: reconcile shell + SwiftUI state
                running = 0; continue;
            case cp_layer_renderer_state_running:
            default:
                break;
        }

        // Drain per-frame ObjC allocations each iteration — this render thread has no
        // runloop autorelease pool (3D design notes; matters once M2 encodes per frame).
        @autoreleasepool {

        cp_frame_t frame = cp_layer_renderer_query_next_frame(layer_renderer);
        if (frame == NULL)
            continue;

        cp_frame_timing_t timing = cp_frame_predict_timing(frame);
        cp_frame_start_update(frame);
        cp_frame_end_update(frame);
        // Pace to the compositor's optimal input time (design notes §6). Without this the loop
        // free-runs (~360 fps in the black box) instead of the compositor cadence.
        cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));

        cp_frame_start_submission(frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // cp_frame_query_drawable is available since visionOS 1.0 (the plural
        // query_drawables is 26.0-only); single drawable is all we need.
        cp_drawable_t drawable = cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
        if (drawable == NULL) {
            cp_frame_end_submission(frame);
            continue;
        }

        if (queue == nil) {
            id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
            queue = [t0.device newCommandQueue];
            q3e_build_pipeline(t0.device, t0.pixelFormat,
                               cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
            // bring-up run-1 diagnostic: is the compositor's device the SAME object as
            // MoltenVK's (system default)? If not, concurrent engine+immersive GPU
            // work can conflict and cross-device texture sampling is illegal.
            id<MTLDevice> sysdev = MTLCreateSystemDefaultDevice();
            NSLog(@"Q3E-VISION immersive DIAG: drawableDev=%p reg=%llu | sysDefault=%p reg=%llu | same=%d | colorFmt=%lu depthFmt=%lu",
                  t0.device, (unsigned long long)t0.device.registryID,
                  sysdev, (unsigned long long)sysdev.registryID,
                  (t0.device == sysdev),
                  (unsigned long)t0.pixelFormat,
                  (unsigned long)cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
            Q3E_BlackBox("imm DIAG: drawableDev=%p reg=%llu sysDefault=%p reg=%llu SAME=%d colorFmt=%lu depthFmt=%lu views=%zu",
                  t0.device, (unsigned long long)t0.device.registryID,
                  sysdev, (unsigned long long)sysdev.registryID,
                  (int)(t0.device == sysdev),
                  (unsigned long)t0.pixelFormat,
                  (unsigned long)cp_drawable_get_depth_texture(drawable, 0).pixelFormat,
                  cp_drawable_get_view_count(drawable));
        }

        // Query the head pose for this frame's presentation time and give it to the
        // compositor for reprojection (required for the frame to display, design notes §6).
        CFTimeInterval presTime = cp_time_to_cf_time_interval(
            cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
        ar_device_anchor_t anchor = ar_device_anchor_create();
        ar_device_anchor_query_status_t anchorStatus =
            ar_world_tracking_provider_query_device_anchor_at_timestamp(wtp, presTime, anchor);
        cp_drawable_set_device_anchor(drawable, anchor);

        // Capture the screen's world placement once tracking has CONVERGED. On the
        // first few frames ARKit returns success with a near-identity pose, which put
        // the panel along the world axis (on the floor, off to the side); waiting ~30
        // frames gives a real head position + heading to anchor the screen to.
        if (!q3e_haveScreenAnchor && anchorStatus == ar_device_anchor_query_status_success
            && q3e_immFrameCount > 30) {
            q3e_frozenHead = ar_device_anchor_get_origin_from_anchor_transform(anchor);
            q3e_haveScreenAnchor = true;
            Q3E_BlackBox("imm: screen anchored at head (%.2f,%.2f,%.2f)",
                         q3e_frozenHead.columns[3].x, q3e_frozenHead.columns[3].y,
                         q3e_frozenHead.columns[3].z);
        }

        id<MTLCommandBuffer> command_buffer = [queue commandBuffer];

        // M3/patch 0007: draw the engine's rendered frame onto a WORLD-LOCKED screen
        // quad, per eye slice of the layered drawable, using projection * (world->eye)
        // * model so the panel stays fixed in the room. Each eye samples its OWN image
        // for true stereo depth.
        //
        // Both-eyes-per-frame: the engine renders L+R fields every host frame and
        // snapshots each into its own per-eye image (in-order on its render queue).
        // When a new pair lands, blit BOTH into our persistent copies on THIS Metal
        // queue — both eyes the same game time, full engine rate per eye. The eye
        // textures are re-resolved every frame (vid_restart recreates them).
        id<MTLTexture> monoTex = (__bridge id<MTLTexture>)VK_Get3DColorMTLTexture();
        int pairs = VK_Get3DPairs();
        if (pairs != q3e_lastPairs) {
            q3e_lastPairs = pairs;
            id<MTLBlitCommandEncoder> blit = nil;
            for (int e = 0; e < 2; e++) {
                id<MTLTexture> src = (__bridge id<MTLTexture>)VK_Get3DEyeMTLTexture(e);
                if (!src) continue;
                if (q3e_eyeCopy[e] == nil ||
                    q3e_eyeCopy[e].width != src.width ||
                    q3e_eyeCopy[e].height != src.height) {
                    // MIPMAPPED: the panel minifies a ~3840-wide texture onto a ~1400 px
                    // footprint; without a mip chain that's raw aliasing ("soft/noisy").
                    // RenderTarget usage is required by generateMipmapsForTexture.
                    MTLTextureDescriptor *td = [MTLTextureDescriptor
                        texture2DDescriptorWithPixelFormat:src.pixelFormat
                        width:src.width height:src.height mipmapped:YES];
                    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
                    td.storageMode = MTLStorageModePrivate;
                    q3e_eyeCopy[e] = [src.device newTextureWithDescriptor:td];
                }
                if (!blit) blit = [command_buffer blitCommandEncoder];
                // Explicit level-0 copy: the whole-texture convenience copy requires
                // matching mip counts, and the engine's snapshot has a single level.
                [blit copyFromTexture:src sourceSlice:0 sourceLevel:0
                         sourceOrigin:MTLOriginMake(0, 0, 0)
                           sourceSize:MTLSizeMake(src.width, src.height, 1)
                            toTexture:q3e_eyeCopy[e] destinationSlice:0 destinationLevel:0
                    destinationOrigin:MTLOriginMake(0, 0, 0)];
                [blit generateMipmapsForTexture:q3e_eyeCopy[e]];
            }
            [blit endEncoding];
        }
        id<MTLTexture> eyeTex[2] = { q3e_eyeCopy[0], q3e_eyeCopy[1] };
        id<MTLTexture> color = cp_drawable_get_color_texture(drawable, 0);
        id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, 0);
        size_t views = cp_drawable_get_view_count(drawable);

        // world->model: the captured head-relative screen placement, scaled to size.
        // (Fall back to a fixed spot if tracking hasn't produced a pose yet.) Height is
        // derived from the game frame's aspect so the picture never stretches.
        simd_float4x4 placement = q3e_haveScreenAnchor ? q3e_make_screen_anchor(q3e_frozenHead)
                                    : q3e_translate(0.0f, 0.0f, -q3e_screenDist);
        float halfW = q3e_screenHalfW;
        float aspect = (monoTex && monoTex.width > 0)
                         ? (float)monoTex.height / (float)monoTex.width : (9.0f / 16.0f);
        simd_float4x4 model = simd_mul(placement, q3e_scale(halfW, halfW * aspect, 1.0f));
        // world->device (head pose) from the anchor set above.
        simd_float4x4 originFromDevice = ar_device_anchor_get_origin_from_anchor_transform(anchor);

        // FPS overlay (settings toggle): a bare number pinned to the panel's top-left,
        // drawn by us — replaces borrowing the cgame QVM's "###fps" HUD counter.
        int drawFPS = Q3E_FPSCounterEnabled() && q3e_textPipeline != nil;
        simd_float4x4 fpsModel = matrix_identity_float4x4;
        if (drawFPS) {
            q3e_update_fps_texture(color.device);
            float halfH = halfW * aspect;
            float fw = halfW * 0.11f;                                  // overlay half-width
            float fh = fw * ((float)Q3E_FPS_TEX_H / (float)Q3E_FPS_TEX_W);
            simd_float4x4 corner = q3e_translate(-halfW + fw + 0.06f,
                                                  halfH - fh - 0.05f, 0.01f);
            fpsModel = simd_mul(placement, simd_mul(corner, q3e_scale(fw, fh, 1.0f)));
        }

        for (size_t v = 0; v < views; v++) {
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = color;
            pass.colorAttachments[0].slice = v;        // this eye's array slice
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
            if (depth) {
                pass.depthAttachment.texture = depth;
                pass.depthAttachment.slice = v;
                pass.depthAttachment.loadAction = MTLLoadActionClear;
                pass.depthAttachment.storeAction = MTLStoreActionStore;
                pass.depthAttachment.clearDepth = 1.0;
            }
            // This eye's texture: its own stereo image if ready, else the mono frame.
            id<MTLTexture> tex = (v < 2 && eyeTex[v]) ? eyeTex[v] : monoTex;

            id<MTLRenderCommandEncoder> enc = [command_buffer renderCommandEncoderWithDescriptor:pass];
            // Surroundings dim (drawn FIRST, under everything): fullscreen clip-space
            // quad (identity mvp through the shared vertex shader), premultiplied black
            // at the perceptual-mapped level. Skipped at 0% (pure passthrough).
            float dimA = 1.0f - powf(1.0f - q3e_dimLevel, 2.2f);
            if (dimA > 0.003f && q3e_dimPipeline) {
                simd_float4x4 ident = matrix_identity_float4x4;
                float dimColor[4] = { 0.0f, 0.0f, 0.0f, dimA };   // premultiplied black
                [enc setRenderPipelineState:q3e_dimPipeline];
                [enc setDepthStencilState:q3e_dimDepthState];
                [enc setVertexBytes:&ident length:sizeof(ident) atIndex:0];
                [enc setFragmentBytes:dimColor length:sizeof(dimColor) atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            }
            if (tex && q3e_pipeline) {
                cp_view_t view = cp_drawable_get_view(drawable, v);
                simd_float4x4 deviceFromEye = cp_view_get_transform(view);
                simd_float4x4 eyeFromOrigin = simd_inverse(simd_mul(originFromDevice, deviceFromEye));
                simd_float4x4 proj = matrix_identity_float4x4;
                if (__builtin_available(visionOS 2.0, *))
                    proj = cp_drawable_compute_projection(drawable,
                               cp_axis_direction_convention_right_up_back, v);
                simd_float4x4 mvp = simd_mul(proj, simd_mul(eyeFromOrigin, model));

                // Linearize display-encoded (UNORM, non-sRGB-view) game pixels when the
                // drawable expects linear — never when the source is an _sRGB view
                // (Metal already decodes those on sample; doing both double-darkens).
                float panelDecode = (q3e_drawableLinear &&
                                     (tex.pixelFormat == MTLPixelFormatBGRA8Unorm ||
                                      tex.pixelFormat == MTLPixelFormatRGBA8Unorm ||
                                      tex.pixelFormat == MTLPixelFormatRGBA16Unorm)) ? 1.0f : 0.0f;
                [enc setRenderPipelineState:q3e_pipeline];
                [enc setDepthStencilState:q3e_depthState];
                [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
                [enc setFragmentTexture:tex atIndex:0];
                [enc setFragmentBytes:&panelDecode length:sizeof(panelDecode) atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];

                if (drawFPS && q3e_fpsTex) {
                    simd_float4x4 fmvp = simd_mul(proj, simd_mul(eyeFromOrigin, fpsModel));
                    float noDecode = 0.0f;   // FPS text is authored as-is
                    [enc setRenderPipelineState:q3e_textPipeline];
                    [enc setVertexBytes:&fmvp length:sizeof(fmvp) atIndex:0];
                    [enc setFragmentTexture:q3e_fpsTex atIndex:0];
                    [enc setFragmentBytes:&noDecode length:sizeof(noDecode) atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                }
            }
            [enc endEncoding];
        }
        if (q3e_immFrameCount == 2 || (q3e_immFrameCount % 240) == 0)
            Q3E_BlackBox("imm: 0007 — FBO=%lux%lu pairs=%d rendFrames=%d | eyeL=%d eyeR=%d | srcFmt=%lu drawLin=%d mips=%lu",
                         (unsigned long)(monoTex ? monoTex.width : 0),
                         (unsigned long)(monoTex ? monoTex.height : 0),
                         pairs, VK_Get3DFrames(),
                         (int)(eyeTex[0] != nil), (int)(eyeTex[1] != nil),
                         (unsigned long)(monoTex ? monoTex.pixelFormat : 0),
                         (int)q3e_drawableLinear,
                         (unsigned long)(eyeTex[0] ? eyeTex[0].mipmapLevelCount : 0));

        cp_drawable_encode_present(drawable, command_buffer);
        [command_buffer commit];

        q3e_immFrameCount++;
        if (q3e_immFrameCount <= 3 || (q3e_immFrameCount % 90) == 0)
            Q3E_BlackBox("imm: frame %d presented", q3e_immFrameCount);

        cp_frame_end_submission(frame);
        } // @autoreleasepool
    }

    if (notifyEnded) Q3E_Immersive_Ended();   // Crown/system dismissal path only
    q3e_immRunning = 0;                        // signal the shell LAST, after cleanup
}
