// AppShell.m — minimal native iOS shell for the quake3e MoltenVK spike.
// Owns: app/scene lifecycle, a CAMetalLayer-backed view, landscape
// geometry gating (engine must not init against a portrait drawable —
// q2repro-ios lesson), and the CADisplayLink that is the ONLY pacer.

#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import "ios_input.h"

extern CAMetalLayer *q3e_layer;              // ios_metal.m
void Q3E_SetDocumentsPath(const char *path); // ios_glue.c
void Q3E_BootEngine(void);
void Q3E_Frame(void);
void Q3E_OnResignActive(void);               // ios_glue.c: sync config flush
void Q3E_SND_Pause(void);                    // ios_snd.c
void Q3E_SND_Resume(void);
void Q3E_Settings_ApplyAll(void);            // ios_settings.m

// Shell-side appliers for the iOS settings sheet. The display link is
// the ONLY pacer — the refresh-rate setting works purely by changing
// its preferredFrameRateRange (min 60 floors iOS's adaptive demotion;
// max = device native, so this is 60-vs-120 on ProMotion and a no-op
// on 60 Hz panels).
static CADisplayLink *q3e_link;
static UILabel *q3e_fpsLabel;
static NSTimer *q3e_fpsTimer;
static int q3e_frameCount;

void Q3E_Shell_SetRefreshMode(int mode60) {
    if (!q3e_link) return;
    if (@available(iOS 15.0, *)) {
        float maxHz = (float)UIScreen.mainScreen.maximumFramesPerSecond;
        if (mode60) {
            q3e_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
        } else {
            q3e_link.preferredFrameRateRange = CAFrameRateRangeMake(60, maxHz, maxHz);
        }
    }
}

void Q3E_Shell_SetFPSCounter(int enabled) {
    q3e_fpsLabel.hidden = !enabled;
    if (enabled && !q3e_fpsTimer) {
        q3e_fpsTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            static int last;
            int now = q3e_frameCount;
            q3e_fpsLabel.text = [NSString stringWithFormat:@"%d", (now - last) * 2];
            last = now;
        }];
    } else if (!enabled && q3e_fpsTimer) {
        [q3e_fpsTimer invalidate];
        q3e_fpsTimer = nil;
    }
}

@interface Q3EViewController : UIViewController
@property (nonatomic) BOOL booted;
@property (nonatomic, strong) CADisplayLink *link;
@end

@implementation Q3EViewController
- (void)loadView {
    self.view = [[Q3EInputView alloc] init];
    self.view.backgroundColor = [UIColor blackColor];
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscapeRight;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.booted) return;

    CGSize sz = self.view.bounds.size;
    if (sz.width <= sz.height) {
        NSLog(@"Q3E-SPIKE gate: geometry still portrait (%.0fx%.0f), waiting", sz.width, sz.height);
        return;
    }

    CGFloat scale = self.view.window.windowScene.screen.nativeScale;
    if (scale <= 0) scale = UIScreen.mainScreen.nativeScale;
    CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
    layer.contentsScale = scale;
    layer.drawableSize = CGSizeMake(sz.width * scale, sz.height * scale);
    q3e_layer = layer;

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    Q3E_SetDocumentsPath(docs.fileSystemRepresentation);

    // Sys_DefaultHomePath (unix_shared.c, MACOS_X branch) mkdirs
    // "$HOME/Library/Application Support/Quake3" non-recursively while
    // computing the fs_homepath DEFAULT — pre-create it so a fresh
    // container doesn't ENOENT before our +set fs_homepath even applies.
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *quake3Home = [appSupport stringByAppendingPathComponent:@"Quake3"];
    NSError *dirErr = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:quake3Home
                                 withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
        NSLog(@"Q3E-SPIKE: home precreate failed: %@", dirErr);
    }

    NSLog(@"Q3E-SPIKE boot: drawable %.0fx%.0f scale %.2f maxFPS %ld docs %@",
          layer.drawableSize.width, layer.drawableSize.height, scale,
          (long)UIScreen.mainScreen.maximumFramesPerSecond, docs);

    self.booted = YES;

    // First-run onboarding: without baseq3 the engine would ERR_FATAL
    // on default.cfg — show the data-import screen instead and boot
    // once the user has provided game files.
    int Q3E_HasGameData(void);
    void Q3E_PresentOnboarding(UIViewController *host, void (^onReady)(void));
    if (!Q3E_HasGameData()) {
        NSLog(@"Q3E-SPIKE: no game data — presenting onboarding");
        dispatch_async(dispatch_get_main_queue(), ^{
            Q3E_PresentOnboarding(self, ^{ [self bootEngineNow]; });
        });
        return;
    }
    [self bootEngineNow];
}

- (void)bootEngineNow {
    [UIApplication sharedApplication].idleTimerDisabled = YES;

    void Q3E_PakMan_Startup(void); // apply queued add-on deletions pre-boot
    Q3E_PakMan_Startup();

    Q3E_BootEngine();

    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    if (@available(iOS 15.0, *)) {
        float maxHz = (float)UIScreen.mainScreen.maximumFramesPerSecond;
        self.link.preferredFrameRateRange = CAFrameRateRangeMake(60, maxHz, maxHz);
    }
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    q3e_link = self.link;
    NSLog(@"Q3E-SPIKE display link started");

    // FPS counter overlay (top-right; the charter warns the window's
    // landscape top inset can be bogus — clamp it)
    q3e_fpsLabel = [[UILabel alloc] init];
    q3e_fpsLabel.textColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:0.9];
    q3e_fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightBold];
    q3e_fpsLabel.textAlignment = NSTextAlignmentLeft;
    q3e_fpsLabel.hidden = YES;
    q3e_fpsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:q3e_fpsLabel];
    CGFloat topInset = MIN(self.view.safeAreaInsets.top, 20.0);
    [NSLayoutConstraint activateConstraints:@[
        [q3e_fpsLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:topInset + 6],
        // top-LEFT now (the ≡ menu button moved to the top-right)
        [q3e_fpsLabel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
    ]];

    Q3E_Settings_ApplyAll();

    // Lifecycle: engine frozen + config flushed + audio paused while
    // inactive; everything resumes on reactivation.
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillDeactivateNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        self.link.paused = YES;
        Q3E_OnResignActive();
        Q3E_SND_Pause();
        NSLog(@"Q3E-SPIKE: deactivated (link paused, config flushed, audio paused)");
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (self.booted) {
            self.link.paused = NO;
            Q3E_SND_Resume();
            NSLog(@"Q3E-SPIKE: reactivated (link + audio resumed)");
        }
    }];
}
- (void)tick:(CADisplayLink *)link {
    Q3E_Frame();
    q3e_frameCount++;
}
@end

@interface Q3ESceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation Q3ESceneDelegate

// quake3e://play?game=<mod> — Shortcuts "Open URL", links, etc.
static void q3e_handleURLs(NSSet<UIOpenURLContext *> *contexts) {
    void Q3E_RequestMod(const char *mod);
    for (UIOpenURLContext *ctx in contexts) {
        NSURL *url = ctx.URL;
        if (![url.scheme isEqualToString:@"quake3e"]) continue;
        NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *game = @"baseq3";
        for (NSURLQueryItem *q in c.queryItems) {
            if ([q.name isEqualToString:@"game"] && q.value.length) game = q.value;
        }
        NSLog(@"Q3E URL launch: %@ -> mod '%@'", url, game);
        Q3E_RequestMod(game.UTF8String);
    }
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UIWindowScene *ws = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:ws];
    self.window.rootViewController = [Q3EViewController new];
    [self.window makeKeyAndVisible];
    q3e_handleURLs(options.URLContexts); // cold launch via URL
    NSLog(@"Q3E-SPIKE scene connected");
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    q3e_handleURLs(URLContexts); // warm launch: hot-switch
}

@end

@interface Q3EAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation Q3EAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
    options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *cfg = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    cfg.delegateClass = NSClassFromString(@"Q3ESceneDelegate");
    return cfg;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"Q3EAppDelegate");
    }
}
