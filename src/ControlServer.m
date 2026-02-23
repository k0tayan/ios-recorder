#import "ControlServer.h"
#import "RecorderCore.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

@interface ControlServer ()
@property (nonatomic) uint16_t port;
@property (nonatomic) int serverFd;
@property (nonatomic) BOOL running;
@property (nonatomic) dispatch_queue_t serverQueue;
@end

@implementation ControlServer

- (instancetype)initWithPort:(uint16_t)port {
    self = [super init];
    if (self) {
        _port = port;
        _serverFd = -1;
        _running = NO;
        _serverQueue = dispatch_queue_create("com.local.iosrecorder.controlserver", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)start {
    // Ignore SIGPIPE to prevent crash when client disconnects during write
    signal(SIGPIPE, SIG_IGN);

    // Create socket
    self.serverFd = socket(AF_INET, SOCK_STREAM, 0);
    if (self.serverFd < 0) {
        NSLog(@"[Recorder] Failed to create socket: %s", strerror(errno));
        return NO;
    }

    // Allow port reuse (avoid "address already in use" after app restart)
    int reuse = 1;
    setsockopt(self.serverFd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    // Bind
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(self.port);

    if (bind(self.serverFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[Recorder] Failed to bind socket on port %u: %s", self.port, strerror(errno));
        close(self.serverFd);
        self.serverFd = -1;
        return NO;
    }

    // Listen
    if (listen(self.serverFd, 5) < 0) {
        NSLog(@"[Recorder] Failed to listen on port %u: %s", self.port, strerror(errno));
        close(self.serverFd);
        self.serverFd = -1;
        return NO;
    }

    self.running = YES;
    NSLog(@"[Recorder] ControlServer listening on port %u", self.port);

    // Accept loop in background
    dispatch_async(self.serverQueue, ^{
        [self _acceptLoop];
    });

    return YES;
}

- (void)_acceptLoop {
    while (self.running) {
        struct sockaddr_in clientAddr;
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

    NSString *upperCommand = [command uppercaseString];

    // PULL command: binary file transfer (handled separately)
    if ([upperCommand hasPrefix:@"PULL "]) {
        NSString *path = [command substringFromIndex:5];
        [self _handlePull:path clientFd:clientFd];
        return;
    }

    // LIST command: enumerate recordings
    if ([upperCommand isEqualToString:@"LIST"]) {
        NSString *response = [self _handleList];
        NSString *responseWithNewline = [response stringByAppendingString:@"\n"];
        const char *responseStr = responseWithNewline.UTF8String;
        write(clientFd, responseStr, strlen(responseStr));
        close(clientFd);
        return;
    }

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

#pragma mark - PULL command

- (void)_handlePull:(NSString *)path clientFd:(int)clientFd {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:path]) {
        NSString *err = @"ERR File not found\n";
        write(clientFd, err.UTF8String, strlen(err.UTF8String));
        close(clientFd);
        return;
    }

    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    unsigned long long fileSize = [attrs fileSize];

    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) {
        NSString *err = @"ERR Cannot open file\n";
        write(clientFd, err.UTF8String, strlen(err.UTF8String));
        close(clientFd);
        return;
    }

    // Send header: OK <size>\n
    NSString *header = [NSString stringWithFormat:@"OK %llu\n", fileSize];
    const char *headerStr = header.UTF8String;
    if (write(clientFd, headerStr, strlen(headerStr)) < 0) {
        [fh closeFile];
        close(clientFd);
        return;
    }

    // Stream file in 64KB chunks
    static const NSUInteger chunkSize = 65536;
    unsigned long long sent = 0;

    while (sent < fileSize) {
        @autoreleasepool {
            NSData *chunk = [fh readDataOfLength:chunkSize];
            if (chunk.length == 0) break;

            const uint8_t *bytes = chunk.bytes;
            NSUInteger remaining = chunk.length;

            while (remaining > 0) {
                ssize_t written = write(clientFd, bytes, remaining);
                if (written <= 0) {
                    NSLog(@"[Recorder] PULL: write error at %llu/%llu", sent, fileSize);
                    [fh closeFile];
                    close(clientFd);
                    return;
                }
                bytes += written;
                remaining -= written;
                sent += written;
            }
        }
    }

    NSLog(@"[Recorder] PULL: sent %llu bytes for %@", sent, path);
    [fh closeFile];
    close(clientFd);

    // Delete file after successful transfer
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSLog(@"[Recorder] PULL: deleted %@", path);
}

#pragma mark - LIST command

- (NSString *)_handleList {
    NSString *tmpDir = NSTemporaryDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:tmpDir error:nil];

    if (!files || files.count == 0) {
        return @"OK";
    }

    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *file in files) {
        if (![file hasPrefix:@"recording_"] || ![file hasSuffix:@".mp4"]) continue;
        NSString *fullPath = [tmpDir stringByAppendingPathComponent:file];
        NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
        unsigned long long size = [attrs fileSize];
        [entries addObject:[NSString stringWithFormat:@"%@:%llu", file, size]];
    }

    return [NSString stringWithFormat:@"OK %@", [entries componentsJoinedByString:@" "]];
}

@end
