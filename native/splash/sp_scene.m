// Scene objects: visuals, display lists, surfaces and the device.
#import "sp_scene.h"

static uint64_t s_generation = 1;

static uint64_t s_content_generation = 1;
void sp_scene_invalidate(void) { s_generation++; s_content_generation++; }
uint64_t sp_scene_generation(void) { return s_generation; }
// A change made by an animation that repeats for ever (a pulsing focus
// highlight) needs drawing, but is not the scene changing: scripted runs
// that wait for Media Center to settle watch the content generation.
void sp_scene_invalidate_looping(void) { s_generation++; }
uint64_t sp_scene_content_generation(void) { return s_content_generation; }

id<MTLDevice> sp_metal_device(void) {
    static id<MTLDevice> device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ device = MTLCreateSystemDefaultDevice(); });
    return device;
}

static SpRectF rectf(struct Sp_RectangleF r) { return (SpRectF){ r.x, r.y, r.width, r.height }; }
static SpVec3 vec3(struct Sp_Vector3 v) { return (SpVec3){ v.m_x, v.m_y, v.m_z }; }

static SpRenderBuilder *builder(SpObject *from, uint32_t handle) {
    id rb = [from.context objectForHandle:handle];
    return [rb isKindOfClass:[SpRenderBuilder class]] ? rb : nil;
}

// SetContent hands a builder's recorded commands over to the visual (or
// window) and leaves the builder empty for its next use: the framework
// records into one builder, assigns it, and records the next visual's
// content into the same builder without clearing it.
static SpRenderBuilder *take_content(SpObject *from, uint32_t handle) {
    SpRenderBuilder *rb = builder(from, handle);
    if (!rb) return nil;
    SpRenderBuilder *content = [SpRenderBuilder new];
    [content.ops addObjectsFromArray:rb.ops];
    [rb.ops removeAllObjects];
    return content;
}

@implementation SpDrawOp
@end

// ---------------------------------------------------------------- RenderBuilder

@implementation SpRenderBuilder

- (instancetype)init {
    if ((self = [super init])) _ops = [NSMutableArray array];
    return self;
}

- (void)spMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case SpMsg_RenderBuilder_Clear:
            [_ops removeAllObjects];
            sp_scene_invalidate();
            break;
        default:
            [self spUnhandled:msg];
    }
}

@end

// ----------------------------------------------------------------------- Visual

@implementation SpVisual

- (instancetype)init {
    if ((self = [super init])) {
        _children = [NSMutableArray array];
        _scale = (SpVec3){ 1, 1, 1 };
        _axis = (SpVec3){ 0, 0, 1 };
        _alpha = 1;
        _color = 0xFFFFFFFF;
        _visible = YES;
    }
    return self;
}

- (void)detach {
    [_parent.children removeObject:self];
    _parent = nil;
}

- (void)spDestroy {
    [self detach];
    for (SpVisual *c in _children) c.parent = nil;
    [_children removeAllObjects];
    sp_scene_invalidate();
}

- (void)spMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case SpMsg_Visual_ChangeDataBits: {
            const struct Sp_RemoteVisual_ChangeDataBits *m = (const void *)msg;
            _dataBits = (_dataBits & ~m->nMask) | (m->nValue & m->nMask);
            break;
        }
        case SpMsg_Visual_ChangeParent: {
            const struct Sp_RemoteVisual_ChangeParent *m = (const void *)msg;
            SpVisual *parent = [self.context objectForHandle:m->visNewParent.value];
            SpVisual *sibling = [self.context objectForHandle:m->visSibling.value];
            [self detach];
            if ([parent isKindOfClass:[SpVisual class]]) {
                _parent = parent;
                NSMutableArray *kids = parent.children;
                NSUInteger at = sibling ? [kids indexOfObject:sibling] : NSNotFound;
                // Children are kept back to front: the last one draws on top.
                switch (m->nOrder) {
                    case 1: // Before: in front of the sibling
                        if (at != NSNotFound) [kids insertObject:self atIndex:at + 1]; else [kids addObject:self];
                        break;
                    case 2: // Behind the sibling
                        if (at != NSNotFound) [kids insertObject:self atIndex:at]; else [kids insertObject:self atIndex:0];
                        break;
                    case 4: // Bottom
                        [kids insertObject:self atIndex:0];
                        break;
                    default: // Any, Top
                        [kids addObject:self];
                }
            }
            break;
        }
        case SpMsg_Visual_SetDebugOutlineColor:
            break;
        case SpMsg_Visual_SetDebugID: {
            const struct Sp_RemoteVisual_SetDebugID *m = (const void *)msg;
            _debugID = sp_blob_string(msg, m->stDebugID.value);
            break;
        }
        case SpMsg_Visual_SetColor:
            _color = ((const struct Sp_RemoteVisual_SetColor *)msg)->clr.value;
            break;
        case SpMsg_Visual_SetAlpha:
            _alpha = ((const struct Sp_RemoteVisual_SetAlpha *)msg)->bAlpha / 255.0f;
            break;
#ifdef SP_HAS_MSG_Visual_SetLayer
        case SpMsg_Visual_SetLayer:
            _layer = ((const struct Sp_RemoteVisual_SetLayer *)msg)->layer;
            break;
#endif
        case SpMsg_Visual_SetRotation: {
            const struct Sp_RemoteVisual_SetRotation *m = (const void *)msg;
            _axis = vec3(m->rotRotation.m_axis);
            _angle = m->rotRotation.m_angleRad;
            break;
        }
#ifndef SP_HAS_MSG_Visual_SetCenterPointOffset
        // XP Media Center Edition: one centre point, in pixels.
        case SpMsg_Visual_SetCenterPoint:
            _centerScale = (SpVec3){ 0, 0, 0 };
            _centerOffset = vec3(((const struct Sp_RemoteVisual_SetCenterPoint *)msg)->vCenterPoint);
            break;
#endif
#ifdef SP_HAS_MSG_Visual_SetCenterPointScale
        case SpMsg_Visual_SetCenterPointScale:
            _centerScale = vec3(((const struct Sp_RemoteVisual_SetCenterPointScale *)msg)->vCenterPointScale);
            break;
#endif
#ifdef SP_HAS_MSG_Visual_SetCenterPointOffset
        case SpMsg_Visual_SetCenterPointOffset:
            _centerOffset = vec3(((const struct Sp_RemoteVisual_SetCenterPointOffset *)msg)->vCenterPointOffset);
            break;
#endif
        case SpMsg_Visual_SetScale:
            _scale = vec3(((const struct Sp_RemoteVisual_SetScale *)msg)->vScale);
            break;
        case SpMsg_Visual_SetSize:
            _size = vec3(((const struct Sp_RemoteVisual_SetSize *)msg)->vSizePxl);
            break;
        case SpMsg_Visual_SetPosition:
            _position = vec3(((const struct Sp_RemoteVisual_SetPosition *)msg)->vPositionPxl);
            break;
        case SpMsg_Visual_SetContent: {
            const struct Sp_RemoteVisual_SetContent *m = (const void *)msg;
            _content = take_content(self, m->rbContent.value);
            break;
        }
        case SpMsg_Visual_SetVisible:
            _visible = ((const struct Sp_RemoteVisual_SetVisible *)msg)->fVisible != 0;
            break;
        default:
            [self spUnhandled:msg];
            return;
    }
    sp_scene_invalidate();
}

@end

// ------------------------------------------------------------------ SurfacePool

static BOOL format_is_32(uint32_t format) { return (format & 0x00F00000) == 0x00200000; }

@implementation SpSurfacePool

- (void)allocateWidth:(int)w height:(int)h format:(uint32_t)format {
    _width = w;
    _height = h;
    _format = format;
    _texture = nil;
    if (w <= 0 || h <= 0) return;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:(NSUInteger)w
                                                                                height:(NSUInteger)h
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    _texture = [sp_metal_device() newTextureWithDescriptor:d];
    // Start from the pool's empty colour so unloaded surfaces are not noise.
    uint32_t *fill = malloc((size_t)w * (size_t)h * 4);
    for (size_t i = 0; i < (size_t)w * (size_t)h; i++) fill[i] = _emptyColor;
    [_texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h)
                mipmapLevel:0
                  withBytes:fill
                bytesPerRow:(NSUInteger)w * 4];
    free(fill);
}

// Copies pixels into the texture, converting to BGRA as needed and clipping
// to the texture.
- (void)upload:(const uint8_t *)pixels stride:(int)stride format:(uint32_t)format rect:(SpRectF)rect {
    if (!_texture || !pixels) return;
    int x = (int)rect.x, y = (int)rect.y, w = (int)rect.w, h = (int)rect.h;
    if (x < 0 || y < 0 || w <= 0 || h <= 0) return;
    if (x + w > _width) w = _width - x;
    if (y + h > _height) h = _height - y;
    if (w <= 0 || h <= 0) return;
    int rowBytes = stride < 0 ? -stride : stride;
    const uint8_t *first = pixels;
    if (format_is_32(format)) {
        BOOL opaque = (format & 0xFFFF) == 0x1808 || format == 2099336u;   // RGB32: alpha byte is unused
        if (!opaque) {
            [_texture replaceRegion:MTLRegionMake2D((NSUInteger)x, (NSUInteger)y, (NSUInteger)w, (NSUInteger)h)
                        mipmapLevel:0
                          withBytes:first
                        bytesPerRow:(NSUInteger)rowBytes];
            return;
        }
        uint32_t *tmp = malloc((size_t)w * (size_t)h * 4);
        for (int r = 0; r < h; r++) {
            const uint32_t *src = (const uint32_t *)(first + (size_t)r * (size_t)rowBytes);
            for (int c = 0; c < w; c++) tmp[r * w + c] = src[c] | 0xFF000000;
        }
        [_texture replaceRegion:MTLRegionMake2D((NSUInteger)x, (NSUInteger)y, (NSUInteger)w, (NSUInteger)h)
                    mipmapLevel:0
                      withBytes:tmp
                    bytesPerRow:(NSUInteger)w * 4];
        free(tmp);
    } else if ((format & 0x00FF0000) == 0x00180000) {   // 24 bits per pixel, B G R
        uint32_t *tmp = malloc((size_t)w * (size_t)h * 4);
        for (int r = 0; r < h; r++) {
            const uint8_t *src = first + (size_t)r * (size_t)rowBytes;
            for (int c = 0; c < w; c++) {
                tmp[r * w + c] = 0xFF000000u | (uint32_t)src[c * 3 + 2] << 16 | (uint32_t)src[c * 3 + 1] << 8 | src[c * 3];
            }
        }
        [_texture replaceRegion:MTLRegionMake2D((NSUInteger)x, (NSUInteger)y, (NSUInteger)w, (NSUInteger)h)
                    mipmapLevel:0
                      withBytes:tmp
                    bytesPerRow:(NSUInteger)w * 4];
        free(tmp);
    } else {
        WLOG("todo", "surface upload in format %#x is not handled", format);
    }
    sp_scene_invalidate();
}

- (void)spMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case SpMsg_SurfacePool_CreateSurface: {
            const struct Sp_RemoteSurfacePool_CreateSurface *m = (const void *)msg;
            SpSurface *s = [SpSurface new];
            s.handle = m->idNewSurface.value;
            s.context = self.context;
            s.spClassName = SP_CLASS("Rendering", "Surface");
            s.pool = self;
            [self.context registerObject:s];
            break;
        }
        case SpMsg_SurfacePool_Free:
            _texture = nil;
            break;
        case SpMsg_SurfacePool_Allocate: {
            const struct Sp_RemoteSurfacePool_Allocate *m = (const void *)msg;
            [self allocateWidth:m->sizePxl.m_width height:m->sizePxl.m_height format:m->nOptions];
            SpDevice *dev = _device;
            if (dev.cbObject) {
                struct Sp_LocalDeviceCallback_OnSurfacePoolAllocation cb = {0};
                cb.size = sizeof(cb);
                cb.msgid = SpMsg_DeviceCallback_OnSurfacePoolAllocation;
                cb.idObjectSubject.value = dev.cbObject;
                cb.target.value = dev.handle;
                cb.idSurfacePool.value = self.handle;
                cb.nResult = _texture ? 2 /* Immoveable: allocated */ : 3 /* NotEnoughVideoMemory */;
                [self.context sendCallback:&cb toContext:dev.cbContext];
            }
            break;
        }
#ifdef SP_HAS_MSG_SurfacePool_SetEmptyColor
        case SpMsg_SurfacePool_SetEmptyColor:
            _emptyColor = ((const struct Sp_RemoteSurfacePool_SetEmptyColor *)msg)->clrFill.value;
            break;
#endif
        case SpMsg_SurfacePool_SetPriority:
            break;
#ifdef SP_HAS_MSG_SurfacePool_Draw
        case SpMsg_SurfacePool_Draw: {
            const struct Sp_RemoteSurfacePool_Draw *m = (const void *)msg;
            SpDrawOp *op = [SpDrawOp new];
            op.kind = SpDrawPool;
            op.pool = self;
            op.src = rectf(m->rcfSrcPxl);
            op.dst = rectf(m->rcfDestPxl);
            op.color = 0xFFFFFFFF;
            [builder(self, m->rb.value).ops addObject:op];
            sp_scene_invalidate();
            break;
        }
#endif
        default:
            [self spUnhandled:msg];
    }
}

@end

// ---------------------------------------------------------------------- Surface

@implementation SpSurface

// The storage rectangle less the pool's gutter. (A surface moved to a pool
// of its own is given a rectangle of exactly its content's size: there the
// storage size the framework stated no longer matches, and nothing is
// taken off.)
- (SpRectF)content {
    SpRectF r = _location;
    // A surface with a pool to itself is never told where it is: it is the
    // whole pool.
    if (r.w <= 0 || r.h <= 0) return (SpRectF){ 0, 0, _pool.width, _pool.height };
    int gx = _pool.gutterX, gy = _pool.gutterY;
    if (gx == 0 && gy == 0) return r;
    if (r.w <= 2 * gx || r.h <= 2 * gy) return r;
    if (_storageWidth > 0 && _storageHeight > 0) {
        BOOL same = (int)r.w == _storageWidth && (int)r.h == _storageHeight;
        BOOL turned = (int)r.w == _storageHeight && (int)r.h == _storageWidth;
        if (!same && !turned) return r;
    }
    return (SpRectF){ r.x + gx, r.y + gy, r.w - 2 * gx, r.h - 2 * gy };
}

// Puts a block of 32-bit pixels at a place in the pool that lies inside the
// content. Where the block reaches an edge of the content, its edge pixels
// are repeated into the gutter beyond: a surface drawn larger than it is
// samples half a pixel past its edge, and must find its own colour there,
// not what an earlier surface left in the pool.
- (void)put:(const uint8_t *)block stride:(int)stride format:(uint32_t)format x:(int)bx y:(int)by width:(int)bw height:(int)bh {
    SpRectF in = self.content;
    // (A surface that is the whole pool has no location, and no room for a
    // gutter around it: Vista's slide show pools have a gutter all the same.)
    BOOL whole = _location.w <= 0 || _location.h <= 0;
    BOOL inset = !whole && (in.w != _location.w || in.h != _location.h);
    int gx = inset ? _pool.gutterX : 0, gy = inset ? _pool.gutterY : 0;
    int l = bx == (int)in.x ? gx : 0, r = bx + bw == (int)(in.x + in.w) ? gx : 0;
    int t = by == (int)in.y ? gy : 0, b = by + bh == (int)(in.y + in.h) ? gy : 0;
    if (!format_is_32(format) || (l | r | t | b) == 0) {
        [_pool upload:block stride:stride format:format rect:(SpRectF){ bx, by, bw, bh }];
        return;
    }
    int ew = bw + l + r, eh = bh + t + b;
    uint32_t *wide = malloc((size_t)ew * (size_t)eh * 4);
    for (int y = 0; y < eh; y++) {
        int sy = y - t < 0 ? 0 : (y - t >= bh ? bh - 1 : y - t);
        const uint32_t *src = (const uint32_t *)(block + (size_t)sy * (size_t)stride);
        uint32_t *dst = wide + (size_t)y * (size_t)ew;
        for (int i = 0; i < l; i++) dst[i] = src[0];
        memcpy(dst + l, src, (size_t)bw * 4);
        for (int i = 0; i < r; i++) dst[l + bw + i] = src[bw - 1];
    }
    [_pool upload:(const uint8_t *)wide stride:ew * 4 format:format rect:(SpRectF){ bx - l, by - t, ew, eh }];
    free(wide);
}

- (void)uploadPixels:(const uint8_t *)pixels
              stride:(int)stride
              format:(uint32_t)format
               width:(int)width
              height:(int)height
                 atX:(int)x
                   y:(int)y {
    if (width <= 0 || height <= 0 || !pixels) return;
    // 24-bit pixels, and rows stored bottom first (a negative stride), are
    // brought to 32-bit rows from the top before anything else.
    uint32_t *converted = NULL;
    BOOL is24 = (format & 0x00FF0000) == 0x00180000;
    if (is24 || stride < 0) {
        int rowBytes = stride < 0 ? -stride : stride;
        converted = malloc((size_t)width * (size_t)height * 4);
        for (int r = 0; r < height; r++) {
            const uint8_t *src = pixels + (size_t)(stride < 0 ? height - 1 - r : r) * (size_t)rowBytes;
            uint32_t *dst = converted + (size_t)r * (size_t)width;
            if (is24) {
                for (int c = 0; c < width; c++)
                    dst[c] = 0xFF000000u | (uint32_t)src[c * 3 + 2] << 16 | (uint32_t)src[c * 3 + 1] << 8 | src[c * 3];
            } else {
                memcpy(dst, src, (size_t)width * 4);
            }
        }
        pixels = (const uint8_t *)converted;
        stride = width * 4;
        if (is24) format = 2132104u;   // ARGB32
    }
    SpRectF in = self.content;
    if (!_rotated) {
        // (clipped to the content: nothing may land on a neighbour)
        int w = width, h = height;
        if (x + w > (int)in.w) w = (int)in.w - x;
        if (y + h > (int)in.h) h = (int)in.h - y;
        if (x >= 0 && y >= 0 && w > 0 && h > 0)
            [self put:pixels stride:stride format:format x:(int)in.x + x y:(int)in.y + y width:w height:h];
        free(converted);
        return;
    }
    if (!format_is_32(format)) {
        WLOG("todo", "rotated surface upload in format %#x is not handled", format);
        free(converted);
        return;
    }
    // Turn the block a quarter turn: content (cx, cy) -> pool (H - 1 - cy, cx).
    int contentHeight = (int)in.w;
    int rowBytes = stride < 0 ? -stride : stride;
    uint32_t *turned = malloc((size_t)width * (size_t)height * 4);
    for (int cy = 0; cy < height; cy++) {
        const uint32_t *src = (const uint32_t *)(pixels + (size_t)cy * (size_t)rowBytes);
        for (int cx = 0; cx < width; cx++) turned[(size_t)cx * (size_t)height + (size_t)(height - 1 - cy)] = src[cx];
    }
    // The block's pool rectangle: content rows y..y+height-1 become columns.
    int px = (int)in.x + (contentHeight - y - height), py = (int)in.y + x;
    if (px >= (int)in.x && py >= (int)in.y && px + height <= (int)(in.x + in.w) && py + width <= (int)(in.y + in.h))
        [self put:(const uint8_t *)turned stride:height * 4 format:format x:px y:py width:height height:width];
    free(turned);
    free(converted);
}

- (void)spMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case SpMsg_Surface_Draw: {
            const struct Sp_RemoteSurface_Draw *m = (const void *)msg;
            SpDrawOp *op = [SpDrawOp new];
            op.kind = SpDrawSurface;
            op.surface = self;
            op.src = rectf(m->rcfSrcPxl);
            op.dst = rectf(m->rcfDestPxl);
            op.color = 0xFFFFFFFF;
            [builder(self, m->rb.value).ops addObject:op];
            break;
        }
        case SpMsg_Surface_DrawGrid: {
            const struct Sp_RemoteSurface_DrawGrid *m = (const void *)msg;
            SpDrawOp *op = [SpDrawOp new];
            op.kind = SpDrawGrid;
            op.surface = self;
            op.gx1 = m->flX1Pxl;
            op.gx2 = m->flX2Pxl;
            op.gy1 = m->flY1Pxl;
            op.gy2 = m->flY2Pxl;
            op.dst = rectf(m->rcfDestPxl);
            op.color = 0xFFFFFFFF;
            [builder(self, m->rb.value).ops addObject:op];
            break;
        }
        case SpMsg_Surface_RemapContainer: {
            const struct Sp_RemoteSurface_RemapContainer *m = (const void *)msg;
            id pool = [self.context objectForHandle:m->poolNewContainer.value];
            _pool = [pool isKindOfClass:[SpSurfacePool class]] ? pool : nil;
            break;
        }
        case SpMsg_Surface_RemapLocation: {
            const struct Sp_RemoteSurface_RemapLocation *m = (const void *)msg;
            _location = (SpRectF){ m->rcContentPxl.m_x, m->rcContentPxl.m_y, m->rcContentPxl.m_width,
                                   m->rcContentPxl.m_height };
            // The framework's packer reuses the room of surfaces it has let
            // go, and loads the newcomer's pixels later (pictures are read
            // in the background). Until then the surface must show nothing,
            // not what its predecessor left behind.
            int w = (int)_location.w, h = (int)_location.h;
            if (w > 0 && h > 0 && w < 16384 && h < 16384 && _pool.texture) {
                uint32_t *fill = malloc((size_t)w * (size_t)h * 4);
                for (size_t i = 0; i < (size_t)w * (size_t)h; i++) fill[i] = _pool.emptyColor;
                [_pool upload:(const uint8_t *)fill stride:w * 4 format:2132104u rect:_location];
                free(fill);
            }
            break;
        }
        case SpMsg_Surface_Clear: {
#ifndef SP_HAS_Sp_RemoteSurface_Clear_rcContentPxl
            // Vista's Clear names no area or colour: the whole surface goes
            // back to empty.
            int w = (int)_location.w, h = (int)_location.h;
            if (w > 0 && h > 0 && w < 16384 && h < 16384 && _pool.texture) {
                uint32_t *fill = malloc((size_t)w * (size_t)h * 4);
                for (size_t i = 0; i < (size_t)w * (size_t)h; i++) fill[i] = _pool.emptyColor;
                [_pool upload:(const uint8_t *)fill stride:w * 4 format:2132104u rect:_location];
                free(fill);
            }
#else
            const struct Sp_RemoteSurface_Clear *m = (const void *)msg;
            int w = m->rcContentPxl.m_width, h = m->rcContentPxl.m_height;
            if (w > 0 && h > 0 && w < 16384 && h < 16384) {
                uint32_t *fill = malloc((size_t)w * (size_t)h * 4);
                for (size_t i = 0; i < (size_t)w * (size_t)h; i++) fill[i] = m->clrFill.value;
                [self uploadPixels:(const uint8_t *)fill
                            stride:w * 4
                            format:2132104u
                             width:w
                            height:h
                               atX:m->rcContentPxl.m_x
                                 y:m->rcContentPxl.m_y];
                free(fill);
            }
#endif
            break;
        }
        case SpMsg_Surface_SetStorageSize: {
            const struct Sp_RemoteSurface_SetStorageSize *m = (const void *)msg;
            _storageWidth = m->sizeStoragePxl.m_width;
            _storageHeight = m->sizeStoragePxl.m_height;
            break;
        }
        case SpMsg_Surface_MarkContentValid:
        case SpMsg_Surface_SetDescription:
            break;
        case SpMsg_Surface_SetRotation:
            _rotated = ((const struct Sp_RemoteSurface_SetRotation *)msg)->fRotated != 0;
            break;
        default:
            [self spUnhandled:msg];
            return;
    }
    sp_scene_invalidate();
}

@end

// ------------------------------------------------------------------- Rasterizer

@interface SpRasterizer : SpObject
@end

@implementation SpRasterizer

// LoadRawImage is sent to the class itself, not to an instance.
+ (void)spStaticMessage:(const SpMessage *)msg context:(SpRenderContext *)context {
    if (msg->nMsg != SpMsg_Rasterizer_LoadRawImage) {
        WLOG("todo", "Rasterizer message %u is not handled", msg->nMsg);
        return;
    }
    const struct Sp_RemoteRasterizer_LoadRawImage *m = (const void *)msg;
    SpSurface *surface = [context objectForHandle:m->surContent.value];
    SpDataBuffer *buffer = [context objectForHandle:m->buffer.value];
    if (![surface isKindOfClass:[SpSurface class]] || ![buffer isKindOfClass:[SpDataBuffer class]]) {
        WLOG("err", "LoadRawImage: surface %#x or buffer %#x is missing", m->surContent.value, m->buffer.value);
        return;
    }
    int w = m->info.sizeActualPxl.m_width, h = m->info.sizeActualPxl.m_height;
    int stride = m->info.nStride;
    size_t need = (size_t)(stride < 0 ? -stride : stride) * (size_t)h;
    if (buffer.data.length < need) {
        WLOG("err", "LoadRawImage: %dx%d stride %d needs %zu bytes, buffer has %lu", w, h, stride, need,
             (unsigned long)buffer.data.length);
        return;
    }
#ifdef SP_HAS_Sp_RemoteRasterizer_LoadRawImage_offset
    int x = m->offset.m_x, y = m->offset.m_y;
#else
    int x = 0, y = 0;     // Vista: always the surface's top left
#endif
    WLOG("img", "LoadRawImage %dx%d stride %d format %#x -> surface %#x at %g,%g %gx%g%s (+%d,%d)", w, h, stride,
         m->info.nFormat, surface.handle, surface.location.x, surface.location.y, surface.location.w,
         surface.location.h, surface.rotated ? " turned" : "", x, y);
    [surface uploadPixels:buffer.data.bytes
                   stride:stride
                   format:m->info.nFormat
                    width:w
                   height:h
                      atX:x
                        y:y];
}

@end

// --------------------------------------------------------------- Gradient, Line

@implementation SpGradient

- (instancetype)init {
    if ((self = [super init])) {
        _stops = [NSMutableArray array];
        _colorMask = 0xFFFFFFFF;
    }
    return self;
}

- (void)addOp:(SpDrawKind)kind to:(uint32_t)rb {
    SpDrawOp *op = [SpDrawOp new];
    op.kind = kind;
    op.gradient = self;
    [builder(self, rb).ops addObject:op];
    sp_scene_invalidate();
}

- (void)spMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case SpMsg_Gradient_Pop: [self addOp:SpDrawGradientPop to:((const struct Sp_RemoteGradient_Pop *)msg)->rb.value]; break;
        case SpMsg_Gradient_Push: [self addOp:SpDrawGradientPush to:((const struct Sp_RemoteGradient_Push *)msg)->rb.value]; break;
        case SpMsg_Gradient_Draw: [self addOp:SpDrawGradient to:((const struct Sp_RemoteGradient_Draw *)msg)->rb.value]; break;
        case SpMsg_Gradient_Clear: [_stops removeAllObjects]; break;
        case SpMsg_Gradient_AddValue: {
            const struct Sp_RemoteGradient_AddValue *m = (const void *)msg;
#ifdef SP_HAS_Sp_RemoteGradient_AddValue_relative
            [_stops addObject:@[ @(m->flValue), @(m->flPosition), @(m->relative) ]];
#else
            [_stops addObject:@[ @(m->flValue), @(m->flPosition), @(_relative) ]];
#endif
            break;
        }
#ifdef SP_HAS_MSG_Gradient_SetRelative
        case SpMsg_Gradient_SetRelative: _relative = ((const struct Sp_RemoteGradient_SetRelative *)msg)->relative; break;
#endif
        case SpMsg_Gradient_SetOffset: _offset = ((const struct Sp_RemoteGradient_SetOffset *)msg)->flOffset; break;
        case SpMsg_Gradient_SetColorMask: _colorMask = ((const struct Sp_RemoteGradient_SetColorMask *)msg)->clrMask.value; break;
        case SpMsg_Gradient_SetOrientation: _orientation = (int)((const struct Sp_RemoteGradient_SetOrientation *)msg)->dir; break;
        default: [self spUnhandled:msg];
    }
}

@end

#ifndef WMC_XP
@interface SpLine : SpObject
@end
@implementation SpLine
- (void)spMessage:(const SpMessage *)msg {
    if (msg->nMsg > SpMsg_Line_DrawPoint) [self spUnhandled:msg];
}
@end
#endif

// ----------------------------------------------------------------------- Device

// Windows 7's and Vista's device class is NtDevice; XP Media Center
// Edition's (the one the engine says it can be) is Dx9Device, with the same
// messages under the same names.
#ifdef WMC_XP
#define DEVMSG(n) SpMsg_Dx9Device_##n
#define DEVSTRUCT(n) struct Sp_RemoteDx9Device_##n
#else
#define DEVMSG(n) SpMsg_NtDevice_##n
#define DEVSTRUCT(n) struct Sp_RemoteNtDevice_##n
#endif

@implementation SpDevice

- (void)spConstruct:(const SpMessage *)msg {
    _metal = sp_metal_device();
    if (!msg) return;
    // Every device class's Create carries the callback target in the same place.
    const DEVSTRUCT(Create) *m = (const void *)msg;
    if (msg->cbSize >= sizeof(*m)) {
        self.cbObject = m->objcb.value;
        self.cbContext = m->ctxcb.value;
    }
#ifdef SP_HAS_MSG_DeviceCallback_OnCreated
    if (self.cbObject) {
        struct Sp_LocalDeviceCallback_OnCreated cb = {0};
        cb.size = sizeof(cb);
        cb.msgid = SpMsg_DeviceCallback_OnCreated;
        cb.idObjectSubject.value = self.cbObject;
        cb.target.value = self.handle;
        cb.fAllowDynamicPool = 1;
        [self.context sendCallback:&cb toContext:self.cbContext];
    }
#endif
}

- (void)adopt:(SpObject *)obj handle:(uint32_t)handle name:(NSString *)name {
    obj.handle = handle;
    obj.context = self.context;
    obj.spClassName = name;
    [self.context registerObject:obj];
}

- (void)spMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case DEVMSG(Stop):
        case DEVMSG(Restart):
            break;
        case DEVMSG(DrawLine): {
            const DEVSTRUCT(DrawLine) *m = (const void *)msg;
            SpDrawOp *op = [SpDrawOp new];
            op.kind = SpDrawLine;
            op.color = m->clrLine.value;
            op.thickness = m->flThickness;
            op.from = vec3(m->vStart);
            op.to = vec3(m->vEnd);
            [builder(self, m->rb.value).ops addObject:op];
            break;
        }
        case DEVMSG(DrawOutline): {
            const DEVSTRUCT(DrawOutline) *m = (const void *)msg;
            SpDrawOp *op = [SpDrawOp new];
            op.kind = SpDrawOutline;
            op.color = m->clrOutline.value;
            op.thickness = m->flThickness;
            op.dst = rectf(m->rcfOutline);
            [builder(self, m->rb.value).ops addObject:op];
            break;
        }
        case DEVMSG(DrawSolid): {
            const DEVSTRUCT(DrawSolid) *m = (const void *)msg;
            SpDrawOp *op = [SpDrawOp new];
            op.kind = SpDrawSolid;
            op.color = m->clrFill.value;
            op.dst = rectf(m->rcfFill);
            [builder(self, m->rb.value).ops addObject:op];
            break;
        }
        case DEVMSG(CreateSurfacePool): {
            const DEVSTRUCT(CreateSurfacePool) *m = (const void *)msg;
            SpSurfacePool *pool = [SpSurfacePool new];
            pool.device = self;
            pool.gutterX = m->sizeGutterPxl.m_width > 0 ? m->sizeGutterPxl.m_width : 0;
            pool.gutterY = m->sizeGutterPxl.m_height > 0 ? m->sizeGutterPxl.m_height : 0;
            [self adopt:pool handle:m->idNewSurface.value name:SP_CLASS("Rendering", "SurfacePool")];
            break;
        }
#ifndef WMC_XP
        case DEVMSG(CreateVideoPool): {
            const DEVSTRUCT(CreateVideoPool) *m = (const void *)msg;
            SpVideoPool *pool = [SpVideoPool new];
            pool.device = self;
            pool.ownerObject = m->objcbOwner.value;
            pool.ownerContext = m->ctxcbOwner.value;
            [self adopt:pool handle:m->idNewSurface.value name:@"Splash::Rendering::VideoPool"];
            break;
        }
#endif
#ifndef WMC_XP
        case DEVMSG(CreateLine): {
            const DEVSTRUCT(CreateLine) *m = (const void *)msg;
            [self adopt:[SpLine new] handle:m->idLine.value name:@"Splash::Rendering::Line"];
            break;
        }
#endif
        case DEVMSG(CreateGradient): {
            const DEVSTRUCT(CreateGradient) *m = (const void *)msg;
            [self adopt:[SpGradient new] handle:m->idNewGradient.value name:SP_CLASS("Rendering", "Gradient")];
            break;
        }
        case DEVMSG(DrawNotify):
        case DEVMSG(EndVideoSurfaceAllocation):
        case DEVMSG(BeginVideoSurfaceAllocation):
        case DEVMSG(Enter3DMode):
        case DEVMSG(RenderNowIfPossible):
        case DEVMSG(CreateTransferBuffer):
#ifndef WMC_XP
        case DEVMSG(SetMaxOverscan):
        case DEVMSG(SetDisplayOverscan):
#endif
        case DEVMSG(SetEnablePageFlip):
            break;
        default:
            [self spUnhandled:msg];
            return;
    }
    sp_scene_invalidate();
}

@end

// ----------------------------------------------------------------------- Window

@implementation SpWindow

- (BOOL)windowMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
#ifdef SP_HAS_MSG_Window_SetBackgroundColor
        case SpMsg_Window_SetBackgroundColor:
            _backgroundColor = ((const struct Sp_RemoteWindow_SetBackgroundColor *)msg)->clrBack.value;
            break;
#endif
        case SpMsg_Window_SetPerspectiveSettings: {
            const struct Sp_RemoteWindow_SetPerspectiveSettings *m = (const void *)msg;
            _zNear = m->flZn;
            _zEye = m->flEye;
            break;
        }
        case SpMsg_Window_SetOutlineMarkedColor:
        case SpMsg_Window_SetOutlineAllColor:
        case SpMsg_Window_ChangeDataBits:
            break;
        case SpMsg_Window_SetContent: {
            const struct Sp_RemoteWindow_SetContent *m = (const void *)msg;
            _content = take_content(self, m->rbContent.value);
            break;
        }
        case SpMsg_Window_SetRoot: {
            const struct Sp_RemoteWindow_SetRoot *m = (const void *)msg;
            id root = [self.context objectForHandle:m->visRoot.value];
            _root = [root isKindOfClass:[SpVisual class]] ? root : nil;
            break;
        }
        default:
            return NO;
    }
    [self sceneChanged];
    return YES;
}

- (void)sceneChanged {
    sp_scene_invalidate();
}

- (void)spMessage:(const SpMessage *)msg {
    if (![self windowMessage:msg]) [self spUnhandled:msg];
}

@end

// Engine objects that accept their messages and do nothing yet.
@interface SpQuietObject : SpObject
@end
@implementation SpQuietObject
- (void)spMessage:(const SpMessage *)msg {
}
+ (void)spStaticMessage:(const SpMessage *)msg context:(SpRenderContext *)context {
}
@end

__attribute__((constructor)) static void register_scene_classes(void) {
#ifdef WMC_XP
    // XP Media Center Edition 2005: its device is a Dx9Device (the engine's
    // capabilities say Direct3D 9 is there); lights and 3D models are
    // declared but drawn as nothing.
    sp_register_class(@"Splash::RenderBuilder", [SpRenderBuilder class]);
    sp_register_class(@"Splash::Visual", [SpVisual class]);
    sp_register_class(@"Splash::SurfacePool", [SpSurfacePool class]);
    sp_register_class(@"Splash::Surface", [SpSurface class]);
    sp_register_class(@"Splash::Rasterizer", [SpRasterizer class]);
    sp_register_class(@"Splash::Gradient", [SpGradient class]);
    sp_register_class(@"Splash::Dx9Device", [SpDevice class]);
    sp_register_class(@"Splash::Window", [SpWindow class]);
    sp_register_class(@"Splash::ParticleSystem", [SpQuietObject class]);
    sp_register_class(@"Splash::Light", [SpQuietObject class]);
    sp_register_class(@"Splash::Model", [SpQuietObject class]);
#else
    sp_register_class(@"Splash::Rendering::RenderBuilder", [SpRenderBuilder class]);
    sp_register_class(@"Splash::Rendering::Visual", [SpVisual class]);
    sp_register_class(@"Splash::Rendering::SurfacePool", [SpSurfacePool class]);
    sp_register_class(@"Splash::Rendering::Surface", [SpSurface class]);
    sp_register_class(@"Splash::Rendering::Rasterizer", [SpRasterizer class]);
    sp_register_class(@"Splash::Rendering::Gradient", [SpGradient class]);
    sp_register_class(@"Splash::Rendering::Line", [SpLine class]);
    sp_register_class(@"Splash::Rendering::Device", [SpDevice class]);
    sp_register_class(@"Splash::Rendering::Dx9Device", [SpDevice class]);
    sp_register_class(@"Splash::Rendering::NullDevice", [SpDevice class]);
    sp_register_class(@"Splash::Rendering::Nt::NtDevice", [SpDevice class]);
    sp_register_class(@"Splash::Rendering::Nt::GdiDevice", [SpDevice class]);
    sp_register_class(@"Splash::Rendering::Window", [SpWindow class]);
    sp_register_class(@"Splash::Rendering::WaitCursor", [SpQuietObject class]);
    // (declared by the protocol; nothing in Media Center makes one)
    sp_register_class(@"Splash::Rendering::ParticleSystem", [SpQuietObject class]);
#endif
}
