#import <Foundation/Foundation.h>

@interface ControlServer : NSObject

- (instancetype)initWithSocketPath:(NSString *)path;
- (BOOL)start;
- (void)stop;

@end
