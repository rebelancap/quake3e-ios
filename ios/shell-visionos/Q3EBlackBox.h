#pragma once

// File-based flight recorder for visionOS debugging (3D design notes §3).
// --console over Wi-Fi drops and the app suspends when the headset is off, so remote
// NSLog is unreliable. This writes Documents/blackbox.log, which the user can read in
// the headset (Files -> On My Vision Pro -> Quake3e) or the Mac can pull with:
//   xcrun devicectl device copy from --user mobile --domain-type appDataContainer \
//     --domain-identifier com.rebelancap.quake3e --source Documents/blackbox.log ...
//
// The file has TWO sections. A single rolling buffer eats its own head: the entry
// lines, the first drawable contract and the mode transitions — the things the file
// exists to report — are the first casualties of a front-truncating buffer rewritten
// at compositor rate. So:
//
//   PINNED  — entry/exit, the first contract dump, mode transitions. Appended once,
//             never truncated (within a budget; overflow spills into the tail and
//             says so).
//   ROLLING — periodic/pacing lines. Truncates only its own front.
//
// Writes are coalesced to ~1 Hz; Q3E_BlackBox_Flush() writes immediately (loop exit,
// resign-active, an explicit dump command) and pinned lines schedule a prompt write
// of their own, so the lines that matter reach disk without waiting a full second.
// The previous session's file is kept as blackbox-prev.log.

void Q3E_BlackBox_Init(const char *documentsPath);

// Rolling tail.
void Q3E_BlackBox(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
// Pinned region.
void Q3E_BlackBox_Pin(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// Non-variadic wrappers callable from Swift.
void Q3E_BlackBox_Str(const char *s);
void Q3E_BlackBox_PinStr(const char *s);

// Unthrottled write. Safe to call from any thread.
void Q3E_BlackBox_Flush(void);
