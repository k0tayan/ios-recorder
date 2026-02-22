#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import "RecorderCore.h"
#import "FrameCapture.h"
#import "AudioCapture.h"
#import "ControlServer.h"

static ControlServer *controlServer = nil;

// Hook CAMetalLayer's nextDrawable to capture Metal frames
%hook CAMetalLayer

- (id<CAMetalDrawable>)nextDrawable {
    id<CAMetalDrawable> drawable = %orig;
    if (drawable) {
        [[FrameCapture shared] captureDrawable:drawable];
    }
    return drawable;
}

%end

%ctor {
    @autoreleasepool {
        NSLog(@"[Recorder] ========================================");
        NSLog(@"[Recorder] iOS App Recorder dylib loaded!");
        NSLog(@"[Recorder] ========================================");

        // Initialize RecorderCore singleton
        [RecorderCore shared];
        NSLog(@"[Recorder] RecorderCore initialized");

        // Initialize FrameCapture
        [FrameCapture shared];
        NSLog(@"[Recorder] FrameCapture initialized");

        // Initialize AudioCapture and install hooks
        AudioCapture *audioCapture = [AudioCapture shared];
        if ([audioCapture installHook]) {
            NSLog(@"[Recorder] AudioCapture hooks installed");
        } else {
            NSLog(@"[Recorder] WARNING: AudioCapture hook installation failed");
        }

        // Start ControlServer (use app sandbox tmp for sandbox compatibility)
        NSString *sockPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rec.sock"];
        controlServer = [[ControlServer alloc] initWithSocketPath:sockPath];
        if ([controlServer start]) {
            NSLog(@"[Recorder] ControlServer started on %@", sockPath);
        } else {
            NSLog(@"[Recorder] WARNING: ControlServer failed to start");
        }

        NSLog(@"[Recorder] Initialization complete. Send commands to %@", sockPath);
        NSLog(@"[Recorder] Commands: START, STOP, STATUS, SET fps=N, SET bitrate=N, SET resolution=WxH");
    }
}
