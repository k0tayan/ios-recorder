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
        // Listen for background transition
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
            if (self.isRecording) {
                [self stopRecordingWithCompletion:^(NSString *path) {
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

    // Generate output path
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    self.currentOutputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"recording_%@.mp4", timestamp]];

    // Get capture size from FrameCapture
    CGSize captureSize = [FrameCapture shared].captureSize;
    if (captureSize.width == 0 || captureSize.height == 0) {
        // Default size if not yet determined (iPad 4:3)
        captureSize = self.maxCaptureSize;
    }

    // Scale down if exceeds max
    int width = (int)captureSize.width;
    int height = (int)captureSize.height;
    if (width > self.maxCaptureSize.width || height > self.maxCaptureSize.height) {
        float scaleW = self.maxCaptureSize.width / width;
        float scaleH = self.maxCaptureSize.height / height;
        float scale = fminf(scaleW, scaleH);
        width = (int)(width * scale);
        height = (int)(height * scale);
        // Ensure even dimensions for H.264
        width = width & ~1;
        height = height & ~1;
    }

    // Initialize VideoEncoder
    self.videoEncoder = [[VideoEncoder alloc] initWithWidth:width
                                                    height:height
                                                       fps:self.targetFPS
                                                   bitrate:self.videoBitrate];

    // Initialize AudioEncoder
    AudioCapture *audioCapture = [AudioCapture shared];
    [audioCapture updateAudioFormat];
    self.audioEncoder = [[AudioEncoder alloc] initWithSampleRate:audioCapture.sampleRate
                                                        channels:audioCapture.channels
                                                         bitrate:self.audioBitrate];
    // Initialize MP4Muxer
    self.muxer = [[MP4Muxer alloc] initWithOutputPath:self.currentOutputPath
                                                width:width
                                               height:height
                                      audioSampleRate:audioCapture.sampleRate
                                        audioChannels:audioCapture.channels];

    // Wire up callbacks
    __weak MP4Muxer *weakMuxer = self.muxer;
    self.videoEncoder.onEncodedSample = ^(CMSampleBufferRef sampleBuffer) {
        [weakMuxer appendVideoSample:sampleBuffer];
    };
    self.audioEncoder.onEncodedSample = ^(CMSampleBufferRef sampleBuffer) {
        [weakMuxer appendAudioSample:sampleBuffer];
    };

    // Start all components
    if (![self.videoEncoder start]) {
        NSLog(@"[Recorder] Failed to start VideoEncoder");
        return;
    }
    if (![self.audioEncoder start]) {
        NSLog(@"[Recorder] Failed to start AudioEncoder");
        [self.videoEncoder stopWithCompletion:nil];
        return;
    }

    // Pass the encoder's format description (with magic cookie) to the muxer
    // so AVAssetWriter can write a correct esds box and codec tag.
    self.muxer.audioFormatDescription = self.audioEncoder.audioFormatDescription;

    if (![self.muxer start]) {
        NSLog(@"[Recorder] Failed to start MP4Muxer");
        [self.videoEncoder stopWithCompletion:nil];
        [self.audioEncoder stopWithCompletion:nil];
        return;
    }

    // Record start time
    self.recordingStartTime = CMClockGetTime(CMClockGetHostTimeClock());

    // Configure capture components
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

    // Stop capturing first (flushes remaining data to delegate), then disconnect.
    // IMPORTANT: keep isRecording = YES during the drain so that the delegate
    // callbacks still forward data to the encoders.  Setting it to NO before
    // the drain caused the final ring-buffer flush to be silently discarded.
    [FrameCapture shared].capturing = NO;
    [FrameCapture shared].delegate = nil;
    [AudioCapture shared].capturing = NO;   // synchronous drain with isRecording still YES
    [AudioCapture shared].delegate = nil;

    self.isRecording = NO;

    // Stop encoders, then finalize muxer
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

        // NSIRD_ProductName_* directories
        if (isDir && [name hasPrefix:@"NSIRD_"]) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            freedBytes += [attrs fileSize];
            [fm removeItemAtPath:fullPath error:nil];
            deletedCount++;
            continue;
        }

        // 0-byte recording_*.mp4 (failed recordings)
        if ([name hasPrefix:@"recording_"] && [name hasSuffix:@".mp4"]) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            unsigned long long size = [attrs fileSize];
            if (size == 0) {
                [fm removeItemAtPath:fullPath error:nil];
                deletedCount++;
                continue;
            }
            // Non-zero recordings that are not currently being recorded
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
               timestamp:(CMTime)timestamp {
    if (!self.isRecording) return;

    self.videoFrameNumber++;

    [self.videoEncoder encodePixelBuffer:pixelBuffer timestamp:timestamp];
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

@end
