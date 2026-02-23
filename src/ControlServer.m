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
    // SIGPIPE を無視 (クライアント切断時の write でクラッシュ防止)
    signal(SIGPIPE, SIG_IGN);

    // ソケット作成
    self.serverFd = socket(AF_INET, SOCK_STREAM, 0);
    if (self.serverFd < 0) {
        NSLog(@"[Recorder] Failed to create socket: %s", strerror(errno));
        return NO;
    }

    // ポート再利用を許可 (アプリ再起動後の "address already in use" 回避)
    int reuse = 1;
    setsockopt(self.serverFd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    // バインド
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

    // リスン
    if (listen(self.serverFd, 5) < 0) {
        NSLog(@"[Recorder] Failed to listen on port %u: %s", self.port, strerror(errno));
        close(self.serverFd);
        self.serverFd = -1;
        return NO;
    }

    self.running = YES;
    NSLog(@"[Recorder] ControlServer listening on port %u", self.port);

    // バックグラウンドで accept ループ
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

        // 新しい dispatch でクライアントを処理
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self _handleClient:clientFd];
        });
    }
}

- (void)_handleClient:(int)clientFd {
    // TCP は部分読み取りを返す可能性があるため、デリミタ (\n) まで読むループ
    char buffer[1024];
    ssize_t total = 0;
    while (total < (ssize_t)(sizeof(buffer) - 1)) {
        ssize_t n = read(clientFd, buffer + total, sizeof(buffer) - 1 - total);
        if (n <= 0) break;
        total += n;
        if (memchr(buffer, '\n', total)) break;  // デリミタ到着
    }
    if (total <= 0) {
        close(clientFd);
        return;
    }

    buffer[total] = '\0';

    // 末尾の改行を除去
    char *newline = strchr(buffer, '\n');
    if (newline) *newline = '\0';
    newline = strchr(buffer, '\r');
    if (newline) *newline = '\0';

    NSString *command = [NSString stringWithUTF8String:buffer];
    NSLog(@"[Recorder] Received command: %@", command);

    NSString *upperCommand = [command uppercaseString];

    // PULL コマンド: バイナリファイル転送 (別処理)
    if ([upperCommand hasPrefix:@"PULL "]) {
        NSString *path = [command substringFromIndex:5];
        [self _handlePull:path clientFd:clientFd];
        return;
    }

    // LIST コマンド: 録画ファイル一覧
    if ([upperCommand isEqualToString:@"LIST"]) {
        NSString *response = [self _handleList];
        [self _writeResponse:response toClientFd:clientFd];
        close(clientFd);
        return;
    }

    NSString *response = [self _processCommand:command];
    [self _writeResponse:response toClientFd:clientFd];

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
        long timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
        if (timedOut != 0) {
            // タイムアウト: 録画状態を強制リセットして半端なリソースをリークさせない
            NSLog(@"[Recorder] STOP timed out, forcing recording state reset");
            [recorder forceResetRecordingState];
            return @"ERR Timeout (recording state reset)";
        }
        return result ?: @"ERR Unknown";
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

- (void)_writeResponse:(NSString *)response toClientFd:(int)clientFd {
    NSString *responseWithNewline = [response stringByAppendingString:@"\n"];
    const char *bytes = responseWithNewline.UTF8String;
    size_t remaining = strlen(bytes);
    while (remaining > 0) {
        ssize_t written = write(clientFd, bytes, remaining);
        if (written <= 0) break;
        bytes += written;
        remaining -= written;
    }
}

#pragma mark - PULL コマンド

- (void)_handlePull:(NSString *)path clientFd:(int)clientFd {
    NSFileManager *fm = [NSFileManager defaultManager];

    // パストラバーサル対策: NSTemporaryDirectory 配下のファイルのみ許可
    NSString *resolvedPath = path.stringByStandardizingPath;
    NSString *tmpDir = NSTemporaryDirectory().stringByStandardizingPath;
    if (![resolvedPath hasPrefix:tmpDir]) {
        NSString *err = @"ERR Access denied\n";
        write(clientFd, err.UTF8String, strlen(err.UTF8String));
        close(clientFd);
        return;
    }

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

    // ヘッダー送信: OK <サイズ>\n
    NSString *header = [NSString stringWithFormat:@"OK %llu\n", fileSize];
    const char *headerStr = header.UTF8String;
    if (write(clientFd, headerStr, strlen(headerStr)) < 0) {
        [fh closeFile];
        close(clientFd);
        return;
    }

    // 64KB チャンクでファイルをストリーミング
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

    // 転送成功後にファイルを削除
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSLog(@"[Recorder] PULL: deleted %@", path);
}

#pragma mark - LIST コマンド

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
