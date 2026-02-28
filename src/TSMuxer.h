#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

@interface TSMuxer : NSObject

/// TS パケットが生成されたときに呼ばれるコールバック。
/// 188 バイトの倍数の連続 TS パケットが渡される。
@property (nonatomic, copy) void (^onTSPackets)(const uint8_t *data, size_t length);

/// H.265 ビデオサンプルを TS パケットに変換して出力する。
- (void)muxVideoSample:(CMSampleBufferRef)sampleBuffer;

/// AAC オーディオサンプルを TS パケットに変換して出力する。
- (void)muxAudioSample:(CMSampleBufferRef)sampleBuffer;

/// PAT + PMT を明示的に送出する。
- (void)emitPATAndPMT;

/// 新規クライアント接続時に送る初期データ (PAT+PMT+最新キーフレーム)。
- (NSData *)bootstrapData;

@end
