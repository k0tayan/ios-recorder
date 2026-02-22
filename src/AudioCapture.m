#import "AudioCapture.h"
#import "UnityTime.h"
#import <dlfcn.h>
#import <substrate.h>
#include <stdatomic.h>

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
} CaptureSlot;

static CaptureSlot  sSlots[RING_SLOT_COUNT];
static atomic_int   sWriteIdx;           // RT produces, drain consumes
static atomic_int   sReadIdx;            // drain produces, RT consumes

// Flags readable from the RT thread without any ObjC
static atomic_bool  sCapturing;
static CMTime       sRecStartTime;
static atomic_bool  sRecStartTimeSet;
static atomic_bool  sUnitReconfigured;

// Original render callback saved by the hook
static AURenderCallback sOrigCallback    = NULL;
static void            *sOrigRefCon      = NULL;
static AudioUnit        sCapturedUnit    = NULL;

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
    // 1. Call the original render callback
    OSStatus status = noErr;
    AURenderCallback orig = sOrigCallback;
    if (orig) {
        status = orig(sOrigRefCon, ioActionFlags, inTimeStamp,
                      inBusNumber, inNumberFrames, ioData);
    }

    // 2. Early exit if not capturing or error
    if (!atomic_load_explicit(&sCapturing, memory_order_acquire)) return status;
    if (status != noErr || !ioData) return status;

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
    slot->numBuffers = numBufs;
    slot->numFrames  = inNumberFrames;
    slot->hostTime   = inTimeStamp->mHostTime;

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
            NSLog(@"[Recorder] Intercepted AudioUnit render callback setup (unit=%p)", inUnit);
            sOrigCallback = cs->inputProc;
            sOrigRefCon   = cs->inputProcRefCon;
            sCapturedUnit = inUnit;
            atomic_store_explicit(&sUnitReconfigured, true, memory_order_release);

            AURenderCallbackStruct wrapper = {
                .inputProc       = renderCallbackWrapper,
                .inputProcRefCon = NULL,
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
        _sampleRate = 44100.0;
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
        // Reset ring buffer + start-time flag before enabling
        atomic_store_explicit(&sRecStartTimeSet, false, memory_order_relaxed);
        atomic_store_explicit(&sWriteIdx, 0, memory_order_relaxed);
        atomic_store_explicit(&sReadIdx,  0, memory_order_relaxed);
        [self _startDrainTimer];
        atomic_store_explicit(&sCapturing, true, memory_order_release);
    } else {
        atomic_store_explicit(&sCapturing, false, memory_order_release);
        [self _stopDrainTimer];   // flushes remaining slots
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
        OSStatus st = AudioUnitGetProperty(sCapturedUnit,
                                            kAudioUnitProperty_StreamFormat,
                                            kAudioUnitScope_Output,
                                            0, &asbd, &size);
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
    // Check for AudioUnit reconfiguration (sample rate / channel change)
    if (atomic_exchange_explicit(&sUnitReconfigured, false, memory_order_acquire)) {
        Float64 oldRate = self.sampleRate;
        UInt32  oldCh   = self.channels;
        [self updateAudioFormat];
        if (self.sampleRate != oldRate || self.channels != oldCh) {
            NSLog(@"[Recorder] Audio format changed: %.0fHz/%uch → %.0fHz/%uch",
                  oldRate, (unsigned)oldCh, self.sampleRate, (unsigned)self.channels);
            id<AudioCaptureDelegate> del = self.delegate;
            if ([del respondsToSelector:@selector(audioCaptureFormatDidChange:sampleRate:channels:)]) {
                [del audioCaptureFormatDidChange:self
                                     sampleRate:self.sampleRate
                                       channels:self.channels];
            }
        }
    }

    int ri = atomic_load_explicit(&sReadIdx, memory_order_relaxed);
    int wi = atomic_load_explicit(&sWriteIdx, memory_order_acquire);

    while (ri != wi) {
        CaptureSlot *slot = &sSlots[ri];

        // Compute PTS using Unity timeline (preferred) or wall-clock fallback
        CMTime pts = [UnityTime audioPTSForHostTime:slot->hostTime];
        if (CMTIME_IS_INVALID(pts)) {
            CMTime hostTime = CMClockMakeHostTimeFromSystemUnits(slot->hostTime);
            if (atomic_load_explicit(&sRecStartTimeSet, memory_order_acquire)) {
                pts = CMTimeSubtract(hostTime, sRecStartTime);
            } else {
                pts = kCMTimeZero;
            }
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

        // Advance read index (release-store so the RT producer sees free space)
        ri = (ri + 1) % RING_SLOT_COUNT;
        atomic_store_explicit(&sReadIdx, ri, memory_order_release);
    }
}

@end
