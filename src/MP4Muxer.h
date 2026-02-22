#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

@interface MP4Muxer : NSObject

/// Set before calling -start to provide a complete audio format hint
/// (including magic cookie / AudioSpecificConfig).
@property (nonatomic) CMAudioFormatDescriptionRef audioFormatDescription;

- (instancetype)initWithOutputPath:(NSString *)path
                             width:(int)width
                            height:(int)height
                   audioSampleRate:(Float64)sampleRate
                     audioChannels:(UInt32)channels;
- (BOOL)start;
- (void)appendVideoSample:(CMSampleBufferRef)sampleBuffer;
- (void)appendAudioSample:(CMSampleBufferRef)sampleBuffer;
- (void)finishWithCompletion:(void (^)(NSString *outputPath))completion;

@end
