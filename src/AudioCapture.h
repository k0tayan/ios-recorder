#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

@class AudioCapture;

@protocol AudioCaptureDelegate <NSObject>
- (void)audioCapture:(AudioCapture *)capture
    didCaptureAudioBuffer:(AudioBufferList *)bufferList
               numFrames:(UInt32)numFrames
               timestamp:(CMTime)timestamp;
@optional
- (void)audioCaptureFormatDidChange:(AudioCapture *)capture
                         sampleRate:(Float64)sampleRate
                           channels:(UInt32)channels;
@end

@interface AudioCapture : NSObject

@property (nonatomic, weak) id<AudioCaptureDelegate> delegate;
@property (nonatomic, readonly) Float64 sampleRate;
@property (nonatomic, readonly) UInt32 channels;
@property (nonatomic) BOOL capturing;

+ (instancetype)shared;
- (BOOL)installHook;
- (void)setRecordingStartTime:(CMTime)startTime;
- (void)updateAudioFormat;

@end
