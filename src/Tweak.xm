#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import "RecorderCore.h"
#import "FrameCapture.h"
#import "AudioCapture.h"
#import "ControlServer.h"

static ControlServer *controlServer = nil;

// addPresentedHandler: は drawable が画面に表示された瞬間に呼ばれるため、
// GPU レンダリング完了が保証され、遅延キャプチャが不要になる。
%hook CAMetalLayer

- (id<CAMetalDrawable>)nextDrawable {
    id<CAMetalDrawable> drawable = %orig;
    if (drawable) {
        // captureSize は常に更新 (録画開始前にも必要)
        id<MTLTexture> texture = drawable.texture;
        if (texture) {
            CGSize newSize = CGSizeMake(texture.width, texture.height);
            [FrameCapture shared].captureSize = newSize;
        }

        // drawable が画面に表示されたタイミングでキャプチャ
        [drawable addPresentedHandler:^(id<MTLDrawable> d) {
            [[FrameCapture shared] captureDrawable:(id<CAMetalDrawable>)d];
        }];
    }
    return drawable;
}

%end

%ctor {
    @autoreleasepool {
        NSLog(@"[Recorder] ========================================");
        NSLog(@"[Recorder] iOS App Recorder dylib loaded!");
        NSLog(@"[Recorder] ========================================");

        // RecorderCore シングルトン初期化
        [RecorderCore shared];
        NSLog(@"[Recorder] RecorderCore initialized");

        // FrameCapture 初期化
        [FrameCapture shared];
        NSLog(@"[Recorder] FrameCapture initialized");

        // AudioCapture 初期化 & フックのインストール
        AudioCapture *audioCapture = [AudioCapture shared];
        if ([audioCapture installHook]) {
            NSLog(@"[Recorder] AudioCapture hooks installed");
        } else {
            NSLog(@"[Recorder] WARNING: AudioCapture hook installation failed");
        }

        // TCP ControlServer 起動
        controlServer = [[ControlServer alloc] initWithPort:8190];
        if ([controlServer start]) {
            NSLog(@"[Recorder] ControlServer started on port 8190");
        } else {
            NSLog(@"[Recorder] WARNING: ControlServer failed to start");
        }

        NSLog(@"[Recorder] Initialization complete. Connect to port 8190");
        NSLog(@"[Recorder] Commands: START, STOP, STATUS, LIST, PULL, SET fps=N, SET bitrate=N, SET resolution=WxH");
    }
}
