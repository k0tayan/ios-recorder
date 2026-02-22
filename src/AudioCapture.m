#import "AudioCapture.h"
#import <dlfcn.h>
#import <substrate.h>
#include <stdatomic.h>
#include <sys/time.h>
#include <mach/mach_time.h>

// ─── File-based debug logging ────────────────────────────────────────
static FILE *sLogFile = NULL;

static void reclog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void reclog(const char *fmt, ...) {
    if (!sLogFile) {
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iosrecorder_audio.log"];
        sLogFile = fopen(tmp.UTF8String, "a");
        if (sLogFile) setlinebuf(sLogFile);
    }
    if (!sLogFile) return;
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm t; localtime_r(&tv.tv_sec, &t);
    fprintf(sLogFile, "%02d:%02d:%02d.%03d ", t.tm_hour, t.tm_min, t.tm_sec, (int)(tv.tv_usec/1000));
    va_list ap; va_start(ap, fmt); vfprintf(sLogFile, fmt, ap); va_end(ap);
    fprintf(sLogFile, "\n");
}

// ─── Lock-free SPSC ring buffer (RT thread → drain thread) ─────────
#define RING_SLOT_COUNT   64
#define SLOT_MAX_BYTES    32768          // 2048 frames × 4 ch × sizeof(Float32)
#define SLOT_MAX_BUFS     2

typedef struct {
    uint8_t  data[SLOT_MAX_BYTES];
    UInt32   bufByteSize[SLOT_MAX_BUFS];
    UInt32   bufChannels[SLOT_MAX_BUFS];
    UInt32   numBuffers;
    UInt32   numFrames;
    uint64_t hostTime;
    uint64_t captureTime;            // mach_absolute_time() at callback invocation
    UInt32   formatGen;              // format generation tag (detects reconfiguration)
} CaptureSlot;

static CaptureSlot  sSlots[RING_SLOT_COUNT];
static atomic_int   sWriteIdx;           // RT produces, drain consumes
static atomic_int   sReadIdx;            // drain produces, RT consumes

// Flags readable from the RT thread without any ObjC
static atomic_bool  sCapturing;
static CMTime       sRecStartTime;
static atomic_bool  sRecStartTimeSet;
static atomic_uint  sFormatGeneration;   // incremented on each AudioUnit reconfiguration

// Per-AudioUnit original callback storage (supports multiple hooked units)
#define MAX_HOOKED_UNITS 8

typedef struct {
    AURenderCallback origCallback;
    void            *origRefCon;
    AudioUnit        unit;
} HookedUnitInfo;

static HookedUnitInfo sHookedUnits[MAX_HOOKED_UNITS];
static int            sHookedUnitCount = 0;
static AudioUnit      sCapturedUnit    = NULL;   // only capture audio from this unit
static atomic_uint_fast64_t sCallbackCount;        // total render callback invocations
static atomic_uint_fast64_t sCapturedCount;        // callbacks that passed the filter
static atomic_uint_fast64_t sCapturedFrames;       // total audio frames captured
static atomic_uint_fast64_t sSkippedNullCbCount;   // callbacks skipped due to NULL origCallback

// ─── RT-safe render callback wrapper ────────────────────────────────
//
// Guarantees:  NO ObjC message sends, NO malloc/free, NO dispatch,
//              NO locks — only memcpy + atomic load/store.

static OSStatus renderCallbackWrapper(void *inRefCon,
                                       AudioUnitRenderActionFlags *ioActionFlags,
                                       const AudioTimeStamp *inTimeStamp,
                                       UInt32 inBusNumber,
                                       UInt32 inNumberFrames,
                                       AudioBufferList *ioData) {
    HookedUnitInfo *info = (HookedUnitInfo *)inRefCon;

    // 1. Call the correct original render callback for THIS AudioUnit
    OSStatus status = noErr;
    if (info && info->origCallback) {
        status = info->origCallback(info->origRefCon, ioActionFlags, inTimeStamp,
                                     inBusNumber, inNumberFrames, ioData);
    } else {
        // Original callback is NULL (FMOD reconfiguration in progress).
        // Fill with silence for speaker output, but do NOT capture — the buffer
        // contains undefined data and encoding it shifts all subsequent audio PTS.
        if (ioData) {
            for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
                memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
            }
        }
        if (atomic_load_explicit(&sCapturing, memory_order_relaxed)) {
            atomic_fetch_add_explicit(&sSkippedNullCbCount, 1, memory_order_relaxed);
        }
        return noErr;
    }

    // 2. Only capture from the designated unit (skip others)
    if (!info || info->unit != sCapturedUnit) return status;

    // 3. Early exit if not capturing or error
    if (!atomic_load_explicit(&sCapturing, memory_order_acquire)) return status;
    if (status != noErr || !ioData) return status;

    // 4. Stats (relaxed — for diagnostics only)
    atomic_fetch_add_explicit(&sCallbackCount, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&sCapturedCount, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&sCapturedFrames, inNumberFrames, memory_order_relaxed);

    // 3. Check ring buffer space (single producer — no CAS needed)
    int wi   = atomic_load_explicit(&sWriteIdx, memory_order_relaxed);
    int next = (wi + 1) % RING_SLOT_COUNT;
    if (next == atomic_load_explicit(&sReadIdx, memory_order_acquire)) {
        return status;  // ring full — drop this callback
    }

    // 4. Copy every AudioBuffer into the slot
    CaptureSlot *slot = &sSlots[wi];
    UInt32 numBufs = ioData->mNumberBuffers;
    if (numBufs > SLOT_MAX_BUFS) numBufs = SLOT_MAX_BUFS;

    UInt32 off = 0;
    for (UInt32 i = 0; i < numBufs; i++) {
        UInt32 sz = ioData->mBuffers[i].mDataByteSize;
        if (off + sz > SLOT_MAX_BYTES) { numBufs = i; break; }
        memcpy(slot->data + off, ioData->mBuffers[i].mData, sz);
        slot->bufByteSize[i] = sz;
        slot->bufChannels[i] = ioData->mBuffers[i].mNumberChannels;
        off += sz;
    }
    slot->numBuffers  = numBufs;
    slot->numFrames   = inNumberFrames;
    slot->hostTime    = inTimeStamp->mHostTime;
    slot->captureTime = mach_absolute_time();
    slot->formatGen   = atomic_load_explicit(&sFormatGeneration, memory_order_relaxed);

    // 5. Release-store: slot contents are visible before the index update
    atomic_store_explicit(&sWriteIdx, next, memory_order_release);

    return status;
}

// ─── AudioUnitSetProperty hook ──────────────────────────────────────
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID,
                                              AudioUnitScope, AudioUnitElement,
                                              const void *, UInt32);

static OSStatus hooked_AudioUnitSetProperty(AudioUnit inUnit,
                                             AudioUnitPropertyID inID,
                                             AudioUnitScope inScope,
                                             AudioUnitElement inElement,
                                             const void *inData,
                                             UInt32 inDataSize) {
    if (inID == kAudioUnitProperty_SetRenderCallback &&
        inScope == kAudioUnitScope_Input) {
        const AURenderCallbackStruct *cs = (const AURenderCallbackStruct *)inData;
        if (cs) {
            // Find or create per-unit info slot
            HookedUnitInfo *info = NULL;
            for (int i = 0; i < sHookedUnitCount; i++) {
                if (sHookedUnits[i].unit == inUnit) {
                    info = &sHookedUnits[i];
                    break;
                }
            }
            if (!info && sHookedUnitCount < MAX_HOOKED_UNITS) {
                info = &sHookedUnits[sHookedUnitCount++];
                info->unit = inUnit;
            }
            if (!info) {
                NSLog(@"[Recorder] Too many AudioUnits hooked, skipping unit=%p", inUnit);
                return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement,
                                                  inData, inDataSize);
            }

            info->origCallback = cs->inputProc;
            info->origRefCon   = cs->inputProcRefCon;
            sCapturedUnit = inUnit;   // always capture from the most recent unit

            // Read format now (safe — we're in game thread, not RT)
            AudioStreamBasicDescription asbd = {0};
            UInt32 asbdSize = sizeof(asbd);
            OSStatus fmtSt = AudioUnitGetProperty(inUnit,
                kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                inElement, &asbd, &asbdSize);
            if (fmtSt != noErr) {
                AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output, 0, &asbd, &asbdSize);
            }
            NSLog(@"[Recorder] Intercepted AudioUnit callback (unit=%p elem=%u) fmt=%.0fHz/%uch [%d units hooked]",
                  inUnit, (unsigned)inElement, asbd.mSampleRate, (unsigned)asbd.mChannelsPerFrame,
                  sHookedUnitCount);
            bool capturing = atomic_load_explicit(&sCapturing, memory_order_relaxed);
            reclog("HOOK unit=%p elem=%u fmt=%.0fHz/%uch cb=%p hooked=%d captureUnit=%p%s",
                   inUnit, (unsigned)inElement, asbd.mSampleRate, (unsigned)asbd.mChannelsPerFrame,
                   cs->inputProc, sHookedUnitCount, sCapturedUnit,
                   capturing ? " [DURING_CAPTURE]" : "");

            // Bump format generation — render callback will tag new slots
            atomic_fetch_add_explicit(&sFormatGeneration, 1, memory_order_release);

            AURenderCallbackStruct wrapper = {
                .inputProc       = renderCallbackWrapper,
                .inputProcRefCon = info,   // pass per-unit info to the wrapper
            };
            return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement,
                                              &wrapper, sizeof(wrapper));
        }
    }
    return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement,
                                      inData, inDataSize);
}

// ─── AudioCapture implementation ────────────────────────────────────
@interface AudioCapture ()
@property (nonatomic, readwrite) Float64 sampleRate;
@property (nonatomic, readwrite) UInt32  channels;
@property (nonatomic) dispatch_source_t  drainTimer;
@property (nonatomic) dispatch_queue_t   drainQueue;
@property (nonatomic) UInt32 currentFormatGen;  // last processed format generation
@property (nonatomic) uint64_t drainSlotCount;   // total slots drained (for periodic logging)
@property (nonatomic) uint64_t drainFrameCount;  // total frames drained
@end

@implementation AudioCapture

+ (instancetype)shared {
    static AudioCapture *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AudioCapture alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sampleRate = 48000.0;
        _channels   = 2;
        _capturing  = NO;
    }
    return self;
}

- (BOOL)installHook {
    NSLog(@"[Recorder] Installing AudioUnit hooks...");
    void *handle = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
                          RTLD_LAZY);
    if (!handle) {
        NSLog(@"[Recorder] Failed to open AudioToolbox");
        return NO;
    }

    void *sym = dlsym(handle, "AudioUnitSetProperty");
    if (!sym) {
        NSLog(@"[Recorder] Failed to find AudioUnitSetProperty");
        return NO;
    }

    MSHookFunction(sym,
                   (void *)hooked_AudioUnitSetProperty,
                   (void **)&orig_AudioUnitSetProperty);
    NSLog(@"[Recorder] AudioUnitSetProperty hooked successfully");
    return YES;
}

- (void)removeHook {
    self.capturing = NO;
    self.delegate  = nil;
}

#pragma mark - Capturing state

- (void)setCapturing:(BOOL)capturing {
    if (capturing == _capturing) return;
    _capturing = capturing;

    if (capturing) {
        // Reset ring buffer before enabling
        // NOTE: sRecStartTimeSet is NOT reset here — RecorderCore sets the
        // recording start time BEFORE enabling capture to avoid a race where
        // slots arrive before the start time is set (which would yield PTS=0).
        atomic_store_explicit(&sWriteIdx, 0, memory_order_relaxed);
        atomic_store_explicit(&sReadIdx,  0, memory_order_relaxed);
        atomic_store_explicit(&sCallbackCount, 0, memory_order_relaxed);
        atomic_store_explicit(&sCapturedCount, 0, memory_order_relaxed);
        atomic_store_explicit(&sCapturedFrames, 0, memory_order_relaxed);
        atomic_store_explicit(&sSkippedNullCbCount, 0, memory_order_relaxed);
        self.drainSlotCount = 0;
        self.drainFrameCount = 0;
        // Force format re-detection on first slot by setting to impossible value
        self.currentFormatGen = UINT32_MAX;
        reclog("START capturing=YES captureUnit=%p hookedUnits=%d sampleRate=%.0f ch=%u",
               sCapturedUnit, sHookedUnitCount, self.sampleRate, (unsigned)self.channels);
        [self _startDrainTimer];
        atomic_store_explicit(&sCapturing, true, memory_order_release);
    } else {
        atomic_store_explicit(&sCapturing, false, memory_order_release);
        [self _stopDrainTimer];   // flushes remaining slots
        reclog("STOP callbacks=%llu captured=%llu frames=%llu skippedNull=%llu",
               (unsigned long long)atomic_load(&sCallbackCount),
               (unsigned long long)atomic_load(&sCapturedCount),
               (unsigned long long)atomic_load(&sCapturedFrames),
               (unsigned long long)atomic_load(&sSkippedNullCbCount));
    }
}

- (void)setRecordingStartTime:(CMTime)startTime {
    sRecStartTime = startTime;
    atomic_store_explicit(&sRecStartTimeSet, true, memory_order_release);
}

- (void)updateAudioFormat {
    if (sCapturedUnit) {
        AudioStreamBasicDescription asbd;
        UInt32 size = sizeof(asbd);
        // Read Input scope first (render callback format), fall back to Output
        OSStatus st = AudioUnitGetProperty(sCapturedUnit,
                                            kAudioUnitProperty_StreamFormat,
                                            kAudioUnitScope_Input,
                                            0, &asbd, &size);
        if (st != noErr) {
            st = AudioUnitGetProperty(sCapturedUnit,
                                       kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output,
                                       0, &asbd, &size);
        }
        if (st == noErr) {
            self.sampleRate = asbd.mSampleRate;
            self.channels   = asbd.mChannelsPerFrame;
            NSLog(@"[Recorder] Audio format: %.0f Hz, %u channels",
                  self.sampleRate, (unsigned int)self.channels);
        }
    }
}

#pragma mark - Drain timer

- (void)_startDrainTimer {
    self.drainQueue = dispatch_queue_create(
        "com.local.iosrecorder.audiodrain", DISPATCH_QUEUE_SERIAL);

    self.drainTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.drainQueue);
    dispatch_source_set_timer(self.drainTimer,
                              DISPATCH_TIME_NOW,
                              2 * NSEC_PER_MSEC,   // 2 ms interval
                              0);                    // no leeway

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.drainTimer, ^{
        [weakSelf _drainRingBuffer];
    });
    dispatch_resume(self.drainTimer);
}

- (void)_stopDrainTimer {
    if (self.drainTimer) {
        dispatch_source_cancel(self.drainTimer);
        self.drainTimer = nil;
    }
    if (self.drainQueue) {
        // Wait for any in-flight handler, then flush remaining slots
        dispatch_sync(self.drainQueue, ^{
            [self _drainRingBuffer];
        });
        self.drainQueue = nil;
    }
}

- (void)_drainRingBuffer {
    int ri = atomic_load_explicit(&sReadIdx, memory_order_relaxed);
    int wi = atomic_load_explicit(&sWriteIdx, memory_order_acquire);

    while (ri != wi) {
        CaptureSlot *slot = &sSlots[ri];

        // Per-slot format generation check — reconfigure BEFORE processing new-format data
        if (slot->formatGen != self.currentFormatGen) {
            Float64 oldRate = self.sampleRate;
            UInt32  oldCh   = self.channels;
            [self updateAudioFormat];
            reclog("FORMATGEN slot#%llu gen %u→%u fmt %.0fHz/%uch→%.0fHz/%uch",
                   (unsigned long long)self.drainSlotCount,
                   (unsigned)self.currentFormatGen, (unsigned)slot->formatGen,
                   oldRate, (unsigned)oldCh, self.sampleRate, (unsigned)self.channels);
            self.currentFormatGen = slot->formatGen;
            if (self.sampleRate != oldRate || self.channels != oldCh) {
                NSLog(@"[Recorder] Audio format changed at slot: %.0fHz/%uch → %.0fHz/%uch",
                      oldRate, (unsigned)oldCh, self.sampleRate, (unsigned)self.channels);
                reclog("FORMAT_CHANGED! Triggering AudioEncoder reconfigure");
                id<AudioCaptureDelegate> del = self.delegate;
                if ([del respondsToSelector:@selector(audioCaptureFormatDidChange:sampleRate:channels:)]) {
                    [del audioCaptureFormatDidChange:self
                                         sampleRate:self.sampleRate
                                           channels:self.channels];
                }
            }
        }

        // Compute PTS from wall-clock time (mach_absolute_time at callback),
        // matching the video timebase. slot->hostTime is the speaker playout
        // time and can be ~1s in the future, causing audio-video desync.
        CMTime hostCMTime = CMClockMakeHostTimeFromSystemUnits(slot->captureTime);
        CMTime pts;
        if (atomic_load_explicit(&sRecStartTimeSet, memory_order_acquire)) {
            pts = CMTimeSubtract(hostCMTime, sRecStartTime);
        } else {
            pts = kCMTimeZero;
        }

        // Reconstruct AudioBufferList on the stack (points into slot data)
        struct {
            UInt32      mNumberBuffers;
            AudioBuffer mBuffers[SLOT_MAX_BUFS];
        } stackABL;

        stackABL.mNumberBuffers = slot->numBuffers;
        UInt32 off = 0;
        for (UInt32 i = 0; i < slot->numBuffers; i++) {
            stackABL.mBuffers[i].mNumberChannels = slot->bufChannels[i];
            stackABL.mBuffers[i].mDataByteSize   = slot->bufByteSize[i];
            stackABL.mBuffers[i].mData           = slot->data + off;
            off += slot->bufByteSize[i];
        }

        // Deliver synchronously — delegate MUST consume data before returning
        id<AudioCaptureDelegate> del = self.delegate;
        if (del) {
            [del audioCapture:self
                didCaptureAudioBuffer:(AudioBufferList *)&stackABL
                           numFrames:slot->numFrames
                           timestamp:pts];
        }

        self.drainSlotCount++;
        self.drainFrameCount += slot->numFrames;

        // Diagnostic: log first 20 slots to measure hostTime vs captureTime offset
        if (self.drainSlotCount <= 20) {
            CMTime origHostCMTime = CMClockMakeHostTimeFromSystemUnits(slot->hostTime);
            double hostSec = CMTimeGetSeconds(origHostCMTime);
            double captureSec = CMTimeGetSeconds(hostCMTime);  // hostCMTime is now captureTime-based
            double offsetSec = hostSec - captureSec;  // positive = hostTime is in the future
            reclog("SLOT#%llu hostTime=%.4f captureTime=%.4f offset=%.4fs pts=%.3f frames=%u",
                   (unsigned long long)self.drainSlotCount,
                   hostSec, captureSec, offsetSec,
                   CMTimeGetSeconds(pts), slot->numFrames);
        }
        // Log every ~1s worth of audio (48000/512 ≈ 94 callbacks)
        if (self.drainSlotCount % 100 == 0) {
            CMTime origHostCMTime = CMClockMakeHostTimeFromSystemUnits(slot->hostTime);
            double hostSec = CMTimeGetSeconds(origHostCMTime);
            double captureSec = CMTimeGetSeconds(hostCMTime);
            double hostVsCapture = hostSec - captureSec;  // positive = hostTime is in the future

            reclog("DRAIN slot#%llu totalFrames=%llu pts=%.3f hostVsCapture=%.4f numFrames=%u",
                   (unsigned long long)self.drainSlotCount,
                   (unsigned long long)self.drainFrameCount,
                   CMTimeGetSeconds(pts), hostVsCapture, slot->numFrames);
        }

        // Advance read index (release-store so the RT producer sees free space)
        ri = (ri + 1) % RING_SLOT_COUNT;
        atomic_store_explicit(&sReadIdx, ri, memory_order_release);
    }
}

@end
