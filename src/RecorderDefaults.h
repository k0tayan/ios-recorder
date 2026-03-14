#ifndef RecorderDefaults_h
#define RecorderDefaults_h

#import <stdint.h>

// 録画デフォルト
static const int kDefaultFPS           = 120;
static const int kDefaultVideoBitrate  = 14000000;
static const int kDefaultAudioBitrate  = 128000;
static const int kDefaultMaxWidth      = 1280;
static const int kDefaultMaxHeight     = 720;

// ストリーミングデフォルト
static const uint16_t kStreamPort      = 8191;
static const int kStreamFPS            = 120;
static const int kStreamBitrate        = 6000000;
static const int kStreamWidth          = 1280;
static const int kStreamHeight         = 720;

#endif
