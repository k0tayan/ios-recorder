#ifndef RecorderLog_h
#define RecorderLog_h

#import <Foundation/Foundation.h>
#include <stdarg.h>
#include <sys/time.h>

// Macro to declare a file-scoped debug logging function.
// Each invocation creates a static FILE* and a printf-like function
// that writes timestamped lines to the specified log file in tmp/.
//
// Usage:  DEFINE_RECLOG(reclog, "iosrecorder_audio.log")
//         reclog("hello %d", 42);

#define DEFINE_RECLOG(funcname, filename)                                       \
static FILE *s_##funcname##_logfile = NULL;                                     \
__attribute__((format(printf, 1, 2)))                                           \
static void funcname(const char *fmt, ...) {                                    \
    if (!s_##funcname##_logfile) {                                              \
        NSString *tmp = [NSTemporaryDirectory()                                 \
            stringByAppendingPathComponent:@filename];                          \
        s_##funcname##_logfile = fopen(tmp.UTF8String, "a");                    \
        if (s_##funcname##_logfile) setlinebuf(s_##funcname##_logfile);         \
    }                                                                           \
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
