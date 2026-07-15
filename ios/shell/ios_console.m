// ios_console.m — launch-gated TCP remote console (port 27999).
// Ported from q2repro-ios Q2ConsoleBridge.m; the single most valuable
// debugging tool of that project. Differences here: console output is
// fanned out directly from Sys_Print (no logfile tailing needed), and
// SO_NOSIGPIPE guards against a dead client SIGPIPE-killing the app.
//
// No engine headers in this file (ObjC 'id' keyword vs engine
// identifiers) — engine interaction goes through q3e_console_command()
// in ios_glue.c.

#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#define BRIDGE_PORT 27999

extern void q3e_console_command(const char *text); // ios_glue.c → Cbuf_AddText

static dispatch_queue_t bridge_queue;
static int listen_fd = -1;
static volatile int client_fd = -1;
static dispatch_source_t listen_src, client_src;
static NSMutableData *inbuf;

static NSLock *cmd_lock;
static NSMutableArray<NSString *> *cmd_queue;

static void client_close(void) {
    if (client_src) { dispatch_source_cancel(client_src); client_src = nil; }
    if (client_fd >= 0) { close(client_fd); client_fd = -1; }
}

static void client_readable(void) {
    char buf[2048];
    ssize_t n = read(client_fd, buf, sizeof(buf));
    if (n <= 0) {
        NSLog(@"Q3E-SPIKE console bridge: client disconnected");
        client_close();
        return;
    }
    [inbuf appendBytes:buf length:n];

    const char *bytes = inbuf.bytes;
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < inbuf.length; i++) {
        if (bytes[i] == '\n') {
            NSUInteger len = i - start;
            while (len && (bytes[start + len - 1] == '\r')) len--;
            if (len) {
                NSString *line = [[NSString alloc]
                    initWithBytes:bytes + start length:len
                         encoding:NSUTF8StringEncoding];
                if (line) {
                    [cmd_lock lock];
                    [cmd_queue addObject:line];
                    [cmd_lock unlock];
                }
            }
            start = i + 1;
        }
    }
    if (start)
        [inbuf replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
}

static void accept_client(void) {
    int fd = accept(listen_fd, NULL, NULL);
    if (fd < 0)
        return;
    client_close(); // one client at a time; newest wins
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    client_fd = fd;
    inbuf = [NSMutableData data];
    NSLog(@"Q3E-SPIKE console bridge: client connected");

    const char *hello = "] quake3e-ios remote console - engine output streams here; type commands.\n";
    write(fd, hello, strlen(hello));

    client_src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, bridge_queue);
    dispatch_source_set_event_handler(client_src, ^{ client_readable(); });
    dispatch_resume(client_src);
}

void Q3E_ConsoleBridge_Start(void) {
    bridge_queue = dispatch_queue_create("q3e.console.bridge", DISPATCH_QUEUE_SERIAL);
    cmd_lock = [NSLock new];
    cmd_queue = [NSMutableArray array];

    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = { .sin_family = AF_INET,
                                .sin_port = htons(BRIDGE_PORT),
                                .sin_addr.s_addr = htonl(INADDR_ANY) };
    // --terminate-existing races the old instance's lingering listener
    // (EADDRINUSE even with SO_REUSEADDR while it still holds the port) —
    // retry for a few seconds instead of giving up.
    int bound = -1;
    for (int attempt = 0; attempt < 10; attempt++) {
        bound = bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr));
        if (bound == 0)
            break;
        usleep(400 * 1000);
    }
    if (bound < 0 || listen(listen_fd, 1) < 0) {
        NSLog(@"Q3E-SPIKE console bridge: bind/listen failed (%d)", errno);
        close(listen_fd); listen_fd = -1;
        return;
    }
    listen_src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, listen_fd, 0, bridge_queue);
    dispatch_source_set_event_handler(listen_src, ^{ accept_client(); });
    dispatch_resume(listen_src);
    NSLog(@"Q3E-SPIKE console bridge listening on port %d", BRIDGE_PORT);
}

// Engine (main) thread, once per frame: feed queued commands into Cbuf.
void Q3E_ConsoleBridge_Drain(void) {
    if (!cmd_lock)
        return;
    NSArray<NSString *> *cmds = nil;
    [cmd_lock lock];
    if (cmd_queue.count) {
        cmds = [cmd_queue copy];
        [cmd_queue removeAllObjects];
    }
    [cmd_lock unlock];
    for (NSString *c in cmds)
        q3e_console_command(c.UTF8String);
}

// Engine (main) thread, from Sys_Print: stream console output to the
// client. Non-blocking; on backpressure the remainder is dropped —
// console text is lossy-tolerable, the engine must never stall on it.
void Q3E_ConsoleBridge_Output(const char *text) {
    int fd = client_fd;
    if (fd < 0)
        return;
    size_t len = strlen(text);
    while (len > 0) {
        ssize_t n = write(fd, text, len);
        if (n <= 0)
            break; // EAGAIN/closed: drop, never block the frame
        text += n;
        len -= (size_t)n;
    }
}
