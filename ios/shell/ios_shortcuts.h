// ios_shortcuts.h — bridging surface for Swift (App Intents) into the
// C shell. Also used by AppShell.m for URL-scheme launches.
#ifndef IOS_SHORTCUTS_H
#define IOS_SHORTCUTS_H

#ifdef __cplusplus
extern "C" {
#endif

// Request that the game run mod <mod> ("baseq3", "q3ut4", "cpma", ...).
// Safe to call at any time: before engine boot it shapes the boot
// command line; after boot it hot-switches via game_restart. Unknown
// mod dirs are ignored with a log line.
void Q3E_RequestMod(const char *mod);

#ifdef __cplusplus
}
#endif

#endif
