#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>

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
@property(nonatomic) BOOL hotKeysActive;
@property(nonatomic) AXError lastAccessibilityError;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *nextWindowIndices;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSValue *> *> *windowOrders;
- (void)toggleSlotNumber:(NSInteger)number;
- (void)releaseAllWindowOrders;
- (void)releaseWindowOrderForBundleIdentifier:(NSString *)bundleIdentifier;
@end

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

static BOOL SameAccessibilityWindow(AXUIElementRef first, AXUIElementRef second) {
    if (!first || !second) return NO;
    return first == second || CFEqual(first, second);
}

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
    if (status == noErr && hotKeyID.signature == 'DNHK') {
        [delegate toggleSlotNumber:(NSInteger)hotKeyID.id];
    }
    return noErr;
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
    self.nextWindowIndices = [NSMutableDictionary dictionary];
    self.windowOrders = [NSMutableDictionary dictionary];
    self.lastAccessibilityError = kAXErrorSuccess;

    [self createStatusItem];
    [self installHotKeyHandler];
    [self registerHotKeys];
    [self rebuildMenu];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                           target:self
                                                         selector:@selector(refreshDockSlots)
                                                         userInfo:nil
                                                          repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self unregisterHotKeys];
    if (self.refreshTimer) [self.refreshTimer invalidate];
    [self releaseAllWindowOrders];
    if (self.eventHandler) {
        RemoveEventHandler(self.eventHandler);
        self.eventHandler = NULL;
    }
}

- (void)createStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:24.0];
    self.statusItem.button.title = @"⌥";
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
        initWithTitle:[NSString stringWithFormat:@"⌥%ld  %@", (long)slot.number, slot.name]
            action:@selector(openFromMenu:)
            keyEquivalent:@""];
        item.target = self;
        item.tag = slot.number;
        [menu addItem:item];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSString *infoTitle = nil;
    if (!self.hotKeysActive) {
        infoTitle = @"快捷键未启动：系统没有接受快捷键注册";
    } else if (self.lastAccessibilityError == kAXErrorAPIDisabled) {
        infoTitle = @"快捷键已触发，但辅助功能未生效（AX -25211）";
    } else if (self.lastAccessibilityError != kAXErrorSuccess) {
        infoTitle = [NSString stringWithFormat:
            @"窗口读取失败（AX 错误 %d），请重新添加当前应用",
            self.lastAccessibilityError];
    } else {
        infoTitle = @"自动读取 Dock 当前顺序";
    }
    NSMenuItem *info = [[NSMenuItem alloc]
        initWithTitle:infoTitle
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
    OSStatus status = InstallEventHandler(
        GetApplicationEventTarget(),
        NewEventHandlerUPP(DockNumberHotKeyHandler),
        1,
        &eventType,
        (__bridge void *)self,
        &_eventHandler
    );
    if (status != noErr) self.eventHandler = NULL;
}

- (void)registerHotKeys {
    self.hotKeyRefs = [NSMutableArray arrayWithCapacity:self.slots.count];
    self.hotKeysActive = (self.eventHandler != NULL);
    OSType signature = 'DNHK';

    for (AppSlot *slot in self.slots) {
        EventHotKeyID hotKeyID = {
            .signature = signature,
            .id = (UInt32)slot.number
        };
        EventHotKeyRef ref = NULL;
        OSStatus status = RegisterEventHotKey(
            slot.keyCode,
            optionKey,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        );
        if (status != noErr || !ref) {
            self.hotKeysActive = NO;
        } else {
            [self.hotKeyRefs addObject:[NSValue valueWithPointer:ref]];
        }
    }
    if (!self.hotKeysActive) {
        for (NSValue *value in self.hotKeyRefs) {
            EventHotKeyRef ref = value.pointerValue;
            if (ref) UnregisterEventHotKey(ref);
        }
        self.hotKeyRefs = [NSMutableArray array];
        self.statusItem.button.title = @"!";
    } else {
        self.statusItem.button.title = @"⌥";
    }
}

- (void)unregisterHotKeys {
    for (NSValue *value in self.hotKeyRefs) {
        EventHotKeyRef ref = value.pointerValue;
        if (ref) UnregisterEventHotKey(ref);
    }
    self.hotKeyRefs = [NSMutableArray array];
    self.hotKeysActive = NO;
}

- (NSArray<NSValue *> *)accessibilityWindowsForApplication:(NSRunningApplication *)application {
    AXUIElementRef applicationElement =
        AXUIElementCreateApplication(application.processIdentifier);
    if (!applicationElement) {
        self.lastAccessibilityError = kAXErrorFailure;
        return nil;
    }

    CFTypeRef windowsValue = NULL;
    AXError error = AXUIElementCopyAttributeValue(
        applicationElement,
        kAXWindowsAttribute,
        &windowsValue
    );
    if (error != kAXErrorSuccess || !windowsValue ||
        CFGetTypeID(windowsValue) != CFArrayGetTypeID()) {
        if (windowsValue) CFRelease(windowsValue);
        CFRelease(applicationElement);
        self.lastAccessibilityError =
            error == kAXErrorSuccess ? kAXErrorFailure : error;
        return nil;
    }

    CFArrayRef windows = (CFArrayRef)windowsValue;
    NSMutableArray<NSValue *> *windowRefs = [NSMutableArray array];
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex index = 0; index < count; index++) {
        AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, index);
        if (window) {
            // Keep the AX element alive after the returned CFArray is released.
            CFRetain(window);
            [windowRefs addObject:[NSValue valueWithPointer:window]];
        }
    }

    CFRelease(windowsValue);
    CFRelease(applicationElement);
    self.lastAccessibilityError = kAXErrorSuccess;
    return windowRefs;
}

- (void)releaseAccessibilityWindows:(NSArray<NSValue *> *)windows {
    for (NSValue *value in windows) {
        AXUIElementRef window = value.pointerValue;
        if (window) CFRelease(window);
    }
}

- (void)releaseAllWindowOrders {
    for (NSString *bundleIdentifier in [self.windowOrders.allKeys copy]) {
        [self releaseWindowOrderForBundleIdentifier:bundleIdentifier];
    }
    [self.windowOrders removeAllObjects];
}

- (void)releaseWindowOrderForBundleIdentifier:(NSString *)bundleIdentifier {
    NSArray<NSValue *> *order = self.windowOrders[bundleIdentifier];
    for (NSValue *value in order) {
        AXUIElementRef window = value.pointerValue;
        if (window) CFRelease(window);
    }
    [self.windowOrders removeObjectForKey:bundleIdentifier];
}

- (NSArray<NSValue *> *)stableWindowOrderForBundleIdentifier:(NSString *)bundleIdentifier
                                                     windows:(NSArray<NSValue *> *)windows {
    NSMutableArray<NSValue *> *order = self.windowOrders[bundleIdentifier];
    if (!order) {
        order = [NSMutableArray array];
        self.windowOrders[bundleIdentifier] = order;
    }

    // Remove windows that were closed since the previous shortcut press.
    for (NSInteger index = order.count - 1; index >= 0; index--) {
        NSValue *stored = order[index];
        BOOL stillExists = NO;
        for (NSValue *current in windows) {
            if (SameAccessibilityWindow(stored.pointerValue, current.pointerValue)) {
                stillExists = YES;
                break;
            }
        }
        if (!stillExists) {
            AXUIElementRef window = stored.pointerValue;
            if (window) CFRelease(window);
            [order removeObjectAtIndex:index];
        }
    }

    // Append newly created windows without changing the order of existing ones.
    for (NSValue *current in windows) {
        BOOL alreadyStored = NO;
        for (NSValue *stored in order) {
            if (SameAccessibilityWindow(stored.pointerValue, current.pointerValue)) {
                alreadyStored = YES;
                break;
            }
        }
        if (!alreadyStored && current.pointerValue) {
            CFRetain(current.pointerValue);
            [order addObject:current];
        }
    }

    return [order copy];
}

- (void)showAccessibilityWindow:(AXUIElementRef)window
                       application:(NSRunningApplication *)application
                       allWindows:(NSArray<NSValue *> *)windows {
    if (!window) return;

    // Keep the other windows open, but make only the selected one visible.
    // This avoids macOS bringing every window forward when the app activates.
    for (NSValue *value in windows) {
        AXUIElementRef otherWindow = value.pointerValue;
        if (otherWindow && !SameAccessibilityWindow(otherWindow, window)) {
            AXUIElementSetAttributeValue(
                otherWindow,
                kAXMinimizedAttribute,
                kCFBooleanTrue
            );
        }
    }
    AXUIElementSetAttributeValue(
        window,
        kAXMinimizedAttribute,
        kCFBooleanFalse
    );
    [application unhide];
    [application activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    AXUIElementPerformAction(window, kAXRaiseAction);
    AXUIElementSetAttributeValue(window, kAXMainAttribute, kCFBooleanTrue);
    AXUIElementSetAttributeValue(window, kAXFocusedAttribute, kCFBooleanTrue);
}

- (void)showApplicationWithoutWindow:(NSRunningApplication *)application {
    [application unhide];
    [application activateWithOptions:NSApplicationActivateIgnoringOtherApps];
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

    if (!running) {
        [self releaseWindowOrderForBundleIdentifier:slot.bundleIdentifier];
        NSURL *url = [NSURL fileURLWithPath:slot.path];
        if ([[NSFileManager defaultManager] fileExistsAtPath:slot.path]) {
            NSWorkspaceOpenConfiguration *configuration =
                [NSWorkspaceOpenConfiguration configuration];
            [[NSWorkspace sharedWorkspace]
                openApplicationAtURL:url
                configuration:configuration
                completionHandler:nil];
            self.nextWindowIndices[slot.bundleIdentifier] = @0;
            return;
        }

        NSAlert *alert = [NSAlert new];
        alert.messageText = [NSString stringWithFormat:@"找不到 %@", slot.name];
        alert.informativeText = @"请检查应用是否安装在 Dock 显示的位置。";
        alert.alertStyle = NSAlertStyleWarning;
        [alert runModal];
        return;
    }

    NSArray<NSValue *> *windows = [self accessibilityWindowsForApplication:running];
    if (!windows) {
        [self releaseWindowOrderForBundleIdentifier:slot.bundleIdentifier];
        self.nextWindowIndices[slot.bundleIdentifier] = @0;
        [self rebuildMenu];
        return;
    }
    NSUInteger windowCount = windows.count;

    if (windowCount <= 1) {
        [self releaseWindowOrderForBundleIdentifier:slot.bundleIdentifier];
        self.nextWindowIndices[slot.bundleIdentifier] = @0;
        if (running.active) {
            [running hide];
        } else if (windowCount == 1) {
            AXUIElementRef window = windows.firstObject.pointerValue;
            [self showAccessibilityWindow:window
                             application:running
                             allWindows:windows];
        } else {
            [self showApplicationWithoutWindow:running];
        }
        [self releaseAccessibilityWindows:windows];
        return;
    }

    NSArray<NSValue *> *orderedWindows =
        [self stableWindowOrderForBundleIdentifier:slot.bundleIdentifier
                                           windows:windows];
    NSUInteger orderedWindowCount = orderedWindows.count;
    if (orderedWindowCount == 0) {
        [self releaseAccessibilityWindows:windows];
        return;
    }

    NSInteger index = 0;
    if (running.active) {
        index = [self.nextWindowIndices[slot.bundleIdentifier] integerValue];
        if (index < 0 || index >= (NSInteger)orderedWindowCount) index = 0;
    }

    AXUIElementRef window = orderedWindows[index].pointerValue;
    [self showAccessibilityWindow:window
                     application:running
                     allWindows:windows];

    self.nextWindowIndices[slot.bundleIdentifier] =
        @((index + 1) % (NSInteger)orderedWindowCount);
    [self releaseAccessibilityWindows:windows];
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
