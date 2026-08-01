#pragma once
#import <Foundation/Foundation.h>

// How Quake3e's sound behaves when another app (Music, a podcast, ...) is
// already playing. Stored in q3e_audio_mode; see ios_audio.m and
// ~/dev/IOS-AUDIO-SESSION-GUIDE.md.
typedef enum {
    Q3E_AUDIO_STOP_OTHERS  = 0, // non-mixable session: the other app is interrupted
    Q3E_AUDIO_MIX          = 1, // both at full volume
    Q3E_AUDIO_DUCK_OTHERS  = 2, // the other app is lowered by iOS (default)
    Q3E_AUDIO_DUCK_GAME    = 3, // WE lower ourselves while the other app plays
    Q3E_AUDIO_MUTE_GAME    = 4, // WE go silent while the other app plays
    Q3E_AUDIO_MODE_COUNT
} Q3EAudioMode;

#define Q3E_DEF_AUDIO_MODE @"q3e_audio_mode"
#define Q3E_DEF_MASTER_VOL @"q3e_master_vol"

// Row titles / one-line explanations for the settings picker (index = mode).
NSArray<NSString *> *Q3E_AudioModeTitles(void);
NSArray<NSString *> *Q3E_AudioModeDetails(void);

// Re-assert the session category/options and recompute the mix gain. Called from
// Q3E_Settings_ApplyAll, from the 4 Hz poll, and on every session notification.
void Q3E_Audio_Apply(void);
// Per-frame: ramps the engine's master gain toward its target. Pure float math —
// the system-property polling lives on a 4 Hz timer so it stays off the frame path.
void Q3E_Audio_Tick(void);
