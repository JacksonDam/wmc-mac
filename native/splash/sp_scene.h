// The retained scene the framework builds in the engine.
//
//   Window        root visual, background colour
//   Visual        a node: position, size, scale, rotation, alpha, children,
//                 and a display list to draw (its "content")
//   RenderBuilder a display list: solid fills, textured quads, lines
//   SurfacePool   a texture
//   Surface       a rectangle of a pool
//   Rasterizer    copies pixel data (sent through a DataBuffer) into a surface
//   Gradient      an alpha ramp applied to draws between its Push and Pop
//   Device        factory for pools, gradients and lines; takes draw calls
#pragma once
#import <Metal/Metal.h>
#import "sp.h"
#import "sp_classes.h"

typedef struct { float x, y, w, h; } SpRectF;
typedef struct { float x, y, z; } SpVec3;

typedef NS_ENUM(int, SpDrawKind) {
    SpDrawSolid,       // colour, dst
    SpDrawSurface,     // surface, src (pixels within the surface), dst
    SpDrawGrid,        // surface, nine-grid with insets gx1 left, gx2 right, gy1 top, gy2 bottom, dst
    SpDrawPool,        // whole-pool draw: pool, src, dst
    SpDrawOutline,     // colour, thickness, dst
    SpDrawLine,        // colour, thickness, from, to
    SpDrawGradientPush,
    SpDrawGradientPop,
    SpDrawGradient,
    SpDrawNotify,
};

@class SpSurface, SpSurfacePool, SpGradient, SpVisual, SpDevice, SpWindow;

@interface SpDrawOp : NSObject
@property (nonatomic) SpDrawKind kind;
@property (nonatomic) uint32_t color;          // 0xAARRGGBB
@property (nonatomic) SpRectF src, dst;
@property (nonatomic) float gx1, gx2, gy1, gy2;
@property (nonatomic) float thickness;
@property (nonatomic) SpVec3 from, to;
@property (nonatomic, strong) SpSurface *surface;
@property (nonatomic, strong) SpSurfacePool *pool;
@property (nonatomic, strong) SpGradient *gradient;
@end

@interface SpRenderBuilder : SpObject
@property (nonatomic, readonly) NSMutableArray<SpDrawOp *> *ops;
@end

@interface SpVisual : SpObject
@property (nonatomic, weak) SpVisual *parent;
@property (nonatomic, readonly) NSMutableArray<SpVisual *> *children;
@property (nonatomic, strong) SpRenderBuilder *content;
@property (nonatomic) SpVec3 position, size, scale, centerScale, centerOffset, axis;
@property (nonatomic) float angle;
@property (nonatomic) float alpha;             // 0..1
@property (nonatomic) uint32_t color;          // modulation, 0xAARRGGBB
@property (nonatomic) uint32_t layer, dataBits;
@property (nonatomic) BOOL visible;
@property (nonatomic, copy) NSString *debugID;
@end

@interface SpSurfacePool : SpObject
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic) int width, height;
@property (nonatomic) uint32_t format, emptyColor;
// The margin the framework's packer leaves around every surface it puts in
// this pool, so that a surface drawn enlarged does not pick up its
// neighbour's pixels at the edges. The engine keeps it filled (see SpSurface).
@property (nonatomic) int gutterX, gutterY;
@property (nonatomic, weak) SpDevice *device;
- (void)upload:(const uint8_t *)pixels stride:(int)stride format:(uint32_t)format
          rect:(SpRectF)rect;
- (void)allocateWidth:(int)w height:(int)h format:(uint32_t)format;
@end

// A pool whose picture is a playing video (sp_video.m). The framework makes
// one for each "dynamic image" and tells the engine the number that names
// it; a player presents into it by that number.
@interface SpVideoPool : SpSurfacePool
@property (nonatomic) uint32_t ownerObject, ownerContext;   // who hears about the video's size
@property (nonatomic) int uniqueId;
@end
void sp_video_tick(void);

@interface SpSurface : SpObject
@property (nonatomic, strong) SpSurfacePool *pool;
// The surface's storage within the pool, in pixels: its content with the
// pool's gutter on every side.
@property (nonatomic) SpRectF location;
// Where the content itself is: `location` less the gutter. Uploads go
// here, and each one that reaches an edge of the content repeats the edge
// pixels into the gutter beside it.
@property (nonatomic, readonly) SpRectF content;
@property (nonatomic) int storageWidth, storageHeight;     // as the framework stated them (0: not stated)
// The framework's packer may store a surface turned a quarter turn to fit
// it in the pool. `content` is then the turned rectangle (its width is the
// content's height). Content point (x, y) lives at pool point
// (content.x + contentHeight - 1 - y, content.y + x).
@property (nonatomic) BOOL rotated;
// Copies 32-bit pixels for a content rectangle into the pool.
- (void)uploadPixels:(const uint8_t *)pixels
              stride:(int)stride
              format:(uint32_t)format
               width:(int)width
              height:(int)height
                 atX:(int)x
                   y:(int)y;
@end

@interface SpGradient : SpObject
@property (nonatomic) int orientation;
@property (nonatomic) float offset;
@property (nonatomic) uint32_t colorMask;
@property (nonatomic, readonly) NSMutableArray<NSArray<NSNumber *> *> *stops;   // value, position, relative
@end

@interface SpDevice : SpObject
@property (nonatomic, strong) id<MTLDevice> metal;
@end

// A top-level window. Subclassed by the desktop FormWindow, which adds the
// Mac window; the scene part lives here.
@interface SpWindow : SpObject
@property (nonatomic, strong) SpVisual *root;
@property (nonatomic, strong) SpRenderBuilder *content;
@property (nonatomic) uint32_t backgroundColor;
@property (nonatomic) float zNear, zEye;
- (BOOL)windowMessage:(const SpMessage *)msg;   // handles the Window message set
- (void)sceneChanged;
@end

// Called after any change to the scene; windows redraw on the next frame.
void sp_scene_invalidate(void);
uint64_t sp_scene_generation(void);
void sp_scene_invalidate_looping(void);
uint64_t sp_scene_content_generation(void);

id<MTLDevice> sp_metal_device(void);
