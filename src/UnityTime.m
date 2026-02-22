#import "UnityTime.h"
#import <dlfcn.h>

// il2cpp resolved function pointers
static double (*sGetUnscaledTime)(void) = NULL;

// Recording start reference
static double sUnityStartTime = 0;
static double sHostStartTimeSecs = 0;

// Host-to-Unity correlation (updated every video frame)
static double sCorrelUnity = 0;
static double sCorrelHost  = 0;

@implementation UnityTime

+ (BOOL)setup {
    typedef void *(*resolve_icall_t)(const char *);
    resolve_icall_t resolve = (resolve_icall_t)dlsym(RTLD_DEFAULT, "il2cpp_resolve_icall");
    if (!resolve) {
        NSLog(@"[Recorder] il2cpp_resolve_icall not found — Unity time unavailable");
        return NO;
    }

    // Try double version first (Unity 2020.2+), then float fallback
    sGetUnscaledTime = (double (*)(void))resolve("UnityEngine.Time::get_unscaledTimeAsDouble");
    if (!sGetUnscaledTime) {
        sGetUnscaledTime = (double (*)(void))resolve("UnityEngine.Time::get_realtimeSinceStartupAsDouble");
    }
    if (!sGetUnscaledTime) {
        NSLog(@"[Recorder] Unity time icalls not resolved");
        return NO;
    }

    NSLog(@"[Recorder] Unity time ready (unscaledTime@%p)", sGetUnscaledTime);
    return YES;
}

+ (BOOL)isAvailable {
    return sGetUnscaledTime != NULL;
}

+ (void)markRecordingStart {
    if (sGetUnscaledTime) {
        sUnityStartTime = sGetUnscaledTime();
    }
    sHostStartTimeSecs = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
    sCorrelUnity = sUnityStartTime;
    sCorrelHost  = sHostStartTimeSecs;
}

+ (CMTime)videoPTS {
    if (!sGetUnscaledTime) return kCMTimeInvalid;

    double now = sGetUnscaledTime();
    double elapsed = now - sUnityStartTime;

    // Update correlation for audio use
    sCorrelHost  = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
    sCorrelUnity = now;

    return CMTimeMakeWithSeconds(elapsed, 600000);
}

+ (CMTime)audioPTSForHostTime:(uint64_t)hostTime {
    // Convert audio callback's mach host time to seconds
    CMTime hostCMTime = CMClockMakeHostTimeFromSystemUnits(hostTime);
    double hostSecs = CMTimeGetSeconds(hostCMTime);

    if (sGetUnscaledTime) {
        // Estimate Unity time at the audio callback using correlation:
        // unityTimeAtAudio = correlUnity + (audioHostSecs - correlHost)
        double unityEstimate = sCorrelUnity + (hostSecs - sCorrelHost);
        double elapsed = unityEstimate - sUnityStartTime;
        return CMTimeMakeWithSeconds(elapsed, 600000);
    }

    // Fallback: wall-clock based
    double elapsed = hostSecs - sHostStartTimeSecs;
    return CMTimeMakeWithSeconds(elapsed, 600000);
}

@end
