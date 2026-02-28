#import "TSMuxer.h"
#import <VideoToolbox/VideoToolbox.h>
#import <mach/mach_time.h>

// TS パケット定数
static const int kTSPacketSize = 188;
static const uint8_t kTSSyncByte = 0x47;

// PID 割り当て
static const uint16_t kPID_PAT   = 0x0000;
static const uint16_t kPID_PMT   = 0x1000;
static const uint16_t kPID_Video = 0x0100;
static const uint16_t kPID_Audio = 0x0101;

// Stream type
static const uint8_t kStreamType_HEVC = 0x24;
static const uint8_t kStreamType_AAC  = 0x0F;

// PES stream ID
static const uint8_t kPES_StreamID_Video = 0xE0;
static const uint8_t kPES_StreamID_Audio = 0xC0;

// PCR / PTS タイムベース: 90kHz
static const int64_t kTimeScale90k = 90000;

#pragma mark - CRC32/MPEG-2

static uint32_t sCRC32Table[256];
static dispatch_once_t sCRC32Once;

static void _initCRC32Table(void) {
    dispatch_once(&sCRC32Once, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t crc = i << 24;
            for (int j = 0; j < 8; j++) {
                if (crc & 0x80000000) {
                    crc = (crc << 1) ^ 0x04C11DB7;
                } else {
                    crc <<= 1;
                }
            }
            sCRC32Table[i] = crc;
        }
    });
}

static uint32_t _crc32MPEG2(const uint8_t *data, size_t length) {
    _initCRC32Table();
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < length; i++) {
        crc = (crc << 8) ^ sCRC32Table[((crc >> 24) ^ data[i]) & 0xFF];
    }
    return crc;
}

#pragma mark -

@interface TSMuxer ()
@property (nonatomic) dispatch_queue_t muxerQueue;
@property (nonatomic) uint8_t videoContinuityCounter;
@property (nonatomic) uint8_t audioContinuityCounter;
@property (nonatomic) uint8_t patContinuityCounter;
@property (nonatomic) uint8_t pmtContinuityCounter;
@property (nonatomic) uint64_t lastPATEmitTime;  // mach_absolute_time
@property (nonatomic) NSMutableData *bootstrapCache;  // PAT+PMT+最新キーフレーム
@end

@implementation TSMuxer

- (instancetype)init {
    self = [super init];
    if (self) {
        _muxerQueue = dispatch_queue_create("com.local.iosrecorder.tsmuxer", DISPATCH_QUEUE_SERIAL);
        _videoContinuityCounter = 0;
        _audioContinuityCounter = 0;
        _patContinuityCounter = 0;
        _pmtContinuityCounter = 0;
        _lastPATEmitTime = 0;
        _bootstrapCache = [NSMutableData data];
    }
    return self;
}

#pragma mark - Public

- (void)muxVideoSample:(CMSampleBufferRef)sampleBuffer {
    CFRetain(sampleBuffer);
    dispatch_async(self.muxerQueue, ^{
        [self _muxVideoSampleInternal:sampleBuffer];
        CFRelease(sampleBuffer);
    });
}

- (void)muxAudioSample:(CMSampleBufferRef)sampleBuffer {
    CFRetain(sampleBuffer);
    dispatch_async(self.muxerQueue, ^{
        [self _muxAudioSampleInternal:sampleBuffer];
        CFRelease(sampleBuffer);
    });
}

- (void)emitPATAndPMT {
    dispatch_async(self.muxerQueue, ^{
        [self _emitPATAndPMTInternal];
    });
}

- (NSData *)bootstrapData {
    __block NSData *data;
    dispatch_sync(self.muxerQueue, ^{
        data = [self.bootstrapCache copy];
    });
    return data;
}

#pragma mark - PAT / PMT 生成

- (void)_emitPATAndPMTInternal {
    NSMutableData *output = [NSMutableData dataWithCapacity:kTSPacketSize * 2];

    // --- PAT ---
    [self _buildPAT:output];

    // --- PMT ---
    [self _buildPMT:output];

    self.lastPATEmitTime = mach_absolute_time();

    if (self.onTSPackets) {
        self.onTSPackets(output.bytes, output.length);
    }
}

- (void)_buildPAT:(NSMutableData *)output {
    uint8_t pkt[kTSPacketSize];
    memset(pkt, 0xFF, kTSPacketSize);

    // TS ヘッダ (4 bytes)
    pkt[0] = kTSSyncByte;
    pkt[1] = 0x40 | ((kPID_PAT >> 8) & 0x1F);  // payload_unit_start=1
    pkt[2] = kPID_PAT & 0xFF;
    pkt[3] = 0x10 | (self.patContinuityCounter & 0x0F);  // payload only
    self.patContinuityCounter = (self.patContinuityCounter + 1) & 0x0F;

    // Pointer field (1 byte)
    pkt[4] = 0x00;

    // PAT セクション
    uint8_t *section = &pkt[5];
    section[0] = 0x00;  // table_id = PAT
    // section_length = 13 (5 header + 4 program + 4 CRC)
    section[1] = 0xB0;  // section_syntax_indicator=1
    section[2] = 13;     // section_length
    section[3] = 0x00;  // transport_stream_id (高)
    section[4] = 0x01;  // transport_stream_id (低)
    section[5] = 0xC1;  // version=0, current_next=1
    section[6] = 0x00;  // section_number
    section[7] = 0x00;  // last_section_number
    // Program 1 → PMT PID
    section[8]  = 0x00;  // program_number (高)
    section[9]  = 0x01;  // program_number (低)
    section[10] = 0xE0 | ((kPID_PMT >> 8) & 0x1F);
    section[11] = kPID_PMT & 0xFF;
    // CRC32
    uint32_t crc = _crc32MPEG2(section, 12);
    section[12] = (crc >> 24) & 0xFF;
    section[13] = (crc >> 16) & 0xFF;
    section[14] = (crc >> 8) & 0xFF;
    section[15] = crc & 0xFF;

    [output appendBytes:pkt length:kTSPacketSize];
}

- (void)_buildPMT:(NSMutableData *)output {
    uint8_t pkt[kTSPacketSize];
    memset(pkt, 0xFF, kTSPacketSize);

    // TS ヘッダ (4 bytes)
    pkt[0] = kTSSyncByte;
    pkt[1] = 0x40 | ((kPID_PMT >> 8) & 0x1F);  // payload_unit_start=1
    pkt[2] = kPID_PMT & 0xFF;
    pkt[3] = 0x10 | (self.pmtContinuityCounter & 0x0F);
    self.pmtContinuityCounter = (self.pmtContinuityCounter + 1) & 0x0F;

    // Pointer field
    pkt[4] = 0x00;

    // PMT セクション
    uint8_t *section = &pkt[5];
    section[0] = 0x02;  // table_id = PMT

    // section_length を後で埋める (section[1..2])
    section[3] = 0x00;  // program_number (高)
    section[4] = 0x01;  // program_number (低)
    section[5] = 0xC1;  // version=0, current_next=1
    section[6] = 0x00;  // section_number
    section[7] = 0x00;  // last_section_number
    // PCR_PID = Video PID
    section[8] = 0xE0 | ((kPID_Video >> 8) & 0x1F);
    section[9] = kPID_Video & 0xFF;
    // program_info_length = 0
    section[10] = 0xF0;
    section[11] = 0x00;

    int offset = 12;

    // Video stream descriptor: HEVC
    section[offset++] = kStreamType_HEVC;
    section[offset++] = 0xE0 | ((kPID_Video >> 8) & 0x1F);
    section[offset++] = kPID_Video & 0xFF;
    section[offset++] = 0xF0;  // ES_info_length = 0
    section[offset++] = 0x00;

    // Audio stream descriptor: AAC
    section[offset++] = kStreamType_AAC;
    section[offset++] = 0xE0 | ((kPID_Audio >> 8) & 0x1F);
    section[offset++] = kPID_Audio & 0xFF;
    section[offset++] = 0xF0;  // ES_info_length = 0
    section[offset++] = 0x00;

    // section_length = offset - 3 (table_id の後から CRC 末尾まで) + 4 (CRC)
    uint16_t sectionLength = (uint16_t)(offset - 3 + 4);
    section[1] = 0xB0 | ((sectionLength >> 8) & 0x0F);
    section[2] = sectionLength & 0xFF;

    // CRC32
    uint32_t crc = _crc32MPEG2(section, offset);
    section[offset++] = (crc >> 24) & 0xFF;
    section[offset++] = (crc >> 16) & 0xFF;
    section[offset++] = (crc >> 8) & 0xFF;
    section[offset++] = crc & 0xFF;

    [output appendBytes:pkt length:kTSPacketSize];
}

#pragma mark - HVCC → Annex-B 変換

/// VPS/SPS/PPS を Annex-B start code 付きで返す
- (NSData *)_annexBParameterSetsFromFormatDescription:(CMFormatDescriptionRef)formatDesc {
    NSMutableData *result = [NSMutableData data];
    static const uint8_t startCode[] = { 0x00, 0x00, 0x00, 0x01 };

    size_t paramCount = 0;
    OSStatus status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        formatDesc, 0, NULL, NULL, &paramCount, NULL);
    if (status != noErr) return nil;

    for (size_t i = 0; i < paramCount; i++) {
        const uint8_t *paramSet = NULL;
        size_t paramSetSize = 0;
        status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDesc, i, &paramSet, &paramSetSize, NULL, NULL);
        if (status != noErr) continue;
        [result appendBytes:startCode length:4];
        [result appendBytes:paramSet length:paramSetSize];
    }
    return result;
}

/// HVCC length-prefix → Annex-B start code 変換
- (NSData *)_annexBDataFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) return nil;

    size_t totalLength = 0;
    char *dataPointer = NULL;
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPointer);
    if (status != noErr || !dataPointer) return nil;

    // NAL length size (通常 4)
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    int nalLengthSize = 4;
    if (formatDesc) {
        int headerMode = 0;
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDesc, 0, NULL, NULL, NULL, &headerMode);
        nalLengthSize = headerMode; // lengthSizeMinusOne + 1
        if (nalLengthSize < 1 || nalLengthSize > 4) nalLengthSize = 4;
    }

    static const uint8_t startCode[] = { 0x00, 0x00, 0x00, 0x01 };
    NSMutableData *result = [NSMutableData dataWithCapacity:totalLength + 64];

    size_t offset = 0;
    while (offset + nalLengthSize <= totalLength) {
        uint32_t nalSize = 0;
        for (int i = 0; i < nalLengthSize; i++) {
            nalSize = (nalSize << 8) | ((uint8_t)dataPointer[offset + i]);
        }
        offset += nalLengthSize;

        if (offset + nalSize > totalLength) break;

        [result appendBytes:startCode length:4];
        [result appendBytes:dataPointer + offset length:nalSize];
        offset += nalSize;
    }
    return result;
}

#pragma mark - AAC → ADTS 変換

- (NSData *)_adtsDataFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) return nil;

    size_t totalLength = 0;
    char *dataPointer = NULL;
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPointer);
    if (status != noErr || !dataPointer) return nil;

    // フォーマット情報取得
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);
    if (!asbd) return nil;

    // ADTS プロファイル: AAC-LC = 1 (ADTS では profile - 1 = 1)
    uint8_t profile = 1;  // AAC-LC

    // サンプルレートインデックス
    uint8_t freqIndex = [self _adtsFrequencyIndex:asbd->mSampleRate];

    // チャンネル設定
    uint8_t channelConfig = (uint8_t)asbd->mChannelsPerFrame;
    if (channelConfig > 7) channelConfig = 0;

    // ADTS フレーム長 = 7 (ヘッダ) + AAC データ長
    uint16_t frameLength = (uint16_t)(7 + totalLength);

    // 7 バイト ADTS ヘッダ
    uint8_t adts[7];
    adts[0] = 0xFF;
    adts[1] = 0xF1;  // MPEG-4, Layer 0, no CRC
    adts[2] = (uint8_t)((profile << 6) | (freqIndex << 2) | ((channelConfig >> 2) & 0x01));
    adts[3] = (uint8_t)(((channelConfig & 0x03) << 6) | ((frameLength >> 11) & 0x03));
    adts[4] = (uint8_t)((frameLength >> 3) & 0xFF);
    adts[5] = (uint8_t)(((frameLength & 0x07) << 5) | 0x1F);
    adts[6] = 0xFC;

    NSMutableData *result = [NSMutableData dataWithCapacity:frameLength];
    [result appendBytes:adts length:7];
    [result appendBytes:dataPointer length:totalLength];
    return result;
}

- (uint8_t)_adtsFrequencyIndex:(Float64)sampleRate {
    static const Float64 freqTable[] = {
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
        16000, 12000, 11025, 8000, 7350
    };
    for (uint8_t i = 0; i < 13; i++) {
        if (fabs(sampleRate - freqTable[i]) < 1.0) return i;
    }
    return 0x0F;  // forbidden (shouldn't happen)
}

#pragma mark - PTS/DTS ユーティリティ

static int64_t _cmTimeToTicks90k(CMTime time) {
    if (CMTIME_IS_INVALID(time)) return 0;
    return (int64_t)(CMTimeGetSeconds(time) * kTimeScale90k);
}

#pragma mark - PES パケット生成

/// PES ヘッダ + ES データを結合した NSData を返す
- (NSData *)_buildPESWithStreamID:(uint8_t)streamID
                              pts:(int64_t)pts90k
                           esData:(NSData *)esData {
    // PES ヘッダサイズ: 3 (start code) + 1 (stream_id) + 2 (PES_packet_length)
    //                  + 3 (flags + header_data_length) + 5 (PTS)
    static const int kPESHeaderSize = 14;

    size_t pesLength = kPESHeaderSize + esData.length;
    NSMutableData *pes = [NSMutableData dataWithCapacity:pesLength];

    uint8_t header[kPESHeaderSize];
    // PES start code
    header[0] = 0x00;
    header[1] = 0x00;
    header[2] = 0x01;
    header[3] = streamID;

    // PES packet length (ヘッダ残り + データ)。ビデオは 0 (無制限) も可だが
    // 正確に計算する。65535 を超える場合は 0 にする。
    size_t payloadLen = (kPESHeaderSize - 6) + esData.length;
    if (payloadLen > 0xFFFF) {
        header[4] = 0x00;
        header[5] = 0x00;
    } else {
        header[4] = (payloadLen >> 8) & 0xFF;
        header[5] = payloadLen & 0xFF;
    }

    // Flags: data_alignment=1, PTS_DTS_flags=10 (PTS のみ)
    header[6] = 0x80;  // '10' marker
    header[7] = 0x80;  // PTS_DTS_flags = 10
    header[8] = 5;     // PES_header_data_length

    // PTS エンコード (5 バイト)
    header[9]  = (uint8_t)(0x21 | (((pts90k >> 30) & 0x07) << 1));
    header[10] = (uint8_t)((pts90k >> 22) & 0xFF);
    header[11] = (uint8_t)(0x01 | (((pts90k >> 15) & 0x7F) << 1));
    header[12] = (uint8_t)((pts90k >> 7) & 0xFF);
    header[13] = (uint8_t)(0x01 | (((pts90k) & 0x7F) << 1));

    [pes appendBytes:header length:kPESHeaderSize];
    [pes appendData:esData];
    return pes;
}

#pragma mark - TS パケット化

/// PES データを 188 バイト TS パケットに分割して出力する。
/// 最初のパケットに adaptation field (PCR) を含める (ビデオのみ)。
- (NSData *)_packetizePES:(NSData *)pesData
                      pid:(uint16_t)pid
       continuityCounter:(uint8_t *)cc
               includePCR:(BOOL)includePCR
                  pcr90k:(int64_t)pcr90k {
    const uint8_t *pesBytes = pesData.bytes;
    size_t pesRemaining = pesData.length;

    // 最悪ケースの TS パケット数を見積もる
    size_t estimatedPackets = (pesRemaining / (kTSPacketSize - 4)) + 2;
    NSMutableData *output = [NSMutableData dataWithCapacity:estimatedPackets * kTSPacketSize];

    BOOL firstPacket = YES;

    while (pesRemaining > 0) {
        uint8_t pkt[kTSPacketSize];
        memset(pkt, 0xFF, kTSPacketSize);

        int headerSize = 4;
        int adaptationFieldSize = 0;

        // Adaptation field (最初のパケットで PCR を含む場合)
        if (firstPacket && includePCR) {
            // adaptation_field_length(1) + flags(1) + PCR(6) = 8
            adaptationFieldSize = 8;
        }

        int availablePayload = kTSPacketSize - headerSize - adaptationFieldSize;

        // 最後のパケットでペイロードが足りない場合、スタッフィング
        if ((int)pesRemaining < availablePayload) {
            int stuffing = availablePayload - (int)pesRemaining;
            if (adaptationFieldSize == 0) {
                // adaptation field を新規作成。stuffing バイト =
                // adaptation_field_length(1) + 内容(stuffing-1)
                adaptationFieldSize = stuffing;
            } else {
                adaptationFieldSize += stuffing;
            }
            availablePayload = kTSPacketSize - headerSize - adaptationFieldSize;
        }

        // TS ヘッダ
        pkt[0] = kTSSyncByte;
        pkt[1] = ((firstPacket ? 0x40 : 0x00) | ((pid >> 8) & 0x1F));
        pkt[2] = pid & 0xFF;

        BOOL hasAdaptation = (adaptationFieldSize > 0);
        BOOL hasPayload = (availablePayload > 0);
        uint8_t adaptPayloadFlags = (uint8_t)((hasAdaptation ? 0x20 : 0x00) | (hasPayload ? 0x10 : 0x00));
        pkt[3] = adaptPayloadFlags | (*cc & 0x0F);
        *cc = (*cc + 1) & 0x0F;

        int writeOffset = 4;

        // Adaptation field 書き込み
        if (hasAdaptation) {
            int afLength = adaptationFieldSize - 1;  // adaptation_field_length は自身を含まない
            pkt[writeOffset] = (uint8_t)afLength;
            writeOffset++;

            if (afLength > 0) {
                // flags
                uint8_t afFlags = 0;
                if (firstPacket && includePCR) {
                    afFlags |= 0x10;  // PCR_flag
                }
                pkt[writeOffset] = afFlags;
                writeOffset++;

                // PCR (6 bytes)
                if (firstPacket && includePCR) {
                    int64_t pcrBase = pcr90k;
                    uint16_t pcrExt = 0;  // no extension
                    pkt[writeOffset++] = (uint8_t)((pcrBase >> 25) & 0xFF);
                    pkt[writeOffset++] = (uint8_t)((pcrBase >> 17) & 0xFF);
                    pkt[writeOffset++] = (uint8_t)((pcrBase >> 9) & 0xFF);
                    pkt[writeOffset++] = (uint8_t)((pcrBase >> 1) & 0xFF);
                    pkt[writeOffset++] = (uint8_t)(((pcrBase & 0x01) << 7) | 0x7E | ((pcrExt >> 8) & 0x01));
                    pkt[writeOffset++] = (uint8_t)(pcrExt & 0xFF);
                }

                // スタッフィングバイト
                int stuffBytes = afLength - (writeOffset - 4 - 1);
                if (stuffBytes > 0) {
                    memset(pkt + writeOffset, 0xFF, stuffBytes);
                    writeOffset += stuffBytes;
                }
            }
        }

        // ペイロード書き込み
        if (hasPayload && availablePayload > 0) {
            int toCopy = (int)MIN((size_t)availablePayload, pesRemaining);
            memcpy(pkt + writeOffset, pesBytes, toCopy);
            pesBytes += toCopy;
            pesRemaining -= toCopy;
        }

        [output appendBytes:pkt length:kTSPacketSize];
        firstPacket = NO;
    }

    return output;
}

#pragma mark - ビデオサンプル処理 (内部)

- (void)_muxVideoSampleInternal:(CMSampleBufferRef)sampleBuffer {
    // キーフレーム判定
    BOOL isKeyframe = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
        isKeyframe = (notSync == NULL || !CFBooleanGetValue(notSync));
    }

    // PAT/PMT 定期送信: キーフレーム前 or 500ms 経過
    BOOL shouldEmitPSI = isKeyframe;
    if (!shouldEmitPSI) {
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        uint64_t now = mach_absolute_time();
        uint64_t elapsedNs = (now - self.lastPATEmitTime) * timebase.numer / timebase.denom;
        if (elapsedNs > 500000000ULL || self.lastPATEmitTime == 0) {
            shouldEmitPSI = YES;
        }
    }

    // PTS 取得
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    int64_t pts90k = _cmTimeToTicks90k(pts);

    // ES データ構築
    NSMutableData *esData = [NSMutableData data];

    // キーフレームの場合、パラメータセットを先行出力
    if (isKeyframe) {
        CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (formatDesc) {
            NSData *paramSets = [self _annexBParameterSetsFromFormatDescription:formatDesc];
            if (paramSets) {
                [esData appendData:paramSets];
            }
        }
    }

    // NAL データを Annex-B に変換
    NSData *annexBNALs = [self _annexBDataFromSampleBuffer:sampleBuffer];
    if (!annexBNALs) return;
    [esData appendData:annexBNALs];

    // PAT/PMT 送出 (キーフレーム直前)
    NSMutableData *allPackets = [NSMutableData data];
    if (shouldEmitPSI) {
        NSMutableData *psiData = [NSMutableData dataWithCapacity:kTSPacketSize * 2];
        [self _buildPAT:psiData];
        [self _buildPMT:psiData];
        self.lastPATEmitTime = mach_absolute_time();
        [allPackets appendData:psiData];
    }

    // PES 構築
    NSData *pes = [self _buildPESWithStreamID:kPES_StreamID_Video
                                          pts:pts90k
                                       esData:esData];

    // TS パケット化 (ビデオは PCR を含む)
    NSData *tsPackets = [self _packetizePES:pes
                                        pid:kPID_Video
                         continuityCounter:&_videoContinuityCounter
                                 includePCR:YES
                                    pcr90k:pts90k];
    [allPackets appendData:tsPackets];

    // ブートストラップキャッシュ更新 (キーフレーム時)
    if (isKeyframe) {
        [self.bootstrapCache setLength:0];
        // PAT+PMT を含める
        NSMutableData *psi = [NSMutableData dataWithCapacity:kTSPacketSize * 2];
        // ブートストラップ用の PAT/PMT は独立したカウンタ値で送出済みなので
        // 直前の PSI パケットか、新たに生成したものをキャッシュ
        [self _buildPAT:psi];
        [self _buildPMT:psi];
        [self.bootstrapCache appendData:psi];
        [self.bootstrapCache appendData:tsPackets];
    }

    // コールバック
    if (self.onTSPackets && allPackets.length > 0) {
        self.onTSPackets(allPackets.bytes, allPackets.length);
    }
}

#pragma mark - オーディオサンプル処理 (内部)

- (void)_muxAudioSampleInternal:(CMSampleBufferRef)sampleBuffer {
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    int64_t pts90k = _cmTimeToTicks90k(pts);

    // AAC → ADTS
    NSData *adtsData = [self _adtsDataFromSampleBuffer:sampleBuffer];
    if (!adtsData) return;

    // PES 構築
    NSData *pes = [self _buildPESWithStreamID:kPES_StreamID_Audio
                                          pts:pts90k
                                       esData:adtsData];

    // TS パケット化 (オーディオは PCR なし)
    NSData *tsPackets = [self _packetizePES:pes
                                        pid:kPID_Audio
                         continuityCounter:&_audioContinuityCounter
                                 includePCR:NO
                                    pcr90k:0];

    if (self.onTSPackets && tsPackets.length > 0) {
        self.onTSPackets(tsPackets.bytes, tsPackets.length);
    }
}

@end
