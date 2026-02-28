#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "FrameCapture.h"
#import "AudioCapture.h"

@interface RecorderCore : NSObject <FrameCaptureDelegate, AudioCaptureDelegate>

@property (atomic, readonly) BOOL isRecording;
@property (atomic, readonly) BOOL isStreaming;
@property (nonatomic) int targetFPS;
@property (nonatomic) int videoBitrate;
@property (nonatomic) int audioBitrate;
@property (nonatomic) CGSize maxCaptureSize;

+ (instancetype)shared;
- (void)startRecording;
- (void)stopRecordingWithCompletion:(void (^)(NSString *outputPath))completion;
- (void)startStreaming;
- (void)stopStreaming;
- (void)forceResetRecordingState;
- (NSDictionary *)cleanupTempFiles;

@end
