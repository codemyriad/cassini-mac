// SPDX-License-Identifier: GPL-3.0-or-later
// Infrastructure only. CoreGraphics' private virtual-display API is also used
// by Chromium's macOS display tests; qualify it again after host OS upgrades.
#import <Cocoa/Cocoa.h>
#include <unistd.h>
#import <CoreGraphics/CoreGraphics.h>

@protocol Descriptor
- (void)setName:(NSString *)name;
- (void)setQueue:(dispatch_queue_t)queue;
- (void)setMaxPixelsWide:(unsigned int)value;
- (void)setMaxPixelsHigh:(unsigned int)value;
- (void)setSizeInMillimeters:(CGSize)value;
- (void)setSerialNum:(unsigned int)value;
- (void)setSerialNumber:(unsigned int)value;
- (void)setVendorID:(unsigned int)value;
- (void)setProductID:(unsigned int)value;
@end
@protocol Mode
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@protocol Settings
- (void)setModes:(NSArray *)modes;
- (void)setHiDPI:(unsigned int)value;
@end
@protocol Display
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
@end

static id<Display> display;
static NSString *readyPath;
static void publish(CGDirectDisplayID changed, CGDisplayChangeSummaryFlags flags, void *context) {
    if (!display || !CGDisplayIsActive(display.displayID)) return;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display.displayID);
    if (!mode) return;
    NSDictionary *state = @{ @"displayId": @(display.displayID), @"width": @(CGDisplayModeGetWidth(mode)),
        @"height": @(CGDisplayModeGetHeight(mode)), @"pixelWidth": @(CGDisplayModeGetPixelWidth(mode)),
        @"pixelHeight": @(CGDisplayModeGetPixelHeight(mode)) };
    CGDisplayModeRelease(mode);
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:&error];
    if (!data || ![data writeToFile:readyPath options:NSDataWritingAtomic error:&error]) {
        NSLog(@"Display readiness write failed: %@", error); exit(1);
    }
    NSLog(@"Virtual display ready: %@", state);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2 || getuid() == 0) return 64;
        readyPath = [NSString stringWithUTF8String:argv[1]];
        [[NSFileManager defaultManager] removeItemAtPath:readyPath error:NULL];
        id<Descriptor> descriptor = [NSClassFromString(@"CGVirtualDisplayDescriptor") new];
        if (!descriptor) return 69;
        [descriptor setName:@"Cassini GUI CI"];
        [descriptor setQueue:dispatch_get_main_queue()];
        [descriptor setMaxPixelsWide:1920]; [descriptor setMaxPixelsHigh:1200];
        [descriptor setSizeInMillimeters:CGSizeMake(508, 317.5)];
        [descriptor setSerialNum:50301]; [descriptor setSerialNumber:50301];
        [descriptor setVendorID:505]; [descriptor setProductID:503];
        display = [(id<Display>)[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (!display) return 70;
        id<Settings> settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
        [settings setHiDPI:0];
        id small = [(id<Mode>)[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:1280 height:960 refreshRate:60];
        id large = [(id<Mode>)[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:1920 height:1200 refreshRate:60];
        if (!small || !large) return 69;
        [settings setModes:@[small, large]];
        CGDisplayRegisterReconfigurationCallback(publish, NULL);
        if (![display applySettings:settings]) return 71;
        publish(0, 0, NULL);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!CGDisplayIsActive(display.displayID)) { NSLog(@"No active virtual display before hang guard"); exit(72); }
        });
        [[NSRunLoop mainRunLoop] run];
    }
}
