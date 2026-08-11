//
//  AppDelegate.mm
//  Mandelbulb3D
//
//  Builds the window and a minimal menu bar entirely in code -- there
//  is no MainMenu.xib/storyboard in this project, so this is the only
//  place the app's UI shell gets assembled.
//

#import "AppDelegate.h"
#import "ViewController.h"

@interface AppDelegate ()
@property (strong) NSWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildMenuBar];

    NSRect frame = NSMakeRect(0, 0, 1280, 800);
    NSUInteger styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

    self.window = [[NSWindow alloc] initWithContentRect:frame
                                               styleMask:styleMask
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    self.window.title = @"Mandelbulb 3D";
    self.window.minSize = NSMakeSize(760, 420); // room for the render view plus the fixed-width control panel
    self.window.contentViewController = [[ViewController alloc] init];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];

    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)buildMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appMenuItem];

    NSMenu *appMenu = [[NSMenu alloc] init];
    NSString *appName = [[NSProcessInfo processInfo] processName];

    [appMenu addItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
                        action:@selector(orderFrontStandardAboutPanel:)
                 keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
                        action:@selector(hide:)
                 keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Quit"
                        action:@selector(terminate:)
                 keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;

    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:windowMenuItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    windowMenuItem.submenu = windowMenu;
    NSApp.windowsMenu = windowMenu;

    NSApp.mainMenu = mainMenu;
}

@end
