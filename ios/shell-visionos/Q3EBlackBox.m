#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <stdarg.h>
#import <unistd.h>
#import <fcntl.h>
#import "Q3EBlackBox.h"

static int q3e_bb_fd = -1;
static mach_timebase_info_data_t q3e_bb_tb;

void Q3E_BlackBox_Init(const char *documentsPath) {
    if (!documentsPath || q3e_bb_fd >= 0) return;
    char path[1200];
    snprintf(path, sizeof(path), "%s/blackbox.log", documentsPath);
    // APPEND (not truncate): the visionOS Exit bug closes the app, and reopening it
    // would wipe a truncating log before we can read the exit sequence. Sessions are
    // separated by the boot marker below.
    q3e_bb_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    mach_timebase_info(&q3e_bb_tb);
    Q3E_BlackBox("=== BLACKBOX BOOT === %s", path);
}

// Append one line: [<ms since boot> t<mach thread id>] <msg>. write() per line keeps
// it crash/wedge-safe with no buffering; small lines interleave cleanly across threads.
void Q3E_BlackBox(const char *fmt, ...) {
    if (q3e_bb_fd < 0) return;
    unsigned long long ms = 0;
    if (q3e_bb_tb.denom)
        ms = (mach_absolute_time() * q3e_bb_tb.numer / q3e_bb_tb.denom) / 1000000ULL;
    char line[600];
    int n = snprintf(line, sizeof(line), "[%llums t%u] ", ms,
                     (unsigned)pthread_mach_thread_np(pthread_self()));
    if (n < 0 || n >= (int)sizeof(line)) return;
    va_list ap; va_start(ap, fmt);
    int m = vsnprintf(line + n, sizeof(line) - n, fmt, ap);
    va_end(ap);
    if (m > 0) n += (n + m < (int)sizeof(line)) ? m : (int)sizeof(line) - n - 1;
    if (n < (int)sizeof(line)) line[n++] = '\n';
    (void)write(q3e_bb_fd, line, n);
}

void Q3E_BlackBox_Str(const char *s) { Q3E_BlackBox("%s", s ? s : "(null)"); }
