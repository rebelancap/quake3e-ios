// ios_pakman.m — add-on pak manager (D-009: the A51 affair made this a
// hard requirement — a server silently auto-downloaded a UI-replacing
// pk3 into baseq3).
//
// Model: at first boot, every pk3 under Documents/ is snapshotted into
// a manifest (stored in Library/, outside the engine's filesystem view)
// as "provisioned". Any pk3 that appears later — server auto-downloads,
// Files-app drop-ins — is an "add-on", listed in the settings sheet
// with per-file removal. Removals are queued and applied on the NEXT
// launch, before Com_Init, so the engine never loses an open pk3.

#import <UIKit/UIKit.h>

#define MANIFEST_FILE @"q3e_pak_manifest.plist"
#define PENDING_FILE  @"q3e_pak_pending_delete.plist"

static NSString *libraryPath(NSString *name) {
    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    return [lib stringByAppendingPathComponent:name];
}

static NSString *docsPath(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

// All pk3s under Documents, as Documents-relative paths.
static NSArray<NSString *> *scanPaks(void) {
    NSMutableArray *result = [NSMutableArray array];
    NSString *docs = docsPath();
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:docs];
    for (NSString *rel in e) {
        if ([rel.pathExtension.lowercaseString isEqualToString:@"pk3"]) {
            [result addObject:rel];
        }
    }
    return result;
}

// Called from AppShell BEFORE the engine boots: apply queued deletions,
// then ensure the manifest exists (first boot snapshots everything).
void Q3E_PakMan_Startup(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = docsPath();

    NSArray *pending = [NSArray arrayWithContentsOfFile:libraryPath(PENDING_FILE)];
    if (pending.count) {
        for (NSString *rel in pending) {
            NSString *full = [docs stringByAppendingPathComponent:rel];
            NSError *err = nil;
            if ([fm removeItemAtPath:full error:&err]) {
                NSLog(@"Q3E pakman: removed add-on %@", rel);
            } else {
                NSLog(@"Q3E pakman: failed to remove %@: %@", rel, err);
            }
        }
        [fm removeItemAtPath:libraryPath(PENDING_FILE) error:nil];
    }

    if (![fm fileExistsAtPath:libraryPath(MANIFEST_FILE)]) {
        NSArray *all = scanPaks();
        [all writeToFile:libraryPath(MANIFEST_FILE) atomically:YES];
        NSLog(@"Q3E pakman: first-boot manifest snapshot (%lu paks provisioned)",
              (unsigned long)all.count);
    }
}

// Add-ons = present now, absent from the manifest, not already pending.
NSArray<NSString *> *Q3E_PakMan_AddOns(void) {
    NSSet *manifest = [NSSet setWithArray:
        [NSArray arrayWithContentsOfFile:libraryPath(MANIFEST_FILE)] ?: @[]];
    NSSet *pending = [NSSet setWithArray:
        [NSArray arrayWithContentsOfFile:libraryPath(PENDING_FILE)] ?: @[]];
    NSMutableArray *addons = [NSMutableArray array];
    for (NSString *rel in scanPaks()) {
        if (![manifest containsObject:rel] && ![pending containsObject:rel]) {
            [addons addObject:rel];
        }
    }
    return addons;
}

void Q3E_PakMan_QueueDelete(NSString *rel) {
    NSMutableArray *pending = [[NSArray arrayWithContentsOfFile:libraryPath(PENDING_FILE)] mutableCopy]
        ?: [NSMutableArray array];
    if (![pending containsObject:rel]) {
        [pending addObject:rel];
        [pending writeToFile:libraryPath(PENDING_FILE) atomically:YES];
    }
}

// ---- the list UI (pushed from the settings sheet) ----

@interface Q3EPakListController : UITableViewController
@end

@implementation Q3EPakListController {
    NSMutableArray<NSString *> *_addons;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Add-on Paks";
    _addons = [Q3E_PakMan_AddOns() mutableCopy];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _addons.count ?: 1;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    if (_addons.count == 0) {
        cell.textLabel.text = @"No add-on paks";
        cell.detailTextLabel.text = @"Server downloads and Files-app drop-ins appear here.";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSString *rel = _addons[ip.row];
    NSString *full = [docsPath() stringByAppendingPathComponent:rel];
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:full error:nil];
    cell.textLabel.text = rel;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1f MB — swipe to remove (applies at next launch)",
                                 [attrs fileSize] / 1048576.0];
    return cell;
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return _addons.count > 0;
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style
    forRowAtIndexPath:(NSIndexPath *)ip {
    if (style == UITableViewCellEditingStyleDelete && ip.row < (NSInteger)_addons.count) {
        Q3E_PakMan_QueueDelete(_addons[ip.row]);
        [_addons removeObjectAtIndex:ip.row];
        [tv reloadData];
    }
}

@end

void Q3E_PresentPakList(UIViewController *from) {
    Q3EPakListController *vc = [Q3EPakListController new];
    if (from.navigationController) {
        [from.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [from presentViewController:nav animated:YES completion:nil];
    }
}
