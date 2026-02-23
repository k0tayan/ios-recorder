#import "RecorderCore.h"
#import "VideoEncoder.h"
#import "AudioEncoder.h"
#import "MP4Muxer.h"
#import <UIKit/UIKit.h>

@interface RecorderCore ()
@property (nonatomic, readwrite) BOOL isRecording;
@property (nonatomic) VideoEncoder *videoEncoder;
@property (nonatomic) AudioEncoder *audioEncoder;
@property (nonatomic) MP4Muxer *muxer;
@property (nonatomic) CMTime recordingStartTime;
@property (nonatomic) NSString *currentOutputPath;
@property (nonatomic) int64_t videoFrameNumber;
@property (nonatomic) id backgroundObserver;
@end

@implementation RecorderCore

+ (instancetype)shared {
    static RecorderCore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[RecorderCore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isRecording = NO;
        _targetFPS = 120;
        _videoBitrate = 16000000;
        _audioBitrate = 128000;
        _maxCaptureSize = CGSizeMake(2060, 1440);
        // バックグラウンド遷移を監視 (retain cycle 回避のため __weak を使用)
        __weak typeof(self) weakSelf = self;
        _backgroundObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.isRecording) {
                [strongSelf stopRecordingWithCompletion:^(NSString *path) {
                    NSLog(@"[Recorder] Auto-stopped on background: %@", path);
                }];
            }
        }];
    }
    return self;
}

- (void)startRecording {
    if (self.isRecording) {
        NSLog(@"[Recorder] Already recording");
        return;
    }

    NSLog(@"[Recorder] Starting recording...");

    // 出力パス生成
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    self.currentOutputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"recording_%@.mp4", timestamp]];

    // FrameCapture からキャプチャサイズを取得
    CGSize captureSize = [FrameCapture shared].captureSize;
    if (captureSize.width == 0 || captureSize.height == 0) {
        // 未決定の場合のデフォルトサイズ (iPad 4:3)
        captureSize = self.maxCaptureSize;
    }

    // 最大サイズを超える場合は縮小
    int width = (int)captureSize.width;
    int height = (int)captureSize.height;
    if (width > self.maxCaptureSize.width || height > self.maxCaptureSize.height) {
        float scaleW = self.maxCaptureSize.width / width;
        float scaleH = self.maxCaptureSize.height / height;
        float scale = fminf(scaleW, scaleH);
        width = (int)(width * scale);
        height = (int)(height * scale);
        // H.264 用に偶数を保証
        width = width & ~1;
        height = height & ~1;
    }

    // VideoEncoder 初期化
    self.videoEncoder = [[VideoEncoder alloc] initWithWidth:width
                                                    height:height
                                                       fps:self.targetFPS
                                                   bitrate:self.videoBitrate];

    // AudioEncoder 初期化
    AudioCapture *audioCapture = [AudioCapture shared];
    [audioCapture updateAudioFormat];
    self.audioEncoder = [[AudioEncoder alloc] initWithSampleRate:audioCapture.sampleRate
                                                        channels:audioCapture.channels
                                                         bitrate:self.audioBitrate];
    // MP4Muxer 初期化
    self.muxer = [[MP4Muxer alloc] initWithOutputPath:self.currentOutputPath
                                                width:width
                                               height:height
                                      audioSampleRate:audioCapture.sampleRate
                                        audioChannels:audioCapture.channels];

    // コールバック接続
    __weak MP4Muxer *weakMuxer = self.muxer;
    self.videoEncoder.onEncodedSample = ^(CMSampleBufferRef sampleBuffer) {
        [weakMuxer appendVideoSample:sampleBuffer];
    };
    self.audioEncoder.onEncodedSample = ^(CMSampleBufferRef sampleBuffer) {
        [weakMuxer appendAudioSample:sampleBuffer];
    };

    // 全コンポーネント開始
    if (![self.videoEncoder start]) {
        NSLog(@"[Recorder] Failed to start VideoEncoder");
        return;
    }
    if (![self.audioEncoder start]) {
        NSLog(@"[Recorder] Failed to start AudioEncoder");
        [self.videoEncoder stopWithCompletion:nil];
        return;
    }

    // エンコーダのフォーマット記述 (magic cookie 付き) を muxer に渡して
    // AVAssetWriter が正しい esds box とコーデックタグを書けるようにする。
    self.muxer.audioFormatDescription = self.audioEncoder.audioFormatDescription;

    if (![self.muxer start]) {
        NSLog(@"[Recorder] Failed to start MP4Muxer");
        [self.videoEncoder stopWithCompletion:nil];
        [self.audioEncoder stopWithCompletion:nil];
        return;
    }

    // 録画開始時刻を記録
    self.recordingStartTime = CMClockGetTime(CMClockGetHostTimeClock());

    // キャプチャコンポーネントの設定
    FrameCapture *frameCapture = [FrameCapture shared];
    frameCapture.targetFPS = self.targetFPS;
    frameCapture.delegate = self;
    [frameCapture setRecordingStartTime:self.recordingStartTime];
    frameCapture.capturing = YES;

    audioCapture.delegate = self;
    [audioCapture setRecordingStartTime:self.recordingStartTime];
    audioCapture.capturing = YES;

    self.videoFrameNumber = 0;
    self.isRecording = YES;
    NSLog(@"[Recorder] Recording started: %dx%d → %@",
          width, height, self.currentOutputPath);
}

- (void)stopRecordingWithCompletion:(void (^)(NSString *outputPath))completion {
    if (!self.isRecording) {
        NSLog(@"[Recorder] Not recording");
        if (completion) completion(nil);
        return;
    }

    NSLog(@"[Recorder] Stopping recording...");

    // まずキャプチャを停止 (残りデータをデリゲートにフラッシュ) し、切断する。
    // 重要: drain 中は isRecording = YES を保持し、デリゲートコールバックが
    // エンコーダにデータを転送し続けるようにする。drain 前に NO にすると
    // 最後のリングバッファフラッシュが無視されていた。
    [FrameCapture shared].capturing = NO;
    [FrameCapture shared].delegate = nil;
    [AudioCapture shared].capturing = NO;   // isRecording = YES のまま同期 drain
    [AudioCapture shared].delegate = nil;

    self.isRecording = NO;

    // エンコーダを停止してから muxer をファイナライズ
    __weak typeof(self) weakSelf = self;
    [self.videoEncoder stopWithCompletion:^{
        [weakSelf.audioEncoder stopWithCompletion:^{
            [weakSelf.muxer finishWithCompletion:^(NSString *outputPath) {
                if (outputPath) {
                    NSLog(@"[Recorder] Recording saved: %@", outputPath);
                }
                if (completion) completion(outputPath);
            }];
        }];
    }];
}

- (NSDictionary *)cleanupTempFiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tmpDir = NSTemporaryDirectory();
    NSArray *contents = [fm contentsOfDirectoryAtPath:tmpDir error:nil];

    int deletedCount = 0;
    unsigned long long freedBytes = 0;

    for (NSString *name in contents) {
        NSString *fullPath = [tmpDir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        [fm fileExistsAtPath:fullPath isDirectory:&isDir];

        // CFNetworkDownload_*.tmp
        if ([name hasPrefix:@"CFNetworkDownload_"] && [name hasSuffix:@".tmp"]) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            freedBytes += [attrs fileSize];
            [fm removeItemAtPath:fullPath error:nil];
            deletedCount++;
            continue;
        }

        // NSIRD_ProductName_* ディレクトリ
        if (isDir && [name hasPrefix:@"NSIRD_"]) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            freedBytes += [attrs fileSize];
            [fm removeItemAtPath:fullPath error:nil];
            deletedCount++;
            continue;
        }

        // 0バイトの recording_*.mp4 (失敗した録画)
        if ([name hasPrefix:@"recording_"] && [name hasSuffix:@".mp4"]) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            unsigned long long size = [attrs fileSize];
            if (size == 0) {
                [fm removeItemAtPath:fullPath error:nil];
                deletedCount++;
                continue;
            }
            // 現在録画中でない非ゼロの録画ファイル
            if (![fullPath isEqualToString:self.currentOutputPath] || !self.isRecording) {
                freedBytes += size;
                [fm removeItemAtPath:fullPath error:nil];
                deletedCount++;
            }
        }
    }

    NSLog(@"[Recorder] Cleanup: deleted %d files, freed %llu bytes", deletedCount, freedBytes);
    return @{
        @"deleted": @(deletedCount),
        @"freedBytes": @(freedBytes)
    };
}

#pragma mark - FrameCaptureDelegate

- (void)frameCapture:(FrameCapture *)capture
    didCapturePixelBuffer:(CVPixelBufferRef)pixelBuffer
               timestamp:(CMTime)timestamp
            surfaceOwner:(id)surfaceOwner {
    if (!self.isRecording) return;

    self.videoFrameNumber++;

    [self.videoEncoder encodePixelBuffer:pixelBuffer timestamp:timestamp surfaceOwner:surfaceOwner];
}

#pragma mark - AudioCaptureDelegate

- (void)audioCapture:(AudioCapture *)capture
    didCaptureAudioBuffer:(AudioBufferList *)bufferList
               numFrames:(UInt32)numFrames
               timestamp:(CMTime)timestamp {
    if (!self.isRecording) return;

    [self.audioEncoder encodePCMBuffer:bufferList numFrames:numFrames timestamp:timestamp];
}

- (void)audioCaptureFormatDidChange:(AudioCapture *)capture
                         sampleRate:(Float64)sampleRate
                           channels:(UInt32)channels {
    if (!self.isRecording) return;
    NSLog(@"[Recorder] Audio format change detected during recording, reconfiguring encoder");
    [self.audioEncoder reconfigureWithSampleRate:sampleRate channels:channels];
}

- (void)dealloc {
    if (_backgroundObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_backgroundObserver];
    }
}

@end
