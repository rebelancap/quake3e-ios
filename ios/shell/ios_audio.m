/*
 * ios_audio.m — AVAudioSession policy + the master mix gain.
 *
 * Two knobs, both surfaced in the iOS Settings "Audio" section:
 *
 *   q3e_audio_mode   what happens when another app is already playing (Music, a
 *                    podcast, ...). Three of the five modes are pure session
 *                    category/option choices that iOS enforces for us; the other
 *                    two ("lower/mute game audio") need US to attenuate our own
 *                    mix, because iOS will duck OTHER apps for you and never you.
 *   q3e_master_vol   a plain master volume, multiplied into the same gain.
 *
 * Recipe + traps: ~/dev/IOS-AUDIO-SESSION-GUIDE.md (written from vkQuake-ios
 * 1.0.6). Two of its three traps do not apply here and one does:
 *
 *   TRAP 1 (SDL's UpdateAudioSession overwrites your category) — N/A: this port
 *     has no SDL. ios_snd.c is a direct AudioQueue backend, so the session is
 *     ours alone. The 4 Hz poll below is kept anyway, but only to notice another
 *     app STARTING (nothing posts a notification for that) — not to fight SDL.
 *   TRAP 2 (the first setActive:YES is the only one that can interrupt other
 *     audio) — APPLIES. Our first activation is Q3E_ActivateAudioSession, called
 *     from SNDDMA_Init, so the category is chosen from the saved setting there,
 *     before the session goes active. No SDL_AUDIO_CATEGORY env hint needed.
 *   TRAP 3 (never implement the gain with s_volume) — APPLIES, and is why the
 *     gain is AudioQueue's own kAudioQueueParam_Volume (ios_snd.c) instead:
 *     s_volume is CVAR_ARCHIVE, so a ducked value would be written to config on
 *     resign-active and become the next launch's base volume — a ratchet that
 *     walks the player's real volume down over days. The queue parameter sits
 *     downstream of the whole mixer (sfx, music, cinematics) and is persisted
 *     nowhere, so the engine's own Sound/Music sliders keep working untouched.
 */
#import "ios_audio.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <math.h>

// ios_snd.c (pure C AudioQueue backend)
void Q3E_SND_Pause(void);
void Q3E_SND_Resume(void);
void Q3E_SND_SetGain(float g);

// How far "Lower Game Audio" pulls the game down: -13 dB. Loud enough to still
// hear an approaching rocket, quiet enough to follow a podcast over it.
#define Q3E_DUCK_GAIN 0.22f
// Gain ramp time constant. A hard cut when music starts is audible as a click on
// a sustained ambient loop; ~0.2 s of exponential glide is not.
#define Q3E_GAIN_TAU  0.20f

NSArray<NSString *> *Q3E_AudioModeTitles(void) {
    return @[ @"Stop Other Audio", @"Play Both", @"Lower Other Audio",
              @"Lower Game Audio", @"Mute Game Audio" ];
}

NSArray<NSString *> *Q3E_AudioModeDetails(void) {
    return @[
        @"Music and podcasts stop when Quake3e starts.",
        @"Both play together, neither one quieter.",
        @"Music and podcasts drop to the background; game audio stays full.",
        @"Game audio drops to the background while another app is playing.",
        @"Game audio goes silent while another app is playing.",
    ];
}

static float q3e_setting_f(NSString *key, float fallback) {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? v.floatValue : fallback;
}

static Q3EAudioMode q3e_audio_mode(void) {
    int m = (int)lroundf(q3e_setting_f(Q3E_DEF_AUDIO_MODE, (float)Q3E_AUDIO_DUCK_OTHERS));
    if (m < 0 || m >= Q3E_AUDIO_MODE_COUNT) m = Q3E_AUDIO_DUCK_OTHERS;
    return (Q3EAudioMode)m;
}

// The category/options this mode wants. Playback throughout — a game must keep
// playing with the hardware Ring/Silent switch off, which is what Playback buys
// over Ambient; only the mixability bits differ.
static NSUInteger q3e_audio_options(Q3EAudioMode m) {
    switch (m) {
        case Q3E_AUDIO_STOP_OTHERS:
            return 0; // non-mixable: activating the session interrupts the other app
        case Q3E_AUDIO_DUCK_OTHERS:
            return AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDuckOthers;
        default:
            return AVAudioSessionCategoryOptionMixWithOthers; // we do our own attenuating, if any
    }
}

static BOOL   q3e_other_playing;    // cached: another app is producing audio
static float  q3e_gain_target = 1;  // where the mix gain is heading
static float  q3e_gain_cur = -1;    // what the queue currently has (-1 = never set)
static NSTimer *q3e_audio_timer;

static BOOL q3e_query_other_playing(AVAudioSession *s) {
    // isOtherAudioPlaying is the broad "someone else has sound out";
    // secondaryAudioShouldBeSilencedHint is the narrower "another app is playing
    // PRIMARY audio (Music, a podcast)". Either means the player is listening to
    // something that is not us.
    return s.isOtherAudioPlaying || s.secondaryAudioShouldBeSilencedHint;
}

static void q3e_audio_recompute_target(void) {
    Q3EAudioMode m = q3e_audio_mode();
    float duck = 1.0f;
    if (q3e_other_playing) {
        if (m == Q3E_AUDIO_DUCK_GAME)      duck = Q3E_DUCK_GAIN;
        else if (m == Q3E_AUDIO_MUTE_GAME) duck = 0.0f;
    }
    float master = q3e_setting_f(Q3E_DEF_MASTER_VOL, 1.0f);
    master = fmaxf(0.0f, fminf(1.0f, master));
    float t = master * duck;
    if (fabsf(t - q3e_gain_target) > 0.0005f) {
        NSLog(@"Q3E audio: mix gain -> %.2f (master %.2f, duck %.2f, other %s)",
              t, master, duck, q3e_other_playing ? "yes" : "no");
    }
    q3e_gain_target = t;
}

void Q3E_Audio_Apply(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance;
    Q3EAudioMode m = q3e_audio_mode();
    NSUInteger want = q3e_audio_options(m);
    NSError *err = nil;

    if (![s.category isEqualToString:AVAudioSessionCategoryPlayback] || s.categoryOptions != want) {
        if (![s setCategory:AVAudioSessionCategoryPlayback
                       mode:AVAudioSessionModeDefault
                    options:want
                      error:&err]) {
            NSLog(@"Q3E audio: setCategory(mode %d, opts %lu) failed: %@", (int)m, (unsigned long)want, err);
        } else {
            NSLog(@"Q3E audio: session -> Playback opts %lu (mode %d)", (unsigned long)want, (int)m);
        }
    }

    // Switching TO the non-mixable mode mid-session only interrupts the other app
    // when the session (re)activates, and setActive:YES on an already-active
    // session is a no-op — so if the other app is still going, bounce it once.
    // Losing that race is survivable: the category is chosen before the FIRST
    // activation at boot, so the next launch is right regardless.
    if (m == Q3E_AUDIO_STOP_OTHERS) {
        [s setActive:YES error:nil];
        if (q3e_query_other_playing(s)) {
            [s setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
            if (![s setActive:YES error:&err]) {
                NSLog(@"Q3E audio: reactivate to interrupt other audio failed: %@", err);
            }
        }
    }

    q3e_other_playing = q3e_query_other_playing(s);
    q3e_audio_recompute_target();
}

static void q3e_reactivate_session(void) {
    NSError *err = nil;
    if (![AVAudioSession.sharedInstance setActive:YES error:&err]) {
        NSLog(@"Q3E: audio reactivate error: %@", err);
    }
}

// Called from SNDDMA_Init (ios_snd.c) BEFORE the AudioQueue is created — i.e.
// this is the session's FIRST activation, the only one that can interrupt other
// apps' audio, so the mode's category must be in place here.
void Q3E_ActivateAudioSession(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance;
    NSError *err = nil;
    Q3EAudioMode m = q3e_audio_mode();

    if (![s setCategory:AVAudioSessionCategoryPlayback
                   mode:AVAudioSessionModeDefault
                options:q3e_audio_options(m)
                  error:&err]) {
        NSLog(@"Q3E: audio category error: %@", err);
    }
    if (![s setActive:YES error:&err]) {
        NSLog(@"Q3E: audio activate error: %@", err);
    }
    q3e_other_playing = q3e_query_other_playing(s);
    q3e_audio_recompute_target();
    NSLog(@"Q3E audio: boot mode %d (%@), other audio %s", (int)m,
          Q3E_AudioModeTitles()[m], q3e_other_playing ? "playing" : "silent");

    static BOOL observing = NO;
    if (observing) return;
    observing = YES;

    // A phone call / Siri / alarm interrupts and stops the AudioQueue; the engine
    // keeps mixing into a stalled queue and the game is silent forever after.
    // Pause on Began; reactivate the session and restart the queue on Ended.
    [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification
        object:s queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
        if (type == AVAudioSessionInterruptionTypeBegan) {
            Q3E_SND_Pause();
            NSLog(@"Q3E: audio interruption began — queue paused");
        } else if (type == AVAudioSessionInterruptionTypeEnded) {
            Q3E_Audio_Apply();          // an interruption can drop our category
            q3e_reactivate_session();
            Q3E_SND_Resume();
            NSLog(@"Q3E: audio interruption ended — session reactivated, queue resumed");
        }
    }];

    // Route change (headphones/BT unplug, dock): the AudioQueue follows the new
    // route automatically; re-assert the session so a system deactivation on the
    // transition can't leave us silently muted.
    [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionRouteChangeNotification
        object:s queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSInteger reason = [n.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue];
        if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
            q3e_reactivate_session();
        }
        Q3E_Audio_Apply();
        NSLog(@"Q3E: audio route change (reason %ld)", (long)reason);
    }];

    // The one thing notifications don't cover: the player hitting play in another
    // app while we are frontmost posts nothing at all. Poll at 4 Hz — off the
    // frame path deliberately, since reading session properties is a hop to
    // mediaserverd and has no business inside a measured frame.
    for (NSNotificationName n in @[ AVAudioSessionSilenceSecondaryAudioHintNotification,
                                    UIApplicationDidBecomeActiveNotification ]) {
        [NSNotificationCenter.defaultCenter addObserverForName:n object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { Q3E_Audio_Apply(); }];
    }
    q3e_audio_timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        AVAudioSession *ss = AVAudioSession.sharedInstance;
        BOOL other = q3e_query_other_playing(ss);
        if (other != q3e_other_playing) {
            q3e_other_playing = other;
            NSLog(@"Q3E audio: other app audio %s", other ? "started" : "stopped");
        }
        if (ss.categoryOptions != q3e_audio_options(q3e_audio_mode()) ||
            ![ss.category isEqualToString:AVAudioSessionCategoryPlayback]) {
            Q3E_Audio_Apply();  // something changed it under us — put it back
        }
        q3e_audio_recompute_target();
    }];
}

void Q3E_Audio_Tick(void) {
    double now = CACurrentMediaTime();
    static double last_frame;
    double dt = last_frame ? now - last_frame : 0;
    last_frame = now;

    // Glide toward the target so duck/unduck and slider drags are not a step.
    if (q3e_gain_cur < 0.0f) {
        q3e_gain_cur = q3e_gain_target;   // first frame: no ramp up from silence
    } else if (dt > 0 && dt < 0.5) {
        float a = 1.0f - expf(-(float)dt / Q3E_GAIN_TAU);
        q3e_gain_cur += (q3e_gain_target - q3e_gain_cur) * a;
        if (fabsf(q3e_gain_target - q3e_gain_cur) < 0.001f) q3e_gain_cur = q3e_gain_target;
    } else {
        q3e_gain_cur = q3e_gain_target;   // first frame after a pause/hitch: snap
    }

    static float applied = -1;
    if (q3e_gain_cur != applied) {
        applied = q3e_gain_cur;
        Q3E_SND_SetGain(q3e_gain_cur);
    }
}
