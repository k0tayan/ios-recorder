#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

@interface MP4Muxer : NSObject

/// -start を呼ぶ前にセットして、完全な音声フォーマットヒント
/// (magic cookie / AudioSpecificConfig を含む) を提供する。
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
