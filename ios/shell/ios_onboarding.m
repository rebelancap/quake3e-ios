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
// "Start" enables only when a playable baseq3 is present.

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *docsPath2(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

int Q3E_HasGameData(void) {
    NSString *pak0 = [docsPath2() stringByAppendingPathComponent:@"baseq3/pak0.pk3"];
    return [NSFileManager.defaultManager fileExistsAtPath:pak0] ? 1 : 0;
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
    if ([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"baseq3/pak8.pk3"]]) {
        [parts addObject:@"1.32 point release ✓"];
    } else {
        [parts addObject:@"point-release paks (pak1–8) missing — multiplayer may be limited"];
    }
    if ([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"missionpack/pak0.pk3"]]) {
        [parts addObject:@"Team Arena ✓"];
    }
    NSArray *known = @[@"baseq3", @"missionpack", @"screenshots", @"demos"];
    NSMutableArray *mods = [NSMutableArray array];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        BOOL isDir = NO;
        [fm fileExistsAtPath:[docs stringByAppendingPathComponent:entry] isDirectory:&isDir];
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

    _progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progress.hidden = YES;
    _progressLabel = [[UILabel alloc] init];
    _progressLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    _progressLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    _progressLabel.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
        @[title, body, _status, pick, recheck, _progress, _progressLabel, _startBtn]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:40],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-40],
    ]];
    [self refreshStatus];
}

- (void)refreshStatus {
    _status.text = classifyInstall();
    BOOL ready = Q3E_HasGameData() != 0;
    _startBtn.enabled = ready;
    _startBtn.alpha = ready ? 1.0 : 0.35;
    NSLog(@"Q3E onboarding status: %@", _status.text);
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
