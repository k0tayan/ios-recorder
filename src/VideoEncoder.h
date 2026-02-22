#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

@interface VideoEncoder : NSObject

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, copy) void (^onEncodedSample)(CMSampleBufferRef sampleBuffer);

- (instancetype)initWithWidth:(int)width
                       height:(int)height
                          fps:(int)fps
                      bitrate:(int)bitrate;
- (BOOL)start;
- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                timestamp:(CMTime)timestamp;
- (void)stopWithCompletion:(void (^)(void))completion;

@end
