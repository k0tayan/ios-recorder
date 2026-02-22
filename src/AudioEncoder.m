#import "AudioEncoder.h"

@interface AudioEncoder ()
@property (nonatomic) AudioConverterRef converter;
@property (nonatomic) Float64 sampleRate;
@property (nonatomic) UInt32 channels;
@property (nonatomic) UInt32 bitrate;
@property (nonatomic) dispatch_queue_t encoderQueue;
@property (nonatomic) BOOL isRunning;

// Ring buffer for accumulating PCM samples
@property (nonatomic) uint8_t *ringBuffer;
@property (nonatomic) UInt32 ringBufferSize;
@property (nonatomic) UInt32 ringBufferReadPos;
@property (nonatomic) UInt32 ringBufferWritePos;
@property (nonatomic) UInt32 ringBufferAvailable;

// PTS tracking with gap-aware re-anchoring
@property (nonatomic) int64_t totalSamplesEncoded;
@property (nonatomic) int64_t totalSamplesReceived;
@property (nonatomic) CMTime ptsAnchor;         // wall-clock time at anchor point
@property (nonatomic) int64_t samplesAtAnchor;  // totalSamplesEncoded at anchor
@property (nonatomic) BOOL ptsAnchorSet;

// Temporary buffer for encoder input
@property (nonatomic) uint8_t *encoderInputBuffer;
@property (nonatomic) UInt32 encoderInputBufferSize;

// Output buffer
@property (nonatomic) uint8_t *aacOutputBuffer;
@property (nonatomic) UInt32 aacOutputBufferSize;

// Audio format descriptions
@property (nonatomic) AudioStreamBasicDescription inputFormat;
@property (nonatomic) AudioStreamBasicDescription outputFormat;
@property (nonatomic) CMAudioFormatDescriptionRef audioFormatDescription;
@end

// Callback for AudioConverter to request input data
static OSStatus audioConverterInputDataProc(AudioConverterRef inAudioConverter,
                                             UInt32 *ioNumberDataPackets,
                                             AudioBufferList *ioData,
                                             AudioStreamPacketDescription **outDataPacketDescription,
                                             void *inUserData) {
    AudioEncoder *encoder = (__bridge AudioEncoder *)inUserData;

    UInt32 requestedFrames = *ioNumberDataPackets;
    UInt32 bytesPerFrame = encoder.channels * sizeof(Float32);
    UInt32 requestedBytes = requestedFrames * bytesPerFrame;

    if (encoder.ringBufferAvailable < requestedBytes) {
        *ioNumberDataPackets = 0;
        return -1;
    }

    // Copy from ring buffer to encoder input buffer
    UInt32 bytesToCopy = requestedBytes;
    UInt32 readPos = encoder.ringBufferReadPos;

    if (readPos + bytesToCopy <= encoder.ringBufferSize) {
        memcpy(encoder.encoderInputBuffer, encoder.ringBuffer + readPos, bytesToCopy);
    } else {
        UInt32 firstPart = encoder.ringBufferSize - readPos;
        memcpy(encoder.encoderInputBuffer, encoder.ringBuffer + readPos, firstPart);
        memcpy(encoder.encoderInputBuffer + firstPart, encoder.ringBuffer, bytesToCopy - firstPart);
    }

    encoder.ringBufferReadPos = (readPos + bytesToCopy) % encoder.ringBufferSize;
    encoder.ringBufferAvailable -= bytesToCopy;

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mData = encoder.encoderInputBuffer;
    ioData->mBuffers[0].mDataByteSize = bytesToCopy;
    ioData->mBuffers[0].mNumberChannels = encoder.channels;

    *ioNumberDataPackets = requestedFrames;
    return noErr;
}

@implementation AudioEncoder

- (instancetype)initWithSampleRate:(Float64)sampleRate
                          channels:(UInt32)channels
                           bitrate:(UInt32)bitrate {
    self = [super init];
    if (self) {
        _sampleRate = sampleRate;
        _channels = channels;
        _bitrate = bitrate;
        _isRunning = NO;
        _totalSamplesEncoded = 0;
        _encoderQueue = dispatch_queue_create("com.local.iosrecorder.audioencoder", DISPATCH_QUEUE_SERIAL);

        // Ring buffer: hold up to 1 second of audio
        UInt32 bytesPerFrame = channels * sizeof(Float32);
        _ringBufferSize = (UInt32)(sampleRate * bytesPerFrame * 2);  // 2 seconds buffer
        _ringBuffer = (uint8_t *)calloc(1, _ringBufferSize);
        _ringBufferReadPos = 0;
        _ringBufferWritePos = 0;
        _ringBufferAvailable = 0;

        // Encoder input buffer: 1024 frames (AAC frame size)
        _encoderInputBufferSize = 1024 * bytesPerFrame;
        _encoderInputBuffer = (uint8_t *)malloc(_encoderInputBufferSize);

        // AAC output buffer
        _aacOutputBufferSize = 1024 * channels * 2;  // generous output buffer
        _aacOutputBuffer = (uint8_t *)malloc(_aacOutputBufferSize);
    }
    return self;
}

- (BOOL)start {
    // Input format: interleaved Float32 PCM
    _inputFormat = (AudioStreamBasicDescription){
        .mFormatID = kAudioFormatLinearPCM,
        .mSampleRate = self.sampleRate,
        .mChannelsPerFrame = self.channels,
        .mBitsPerChannel = 32,
        .mBytesPerFrame = self.channels * sizeof(Float32),
        .mBytesPerPacket = self.channels * sizeof(Float32),
        .mFramesPerPacket = 1,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    };

    // Output format: AAC
    _outputFormat = (AudioStreamBasicDescription){
        .mFormatID = kAudioFormatMPEG4AAC,
        .mSampleRate = self.sampleRate,
        .mChannelsPerFrame = self.channels,
        .mFramesPerPacket = 1024,
    };

    OSStatus status = AudioConverterNew(&_inputFormat, &_outputFormat, &_converter);
    if (status != noErr) {
        NSLog(@"[Recorder] Failed to create AudioConverter: %d", (int)status);
        return NO;
    }

    // Set bitrate
    UInt32 outputBitrate = self.bitrate;
    AudioConverterSetProperty(self.converter, kAudioConverterEncodeBitRate,
                               sizeof(outputBitrate), &outputBitrate);

    // Get the actual output format (may have been adjusted)
    UInt32 size = sizeof(_outputFormat);
    AudioConverterGetProperty(self.converter, kAudioConverterCurrentOutputStreamDescription,
                               &size, &_outputFormat);

    // Get magic cookie (AudioSpecificConfig) from the converter
    UInt32 cookieSize = 0;
    void *cookie = NULL;
    OSStatus cookieStatus = AudioConverterGetPropertyInfo(
        _converter, kAudioConverterCompressionMagicCookie, &cookieSize, NULL);
    if (cookieStatus == noErr && cookieSize > 0) {
        cookie = malloc(cookieSize);
        AudioConverterGetProperty(_converter, kAudioConverterCompressionMagicCookie,
                                   &cookieSize, cookie);
    }

    // Create audio format description with magic cookie for proper esds box
    CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &_outputFormat,
                                    0, NULL,
                                    cookieSize, cookie,
                                    NULL, &_audioFormatDescription);
    if (cookie) free(cookie);

    self.isRunning = YES;
    self.totalSamplesEncoded = 0;
    self.totalSamplesReceived = 0;
    self.ptsAnchorSet = NO;
    self.ringBufferReadPos = 0;
    self.ringBufferWritePos = 0;
    self.ringBufferAvailable = 0;

    NSLog(@"[Recorder] AudioEncoder started: %.0fHz, %uch, %ubps",
          self.sampleRate, (unsigned int)self.channels, (unsigned int)self.bitrate);
    return YES;
}

- (void)reconfigureWithSampleRate:(Float64)sampleRate channels:(UInt32)channels {
    dispatch_sync(self.encoderQueue, ^{
        if (sampleRate == self.sampleRate && channels == self.channels) return;

        NSLog(@"[Recorder] AudioEncoder reconfiguring: %.0fHz/%uch → %.0fHz/%uch",
              self.sampleRate, (unsigned)self.channels, sampleRate, (unsigned)channels);

        // Encode remaining data with old settings
        [self _encodeAvailableFrames];

        // Dispose old converter
        if (self.converter) {
            AudioConverterDispose(self.converter);
            self.converter = NULL;
        }
        if (self.audioFormatDescription) {
            CFRelease(self.audioFormatDescription);
            self.audioFormatDescription = NULL;
        }

        // Update format
        self.sampleRate = sampleRate;
        self.channels = channels;

        // Reallocate ring buffer for new format
        UInt32 bytesPerFrame = channels * sizeof(Float32);
        self.ringBufferSize = (UInt32)(sampleRate * bytesPerFrame * 2);
        free(self.ringBuffer);
        self.ringBuffer = (uint8_t *)calloc(1, self.ringBufferSize);
        self.ringBufferReadPos = 0;
        self.ringBufferWritePos = 0;
        self.ringBufferAvailable = 0;

        self.encoderInputBufferSize = 1024 * bytesPerFrame;
        free(self.encoderInputBuffer);
        self.encoderInputBuffer = (uint8_t *)malloc(self.encoderInputBufferSize);

        self.aacOutputBufferSize = 1024 * channels * 2;
        free(self.aacOutputBuffer);
        self.aacOutputBuffer = (uint8_t *)malloc(self.aacOutputBufferSize);

        // Create new converter
        _inputFormat = (AudioStreamBasicDescription){
            .mFormatID = kAudioFormatLinearPCM,
            .mSampleRate = sampleRate,
            .mChannelsPerFrame = channels,
            .mBitsPerChannel = 32,
            .mBytesPerFrame = channels * sizeof(Float32),
            .mBytesPerPacket = channels * sizeof(Float32),
            .mFramesPerPacket = 1,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        };
        _outputFormat = (AudioStreamBasicDescription){
            .mFormatID = kAudioFormatMPEG4AAC,
            .mSampleRate = sampleRate,
            .mChannelsPerFrame = channels,
            .mFramesPerPacket = 1024,
        };

        OSStatus status = AudioConverterNew(&_inputFormat, &_outputFormat, &_converter);
        if (status != noErr) {
            NSLog(@"[Recorder] Failed to recreate AudioConverter: %d", (int)status);
            return;
        }

        UInt32 outputBitrate = self.bitrate;
        AudioConverterSetProperty(self.converter, kAudioConverterEncodeBitRate,
                                   sizeof(outputBitrate), &outputBitrate);

        UInt32 size = sizeof(_outputFormat);
        AudioConverterGetProperty(self.converter, kAudioConverterCurrentOutputStreamDescription,
                                   &size, &_outputFormat);

        UInt32 cookieSize = 0;
        void *cookie = NULL;
        OSStatus cookieStatus = AudioConverterGetPropertyInfo(
            _converter, kAudioConverterCompressionMagicCookie, &cookieSize, NULL);
        if (cookieStatus == noErr && cookieSize > 0) {
            cookie = malloc(cookieSize);
            AudioConverterGetProperty(_converter, kAudioConverterCompressionMagicCookie,
                                       &cookieSize, cookie);
        }
        CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &_outputFormat,
                                        0, NULL, cookieSize, cookie,
                                        NULL, &_audioFormatDescription);
        if (cookie) free(cookie);

        // Re-anchor PTS
        self.ptsAnchorSet = NO;

        NSLog(@"[Recorder] AudioEncoder reconfigured: %.0fHz, %uch",
              sampleRate, (unsigned)channels);
    });
}

- (void)encodePCMBuffer:(AudioBufferList *)bufferList
              numFrames:(UInt32)numFrames
              timestamp:(CMTime)timestamp {
    if (!self.isRunning) return;

    // Gap-aware PTS anchoring:
    // Check if there's a significant gap between expected and actual timestamp.
    // This happens when AudioUnit is reconfigured (e.g. UI → rhythm game transition).
    if (!self.ptsAnchorSet) {
        self.ptsAnchor = timestamp;
        self.samplesAtAnchor = self.totalSamplesEncoded;
        self.ptsAnchorSet = YES;
        NSLog(@"[Recorder] Audio PTS anchor set: %.3fs", CMTimeGetSeconds(timestamp));
    } else {
        // Where we expect to be based on continuous sample counting
        CMTime expectedTime = CMTimeAdd(self.ptsAnchor,
            CMTimeMake(self.totalSamplesReceived - self.samplesAtAnchor,
                       (int32_t)self.sampleRate));
        double drift = CMTimeGetSeconds(CMTimeSubtract(timestamp, expectedTime));
        if (fabs(drift) > 0.05) {  // 50ms gap threshold
            // Re-anchor: account for pending samples in ring buffer
            int64_t pendingSamples = self.totalSamplesReceived - self.totalSamplesEncoded;
            CMTime pendingDuration = CMTimeMake(pendingSamples, (int32_t)self.sampleRate);
            self.ptsAnchor = CMTimeSubtract(timestamp, pendingDuration);
            self.samplesAtAnchor = self.totalSamplesEncoded;
            NSLog(@"[Recorder] Audio PTS re-anchored (drift=%.1fms): %.3fs",
                  drift * 1000, CMTimeGetSeconds(timestamp));
        }
    }
    self.totalSamplesReceived += numFrames;

    // dispatch_sync: caller's bufferList must stay valid until data is copied
    // into our ring buffer.  The drain thread blocks here briefly while the
    // encoder queue copies + encodes — this is intentional.
    dispatch_sync(self.encoderQueue, ^{
        [self _enqueuePCM:bufferList numFrames:numFrames];
        [self _encodeAvailableFrames];
    });
}

- (void)_enqueuePCM:(AudioBufferList *)bufferList numFrames:(UInt32)numFrames {
    UInt32 bytesPerFrame = self.channels * sizeof(Float32);

    if (bufferList->mNumberBuffers == 1) {
        // Interleaved: copy directly
        UInt32 bytesToWrite = numFrames * bytesPerFrame;
        [self _writeToRingBuffer:bufferList->mBuffers[0].mData length:bytesToWrite];
    } else {
        // Non-interleaved: interleave the data
        UInt32 bytesPerSample = sizeof(Float32);
        for (UInt32 frame = 0; frame < numFrames; frame++) {
            for (UInt32 ch = 0; ch < bufferList->mNumberBuffers && ch < self.channels; ch++) {
                Float32 *src = (Float32 *)bufferList->mBuffers[ch].mData;
                [self _writeToRingBuffer:&src[frame] length:bytesPerSample];
            }
        }
    }
}

- (void)_writeToRingBuffer:(const void *)data length:(UInt32)length {
    if (self.ringBufferAvailable + length > self.ringBufferSize) {
        // Buffer overflow - drop oldest data
        NSLog(@"[Recorder] Audio ring buffer overflow, dropping data");
        return;
    }

    const uint8_t *src = (const uint8_t *)data;
    UInt32 writePos = self.ringBufferWritePos;

    if (writePos + length <= self.ringBufferSize) {
        memcpy(self.ringBuffer + writePos, src, length);
    } else {
        UInt32 firstPart = self.ringBufferSize - writePos;
        memcpy(self.ringBuffer + writePos, src, firstPart);
        memcpy(self.ringBuffer, src + firstPart, length - firstPart);
    }

    self.ringBufferWritePos = (writePos + length) % self.ringBufferSize;
    self.ringBufferAvailable += length;
}

- (void)_encodeAvailableFrames {
    UInt32 bytesPerFrame = self.channels * sizeof(Float32);
    UInt32 bytesPerAACFrame = 1024 * bytesPerFrame;

    while (self.ringBufferAvailable >= bytesPerAACFrame) {
        // Prepare output buffer
        AudioBufferList outputBufferList;
        outputBufferList.mNumberBuffers = 1;
        outputBufferList.mBuffers[0].mNumberChannels = self.channels;
        outputBufferList.mBuffers[0].mDataByteSize = self.aacOutputBufferSize;
        outputBufferList.mBuffers[0].mData = self.aacOutputBuffer;

        UInt32 outputPackets = 1;
        AudioStreamPacketDescription outputPacketDesc;

        OSStatus status = AudioConverterFillComplexBuffer(
            self.converter,
            audioConverterInputDataProc,
            (__bridge void *)self,
            &outputPackets,
            &outputBufferList,
            &outputPacketDesc
        );

        if (status != noErr || outputPackets == 0) {
            break;
        }

        // Create CMSampleBuffer from encoded AAC data
        // PTS = anchor + (samplesEncoded - samplesAtAnchor) / sampleRate
        CMTime sampleOffset = CMTimeMake(self.totalSamplesEncoded - self.samplesAtAnchor,
                                          (int32_t)self.sampleRate);
        CMTime pts = CMTimeAdd(self.ptsAnchor, sampleOffset);
        self.totalSamplesEncoded += 1024;

        CMSampleBufferRef sampleBuffer = NULL;
        CMBlockBufferRef blockBuffer = NULL;

        status = CMBlockBufferCreateWithMemoryBlock(
            kCFAllocatorDefault,
            NULL,
            outputBufferList.mBuffers[0].mDataByteSize,
            kCFAllocatorDefault,
            NULL, 0,
            outputBufferList.mBuffers[0].mDataByteSize,
            0,
            &blockBuffer
        );

        if (status != noErr) continue;

        status = CMBlockBufferReplaceDataBytes(
            outputBufferList.mBuffers[0].mData,
            blockBuffer, 0,
            outputBufferList.mBuffers[0].mDataByteSize
        );

        if (status != noErr) {
            CFRelease(blockBuffer);
            continue;
        }

        CMSampleTimingInfo timing = {
            .duration = CMTimeMake(1024, (int32_t)self.sampleRate),
            .presentationTimeStamp = pts,
            .decodeTimeStamp = kCMTimeInvalid
        };

        size_t sampleSize = outputBufferList.mBuffers[0].mDataByteSize;

        status = CMSampleBufferCreate(
            kCFAllocatorDefault,
            blockBuffer,
            true,
            NULL, NULL,
            self.audioFormatDescription,
            1,
            1, &timing,
            1, &sampleSize,
            &sampleBuffer
        );

        CFRelease(blockBuffer);

        if (status == noErr && sampleBuffer && self.onEncodedSample) {
            self.onEncodedSample(sampleBuffer);
        }

        if (sampleBuffer) {
            CFRelease(sampleBuffer);
        }
    }
}

- (void)stopWithCompletion:(void (^)(void))completion {
    if (!self.isRunning) {
        if (completion) completion();
        return;
    }

    self.isRunning = NO;

    dispatch_async(self.encoderQueue, ^{
        // Encode any remaining samples
        [self _encodeAvailableFrames];

        if (self.converter) {
            AudioConverterDispose(self.converter);
            self.converter = NULL;
        }

        if (self.audioFormatDescription) {
            CFRelease(self.audioFormatDescription);
            self.audioFormatDescription = NULL;
        }

        NSLog(@"[Recorder] AudioEncoder stopped");
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    });
}

- (void)dealloc {
    if (_converter) AudioConverterDispose(_converter);
    if (_audioFormatDescription) CFRelease(_audioFormatDescription);
    free(_ringBuffer);
    free(_encoderInputBuffer);
    free(_aacOutputBuffer);
}

@end
