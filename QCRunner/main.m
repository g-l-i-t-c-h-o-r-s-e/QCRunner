// main.m — QC fullscreen runner (Mojave 10.14)
// Status bar app (no Dock, no ⌘-Tab). Menu bar icon controls.
// Interactive mode: mouse/keyboard go to QC; Esc/Cmd+Q quit.
// Saver mode: mouse/keys dismiss (configurable). Quartz-idle (Input-Leap friendly).
//
// BUILD (example for x86_64 only; your script handles universal):
//   clang -fobjc-arc \
//     -framework Cocoa -framework Quartz -framework IOKit \
//     -framework Carbon -framework ApplicationServices \
//     -o QCRunner main.m
//

#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>

// ===== ARC / legacy (i386) compatibility =====
#ifndef __has_feature
  #define __has_feature(x) 0
#endif

#if __has_feature(objc_arc)
  #define QCR_STRONG  strong
  #define QCR_COPY    copy
  #define QCR_WEAK    __weak
  #define QCR_AUTORELEASE(x) (x)
  #define QCR_RELEASE(x)     do{}while(0)
  #define QCR_RETAIN(x)      (x)
#else
  // i386 legacy runtime: no ARC, no __weak
  #define QCR_STRONG  retain
  #define QCR_COPY    copy
  #define QCR_WEAK    __unsafe_unretained
  #define QCR_AUTORELEASE(x) [(x) autorelease]
  #define QCR_RELEASE(x)     [(x) release]
  #define QCR_RETAIN(x)      [(x) retain]
#endif

#define QCR_WEAKIFY_SELF  QCR_WEAK __typeof(self) weakSelf = self;

static BOOL gDebug = NO;

@interface BorderlessWindow : NSWindow @end
@implementation BorderlessWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface QCFullScreenController : NSObject <NSApplicationDelegate>
{
    // Explicit ivars for legacy runtime
    NSMutableArray<NSWindow*> *_windows;
    IOPMAssertionID            _sleepAssertion;

    NSString                  *_compositionPath;

    BOOL                       _quitOnMouseMove;
    BOOL                       _anyKeyQuits;

    CFMachPortRef              _keyTap;
    CFRunLoopSourceRef         _keyTapSrc;

    id                         _globalMouseMon;
    id                         _localMouseMon;
    id                         _localKeyMon;

    NSTimeInterval             _autoQuitSeconds;
    NSTimer                   *_autoQuitTimer;

    // Saver
    BOOL                       _saverMode;
    BOOL                       _saverKeys;
    NSTimeInterval             _saverThreshold;
    NSTimer                   *_idleTimer;
    BOOL                       _isShowing;
    BOOL                       _isDismissing;

    BOOL                       _cursorHidden;

    // Activity markers
    CFAbsoluteTime             _lastActivityTS;    // any observed activity (events)
    CFAbsoluteTime             _lastNotIdleTS;     // based on Quartz idle

    // Status bar
    NSStatusItem              *_statusItem;
}

// Properties (retain/copy on legacy, strong/copy on ARC)
@property (nonatomic, QCR_STRONG) NSMutableArray<NSWindow*> *windows;
@property (nonatomic) IOPMAssertionID sleepAssertion;

@property (nonatomic, QCR_COPY)   NSString *compositionPath;

@property (nonatomic) BOOL quitOnMouseMove;   // non-saver option
@property (nonatomic) BOOL anyKeyQuits;       // non-saver option

@property (nonatomic) CFMachPortRef keyTap;          // CF types: plain assign
@property (nonatomic) CFRunLoopSourceRef keyTapSrc;  // CF types: plain assign

@property (nonatomic, QCR_STRONG) id globalMouseMon;
@property (nonatomic, QCR_STRONG) id localMouseMon;
@property (nonatomic, QCR_STRONG) id localKeyMon;

@property (nonatomic) NSTimeInterval autoQuitSeconds;
@property (nonatomic, QCR_STRONG) NSTimer *autoQuitTimer;

// Saver mode
@property (nonatomic) BOOL saverMode;
@property (nonatomic) BOOL saverKeys;
@property (nonatomic) NSTimeInterval saverThreshold;
@property (nonatomic, QCR_STRONG) NSTimer *idleTimer;
@property (nonatomic) BOOL isShowing;
@property (atomic)  BOOL isDismissing;
@property (nonatomic) BOOL cursorHidden;

// Activity markers
@property (atomic)  CFAbsoluteTime lastActivityTS;
@property (atomic)  CFAbsoluteTime lastNotIdleTS;

// Status bar
@property (nonatomic, QCR_STRONG) NSStatusItem *statusItem;
@end

// ---------- Sidecar config support ----------

static NSString *ExecutableDirectory(void) {
    NSString *argv0 = [NSProcessInfo processInfo].arguments.firstObject ?: @"";
    if (![argv0 length]) return [[NSFileManager defaultManager] currentDirectoryPath];
    if (![argv0 hasPrefix:@"/"]) {
        NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
        argv0 = [cwd stringByAppendingPathComponent:argv0];
    }
    return [argv0 stringByDeletingLastPathComponent];
}

static NSString *FindSidecarConfig(NSString *exeDir) {
    NSArray<NSString *> *cands = @[@"QCRunner.flags", @"QCRunner.conf", @"QCRunner.args"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in cands) {
        NSString *p = [exeDir stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

// Simple shell-like tokenizer: handles quotes and backslash escapes.
static NSArray<NSString *> *ShellSplit(NSString *text) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableString *tok = [NSMutableString string];
    BOOL inQuotes = NO;
    unichar qc = 0; // quote char

    // Preprocess: remove comment-only lines (# or // at start)
    NSMutableString *filtered = [NSMutableString string];
    [text enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
        NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trim hasPrefix:@"#"] || [trim hasPrefix:@"//"] || trim.length == 0) return;
        [filtered appendString:line];
        [filtered appendString:@"\n"];
    }];

    NSString *s = filtered;
    NSUInteger len = s.length;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '\\') { if (i + 1 < len) { [tok appendFormat:@"%C", [s characterAtIndex:++i]]; } continue; }
        if (inQuotes) { if (c == qc) { inQuotes = NO; qc = 0; continue; } [tok appendFormat:@"%C", c]; continue; }
        if (c == '\"') { inQuotes = YES; qc = '\"'; continue; }
        if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c]) { if (tok.length) { [out addObject:[tok copy]]; [tok setString:@""]; } continue; }
        [tok appendFormat:@"%C", c];
    }
    if (tok.length) [out addObject:[tok copy]];
    return out;
}

// If argv.count == 1, read tokens from sidecar config and append to argv array.
static NSArray<NSString *> *AugmentedArgumentsFromSidecarIfEmpty(void) {
    NSArray<NSString *> *args = [NSProcessInfo processInfo].arguments;
    if (args.count > 1) return args; // already has CLI flags

    NSString *exeDir = ExecutableDirectory();
    NSString *cfg = FindSidecarConfig(exeDir);
    if (!cfg) return args;

    NSError *err = nil;
    NSString *txt = [NSString stringWithContentsOfFile:cfg encoding:NSUTF8StringEncoding error:&err];
    if (!txt || err) return args;

    NSArray<NSString *> *tokens = ShellSplit(txt);
    if (tokens.count == 0) return args;

    NSMutableArray<NSString *> *aug = [args mutableCopy];
    [aug addObjectsFromArray:tokens];
    return aug;
}

@implementation QCFullScreenController

// Explicit ivar synthesis
@synthesize windows = _windows;
@synthesize sleepAssertion = _sleepAssertion;
@synthesize compositionPath = _compositionPath;
@synthesize quitOnMouseMove = _quitOnMouseMove;
@synthesize anyKeyQuits = _anyKeyQuits;
@synthesize keyTap = _keyTap;
@synthesize keyTapSrc = _keyTapSrc;
@synthesize globalMouseMon = _globalMouseMon;
@synthesize localMouseMon = _localMouseMon;
@synthesize localKeyMon = _localKeyMon;
@synthesize autoQuitSeconds = _autoQuitSeconds;
@synthesize autoQuitTimer = _autoQuitTimer;
@synthesize saverMode = _saverMode;
@synthesize saverKeys = _saverKeys;
@synthesize saverThreshold = _saverThreshold;
@synthesize idleTimer = _idleTimer;
@synthesize isShowing = _isShowing;
@synthesize isDismissing = _isDismissing;
@synthesize cursorHidden = _cursorHidden;
@synthesize lastActivityTS = _lastActivityTS;
@synthesize lastNotIdleTS = _lastNotIdleTS;
@synthesize statusItem = _statusItem;

#pragma mark - Logging

- (void)log:(NSString *)fmt, ... {
    if (!gDebug) return;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[QCRunner] %@", s);
}

#pragma mark - Helpers

- (void)pinLifespan {
    [[NSProcessInfo processInfo] disableAutomaticTermination:@"Saver mode running"];
    [[NSProcessInfo processInfo] disableSuddenTermination];
}
- (void)markUserActivityNow {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    self.lastActivityTS = now;
    self.lastNotIdleTS  = now;
}

#pragma mark - Power

- (void)preventSleep {
    IOPMAssertionID aid = kIOPMNullAssertionID;
    IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep,
                                kIOPMAssertionLevelOn,
                                CFSTR("QC Fullscreen Running"),
                                &aid);
    self.sleepAssertion = aid;
}
- (void)allowSleep {
    if (self.sleepAssertion) { IOPMAssertionRelease(self.sleepAssertion); self.sleepAssertion = kIOPMNullAssertionID; }
}

#pragma mark - Status bar UI

- (NSImage *)statusIconTemplate {
    // Simple "dot in ring" template image that adapts to light/dark menu bar
    NSSize sz = NSMakeSize(18, 18);
    NSImage *img = [[NSImage alloc] initWithSize:sz];
    [img setTemplate:YES];
    [img lockFocus];
    [[NSColor clearColor] setFill];
    NSRectFill(NSMakeRect(0,0,sz.width,sz.height));
    [[NSColor labelColor] setStroke];
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(NSMakeRect(2,2,14,14), 0.5, 0.5)];
    [ring setLineWidth:1.5];
    [ring stroke];
    NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(7,7,4,4)];
    [dot fill];
    [img unlockFocus];
    return img;
}

- (void)statusShowNow:(id)sender { if (!self.isShowing) [self showComposition]; }
- (void)statusDismiss:(id)sender { if (self.isShowing)  [self dismissComposition]; }
- (void)statusQuit:(id)sender    { [NSApp terminate:nil]; }

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = [self statusIconTemplate];
    self.statusItem.button.toolTip = @"QCRunner";

    NSMenu *m = [[NSMenu alloc] initWithTitle:@"QCRunner"];
    NSMenuItem *show = [[NSMenuItem alloc] initWithTitle:@"Show Screen Saver Now"
                                                   action:@selector(statusShowNow:)
                                            keyEquivalent:@""];
    [show setTarget:self];
    [m addItem:show];

    NSMenuItem *dismiss = [[NSMenuItem alloc] initWithTitle:@"Dismiss"
                                                     action:@selector(statusDismiss:)
                                              keyEquivalent:@""];
    [dismiss setTarget:self];
    [m addItem:dismiss];

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                  action:@selector(statusQuit:)
                                           keyEquivalent:@""];
    [quit setTarget:self];
    [m addItem:quit];

    self.statusItem.menu = m;
}

#pragma mark - Windows / QC

- (void)buildWindowForScreen:(NSScreen *)screen {
    NSRect f = screen.frame;
    NSWindow *win = [[BorderlessWindow alloc] initWithContentRect:f
                                                        styleMask:NSWindowStyleMaskBorderless
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO
                                                           screen:screen];
    win.opaque = YES;
    win.backgroundColor = [NSColor blackColor];
    win.level = NSMainMenuWindowLevel + 2;
    win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                             NSWindowCollectionBehaviorFullScreenAuxiliary |
                             NSWindowCollectionBehaviorStationary;
    [win setAcceptsMouseMovedEvents:YES];
    [win setIgnoresMouseEvents:NO];

    QCView *qc = [[QCView alloc] initWithFrame:win.contentView.bounds];

    // Forward all user input to the composition (keyboard, mouse, wheel, gestures)
    if ([qc respondsToSelector:@selector(setEventForwardingMask:)]) {
        [qc setEventForwardingMask:NSUIntegerMax];
    }

    qc.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [qc setAutostartsRendering:YES];

    BOOL ok = NO;
    if (self.compositionPath.length > 0) {
        ok = [qc loadCompositionFromFile:self.compositionPath];
    } else {
        NSString *bundleDefault = [[NSBundle mainBundle] pathForResource:@"Default" ofType:@"qtz"];
        if (bundleDefault) ok = [qc loadCompositionFromFile:bundleDefault];
    }
    if (!ok) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"Failed to load composition";
        a.informativeText = self.compositionPath ?: @"(no path provided)";
        [a runModal];
        if (!self.saverMode) [NSApp terminate:nil];
        return;
    }

    [win.contentView addSubview:qc];
    [win makeKeyAndOrderFront:nil];
    [win setInitialFirstResponder:qc];
    [win makeFirstResponder:qc];

    if (!self.windows) self.windows = (NSMutableArray<NSWindow*> *)[NSMutableArray array];
    [self.windows addObject:win];
}

- (void)ensureWindowsVisibleOrCreate {
    if (self.windows.count > 0) {
        for (NSWindow *w in self.windows) [w makeKeyAndOrderFront:nil];
    } else {
        for (NSScreen *screen in [NSScreen screens]) [self buildWindowForScreen:screen];
    }
}

#pragma mark - Quartz idle (works with Input-Leap)

- (NSTimeInterval)quartzIdleSeconds {
    return CGEventSourceSecondsSinceLastEventType(
        kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
}

#pragma mark - Show / Dismiss

- (void)showComposition {
    if (self.isShowing) return;
    self.isShowing = YES;
    [self log:@"showComposition"];

    [NSApp setPresentationOptions:
        NSApplicationPresentationHideDock |
        NSApplicationPresentationHideMenuBar |
        NSApplicationPresentationDisableProcessSwitching |
        NSApplicationPresentationDisableHideApplication];

    // Cursor: only hide in saver mode
    if (self.saverMode) { [NSCursor hide]; self.cursorHidden = YES; } else { self.cursorHidden = NO; }

    [self preventSleep];
    [self ensureWindowsVisibleOrCreate];

    // Raise our windows even as an Accessory app
    [NSApp activateIgnoringOtherApps:YES];

    // Reassert first responder in interactive mode
    if (!self.saverMode) {
        for (NSWindow *w in self.windows) {
            NSView *v = w.contentView.subviews.firstObject;
            if (v) [w makeFirstResponder:v];
        }
    }

    // ----- Event monitors -----
    QCR_WEAKIFY_SELF

    // Mouse
    NSEventMask mouseMasks =
        NSEventMaskMouseMoved |
        NSEventMaskLeftMouseDragged |
        NSEventMaskRightMouseDragged |
        NSEventMaskOtherMouseDragged |
        NSEventMaskLeftMouseDown |
        NSEventMaskLeftMouseUp |
        NSEventMaskRightMouseDown |
        NSEventMaskRightMouseUp |
        NSEventMaskOtherMouseDown |
        NSEventMaskOtherMouseUp |
        NSEventMaskScrollWheel;

    if (self.saverMode) {
        // Saver: dismiss on any mouse, swallow locally
        self.globalMouseMon =
            [NSEvent addGlobalMonitorForEventsMatchingMask:mouseMasks handler:^(__unused NSEvent *e){
                [weakSelf markUserActivityNow];
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf dismissComposition]; });
            }];
        self.localMouseMon =
            [NSEvent addLocalMonitorForEventsMatchingMask:mouseMasks handler:^NSEvent * _Nullable(__unused NSEvent *e){
                [weakSelf markUserActivityNow];
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf dismissComposition]; });
                return nil; // swallow in saver
            }];
    } else if (self.quitOnMouseMove) {
        // Interactive (optional): quit on mouse activity
        self.globalMouseMon =
            [NSEvent addGlobalMonitorForEventsMatchingMask:mouseMasks handler:^(__unused NSEvent *e){
                [weakSelf log:@"quit-on-mouse"];
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf quit]; });
            }];
        self.localMouseMon = nil;
    }

    // Keys
    if (!self.saverMode) {
        // Interactive: Esc/Cmd+Q quit; otherwise pass-through.
        self.localKeyMon =
            [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                  handler:^NSEvent * _Nullable(NSEvent *e) {
            [weakSelf markUserActivityNow];
            BOOL isCmd = (e.modifierFlags & NSEventModifierFlagCommand) == NSEventModifierFlagCommand;
            BOOL isEsc = (e.keyCode == 53);
            BOOL isCmdQ = (isCmd && e.keyCode == 12);
            if (weakSelf.anyKeyQuits || isEsc || isCmdQ) {
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf quit]; });
                return nil;
            }
            return e;
        }];
    } else if (self.saverKeys) {
        // Saver: any key dismiss (local monitor when active)
        self.localKeyMon =
            [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                  handler:^NSEvent * _Nullable(__unused NSEvent *e) {
            [weakSelf markUserActivityNow];
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf dismissComposition]; });
            return nil;
        }];
        // Plus a global CGEvent tap for robustness when not active (needs Accessibility)
        if ([self ensureAccessibilityTrusted]) {
            [self installCGKeyTapIfNeededForSaverAnyKey];
        }
    }
}

- (void)orderOutAllWindows {
    for (NSWindow *w in self.windows) [w orderOut:nil];
}

- (void)applicationDidBecomeActive:(NSNotification *)note
{
    // Re-focus windows when needed (accessory apps don't show in ⌘-Tab)
    for (NSWindow *w in self.windows) {
        [w makeKeyAndOrderFront:nil];
        NSView *v = w.contentView.subviews.firstObject;
        if (v && [w makeFirstResponder:v]) {
            [self log:@"Reasserted first responder to QCView"];
        }
    }
}

- (void)dismissComposition {
    if (![NSThread isMainThread]) {
        QCR_WEAKIFY_SELF
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf dismissComposition]; });
        return;
    }
    if (self.isDismissing || !self.isShowing) return;
    self.isDismissing = YES;
    [self log:@"dismissComposition"];

    [self markUserActivityNow];

    if (self.globalMouseMon) { [NSEvent removeMonitor:self.globalMouseMon]; self.globalMouseMon = nil; }
    if (self.localMouseMon)  { [NSEvent removeMonitor:self.localMouseMon];  self.localMouseMon  = nil; }
    if (self.localKeyMon)    { [NSEvent removeMonitor:self.localKeyMon];    self.localKeyMon    = nil; }

    if (self.keyTap) {
        CGEventTapEnable(self.keyTap, false);
        if (self.keyTapSrc) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), self.keyTapSrc, kCFRunLoopCommonModes);
            CFRelease(self.keyTapSrc); self.keyTapSrc = NULL;
        }
        CFMachPortInvalidate(self.keyTap);
        CFRelease(self.keyTap); self.keyTap = NULL;
    }

    if (self.cursorHidden) { [NSCursor unhide]; self.cursorHidden = NO; }
    [NSApp setPresentationOptions:0];
    [self allowSleep];

    [self orderOutAllWindows];

    self.isShowing = NO;
    self.isDismissing = NO;
}

#pragma mark - Quit

- (void)quit {
    if (self.saverMode) {
        [self dismissComposition];
    } else {
        [self dismissComposition];
        for (NSWindow *w in self.windows) [w close];
        [self.windows removeAllObjects];
        [NSApp terminate:nil];
    }
}

#pragma mark - (CGEvent tap helpers for saver keys)

static CGEventRef KeyTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    QCFullScreenController *self = (__bridge QCFullScreenController *)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (self && self.keyTap) {
            dispatch_async(dispatch_get_main_queue(), ^{ CGEventTapEnable(self.keyTap, true); });
        }
        return event;
    }
    if (type != kCGEventKeyDown) return event;

    [self markUserActivityNow];

    // In saver mode, any key -> dismiss
    QCR_WEAKIFY_SELF
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf dismissComposition]; });
    return NULL; // swallow
}

- (BOOL)ensureAccessibilityTrusted {
    NSDictionary *opts = @{(__bridge NSString*)kAXTrustedCheckOptionPrompt: @YES};
    BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    if (!trusted) {
        fprintf(stderr,
            "[QCRunner] Keyboard control needs Accessibility permission.\n"
            "System Preferences → Security & Privacy → Privacy → Accessibility: enable QCRunner%s.\n",
            [[NSProcessInfo processInfo].arguments.firstObject containsString:@"/Applications/"] ? "" : " (and your Terminal if launching from Terminal)");
    }
    return trusted;
}

- (void)installCGKeyTapIfNeededForSaverAnyKey {
    if (self.keyTap) return;
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
    self.keyTap = CGEventTapCreate(kCGSessionEventTap,
                                   kCGHeadInsertEventTap,
                                   kCGEventTapOptionDefault,
                                   mask,
                                   KeyTapCallback,
                                   (__bridge void *)self);
    if (!self.keyTap) {
        fprintf(stderr, "[QCRunner] CGEventTapCreate failed (Accessibility). Keys may not dismiss.\n");
        return;
    }
    self.keyTapSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.keyTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), self.keyTapSrc, kCFRunLoopCommonModes);
    CGEventTapEnable(self.keyTap, true);
    [self log:@"Installed CGEvent tap for key down events (saver)"];
}

#pragma mark - Idle watch / timers (Quartz-based, no cooldown/guard)

static BOOL parseFlagValue(NSArray<NSString*> *args, NSString *flag, double *outVal) {
    for (NSInteger i = 0; i < args.count; i++) {
        NSString *a = args[i];
        if ([a isEqualToString:flag] && i+1 < args.count) { *outVal = [args[i+1] doubleValue]; return YES; }
        NSString *pref = [flag stringByAppendingString:@"="];
        if ([a hasPrefix:pref]) { *outVal = [[a substringFromIndex:pref.length] doubleValue]; return YES; }
    }
    return NO;
}

- (void)scheduleAutoQuitIfNeeded {
    if (self.autoQuitSeconds > 0 && !self.saverMode) {
        QCR_WEAKIFY_SELF
        self.autoQuitTimer = [NSTimer scheduledTimerWithTimeInterval:self.autoQuitSeconds repeats:NO block:^(__unused NSTimer *t){
            [weakSelf log:@"Auto-quit timer fired"];
            [weakSelf quit];
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.autoQuitTimer forMode:NSRunLoopCommonModes];
        [self log:@"Armed auto-quit for %.2fs", self.autoQuitSeconds];
    }
}

- (void)startIdleWatch {
    if (!self.saverMode) return;
    [self log:@"startIdleWatch threshold=%.0fs", self.saverThreshold];

    // Initialize activity baselines
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    self.lastActivityTS    = now;
    self.lastNotIdleTS     = now;

    // Tunables (Quartz idle)
    const NSTimeInterval ACTIVE_CUTOFF = 0.33; // if Quartz idle < 0.33s => active

    QCR_WEAKIFY_SELF
    self.idleTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(__unused NSTimer *t){
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (self.isDismissing) return;

        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        NSTimeInterval qIdle = [self quartzIdleSeconds];

        // Rolling activity detector (Quartz)
        if (qIdle < ACTIVE_CUTOFF) {
            self.lastNotIdleTS = now;
        }

        if (self.isShowing) {
            // No guard-based auto-dismiss. Dismiss only via event monitors/tap.
            return;
        }

        // Not showing: show only after a continuous idle span ≥ threshold
        NSTimeInterval idleSpan = now - self.lastNotIdleTS;
        if (idleSpan >= self.saverThreshold) {
            [self showComposition];
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.idleTimer forMode:NSRunLoopCommonModes];
}

#pragma mark - App lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    // Status bar UI (Accessory app)
    [self setupStatusItem];

    self.windows = (NSMutableArray<NSWindow*> *)[NSMutableArray array];
    [self markUserActivityNow];

    NSArray<NSString *> *args = AugmentedArgumentsFromSidecarIfEmpty();

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification
                                               object:nil];

    NSString *exeDir = ExecutableDirectory();
    for (NSInteger i = 0; i < (NSInteger)args.count; i++) {
        NSString *a = args[i];

        if ([a isEqualToString:@"--debug"]) { gDebug = YES; continue; }

        if ([a isEqualToString:@"--comp"] && i+1 < (NSInteger)args.count) {
            NSString *val = args[++i];
            if (![val hasPrefix:@"/"]) val = [exeDir stringByAppendingPathComponent:val];
            self.compositionPath = val;
        }
        else if ([a hasPrefix:@"--comp="]) {
            NSString *val = [[a componentsSeparatedByString:@"="] lastObject] ?: @"";
            if (![val hasPrefix:@"/"]) val = [exeDir stringByAppendingPathComponent:val];
            self.compositionPath = val;
        }
        else if ([a isEqualToString:@"--quit-on-mouse"]) { self.quitOnMouseMove = YES; }
        else if ([a isEqualToString:@"--any-key"])      { self.anyKeyQuits = YES; }
        else if ([a isEqualToString:@"--ss-keys"])      { self.saverKeys = YES; }
        else if ([a isEqualToString:@"--screensaver"] && i+1 < (NSInteger)args.count) {
            self.saverMode = YES; self.saverThreshold = [args[++i] doubleValue];
        }
        else if ([a hasPrefix:@"--screensaver="]) {
            self.saverMode = YES; self.saverThreshold = [[[a componentsSeparatedByString:@"="] lastObject] doubleValue];
        }
        else if ([a isEqualToString:@"--ss"] && i+1 < (NSInteger)args.count) {
            self.saverMode = YES; self.saverThreshold = [args[++i] doubleValue];
        }
        else if ([a hasPrefix:@"--ss="]) {
            self.saverMode = YES; self.saverThreshold = [[[a componentsSeparatedByString:@"="] lastObject] doubleValue];
        }
    }
    double secs = 0.0;
    if (parseFlagValue(args, @"--auto-quit", &secs) && secs > 0.0) self.autoQuitSeconds = secs;

    if (gDebug) {
        NSMutableString *joined = [NSMutableString string];
        for (NSUInteger i = 0; i < args.count; i++) { [joined appendString:args[i]]; if (i + 1 < args.count) [joined appendString:@" "]; }
        NSLog(@"[QCRunner] argv(final): %@", joined);
        if (self.compositionPath) NSLog(@"[QCRunner] comp: %@", self.compositionPath);
    }

    if (self.saverMode) {
        [self pinLifespan];
        if (self.saverThreshold <= 0) self.saverThreshold = 300;
        [self startIdleWatch];
        [self log:@"Saver mode armed (threshold %.0fs, keys=%s). Waiting for idle…",
                  self.saverThreshold, self.saverKeys ? "on" : "off"];
    } else {
        [self showComposition];
        [self scheduleAutoQuitIfNeeded];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return self.saverMode ? NO : YES;
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        // Status bar / Accessory app: no Dock, no ⌘-Tab.
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        QCFullScreenController *delegate = [QCFullScreenController new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
