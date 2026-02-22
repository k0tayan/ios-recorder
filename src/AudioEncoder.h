#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

@interface AudioEncoder : NSObject

@property (nonatomic, copy) void (^onEncodedSample)(CMSampleBufferRef sampleBuffer);
@property (nonatomic, readonly) CMAudioFormatDescriptionRef audioFormatDescription;

- (instancetype)initWithSampleRate:(Float64)sampleRate
                          channels:(UInt32)channels
                           bitrate:(UInt32)bitrate;
- (BOOL)start;
- (void)reconfigureWithSampleRate:(Float64)sampleRate channels:(UInt32)channels;
- (void)encodePCMBuffer:(AudioBufferList *)bufferList
              numFrames:(UInt32)numFrames
              timestamp:(CMTime)timestamp;
- (void)stopWithCompletion:(void (^)(void))completion;

@end
