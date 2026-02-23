#import <Foundation/Foundation.h>

@interface ControlServer : NSObject

- (instancetype)initWithPort:(uint16_t)port;
- (BOOL)start;

@end
