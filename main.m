#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>

@interface AppSlot : NSObject
@property(nonatomic) NSInteger number;
@property(nonatomic) UInt32 keyCode;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic, copy) NSString *path;
@end

@implementation AppSlot
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSArray<AppSlot *> *slots;
@property(nonatomic) EventHandlerRef eventHandler;
@property(nonatomic) NSMutableArray<NSValue *> *hotKeyRefs;
@property(nonatomic, strong) NSTimer *refreshTimer;
- (void)toggleSlotNumber:(NSInteger)number;
@end

static OSStatus DockNumberHotKeyHandler(
    EventHandlerCallRef nextHandler,
    EventRef event,
    void *userData
) {
    AppDelegate *delegate = (__bridge AppDelegate *)userData;
    EventHotKeyID hotKeyID = {0};
    OSStatus status = GetEventParameter(
        event,
        kEventParamDirectObject,
        typeEventHotKeyID,
        NULL,
        sizeof(hotKeyID),
        NULL,
        &hotKeyID
    );
    if (status == noErr) {
        [delegate toggleSlotNumber:(NSInteger)hotKeyID.id];
    }
    return noErr;
}

static AppSlot *Slot(
    NSInteger number,
    UInt32 keyCode,
    NSString *name,
    NSString *bundleIdentifier,
    NSString *path
) {
    AppSlot *slot = [AppSlot new];
    slot.number = number;
    slot.keyCode = keyCode;
    slot.name = name;
    slot.bundleIdentifier = bundleIdentifier;
    slot.path = path;
    return slot;
}

static UInt32 KeyCodeForNumber(NSInteger number) {
    // macOS virtual key codes for the number row: 1 2 3 4 5 6 7 8 9.
    static const UInt32 keyCodes[] = {18, 19, 20, 21, 23, 22, 26, 28, 25};
    if (number < 1 || number > 9) return 0;
    return keyCodes[number - 1];
}

static NSArray<AppSlot *> *ReadDockSlots(void) {
    NSMutableArray<AppSlot *> *slots = [NSMutableArray array];

    // Finder is always displayed first in the Dock, but macOS does not
    // include it in com.apple.dock's persistent-apps list.
    [slots addObject:Slot(
        1,
        KeyCodeForNumber(1),
        @"访达",
        @"com.apple.finder",
        @"/System/Library/CoreServices/Finder.app"
    )];

    CFPropertyListRef value = CFPreferencesCopyAppValue(
        CFSTR("persistent-apps"),
        CFSTR("com.apple.dock")
    );
    NSArray *items = CFBridgingRelease(value);
    if (![items isKindOfClass:[NSArray class]]) return slots;

    NSInteger number = 2;
    for (NSDictionary *tile in items) {
        if (number > 9 || ![tile isKindOfClass:[NSDictionary class]]) break;

        NSDictionary *tileData = tile[@"tile-data"];
        NSDictionary *fileData = tileData[@"file-data"];
        NSString *bundleIdentifier = tileData[@"bundle-identifier"];
        NSString *fileURLString = fileData[@"_CFURLString"];

        if (![fileURLString isKindOfClass:[NSString class]]) continue;
        NSURL *url = [NSURL URLWithString:fileURLString];
        NSString *path = url.path;
        if (path.length == 0) continue;

        if (bundleIdentifier.length == 0) {
            bundleIdentifier = [[NSBundle bundleWithPath:path] bundleIdentifier];
        }
        if (bundleIdentifier.length == 0 ||
            [bundleIdentifier isEqualToString:@"com.apple.finder"]) {
            continue;
        }

        BOOL duplicate = NO;
        for (AppSlot *existing in slots) {
            if ([existing.bundleIdentifier isEqualToString:bundleIdentifier]) {
                duplicate = YES;
                break;
            }
        }
        if (duplicate) continue;

        NSString *name = [[NSFileManager defaultManager] displayNameAtPath:path];
        if (name.length == 0) {
            name = [[NSBundle bundleWithPath:path]
                objectForInfoDictionaryKey:@"CFBundleDisplayName"];
        }
        if (name.length == 0) name = bundleIdentifier;

        [slots addObject:Slot(
            number,
            KeyCodeForNumber(number),
            name,
            bundleIdentifier,
            path
        )];
        number += 1;
    }

    return slots;
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.slots = ReadDockSlots();

    [self createStatusItem];
    [self installHotKeyHandler];
    [self registerHotKeys];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                           target:self
                                                         selector:@selector(refreshDockSlots)
                                                         userInfo:nil
                                                          repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self unregisterHotKeys];
    if (self.eventHandler) {
        RemoveEventHandler(self.eventHandler);
    }
}

- (void)createStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:24.0];
    self.statusItem.button.title = @"⌘";
    [self rebuildMenu];
}

- (void)rebuildMenu {
    NSMenu *menu = [NSMenu new];
    NSMenuItem *heading = [[NSMenuItem alloc]
        initWithTitle:@"Dock 数字快捷键"
        action:nil
        keyEquivalent:@""];
    heading.enabled = NO;
    [menu addItem:heading];
    [menu addItem:[NSMenuItem separatorItem]];

    for (AppSlot *slot in self.slots) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"⌘%ld  %@", (long)slot.number, slot.name]
            action:@selector(openFromMenu:)
            keyEquivalent:@""];
        item.target = self;
        item.tag = slot.number;
        [menu addItem:item];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *info = [[NSMenuItem alloc]
        initWithTitle:@"自动读取 Dock 当前顺序"
        action:nil
        keyEquivalent:@""];
    info.enabled = NO;
    [menu addItem:info];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"退出"
        action:@selector(quit)
        keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
    self.statusItem.menu = menu;
}

- (void)refreshDockSlots {
    NSArray<AppSlot *> *newSlots = ReadDockSlots();
    if (newSlots.count != self.slots.count) {
        [self unregisterHotKeys];
        self.slots = newSlots;
        [self registerHotKeys];
        [self rebuildMenu];
        return;
    }

    for (NSUInteger index = 0; index < newSlots.count; index++) {
        AppSlot *oldSlot = self.slots[index];
        AppSlot *newSlot = newSlots[index];
        if (![oldSlot.bundleIdentifier isEqualToString:newSlot.bundleIdentifier] ||
            ![oldSlot.path isEqualToString:newSlot.path]) {
            [self unregisterHotKeys];
            self.slots = newSlots;
            [self registerHotKeys];
            [self rebuildMenu];
            return;
        }
    }
}

- (void)openFromMenu:(NSMenuItem *)sender {
    [self toggleSlotNumber:sender.tag];
}

- (void)quit {
    [NSApp terminate:nil];
}

- (void)installHotKeyHandler {
    EventTypeSpec eventType = {
        .eventClass = kEventClassKeyboard,
        .eventKind = kEventHotKeyPressed
    };
    InstallEventHandler(
        GetApplicationEventTarget(),
        NewEventHandlerUPP(DockNumberHotKeyHandler),
        1,
        &eventType,
        (__bridge void *)self,
        &_eventHandler
    );
}

- (void)registerHotKeys {
    self.hotKeyRefs = [NSMutableArray arrayWithCapacity:self.slots.count];
    OSType signature = 'DNHK';
    for (AppSlot *slot in self.slots) {
        EventHotKeyID hotKeyID = {
            .signature = signature,
            .id = (UInt32)slot.number
        };
        EventHotKeyRef ref = NULL;
        RegisterEventHotKey(
            slot.keyCode,
            cmdKey,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        );
        [self.hotKeyRefs addObject:[NSValue valueWithPointer:ref]];
    }
}

- (void)unregisterHotKeys {
    for (NSValue *value in self.hotKeyRefs) {
        EventHotKeyRef ref = NULL;
        [value getValue:&ref];
        if (ref) {
            UnregisterEventHotKey(ref);
        }
    }
    self.hotKeyRefs = [NSMutableArray array];
}

- (void)toggleSlotNumber:(NSInteger)number {
    AppSlot *slot = nil;
    for (AppSlot *candidate in self.slots) {
        if (candidate.number == number) {
            slot = candidate;
            break;
        }
    }
    if (!slot) return;

    NSRunningApplication *running = nil;
    for (NSRunningApplication *candidate in [NSWorkspace sharedWorkspace].runningApplications) {
        if ([candidate.bundleIdentifier isEqualToString:slot.bundleIdentifier]) {
            running = candidate;
            break;
        }
    }

    if (running) {
        if (running.active) {
            [running hide];
        } else {
            [running activateWithOptions:
                NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps];
        }
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:slot.path];
    if ([[NSFileManager defaultManager] fileExistsAtPath:slot.path]) {
        NSWorkspaceOpenConfiguration *configuration =
            [NSWorkspaceOpenConfiguration configuration];
        [[NSWorkspace sharedWorkspace]
            openApplicationAtURL:url
            configuration:configuration
            completionHandler:nil];
        return;
    }

    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"找不到 %@", slot.name];
    alert.informativeText = @"请检查应用是否安装在 /Applications 中。";
    alert.alertStyle = NSAlertStyleWarning;
    [alert runModal];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
