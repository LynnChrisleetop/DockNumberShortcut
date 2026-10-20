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

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    self.slots = @[
        Slot(1, 18, @"访达", @"com.apple.finder", @"/System/Library/CoreServices/Finder.app"),
        Slot(2, 19, @"Cursor", @"com.todesktop.230313mzl4w4u92", @"/Applications/Cursor.app"),
        Slot(3, 20, @"ChatGPT", @"com.openai.codex", @"/Applications/ChatGPT.app"),
        Slot(4, 21, @"Microsoft Edge", @"com.microsoft.edgemac", @"/Applications/Microsoft Edge.app"),
        Slot(5, 23, @"飞书", @"com.electron.lark", @"/Applications/Lark.app"),
        Slot(6, 22, @"网易云音乐", @"com.netease.163music", @"/Applications/NeteaseMusic.app"),
        Slot(7, 26, @"App", @"com.apple.apps.launcher", @"/System/Applications/Apps.app"),
        Slot(8, 28, @"系统设置", @"com.apple.systempreferences", @"/System/Applications/System Settings.app")
    ];

    [self createStatusItem];
    [self installHotKeyHandler];
    [self registerHotKeys];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    for (NSValue *value in self.hotKeyRefs) {
        EventHotKeyRef ref = NULL;
        [value getValue:&ref];
        if (ref) {
            UnregisterEventHotKey(ref);
        }
    }
    if (self.eventHandler) {
        RemoveEventHandler(self.eventHandler);
    }
}

- (void)createStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:24.0];
    self.statusItem.button.title = @"⌘";

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
        initWithTitle:@"已按当前 Dock 顺序设置"
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
