#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/stat.h>
#import "Q3EBlackBox.h"

// Two in-memory sections (see the header) flushed to one file. Appends take a
// mutex and are lock-only — no I/O, no allocation beyond a growth realloc — so a
// line from the compositor thread costs the same as a line from the engine thread.
// All file I/O happens on one serial queue.

static pthread_mutex_t q3e_bb_lock = PTHREAD_MUTEX_INITIALIZER;
static mach_timebase_info_data_t q3e_bb_tb;

typedef struct {
    char  *buf;
    size_t len;
    size_t cap;
} q3e_bb_sec_t;

static q3e_bb_sec_t q3e_bb_pinned;
static q3e_bb_sec_t q3e_bb_roll;
static int          q3e_bb_pinnedFull;     // budget spent -> pinned lines spill to the tail

// A pinned section is only "never truncated" if what goes into it is bounded.
// Entry/contract are bounded; mode transitions are not (a player toggling for an
// hour), so the pinned section has a budget and spills into the rolling tail once
// it is spent — loudly, in the file.
static const size_t kQ3EPinnedBudget = 96000;
static const size_t kQ3ERollCap      = 160000;

static char q3e_bb_path[1200];
static char q3e_bb_tmpPath[1216];
static int  q3e_bb_ready = 0;

static dispatch_queue_t q3e_bb_queue;
static double           q3e_bb_lastWrite;
static int              q3e_bb_pendingWrite;

static void q3e_bb_sec_append(q3e_bb_sec_t *s, const char *line, size_t n) {
    if (s->len + n + 1 > s->cap) {
        size_t want = s->cap ? s->cap * 2 : 8192;
        while (want < s->len + n + 1) want *= 2;
        char *nb = realloc(s->buf, want);
        if (!nb) return;                 // out of memory: drop the line, never crash
        s->buf = nb; s->cap = want;
    }
    memcpy(s->buf + s->len, line, n);
    s->len += n;
    s->buf[s->len] = '\0';
}

// Drop the front HALF of the rolling tail, realigned to a line boundary so the
// file never starts mid-line (a half line reads as a real line to a grep).
static void q3e_bb_roll_trim(void) {
    if (q3e_bb_roll.len <= kQ3ERollCap) return;
    size_t cut = kQ3ERollCap / 2;
    char *nl = memchr(q3e_bb_roll.buf + cut, '\n', q3e_bb_roll.len - cut);
    cut = nl ? (size_t)(nl - q3e_bb_roll.buf) + 1 : q3e_bb_roll.len;
    memmove(q3e_bb_roll.buf, q3e_bb_roll.buf + cut, q3e_bb_roll.len - cut);
    q3e_bb_roll.len -= cut;
    q3e_bb_roll.buf[q3e_bb_roll.len] = '\0';
}

// Must run on q3e_bb_queue.
static void q3e_bb_write_now(void) {
    if (!q3e_bb_ready) return;
    pthread_mutex_lock(&q3e_bb_lock);
    size_t pl = q3e_bb_pinned.len, rl = q3e_bb_roll.len;
    char *pinCopy  = pl ? malloc(pl) : NULL;
    char *rollCopy = rl ? malloc(rl) : NULL;
    if (pl && pinCopy)  memcpy(pinCopy,  q3e_bb_pinned.buf, pl);
    if (rl && rollCopy) memcpy(rollCopy, q3e_bb_roll.buf,   rl);
    if (pl && !pinCopy)  pl = 0;
    if (rl && !rollCopy) rl = 0;
    pthread_mutex_unlock(&q3e_bb_lock);

    // Write a temp file and rename: a reader (or a Files-app copy) never sees a
    // half-written report, and a crash mid-write cannot destroy the old one.
    int fd = open(q3e_bb_tmpPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        char hdr[512];
        int n = snprintf(hdr, sizeof(hdr),
            "Quake3e visionOS black box\n"
            "==========================\n"
            "Every line below is a measurement, not a guess. Send the whole file back.\n"
            "\n--- PINNED (boot, mode transitions, drawable contract — never truncated) ---\n");
        if (n > 0) (void)!write(fd, hdr, (size_t)n);
        if (pl) (void)!write(fd, pinCopy, pl);
        n = snprintf(hdr, sizeof(hdr),
            "\n--- ROLLING TAIL (periodic lines; oldest are dropped first) ---\n");
        if (n > 0) (void)!write(fd, hdr, (size_t)n);
        if (rl) (void)!write(fd, rollCopy, rl);
        close(fd);
        rename(q3e_bb_tmpPath, q3e_bb_path);
    }
    free(pinCopy); free(rollCopy);
    q3e_bb_lastWrite = CACurrentMediaTime();
}

// Rolling lines are coalesced to at most one file write per second, with a
// trailing write so the last state always lands.
//
// PINNED lines are NOT coalesced: they are bounded, rare, and they are the
// lines a post-mortem is made of. Sharing one "a write is pending" flag with the
// rolling path meant a pinned line arriving behind a queued 1 s write inherited
// that delay — the mode transition that preceded a crash would be exactly the
// line lost.
static void q3e_bb_request_write(int pinned) {
    if (!q3e_bb_ready) return;
    if (pinned) {
        dispatch_async(q3e_bb_queue, ^{ q3e_bb_write_now(); });
        return;
    }
    dispatch_async(q3e_bb_queue, ^{
        double now = CACurrentMediaTime();
        double since = now - q3e_bb_lastWrite;
        if (since < 1.0) {
            if (!q3e_bb_pendingWrite) {
                q3e_bb_pendingWrite = 1;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)((1.0 - since) * NSEC_PER_SEC)),
                               q3e_bb_queue, ^{
                    q3e_bb_pendingWrite = 0;
                    q3e_bb_write_now();
                });
            }
            return;
        }
        q3e_bb_write_now();
    });
}

// SYNCHRONOUS. Every caller of this is at a point where the process may not
// exist a moment later — loop exit, resign-active (frequently the first half of
// a swipe-kill, and swipe-kill is SIGKILL), an explicit dump command. An
// asynchronous "flush" at those points is a flush that did not happen.
void Q3E_BlackBox_Flush(void) {
    if (!q3e_bb_ready) return;
    dispatch_sync(q3e_bb_queue, ^{ q3e_bb_write_now(); });
}

// Format one line as [<ms since boot> t<mach thread id>] <msg>\n and append it to
// the requested section.
static void q3e_bb_emit(int pinned, const char *fmt, va_list ap) {
    if (!q3e_bb_ready) return;
    unsigned long long ms = 0;
    if (q3e_bb_tb.denom)
        ms = (mach_absolute_time() * q3e_bb_tb.numer / q3e_bb_tb.denom) / 1000000ULL;
    char line[800];
    int n = snprintf(line, sizeof(line), "[%llums t%u] ", ms,
                     (unsigned)pthread_mach_thread_np(pthread_self()));
    if (n < 0 || n >= (int)sizeof(line)) return;
    int m = vsnprintf(line + n, sizeof(line) - n, fmt, ap);
    if (m > 0) n += (n + m < (int)sizeof(line)) ? m : (int)sizeof(line) - n - 1;
    if (n < (int)sizeof(line)) line[n++] = '\n';

    pthread_mutex_lock(&q3e_bb_lock);
    int spill = 0;
    if (pinned && !q3e_bb_pinnedFull) {
        if (q3e_bb_pinned.len > kQ3EPinnedBudget) {
            q3e_bb_pinnedFull = 1;
            const char *note = "--- pinned budget spent; further pinned lines are in the rolling tail below ---\n";
            q3e_bb_sec_append(&q3e_bb_pinned, note, strlen(note));
            spill = 1;
        }
    } else if (pinned) {
        spill = 1;
    }
    if (pinned && !spill)
        q3e_bb_sec_append(&q3e_bb_pinned, line, (size_t)n);
    else {
        q3e_bb_sec_append(&q3e_bb_roll, line, (size_t)n);
        q3e_bb_roll_trim();
    }
    pthread_mutex_unlock(&q3e_bb_lock);

    q3e_bb_request_write(pinned);
}

void Q3E_BlackBox(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    q3e_bb_emit(0, fmt, ap);
    va_end(ap);
}

void Q3E_BlackBox_Pin(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    q3e_bb_emit(1, fmt, ap);
    va_end(ap);
}

void Q3E_BlackBox_Str(const char *s)    { Q3E_BlackBox("%s", s ? s : "(null)"); }
void Q3E_BlackBox_PinStr(const char *s) { Q3E_BlackBox_Pin("%s", s ? s : "(null)"); }

void Q3E_BlackBox_Init(const char *documentsPath) {
    if (!documentsPath || q3e_bb_ready) return;
    snprintf(q3e_bb_path,    sizeof(q3e_bb_path),    "%s/blackbox.log", documentsPath);
    snprintf(q3e_bb_tmpPath, sizeof(q3e_bb_tmpPath), "%s/blackbox.log.tmp", documentsPath);
    // The file is rewritten in place from memory, so keep the previous session one
    // file back — a wedge or a swipe-kill is usually diagnosed from the session
    // BEFORE the relaunch that found it.
    //
    // Only rotate a log with something in it. A crash-on-boot loop otherwise
    // destroys the evidence in two relaunches: the useful session becomes prev,
    // then the near-empty session that follows overwrites it.
    char prev[1216];
    snprintf(prev, sizeof(prev), "%s/blackbox-prev.log", documentsPath);
    struct stat st;
    if (stat(q3e_bb_path, &st) == 0) {
        if (st.st_size >= 4096) {
            rename(q3e_bb_path, prev);
        } else {
            unlink(q3e_bb_path);   // too short to have recorded anything; keep prev
        }
    }
    mach_timebase_info(&q3e_bb_tb);
    q3e_bb_queue = dispatch_queue_create("com.rebelancap.quake3e.blackbox", DISPATCH_QUEUE_SERIAL);
    q3e_bb_ready = 1;
    Q3E_BlackBox_Pin("=== BLACKBOX BOOT === %s (previous session: blackbox-prev.log)", q3e_bb_path);
}
