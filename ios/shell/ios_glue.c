// ios_glue.c — everything the engine links against that unix_main.c and
// the SDL backends provided on desktop. Compiled against engine headers;
// the ObjC/Metal side lives in ios_metal.m behind plain C calls.

#include <unistd.h>
#include <pthread.h>

#include "client/client.h"
#include "server/server.h"          // svs.time — authoritative sim clock (sim-rate)
#include "renderercommon/tr_public.h"

// ---- ios_metal.m ----
int   Q3E_LayerWidth(void);
int   Q3E_LayerHeight(void);
int   Q3E_DisplayMaxFPS(void);
void *Q3E_GetInstanceProcAddr(void *instance, const char *name);
int   Q3E_CreateMetalSurface(void *instance, void **surfaceOut);

static char q3e_docs[1024];

void Q3E_SetDocumentsPath(const char *path) {
	Q_strncpyz(q3e_docs, path, sizeof(q3e_docs));
}

// ---- touch layout editor (ios_input.m) ----
// Registered as console commands so the editor is reachable from the remote
// console bridge. Without this the drag path could only ever be exercised by a
// finger on glass: injected UIKit touches do not reach the touch handlers on a
// simulator (vkQuake, 2026-07-28).
void Q3E_Input_BeginLayoutEdit(void);
void Q3E_Input_ToggleLayoutEdit(void);
void Q3E_Input_FakeTouch(float nx, float ny, int phase);
void Q3E_Input_PrintLayout(void);

static void Q3E_TouchEdit_f(void) {
	if (Cmd_Argc() == 2 && !strcmp(Cmd_Argv(1), "print")) {
		Q3E_Input_PrintLayout();
		return;
	}
	Q3E_Input_ToggleLayoutEdit();
}

static void Q3E_FakeTouch_f(void) {
	const char *ph;
	int phase;
	if (Cmd_Argc() != 4) {
		Com_Printf("q3e_faketouch <x 0..1> <y 0..1> <down|move|up>\n");
		return;
	}
	ph = Cmd_Argv(3);
	phase = !strcmp(ph, "down") ? 0 : (!strcmp(ph, "move") ? 1 : (!strcmp(ph, "layout") ? 3 : 2));
	Q3E_Input_FakeTouch((float)atof(Cmd_Argv(1)), (float)atof(Cmd_Argv(2)), phase);
}

// ---- remote console bridge (ios_console.m) ----
void Q3E_ConsoleBridge_Start(void);
int  Q3E_RemoteConsoleEnabled(void);   // ios_settings.m (dev builds only)
void Q3E_ConsoleBridge_Drain(void);
void Q3E_ConsoleBridge_Output(const char *text);
static qboolean q3e_bridge_active = qfalse;

// The settings switch must go through THIS, not straight to
// Q3E_ConsoleBridge_Start(). Opening the socket is only half of it:
// q3e_bridge_active is what makes Q3E_Frame drain queued commands into Cbuf and
// Sys_Print tee output back to the client. Starting the listener alone gave a
// port that accepted connections, echoed the banner, and then ignored
// everything — which is exactly how it behaved when toggled on mid-session.
void Q3E_EnableConsoleBridge(void) {
	q3e_bridge_active = qtrue;
	Q3E_ConsoleBridge_Start();
}

void q3e_console_command(const char *text) {
	Cbuf_AddText(text);
	Cbuf_AddText("\n");
}

// Which side is calling Q3E_Frame right now: 0 = the main-thread display link,
// 1 = a dedicated engine thread (visionOS VR). Exactly one owner at any moment.
// It lives here, in the shared shell, because code shared with the iPhone build
// asks the question and only the visionOS build can ever answer 1.
volatile int q3e_frame_owner = 0;

// ---- input shims (called from ios_input.m) ----

void Q3E_Input_Frame(void); // ios_input.m
void Q3E_Audio_Tick(void);  // ios_audio.m — ramps the master gain (float math only)

// PRODUCER FUNNEL.
//
// Sys_QueEvent's ring is a plain unlocked ring buffer, and Cbuf_AddText is no
// safer. That was fine while every producer and the consumer were the main
// thread. In VR the engine runs on its own thread while touch handlers, the
// settings sheet, scene notifications and the compositor keep producing from
// main — so every producer goes through this locked queue instead, drained at
// the top of Q3E_Frame by whichever thread owns the engine.
//
// It is unconditional, not VR-gated: a funnel that only runs in one mode is a
// funnel nobody exercises. The cost is one lock per input event and at most one
// frame of latency, uniform across modes.
typedef enum {
	Q3E_PROD_MOUSE = 0,
	Q3E_PROD_JOYAXIS,
	Q3E_PROD_KEY,
	Q3E_PROD_CHAR,
	Q3E_PROD_WRITECONFIG
} q3e_prod_type_t;

#define Q3E_PROD_QUEUE_SIZE 512

typedef struct {
	int type;
	int a, b;
} q3e_prod_t;

// Input events ride a ring; console commands ride a separate growable list.
// The split is deliberate, and both halves mirror the invariants of the
// Sys_QueEvent ring this fronts:
//   * sequential mouse deltas COALESCE, so a busy producer cannot fill the ring
//     with motion that means the same thing as one entry;
//   * an overflow drops the OLDEST event, never the newest — dropping the newest
//     throws away the key-up while keeping the key-down, which is a stuck key;
//   * commands are NEVER dropped. A dropped `vid_restart` strands VR entry
//     half-way, and during a map load the ring genuinely does fill.
static q3e_prod_t q3e_prodq[Q3E_PROD_QUEUE_SIZE];
static int q3e_prod_head = 0;   // next write
static int q3e_prod_tail = 0;   // next read
static int q3e_prod_dropped = 0;
static int q3e_prod_reported = 0;
static pthread_mutex_t q3e_prod_lock = PTHREAD_MUTEX_INITIALIZER;

static char **q3e_cmdq = NULL;
static int    q3e_cmdq_count = 0;
static int    q3e_cmdq_cap = 0;
static int    q3e_cmdq_lost = 0;   // only ever nonzero if malloc itself failed
static volatile int q3e_config_write_pending = 0;
// Queued vs EXECUTED. The drain takes the whole list in one go, so "the queue is
// empty" goes true the instant the engine thread picks the work UP — a barrier
// built on it waves through while a vid_restart is still running, and whatever
// runs next is a second thread inside the engine. These two counters make the
// barrier mean what it says.
static unsigned q3e_cmd_seq = 0;        // commands accepted
static volatile unsigned q3e_cmd_done = 0;   // commands finished executing

static void q3e_prod_push(int type, int a, int b) {
	int next;
	pthread_mutex_lock(&q3e_prod_lock);
	if (type == Q3E_PROD_MOUSE && q3e_prod_head != q3e_prod_tail) {
		const int last = (q3e_prod_head + Q3E_PROD_QUEUE_SIZE - 1) % Q3E_PROD_QUEUE_SIZE;
		if (q3e_prodq[last].type == Q3E_PROD_MOUSE) {
			q3e_prodq[last].a += a;      // one motion, however many samples made it
			q3e_prodq[last].b += b;
			pthread_mutex_unlock(&q3e_prod_lock);
			return;
		}
	}
	next = (q3e_prod_head + 1) % Q3E_PROD_QUEUE_SIZE;
	if (next == q3e_prod_tail) {
		q3e_prod_tail = (q3e_prod_tail + 1) % Q3E_PROD_QUEUE_SIZE;   // drop the oldest
		q3e_prod_dropped++;
	}
	q3e_prodq[q3e_prod_head].type = type;
	q3e_prodq[q3e_prod_head].a = a;
	q3e_prodq[q3e_prod_head].b = b;
	q3e_prod_head = next;
	pthread_mutex_unlock(&q3e_prod_lock);
}

// Must hold q3e_prod_lock.
static void q3e_cmd_push_locked(const char *cmd) {
	if (q3e_cmdq_count == q3e_cmdq_cap) {
		const int want = q3e_cmdq_cap ? q3e_cmdq_cap * 2 : 32;
		char **grown = realloc(q3e_cmdq, (size_t)want * sizeof(char *));
		if (!grown) {
			q3e_cmdq_lost++;
			return;
		}
		q3e_cmdq = grown;
		q3e_cmdq_cap = want;
	}
	q3e_cmdq[q3e_cmdq_count] = strdup(cmd);
	if (!q3e_cmdq[q3e_cmdq_count]) {
		q3e_cmdq_lost++;
		return;
	}
	q3e_cmdq_count++;
	q3e_cmd_seq++;
}

int Q3E_ProducerDropped(void) { return q3e_prod_dropped; }

// How many commands are still waiting to be executed. Used as a drain barrier:
// "queued" is not "done", and an exit that queues restores and then stops the
// only thread that could run them has restored nothing.
// Every command accepted so far, and every command that has finished RUNNING.
// A caller waiting for its work to be done waits for done to catch up with the
// sequence it saw when it queued.
unsigned Q3E_CommandSeq(void) {
	unsigned n;
	pthread_mutex_lock(&q3e_prod_lock);
	n = q3e_cmd_seq;
	pthread_mutex_unlock(&q3e_prod_lock);
	return n;
}

unsigned Q3E_CommandDone(void) { return q3e_cmd_done; }

int Q3E_ProducerPending(void) {
	int n;
	pthread_mutex_lock(&q3e_prod_lock);
	n = q3e_cmdq_count;
	pthread_mutex_unlock(&q3e_prod_lock);
	return n;
}

// Drop queued commands whose text contains `substr`, returning how many went.
//
// This exists because an abandoned VR entry leaves its own vid_restart sitting
// in the queue: on the device the entry's restart could not drain while the
// window's display link was dead, and it then executed AFTER the rollback had
// already put the render size back — a full renderer restart to the VR extent,
// in 2D, followed by a second one to undo it. Two RE_Shutdown/R_Init cycles
// back to back, with the audio ring starving through both.
int Q3E_CancelQueuedCommands(const char *substr) {
	int removed = 0, i, w = 0;
	if (!substr || !substr[0]) {
		return 0;
	}
	pthread_mutex_lock(&q3e_prod_lock);
	for (i = 0; i < q3e_cmdq_count; i++) {
		if (strstr(q3e_cmdq[i], substr)) {
			free(q3e_cmdq[i]);
			removed++;
		} else {
			q3e_cmdq[w++] = q3e_cmdq[i];
		}
	}
	q3e_cmdq_count = w;
	pthread_mutex_unlock(&q3e_prod_lock);
	return removed;
}

// Drained by the engine-frame owner, once per frame, before anything else runs.
void Q3E_DrainProducers(void) {
	char **cmds = NULL;
	int ncmds = 0, dropped, lost;

	for (;;) {
		q3e_prod_t ev;
		pthread_mutex_lock(&q3e_prod_lock);
		if (q3e_prod_tail == q3e_prod_head) {
			// Take the whole command list in one go, so a command that queues
			// another command cannot spin this loop.
			cmds = q3e_cmdq; ncmds = q3e_cmdq_count;
			q3e_cmdq = NULL; q3e_cmdq_count = 0; q3e_cmdq_cap = 0;
			dropped = q3e_prod_dropped; lost = q3e_cmdq_lost;
			pthread_mutex_unlock(&q3e_prod_lock);
			break;
		}
		ev = q3e_prodq[q3e_prod_tail];
		q3e_prod_tail = (q3e_prod_tail + 1) % Q3E_PROD_QUEUE_SIZE;
		pthread_mutex_unlock(&q3e_prod_lock);

		switch (ev.type) {
		case Q3E_PROD_MOUSE:    Sys_QueEvent(0, SE_MOUSE, ev.a, ev.b, 0, NULL); break;
		case Q3E_PROD_JOYAXIS:  Sys_QueEvent(0, SE_JOYSTICK_AXIS, ev.a, ev.b, 0, NULL); break;
		case Q3E_PROD_KEY:      Sys_QueEvent(0, SE_KEY, ev.a, ev.b, 0, NULL); break;
		case Q3E_PROD_CHAR:     Sys_QueEvent(0, SE_CHAR, ev.a, 0, 0, NULL); break;
		default: break;
		}
	}

	for (int i = 0; i < ncmds; i++) {
		if (!strcmp(cmds[i], "\0writeconfig")) {
			Cbuf_ExecuteText(EXEC_NOW, "writeconfig q3config.cfg\n");
			q3e_config_write_pending = 0;
		} else {
			// EXEC_NOW, not AddText: a command that merely lands in the command
			// buffer has not run when the barrier below says it has, and the
			// whole point of the counter is that "done" means done.
			char line[256];
			Q_strncpyz(line, cmds[i], sizeof(line) - 2);
			Q_strcat(line, sizeof(line), "\n");
			Cbuf_ExecuteText(EXEC_NOW, line);
		}
		free(cmds[i]);
		q3e_cmd_done++;
	}
	free(cmds);

	// Reported HERE, on the engine thread, because Com_Printf is not safe to
	// call from the producers' threads — which is the whole reason this queue
	// exists.
	if (dropped != q3e_prod_reported) {
		Com_Printf("Q3E: input funnel dropped %i oldest event(s)\n", dropped - q3e_prod_reported);
		q3e_prod_reported = dropped;
	}
	if (lost) {
		Com_Printf("Q3E: LOUD FAILURE — %i queued command(s) lost to allocation failure\n", lost);
		pthread_mutex_lock(&q3e_prod_lock);
		q3e_cmdq_lost = 0;
		pthread_mutex_unlock(&q3e_prod_lock);
	}
}

void Q3E_QueueMouse(int dx, int dy) {
	q3e_prod_push(Q3E_PROD_MOUSE, dx, dy);
}

void Q3E_QueueJoyAxis(int axis, int value) {
	q3e_prod_push(Q3E_PROD_JOYAXIS, axis, value);
}

void Q3E_QueueNamedKey(const char *name, int down) {
	int key;
	// K_CONSOLE has no entry in the engine's keynames table (nothing binds it),
	// but a hardware keyboard's ` key IS it — spell it here so the shell can stay
	// string-only.
	if (!Q_stricmp(name, "CONSOLE")) {
		key = K_CONSOLE;
	} else {
		key = Key_StringToKeynum(name);
	}
	if (key > 0) {
		q3e_prod_push(Q3E_PROD_KEY, key, down ? 1 : 0);
	}
}

void Q3E_QueueChar(int ch) {
	q3e_prod_push(Q3E_PROD_CHAR, ch, 0);
}

// Run a console command from any thread — controller binds that map to a
// command rather than a key, the settings appliers, the mode machine.
void Q3E_QueueCommand(const char *cmd) {
	if (!cmd || !cmd[0]) {
		return;
	}
	pthread_mutex_lock(&q3e_prod_lock);
	q3e_cmd_push_locked(cmd);
	pthread_mutex_unlock(&q3e_prod_lock);
}

// Active mod dir ("" = baseq3) — the touch layer picks the UI-cursor
// transform per game (mod UIs handle widescreen differently).
// Cvar_VariableString hands back a pointer into a small rotating buffer inside
// the engine, and this is read from the touch layer on the main thread while the
// VR engine thread runs. Publish a private copy from the engine thread instead
// (refreshed once per frame); a torn read of a fixed buffer is bounded, a freed
// engine pointer is not.
static char q3e_cur_game[MAX_QPATH];

const char *Q3E_CurrentGame(void) {
	return q3e_cur_game;
}

// Menu mode: taps should click a UI cursor rather than drive gameplay.
int Q3E_MenuMode(void) {
	if (Key_GetCatcher() & (KEYCATCH_UI | KEYCATCH_CONSOLE)) {
		return 1;
	}
	return cls.state != CA_ACTIVE;
}

static qboolean q3e_booted = qfalse;

// ---- text input: does the engine want characters right now? ----
// Three sources, in the order they are certain:
//   1. the console and the chat/message field are engine-owned and unambiguous;
//   2. a QVM menu field's focus is NOT announced anywhere — but the UI module
//      asks for the overstrike mode once per frame while it paints the cursor of
//      the focused field, and only then (overlay patch 0024 records the time of
//      that query). A query within the freshness window therefore means "a menu
//      text field has focus".
// The window is generous relative to a frame and short relative to a person
// moving the menu cursor off the field.
#define Q3E_TEXTHINT_FRESH_MS 400

int Q3E_TextInputWanted(void) {
	int catcher;
	if (!q3e_booted) {
		return 0;
	}
	catcher = Key_GetCatcher();
	if (catcher & (KEYCATCH_CONSOLE | KEYCATCH_MESSAGE)) {
		return 1;
	}
	if ((catcher & KEYCATCH_UI) && cl_uiTextFieldQueryTime > 0) {
		const int age = Sys_Milliseconds() - cl_uiTextFieldQueryTime;
		if (age >= 0 && age < Q3E_TEXTHINT_FRESH_MS) {
			return 1;
		}
	}
	return 0;
}

int Q3E_TextInputHintAge(void) {
	if (!q3e_booted || cl_uiTextFieldQueryTime <= 0) {
		return -1;
	}
	return Sys_Milliseconds() - cl_uiTextFieldQueryTime;
}

int Q3E_KeyCatcher(void) {
	return q3e_booted ? Key_GetCatcher() : 0;
}

// ---- keyboard console surface (handlers live in ios_input.m) ----
void Q3E_Keyboard_SetMode(int mode);
int  Q3E_Keyboard_GetMode(void);
void Q3E_Keyboard_DumpLine(char *out, int len);
void Q3E_Keyboard_InjectText(const char *utf8);
void Q3E_Keyboard_InjectKey(const char *name, int down);
void Q3E_Keyboard_Paste(const char *literal);
void Q3E_Keyboard_Dismiss(void);

static void Q3E_Kbd_f(void) {
	static const char *names[3] = { "auto", "on", "off" };
	if (Cmd_Argc() == 2) {
		const char *a = Cmd_Argv(1);
		if (!Q_stricmp(a, "auto")) Q3E_Keyboard_SetMode(0);
		else if (!Q_stricmp(a, "on") || !strcmp(a, "1")) Q3E_Keyboard_SetMode(1);
		else if (!Q_stricmp(a, "off") || !strcmp(a, "0")) Q3E_Keyboard_SetMode(2);
		else { Com_Printf("usage: q3ekbd <auto|on|off>\n"); return; }
	}
	Com_Printf("q3ekbd: %s\n", names[Q3E_Keyboard_GetMode() % 3]);
}

static void Q3E_KbdNow_f(void) {
	char line[512];
	Q3E_Keyboard_DumpLine(line, sizeof(line));
	Com_Printf("KBDNOW %s catcher=0x%x uihint=%dms want=%d\n",
	           line, Q3E_KeyCatcher(), Q3E_TextInputHintAge(), Q3E_TextInputWanted());
}

// Type into whatever the engine has focused, through the SAME entry point UIKit
// calls for a hardware keystroke and for a tap on the virtual keyboard
// (-insertText:). A simulator cannot deliver either one to a headless device, so
// this is how the sim suite proves the path.
static void Q3E_KbdType_f(void) {
	if (Cmd_Argc() < 2) { Com_Printf("usage: q3ekbdtype <text>\n"); return; }
	Q3E_Keyboard_InjectText(Cmd_ArgsFrom(1));
}

static void Q3E_KbdKey_f(void) {
	if (Cmd_Argc() < 2) { Com_Printf("usage: q3ekbdkey <keyname> [0|1]  (no state = press+release)\n"); return; }
	if (Cmd_Argc() >= 3) {
		Q3E_Keyboard_InjectKey(Cmd_Argv(1), atoi(Cmd_Argv(2)));
	} else {
		Q3E_Keyboard_InjectKey(Cmd_Argv(1), 1);
		Q3E_Keyboard_InjectKey(Cmd_Argv(1), 0);
	}
}

// The accessory bar's Paste button, fired from the console — nothing can tap a
// UIToolbar item headlessly.
static void Q3E_KbdPaste_f(void) {
	// No argument = the real clipboard (which may raise iOS's paste alert).
	// With an argument, the literal stands in for the clipboard string so the
	// rest of the path can be driven from a script.
	Q3E_Keyboard_Paste(Cmd_Argc() >= 2 ? Cmd_ArgsFrom(1) : "");
}

// The accessory bar's Dismiss button, fired from the console. Same reason as
// Paste: a UIToolbar item is untappable from a script.
static void Q3E_KbdDismiss_f(void) {
	Q3E_Keyboard_Dismiss();
}

// ---- boot + frame (called from AppShell.m) ----

extern const char *q3e_ios_stamp; // generated by build-spike.sh


// ---- Shortcuts / URL-scheme mod launching ----
// One pending slot: set before boot -> baked into the boot command
// line; set after boot -> immediate hot-switch via game_restart.

static char q3e_pending_mod[64];

static int q3e_mod_exists(const char *mod) {
	char path[1200];
	if (!mod[0] || !strcmp(mod, "baseq3")) {
		return 1;
	}
	Com_sprintf(path, sizeof(path), "%s/%s", q3e_docs, mod);
	return access(path, F_OK) == 0;
}

void Q3E_RequestMod(const char *mod) {
	char clean[64];
	int i, j = 0;

	// sanitize: fs_game-legal chars only (it becomes a filesystem path)
	for (i = 0; mod && mod[i] && j < 63; i++) {
		char c = mod[i];
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		    (c >= '0' && c <= '9') || c == '_' || c == '-') {
			clean[j++] = c;
		}
	}
	clean[j] = '\0';

	if (!q3e_mod_exists(clean)) {
		fprintf(stderr, "Q3E shortcuts: mod dir '%s' not found — ignoring\n", clean);
		return;
	}

	if (!q3e_booted) {
		Q_strncpyz(q3e_pending_mod, clean, sizeof(q3e_pending_mod));
		fprintf(stderr, "Q3E shortcuts: boot mod set to '%s'\n", clean);
		return;
	}

	// hot switch (main thread: URL opens and intent perform both are)
	char cmd[128];
	if (!clean[0] || !strcmp(clean, "baseq3")) {
		Com_sprintf(cmd, sizeof(cmd), "game_restart \"\"");
	} else {
		Com_sprintf(cmd, sizeof(cmd), "game_restart %s", clean);
	}
	fprintf(stderr, "Q3E shortcuts: hot-switching -> %s\n", cmd);
	// Through the funnel: this runs on the main thread (URL opens and intents
	// both do), and in VR the engine is on its own thread.
	Q3E_QueueCommand(cmd);
}

// One-time config migrations for EXISTING installs. Fresh installs bake the
// modern defaults into their first config (below); an install that already
// has a config predates those defaults, so we override the stale value
// exactly once — a marker file gates it so we never fight a choice the user
// later makes. Bump the level when adding a new one-time default.
#define Q3E_MIGRATION_LEVEL 3

static int q3e_migration_level(void) {
	char p[1200];
	Com_sprintf(p, sizeof(p), "%s/.q3e_migrations", q3e_docs);
	FILE *f = fopen(p, "rb");
	int lvl = 0;
	if (f) {
		if (fscanf(f, "%d", &lvl) != 1) lvl = 0;
		fclose(f);
	}
	return lvl;
}

static void q3e_set_migration_level(int lvl) {
	char p[1200];
	Com_sprintf(p, sizeof(p), "%s/.q3e_migrations", q3e_docs);
	FILE *f = fopen(p, "wb");
	if (f) {
		fprintf(f, "%d\n", lvl);
		fclose(f);
	}
}

// Urban Terror's server browser, and why it listed nothing.
//
// UrT's own engine defines PORT_MASTER as 27900; quake3e (like every other ioq3
// descendant) uses 27950. UrT's ui.qvm force-writes sv_master1/sv_master2 to
// "master.urbanterror.info" / "master2.urbanterror.info" with NO port, so
// quake3e appends 27950 and the getservers query goes to a port nothing is
// listening on. Raw UDP proves it: 27900 answers with ~250 servers, 27950
// answers with nothing. The QVM writes those two cvars through Cvar_SetSafe,
// which overrides even CVAR_INIT, so neither a command line nor a config can
// hold a corrected value in slots 1-3.
//
// Slots 4 and 5 the UI never touches, they are plain CVAR_ARCHIVE_ND, and
// masterNum 0 — which is what the UrT browser asks for — fans out to every
// non-empty sv_master1..5. So the whole fix is two lines in the mod's own
// autoexec.cfg, which the engine execs after default.cfg and q3config.cfg on
// both a cold boot and a game_restart hot-switch into the mod.
//
// The file usually already exists and is the player's own (the maintainer's carries his
// PC binds), so this APPENDS a marked block and never rewrites anything. The
// marker is what stops it growing a block per launch.
#define Q3E_UT_MASTER_MARK "// quake3e-ios: Urban Terror master servers"

static void q3e_ensure_ut_masters(void) {
	char dir[1200], path[1240];
	static char buf[65536];
	FILE *f;
	size_t n;

	Com_sprintf(dir, sizeof(dir), "%s/q3ut4", q3e_docs);
	if (access(dir, F_OK) != 0) {
		return;                     // Urban Terror is not installed
	}
	Com_sprintf(path, sizeof(path), "%s/autoexec.cfg", dir);

	buf[0] = '\0';
	f = fopen(path, "rb");
	if (f) {
		n = fread(buf, 1, sizeof(buf) - 1, f);
		buf[n] = '\0';
		fclose(f);
		if (strstr(buf, Q3E_UT_MASTER_MARK)) {
			return;                 // already ours
		}
		if (n >= sizeof(buf) - 1) {
			// Bigger than we can search in one gulp: a marker past the end
			// would be invisible and we would append a block every launch.
			Sys_Print("Q3E-UT: q3ut4/autoexec.cfg is too large to check — leaving it alone\n");
			return;
		}
	}

	f = fopen(path, "ab");
	if (!f) {
		Sys_Print("Q3E-UT: WARNING could not open q3ut4/autoexec.cfg for append\n");
		return;
	}
	fprintf(f,
		"\n" Q3E_UT_MASTER_MARK " (added automatically; edit or delete freely)\n"
		"// The mod's UI rewrites sv_master1..3 without a port, and Urban Terror's\n"
		"// masters listen on 27900, not the 27950 quake3e assumes.\n"
		"seta sv_master4 \"master.urbanterror.info:27900\"\n"
		"seta sv_master5 \"master2.urbanterror.info:27900\"\n");
	fclose(f);

	// Assert the write: a silently-skipped file edit is exactly how three
	// regressions shipped in one day on the sibling port.
	f = fopen(path, "rb");
	if (f) {
		n = fread(buf, 1, sizeof(buf) - 1, f);
		buf[n] = '\0';
		fclose(f);
	} else {
		buf[0] = '\0';
	}
	if (strstr(buf, "master.urbanterror.info:27900")) {
		Sys_Print("Q3E-UT: added the Urban Terror master servers to q3ut4/autoexec.cfg\n");
	} else {
		Sys_Print("Q3E-UT: FAILED to add the master servers to q3ut4/autoexec.cfg\n");
	}
}

void Q3E_BootEngine(void) {
	static char cmdline[4096];
	const char *extra = getenv("Q3E_ARGS");
	Sys_Print("Q3E_STAMP: ");
	Sys_Print(q3e_ios_stamp);
	Sys_Print("\n");
	// iOS-optimal engine defaults, applied INCREMENTALLY so each new default is
	// baked in exactly once. A fresh install (no config) gets con_scale plus
	// every migration level; an existing install gets only the levels above
	// its recorded marker (.q3e_migrations) — overriding a value written before
	// that default existed, without ever fighting a later user change. All are
	// +set before subsystem init, so latched cvars (s_khz, MSAA) take effect on
	// this boot. Levels:
	//   L1: s_khz 44 (engine default 22 = half rate) + 16x anisotropic
	//   L2: 4x MSAA (free on the A19 — M-016 held locked 120 at 8x under 12-bot
	//       stress; 4x is the battery-conscious default, 8x available in SETUP)
	//   L3: default binds for the pad buttons that stopped being hardcoded
	//       (AUX6 = B = +movedown, AUX7 = R3 = centerview)
	char firstrun[512] = "";
	{
		char cfgpath[1200];
		Com_sprintf(cfgpath, sizeof(cfgpath), "%s/baseq3/q3config.cfg", q3e_docs);
		FILE *f = fopen(cfgpath, "rb");
		qboolean haveConfig = (f != NULL);
		if (f) fclose(f);
		int mlevel = haveConfig ? q3e_migration_level() : 0; // fresh = 0 -> gets all
		if (!haveConfig) {
			Q_strcat(firstrun, sizeof(firstrun), "+set con_scale 2 ");
		}
		if (mlevel < 1) {
			Q_strcat(firstrun, sizeof(firstrun),
				"+set s_khz 44 +set r_ext_texture_filter_anisotropic 16 ");
		}
		if (mlevel < 2) {
			Q_strcat(firstrun, sizeof(firstrun), "+set r_ext_multisample 4 ");
		}
		if (mlevel < 3) {
			// The pad's B and R3 stopped being hardcoded (+movedown / centerview)
			// so a player can reproduce a PC layout exactly; they now emit AUX6
			// and AUX7. These two binds are what keeps the OLD behaviour for a
			// player who never opens a console — and because they are ordinary
			// binds written into q3config.cfg, rebinding either just overwrites
			// it and this level never runs again.
			//
			// The quotes matter: an unquoted "+movedown" would be parsed as a
			// NEW command-line command (Com_ParseCommandLine splits on '+').
			Q_strcat(firstrun, sizeof(firstrun),
				"+bind AUX6 \"+movedown\" +bind AUX7 \"centerview\" ");
		}
	}
	// Before Com_Init, because the engine execs the mod's autoexec.cfg during it.
	q3e_ensure_ut_masters();
	char modarg[96] = "";
	if (q3e_pending_mod[0] && strcmp(q3e_pending_mod, "baseq3") != 0) {
		Com_sprintf(modarg, sizeof(modarg), "+set fs_game %s ", q3e_pending_mod);
	}
	Com_sprintf(cmdline, sizeof(cmdline),
		"+set fs_basepath %s +set fs_homepath %s +set com_skipIdLogo 1 +set r_fbo 1 "
		"+set cl_allowDownload 1 %s%s%s",
		q3e_docs, q3e_docs, firstrun, modarg, extra ? extra : "");
	Sys_Print("Q3E-SPIKE cmdline: ");
	Sys_Print(cmdline);
	Sys_Print("\n");
	// Two ways in: the env var (desktop/devicectl path, needs a cable) and the
	// dev-build-only Settings switch — which exists because device services do
	// NOT traverse a tailnet, so an OTA-installed app tapped from the home screen
	// could never open the port however reachable the device was.
	if (getenv("Q3E_CONSOLE") || Q3E_RemoteConsoleEnabled()) {
		q3e_bridge_active = qtrue;
		Q3E_ConsoleBridge_Start();
	}
	Com_Init(cmdline);
	Cmd_AddCommand("touchedit", Q3E_TouchEdit_f);
	Cmd_AddCommand("q3e_faketouch", Q3E_FakeTouch_f);
	Cmd_AddCommand("q3ekbd", Q3E_Kbd_f);
	Cmd_AddCommand("q3ekbdnow", Q3E_KbdNow_f);
	Cmd_AddCommand("q3ekbdtype", Q3E_KbdType_f);
	Cmd_AddCommand("q3ekbdkey", Q3E_KbdKey_f);
	Cmd_AddCommand("q3ekbdpaste", Q3E_KbdPaste_f);
	Cmd_AddCommand("q3ekbddismiss", Q3E_KbdDismiss_f);
	q3e_booted = qtrue;
	if (q3e_migration_level() < Q3E_MIGRATION_LEVEL) {
		q3e_set_migration_level(Q3E_MIGRATION_LEVEL);
	}
	Sys_Print("Q3E-SPIKE Com_Init complete\n");
}

// Scene resign-active: the engine's own config flush runs one frame
// after a cvar change; a suspend-kill in that window loses settings.
// Flush synchronously here (main thread).
void Q3E_OnResignActive(void) {
	if (!q3e_booted) {
		return;
	}
	// The engine writes its config on a clean exit only, and a swipe-kill is
	// SIGKILL — so this write has to have HAPPENED by the time we return, not be
	// scheduled. When the display link owns the frame we are already on the
	// engine's thread and can just do it.
	if (q3e_frame_owner == 0) {
		Cbuf_ExecuteText(EXEC_NOW, "writeconfig q3config.cfg\n");
		Sys_Print("Q3E-SPIKE: config flushed on resign-active\n");
		return;
	}
	// In VR the engine runs on its own thread, so hand the write to it and WAIT
	// briefly for it to land (a VR frame is ~11 ms; 200 ms is ~18 of them).
	q3e_config_write_pending = 1;
	Q3E_QueueCommand("\0writeconfig");
	for (int i = 0; i < 100 && q3e_config_write_pending; i++) {
		usleep(2000);
	}
	if (q3e_config_write_pending) {
		// The engine thread did not drain in time — it is loading a map, or
		// running a vid_restart. Writing it from HERE was the R0.1 compromise and
		// it is not survivable: EXEC_NOW reaches into the engine from a second
		// thread, and doing that during a renderer restart aborted the process
		// with 'mutex lock failed: Invalid argument' out of MoltenVK. The write
		// stays queued; it runs at the engine's next frame, which is also the
		// moment it becomes safe.
		Sys_Print("Q3E-SPIKE: config write still QUEUED after 200 ms (engine busy) — "
			"it will run at the next engine frame; NOT forcing it from another thread\n");
		return;
	}
	Sys_Print("Q3E-SPIKE: config flushed on resign-active\n");
}

// Per-callback frame split: wall (callback-to-callback) vs engine-frame
// (inside Com_Frame, includes in-call blocking — q2repro naming lesson).
// RAM-ring buffered, one summary line per 600 frames (~5 s at 120 Hz);
// a single NSLog-equivalent every 5 s is not a measurement pollutant.

#define Q3E_FT_WINDOW 600

static uint32_t q3e_ft_busy[Q3E_FT_WINDOW];
static uint32_t q3e_ft_wall[Q3E_FT_WINDOW];
static int q3e_ft_n;
static int64_t q3e_ft_prev;

// Sim-rate: authoritative game-time advance vs wall time — the charter's
// day-one metric (the number that turns "enemies move in slow motion"
// into a diagnosis, and the exact failure mode patch 0002 fixed). 100% =
// the simulation keeps up with wall inside the display-link callback.
// Sampled only over frames where the sim is meant to advance (in-world,
// unpaused) so a legitimate menu/pause never reads as a stall.
static int      q3e_auth_prev;
static qboolean q3e_auth_have;
static double   q3e_sim_ms;       // summed authoritative advance this window (ms)
static double   q3e_sim_wall_us;  // summed wall over those same frames (us)

static int q3e_auth_clock(qboolean *active) {
	// listen server / single-player: svs.time is the monotonic cross-map
	// server clock (sv.time resets each level; svs.time does not).
	if (Cvar_VariableIntegerValue("sv_running") &&
	    !Cvar_VariableIntegerValue("cl_paused")) {
		*active = qtrue;
		return svs.time;
	}
	// pure remote client: the latest snapshot's authoritative server time.
	if (cls.state == CA_ACTIVE) {
		*active = qtrue;
		return cl.snap.serverTime;
	}
	*active = qfalse;
	return 0;
}

static int q3e_ft_cmp(const void *a, const void *b) {
	const uint32_t ua = *(const uint32_t *)a, ub = *(const uint32_t *)b;
	return (ua > ub) - (ua < ub);
}

int Q3E_ThermalState(void); // ios_metal.m (0 nominal / 1 fair / 2 serious / 3 critical)

static void q3e_ft_report(void) {
	static const char *thermal_names[] = { "nominal", "fair", "serious", "critical" };
	char line[256];
	int th = Q3E_ThermalState();
	if (th < 0 || th > 3) th = 0;
	char simstr[24];
	if (q3e_sim_wall_us > 0.0) {
		Com_sprintf(simstr, sizeof(simstr), "%.1f%%",
			(q3e_sim_ms / (q3e_sim_wall_us / 1000.0)) * 100.0);
	} else {
		Q_strncpyz(simstr, "n/a", sizeof(simstr)); // no in-world frames this window
	}
	qsort(q3e_ft_busy, Q3E_FT_WINDOW, sizeof(uint32_t), q3e_ft_cmp);
	qsort(q3e_ft_wall, Q3E_FT_WINDOW, sizeof(uint32_t), q3e_ft_cmp);
	Com_sprintf(line, sizeof(line),
		"Q3E_FT: wall p50=%.2f p95=%.2f | engine-frame p50=%.2f p95=%.2f p99=%.2f max=%.2f | sim=%s (ms, n=%d, thermal=%s)\n",
		q3e_ft_wall[Q3E_FT_WINDOW / 2] / 1000.0,
		q3e_ft_wall[(Q3E_FT_WINDOW * 95) / 100] / 1000.0,
		q3e_ft_busy[Q3E_FT_WINDOW / 2] / 1000.0,
		q3e_ft_busy[(Q3E_FT_WINDOW * 95) / 100] / 1000.0,
		q3e_ft_busy[(Q3E_FT_WINDOW * 99) / 100] / 1000.0,
		q3e_ft_busy[Q3E_FT_WINDOW - 1] / 1000.0,
		simstr, Q3E_FT_WINDOW, thermal_names[th]);
	Sys_Print(line);

	q3e_sim_ms = 0.0;
	q3e_sim_wall_us = 0.0;
}

void Q3E_Frame(void) {
	const int64_t begin = Sys_Microseconds();

	if (q3e_bridge_active) {
		Q3E_ConsoleBridge_Drain();
	}
	Q3E_DrainProducers();   // locked hand-off from every off-engine-thread producer
	Q_strncpyz(q3e_cur_game, Cvar_VariableString("fs_game"), sizeof(q3e_cur_game));
	Q3E_Input_Frame();
	Q3E_Audio_Tick();
	Com_Frame(qtrue); // noDelay: the CADisplayLink is the only pacer

	const int64_t end = Sys_Microseconds();
	if (q3e_ft_prev != 0) {
		const uint32_t wall_us = (uint32_t)(begin - q3e_ft_prev);
		q3e_ft_busy[q3e_ft_n] = (uint32_t)(end - begin);
		q3e_ft_wall[q3e_ft_n] = wall_us;

		// pair this frame's authoritative sim advance with its wall interval
		qboolean active;
		const int authNow = q3e_auth_clock(&active);
		if (active && q3e_auth_have) {
			const int d = authNow - q3e_auth_prev;
			if (d >= 0 && d < 1000) { // ignore level resets / source switches
				q3e_sim_ms += d;
				q3e_sim_wall_us += wall_us;
			}
		}
		q3e_auth_have = active;
		q3e_auth_prev = authNow;

		if (++q3e_ft_n == Q3E_FT_WINDOW) {
			q3e_ft_report();
			q3e_ft_n = 0;
		}
	}
	q3e_ft_prev = begin;
}

// ---- Vulkan renderer platform hooks (tr_public.h:225-228) ----

// Render-size override (visionOS VR). The engine fixes its render resolution at
// the initial FBO size for the process lifetime and `vid_resize` deliberately
// never changes it (the QVM cgame caches glconfig at CG_Init, so a render-res
// change without a full restart crops the HUD). VR needs a PER-EYE extent
// instead of the window's, so it sets the override and goes through the restart
// machinery — which is also what re-creates the eye images and re-inits the QVMs
// with a consistent glconfig. Zero = follow the window, which is every other
// build and every other mode.
static int q3e_render_override_w = 0;
static int q3e_render_override_h = 0;

// OWNERSHIP. The override has more than one plausible writer: VR sets a per-eye
// extent, and the window's own geometry path re-sizes the renderer whenever the
// scene resizes. On the device, opening the VR space IS a scene-geometry event,
// so both writers run during entry and the last one wins — which is how a device
// round watched three entries restart the renderer and come back at the window's
// resolution every time. So the extent has exactly one owner at a time: VR
// claims it for the whole session (entry through the 2D restore) and every other
// writer is REFUSED BY NAME rather than politely gated at each call site, where
// the next new call site would forget.
static const char *q3e_render_override_owner = NULL;   // NULL = free
static int q3e_render_override_refusals = 0;
// The black box lives in the visionOS shell only (the iPhone target compiles
// this file without it), so refusals are reported through a hook the shell
// installs; the console print happens either way.
static void (*q3e_render_override_report)(const char *) = NULL;

void Q3E_SetRenderOverrideReporter(void (*fn)(const char *)) {
	q3e_render_override_report = fn;
}

static void q3e_render_override_say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void q3e_render_override_say(const char *fmt, ...) {
	char line[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	Com_Printf("%s\n", line);
	if (q3e_render_override_report) q3e_render_override_report(line);
}

const char *Q3E_RenderSizeOverrideOwner(void) { return q3e_render_override_owner; }
int Q3E_RenderSizeOverrideRefusals(void) { return q3e_render_override_refusals; }

// A platform shell that stops a re-size BEFORE it reaches the override (the
// visionOS window/geometry gate does exactly that, so the layer's own drawable
// size is never moved either) records it on the same counter. One number for
// "attempts to re-size the renderer that were refused", however far each one
// got — two counters for one event is how a dump starts disagreeing with itself.
void Q3E_NoteRenderSizeOverrideRefusal(void) { q3e_render_override_refusals++; }

int Q3E_ClaimRenderSizeOverride(const char *who) {
	if (!who) return 0;
	if (q3e_render_override_owner && strcmp(q3e_render_override_owner, who) != 0) {
		q3e_render_override_refusals++;
		q3e_render_override_say("render extent: CLAIM by '%s' REFUSED — '%s' already owns it",
			who, q3e_render_override_owner);
		return 0;
	}
	q3e_render_override_owner = who;   // callers pass string literals
	q3e_render_override_say("render extent: CLAIMED by '%s' (no window or scene path may "
		"re-size the renderer until it is released)", who);
	return 1;
}

void Q3E_ReleaseRenderSizeOverride(const char *who) {
	if (!q3e_render_override_owner) return;
	if (!who || strcmp(q3e_render_override_owner, who) != 0) {
		q3e_render_override_refusals++;
		q3e_render_override_say("render extent: RELEASE by '%s' REFUSED — '%s' owns it",
			who ? who : "(null)", q3e_render_override_owner);
		return;
	}
	q3e_render_override_owner = NULL;
	q3e_render_override_say("render extent: RELEASED by '%s' (the window owns it again)", who);
}

// RENDER GENERATION. A vid_restart destroys and recreates every VkImage the
// visionOS compositor holds Metal texture handles for, and the compositor loop
// runs on its own thread throughout. So the renderer publishes a generation
// counter and a liveness flag: the loop re-resolves its handles every frame and
// skips the ones it took while the generation was moving.
volatile int q3e_render_gen = 0;
volatile int q3e_render_live = 0;

// Called by the shell immediately BEFORE it queues a vid_restart, so the window
// between "the restart is coming" and "the renderer has torn down" is covered
// too — not just the teardown itself.
void Q3E_NoteRenderRestart(void) {
	q3e_render_live = 0;
	q3e_render_gen++;
}

// Returns 1 if the write landed. `caller` must be the current owner whenever
// there is one — a refusal is a named, counted event, never a silent no-op.
int Q3E_SetRenderSizeOverride(const char *caller, int w, int h) {
	if (w < 0 || h < 0) {
		return 0;
	}
	if (q3e_render_override_owner &&
	    (!caller || strcmp(caller, q3e_render_override_owner) != 0)) {
		q3e_render_override_refusals++;
		q3e_render_override_say("render extent: write %dx%d from '%s' REFUSED — '%s' owns it",
			w, h, caller ? caller : "(unnamed)", q3e_render_override_owner);
		return 0;
	}
	q3e_render_override_w = w;
	q3e_render_override_h = h;
	Com_Printf("Q3E: render size override -> %dx%d%s\n", w, h,
		(w == 0 || h == 0) ? " (off: follow the window)" : "");
	return 1;
}

void Q3E_GetRenderSizeOverride(int *w, int *h) {
	if (w) *w = q3e_render_override_w;
	if (h) *h = q3e_render_override_h;
}

void VKimp_Init(glconfig_t *config) {
	config->vidWidth = Q3E_LayerWidth();
	config->vidHeight = Q3E_LayerHeight();
	if (q3e_render_override_w > 0 && q3e_render_override_h > 0) {
		config->vidWidth = q3e_render_override_w;
		config->vidHeight = q3e_render_override_h;
	}
	config->windowAspect = (float)config->vidWidth / (float)config->vidHeight;
	config->colorBits = 24;
	config->depthBits = 24;
	config->stencilBits = 8;
	config->displayFrequency = Q3E_DisplayMaxFPS();
	config->isFullscreen = qtrue;
	// Report gamma as supported even though iOS has no hardware ramps: with the
	// FBO active the renderer applies r_gamma in the post-blit shader (rebuilt
	// live on change via CVG_RENDERER), and the stock SETUP menu GRAYS OUT its
	// Brightness slider when glconfig says unsupported — leaving users no
	// in-game brightness control. GLimp_SetGamma below stays a no-op.
	config->deviceSupportsGamma = qtrue;
	config->driverType = GLDRV_ICD;
	config->hardwareType = GLHW_GENERIC;
	config->stereoEnabled = qfalse;
	q3e_render_gen++;
	q3e_render_live = 1;
	Com_Printf("VKimp_Init(iOS): %dx%d @%dHz (render gen %d)\n",
		config->vidWidth, config->vidHeight, config->displayFrequency, q3e_render_gen);
}

void VKimp_Shutdown(qboolean unloadDLL) {
	q3e_render_live = 0;
	q3e_render_gen++;
}

void *VK_GetInstanceProcAddr(VkInstance instance, const char *name) {
	return Q3E_GetInstanceProcAddr((void *)instance, name);
}

qboolean VK_CreateSurface(VkInstance instance, VkSurfaceKHR *pSurface) {
	void *surface = NULL;
	if (!Q3E_CreateMetalSurface((void *)instance, &surface)) {
		return qfalse;
	}
	*pSurface = (VkSurfaceKHR)surface;
	return qtrue;
}

// ---- gamma (no hardware ramps on iOS; r_fbo shader gamma instead) ----

void GLimp_InitGamma(glconfig_t *config) {
	config->deviceSupportsGamma = qtrue;   // see VKimp_Init: shader gamma is live
}

void GLimp_SetGamma(unsigned char red[256], unsigned char green[256], unsigned char blue[256]) {
}

// ---- input (spike: none — timedemo needs no input) ----

void IN_Init(void) {}
void IN_Frame(void) {}
void IN_Shutdown(void) {}
void IN_Restart(void) {}
void Sys_SendKeyEvents(void) {}
qboolean Key_CapsLockOn(void) { return qfalse; }

// ---- clipboard (paste server addresses / passwords into console + menus) ----

const char *Q3E_ClipboardText(void); // ios_metal.m (UIPasteboard)

char *Sys_GetClipboardData(void) {
	const char *s = Q3E_ClipboardText();
	size_t n;
	char *buf;
	if (!s || !s[0]) {
		return NULL;
	}
	// callers Z_Free the result (cl_keys.c/cl_ui.c) → it must be Z_Malloc'd;
	// mirror the desktop impl (first line only — strips a trailing newline).
	n = strlen(s) + 1;
	buf = Z_Malloc(n);
	Q_strncpyz(buf, s, (int)n);
	strtok(buf, "\n\r\b");
	return buf;
}
void Sys_SetClipboardBitmap(const byte *bitmap, int length) {}

// ---- sound: real AudioQueue SNDDMA lives in ios_snd.c ----

// ---- Sys_* subset normally provided by unix_main.c (excluded: its
//      main() and tty console don't apply on iOS) ----

void QDECL Sys_Error(const char *error, ...) {
	va_list argptr;
	char text[4096];

	va_start(argptr, error);
	Q_vsnprintf(text, sizeof(text), error, argptr);
	va_end(argptr);

	fprintf(stderr, "Sys_Error: %s\n", text);
	fflush(stderr);
	exit(1);
}

void NORETURN Sys_Quit(void) {
	fprintf(stderr, "Sys_Quit()\n");
	fflush(stderr);
	exit(0);
}

void Sys_Init(void) {
}

void Sys_Print(const char *msg) {
	fputs(msg, stderr);
	if (q3e_bridge_active) {
		Q3E_ConsoleBridge_Output(msg);
	}
}

void QDECL Sys_SetStatus(const char *format, ...) {
}

qboolean Sys_LowPhysicalMemory(void) {
	return qfalse;
}

const char *Sys_DefaultBasePath(void) {
	return q3e_docs;
}

char *Sys_DefaultAppPath(void) {
	return q3e_docs;
}

void Sys_Sleep(int msec) {
	if (msec > 0) {
		usleep((useconds_t)msec * 1000);
	}
}

char *Sys_ConsoleInput(void) {
	return NULL;
}

void Sys_BeginProfiling(void) {
}
