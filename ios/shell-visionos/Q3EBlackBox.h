#pragma once

// File-based flight recorder for visionOS 3D debugging (3D design notes §3).
// --console over Wi-Fi drops and the app suspends when the headset is off, so remote
// NSLog is unreliable. This writes to Documents/blackbox.log (truncated at boot with
// a marker); pull it after a wedge with:
//   xcrun devicectl device copy from --user mobile --domain-type appDataContainer \
//     --domain-identifier com.rebelancap.quake3e --source Documents/blackbox.log ...
void Q3E_BlackBox_Init(const char *documentsPath);
void Q3E_BlackBox(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
// Non-variadic wrapper callable from Swift.
void Q3E_BlackBox_Str(const char *s);
