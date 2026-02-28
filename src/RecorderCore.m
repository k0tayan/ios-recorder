#import "RecorderCore.h"
#import "VideoEncoder.h"
#import "AudioEncoder.h"
#import "MP4Muxer.h"
#import "TSMuxer.h"
#import "StreamServer.h"
#import <UIKit/UIKit.h>

static const uint16_t kStreamPort = 8191;
static const int kStreamFPS = 60;
static const int kStreamBitrate = 6000000;
static const int kStreamWidth = 1280;
static const int kStreamHeight = 720;

@interface RecorderCore ()
@property (atomic, readwrite) BOOL isRecording;
@property (atomic, readwrite) BOOL isStreaming;
@property (nonatomic) VideoEncoder *videoEncoder;
@property (nonatomic) AudioEncoder *audioEncoder;
@property (nonatomic) MP4Muxer *muxer;
@property (nonatomic) TSMuxer *tsMuxer;
@property (nonatomic) StreamServer *streamServer;
@property (nonatomic) CMTime recordingStartTime;
@property (nonatomic) NSString *currentOutputPath;
@property (nonatomic) id backgroundObserver;
@property (nonatomic) dispatch_queue_t recordingQueue;  // start/stop のシリアライズ用
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
        _isStreaming = NO;
        _targetFPS = 120;
        _videoBitrate = 16000000;
        _audioBitrate = 128000;
        _maxCaptureSize = CGSizeMake(2560, 1440);
        _recordingQueue = dispatch_queue_create("com.local.iosrecorder.recording", DISPATCH_QUEUE_SERIAL);
        // バックグラウンド遷移を監視 (retain cycle 回避のため __weak を使用)
        __weak typeof(self) weakSelf = self;
        _backgroundObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.isStreaming) {
                [strongSelf stopStreaming];
                NSLog(@"[Recorder] Auto-stopped streaming on background");
            }
            if (strongSelf.isRecording) {
                [strongSelf stopRecordingWithCompletion:^(NSString *path) {
                    NSLog(@"[Recorder] Auto-stopped recording on background: %@", path);
                }];
            }
        }];
    }
    return self;
}

- (void)startRecording {
    // recordingQueue でシリアライズし、stop 完了チェーンとの競合を防止
    dispatch_sync(self.recordingQueue, ^{
        [self _startRecordingInternal];
    });
}

- (void)_startRecordingInternal {
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

    // ストリーミング中はエンコーダが既に動いている
    BOOL needEncoders = !self.isStreaming;

    // FrameCapture からキャプチャサイズを取得
    CGSize captureSize = [FrameCapture shared].captureSize;
    if (captureSize.width == 0 || captureSize.height == 0) {
        captureSize = self.maxCaptureSize;
    }

    int width = (int)captureSize.width;
    int height = (int)captureSize.height;
    if (width > self.maxCaptureSize.width || height > self.maxCaptureSize.height) {
        float scaleW = self.maxCaptureSize.width / width;
        float scaleH = self.maxCaptureSize.height / height;
        float scale = fminf(scaleW, scaleH);
        width = (int)(width * scale);
        height = (int)(height * scale);
    }
    width = width & ~1;
    height = height & ~1;

    AudioCapture *audioCapture = [AudioCapture shared];

    if (needEncoders) {
        // VideoEncoder 初期化
        self.videoEncoder = [[VideoEncoder alloc] initWithWidth:width
                                                        height:height
                                                           fps:self.targetFPS
                                                       bitrate:self.videoBitrate];

        // AudioEncoder 初期化
        [audioCapture updateAudioFormat];
        self.audioEncoder = [[AudioEncoder alloc] initWithSampleRate:audioCapture.sampleRate
                                                            channels:audioCapture.channels
                                                             bitrate:self.audioBitrate];
    }

    // MP4Muxer 初期化
    self.muxer = [[MP4Muxer alloc] initWithOutputPath:self.currentOutputPath
                                                width:width
                                               height:height
                                      audioSampleRate:audioCapture.sampleRate
                                        audioChannels:audioCapture.channels];

    if (needEncoders) {
        if (![self.videoEncoder start]) {
            NSLog(@"[Recorder] Failed to start VideoEncoder");
            self.videoEncoder = nil;
            self.audioEncoder = nil;
            self.muxer = nil;
            return;
        }
        if (![self.audioEncoder start]) {
            NSLog(@"[Recorder] Failed to start AudioEncoder");
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [self.videoEncoder stopWithCompletion:^{ dispatch_semaphore_signal(sem); }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
            self.videoEncoder = nil;
            self.audioEncoder = nil;
            self.muxer = nil;
            return;
        }
    }

    self.muxer.audioFormatDescription = self.audioEncoder.audioFormatDescription;

    if (![self.muxer start]) {
        NSLog(@"[Recorder] Failed to start MP4Muxer");
        if (needEncoders) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [self.videoEncoder stopWithCompletion:^{
                [self.audioEncoder stopWithCompletion:^{ dispatch_semaphore_signal(sem); }];
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
            self.videoEncoder = nil;
            self.audioEncoder = nil;
        }
        self.muxer = nil;
        return;
    }

    // コールバック再接続 (MP4 + TS 両方に fan-out)
    [self _rewireEncoderCallbacks];

    if (needEncoders) {
        self.recordingStartTime = CMClockGetTime(CMClockGetHostTimeClock());

        FrameCapture *frameCapture = [FrameCapture shared];
        frameCapture.targetFPS = self.targetFPS;
        frameCapture.delegate = self;
        [frameCapture setRecordingStartTime:self.recordingStartTime];
        frameCapture.capturing = YES;

        audioCapture.delegate = self;
        [audioCapture setRecordingStartTime:self.recordingStartTime];
        audioCapture.capturing = YES;
    }

    self.isRecording = YES;
    NSLog(@"[Recorder] Recording started: %dx%d → %@",
          width, height, self.currentOutputPath);
}

- (void)startStreaming {
    dispatch_sync(self.recordingQueue, ^{
        [self _startStreamingInternal];
    });
}

- (void)_startStreamingInternal {
    if (self.isStreaming) {
        NSLog(@"[Recorder] Already streaming");
        return;
    }

    NSLog(@"[Recorder] Starting streaming...");

    // エンコーダが未起動の場合 (ストリーミングのみ) は起動する
    BOOL needEncoders = !self.isRecording;
    if (needEncoders) {
        // ストリーミング専用: 720p 60fps 固定
        int width = kStreamWidth;
        int height = kStreamHeight;

        self.videoEncoder = [[VideoEncoder alloc] initWithWidth:width
                                                        height:height
                                                           fps:kStreamFPS
                                                       bitrate:kStreamBitrate];

        AudioCapture *audioCapture = [AudioCapture shared];
        [audioCapture updateAudioFormat];
        self.audioEncoder = [[AudioEncoder alloc] initWithSampleRate:audioCapture.sampleRate
                                                            channels:audioCapture.channels
                                                             bitrate:self.audioBitrate];

        if (![self.videoEncoder start]) {
            NSLog(@"[Recorder] Failed to start VideoEncoder for streaming");
            self.videoEncoder = nil;
            self.audioEncoder = nil;
            return;
        }
        if (![self.audioEncoder start]) {
            NSLog(@"[Recorder] Failed to start AudioEncoder for streaming");
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [self.videoEncoder stopWithCompletion:^{ dispatch_semaphore_signal(sem); }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
            self.videoEncoder = nil;
            self.audioEncoder = nil;
            return;
        }
    }

    // TSMuxer + StreamServer 初期化
    self.tsMuxer = [[TSMuxer alloc] init];
    self.streamServer = [[StreamServer alloc] initWithPort:kStreamPort];

    __weak TSMuxer *weakTSMuxer = self.tsMuxer;
    self.streamServer.bootstrapProvider = ^NSData * {
        return [weakTSMuxer bootstrapData];
    };

    __weak StreamServer *weakServer = self.streamServer;
    self.tsMuxer.onTSPackets = ^(const uint8_t *data, size_t length) {
        [weakServer sendData:data length:length];
    };

    if (![self.streamServer start]) {
        NSLog(@"[Recorder] Failed to start StreamServer");
        self.tsMuxer = nil;
        self.streamServer = nil;
        if (needEncoders) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [self.videoEncoder stopWithCompletion:^{
                [self.audioEncoder stopWithCompletion:^{ dispatch_semaphore_signal(sem); }];
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
            self.videoEncoder = nil;
            self.audioEncoder = nil;
        }
        return;
    }

    // コールバック再接続
    [self _rewireEncoderCallbacks];

    // キャプチャが未起動の場合は起動
    if (needEncoders) {
        self.recordingStartTime = CMClockGetTime(CMClockGetHostTimeClock());

        FrameCapture *frameCapture = [FrameCapture shared];
        frameCapture.targetFPS = kStreamFPS;
        frameCapture.delegate = self;
        [frameCapture setRecordingStartTime:self.recordingStartTime];
        frameCapture.capturing = YES;

        AudioCapture *audioCapture = [AudioCapture shared];
        audioCapture.delegate = self;
        [audioCapture setRecordingStartTime:self.recordingStartTime];
        audioCapture.capturing = YES;
    }

    self.isStreaming = YES;
    NSLog(@"[Recorder] Streaming started: %dx%d@%dfps %dkbps on port %u",
          kStreamWidth, kStreamHeight, kStreamFPS, kStreamBitrate / 1000, kStreamPort);
}

- (void)stopStreaming {
    dispatch_sync(self.recordingQueue, ^{
        [self _stopStreamingInternal];
    });
}

- (void)_stopStreamingInternal {
    if (!self.isStreaming) {
        NSLog(@"[Recorder] Not streaming");
        return;
    }

    NSLog(@"[Recorder] Stopping streaming...");

    self.isStreaming = NO;

    // StreamServer + TSMuxer 停止
    [self.streamServer stop];
    self.streamServer = nil;
    self.tsMuxer = nil;

    // コールバック再接続 (録画が続いている場合は MP4 のみに戻す)
    if (self.isRecording) {
        [self _rewireEncoderCallbacks];
    } else {
        // キャプチャも停止
        [FrameCapture shared].capturing = NO;
        [FrameCapture shared].delegate = nil;
        [AudioCapture shared].capturing = NO;
        [AudioCapture shared].delegate = nil;

        // エンコーダ停止
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        VideoEncoder *ve = self.videoEncoder;
        AudioEncoder *ae = self.audioEncoder;
        [ve stopWithCompletion:^{
            [ae stopWithCompletion:^{
                dispatch_semaphore_signal(sem);
            }];
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        self.videoEncoder = nil;
        self.audioEncoder = nil;
    }

    NSLog(@"[Recorder] Streaming stopped");
}

- (void)stopRecordingWithCompletion:(void (^)(NSString *outputPath))completion {
    // recordingQueue でシリアライズし、start との競合を防止。
    // dispatch_async を使い、ControlServer の STOP セマフォ待ちと
    // recordingQueue のデッドロックを回避する。
    dispatch_async(self.recordingQueue, ^{
        [self _stopRecordingInternalWithCompletion:completion];
    });
}

- (void)_stopRecordingInternalWithCompletion:(void (^)(NSString *outputPath))completion {
    if (!self.isRecording) {
        NSLog(@"[Recorder] Not recording");
        if (completion) completion(nil);
        return;
    }

    NSLog(@"[Recorder] Stopping recording...");

    // ストリーミングが続いている場合はキャプチャ・エンコーダを維持
    BOOL keepEncoders = self.isStreaming;

    if (!keepEncoders) {
        // まずキャプチャを停止 (残りデータをデリゲートにフラッシュ) し、切断する。
        // 重要: drain 中は isRecording = YES を保持し、デリゲートコールバックが
        // エンコーダにデータを転送し続けるようにする。
        [FrameCapture shared].capturing = NO;
        [FrameCapture shared].delegate = nil;
        [AudioCapture shared].capturing = NO;
        [AudioCapture shared].delegate = nil;
    }

    self.isRecording = NO;

    // コールバック再接続 (TS のみに戻す or 全停止)
    if (keepEncoders) {
        [self _rewireEncoderCallbacks];
    }

    MP4Muxer *mux = self.muxer;
    self.muxer = nil;

    if (keepEncoders) {
        // エンコーダは維持、muxer のみファイナライズ
        [mux finishWithCompletion:^(NSString *outputPath) {
            if (outputPath) {
                NSLog(@"[Recorder] Recording saved: %@", outputPath);
            }
            if (completion) completion(outputPath);
        }];
    } else {
        // エンコーダを停止してから muxer をファイナライズ
        VideoEncoder *ve = self.videoEncoder;
        AudioEncoder *ae = self.audioEncoder;
        self.videoEncoder = nil;
        self.audioEncoder = nil;
        [ve stopWithCompletion:^{
            [ae stopWithCompletion:^{
                [mux finishWithCompletion:^(NSString *outputPath) {
                    if (outputPath) {
                        NSLog(@"[Recorder] Recording saved: %@", outputPath);
                    }
                    if (completion) completion(outputPath);
                }];
            }];
        }];
    }
}

/// エンコーダの出力コールバックを現在のモード (録画/ストリーミング/両方) に合わせて再設定する。
/// recordingQueue 上で呼ぶこと。
- (void)_rewireEncoderCallbacks {
    __weak MP4Muxer *weakMuxer = self.muxer;
    __weak TSMuxer *weakTSMuxer = self.tsMuxer;

    BOOL toMuxer = (self.muxer != nil);
    BOOL toTS = (self.tsMuxer != nil);

    if (toMuxer && toTS) {
        // 両方に fan-out
        self.videoEncoder.onEncodedSample = ^(CMSampleBufferRef sampleBuffer) {
            [weakMuxer appendVideoSample:sampleBuffer];
            [weakTSMuxer muxVideoSample:sampleBuffer];
        };
        self.audioEncoder.onEncodedSample = ^(CMSampleBufferRef sampleBuffer) {
            [weakMuxer appendAudioSample:sampleBuffer];
            [weakTSMuxer muxAudioSample:sampleBuffer];
        };
    } else if (toMuxer) {
        // MP4 のみ
        self.videoEncoder.onEncodedSample = ^(CMSampleBufferRef sampleBuffer) {
            [weakMuxer appendVideoSample:sampleBuffer];
        };
        self.audioEncoder.onEncodedSample = ^(CMSampleBufferRef sampleBuffer) {
            [weakMuxer appendAudioSample:sampleBuffer];
        };
    } else if (toTS) {
        // TS のみ
        self.videoEncoder.onEncodedSample = ^(CMSampleBufferRef sampleBuffer) {
            [weakTSMuxer muxVideoSample:sampleBuffer];
        };
        self.audioEncoder.onEncodedSample = ^(CMSampleBufferRef sampleBuffer) {
            [weakTSMuxer muxAudioSample:sampleBuffer];
        };
    } else {
        self.videoEncoder.onEncodedSample = nil;
        self.audioEncoder.onEncodedSample = nil;
    }
}

- (void)forceResetRecordingState {
    // 緊急リセット: recordingQueue を経由しない。
    NSLog(@"[Recorder] Force resetting recording state");
    [FrameCapture shared].capturing = NO;
    [FrameCapture shared].delegate = nil;
    [AudioCapture shared].capturing = NO;
    [AudioCapture shared].delegate = nil;
    self.isRecording = NO;
    self.isStreaming = NO;
    self.videoEncoder = nil;
    self.audioEncoder = nil;
    self.muxer = nil;
    [self.streamServer stop];
    self.streamServer = nil;
    self.tsMuxer = nil;
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
            // ディレクトリ内のファイルサイズを再帰的に合算
            NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:fullPath];
            for (__unused NSString *subPath in enumerator) {
                NSDictionary *subAttrs = [enumerator fileAttributes];
                if (![subAttrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
                    freedBytes += [subAttrs fileSize];
                }
            }
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
    if (!self.isRecording && !self.isStreaming) return;

    [self.videoEncoder encodePixelBuffer:pixelBuffer timestamp:timestamp surfaceOwner:surfaceOwner];
}

#pragma mark - AudioCaptureDelegate

- (void)audioCapture:(AudioCapture *)capture
    didCaptureAudioBuffer:(AudioBufferList *)bufferList
               numFrames:(UInt32)numFrames
               timestamp:(CMTime)timestamp {
    if (!self.isRecording && !self.isStreaming) return;

    [self.audioEncoder encodePCMBuffer:bufferList numFrames:numFrames timestamp:timestamp];
}

- (void)audioCaptureFormatDidChange:(AudioCapture *)capture
                         sampleRate:(Float64)sampleRate
                           channels:(UInt32)channels {
    if (!self.isRecording && !self.isStreaming) return;
    NSLog(@"[Recorder] Audio format change detected, reconfiguring encoder");
    [self.audioEncoder reconfigureWithSampleRate:sampleRate channels:channels];
}

- (void)dealloc {
    if (_backgroundObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_backgroundObserver];
    }
}

@end
