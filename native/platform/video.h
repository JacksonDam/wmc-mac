// Video players (native/platform/video.m), shared by both engines.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include "wmc.h"

// Where a surface's frames go: the engine's side.
typedef struct {
    // 0: the surface is shown nowhere now; 1: it is; 2: it is, and has no
    // picture yet (it is given the current one even if not new).
    int (*target)(int surfaceId);
    // A frame: rows of B G R A, `stride` bytes apart; shown at shownWidth x
    // shownHeight (the pixels' aspect). `first`: the first on this surface.
    void (*put)(int surfaceId, const void *bgra, size_t stride, int width, int height, int shownWidth, int shownHeight,
                bool first);
} WmcVideoSink;

// Each playing video's newest frame, to the sink. Main thread, before drawing.
void wmc_video_tick(const WmcVideoSink *sink);
