// The Mac main thread.
//
// AppKit must own the process's main thread, and so must everything the
// render engine does with windows and layers. The managed program therefore
// starts its real work on a second thread (the framework's "application"
// thread) and parks the main thread here.
#import <Cocoa/Cocoa.h>
#include "wmc.h"

static int s_exit_code;

@interface WmcAppDelegate : NSObject <NSApplicationDelegate>
@end

// Posted when the user asks to quit. A window that can shut Media Center
// down in an orderly way (so that it saves its settings) answers by setting
// `handled` in the notification's object.
NSString *const WmcQuitRequestedNotification = @"WmcQuitRequested";

@implementation WmcAppDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    NSMutableDictionary *answer = [NSMutableDictionary dictionary];
    [NSNotificationCenter.defaultCenter postNotificationName:WmcQuitRequestedNotification object:answer];
    if ([answer[@"handled"] boolValue]) {
        // Media Center closes its window and returns from its entry point,
        // which stops this run loop. If it has not done so soon, quit anyway.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
        return NSTerminateCancel;
    }
    return NSTerminateNow;
}
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return NO;
}
@end

static WmcAppDelegate *s_delegate;

static void build_menu(void) {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [bar addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Quit Media Center" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = bar;
}

// Runs AppKit until wmc_stop_main_loop. Returns the code given there.
WMC_API int wmc_run_main_loop(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        s_delegate = [WmcAppDelegate new];
        NSApp.delegate = s_delegate;
        // Offscreen runs are "prohibited" apps: macOS will not let them be
        // activated at all, so they can never take the focus from the user.
        [NSApp setActivationPolicy:getenv("WMC_HEADLESS") ? NSApplicationActivationPolicyProhibited
                                                         : NSApplicationActivationPolicyRegular];
        build_menu();
        [NSApp run];
    }
    return s_exit_code;
}

WMC_API void wmc_stop_main_loop(int exitCode) {
    s_exit_code = exitCode;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp stop:nil];
        // -stop: only takes effect after the next event.
        NSEvent *e = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                        location:NSZeroPoint
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:0
                                         context:nil
                                         subtype:0
                                           data1:0
                                           data2:0];
        [NSApp postEvent:e atStart:NO];
    });
}
