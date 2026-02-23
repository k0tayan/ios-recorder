#ifndef RecorderLog_h
#define RecorderLog_h

#import <Foundation/Foundation.h>
#include <stdarg.h>
#include <sys/time.h>

// ファイルスコープのデバッグログ関数を定義するマクロ。
// 呼び出しごとに static FILE* と printf 風関数を生成し、
// tmp/ 内の指定ログファイルにタイムスタンプ付きで書き出す。
// dispatch_once でファイルオープンをスレッドセーフに保護。
//
// 使い方:  DEFINE_RECLOG(reclog, "iosrecorder_audio.log")
//          reclog("hello %d", 42);

#define DEFINE_RECLOG(funcname, filename)                                       \
static FILE *s_##funcname##_logfile = NULL;                                     \
static dispatch_once_t s_##funcname##_once;                                     \
__attribute__((format(printf, 1, 2)))                                           \
static void funcname(const char *fmt, ...) {                                    \
    dispatch_once(&s_##funcname##_once, ^{                                      \
        NSString *tmp = [NSTemporaryDirectory()                                 \
            stringByAppendingPathComponent:@filename];                          \
        s_##funcname##_logfile = fopen(tmp.UTF8String, "a");                    \
        if (s_##funcname##_logfile) setlinebuf(s_##funcname##_logfile);         \
    });                                                                         \
    if (!s_##funcname##_logfile) return;                                         \
    struct timeval tv; gettimeofday(&tv, NULL);                                 \
    struct tm t; localtime_r(&tv.tv_sec, &t);                                   \
    fprintf(s_##funcname##_logfile, "%02d:%02d:%02d.%03d ",                     \
            t.tm_hour, t.tm_min, t.tm_sec, (int)(tv.tv_usec/1000));            \
    va_list ap; va_start(ap, fmt);                                              \
    vfprintf(s_##funcname##_logfile, fmt, ap);                                  \
    va_end(ap);                                                                 \
    fprintf(s_##funcname##_logfile, "\n");                                       \
}

#endif /* RecorderLog_h */
