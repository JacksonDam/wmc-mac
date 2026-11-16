// The "Desktop" protocol: the display list of monitors, the form window and
// its input router.
//
// A FormWindow is the scene window plus a real Mac window. In test runs
// (WMC_HEADLESS) no Mac window is made at all: the scene is rendered
// offscreen and written to WMC_SNAPSHOT, so nothing appears on the user's
// screen and nothing takes focus.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import "sp_render.h"
#import "sp_scene.h"

HWND wmc_window_adopt(const char *className, void *proc, WmcThreadQueue *queue);
void sp_animation_tick(void);
BOOL sp_animation_settling(void);
WmcThreadQueue *sp_app_queue(uint32_t idContext);

typedef struct __attribute__((packed)) {
    uint32_t cbSize;
    int32_t nMsg;
    uint32_t idObjectSubject;
    uint32_t uRecentlyChanged;      // 1 window state, 2 activation, 4 visibility
    uint32_t uCurrentMode;          // 0 normal, 1 minimised, 2 maximised
    uint32_t uActivation;           // 1 active
    int32_t fVisible;
    int32_t cx, cy;                 // client size in pixels
    int32_t left, top, right, bottom;
    uint32_t idDisplay;
    uint32_t cSpanningMonitors;
    int32_t fExclusive;
    int32_t fOnSecondaryMonitor;
} SpFormState;
_Static_assert(sizeof(SpFormState) == 68, "form state layout");

typedef struct __attribute__((packed)) {
    uint32_t cbSize;
    int32_t nMsg;
    uint32_t idObjectSubject;
    uint32_t idDisplay;
    uint32_t nTvFormat;
    int32_t width, height;
    uint32_t nFormat;
    int32_t nRefreshRate;
    uint32_t fInterlaced;
    uint32_t cbMiSize;
    int32_t rcMon[4];
    int32_t rcWork[4];
    uint32_t dwFlags;               // 1 primary
    uint16_t szDevice[32];
    uint16_t szMonitorPnP[64];
} SpMonitorInfo;
_Static_assert(sizeof(SpMonitorInfo) == 272, "monitor info layout");

#define SP_FORMAT_RGB32 2099336u

// Input reaches the framework as a blob inside InputCallback.OnInput. These
// are the framework's own layouts for the two kinds used here.
typedef struct __attribute__((packed)) {
    uint32_t cbSize;
    int32_t nMsg;
    uint32_t idObjectSubject;
    uint32_t hOwner;
    uint32_t uCode;        // 1: keyboard
    int32_t isRemote;
    int32_t scanCode;
    int32_t vk;            // Windows virtual-key code (or the character, for a character message)
    uint32_t uiMsg;        // 0 down, 1 up, 2 character; 3, 4, 5 the same with Alt held
    int32_t cRep;
    uint32_t dwState;      // modifiers
} SpKeyboardInput;

typedef struct __attribute__((packed)) {
    uint32_t cbSize;
    int32_t nMsg;
    uint32_t idObjectSubject;
    uint32_t ownerCookie;
    uint32_t ownerMessage; // 4: mouse
    uint32_t uMessage;     // WM_MOUSEMOVE, WM_LBUTTONDOWN, ...
    uint32_t dwSubject;    // the visual that receives the event
    int32_t ptPositionX, ptPositionY;   // in the subject's coordinates
    uint32_t dwNatural;    // the visual actually under the pointer
    int32_t ptNaturalX, ptNaturalY;
    int32_t ptPhysicalX, ptPhysicalY;   // in the window's client pixels
    uint32_t nModifiers;
    uint32_t bButton;
    int16_t wheelDelta;
    uint8_t _pad[2];
} SpMouseInput;

enum {
    SpModControl = 1, SpModShift = 2, SpModAlt = 4, SpModWindows = 8,
    SpModLeftMouse = 0x10, SpModRightMouse = 0x20, SpModMiddleMouse = 0x40,
};
enum { SpWmMouseMove = 0x200, SpWmLButtonDown = 0x201, SpWmLButtonUp = 0x202, SpWmRButtonDown = 0x204,
       SpWmRButtonUp = 0x205, SpWmMButtonDown = 0x207, SpWmMButtonUp = 0x208, SpWmMouseWheel = 0x20A,
       SpWmMouseLeave = 0x2A3 };

@class SpInputRouter;

static void copy_utf16(uint16_t *dst, size_t cap, NSString *s) {
    NSUInteger n = MIN(s.length, cap - 1);
    [s getCharacters:dst range:NSMakeRange(0, n)];
    dst[n] = 0;
}

// --------------------------------------------------------------- DesktopManager

@interface SpDesktopManager : SpObject
@end

@implementation SpDesktopManager

- (void)spConstruct:(const SpMessage *)msg {
    const struct Sp_RemoteDesktopManager_Create *m = (const void *)msg;
    if (msg && msg->cbSize >= sizeof(*m)) {
        self.cbObject = m->objcb.value;
        self.cbContext = m->ctxcb.value;
    }
}

- (void)simple:(uint32_t)msgid {
    struct Sp_LocalDesktopManagerCallback_OnBeginEnumMonitorInfo cb = {0};   // every "no argument" callback has this shape
    cb.size = sizeof(cb);
    cb.msgid = msgid;
    cb.idObjectSubject.value = self.cbObject;
    cb.target.value = self.handle;
    [self.context sendCallback:&cb toContext:self.cbContext];
}

- (void)rebuildMonitorCache {
    if (!self.cbObject) return;
    [self simple:SpMsg_DesktopManagerCallback_OnBeginEnumMonitorInfo];
    uint32_t count = 0;
    CGDirectDisplayID displays[16];
    CGGetActiveDisplayList(16, displays, &count);
    CGDirectDisplayID main = CGMainDisplayID();
    for (uint32_t i = 0; i < count; i++) {
        CGRect bounds = CGDisplayBounds(displays[i]);
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displays[i]);
        int refresh = mode ? (int)lround(CGDisplayModeGetRefreshRate(mode)) : 60;
        if (refresh <= 0) refresh = 60;
        if (mode) CGDisplayModeRelease(mode);

        struct {
            struct Sp_LocalDesktopManagerCallback_OnMonitorInfo head;
            SpMonitorInfo info;
        } __attribute__((packed)) cb;
        memset(&cb, 0, sizeof(cb));
        cb.head.size = sizeof(cb);
        cb.head.msgid = SpMsg_DesktopManagerCallback_OnMonitorInfo;
        cb.head.idObjectSubject.value = self.cbObject;
        cb.head.target.value = self.handle;
        cb.head.info.value = (uint32_t)sizeof(cb.head) | ((uint32_t)sizeof(cb.info) << 16);
        cb.info.cbSize = sizeof(cb.info);
        cb.info.idDisplay = displays[i];
        cb.info.width = (int32_t)bounds.size.width;
        cb.info.height = (int32_t)bounds.size.height;
        cb.info.nFormat = SP_FORMAT_RGB32;
        cb.info.nRefreshRate = refresh;
        cb.info.cbMiSize = 104;   // sizeof(MONITORINFOEXW)
        cb.info.rcMon[0] = cb.info.rcWork[0] = (int32_t)bounds.origin.x;
        cb.info.rcMon[1] = cb.info.rcWork[1] = (int32_t)bounds.origin.y;
        cb.info.rcMon[2] = cb.info.rcWork[2] = (int32_t)(bounds.origin.x + bounds.size.width);
        cb.info.rcMon[3] = cb.info.rcWork[3] = (int32_t)(bounds.origin.y + bounds.size.height);
        cb.info.dwFlags = displays[i] == main ? 1 : 0;
        copy_utf16(cb.info.szDevice, 32, [NSString stringWithFormat:@"\\\\.\\DISPLAY%u", i + 1]);
        copy_utf16(cb.info.szMonitorPnP, 64, @"MONITOR\\Default_Monitor");
        [self.context sendCallback:&cb toContext:self.cbContext];

        // One display mode: the current one.
        [self simple:SpMsg_DesktopManagerCallback_OnBeginDisplayModes];
        struct Sp_LocalDesktopManagerCallback_OnDisplayMode dm = {0};
        dm.size = sizeof(dm);
        dm.msgid = SpMsg_DesktopManagerCallback_OnDisplayMode;
        dm.idObjectSubject.value = self.cbObject;
        dm.target.value = self.handle;
        dm.mode.sizePhysicalPxl.m_width = dm.mode.sizeLogicalPxl.m_width = cb.info.width;
        dm.mode.sizePhysicalPxl.m_height = dm.mode.sizeLogicalPxl.m_height = cb.info.height;
        dm.mode.nFormat = SP_FORMAT_RGB32;
        dm.mode.nRefreshRate = refresh;
        dm.fSupported = 1;
        [self.context sendCallback:&dm toContext:self.cbContext];
        [self simple:SpMsg_DesktopManagerCallback_OnEndDisplayModes];
    }
    [self simple:SpMsg_DesktopManagerCallback_OnEndEnumMonitorInfo];
}

- (void)spMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case SpMsg_DesktopManager_RebuildMonitorCache:
            [self rebuildMonitorCache];
            break;
        default:
            [self spUnhandled:msg];
    }
}

@end

// ------------------------------------------------------------------ FormWindow

@class SpFormWindow;

@interface SpFormView : NSView
@property (nonatomic, weak) SpFormWindow *owner;
@end

@interface SpFormWindow : SpWindow <NSWindowDelegate>
@property (nonatomic, weak) SpInputRouter *inputRouter;
- (void)drawIfNeeded;
- (void)keyEvent:(NSEvent *)event down:(BOOL)down;
- (void)modifiersChanged:(NSEvent *)event;
- (void)mouseEvent:(NSEvent *)event message:(uint32_t)message button:(uint32_t)button;
- (void)sendKey:(int)vk message:(uint32_t)message repeat:(int)repeat modifiers:(uint32_t)modifiers;
- (void)sendMouse:(uint32_t)message x:(float)x y:(float)y button:(uint32_t)button modifiers:(uint32_t)modifiers wheel:(int)wheel;
@end

@interface SpInputRouter : SpObject
@end

@implementation SpFormView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
    }
    return self;
}

- (CALayer *)makeBackingLayer {
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = sp_metal_device();
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    return layer;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

// A click on the window while another app is in front acts on what was
// clicked, as well as bringing the window forward.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (void)tick:(id)sender {
    [self.owner drawIfNeeded];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in [self.trackingAreas copy]) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                       options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                               NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil]];
}

- (void)keyDown:(NSEvent *)event { [self.owner keyEvent:event down:YES]; }
- (void)keyUp:(NSEvent *)event { [self.owner keyEvent:event down:NO]; }
- (void)flagsChanged:(NSEvent *)event { [self.owner modifiersChanged:event]; }
- (void)mouseMoved:(NSEvent *)event { [self.owner mouseEvent:event message:SpWmMouseMove button:0]; }
- (void)mouseDragged:(NSEvent *)event { [self.owner mouseEvent:event message:SpWmMouseMove button:0]; }
- (void)rightMouseDragged:(NSEvent *)event { [self.owner mouseEvent:event message:SpWmMouseMove button:0]; }
- (void)mouseDown:(NSEvent *)event { [self.owner mouseEvent:event message:SpWmLButtonDown button:1]; }
- (void)mouseUp:(NSEvent *)event { [self.owner mouseEvent:event message:SpWmLButtonUp button:1]; }
- (void)rightMouseDown:(NSEvent *)event { [self.owner mouseEvent:event message:SpWmRButtonDown button:2]; }
- (void)rightMouseUp:(NSEvent *)event { [self.owner mouseEvent:event message:SpWmRButtonUp button:2]; }
- (void)otherMouseDown:(NSEvent *)event { [self.owner mouseEvent:event message:SpWmMButtonDown button:4]; }
- (void)otherMouseUp:(NSEvent *)event { [self.owner mouseEvent:event message:SpWmMButtonUp button:4]; }
- (void)scrollWheel:(NSEvent *)event { [self.owner mouseEvent:event message:SpWmMouseWheel button:0]; }
- (void)mouseExited:(NSEvent *)event { [self.owner mouseEvent:event message:SpWmMouseLeave button:0]; }

@end

static NSArray<NSArray<NSString *> *> *script_commands(NSString *script);

@implementation SpFormWindow {
    NSWindow *_window;
    SpFormView *_view;
    id _displayLink;
    NSTimer *_timer;
    HWND _hwnd;
    int _clientW, _clientH;
    int _posX, _posY;
    BOOL _visible, _headless, _destroyed;
    uint32_t _mode;
    NSString *_title;
    uint64_t _drawnGeneration;
    uint32_t _hitTraverse, _hitHit, _hitResult;
    double _wheelRemainder;
    BOOL _focusSent;
    BOOL _changing, _modeQueued;   // a full-screen transition is under way; a mode request waits for it
}

- (void)spConstruct:(const SpMessage *)msg {
    const struct Sp_RemoteFormWindow_Create *m = (const void *)msg;
    if (msg && msg->cbSize >= sizeof(*m)) {
        self.cbObject = m->objcb.value;
        self.cbContext = m->ctxcb.value;
    }
    _headless = getenv("WMC_HEADLESS") != NULL;
    _clientW = 640;
    _clientH = 480;
    _title = @"Windows Media Center";
    _hwnd = wmc_window_adopt("eHome Render Window", NULL, sp_app_queue(self.cbContext));
    // Quit (Cmd+Q, the Dock) becomes a close request, like the close button.
    __weak SpFormWindow *weakSelf = self;
    [NSNotificationCenter.defaultCenter addObserverForName:@"WmcQuitRequested" object:nil queue:nil usingBlock:^(NSNotification *note) {
        SpFormWindow *me = weakSelf;
        if (!me || me->_destroyed) return;
        wmc_threadq_closing();
        [me simple:SpMsg_FormWindowCallback_OnCloseRequested];
        ((NSMutableDictionary *)note.object)[@"handled"] = @YES;
    }];

    struct Sp_LocalFormWindowCallback_OnWindowCreated created = {0};
    created.size = sizeof(created);
    created.msgid = SpMsg_FormWindowCallback_OnWindowCreated;
    created.idObjectSubject.value = self.cbObject;
    created.target.value = self.handle;
    memcpy(&created.m_hWnd, &_hwnd, sizeof(_hwnd));
    [self.context sendCallback:&created toContext:self.cbContext];
    [self simple:SpMsg_FormWindowCallback_OnLoad];

    if (getenv("WMC_INPUT")) [self runScript:@(getenv("WMC_INPUT"))];
    if (getenv("WMC_STEPS")) [self runSteps:script_commands(@(getenv("WMC_STEPS"))) at:0];

    // A series of offscreen frames at a fixed interval, for looking at motion
    // without recording the screen: WMC_SERIES=<folder>, WMC_SERIES_EVERY,
    // WMC_SERIES_COUNT.
    const char *series = getenv("WMC_SERIES");
    if (series && *series) {
        double every = getenv("WMC_SERIES_EVERY") ? atof(getenv("WMC_SERIES_EVERY")) : 0.25;
        int count = getenv("WMC_SERIES_COUNT") ? atoi(getenv("WMC_SERIES_COUNT")) : 40;
        NSString *folder = @(series);
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        __block int index = 0;
        CFTimeInterval began = CACurrentMediaTime();
        NSTimer *timer = [NSTimer timerWithTimeInterval:every repeats:YES block:^(NSTimer *t) {
            // (logged before drawing, so that the line's own time is the time
            // the frame shows: the timer is not exact, and motion is measured
            // against these)
            WLOG("series", "frame %d at %.4f s", index, CACurrentMediaTime() - began);
            sp_animation_tick();
            NSString *path = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"frame_%03d.png", index]];
            [[SpRenderer shared] snapshot:self width:self->_clientW height:self->_clientH toPath:path];
            if (++index >= count) {
                [t invalidate];
                wmc_threadq_closing(); [self simple:SpMsg_FormWindowCallback_OnCloseRequested];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    exit(0);
                });
            }
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    }

    const char *snapshot = getenv("WMC_SNAPSHOT");
    if (snapshot && *snapshot) {
        double after = getenv("WMC_SNAPSHOT_AFTER") ? atof(getenv("WMC_SNAPSHOT_AFTER")) : 3.0;
        NSString *path = @(snapshot);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            sp_animation_tick();
            [[SpRenderer shared] snapshot:self width:self->_clientW height:self->_clientH toPath:path];
            if (getenv("WMC_SNAPSHOT_EXIT")) {
                wmc_threadq_closing(); [self simple:SpMsg_FormWindowCallback_OnCloseRequested];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    exit(0);
                });
            }
        });
    }
}

- (void)simple:(uint32_t)msgid {
    struct Sp_LocalFormWindowCallback_OnLoad cb = {0};
    cb.size = sizeof(cb);
    cb.msgid = msgid;
    cb.idObjectSubject.value = self.cbObject;
    cb.target.value = self.handle;
    [self.context sendCallback:&cb toContext:self.cbContext];
}

- (CGFloat)scale {
    return _window ? _window.backingScaleFactor : 1.0;
}

- (void)sendState:(uint32_t)changed {
    struct {
        struct Sp_LocalFormWindowCallback_OnStateChange head;
        SpFormState state;
    } __attribute__((packed)) cb;
    memset(&cb, 0, sizeof(cb));
    cb.head.size = sizeof(cb);
    cb.head.msgid = SpMsg_FormWindowCallback_OnStateChange;
    cb.head.idObjectSubject.value = self.cbObject;
    cb.head.target.value = self.handle;
    cb.head.stateInfo.value = (uint32_t)sizeof(cb.head) | ((uint32_t)sizeof(cb.state) << 16);
    cb.state.cbSize = sizeof(cb.state);
    cb.state.uRecentlyChanged = changed;
    cb.state.uCurrentMode = _mode;
    cb.state.uActivation = (_headless || _window.isKeyWindow) ? 1 : 0;
    cb.state.fVisible = _visible;
    cb.state.cx = _clientW;
    cb.state.cy = _clientH;
    cb.state.left = _posX;
    cb.state.top = _posY;
    cb.state.right = _posX + _clientW;
    cb.state.bottom = _posY + _clientH;
    cb.state.idDisplay = CGMainDisplayID();
    cb.state.cSpanningMonitors = 1;
    [self.context sendCallback:&cb toContext:self.cbContext];
}

- (void)ensureWindow {
    if (_window || _headless) return;
    CGFloat scale = NSScreen.mainScreen.backingScaleFactor ?: 1;
    NSRect content = NSMakeRect(0, 0, _clientW / scale, _clientH / scale);
    _window = [[NSWindow alloc] initWithContentRect:content
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = _title;
    _window.delegate = self;
    _window.releasedWhenClosed = NO;
    _window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    _view = [[SpFormView alloc] initWithFrame:content];
    _view.owner = self;
    _window.contentView = _view;
    _window.acceptsMouseMovedEvents = YES;
    [_window makeFirstResponder:_view];
    [_window center];
    // The screen's own refresh where macOS has it for windows (14 and later);
    // a timer before that. (The #if lets an older SDK, as on macOS 11 with
    // its own Command Line Tools, compile this at all.)
#if defined(__MAC_14_0) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_14_0
    if (@available(macOS 14.0, *)) {
        CADisplayLink *link = [_view displayLinkWithTarget:_view selector:@selector(tick:)];
        [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        _displayLink = link;
        return;
    }
#endif
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 target:_view selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (void)drawIfNeeded {
    if (!_window || !_visible) return;
    sp_animation_tick();
    uint64_t gen = sp_scene_generation();
    if (gen == _drawnGeneration) return;
    CAMetalLayer *layer = (CAMetalLayer *)_view.layer;
    CGSize px = [_view convertSizeToBacking:_view.bounds.size];
    if (px.width < 1 || px.height < 1) return;
    if (!CGSizeEqualToSize(layer.drawableSize, px)) layer.drawableSize = px;
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return;
    _drawnGeneration = gen;
    id<MTLCommandBuffer> cb = [[SpRenderer shared].queue commandBuffer];
    [[SpRenderer shared] render:self target:drawable.texture commandBuffer:cb];
    [cb presentDrawable:drawable];
    [cb commit];
}

// ---- focus ---------------------------------------------------------------------

- (void)sendFocus:(BOOL)focused {
    struct Sp_LocalFormWindowCallback_OnSetFocus cb;
    memset(&cb, 0, sizeof(cb));
    cb.size = sizeof(cb);
    cb.msgid = SpMsg_FormWindowCallback_OnSetFocus;
    cb.idObjectSubject.value = self.cbObject;
    cb.target.value = self.handle;
    cb.focused = focused ? 1 : 0;
    [self.context sendCallback:&cb toContext:self.cbContext];
}

// ---- keyboard ------------------------------------------------------------------

// Mac virtual key codes to Windows virtual-key codes, for the keys that have
// no character of their own.
static int vk_for_mac_key(unsigned short keyCode) {
    switch (keyCode) {
        case 0x24: case 0x4C: return 0x0D;   // Return, keypad Enter
        case 0x30: return 0x09;              // Tab
        case 0x31: return 0x20;              // Space
        case 0x33: return 0x08;              // Delete (backspace): Media Center's "Back"
        case 0x35: return 0x1B;              // Escape
        case 0x75: return 0x2E;              // Forward delete
        case 0x7B: return 0x25;              // Left
        case 0x7E: return 0x26;              // Up
        case 0x7C: return 0x27;              // Right
        case 0x7D: return 0x28;              // Down
        case 0x73: return 0x24;              // Home
        case 0x77: return 0x23;              // End
        case 0x74: return 0x21;              // Page Up
        case 0x79: return 0x22;              // Page Down
        case 0x7A: return 0x70; case 0x78: return 0x71; case 0x63: return 0x72; case 0x76: return 0x73;   // F1-F4
        case 0x60: return 0x74; case 0x61: return 0x75; case 0x62: return 0x76; case 0x64: return 0x77;   // F5-F8
        case 0x65: return 0x78; case 0x6D: return 0x79; case 0x67: return 0x7A; case 0x6F: return 0x7B;   // F9-F12
    }
    return 0;
}

static uint32_t modifiers_for_flags(NSEventModifierFlags flags) {
    uint32_t m = 0;
    if (flags & NSEventModifierFlagControl) m |= SpModControl;
    if (flags & NSEventModifierFlagShift) m |= SpModShift;
    if (flags & NSEventModifierFlagOption) m |= SpModAlt;
    return m;
}

- (void)sendKey:(int)vk message:(uint32_t)message repeat:(int)repeat modifiers:(uint32_t)modifiers {
    SpInputRouter *router = _inputRouter;
    if (!router.cbObject) return;
    struct {
        struct Sp_LocalInputCallback_OnInput head;
        SpKeyboardInput key;
    } __attribute__((packed)) cb;
    memset(&cb, 0, sizeof(cb));
    cb.head.size = sizeof(cb);
    cb.head.msgid = SpMsg_InputCallback_OnInput;
    cb.head.idObjectSubject.value = router.cbObject;
    cb.head.target.value = router.handle;
    cb.head.inputInfo.value = (uint32_t)sizeof(cb.head) | ((uint32_t)sizeof(cb.key) << 16);
    cb.key.cbSize = sizeof(cb.key);
    cb.key.uCode = 1;
    cb.key.vk = vk;
    cb.key.uiMsg = message + ((modifiers & SpModAlt) ? 3 : 0);
    cb.key.cRep = repeat > 0 ? repeat : 1;
    cb.key.dwState = modifiers;
    WLOG("input", "key vk %#x message %u modifiers %#x", vk, cb.key.uiMsg, modifiers);
    [self.context sendCallback:&cb toContext:router.cbContext];
}

- (void)keyEvent:(NSEvent *)event down:(BOOL)down {
    uint32_t mods = modifiers_for_flags(event.modifierFlags);
    int vk = vk_for_mac_key(event.keyCode);
    NSString *plain = event.charactersIgnoringModifiers;
    if (!vk && plain.length) {
        unichar c = [plain.uppercaseString characterAtIndex:0];
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) vk = c;
    }
    if (vk) [self sendKey:vk message:down ? 0 : 1 repeat:1 modifiers:mods];
    // Typed characters follow the key-down, as WM_CHAR follows WM_KEYDOWN.
    if (down && !(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl))) {
        NSString *typed = event.characters;
        for (NSUInteger i = 0; i < typed.length; i++) {
            unichar c = [typed characterAtIndex:i];
            if (c == 0x7F) c = 0x08;
            if (c >= 0xF700 && c <= 0xF8FF) continue;   // function-key code points
            [self sendKey:c message:2 repeat:1 modifiers:mods];
        }
    }
}

- (void)modifiersChanged:(NSEvent *)event {
    static NSEventModifierFlags previous;
    NSEventModifierFlags now = event.modifierFlags;
    struct { NSEventModifierFlags flag; int vk; } keys[] = {
        { NSEventModifierFlagShift, 0x10 }, { NSEventModifierFlagControl, 0x11 }, { NSEventModifierFlagOption, 0x12 },
    };
    for (int i = 0; i < 3; i++) {
        BOOL was = (previous & keys[i].flag) != 0, is = (now & keys[i].flag) != 0;
        if (was != is) [self sendKey:keys[i].vk message:is ? 0 : 1 repeat:1 modifiers:modifiers_for_flags(now)];
    }
    previous = now;
}

// ---- mouse ----------------------------------------------------------------------

BOOL sp_hit_test(SpWindow *window, float x, float y, float width, float height, uint32_t traverse, uint32_t hit,
                 uint32_t result, uint32_t *subject, float subjectPoint[2], uint32_t *natural, float naturalPoint[2]);

- (void)sendMouse:(uint32_t)message
                x:(float)x
                y:(float)y
           button:(uint32_t)button
        modifiers:(uint32_t)modifiers
            wheel:(int)wheel {
    SpInputRouter *router = _inputRouter;
    if (!router.cbObject) return;
    struct {
        struct Sp_LocalInputCallback_OnInput head;
        SpMouseInput mouse;
    } __attribute__((packed)) cb;
    memset(&cb, 0, sizeof(cb));
    cb.head.size = sizeof(cb);
    cb.head.msgid = SpMsg_InputCallback_OnInput;
    cb.head.idObjectSubject.value = router.cbObject;
    cb.head.target.value = router.handle;
    cb.head.inputInfo.value = (uint32_t)sizeof(cb.head) | ((uint32_t)sizeof(cb.mouse) << 16);
    cb.mouse.cbSize = sizeof(cb.mouse);
    cb.mouse.ownerMessage = 4;
    cb.mouse.uMessage = message;
    cb.mouse.ptPhysicalX = (int32_t)x;
    cb.mouse.ptPhysicalY = (int32_t)y;
    cb.mouse.nModifiers = modifiers;
    cb.mouse.bButton = button;
    cb.mouse.wheelDelta = (int16_t)wheel;
    if (message != SpWmMouseLeave) {
        float sp[2] = { 0, 0 }, np[2] = { 0, 0 };
        uint32_t subject = 0, natural = 0;
        sp_hit_test(self, x, y, _clientW, _clientH, _hitTraverse, _hitHit, _hitResult, &subject, sp, &natural, np);
        cb.mouse.dwSubject = subject;
        cb.mouse.ptPositionX = (int32_t)sp[0];
        cb.mouse.ptPositionY = (int32_t)sp[1];
        cb.mouse.dwNatural = natural;
        cb.mouse.ptNaturalX = (int32_t)np[0];
        cb.mouse.ptNaturalY = (int32_t)np[1];
    }
    if (message != SpWmMouseMove) {
        WLOG("input", "mouse message %#x at %g,%g subject %#x natural %#x", message, x, y, cb.mouse.dwSubject,
             cb.mouse.dwNatural);
    }
    [self.context sendCallback:&cb toContext:router.cbContext];
}

- (void)mouseEvent:(NSEvent *)event message:(uint32_t)message button:(uint32_t)button {
    if (!_view) return;
    NSPoint p = [_view convertPoint:event.locationInWindow fromView:nil];
    CGFloat scale = [self scale];
    float x = (float)(p.x * scale), y = (float)((_view.bounds.size.height - p.y) * scale);
    uint32_t mods = modifiers_for_flags(event.modifierFlags);
    // Which buttons are down, as of this event: the event's own button
    // counts from its "down" until its "up".
    NSUInteger buttons = NSEvent.pressedMouseButtons;
    if (message == SpWmLButtonDown) buttons |= 1; else if (message == SpWmLButtonUp) buttons &= ~(NSUInteger)1;
    if (message == SpWmRButtonDown) buttons |= 2; else if (message == SpWmRButtonUp) buttons &= ~(NSUInteger)2;
    if (message == SpWmMButtonDown) buttons |= 4; else if (message == SpWmMButtonUp) buttons &= ~(NSUInteger)4;
    if (buttons & 1) mods |= SpModLeftMouse;
    if (buttons & 2) mods |= SpModRightMouse;
    if (buttons & 4) mods |= SpModMiddleMouse;
    int wheel = 0;
    if (message == SpWmMouseWheel) {
        // One wheel notch is 120 on Windows; trackpads send fine-grained deltas.
        _wheelRemainder += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 12.0 : event.scrollingDeltaY * 120.0;
        wheel = (int)(_wheelRemainder / 120.0) * 120;
        if (wheel == 0) return;
        _wheelRemainder -= wheel;
    }
    [self sendMouse:message x:x y:y button:button modifiers:mods wheel:wheel];
}

// ---- scripted input ---------------------------------------------------------------
// WMC_INPUT="2.0 key down; 3.0 key right; 4 key enter; 5 move 400 300; 6 click 400 300"
// plays input at the given seconds after the window is created: for tests.
//
// WMC_STEPS runs commands one after another instead, waiting for Media Center
// rather than the clock: the same input without the time, and
//   wait S                  S seconds
//   settle [MAX [QUIET]]    until Media Center is idle: no animation playing,
//                           its UI thread done with the input it was given,
//                           and the scene unchanged for QUIET seconds (0.3);
//                           at most MAX seconds (4: a playing video never settles)
//   ready                   the same at start-up, once the window is shown and
//                           something has been drawn (quiet 1 s, at most 60 s)
//   snap PATH               an offscreen frame
//   quit                    ask Media Center to close, as the close button does
//   exit                    end at once (nothing saved: for checks)

static NSArray<NSArray<NSString *> *> *script_commands(NSString *script) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *raw in [script componentsSeparatedByString:@";"]) {
        NSArray<NSString *> *parts = [[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
            componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (parts.count) [out addObject:parts];
    }
    return out;
}

- (void)runScript:(NSString *)script {
    for (NSArray<NSString *> *parts in script_commands(script)) {
        if (parts.count < 3) continue;
        double at = parts[0].doubleValue;
        NSArray<NSString *> *command = [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self perform:command];
        });
    }
}

// One input command: "key down", "char x", "move 400 300", "click 400 300",
// "resize 800 600", "nskey 36", "nsmove 10 10", "nsclick 10 10".
- (void)perform:(NSArray<NSString *> *)parts {
    if (parts.count < 2) return;
    NSDictionary<NSString *, NSNumber *> *names = @{
        @"left" : @0x25, @"up" : @0x26, @"right" : @0x27, @"down" : @0x28, @"enter" : @0x0D, @"back" : @0x08,
        @"escape" : @0x1B, @"tab" : @0x09, @"space" : @0x20, @"home" : @0x24, @"end" : @0x23,
        @"pageup" : @0x21, @"pagedown" : @0x22, @"apps" : @0x5D,   // (apps: the context-menu key)
        @"f1" : @0x70, @"f2" : @0x71, @"f3" : @0x72, @"f4" : @0x73, @"f5" : @0x74, @"f6" : @0x75,
        @"f7" : @0x76, @"f8" : @0x77, @"f9" : @0x78, @"f10" : @0x79, @"f11" : @0x7A, @"f12" : @0x7B,
    };
    NSString *kind = parts[0];
    if ([kind isEqualToString:@"resize"] && parts.count >= 3) {
        // "resize W H": the window's content becomes W by H points.
        int w = parts[1].intValue, h = parts[2].intValue;
        if (self->_window) {
            [self->_window setContentSize:NSMakeSize(w, h)];
        } else {
            self->_clientW = w;
            self->_clientH = h;
            [self sendState:0];
            sp_scene_invalidate();
        }
        return;
    }
    if ([kind isEqualToString:@"nskey"] && self->_window) {
        // A real key event through the window, to exercise the Mac
        // event path (parts[1] is a Mac virtual key code).
        unsigned short code = (unsigned short)strtol(parts[1].UTF8String, NULL, 0);
        for (int down = 1; down >= 0; down--) {
            NSEvent *e = [NSEvent keyEventWithType:down ? NSEventTypeKeyDown : NSEventTypeKeyUp
                                          location:NSZeroPoint
                                     modifierFlags:0
                                         timestamp:NSProcessInfo.processInfo.systemUptime
                                      windowNumber:self->_window.windowNumber
                                           context:nil
                                        characters:@""
                       charactersIgnoringModifiers:@""
                                         isARepeat:NO
                                           keyCode:code];
            [self->_window sendEvent:e];
        }
    } else if (([kind isEqualToString:@"nsmove"] || [kind isEqualToString:@"nsclick"]) && self->_window &&
               parts.count >= 3) {
        // Real mouse events; x and y are view points from the top left.
        NSPoint inView = NSMakePoint(parts[1].doubleValue, self->_view.bounds.size.height - parts[2].doubleValue);
        NSPoint inWindow = [self->_view convertPoint:inView toView:nil];
        NSArray<NSNumber *> *types = [kind isEqualToString:@"nsclick"]
            ? @[ @(NSEventTypeMouseMoved), @(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp) ]
            : @[ @(NSEventTypeMouseMoved) ];
        for (NSNumber *type in types) {
            NSEvent *e = [NSEvent mouseEventWithType:(NSEventType)type.unsignedIntegerValue
                                            location:inWindow
                                       modifierFlags:0
                                           timestamp:NSProcessInfo.processInfo.systemUptime
                                        windowNumber:self->_window.windowNumber
                                             context:nil
                                         eventNumber:0
                                          clickCount:1
                                            pressure:1];
            [self->_window sendEvent:e];
        }
    } else if ([kind isEqualToString:@"char"]) {
        // "char x": a typed character, as a keyboard sends it (key
        // down, the character, key up).
        unichar c = [parts[1] characterAtIndex:0];
        int vk = toupper(c);
        [self sendKey:vk message:0 repeat:1 modifiers:0];
        [self sendKey:c message:2 repeat:1 modifiers:0];
        [self sendKey:vk message:1 repeat:1 modifiers:0];
    } else if ([kind isEqualToString:@"key"]) {
        // "key ctrl+shift+d": modifiers first (Ctrl 1, Shift 2, Alt 4), then the key.
        NSArray<NSString *> *chord = [parts[1].lowercaseString componentsSeparatedByString:@"+"];
        uint32_t mods = 0;
        for (NSUInteger i = 0; i + 1 < chord.count; i++) {
            if ([chord[i] isEqualToString:@"ctrl"]) mods |= 1;
            else if ([chord[i] isEqualToString:@"shift"]) mods |= 2;
            else if ([chord[i] isEqualToString:@"alt"]) mods |= 4;
        }
        NSString *name = chord.lastObject;
        int vk = names[name] ? names[name].intValue : (name.length == 1 ? toupper([name characterAtIndex:0]) : 0);
        if (!vk) return;
        static const int modifierKeys[3] = { 0x11, 0x10, 0x12 };   // VK_CONTROL, VK_SHIFT, VK_MENU
        for (int i = 0; i < 3; i++)
            if (mods & (1u << i)) [self sendKey:modifierKeys[i] message:0 repeat:1 modifiers:mods];
        [self sendKey:vk message:0 repeat:1 modifiers:mods];
        [self sendKey:vk message:1 repeat:1 modifiers:mods];
        for (int i = 2; i >= 0; i--)
            if (mods & (1u << i)) [self sendKey:modifierKeys[i] message:1 repeat:1 modifiers:0];
    } else if (parts.count >= 3) {
        float x = parts[1].floatValue, y = parts[2].floatValue;
        [self sendMouse:SpWmMouseMove x:x y:y button:0 modifiers:0 wheel:0];
        if ([kind isEqualToString:@"click"]) {
            [self sendMouse:SpWmLButtonDown x:x y:y button:1 modifiers:SpModLeftMouse wheel:0];
            [self sendMouse:SpWmLButtonUp x:x y:y button:1 modifiers:0 wheel:0];
        }
    }
}

- (void)runSteps:(NSArray<NSArray<NSString *> *> *)steps at:(NSUInteger)i {
    if (i >= steps.count || _destroyed) return;
    NSArray<NSString *> *step = steps[i];
    NSString *kind = step[0];
    void (^next)(void) = ^{ [self runSteps:steps at:i + 1]; };
    if ([kind isEqualToString:@"wait"]) {
        double seconds = step.count > 1 ? step[1].doubleValue : 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([kind isEqualToString:@"settle"] || [kind isEqualToString:@"ready"]) {
        BOOL ready = [kind isEqualToString:@"ready"];
        double max = step.count > 1 ? step[1].doubleValue : (ready ? 60 : 4);
        double quiet = step.count > 2 ? step[2].doubleValue : (ready ? 1.0 : 0.3);
        CFTimeInterval now = CACurrentMediaTime();
        uint64_t gen = sp_scene_content_generation();
        [self settleBegan:now changed:now generation:gen first:gen max:max quiet:quiet ready:ready then:next];
    } else if ([kind isEqualToString:@"snap"] && step.count > 1) {
        NSString *path = [[step subarrayWithRange:NSMakeRange(1, step.count - 1)] componentsJoinedByString:@" "];
        sp_animation_tick();
        [[SpRenderer shared] snapshot:self width:_clientW height:_clientH toPath:path];
        WLOG("steps", "snap %s", path.UTF8String);
        next();
    } else if ([kind isEqualToString:@"exit"]) {
        WLOG("steps", "exit");
        exit(0);
    } else if ([kind isEqualToString:@"quit"]) {
        WLOG("steps", "quit");
        wmc_threadq_closing();
        [self simple:SpMsg_FormWindowCallback_OnCloseRequested];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    } else {
        [self perform:step];
        next();
    }
}

- (void)settleBegan:(CFTimeInterval)began changed:(CFTimeInterval)changed generation:(uint64_t)gen
              first:(uint64_t)first max:(double)max quiet:(double)quiet ready:(BOOL)ready
               then:(void (^)(void))next {
    CFTimeInterval now = CACurrentMediaTime();
    uint64_t g = sp_scene_content_generation();
    BOOL started = !ready || (_visible && g != first);
    BOOL animating = sp_animation_settling(), busy = wmc_threadq_ui_busy();
    if (g != gen || !started || animating || busy) {
        changed = now;
        gen = g;
    }
    if (now - changed >= quiet || now - began >= max) {
        WLOG("steps", "%s after %.2f s%s", ready ? "ready" : "settled", now - began,
             now - changed >= quiet ? ""
             : !started ? " (stopped waiting: nothing drawn)"
             : animating ? " (stopped waiting: animating)"
             : busy ? " (stopped waiting: UI thread busy)" : " (stopped waiting: scene changing)");
        next();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self settleBegan:began changed:changed generation:gen first:first max:max quiet:quiet ready:ready then:next];
    });
}

// ---- NSWindowDelegate ----------------------------------------------------------

- (void)windowDidResize:(NSNotification *)note {
    CGSize px = [_view convertSizeToBacking:_view.bounds.size];
    if ((int)px.width == _clientW && (int)px.height == _clientH) return;
    _clientW = (int)px.width;
    _clientH = (int)px.height;
    [self sendState:0];
    sp_scene_invalidate();
}

// Window modes. Media Center's maximised window is its full screen (on
// Windows it covers the taskbar too), so here it is the Mac's full screen;
// minimised is the Dock. At start it asks for the mode it saved when it last
// quit, and on quitting it saves the mode it last heard of, so a change made
// with the Mac's own controls is reported back. Runs that must leave the
// user's screen alone (offscreen, or shown without the focus) only echo the
// mode asked for, so they never change what it saved.

- (void)applyMode {
    if (!_window || !_visible || _destroyed || getenv("WMC_NO_ACTIVATE")) return;
    if (_changing) { _modeQueued = YES; return; }
    // After the current event: a window just put on screen ignores a
    // full-screen request.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *w = self->_window;
        if (!w || self->_destroyed) return;
        if (self->_changing) { self->_modeQueued = YES; return; }
        BOOL full = (w.styleMask & NSWindowStyleMaskFullScreen) != 0;
        switch (self->_mode) {
            case 2:
                if (w.miniaturized) [w deminiaturize:nil];
                if (!full) [w toggleFullScreen:nil];
                break;
            case 1:   // a full-screen window leaves full screen first (see fullScreenChanged)
                if (full) [w toggleFullScreen:nil];
                else if (!w.miniaturized) [w miniaturize:nil];
                break;
            default:
                if (w.miniaturized) [w deminiaturize:nil];
                if (full) [w toggleFullScreen:nil];
        }
    });
}

// A change Media Center did not ask for ("unplanned", 0x100).
- (void)reportMode:(uint32_t)mode {
    if (mode == _mode) return;
    WLOG("win", "window mode changed on the Mac: %u", mode);
    _mode = mode;
    [self sendState:1 | 0x100];
}

- (void)fullScreenChanged {
    _changing = NO;
    BOOL full = (_window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    // Media Center asked for another mode meanwhile, or to be minimised,
    // which a full-screen window can do only once it has left full screen.
    if (_modeQueued || (_mode == 1 && !full)) {
        _modeQueued = NO;
        [self applyMode];
        return;
    }
    [self reportMode:full ? 2 : 0];
}

- (void)windowWillEnterFullScreen:(NSNotification *)note { _changing = YES; }
- (void)windowWillExitFullScreen:(NSNotification *)note { _changing = YES; }
- (void)windowDidEnterFullScreen:(NSNotification *)note { [self fullScreenChanged]; }
- (void)windowDidExitFullScreen:(NSNotification *)note { [self fullScreenChanged]; }
- (void)windowDidFailToEnterFullScreen:(NSWindow *)window { [self fullScreenChanged]; }
- (void)windowDidFailToExitFullScreen:(NSWindow *)window { [self fullScreenChanged]; }
- (void)windowDidMiniaturize:(NSNotification *)note { [self reportMode:1]; }
- (void)windowDidDeminiaturize:(NSNotification *)note {
    [self reportMode:(_window.styleMask & NSWindowStyleMaskFullScreen) ? 2 : 0];
}

- (void)windowDidBecomeKey:(NSNotification *)note {
    [self sendState:2];
    [self sendFocus:YES];
}

- (void)windowDidResignKey:(NSNotification *)note {
    [self sendState:2];
    [self sendFocus:NO];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    wmc_threadq_closing(); [self simple:SpMsg_FormWindowCallback_OnCloseRequested];
    return NO;   // the framework closes it when it has shut down
}

// ---- messages -------------------------------------------------------------------

- (void)spDestroy {
    if (_destroyed) return;
    _destroyed = YES;
    [_displayLink invalidate];
    [_timer invalidate];
    [_window orderOut:nil];
    _window.delegate = nil;
    _window = nil;
}

- (void)spMessage:(const SpMessage *)msg {
    if (msg->nMsg <= SpMsg_FormWindow_SetRoot && [self windowMessage:msg]) return;
    switch (msg->nMsg) {
        case SpMsg_FormWindow_SetVisible: {
            _visible = ((const struct Sp_RemoteFormWindow_SetVisible *)msg)->fVisible != 0;
            if (_visible) {
                [self ensureWindow];
                if (_headless) {
                    // No window offscreen, and never take the focus from the
                    // user's app (activating would, window or not).
                } else if (getenv("WMC_NO_ACTIVATE")) {
                    [_window orderFrontRegardless];   // visible, but the user keeps their focus
                } else {
                    [_window makeKeyAndOrderFront:nil];
                    [NSApp activateIgnoringOtherApps:YES];
                }
                if (_window) WLOG("sp", "window on screen: id %ld", (long)_window.windowNumber);
            } else {
                [_window orderOut:nil];
            }
            [self sendState:4 | 2];
            [self applyMode];
            // With no key window to report it (offscreen, or shown without
            // activating), tell the framework it has the focus, as it would
            // on a normal start.
            if (_visible && !_focusSent && (!_window || !_window.isKeyWindow)) {
                _focusSent = YES;
                [self sendFocus:YES];
            }
            break;
        }
        case SpMsg_FormWindow_SetSize: {
            const struct Sp_RemoteFormWindow_SetSize *m = (const void *)msg;
            _clientW = m->sizeClientPxl.m_width;
            _clientH = m->sizeClientPxl.m_height;
            if (_window) [_window setContentSize:NSMakeSize(_clientW / [self scale], _clientH / [self scale])];
            [self sendState:0];
            break;
        }
        case SpMsg_FormWindow_SetPosition: {
            const struct Sp_RemoteFormWindow_SetPosition *m = (const void *)msg;
            _posX = m->ptScreenPxl.m_x;
            _posY = m->ptScreenPxl.m_y;
            [self sendState:0];
            break;
        }
        case SpMsg_FormWindow_SetText: {
            const struct Sp_RemoteFormWindow_SetText *m = (const void *)msg;
            _title = sp_blob_string(msg, m->text.value);
            _window.title = _title;
            break;
        }
        case SpMsg_FormWindow_SetMode: {
            _mode = ((const struct Sp_RemoteFormWindow_SetMode *)msg)->uMode;
            WLOG("win", "Media Center asks for window mode %u", _mode);
            [self sendState:1];
            [self applyMode];
            break;
        }
        case SpMsg_FormWindow_Destroy:
            [self spDestroy];
            [self simple:SpMsg_FormWindowCallback_OnWindowDestroyed];
            break;
        case SpMsg_FormWindow_BringToTop:
        case SpMsg_FormWindow_SetForeground:
        case SpMsg_FormWindow_TakeFocus:
            if (_window && _visible && !getenv("WMC_NO_ACTIVATE")) [_window makeKeyAndOrderFront:nil];
            break;
        case SpMsg_FormWindow_SetHitMasks: {
            const struct Sp_RemoteFormWindow_SetHitMasks *m = (const void *)msg;
            _hitTraverse = m->uMaskTraverse;
            _hitHit = m->uMaskHit;
            _hitResult = m->uMaskResult;
            break;
        }
        case SpMsg_FormWindow_CreateRootContainer:
        case SpMsg_FormWindow_SetIcon:
        case SpMsg_FormWindow_SetMaxResizeWidth:
        case SpMsg_FormWindow_SetMinResizeWidth:
        case SpMsg_FormWindow_EnableShellShutdownHook:
        case SpMsg_FormWindow_UpdateForegroundLockState:
        case SpMsg_FormWindow_SetAppNotifyWindow:
        case SpMsg_FormWindow_SetCapture:
        case SpMsg_FormWindow_ForceMouseIdle:
        case SpMsg_FormWindow_TemporarilyExitExclusiveMode:
        case SpMsg_FormWindow_Restore:
        case SpMsg_FormWindow_SetCursors:
        case SpMsg_FormWindow_SetStyles:
        case SpMsg_FormWindow_SetMouseIdleOptions:
        case SpMsg_FormWindow_SetOptions:
            break;
        default:
            [self spUnhandled:msg];
    }
}

@end

// ------------------------------------------------------------------ InputRouter

@implementation SpInputRouter
- (void)spConstruct:(const SpMessage *)msg {
    const struct Sp_RemoteInputRouter_Create *m = (const void *)msg;
    if (msg && msg->cbSize >= sizeof(*m)) {
        self.cbObject = m->objic.value;
        self.cbContext = m->ctxic.value;
    }
}
- (void)spMessage:(const SpMessage *)msg {
    if (msg->nMsg == SpMsg_InputRouter_RegisterWithInputSource) {
        const struct Sp_RemoteInputRouter_RegisterWithInputSource *m = (const void *)msg;
        id source = [self.context objectForHandle:m->idSource.value];
        if ([source isKindOfClass:[SpFormWindow class]]) ((SpFormWindow *)source).inputRouter = self;
    }
}
@end

__attribute__((constructor)) static void register_desktop_classes(void) {
    sp_register_class(@"Splash::Desktop::DesktopManager", [SpDesktopManager class]);
    sp_register_class(@"Splash::Desktop::FormWindow", [SpFormWindow class]);
    sp_register_class(@"Splash::Desktop::InputRouter", [SpInputRouter class]);
}
