// ios_onboarding.m — first-run game-data onboarding (charter Phase 1).
//
// The app ships with no game data. When Documents/baseq3/pak0.pk3 is
// absent at launch, this screen appears instead of the engine:
//   * explanation of what's needed and where to get it
//   * a document picker (folders or loose .pk3 files — works against
//     Files providers: iCloud, OneDrive, local)
//   * byte-progress copy into the app container, preserving game-dir
//     structure (baseq3/missionpack/<mod>); loose pk3s land in baseq3
//   * a classifier: retail vs demo pak0, point-release paks,
//     expansions and mods recognized and listed
//   * the Files-app drop-in alternate path with a "Check again" button
//   * a downloader for id's free 1.32 point release (pak1–pak8) when only
//     pak0 is present (disc installs) — size + SHA-256 pinned, mirrors
//     untrusted, never overwrites an existing file (issue #1)
// "Start" enables only when a playable baseq3 is present.

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *docsPath2(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

// The engine's FS_Startup (files.c, upstream) calls Com_Error(ERR_FATAL)
// unless pak0..pak8 are ALL present in baseq3 with their retail checksums —
// so "has game data" must mean all nine, not just pak0. Gating on pak0 alone
// let a player press Start with a partial set and the engine then exited
// silently, which was reported as "crashes on launch" (issue #1). Checksums
// are not verified here; a wrong pak still fails in the engine, but that now
// shows an alert and writes q3e-fatal.log instead of vanishing.
int Q3E_HasGameData(void) {
    NSString *docs = docsPath2();
    for (int i = 0; i <= 8; i++) {
        NSString *pak = [docs stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"baseq3/pak%d.pk3", i]];
        if (![NSFileManager.defaultManager fileExistsAtPath:pak]) return 0;
    }
    return 1;
}

// ---- 1.32 point release (pak1–pak8) downloader --------------------------
//
// pak1–pak8 are id Software's free 1.32 point-release patch files. A disc
// install has only pak0, and FS_Startup is fatal without all nine (issue #1),
// so the onboarding offers to fetch the missing ones. The pinned size + SHA-256
// below is the trust anchor; mirrors are untrusted. Values verified against
// retail 1.32 data (gamedata/baseq3) on 2026-11-05.
typedef struct { int n; unsigned long long size; const char *sha256; } q3ePrPak;
static const q3ePrPak kPointRelease[8] = {
    {1,   374405ULL, "d4ffd60b4b414c3419499e321b6f5c2e933cf082df85823ad2d6ae2f803e1682"},
    {2,  7511182ULL, "ccae938a2f13a03b24902d675181d516a431699701ed88023a307f34b5bcd58c"},
    {3,   276305ULL, "d03c0a0e06b99f9ecca2be7389f57faed406e85f7c09b9c56afdfa53ba25e312"},
    {4,  9600350ULL, "af5f6d5c82fe4440ae0bb660f0648d1fa1731a9e8305a9eb652aa243428697f1"},
    {5,   191872ULL, "69f87070ca7719e252a3ba97e6483f6663939c987ede550d1268d4d9a07b45bc"},
    {6,  7346884ULL, "bb4f0ae2bf603b050fb665436d3178ce7c1c20360e67bacf7c14d93daff38daf"},
    {7,   320873ULL, "de6283ce23e3486a2622c5dbf73d3721a59f24debd380e90f43a97d952fea283"},
    {8,   454478ULL, "812c9e97f231e89cefede3848c6110b7bd34245093af6f22c2cacde3e6b15663"},
};
// Built-in mirror base URLs (file = <base>/pakN.pk3). The remote list below
// is tried first so dead mirrors can be replaced without an app update.
static NSArray<NSString *> *prBuiltinMirrors(void) {
    return @[@"https://github.com/nrempel/q3-server/raw/master/baseq3",
             @"https://github.com/diegoulloao/ioquake3-mac-install/raw/master/dependencies/baseq3"];
}
static NSString *const kPrRemoteMirrorList =
    @"https://raw.githubusercontent.com/rebelancap/quake3e-ios/main/point-release-mirrors.json";

static NSString *prPakPath(int n) {
    return [docsPath2() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"baseq3/pak%d.pk3", n]];
}

// Indices into kPointRelease of the paks that are absent. Empty unless pak0
// exists: the patch is useless (and not what the user needs) without the game.
static NSArray<NSNumber *> *prMissing(void) {
    NSMutableArray *m = [NSMutableArray array];
    if (![NSFileManager.defaultManager fileExistsAtPath:prPakPath(0)]) return m;
    for (int i = 0; i < 8; i++) {
        if (![NSFileManager.defaultManager fileExistsAtPath:prPakPath(kPointRelease[i].n)])
            [m addObject:@(i)];
    }
    return m;
}

// Streamed SHA-256 of a file as lowercase hex, nil on read error.
static NSString *prSha256(NSString *path) {
    NSInputStream *in = [NSInputStream inputStreamWithFileAtPath:path];
    if (!in) return nil;
    [in open];
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    uint8_t buf[65536];
    NSInteger r;
    while ((r = [in read:buf maxLength:sizeof buf]) > 0) CC_SHA256_Update(&ctx, buf, (CC_LONG)r);
    [in close];
    if (r < 0) return nil;
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(md, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", md[i]];
    return hex;
}

// Downloads one URL at a time, synchronously from a background queue, into a
// private temp file (never into Documents). Progress reported per chunk.
@interface Q3EPrFetcher : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy) void (^onBytes)(int64_t written);
- (NSString *)fetch:(NSURL *)url error:(NSString **)why;   // temp path or nil
- (void)invalidate;
@end

@implementation Q3EPrFetcher {
    NSURLSession *_session;
    dispatch_semaphore_t _done;
    NSString *_tmp;
    NSString *_why;
}
- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        c.timeoutIntervalForRequest = 20;
        c.timeoutIntervalForResource = 300;
        c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        NSOperationQueue *q = [NSOperationQueue new];
        q.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:q];
    }
    return self;
}
- (void)invalidate { [_session invalidateAndCancel]; }
- (NSString *)fetch:(NSURL *)url error:(NSString **)why {
    _done = dispatch_semaphore_create(0);
    _tmp = nil; _why = nil;
    [[_session downloadTaskWithURL:url] resume];
    dispatch_semaphore_wait(_done, DISPATCH_TIME_FOREVER);
    if (!_tmp && why) *why = _why ?: @"unknown error";
    return _tmp;
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t
      didWriteData:(int64_t)b totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)exp {
    if (self.onBytes) self.onBytes(total);
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t
    didFinishDownloadingToURL:(NSURL *)location {
    NSInteger code = [t.response isKindOfClass:NSHTTPURLResponse.class]
                   ? ((NSHTTPURLResponse *)t.response).statusCode : 0;
    if (code != 200) { _why = [NSString stringWithFormat:@"HTTP %ld", (long)code]; return; }
    // The system deletes `location` when this returns; move it somewhere ours.
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"q3e-pr-%@.part", NSUUID.UUID.UUIDString]];
    NSError *err = nil;
    if ([NSFileManager.defaultManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:dst] error:&err])
        _tmp = dst;
    else
        _why = [NSString stringWithFormat:@"temp move failed: %@", err.localizedDescription];
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error {
    if (error && !_tmp) _why = error.localizedDescription;
    dispatch_semaphore_signal(_done);
}
@end

// Mirror list: Q3E_PR_MIRRORS (comma-separated) REPLACES everything — test
// hook for failure paths. Otherwise the remote list (if it parses as an array
// of https strings) followed by the built-ins, de-duplicated. Any remote
// failure is silently ignored. Call off the main thread (≤5 s network wait).
static NSArray<NSString *> *prMirrorList(void) {
    const char *env = getenv("Q3E_PR_MIRRORS");
    if (env && *env) {
        NSMutableArray *m = [NSMutableArray array];
        for (NSString *p in [@(env) componentsSeparatedByString:@","]) {
            NSString *t = [p stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (t.length) [m addObject:t];
        }
        NSLog(@"Q3E onboarding pr: mirrors from Q3E_PR_MIRRORS: %@", m);
        return m;
    }
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
    NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    c.timeoutIntervalForRequest = 5;
    c.timeoutIntervalForResource = 5;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *s = [NSURLSession sessionWithConfiguration:c];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    __block NSInteger code = 0;
    [[s dataTaskWithURL:[NSURL URLWithString:kPrRemoteMirrorList]
      completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if ([r isKindOfClass:NSHTTPURLResponse.class]) code = ((NSHTTPURLResponse *)r).statusCode;
        if (!e && code == 200) body = d;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
    [s invalidateAndCancel];
    id json = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
    NSUInteger remote = 0;
    if ([json isKindOfClass:NSArray.class]) {
        for (id e in json) {
            if ([e isKindOfClass:NSString.class] && [(NSString *)e hasPrefix:@"https://"]) {
                [set addObject:e]; remote++;
            }
        }
    }
    NSLog(@"Q3E onboarding pr: remote mirror list HTTP %ld, %lu usable entries",
          (long)code, (unsigned long)remote);
    [set addObjectsFromArray:prBuiltinMirrors()];
    return set.array;
}

// One-line human-readable classification of what's installed.
static NSString *classifyInstall(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = docsPath2();
    NSString *pak0 = [docs stringByAppendingPathComponent:@"baseq3/pak0.pk3"];
    if (![fm fileExistsAtPath:pak0]) {
        return @"No game data found yet.";
    }
    unsigned long long size = [[fm attributesOfItemAtPath:pak0 error:nil] fileSize];
    NSMutableArray *parts = [NSMutableArray array];
    if (size > 300 * 1048576ULL) {
        [parts addObject:@"Retail Quake III Arena ✓"];
    } else if (size > 30 * 1048576ULL) {
        [parts addObject:@"DEMO data (limited — retail recommended)"];
    } else {
        [parts addObject:@"Unrecognized pak0.pk3"];
    }
    NSMutableArray *missing = [NSMutableArray array];
    for (int i = 1; i <= 8; i++) {
        NSString *name = [NSString stringWithFormat:@"pak%d.pk3", i];
        if (![fm fileExistsAtPath:[docs stringByAppendingPathComponent:
                                   [@"baseq3/" stringByAppendingString:name]]]) {
            [missing addObject:name];
        }
    }
    if (missing.count == 0) {
        [parts addObject:@"1.32 point release ✓"];
    } else {
        [parts addObject:[NSString stringWithFormat:
            @"REQUIRED point-release files missing: %@ — the game cannot start without "
             "all of pak0–pak8. pak1–pak8 are id Software's free 1.32 point release "
             "patch (already included in Steam/GOG copies)",
            [missing componentsJoinedByString:@", "]]];
    }
    if ([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"missionpack/pak0.pk3"]]) {
        [parts addObject:@"Team Arena ✓"];
    }
    NSArray *known = @[@"baseq3", @"missionpack", @"screenshots", @"demos"];
    NSMutableArray *mods = [NSMutableArray array];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        BOOL isDir = NO;
        [fm fileExistsAtPath:[docs stringByAppendingPathComponent:entry] isDirectory:&isDir];
        // Dot-directories are never mods: the Files app keeps deleted items in
        // Documents/.Trash, which showed up as "mods: .Trash" (issue #1).
        if ([entry hasPrefix:@"."]) continue;
        if (isDir && ![known containsObject:entry] &&
            [fm contentsOfDirectoryAtPath:[NSString pathWithComponents:@[docs, entry]] error:nil].count) {
            [mods addObject:entry];
        }
    }
    if (mods.count) {
        [parts addObject:[NSString stringWithFormat:@"mods: %@", [mods componentsJoinedByString:@", "]]];
    }
    return [parts componentsJoinedByString:@"  •  "];
}

@interface Q3EOnboardingController : UIViewController <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^onReady)(void);
@end

@implementation Q3EOnboardingController {
    UILabel *_status;
    UIProgressView *_progress;
    UILabel *_progressLabel;
    UIButton *_startBtn;
    UIButton *_dlBtn;
    UIScrollView *_scroll;
    BOOL _downloading;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    // Hold the screen awake during a potentially long import (Team Arena is
    // ~335 MB); the engine sets idleTimerDisabled too, but not until after
    // onboarding hands off.
    [UIApplication sharedApplication].idleTimerDisabled = YES;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Quake III Arena — Game Data Setup";
    title.font = [UIFont boldSystemFontOfSize:24];
    title.textColor = UIColor.whiteColor;

    UILabel *body = [[UILabel alloc] init];
    body.numberOfLines = 0;
    body.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    body.font = [UIFont systemFontOfSize:15];
    body.text = @"This app is the Quake3e engine — it needs the game data from your own copy "
                @"of Quake III Arena (Steam, GOG, or CD).\n\n"
                @"Option 1: tap “Choose game files…” and pick your Quake III folder (the one "
                @"containing baseq3) or the pak files themselves — works with iCloud, OneDrive, "
                @"and other Files providers.\n\n"
                @"Option 2: open the Files app and copy your baseq3 folder into "
                @"“On My iPhone ▸ Quake3e”, then tap “Check again”.\n\n"
                @"Optional, anytime later: Team Arena (missionpack folder) and mods "
                @"(cpma, osp, …) the same two ways.";

    _status = [[UILabel alloc] init];
    _status.numberOfLines = 0;
    _status.font = [UIFont boldSystemFontOfSize:14];
    _status.textColor = [UIColor colorWithRed:1 green:0.85 blue:0.2 alpha:1];
    _status.text = classifyInstall();

    UIButton *pick = [UIButton buttonWithType:UIButtonTypeSystem];
    [pick setTitle:@"Choose game files…" forState:UIControlStateNormal];
    pick.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [pick addTarget:self action:@selector(pickFiles) forControlEvents:UIControlEventTouchUpInside];

    UIButton *recheck = [UIButton buttonWithType:UIButtonTypeSystem];
    [recheck setTitle:@"Check again" forState:UIControlStateNormal];
    [recheck addTarget:self action:@selector(refreshStatus) forControlEvents:UIControlEventTouchUpInside];

    _startBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_startBtn setTitle:@"Start Quake III" forState:UIControlStateNormal];
    _startBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [_startBtn addTarget:self action:@selector(startGame) forControlEvents:UIControlEventTouchUpInside];

    _dlBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _dlBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    _dlBtn.titleLabel.numberOfLines = 0;
    [_dlBtn addTarget:self action:@selector(confirmPointRelease) forControlEvents:UIControlEventTouchUpInside];
    _dlBtn.hidden = YES;

    _progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progress.hidden = YES;
    _progressLabel = [[UILabel alloc] init];
    _progressLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    _progressLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    _progressLabel.hidden = YES;
    _progressLabel.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
        @[title, body, _status, _dlBtn, pick, recheck, _progress, _progressLabel, _startBtn]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    // Scrollable: with the point-release button and a long "missing" status the
    // stack outgrows a landscape phone and Start fell off the bottom. Content is
    // centred when it fits, scrolls when it doesn't.
    _scroll = [[UIScrollView alloc] init];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [self.view addSubview:_scroll];
    [_scroll addSubview:stack];
    UILayoutGuide *content = _scroll.contentLayoutGuide, *frame = _scroll.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [content.widthAnchor constraintEqualToAnchor:frame.widthAnchor],
        [content.heightAnchor constraintGreaterThanOrEqualToAnchor:frame.heightAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:20],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-20],
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:40],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-40],
    ]];
    [self refreshStatus];
}

- (void)refreshStatus {
    _status.text = classifyInstall();
    BOOL ready = Q3E_HasGameData() != 0;
    _startBtn.enabled = ready;
    _startBtn.alpha = ready ? 1.0 : 0.35;
    NSArray *missing = prMissing();
    unsigned long long bytes = 0;
    for (NSNumber *i in missing) bytes += kPointRelease[i.intValue].size;
    _dlBtn.hidden = missing.count == 0;
    _dlBtn.enabled = !_downloading;
    [_dlBtn setTitle:[NSString stringWithFormat:@"Download free 1.32 point release (%.0f MB)",
                      bytes / 1e6 < 1 ? 1 : bytes / 1e6]
            forState:UIControlStateNormal];
    NSLog(@"Q3E onboarding status: %@", _status.text);
    NSLog(@"Q3E onboarding pr: button %@ (%lu missing, %llu bytes)%@",
          missing.count ? @"shown" : @"hidden", (unsigned long)missing.count, bytes,
          _downloading ? @" [downloading]" : @"");
}

- (void)confirmPointRelease {
    if (_downloading || prMissing().count == 0) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Download the 1.32 point release?"
        message:@"pak1–pak8 are id Software's free Quake III Arena 1.32 point-release patch "
                @"files. They will be downloaded from public mirrors and checked against their "
                @"known SHA-256 fingerprints before use. Use is subject to id Software's "
                @"point-release EULA. Only missing files are downloaded; nothing you already "
                @"have is replaced."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *x) {
        NSLog(@"Q3E onboarding pr: user cancelled");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [self downloadPointRelease]; }]];
    NSLog(@"Q3E onboarding pr: confirm shown");
    [self presentViewController:a animated:YES completion:nil];
}

- (void)downloadPointRelease {
    NSArray<NSNumber *> *missing = prMissing();
    if (_downloading || missing.count == 0) return;
    _downloading = YES;
    _dlBtn.enabled = NO;
    _progress.hidden = _progressLabel.hidden = NO;
    _progress.progress = 0;
    _progressLabel.text = @"Finding mirrors…";
    unsigned long long total = 0;
    for (NSNumber *i in missing) total += kPointRelease[i.intValue].size;
    NSLog(@"Q3E onboarding pr: start, %lu files, %llu bytes", (unsigned long)missing.count, total);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *mirrors = prMirrorList();
        NSFileManager *fm = NSFileManager.defaultManager;
        Q3EPrFetcher *f = [Q3EPrFetcher new];
        __block unsigned long long done = 0;
        NSMutableArray *failed = [NSMutableArray array];
        NSUInteger ok = 0;
        for (NSNumber *idx in missing) {
            const q3ePrPak *p = &kPointRelease[idx.intValue];
            NSString *name = [NSString stringWithFormat:@"pak%d.pk3", p->n];
            NSString *dst = prPakPath(p->n);
            unsigned long long base = done;
            f.onBytes = ^(int64_t w) {
                unsigned long long cur = base + MIN((unsigned long long)MAX(w, 0), p->size);
                float frac = total ? (float)((double)cur / (double)total) : 1.0f;
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_progress.progress = frac;
                    self->_progressLabel.text = [NSString stringWithFormat:@"%.1f / %.1f MB — %@",
                        cur / 1e6, total / 1e6, name];
                });
            };
            BOOL got = NO;
            for (NSString *m in mirrors) {
                NSURL *url = [NSURL URLWithString:[[m stringByTrimmingCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"/"]]
                    stringByAppendingFormat:@"/%@", name]];
                if (!url) { NSLog(@"Q3E onboarding pr: bad mirror %@", m); continue; }
                NSString *why = nil;
                NSString *tmp = [f fetch:url error:&why];
                if (!tmp) {
                    NSLog(@"Q3E onboarding pr: %@ from %@ failed: %@", name, url.absoluteString, why);
                    continue;
                }
                unsigned long long sz = [[fm attributesOfItemAtPath:tmp error:nil] fileSize];
                NSString *hash = sz == p->size ? prSha256(tmp) : nil;
                if (sz != p->size || ![hash isEqualToString:@(p->sha256)]) {
                    NSLog(@"Q3E onboarding pr: %@ from %@ REJECTED (size %llu want %llu, sha256 %@)",
                          name, url.absoluteString, sz, p->size, hash ?: @"-");
                    [fm removeItemAtPath:tmp error:nil];
                    continue;
                }
                // Never overwrite: moveItem fails if dst appeared meanwhile.
                NSError *err = nil;
                [fm createDirectoryAtPath:dst.stringByDeletingLastPathComponent
              withIntermediateDirectories:YES attributes:nil error:nil];
                if ([fm moveItemAtPath:tmp toPath:dst error:&err]) {
                    NSLog(@"Q3E onboarding pr: %@ OK from %@ (%llu bytes, sha256 verified)",
                          name, url.absoluteString, sz);
                    got = YES;
                } else {
                    NSLog(@"Q3E onboarding pr: %@ verified but not installed: %@",
                          name, err.localizedDescription);
                }
                [fm removeItemAtPath:tmp error:nil];   // no-op after a successful move
                break;
            }
            if (got) ok++; else [failed addObject:name];
            done = base + p->size;
        }
        [f invalidate];
        NSLog(@"Q3E onboarding pr: finished, %lu ok, %lu failed%@%@", (unsigned long)ok,
              (unsigned long)failed.count, failed.count ? @": " : @"",
              [failed componentsJoinedByString:@", "]);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_downloading = NO;
            if (failed.count == 0) {
                self->_progress.progress = 1;
                self->_progressLabel.text = @"Point release downloaded and verified.";
                [self refreshStatus];
                [self.view layoutIfNeeded];
                [self->_scroll scrollRectToVisible:[self->_scroll convertRect:self->_startBtn.bounds
                                                                     fromView:self->_startBtn]
                                          animated:YES];
                return;
            } else {
                self->_progressLabel.text = [NSString stringWithFormat:
                    @"Download failed for %@ — check your internet connection and tap "
                    @"Download to retry, or copy the files in yourself.",
                    [failed componentsJoinedByString:@", "]];
            }
            [self refreshStatus];
        });
    });
}

- (void)startGame {
    if (Q3E_HasGameData() && self.onReady) {
        void (^ready)(void) = self.onReady;
        [self dismissViewControllerAnimated:YES completion:^{ ready(); }];
    }
}

- (void)pickFiles {
    NSArray *types = @[UTTypeFolder, UTTypeItem];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

// Collect (sourceURL, destination-relative-path) pairs. Game-dir
// structure is preserved by each pk3's parent directory name; loose
// picks default to baseq3.
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSURL *> *files = [NSMutableArray array];
        NSMutableArray<NSString *> *dests = [NSMutableArray array];
        unsigned long long totalBytes = 0;

        for (NSURL *url in urls) {
            BOOL scoped = [url startAccessingSecurityScopedResource];
            NSNumber *isDir = nil;
            [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
            if (isDir.boolValue) {
                NSDirectoryEnumerator *e = [NSFileManager.defaultManager
                    enumeratorAtURL:url includingPropertiesForKeys:@[NSURLFileSizeKey]
                    options:0 errorHandler:nil];
                for (NSURL *f in e) {
                    if (![f.pathExtension.lowercaseString isEqualToString:@"pk3"] &&
                        ![f.lastPathComponent isEqualToString:@"q3key"]) continue;
                    NSString *parent = f.URLByDeletingLastPathComponent.lastPathComponent;
                    if ([parent isEqualToString:url.lastPathComponent]) parent = @"baseq3";
                    [files addObject:f];
                    [dests addObject:[parent stringByAppendingPathComponent:f.lastPathComponent]];
                    NSNumber *sz = nil; [f getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
                    totalBytes += sz.unsignedLongLongValue;
                }
            } else if ([url.pathExtension.lowercaseString isEqualToString:@"pk3"]) {
                [files addObject:url];
                [dests addObject:[@"baseq3" stringByAppendingPathComponent:url.lastPathComponent]];
                NSNumber *sz = nil; [url getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
                totalBytes += sz.unsignedLongLongValue;
            }
            (void)scoped;
        }

        NSLog(@"Q3E onboarding: importing %lu files, %.1f MB",
              (unsigned long)files.count, totalBytes / 1048576.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_progress.hidden = self->_progressLabel.hidden = NO;
            self->_progress.progress = 0;
        });

        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *docs = docsPath2();
        unsigned long long copied = 0;
        for (NSUInteger i = 0; i < files.count; i++) {
            NSURL *src = files[i];
            NSString *dst = [docs stringByAppendingPathComponent:dests[i]];
            [fm createDirectoryAtPath:dst.stringByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtPath:dst error:nil];
            NSError *err = nil;
            [fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:dst] error:&err];
            if (err) NSLog(@"Q3E onboarding copy failed %@: %@", dests[i], err);
            NSNumber *sz = nil; [src getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
            copied += sz.unsignedLongLongValue;
            float frac = totalBytes ? (float)((double)copied / (double)totalBytes) : 1.0f;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_progress.progress = frac;
                self->_progressLabel.text = [NSString stringWithFormat:@"%.0f / %.0f MB — %@",
                    copied / 1048576.0, totalBytes / 1048576.0, dests[i]];
            });
        }
        for (NSURL *url in urls) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_progressLabel.text = @"Import complete.";
            [self refreshStatus];
        });
    });
}

@end

// Present the onboarding over the game VC; calls onReady after valid
// data exists and the user taps Start.
void Q3E_PresentOnboarding(UIViewController *host, void (^onReady)(void)) {
    Q3EOnboardingController *vc = [Q3EOnboardingController new];
    vc.onReady = onReady;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [host presentViewController:vc animated:NO completion:nil];
}
