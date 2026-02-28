#import <Foundation/Foundation.h>

@interface StreamServer : NSObject

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) BOOL hasClient;

/// 新規クライアント接続時に送るブートストラップデータを返すブロック。
@property (nonatomic, copy) NSData *(^bootstrapProvider)(void);

- (instancetype)initWithPort:(uint16_t)port;
- (BOOL)start;
- (void)stop;
- (void)sendData:(const uint8_t *)data length:(size_t)length;

@end
