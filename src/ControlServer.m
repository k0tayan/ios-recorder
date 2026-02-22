#import "ControlServer.h"
#import "RecorderCore.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>

@interface ControlServer ()
@property (nonatomic) NSString *socketPath;
@property (nonatomic) int serverFd;
@property (nonatomic) BOOL running;
@property (nonatomic) dispatch_queue_t serverQueue;
@end

@implementation ControlServer

- (instancetype)initWithSocketPath:(NSString *)path {
    self = [super init];
    if (self) {
        _socketPath = [path copy];
        _serverFd = -1;
        _running = NO;
        _serverQueue = dispatch_queue_create("com.local.iosrecorder.controlserver", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)start {
    // Remove existing socket file
    unlink(self.socketPath.UTF8String);

    // Create socket
    self.serverFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (self.serverFd < 0) {
        NSLog(@"[Recorder] Failed to create socket: %s", strerror(errno));
        return NO;
    }

    // Bind
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, self.socketPath.UTF8String, sizeof(addr.sun_path) - 1);

    if (bind(self.serverFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[Recorder] Failed to bind socket: %s", strerror(errno));
        close(self.serverFd);
        self.serverFd = -1;
        return NO;
    }

    // Listen
    if (listen(self.serverFd, 5) < 0) {
        NSLog(@"[Recorder] Failed to listen on socket: %s", strerror(errno));
        close(self.serverFd);
        self.serverFd = -1;
        return NO;
    }

    // Set permissions so any process can connect
    chmod(self.socketPath.UTF8String, 0777);

    self.running = YES;
    NSLog(@"[Recorder] ControlServer listening on %@", self.socketPath);

    // Accept loop in background
    dispatch_async(self.serverQueue, ^{
        [self _acceptLoop];
    });

    return YES;
}

- (void)_acceptLoop {
    while (self.running) {
        struct sockaddr_un clientAddr;
        socklen_t clientLen = sizeof(clientAddr);

        int clientFd = accept(self.serverFd, (struct sockaddr *)&clientAddr, &clientLen);
        if (clientFd < 0) {
            if (self.running) {
                NSLog(@"[Recorder] Accept error: %s", strerror(errno));
            }
            continue;
        }

        // Handle client in a new dispatch
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self _handleClient:clientFd];
        });
    }
}

- (void)_handleClient:(int)clientFd {
    char buffer[1024];
    ssize_t bytesRead = read(clientFd, buffer, sizeof(buffer) - 1);
    if (bytesRead <= 0) {
        close(clientFd);
        return;
    }

    buffer[bytesRead] = '\0';

    // Strip trailing newline
    char *newline = strchr(buffer, '\n');
    if (newline) *newline = '\0';
    newline = strchr(buffer, '\r');
    if (newline) *newline = '\0';

    NSString *command = [NSString stringWithUTF8String:buffer];
    NSLog(@"[Recorder] Received command: %@", command);

    NSString *response = [self _processCommand:command];

    // Send response
    NSString *responseWithNewline = [response stringByAppendingString:@"\n"];
    const char *responseStr = responseWithNewline.UTF8String;
    write(clientFd, responseStr, strlen(responseStr));

    close(clientFd);
}

- (NSString *)_processCommand:(NSString *)command {
    RecorderCore *recorder = [RecorderCore shared];
    NSString *upperCommand = [command uppercaseString];

    if ([upperCommand isEqualToString:@"START"]) {
        if (recorder.isRecording) {
            return @"ERR Already recording";
        }
        [recorder startRecording];
        return @"OK";
    }

    if ([upperCommand isEqualToString:@"STOP"]) {
        if (!recorder.isRecording) {
            return @"ERR Not recording";
        }
        __block NSString *result = nil;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [recorder stopRecordingWithCompletion:^(NSString *outputPath) {
            if (outputPath) {
                result = [NSString stringWithFormat:@"OK %@", outputPath];
            } else {
                result = @"ERR Recording failed";
            }
            dispatch_semaphore_signal(semaphore);
        }];
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
        return result ?: @"ERR Timeout";
    }

    if ([upperCommand isEqualToString:@"STATUS"]) {
        return recorder.isRecording ? @"OK recording" : @"OK idle";
    }

    if ([upperCommand isEqualToString:@"CLEANUP"]) {
        NSDictionary *result = [recorder cleanupTempFiles];
        int deleted = [result[@"deleted"] intValue];
        unsigned long long freed = [result[@"freedBytes"] unsignedLongLongValue];
        return [NSString stringWithFormat:@"OK deleted=%d freed=%llu", deleted, freed];
    }

    if ([upperCommand hasPrefix:@"SET "]) {
        NSString *params = [command substringFromIndex:4];
        return [self _processSetCommand:params];
    }

    return @"ERR Unknown command";
}

- (NSString *)_processSetCommand:(NSString *)params {
    RecorderCore *recorder = [RecorderCore shared];
    NSArray *parts = [params componentsSeparatedByString:@"="];

    if (parts.count != 2) {
        return @"ERR Invalid SET syntax (use key=value)";
    }

    NSString *key = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *value = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if ([key isEqualToString:@"fps"]) {
        int fps = [value intValue];
        if (fps < 1 || fps > 120) return @"ERR FPS must be 1-120";
        recorder.targetFPS = fps;
        return [NSString stringWithFormat:@"OK fps=%d", fps];
    }

    if ([key isEqualToString:@"bitrate"]) {
        int bitrate = [value intValue];
        if (bitrate < 100000) return @"ERR Bitrate too low";
        recorder.videoBitrate = bitrate;
        return [NSString stringWithFormat:@"OK bitrate=%d", bitrate];
    }

    if ([key isEqualToString:@"resolution"]) {
        NSArray *dims = [value componentsSeparatedByString:@"x"];
        if (dims.count != 2) return @"ERR Use WxH format";
        int w = [dims[0] intValue];
        int h = [dims[1] intValue];
        if (w < 100 || h < 100) return @"ERR Resolution too small";
        recorder.maxCaptureSize = CGSizeMake(w, h);
        return [NSString stringWithFormat:@"OK resolution=%dx%d", w, h];
    }

    return @"ERR Unknown parameter";
}

- (void)stop {
    self.running = NO;
    if (self.serverFd >= 0) {
        close(self.serverFd);
        self.serverFd = -1;
    }
    unlink(self.socketPath.UTF8String);
    NSLog(@"[Recorder] ControlServer stopped");
}

- (void)dealloc {
    [self stop];
}

@end
