#import <Cocoa/Cocoa.h>
// wincap SECONDS : a 480x320 window filled with one colour (sRGB 0.20 0.60 0.90), redrawn every frame so WindowServer keeps
// compositing it. Prints "wid <window number>" once it is on screen; `screencapture -x -l <wid>` must then show that colour
// (NullMoth 79f47d0: window captures read the window's surface while WindowServer is still drawing it - black before the fix).
@interface Fill : NSView @end
@implementation Fill
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)r { [[NSColor colorWithSRGBRed:0.20 green:0.60 blue:0.90 alpha:1] setFill]; NSRectFill(r);
  static int k; [[NSColor colorWithSRGBRed:0.20 green:0.60 blue:0.90 alpha:1] setFill]; NSRectFill(NSMakeRect(k++ % 2, 0, 1, 1)); }
@end
int main(int argc, char **argv) { @autoreleasepool {
  const double secs = argc > 1 ? atof(argv[1]) : 6;
  [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 480, 320) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  w.title = @"wincap"; Fill *v = [[Fill alloc] initWithFrame:NSMakeRect(0, 0, 480, 320)]; w.contentView = v;
  [w makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
  [NSTimer scheduledTimerWithTimeInterval:1 / 120.0 repeats:YES block:^(NSTimer *t) { [v setNeedsDisplay:YES]; }];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ printf("wid %ld\n", (long)w.windowNumber); fflush(stdout); });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
  [NSApp run]; } return 0; }
