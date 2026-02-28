#import "StreamServer.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>

@interface StreamServer ()
@property (nonatomic) uint16_t port;
@property (nonatomic) int serverFd;
@property (nonatomic) int clientFd;
@property (nonatomic, readwrite) BOOL isRunning;
@property (nonatomic) dispatch_queue_t acceptQueue;
@property (nonatomic) dispatch_queue_t sendQueue;
@end

@implementation StreamServer

- (instancetype)initWithPort:(uint16_t)port {
    self = [super init];
    if (self) {
        _port = port;
        _serverFd = -1;
        _clientFd = -1;
        _isRunning = NO;
        _acceptQueue = dispatch_queue_create("com.local.iosrecorder.stream.accept", DISPATCH_QUEUE_SERIAL);
        _sendQueue = dispatch_queue_create("com.local.iosrecorder.stream.send", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)hasClient {
    __block BOOL result;
    dispatch_sync(self.sendQueue, ^{
        result = (self.clientFd >= 0);
    });
    return result;
}

#pragma mark - Start / Stop

- (BOOL)start {
    signal(SIGPIPE, SIG_IGN);

    self.serverFd = socket(AF_INET, SOCK_STREAM, 0);
    if (self.serverFd < 0) {
        NSLog(@"[StreamServer] Failed to create socket: %s", strerror(errno));
        return NO;
    }

    int reuse = 1;
    setsockopt(self.serverFd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(self.port);

    if (bind(self.serverFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[StreamServer] Failed to bind on port %u: %s", self.port, strerror(errno));
        close(self.serverFd);
        self.serverFd = -1;
        return NO;
    }

    if (listen(self.serverFd, 1) < 0) {
        NSLog(@"[StreamServer] Failed to listen on port %u: %s", self.port, strerror(errno));
        close(self.serverFd);
        self.serverFd = -1;
        return NO;
    }

    self.isRunning = YES;
    NSLog(@"[StreamServer] Listening on port %u", self.port);

    dispatch_async(self.acceptQueue, ^{
        [self _acceptLoop];
    });

    return YES;
}

- (void)stop {
    self.isRunning = NO;

    // サーバーソケットを閉じて accept() を中断
    if (self.serverFd >= 0) {
        close(self.serverFd);
        self.serverFd = -1;
    }

    // クライアント切断
    dispatch_sync(self.sendQueue, ^{
        [self _disconnectClientLocked];
    });

    NSLog(@"[StreamServer] Stopped");
}

#pragma mark - Accept ループ

- (void)_acceptLoop {
    while (self.isRunning) {
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);

        int newFd = accept(self.serverFd, (struct sockaddr *)&clientAddr, &clientLen);
        if (newFd < 0) {
            if (self.isRunning) {
                NSLog(@"[StreamServer] Accept error: %s", strerror(errno));
            }
            break;
        }

        char addrStr[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &clientAddr.sin_addr, addrStr, sizeof(addrStr));
        NSLog(@"[StreamServer] Client connected: %s:%d", addrStr, ntohs(clientAddr.sin_port));

        // ソケットオプション設定
        int flag = 1;
        setsockopt(newFd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));

        // 送信タイムアウト 100ms (バックプレッシャー)
        struct timeval sndTimeout = { .tv_sec = 0, .tv_usec = 100000 };
        setsockopt(newFd, SOL_SOCKET, SO_SNDTIMEO, &sndTimeout, sizeof(sndTimeout));

        // 送信バッファ 2MB
        int sndbuf = 2 * 1024 * 1024;
        setsockopt(newFd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

        // 既存クライアントを切断して新規クライアントに切り替え
        dispatch_sync(self.sendQueue, ^{
            [self _disconnectClientLocked];
            self.clientFd = newFd;
        });

        // ブートストラップデータ送信
        if (self.bootstrapProvider) {
            NSData *bootstrap = self.bootstrapProvider();
            if (bootstrap.length > 0) {
                [self sendData:bootstrap.bytes length:bootstrap.length];
                NSLog(@"[StreamServer] Sent bootstrap: %lu bytes", (unsigned long)bootstrap.length);
            }
        }
    }
}

#pragma mark - データ送信

- (void)sendData:(const uint8_t *)data length:(size_t)length {
    if (length == 0) return;

    // データをコピーしてキャプチャ
    NSData *dataCopy = [[NSData alloc] initWithBytes:data length:length];

    dispatch_async(self.sendQueue, ^{
        if (self.clientFd < 0) return;

        const uint8_t *bytes = dataCopy.bytes;
        size_t remaining = dataCopy.length;

        while (remaining > 0) {
            ssize_t written = write(self.clientFd, bytes, remaining);
            if (written <= 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // 送信タイムアウト → フレームドロップ
                    NSLog(@"[StreamServer] Send timeout, dropping %zu bytes", remaining);
                } else {
                    // 接続切断
                    NSLog(@"[StreamServer] Client disconnected: %s", strerror(errno));
                    [self _disconnectClientLocked];
                }
                return;
            }
            bytes += written;
            remaining -= written;
        }
    });
}

#pragma mark - Private

- (void)_disconnectClientLocked {
    // sendQueue 上で呼ぶこと
    if (self.clientFd >= 0) {
        close(self.clientFd);
        self.clientFd = -1;
        NSLog(@"[StreamServer] Client disconnected");
    }
}

- (void)dealloc {
    [self stop];
}

@end
