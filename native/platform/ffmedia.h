// Windows Media (WMV, WMA, ASF) and AVI files with FFmpeg: the Mac's own
// media frameworks cannot open them. See ffmedia.m.
#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

// Whether a file is one FFmpeg plays here (by its extension: .wmv .wma .asf .wm .avi .divx).
bool wmc_ff_handles(const char *path);

// A player. Opening reads the file's header (NULL if it cannot be played);
// it starts paused at the beginning.
void *wmc_ff_open(const char *path, bool with_video);
void wmc_ff_close(void *player);
int wmc_ff_state(void *player);          // 1 ready and paused, 2 playing, 3 played to the end
int wmc_ff_has_audio(void *player);
int wmc_ff_has_video(void *player);
void wmc_ff_size(void *player, int *width, int *height);
// The size the picture is shown at: its pixels may not be square (DV, DivX).
void wmc_ff_display_size(void *player, int *width, int *height);
double wmc_ff_duration(void *player);
double wmc_ff_position(void *player);
void wmc_ff_seek(void *player, double seconds);
void wmc_ff_play(void *player);
void wmc_ff_pause(void *player);
void wmc_ff_set_rate(void *player, float rate);
void wmc_ff_set_volume(void *player, float volume, int muted);
// The frame due now, as BGRA: 1 if it is not the one handed out last time.
int wmc_ff_take_frame(void *player, const uint8_t **bgra, int *stride, int *width, int *height);

// "key=value" lines like wmc_media_tags; -1 if the file cannot be read.
int wmc_ff_tags(const char *path, char *out, int size);
// The cover picture an ASF file carries, written to dest: 1 if there was one.
int wmc_ff_artwork(const char *path, const char *dest);
// A frame about a tenth of the way in, no larger than box (the caller releases it).
CGImageRef wmc_ff_thumbnail(const char *path, int box);
