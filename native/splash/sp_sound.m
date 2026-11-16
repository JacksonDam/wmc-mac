// Sound effects.
//
// The framework decodes a .wav with SpSoundLoadBuffer (getting the format and
// a pointer to the samples), creates a sound buffer in the engine, sends the
// samples through a DataBuffer, waits to be told the buffer is ready, then
// creates Sound objects on it and plays them. Playback here is AVAudioPlayer
// on the same PCM, wrapped back into a .wav in memory.
#import <AVFoundation/AVFoundation.h>
#import "sp.h"
#import "sp_classes.h"

typedef struct Sp_RenderApi_SoundHeader SpSoundHeader;
typedef struct Sp_RenderApi_SoundInformation SpSoundInfo;

// ---- decoding ----------------------------------------------------------------

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

// Finds the format and sample chunks of a RIFF/WAVE file.
WMC_API HRESULT SpSoundLoadBuffer(const uint8_t *buffer, int size, int options, void **handle, SpSoundInfo *info) {
    memset(info, 0, sizeof(*info));
    *handle = NULL;
    if (!buffer || size < 44 || memcmp(buffer, "RIFF", 4) != 0 || memcmp(buffer + 8, "WAVE", 4) != 0) return E_INVALIDARG;
    const uint8_t *fmt = NULL, *data = NULL;
    uint32_t fmtSize = 0, dataSize = 0;
    for (uint32_t off = 12; off + 8 <= (uint32_t)size;) {
        uint32_t chunk = le32(buffer + off + 4);
        if (off + 8 + chunk > (uint32_t)size) chunk = (uint32_t)size - off - 8;
        if (!memcmp(buffer + off, "fmt ", 4)) { fmt = buffer + off + 8; fmtSize = chunk; }
        else if (!memcmp(buffer + off, "data", 4)) { data = buffer + off + 8; dataSize = chunk; }
        off += 8 + chunk + (chunk & 1);
    }
    if (!fmt || fmtSize < 16 || !data) return E_FAIL;
    info->Header.wFormatTag = le16(fmt);
    info->Header.nChannels = le16(fmt + 2);
    info->Header.nSamplesPerSec = le32(fmt + 4);
    info->Header.nAvgBytesPerSec = le32(fmt + 8);
    info->Header.nBlockAlign = le16(fmt + 12);
    info->Header.wBitsPerSample = le16(fmt + 14);
    info->Header.cbExtraData = 0;
    info->Header.cbDataSize = dataSize;
    void *copy = malloc(dataSize ? dataSize : 1);
    memcpy(copy, data, dataSize);
    info->Data.rgData = (int64_t)(intptr_t)copy;
    *handle = copy;
    WLOG("snd", "decoded wav: format %u, %u ch, %u Hz, %u bits, %u bytes", info->Header.wFormatTag,
         info->Header.nChannels, info->Header.nSamplesPerSec, info->Header.wBitsPerSample, dataSize);
    return S_OK;
}

WMC_API HRESULT SpSoundDispose(void *handle, SpSoundInfo info) {
    free(handle);
    return S_OK;
}

// ---- engine objects -------------------------------------------------------------

@interface SpSoundBuffer : SpObject
@property (nonatomic) SpSoundHeader header;
@property (nonatomic, strong) NSData *wav;   // a complete .wav file, once the samples arrive
@end

@implementation SpSoundBuffer

- (void)spMessage:(const SpMessage *)msg {
    if (msg->nMsg != SpMsg_SoundBuffer_LoadSoundData) {
        [self spUnhandled:msg];
        return;
    }
    const struct Sp_RemoteSoundBuffer_LoadSoundData *m = (const void *)msg;
    SpDataBuffer *buffer = [self.context objectForHandle:m->dataBuffer.value];
    if (![buffer isKindOfClass:[SpDataBuffer class]] || !buffer.data) {
        WLOG("err", "sound buffer %#x: data buffer %#x is missing", self.handle, m->dataBuffer.value);
        return;
    }
    NSData *pcm = buffer.data;
    NSMutableData *wav = [NSMutableData dataWithCapacity:pcm.length + 44];
    uint32_t dataSize = (uint32_t)pcm.length, riffSize = dataSize + 36, fmtSize = 16;
    uint16_t tag = _header.wFormatTag ?: 1, channels = _header.nChannels, align = _header.nBlockAlign,
             bits = _header.wBitsPerSample;
    uint32_t rate = _header.nSamplesPerSec, bytesPerSec = _header.nAvgBytesPerSec;
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&riffSize length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    [wav appendBytes:&fmtSize length:4];
    [wav appendBytes:&tag length:2];
    [wav appendBytes:&channels length:2];
    [wav appendBytes:&rate length:4];
    [wav appendBytes:&bytesPerSec length:4];
    [wav appendBytes:&align length:2];
    [wav appendBytes:&bits length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataSize length:4];
    [wav appendData:pcm];
    _wav = wav;
    if (self.cbObject) {
        struct Sp_LocalSoundBufferCallback_OnSoundBufferReady cb = {0};
        cb.size = sizeof(cb);
        cb.msgid = SpMsg_SoundBufferCallback_OnSoundBufferReady;
        cb.idObjectSubject.value = self.cbObject;
        cb.idTarget.value = self.handle;
        [self.context sendCallback:&cb toContext:self.cbContext];
    }
}

@end

@interface SpSound : SpObject <AVAudioPlayerDelegate>
@property (nonatomic, strong) SpSoundBuffer *buffer;
@end

// Players are kept alive here while they play, even if the framework lets go
// of the Sound object first.
static NSMutableSet<AVAudioPlayer *> *s_players;

@implementation SpSound {
    AVAudioPlayer *_player;
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    [s_players removeObject:player];
}

- (void)spMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case SpMsg_Sound_Play: {
            if (!_buffer.wav) {
                WLOG("err", "sound %#x played before its buffer was loaded", self.handle);
                break;
            }
            NSError *error = nil;
            _player = [[AVAudioPlayer alloc] initWithData:_buffer.wav error:&error];
            if (!_player) {
                WLOG("err", "sound %#x cannot play: %s", self.handle, error.localizedDescription.UTF8String);
                break;
            }
            if (getenv("WMC_MUTE")) _player.volume = 0;
            _player.delegate = self;
            if (!s_players) s_players = [NSMutableSet set];
            [s_players addObject:_player];
            BOOL ok = [_player play];
            WLOG("snd", "play sound %#x: %.2f s, %lu bytes%s", self.handle, _player.duration,
                 (unsigned long)_buffer.wav.length, ok ? "" : " (FAILED to start)");
            break;
        }
        case SpMsg_Sound_Stop:
            [_player stop];
            if (_player) [s_players removeObject:_player];
            _player = nil;
            break;
        default:
            [self spUnhandled:msg];
    }
}

@end

@interface SpSoundDevice : SpObject
@end

@implementation SpSoundDevice

- (void)spMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case SpMsg_SoundDevice_CreateSound: {
            const struct Sp_RemoteSoundDevice_CreateSound *m = (const void *)msg;
            SpSound *sound = [SpSound new];
            sound.handle = m->idNewSound.value;
            sound.context = self.context;
            sound.spClassName = @"Splash::Rendering::Sound";
            id buffer = [self.context objectForHandle:m->soundBuffer.value];
            sound.buffer = [buffer isKindOfClass:[SpSoundBuffer class]] ? buffer : nil;
            [self.context registerObject:sound];
            break;
        }
        case SpMsg_SoundDevice_CreateSoundBuffer: {
            const struct Sp_RemoteSoundDevice_CreateSoundBuffer *m = (const void *)msg;
            SpSoundBuffer *buffer = [SpSoundBuffer new];
            buffer.handle = m->idNewBuffer.value;
            buffer.context = self.context;
            buffer.spClassName = @"Splash::Rendering::SoundBuffer";
            buffer.header = m->info;
            buffer.cbObject = m->objcb.value;
            buffer.cbContext = m->ctxcb.value;
            [self.context registerObject:buffer];
            break;
        }
        case SpMsg_SoundDevice_EvictExternalResources:
        case SpMsg_SoundDevice_CreateExternalResources:
            break;
        default:
            [self spUnhandled:msg];
    }
}

@end

__attribute__((constructor)) static void register_sound_classes(void) {
    sp_register_class(@"Splash::Rendering::SoundDevice", [SpSoundDevice class]);
    sp_register_class(@"Splash::Rendering::Nt::WinSoundDevice", [SpSoundDevice class]);
    sp_register_class(@"Splash::Rendering::Nt::Dx9SoundDevice", [SpSoundDevice class]);
    sp_register_class(@"Splash::Rendering::Nt::ExtenderSoundDevice", [SpSoundDevice class]);
    sp_register_class(@"Splash::Rendering::SoundBuffer", [SpSoundBuffer class]);
    sp_register_class(@"Splash::Rendering::Sound", [SpSound class]);
}
