#import "MP4Muxer.h"
#import <AudioToolbox/AudioToolbox.h>

@interface MP4Muxer ()
@property (nonatomic) AVAssetWriter *writer;
@property (nonatomic) AVAssetWriterInput *videoInput;
@property (nonatomic) AVAssetWriterInput *audioInput;
@property (nonatomic) NSString *outputPath;
@property (nonatomic) int width;
@property (nonatomic) int height;
@property (nonatomic) Float64 audioSampleRate;
@property (nonatomic) UInt32  audioChannels;
@property (nonatomic) dispatch_queue_t muxerQueue;
@property (nonatomic) BOOL sessionStarted;
@property (nonatomic) BOOL videoInputReady;
@property (nonatomic) BOOL audioInputReady;
@property (nonatomic) int64_t videoDropCount;
@property (nonatomic) int64_t audioDropCount;
@end

@implementation MP4Muxer

- (instancetype)initWithOutputPath:(NSString *)path
                             width:(int)width
                            height:(int)height
                   audioSampleRate:(Float64)sampleRate
                     audioChannels:(UInt32)channels {
    self = [super init];
    if (self) {
        _outputPath = [path copy];
        _width = width;
        _height = height;
        _audioSampleRate = sampleRate;
        _audioChannels = channels;
        _sessionStarted = NO;
        _videoInputReady = NO;
        _audioInputReady = NO;
        _muxerQueue = dispatch_queue_create("com.local.iosrecorder.muxer", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)start {
    NSError *error = nil;
    NSURL *outputURL = [NSURL fileURLWithPath:self.outputPath];

    // 既存ファイルを削除
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    self.writer = [[AVAssetWriter alloc] initWithURL:outputURL
                                            fileType:AVFileTypeMPEG4
                                               error:&error];
    if (error) {
        NSLog(@"[Recorder] Failed to create AVAssetWriter: %@", error);
        return NO;
    }

    // 映像入力 — HEVC パススルー (フォーマットヒント付き)
    CMVideoFormatDescriptionRef videoFmt = NULL;
    CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                    kCMVideoCodecType_HEVC,
                                    self.width, self.height,
                                    NULL, &videoFmt);

    self.videoInput = [[AVAssetWriterInput alloc]
        initWithMediaType:AVMediaTypeVideo
           outputSettings:nil
         sourceFormatHint:(CMFormatDescriptionRef)videoFmt];
    if (videoFmt) CFRelease(videoFmt);

    self.videoInput.expectsMediaDataInRealTime = YES;
    if ([self.writer canAddInput:self.videoInput]) {
        [self.writer addInput:self.videoInput];
        self.videoInputReady = YES;
    } else {
        NSLog(@"[Recorder] Cannot add video passthrough input");
        return NO;
    }

    // 音声入力 — AAC パススルー (フォーマットヒント付き)
    CMAudioFormatDescriptionRef audioFmt = self.audioFormatDescription;
    BOOL ownedAudioFmt = NO;
    if (!audioFmt) {
        // フォールバック: 最小限のフォーマットヒント (magic cookie なし)
        AudioStreamBasicDescription aacDesc = {
            .mFormatID         = kAudioFormatMPEG4AAC,
            .mSampleRate       = self.audioSampleRate,
            .mChannelsPerFrame = self.audioChannels,
            .mFramesPerPacket  = 1024,
        };
        CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &aacDesc,
                                        0, NULL, 0, NULL, NULL, &audioFmt);
        ownedAudioFmt = YES;
    }

    self.audioInput = [[AVAssetWriterInput alloc]
        initWithMediaType:AVMediaTypeAudio
           outputSettings:nil
         sourceFormatHint:(CMFormatDescriptionRef)audioFmt];
    if (ownedAudioFmt && audioFmt) CFRelease(audioFmt);

    self.audioInput.expectsMediaDataInRealTime = YES;
    if ([self.writer canAddInput:self.audioInput]) {
        [self.writer addInput:self.audioInput];
        self.audioInputReady = YES;
    } else {
        NSLog(@"[Recorder] Cannot add audio passthrough input, continuing video-only");
        self.audioInput = nil;
        self.audioInputReady = NO;
    }

    BOOL started = [self.writer startWriting];
    if (!started) {
        NSLog(@"[Recorder] AVAssetWriter failed to start: %@", self.writer.error);
        return NO;
    }

    NSLog(@"[Recorder] MP4Muxer started: %@ (video:%@ audio:%@)",
          self.outputPath,
          self.videoInputReady ? @"YES" : @"NO",
          self.audioInputReady ? @"YES" : @"NO");
    return YES;
}

- (void)appendVideoSample:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;

    CFRetain(sampleBuffer);
    dispatch_async(self.muxerQueue, ^{
        if (self.writer.status != AVAssetWriterStatusWriting) {
            CFRelease(sampleBuffer);
            return;
        }

        if (!self.sessionStarted) {
            // 映像の最初の PTS は 0 (FrameCapture が保証) なので、
            // セッション開始時刻も 0 にして全サンプルを含める。
            [self.writer startSessionAtSourceTime:kCMTimeZero];
            self.sessionStarted = YES;
        }

        if (self.videoInputReady && self.videoInput.isReadyForMoreMediaData) {
            if (![self.videoInput appendSampleBuffer:sampleBuffer]) {
                NSLog(@"[Recorder] Failed to append video sample: %@", self.writer.error);
            }
        } else {
            self.videoDropCount++;
        }

        CFRelease(sampleBuffer);
    });
}

- (void)appendAudioSample:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer || !self.audioInputReady) return;

    CFRetain(sampleBuffer);
    dispatch_async(self.muxerQueue, ^{
        if (self.writer.status != AVAssetWriterStatusWriting) {
            CFRelease(sampleBuffer);
            return;
        }

        // 映像より先に音声が到着した場合、時刻 0 からセッション開始
        if (!self.sessionStarted) {
            [self.writer startSessionAtSourceTime:kCMTimeZero];
            self.sessionStarted = YES;
        }

        if (self.audioInput.isReadyForMoreMediaData) {
            if (![self.audioInput appendSampleBuffer:sampleBuffer]) {
                NSLog(@"[Recorder] Failed to append audio sample: %@", self.writer.error);
            }
        } else {
            self.audioDropCount++;
        }

        CFRelease(sampleBuffer);
    });
}

- (void)finishWithCompletion:(void (^)(NSString *outputPath))completion {
    dispatch_async(self.muxerQueue, ^{
        if (self.writer.status != AVAssetWriterStatusWriting) {
            NSLog(@"[Recorder] Writer not in writing state: %ld", (long)self.writer.status);
            if (completion) completion(nil);
            return;
        }

        if (self.videoDropCount > 0 || self.audioDropCount > 0) {
            NSLog(@"[Recorder] Muxer drops: video=%lld audio=%lld (isReadyForMoreMediaData was NO)",
                  (long long)self.videoDropCount, (long long)self.audioDropCount);
        }

        if (self.videoInputReady) [self.videoInput markAsFinished];
        if (self.audioInputReady) [self.audioInput markAsFinished];

        NSString *path = self.outputPath;
        [self.writer finishWritingWithCompletionHandler:^{
            if (self.writer.status == AVAssetWriterStatusCompleted) {
                NSLog(@"[Recorder] MP4 written successfully: %@", path);
            } else {
                NSLog(@"[Recorder] MP4 write failed: %@", self.writer.error);
            }
            // stop チェーンはメインキューを経由しない。
            // 最終的な呼び出し元 (ControlServer) がセマフォで待つため、
            // メインキュー dispatch だとデッドロックの可能性がある。
            if (completion) {
                completion(self.writer.status == AVAssetWriterStatusCompleted ? path : nil);
            }
        }];
    });
}

@end
