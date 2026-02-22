#import <CoreMedia/CoreMedia.h>

/// Resolves Unity il2cpp time functions and provides a unified
/// timeline for both video and audio PTS.
@interface UnityTime : NSObject

/// Resolve il2cpp icalls. Call after the game has started.
+ (BOOL)setup;
+ (BOOL)isAvailable;

/// Mark recording start on the Unity timeline.
+ (void)markRecordingStart;

/// Video PTS — call from the Metal capture thread.
+ (CMTime)videoPTS;

/// Audio PTS — converts an audio host-time to the Unity timeline.
+ (CMTime)audioPTSForHostTime:(uint64_t)hostTime;

@end
