// Q3ESense.m — PSVR2 Sense controllers on visionOS.
//
// Two questions, deliberately kept apart, because conflating them cost a sibling
// port days:
//
//   WHO DRIVES INPUT — a product-category question. Spatial-category controllers
//   are ours; every ordinary gamepad stays with the pad layer and the player's
//   own binds. ios_input.m's filter asks THIS file the same question, so the two
//   halves can never disagree about who owns a device.
//
//   WHERE THE HAND IS — an ARKit question, and NOT the same gate.
//   ar_accessory_load_from_device takes a GCDevice, not a spatial controller: a
//   device that is "just a gamepad" for input may still be trackable. So the
//   load is attempted for EVERY controller and the result is logged either way.
//
// THE TRAP LEDGER, paid for on the sibling port and not paid again here:
//   - Declaration and filter ship together. Without `SpatialGamepad` in the
//     Info.plist the pair enumerates as ONE aggregate MFi gamepad and
//     ar_accessory_load_from_device fails with code 1200. With it, two
//     GCProductCategorySpatialController devices appear (visionOS 26+).
//   - AUTHORIZATION BEFORE LOAD. A load issued without accessory-tracking
//     authorization fails in exactly the shape of "this hardware cannot be
//     tracked", which is the most misleading result available. Ask first, park
//     devices until the answer lands, then drain the queue.
//   - ELEMENT NAMES ARE NOT GUESSED. The constants below are the documented
//     ones; each also has a by-shape fallback, so a naming surprise degrades one
//     button instead of killing the pad. And the full inventory is logged on
//     every connect, into the headset-readable black box, because the person who
//     can produce it is wearing a Vision Pro and not sitting at a Mac.
//   - A working path is never removed in the build that introduces its
//     replacement. Nothing here touches the existing gamepad path.

#import "Q3ESense.h"
#import "Q3EBlackBox.h"

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <ARKit/ARKit.h>
#import <CoreHaptics/CoreHaptics.h>
#import <math.h>
#import <pthread.h>
#import <string.h>

#define Q3E_SENSE_MAX 4

static void q3e_sense_pin(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void q3e_sense_pin(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    // ONE LINE PER RECORD, always. Several of these lines interpolate Foundation
    // container descriptions — the Info.plist array, the element key lists — and
    // those are pretty-printed across several lines. A multi-line record is
    // exactly the failure the dump rules exist to prevent: a grep for the record
    // matches a CONTINUATION line and reads half a value as the whole of it,
    // which is precisely how the SpatialGamepad declaration read as absent from
    // a build that carried it.
    {
        NSMutableString *flat = [s mutableCopy];
        NSCharacterSet *breaks = [NSCharacterSet characterSetWithCharactersInString:@"\n\r\t"];
        NSRange r = [flat rangeOfCharacterFromSet:breaks];
        while (r.location != NSNotFound) {
            [flat replaceCharactersInRange:r withString:@" "];
            r = [flat rangeOfCharacterFromSet:breaks];
        }
        Q3E_BlackBox_PinStr(flat.UTF8String);
    }
}

// ---------------------------------------------------------------------------
// State. The GameController notifications land on the main queue; the poll runs
// on the compositor thread; the flat/menu sample runs on the engine thread. One
// lock covers the accessory table, the hand assignment and the edge accumulator.
// ---------------------------------------------------------------------------
static pthread_mutex_t sLock = PTHREAD_MUTEX_INITIALIZER;

static GCController *sHand[2];                   // 0 = left, 1 = right, by ARKit chirality
static NSMutableArray<GCController *> *sSpatial; // spatial-category devices
static NSMutableString                *sInventory;
static BOOL                            sStarted;

API_AVAILABLE(visionos(26.0))
static ar_accessory_t sAccessory[Q3E_SENSE_MAX];
static GCController  *sAccessoryDevice[Q3E_SENSE_MAX];
static int            sAccessoryCount;

API_AVAILABLE(visionos(26.0))
static ar_accessory_tracking_provider_t sProvider;
API_AVAILABLE(visionos(26.0))
static ar_session_t sSession;
static bool         sProviderDirty;

static int           sAuthState;   // 0 = pending / not asked, 1 = allowed, -1 = denied
static BOOL          sAuthAsked;
static GCController *sPending[Q3E_SENSE_MAX];
static int           sPendingCount;

static int sLoadOK, sLoadFail, sLoadFailCode, sLastAnchorCount, sPollCount;
static int sTrackedMask;   // which hands the last poll saw

// THE ONE EDGE DETECTOR (charter D5). Fed by whichever poll runs, drained by the
// single consumer. Guarded by sLock, which is therefore "the publish lock" the
// charter names: no edge is ever computed on a consumer thread.
static unsigned sEdgeLevel[2];   // what the last poll saw down
static unsigned sEdgeDown[2];    // presses since the consumer last drained
static unsigned sEdgeUp[2];      // releases since the consumer last drained
static int      sEdgeHands;      // hands that answered the last poll
static float    sEdgeStick[4];   // (Lx, Ly, Rx, Ry) from that same poll

// Synthetic hands (simulator). Stored as a finished tracking-space pose so the
// injection point is byte-identical to a real anchor's.
static int           sSynthOn[2];
static simd_float4x4 sSynthPose[2];
static float         sSynthYPR[2][3];   // for the dump: what was asked for
static float         sSynthXYZ[2][3];
static unsigned      sSynthButtons[2];
static float         sSynthStick[2][2];

// ---------------------------------------------------------------------------
// Element access. Spatial controllers are NOT `extendedGamepad` devices, so
// everything goes through `physicalInputProfile` by alias.
// ---------------------------------------------------------------------------
// NIL-SAFE on purpose. The spatial element names below only exist from
// visionOS 26, and this build's deployment target is 1.0 — so on an older system
// the constant resolves to nil, and a nil subscript on an NSDictionary throws.
// A nil name here simply means "no documented alias on this system", and the
// by-shape fallback answers instead.
static GCControllerButtonInput *q3e_btn(GCController *c, NSString *name) {
    if (c == nil || name == nil)
        return nil;
    return c.physicalInputProfile.buttons[name];
}

// The documented aliases, resolved behind an availability check so the constants
// are only touched on a system that has them. Every one has a by-shape fallback
// at the call site, so a system without them degrades to name matching rather
// than losing the button.
static NSString *q3e_name_trigger(void) {
    if (@available(visionOS 26.0, *)) return GCInputTrigger;
    return nil;
}
static NSString *q3e_name_grip(void) {
    if (@available(visionOS 26.0, *)) return GCInputGripButton;
    return nil;
}
static NSString *q3e_name_stickbutton(void) {
    if (@available(visionOS 26.0, *)) return GCInputThumbstickButton;
    return nil;
}
static NSString *q3e_name_stick(void) {
    if (@available(visionOS 26.0, *)) return GCInputThumbstick;
    return nil;
}

// By-shape fallback: find a button whose alias merely CONTAINS the needle. The
// documented constant is always tried first; this only catches a rename.
static GCControllerButtonInput *q3e_btn_like(GCController *c, NSString *needle) {
    if (c == nil)
        return nil;
    for (NSString *k in c.physicalInputProfile.buttons.allKeys)
        if ([k rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound)
            return c.physicalInputProfile.buttons[k];
    return nil;
}

static bool q3e_down(GCController *c, NSString *name, NSString *needle) {
    GCControllerButtonInput *b = q3e_btn(c, name);
    if (b == nil && needle)
        b = q3e_btn_like(c, needle);
    return b ? b.isPressed : false;
}

// Analog value. On a Sense the trigger's analog travel rides on the BUTTON
// element (`value`), not on an axis — reading `axes` for it is the mistake that
// produced a digital-feeling trigger elsewhere.
static float q3e_analog(GCController *c, NSString *name, NSString *needle) {
    GCControllerButtonInput *b = q3e_btn(c, name);
    if (b == nil && needle)
        b = q3e_btn_like(c, needle);
    return b ? b.value : 0.0f;
}

// The thumbstick is a DIRECTION PAD, which is why it lives under `dpads`.
static GCControllerDirectionPad *q3e_stick(GCController *c) {
    if (c == nil)
        return nil;
    GCPhysicalInputProfile   *p = c.physicalInputProfile;
    NSString                 *name = q3e_name_stick();
    GCControllerDirectionPad *d = name ? p.dpads[name] : nil;
    if (d != nil)
        return d;
    for (NSString *k in p.dpads.allKeys)
        return p.dpads[k];   // first of any: better one stick than none
    return nil;
}

static bool q3e_is_spatial(GCController *c) {
    if (@available(visionOS 26.0, *))
        return [c.productCategory isEqualToString:GCProductCategorySpatialController];
    return false;
}

static unsigned q3e_sense_buttons(GCController *c) {
    unsigned b = 0;
    if (q3e_down(c, q3e_name_trigger(), @"Trigger"))       b |= Q3E_SENSE_TRIGGER;
    if (q3e_down(c, q3e_name_grip(), @"Grip"))            b |= Q3E_SENSE_GRIP;
    if (q3e_down(c, GCInputButtonA, @"Button A"))         b |= Q3E_SENSE_A;
    if (q3e_down(c, GCInputButtonB, @"Button B"))         b |= Q3E_SENSE_B;
    if (q3e_down(c, q3e_name_stickbutton(), @"Thumbstick Button")) b |= Q3E_SENSE_STICK;
    if (q3e_down(c, GCInputButtonMenu, @"Menu"))          b |= Q3E_SENSE_MENU;
    return b;
}

// ---------------------------------------------------------------------------
// The edge accumulator. Called with sLock HELD, from inside a poll.
// ---------------------------------------------------------------------------
static void q3e_sense_fold_edges_locked(const unsigned cur[2], int hands, const float stick[4]) {
    for (int h = 0; h < 2; h++) {
        sEdgeDown[h] |= cur[h] & ~sEdgeLevel[h];
        sEdgeUp[h]   |= sEdgeLevel[h] & ~cur[h];
        sEdgeLevel[h] = cur[h];
    }
    for (int i = 0; i < 4; i++)
        sEdgeStick[i] = stick[i];
    sEdgeHands = hands;
}

int Q3E_Sense_TakeEdges(unsigned down[2], unsigned up[2], unsigned level[2], float stick[4]) {
    int hands;
    pthread_mutex_lock(&sLock);
    for (int h = 0; h < 2; h++) {
        if (down)  down[h]  = sEdgeDown[h];
        if (up)    up[h]    = sEdgeUp[h];
        if (level) level[h] = sEdgeLevel[h];
        sEdgeDown[h] = 0;
        sEdgeUp[h] = 0;
    }
    if (stick)
        for (int i = 0; i < 4; i++)
            stick[i] = sEdgeStick[i];
    hands = sEdgeHands;
    pthread_mutex_unlock(&sLock);
    return hands;
}

int Q3E_Sense_PeekLevel(unsigned level[2], float stick[4]) {
    int hands;
    pthread_mutex_lock(&sLock);
    if (level)
        for (int h = 0; h < 2; h++)
            level[h] = sEdgeLevel[h];
    if (stick)
        for (int i = 0; i < 4; i++)
            stick[i] = sEdgeStick[i];
    hands = sEdgeHands;
    pthread_mutex_unlock(&sLock);
    return hands;
}

void Q3E_Sense_RebaseEdges(void) {
    pthread_mutex_lock(&sLock);
    for (int h = 0; h < 2; h++) {
        sEdgeDown[h] = 0;
        sEdgeUp[h] = 0;
        // sEdgeLevel is DELIBERATELY kept: whatever is physically held stays
        // held, so the next poll produces no edge for it. That is what makes a
        // trigger held across a context boundary neither re-fire on the far side
        // nor emit a release nobody made.
    }
    pthread_mutex_unlock(&sLock);
}

// ---------------------------------------------------------------------------
// Inventory — the deliverable of the first device round.
// ---------------------------------------------------------------------------
static void q3e_sense_log_inventory(GCController *c) {
    NSString *cat = @"(unknown)";
    if (@available(visionOS 26.0, *))
        cat = c.productCategory ?: @"(nil)";
    q3e_sense_pin(@"SENSE controller '%@' category='%@' spatial=%d",
                  c.vendorName ?: @"(nil)", cat, q3e_is_spatial(c) ? 1 : 0);
    q3e_sense_pin(@"SENSE   buttons: %@",
                  [c.physicalInputProfile.buttons.allKeys componentsJoinedByString:@", "]);
    q3e_sense_pin(@"SENSE   axes:    %@",
                  [c.physicalInputProfile.axes.allKeys componentsJoinedByString:@", "]);
    q3e_sense_pin(@"SENSE   dpads:   %@",
                  [c.physicalInputProfile.dpads.allKeys componentsJoinedByString:@", "]);
    q3e_sense_pin(@"SENSE   haptics: %@", c.haptics ? @"yes" : @"no");
    // Did the declaration survive plist processing into the BUILT product? One
    // line closes that question permanently, and it is the first thing a device
    // round has to answer.
    q3e_sense_pin(@"SENSE   bundle GCSupportedGameControllers = %@",
                  [NSBundle.mainBundle objectForInfoDictionaryKey:@"GCSupportedGameControllers"]);
    if (sInventory == nil)
        sInventory = [NSMutableString string];
    [sInventory appendFormat:@"%@ [%@] %lub/%lud%@\n", c.vendorName ?: @"?", cat,
                             (unsigned long)c.physicalInputProfile.buttons.allKeys.count,
                             (unsigned long)c.physicalInputProfile.dpads.allKeys.count,
                             c.haptics ? @" haptics" : @""];
}

// ---------------------------------------------------------------------------
// Accessory tracking (poses)
// ---------------------------------------------------------------------------
API_AVAILABLE(visionos(26.0))
static void q3e_sense_load_retry(GCController *c, int attempt);
static void q3e_sense_provider_needs_rebuild(void);

API_AVAILABLE(visionos(26.0))
static void q3e_sense_load(GCController *c) { q3e_sense_load_retry(c, 0); }

API_AVAILABLE(visionos(26.0))
static void q3e_sense_load_retry(GCController *c, int attempt) {
    if (c == nil)
        return;
    pthread_mutex_lock(&sLock);
    for (int i = 0; i < sAccessoryCount; i++)
        if (sAccessoryDevice[i] == c) {
            pthread_mutex_unlock(&sLock);
            return;   // already loaded — a device can arrive twice (queue + reconnect)
        }
    pthread_mutex_unlock(&sLock);

    ar_accessory_load_from_device(c, ^(id<GCDevice> device, bool successful,
                                       ar_error_t error, ar_accessory_t accessory) {
        (void)device;
        if (!successful || accessory == NULL) {
            long        code = -1;
            CFStringRef desc = NULL;
            if (error != NULL) {
                code = (long)ar_error_get_error_code(error);
                CFErrorRef cfe = ar_error_copy_cf_error(error);
                if (cfe != NULL) {
                    desc = CFErrorCopyDescription(cfe);
                    CFRelease(cfe);
                }
            }
            sLoadFail++;
            sLoadFailCode = (int)code;
            // 1200 is ar_accessory_tracking_error_code_accessory_loading_failed —
            // on this system that means the SpatialGamepad declaration did not
            // take effect and the pair is still one aggregate MFi device.
            q3e_sense_pin(@"SENSE accessory load FAILED for '%@' code=%ld attempt=%d%@ desc=%@",
                          c.vendorName ?: @"(nil)", code, attempt,
                          code == 1200 ? @"  (1200 = aggregate MFi: the SpatialGamepad declaration is missing or ineffective)" : @"",
                          desc ? (__bridge NSString *)desc : @"(none)");
            if (desc != NULL)
                CFRelease(desc);
            // ONE retry, 2 s later: accessory tracking is gated on the app being
            // focused, and a load issued during entry or a focus change can fail
            // for that alone. Both results are logged, so a retry cannot hide the
            // first answer.
            if (attempt == 0)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (@available(visionOS 26.0, *))
                        q3e_sense_load_retry(c, 1);
                });
            return;
        }
        pthread_mutex_lock(&sLock);
        if (sAccessoryCount >= Q3E_SENSE_MAX) {
            pthread_mutex_unlock(&sLock);
            q3e_sense_pin(@"SENSE accessory table full — ignoring '%s'", ar_accessory_get_name(accessory));
            return;
        }
        ar_accessory_chirality_t ch = ar_accessory_get_inherent_chirality(accessory);
        sAccessory[sAccessoryCount] = accessory;
        sAccessoryDevice[sAccessoryCount] = c;
        sAccessoryCount++;
        sLoadOK++;
        sProviderDirty = true;
        // GameController has NO handedness API — the ARKit accessory's inherent
        // chirality is the documented pairing, and it is why input assignment has
        // to wait for an asynchronous answer instead of guessing from a name.
        if (ch == ar_accessory_chirality_left)
            sHand[0] = c;
        else if (ch == ar_accessory_chirality_right)
            sHand[1] = c;
        pthread_mutex_unlock(&sLock);
        q3e_sense_provider_needs_rebuild();
        q3e_sense_pin(@"SENSE accessory LOADED '%s' chirality=%s from '%@' — %d known",
                      ar_accessory_get_name(accessory),
                      ch == ar_accessory_chirality_left ? "LEFT"
                      : ch == ar_accessory_chirality_right ? "RIGHT" : "unspecified",
                      c.vendorName ?: @"(nil)", sAccessoryCount);
    });
}

API_AVAILABLE(visionos(26.0))
static void q3e_sense_request_auth(void) {
    if (sAuthAsked)
        return;
    sAuthAsked = YES;
    if (sSession == NULL)
        sSession = ar_session_create();
    q3e_sense_pin(@"SENSE requesting accessory-tracking authorization");
    ar_session_request_authorization(sSession, ar_authorization_type_accessory_tracking,
                                     ^(ar_authorization_results_t results, ar_error_t error) {
        __block int state = -1;
        if (results != NULL)
            ar_authorization_results_enumerate_results(results, ^bool(ar_authorization_result_t r) {
                if (ar_authorization_result_get_authorization_type(r) == ar_authorization_type_accessory_tracking)
                    state = (ar_authorization_result_get_status(r) == ar_authorization_status_allowed) ? 1 : -1;
                return true;
            });
        sAuthState = state;
        q3e_sense_pin(@"SENSE accessory-tracking authorization: %s%s",
                      state == 1 ? "ALLOWED" : "DENIED", error ? " (with error)" : "");
        if (state != 1)
            return;
        for (int i = 0; i < sPendingCount; i++)
            q3e_sense_load(sPending[i]);
        sPendingCount = 0;
    });
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------
static void q3e_sense_adopt(GCController *c) {
    if (c == nil)
        return;
    q3e_sense_log_inventory(c);
    if (q3e_is_spatial(c)) {
        pthread_mutex_lock(&sLock);
        if (sSpatial == nil)
            sSpatial = [NSMutableArray array];
        if (![sSpatial containsObject:c])
            [sSpatial addObject:c];
        pthread_mutex_unlock(&sLock);
    }
    // Poses are asked for on EVERY controller, spatial or not — see the header.
    if (@available(visionOS 26.0, *)) {
        q3e_sense_request_auth();
        if (sAuthState == 1)
            q3e_sense_load(c);
        else if (sAuthState == 0 && sPendingCount < Q3E_SENSE_MAX)
            sPending[sPendingCount++] = c;   // parked until the grant lands
    }
}

static void q3e_sense_forget(GCController *c) {
    pthread_mutex_lock(&sLock);
    for (int i = 0; i < 2; i++)
        if (sHand[i] == c) {
            sHand[i] = nil;
            // Losing a controller RELEASES everything it was holding, through
            // the same edge detector every ordinary release goes through: a
            // battery that dies mid-fire must not leave +attack latched.
            sEdgeUp[i] |= sEdgeLevel[i];
            sEdgeLevel[i] = 0;
            sEdgeDown[i] = 0;
        }
    [sSpatial removeObject:c];
    for (int i = 0; i < sPendingCount; i++)
        if (sPending[i] == c) {
            for (int j = i; j < sPendingCount - 1; j++)
                sPending[j] = sPending[j + 1];
            sPending[--sPendingCount] = nil;
            break;
        }
    for (int i = 0; i < sAccessoryCount; i++)
        if (sAccessoryDevice[i] == c) {
            for (int j = i; j < sAccessoryCount - 1; j++) {
                sAccessory[j] = sAccessory[j + 1];
                sAccessoryDevice[j] = sAccessoryDevice[j + 1];
            }
            sAccessoryCount--;
            sAccessory[sAccessoryCount] = NULL;
            sAccessoryDevice[sAccessoryCount] = nil;
            sProviderDirty = true;
            break;
        }
    pthread_mutex_unlock(&sLock);
    q3e_sense_provider_needs_rebuild();
    q3e_sense_pin(@"SENSE controller disconnected ('%@') — everything it held is released",
                  c.vendorName ?: @"(nil)");
}

void Q3E_Sense_Start(void) {
    if (sStarted)
        return;
    sStarted = YES;
    for (GCController *c in GCController.controllers)
        q3e_sense_adopt(c);
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        q3e_sense_adopt((GCController *)n.object);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        q3e_sense_forget((GCController *)n.object);
    }];
    // Logged at START, not only on a connect: the simulator has no controllers at
    // all, so "did the SpatialGamepad declaration survive plist processing into
    // the built product" would otherwise be unanswerable there — and that is the
    // one hardware claim the sim CAN prove.
    q3e_sense_pin(@"SENSE backend ready (%lu controller(s) present) — bundle GCSupportedGameControllers = %@",
                  (unsigned long)GCController.controllers.count,
                  [NSBundle.mainBundle objectForInfoDictionaryKey:@"GCSupportedGameControllers"] ?: @"(ABSENT)");
    q3e_sense_pin(@"SENSE bundle NSAccessoryTrackingUsageDescription = %@",
                  [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSAccessoryTrackingUsageDescription"] ?: @"(ABSENT)");
}

// ---------------------------------------------------------------------------
// The pad layer's filter. Conservative by construction: it fires only for a
// device that IS spatial-category, so an ordinary gamepad can never be taken
// away from the pad layer.
// ---------------------------------------------------------------------------
int Q3E_Sense_ShouldIgnorePad(const void *controller) {
    if (controller == NULL)
        return 0;
    Q3E_Sense_Start();   // the pad layer can reach this before anything else has run
    @autoreleasepool {
        GCController *c = (__bridge GCController *)controller;
        const int spatial = q3e_is_spatial(c) ? 1 : 0;
        static NSMutableSet *logged;
        if (logged == nil)
            logged = [NSMutableSet set];
        NSString *key = [NSString stringWithFormat:@"%@|%d", c.vendorName ?: @"(nil)", spatial];
        if (![logged containsObject:key]) {
            [logged addObject:key];
            q3e_sense_pin(@"SENSE pad filter: '%@' spatial=%d -> %@", c.vendorName ?: @"(nil)", spatial,
                          spatial ? @"IGNORED by the pad layer (the Sense path owns it)" : @"kept by the pad layer");
        }
        return spatial;
    }
}

int Q3E_Sense_Connected(void) {
    int n;
    pthread_mutex_lock(&sLock);
    n = (sHand[0] != nil) + (sHand[1] != nil);
    pthread_mutex_unlock(&sLock);
    return n + (Q3E_Sense_SynthActive() ? 2 : 0);
}

// ---------------------------------------------------------------------------
// Provider lifecycle
// ---------------------------------------------------------------------------
// NEVER called from the compositor thread. `ar_session_run` is a synchronous
// ARKit call of unbounded duration, and doing it from inside the per-frame poll
// with the state lock held would stall a compositor frame AND block the main
// thread's connect/disconnect handling behind it, for as long as ARKit felt like
// taking. The set of accessories only changes on a connect, a disconnect or a
// load completing, all of which are main-queue events, so this belongs there and
// the poll just reads whatever provider is currently published.
API_AVAILABLE(visionos(26.0))
static void q3e_sense_rebuild_provider(void) {
    ar_accessories_t                     set = NULL;
    ar_accessory_tracking_configuration_t cfg = NULL;
    int                                  n = 0;

    pthread_mutex_lock(&sLock);
    sProviderDirty = false;
    n = sAccessoryCount;
    if (n > 0) {
        set = ar_accessories_create();
        for (int i = 0; i < n; i++)
            if (sAccessory[i] != NULL)
                ar_accessories_add_accessory(set, sAccessory[i]);
    }
    pthread_mutex_unlock(&sLock);

    if (n == 0) {
        pthread_mutex_lock(&sLock);
        sProvider = NULL;
        pthread_mutex_unlock(&sLock);
        return;
    }
    cfg = ar_accessory_tracking_configuration_create();
    ar_accessory_tracking_configuration_set_accessories(cfg, set);
    // The SAME session the authorization was granted on — a fresh one would be
    // unauthorized again. And a SEPARATE session from the VR loop's world
    // tracking, deliberately: accessories load asynchronously and controllers
    // come and go, while the world provider is created once at loop start. If
    // this session never runs, the world is exactly as it was and only the hands
    // are missing.
    if (sSession == NULL)
        sSession = ar_session_create();
    {
        ar_accessory_tracking_provider_t p = ar_accessory_tracking_provider_create(cfg);
        ar_data_providers_t providers = ar_data_providers_create_with_data_providers(p, NULL);
        ar_session_run(sSession, providers);
        pthread_mutex_lock(&sLock);
        sProvider = p;
        pthread_mutex_unlock(&sLock);
    }
    q3e_sense_pin(@"SENSE accessory tracking running with %d accessory(s)", n);
}

// Schedule a rebuild on the main queue. Coalesced by the dirty flag, so a burst
// of connects costs one session run.
static void q3e_sense_provider_needs_rebuild(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(visionOS 26.0, *)) {
            bool want;
            pthread_mutex_lock(&sLock);
            want = sProviderDirty;
            pthread_mutex_unlock(&sLock);
            if (want)
                q3e_sense_rebuild_provider();
        }
    });
}

// ---------------------------------------------------------------------------
// Per-frame poll
// ---------------------------------------------------------------------------
static simd_float4x4 q3e_synth_matrix(float yawDeg, float pitchDeg, float rollDeg,
                                      float x, float y, float z) {
    const float d2r = (float)M_PI / 180.0f;
    float cy = cosf(yawDeg * d2r),   sy = sinf(yawDeg * d2r);
    float cp = cosf(pitchDeg * d2r), sp = sinf(pitchDeg * d2r);
    float cr = cosf(rollDeg * d2r),  sr = sinf(rollDeg * d2r);
    simd_float4x4 ry = matrix_identity_float4x4, rx = matrix_identity_float4x4;
    simd_float4x4 rz = matrix_identity_float4x4, m;
    ry.columns[0] = simd_make_float4(cy, 0, -sy, 0);
    ry.columns[2] = simd_make_float4(sy, 0, cy, 0);
    rx.columns[1] = simd_make_float4(0, cp, sp, 0);
    rx.columns[2] = simd_make_float4(0, -sp, cp, 0);
    rz.columns[0] = simd_make_float4(cr, sr, 0, 0);
    rz.columns[1] = simd_make_float4(-sr, cr, 0, 0);
    m = simd_mul(ry, simd_mul(rx, rz));
    m.columns[3] = simd_make_float4(x, y, z, 1.0f);
    return m;
}

void Q3E_Sense_Poll(Q3ESenseHand out[2]) {
    unsigned cur[2] = { 0u, 0u };
    int hands = 0;

    memset(out, 0, 2 * sizeof(Q3ESenseHand));
    out[0].originFromHand = out[1].originFromHand = matrix_identity_float4x4;

    // --- buttons ------------------------------------------------------------
    GCController *hnd[2];
    pthread_mutex_lock(&sLock);
    hnd[0] = sHand[0];
    hnd[1] = sHand[1];
    pthread_mutex_unlock(&sLock);
    for (int h = 0; h < 2; h++) {
        GCController *c = hnd[h];
        if (c == nil)
            continue;
        hands++;
        out[h].present = 1;
        out[h].buttons = q3e_sense_buttons(c);
        out[h].trigger = q3e_analog(c, q3e_name_trigger(), @"Trigger");
        out[h].grip = q3e_analog(c, q3e_name_grip(), @"Grip");
        GCControllerDirectionPad *d = q3e_stick(c);
        if (d) {
            out[h].stickX = d.xAxis.value;
            out[h].stickY = d.yAxis.value;
        }
    }

    // --- poses --------------------------------------------------------------
    if (@available(visionOS 26.0, *)) {
        ar_accessory_tracking_provider_t provider;
        bool dirty;
        pthread_mutex_lock(&sLock);
        provider = sProvider;
        dirty = sProviderDirty;
        pthread_mutex_unlock(&sLock);
        // The rebuild happens on the MAIN queue, never here — see the note on
        // q3e_sense_rebuild_provider. This frame simply uses whatever provider
        // exists right now, which is the correct behaviour anyway: a hand that
        // arrives mid-frame appears on the next one.
        if (dirty)
            q3e_sense_provider_needs_rebuild();

        if (provider != NULL) {
            ar_accessory_anchors_t anchors =
                ar_accessory_tracking_provider_get_latest_anchors(provider);
            if (anchors != NULL) {
                sLastAnchorCount = (int)ar_accessory_anchors_get_count(anchors);
                __block Q3ESenseHand *o = out;
                ar_accessory_anchors_enumerate_anchors(anchors, ^bool(ar_accessory_anchor_t anchor) {
                    if (!ar_accessory_anchor_is_tracked(anchor))
                        return true;
                    // Chirality can be unspecified (a controller on a table is in
                    // nobody's hand). Fall back to the accessory's INHERENT
                    // chirality, which a left/right pair always has, rather than
                    // guessing from position.
                    ar_accessory_chirality_t ch = ar_accessory_anchor_get_held_chirality(anchor);
                    int hand = -1;
                    if (ch == ar_accessory_chirality_left)
                        hand = 0;
                    else if (ch == ar_accessory_chirality_right)
                        hand = 1;
                    else {
                        ar_accessory_t acc = ar_accessory_anchor_get_accessory(anchor);
                        if (acc != NULL) {
                            ar_accessory_chirality_t inh = ar_accessory_get_inherent_chirality(acc);
                            if (inh == ar_accessory_chirality_left)
                                hand = 0;
                            else if (inh == ar_accessory_chirality_right)
                                hand = 1;
                        }
                    }
                    if (hand < 0)
                        return true;
                    o[hand].posed = 1;
                    o[hand].present = 1;
                    o[hand].held = ar_accessory_anchor_is_held(anchor) ? 1 : 0;
                    o[hand].originFromHand =
                        ar_accessory_anchor_get_origin_from_anchor_transform(anchor);
                    // Velocity from the anchor, never hand-differenced: ARKit
                    // already has it and our own delta would carry our poll jitter.
                    o[hand].velocity = ar_accessory_anchor_get_velocity(anchor);
                    return true;
                });
            }
        }
    }

    // --- synthetic override (simulator) -------------------------------------
    for (int h = 0; h < 2; h++) {
        if (!sSynthOn[h])
            continue;
        if (hnd[h] == nil)
            hands++;
        out[h].posed = 1;
        out[h].present = 1;
        out[h].held = 1;
        out[h].originFromHand = sSynthPose[h];
        out[h].velocity = simd_make_float3(0, 0, 0);
        out[h].buttons |= sSynthButtons[h];
        out[h].trigger = (sSynthButtons[h] & Q3E_SENSE_TRIGGER) ? 1.0f : 0.0f;
        out[h].grip = (sSynthButtons[h] & Q3E_SENSE_GRIP) ? 1.0f : 0.0f;
        out[h].stickX = sSynthStick[h][0];
        out[h].stickY = sSynthStick[h][1];
    }

    // Buttons follow PRESENCE, not pose. A controller whose pose ARKit has
    // momentarily lost is still in a hand with a finger on the trigger, and
    // deafening it would also make every button dead for the whole session on a
    // headset where accessory tracking was declined — the pose is what the aim
    // and the weapon need, not what a button press means. What releases a held
    // button is the controller GOING: a disconnect (q3e_sense_forget pushes the
    // up edges), or presence dropping to zero here, or the session ending
    // (Q3E_VR_ResetHands). A battery that dies mid-fire disconnects, which is
    // the first of those.
    for (int h = 0; h < 2; h++)
        cur[h] = out[h].present ? out[h].buttons : 0u;

    {
        const float st[4] = { out[0].stickX, out[0].stickY, out[1].stickX, out[1].stickY };
        pthread_mutex_lock(&sLock);
        q3e_sense_fold_edges_locked(cur, hands, st);
        pthread_mutex_unlock(&sLock);
    }

    sTrackedMask = (out[0].posed ? 1 : 0) | (out[1].posed ? 2 : 0);
    sPollCount++;
}

int Q3E_Sense_UISample(unsigned *btn, float *stick) {
    @autoreleasepool {
        GCController *hnd[2];
        unsigned cur[2] = { 0u, 0u };
        int n = 0;
        if (!btn || !stick)
            return 0;
        btn[0] = btn[1] = 0u;
        stick[0] = stick[1] = stick[2] = stick[3] = 0.0f;
        pthread_mutex_lock(&sLock);
        hnd[0] = sHand[0];
        hnd[1] = sHand[1];
        pthread_mutex_unlock(&sLock);
        for (int h = 0; h < 2; h++) {
            GCController *c = hnd[h];
            if (c != nil) {
                GCControllerDirectionPad *d;
                n++;
                btn[h] = q3e_sense_buttons(c);
                d = q3e_stick(c);
                if (d) {
                    stick[h * 2 + 0] = d.xAxis.value;
                    stick[h * 2 + 1] = d.yAxis.value;
                }
            }
            // Injected hands answer here too, or the simulator could never test
            // the menus or the flat merge.
            if (sSynthOn[h]) {
                if (c == nil)
                    n++;
                btn[h] |= sSynthButtons[h];
                stick[h * 2 + 0] = sSynthStick[h][0];
                stick[h * 2 + 1] = sSynthStick[h][1];
            }
            cur[h] = btn[h];
        }
        // The SAME accumulator the compositor poll feeds. In VR both run and the
        // second fold is a no-op (the level has not changed between them); in 2D
        // and 3D this is the only poll there is, and without the fold the one
        // edge detector would go blind exactly where the flat merge needs it.
        pthread_mutex_lock(&sLock);
        q3e_sense_fold_edges_locked(cur, n, stick);
        pthread_mutex_unlock(&sLock);
        return n;
    }
}

// ---------------------------------------------------------------------------
// Haptics — per hand, short bursts. Built on demand and kept, so a shot does not
// pay for engine creation every time.
// ---------------------------------------------------------------------------
static CHHapticEngine *sHapticEngine[2];
static int             sHapticStarting[2];
static int             sHapticSeq;
static double          sHapticLastLog;

// WHY A PULSE DID OR DID NOT ARRIVE, from the log alone. Without this, "the call
// site never ran", "it ran and the engine was not up yet", "it ran and there is
// no controller for that hand" and "it ran, it played, and it was too weak to
// feel" are four hypotheses with one symptom between them. The line is throttled
// so a held trigger cannot flood the file, and every FAILURE is logged.
static void q3e_haptic_log(int hand, float strength, float duration,
                           const char *why, const char *outcome) {
    const double now = CFAbsoluteTimeGetCurrent();
    char line[256];
    sHapticSeq++;
    if (now - sHapticLastLog < 0.25 && strcmp(outcome, "played") == 0)
        return;
    sHapticLastLog = now;
    snprintf(line, sizeof(line), "HAPTIC #%d %s hand=%s str=%.2f dur=%.3fs -> %s",
             sHapticSeq, why ? why : "-", hand ? "right" : "left", strength, duration, outcome);
    Q3E_BlackBox_Str(line);
}

void Q3E_Sense_Haptic(int hand, float strength, float duration, const char *why) {
    if (hand < 0 || hand > 1 || !(strength > 0.0f))
        return;
    GCController *c;
    pthread_mutex_lock(&sLock);
    c = sHand[hand];
    pthread_mutex_unlock(&sLock);
    if (c == nil) {
        q3e_haptic_log(hand, strength, duration, why, "NO CONTROLLER for that hand");
        return;
    }

    CHHapticEngine *eng = sHapticEngine[hand];
    if (eng == nil) {
        // Creating and starting a CHHapticEngine is synchronous and can take
        // milliseconds; paying that inside the frame that fires the shot would
        // show up as a hitch at exactly the worst moment. So the engine is built
        // once, asynchronously, and the first pulse that finds it missing simply
        // goes unfelt rather than stalling the frame.
        if (!sHapticStarting[hand]) {
            sHapticStarting[hand] = 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                GCDeviceHaptics *h = c.haptics;
                CHHapticEngine  *e = h ? [h createEngineWithLocality:GCHapticsLocalityDefault] : nil;
                NSError         *err = nil;
                if (e == nil)
                    return;
                [e startAndReturnError:&err];
                if (err)
                    return;
                e.autoShutdownEnabled = YES;
                sHapticEngine[hand] = e;
            });
        }
        q3e_haptic_log(hand, strength, duration, why,
                       "engine not up yet (built asynchronously; this pulse is skipped)");
        return;
    }

    NSError *err = nil;
    CHHapticEventParameter *i =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:strength];
    CHHapticEventParameter *s =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.7f];
    // A TICK is a transient, not a short continuous buzz. On these actuators a
    // 20 ms continuous event is close to nothing; the transient event type is
    // designed for exactly this ("you touched something") and reads as a crisp
    // tap. Anything at or under 40 ms takes that path.
    const BOOL tick = (duration <= 0.04f);
    CHHapticEvent *ev = tick
        ? [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                        parameters:@[ i, s ] relativeTime:0]
        : [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                        parameters:@[ i, s ] relativeTime:0 duration:duration];
    CHHapticPattern *pat = [[CHHapticPattern alloc] initWithEvents:@[ ev ] parameters:@[] error:&err];
    if (err || pat == nil) {
        q3e_haptic_log(hand, strength, duration, why, "pattern build FAILED");
        return;
    }
    id<CHHapticPatternPlayer> player = [eng createPlayerWithPattern:pat error:&err];
    if (err || player == nil) {
        q3e_haptic_log(hand, strength, duration, why, "player create FAILED");
        return;
    }
    [player startAtTime:0 error:&err];
    q3e_haptic_log(hand, strength, duration, why, err ? "start FAILED" : "played");
}

// The settings gate lives here so every call site is covered by one switch, and
// a suppressed pulse still says so — "off in settings" and "never fired" are
// different bugs.
extern int q3e_vrHaptics;   // Q3EVRGlue.c, driven by the Controller Haptics row

void Q3E_VR_Haptic(int hand, float strength, float duration, const char *why) {
    if (!q3e_vrHaptics) {
        q3e_haptic_log(hand, strength, duration, why,
                       "SUPPRESSED — Controller Haptics is off in settings");
        return;
    }
    Q3E_Sense_Haptic(hand, strength, duration, why);
}

// ---------------------------------------------------------------------------
// Status rows. A device round has to answer "did the declaration work" from the
// settings sheet and the black box alone.
// ---------------------------------------------------------------------------
static char sStatusA[192], sStatusB[192];

const char *Q3E_Sense_StatusControllers(void) {
    @autoreleasepool {
        NSArray<GCController *> *cs = GCController.controllers;
        if (cs.count == 0) {
            snprintf(sStatusA, sizeof(sStatusA), "none connected");
            return sStatusA;
        }
        NSMutableString *s = [NSMutableString string];
        int nSpatial = 0;
        for (GCController *c in cs) {
            NSString *cat = @"?";
            if (@available(visionOS 26.0, *))
                cat = c.productCategory ?: @"?";
            if (q3e_is_spatial(c))
                nSpatial++;
            [s appendFormat:@"[%@ %lub/%lud] ", cat,
                            (unsigned long)c.physicalInputProfile.buttons.allKeys.count,
                            (unsigned long)c.physicalInputProfile.dpads.allKeys.count];
        }
        snprintf(sStatusA, sizeof(sStatusA), "%lu pad(s), %d spatial: %s",
                 (unsigned long)cs.count, nSpatial, s.UTF8String);
        return sStatusA;
    }
}

const char *Q3E_Sense_StatusTracking(void) {
    if (sAuthState == -1)
        snprintf(sStatusB, sizeof(sStatusB), "accessory permission DENIED");
    else if (sAuthState == 0)
        snprintf(sStatusB, sizeof(sStatusB), "awaiting permission%s", sAuthAsked ? "" : " (not asked)");
    else if (sLoadOK == 0 && sLoadFail == 0)
        snprintf(sStatusB, sizeof(sStatusB), "allowed, no controller seen");
    else if (sLoadOK == 0)
        snprintf(sStatusB, sizeof(sStatusB), "allowed, %d load fail (err %d)%s",
                 sLoadFail, sLoadFailCode, sLoadFailCode == 1200 ? " — aggregate MFi" : "");
    else
        snprintf(sStatusB, sizeof(sStatusB), "%d loaded, %d anchor(s), %s%s%s",
                 sLoadOK, sLastAnchorCount, (sTrackedMask & 1) ? "L" : "-",
                 (sTrackedMask & 2) ? "R" : "-", Q3E_Sense_SynthActive() ? " (synthetic)" : "");
    return sStatusB;
}

const char *Q3E_Sense_InventoryText(void) {
    return sInventory.length ? sInventory.UTF8String : "(no controller has connected)";
}

// ---------------------------------------------------------------------------
// Synthetic injection
// ---------------------------------------------------------------------------
void Q3E_Sense_SetSynthHand(int hand, int on, float yaw, float pitch, float roll,
                            float x, float y, float z) {
    if (hand < 0 || hand > 1)
        return;
    sSynthOn[hand] = on ? 1 : 0;
    if (on) {
        sSynthPose[hand] = q3e_synth_matrix(yaw, pitch, roll, x, y, z);
        sSynthYPR[hand][0] = yaw; sSynthYPR[hand][1] = pitch; sSynthYPR[hand][2] = roll;
        sSynthXYZ[hand][0] = x;   sSynthXYZ[hand][1] = y;     sSynthXYZ[hand][2] = z;
    } else {
        sSynthButtons[hand] = 0;
        sSynthStick[hand][0] = sSynthStick[hand][1] = 0.0f;
    }
}

void Q3E_Sense_SetSynthButtons(int hand, unsigned buttons) {
    if (hand >= 0 && hand <= 1)
        sSynthButtons[hand] = buttons;
}

void Q3E_Sense_SetSynthStick(int hand, float x, float y) {
    if (hand < 0 || hand > 1)
        return;
    sSynthStick[hand][0] = x;
    sSynthStick[hand][1] = y;
}

int Q3E_Sense_SynthActive(void) { return sSynthOn[0] || sSynthOn[1]; }

void Q3E_Sense_SynthDescribe(char *buf, int n) {
    snprintf(buf, (size_t)n,
             "L(on%d,ypr%.0f/%.0f/%.0f,xyz%.2f/%.2f/%.2f,btn0x%02x,stick%.2f/%.2f) "
             "R(on%d,ypr%.0f/%.0f/%.0f,xyz%.2f/%.2f/%.2f,btn0x%02x,stick%.2f/%.2f)",
             sSynthOn[0], sSynthYPR[0][0], sSynthYPR[0][1], sSynthYPR[0][2],
             sSynthXYZ[0][0], sSynthXYZ[0][1], sSynthXYZ[0][2],
             sSynthButtons[0], sSynthStick[0][0], sSynthStick[0][1],
             sSynthOn[1], sSynthYPR[1][0], sSynthYPR[1][1], sSynthYPR[1][2],
             sSynthXYZ[1][0], sSynthXYZ[1][1], sSynthXYZ[1][2],
             sSynthButtons[1], sSynthStick[1][0], sSynthStick[1][1]);
}
