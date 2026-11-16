#import "sp_render.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <simd/simd.h>

typedef struct {
    vector_float4 pos;
    vector_float2 uv;
    vector_float4 color;
} SpVertex;

static NSString *const kShaderSource = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Vertex { float4 pos; float2 uv; float4 color; };\n"
    "struct Varying { float4 pos [[position]]; float2 uv; float4 color; };\n"
    "vertex Varying sp_vertex(uint vid [[vertex_id]], const device Vertex *v [[buffer(0)]]) {\n"
    "    Varying o; o.pos = v[vid].pos; o.uv = v[vid].uv; o.color = v[vid].color; return o;\n"
    "}\n"
    "fragment float4 sp_fragment(Varying in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
    "                            sampler smp [[sampler(0)]]) {\n"
    "    return tex.sample(smp, in.uv) * in.color;\n"
    "}\n";

typedef struct {
    NSUInteger first, count;
} SpBatchRange;

// A gradient in force while part of the scene is drawn. A gradient is a
// one-dimensional ramp of values along the x or y axis of the visual that
// declared it; it scales the alpha (and, through its colour mask, the colour)
// of everything drawn in that visual's subtree. With hard stops it is how
// the framework clips; with soft ones, how it fades edges.
#define SP_MAX_GRADIENTS 16
#define SP_MAX_STOPS 8
typedef struct {
    matrix_float4x4 toOwner;       // window pixels -> the declaring visual's coordinates
    int vertical;
    int count;
    float pos[SP_MAX_STOPS], val[SP_MAX_STOPS];
    float mask[4];                 // r g b a: how much of each channel the ramp scales
} SpActiveGradient;

@implementation SpRenderer {
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLSamplerState> _sampler;
    id<MTLTexture> _white;
    NSMutableData *_vertices;
    NSMutableArray<id<MTLTexture>> *_batchTextures;
    NSMutableData *_batchRanges;
    float _width, _height;
    // Perspective (the window's eye and near plane, see -render:): how far
    // the eye is from the screen plane in pixels (0: no perspective), and
    // the near plane's distance as a share of that.
    float _eye, _near;
    SpActiveGradient _gradients[SP_MAX_GRADIENTS];
    int _gradientCount;
}

+ (instancetype)shared {
    static SpRenderer *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [SpRenderer new]; });
    return r;
}

- (instancetype)init {
    if ((self = [super init])) {
        _device = sp_metal_device();
        _queue = [_device newCommandQueue];
        NSError *error = nil;
        // Metal Shading Language 2.3, the newest macOS 11 has: the shaders
        // compile the same on every macOS this runs on.
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion2_3;
        id<MTLLibrary> lib = [_device newLibraryWithSource:kShaderSource options:options error:&error];
        if (!lib) WLOG("err", "shader compile failed: %s", error.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"sp_vertex"];
        d.fragmentFunction = [lib newFunctionWithName:@"sp_fragment"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        d.colorAttachments[0].blendingEnabled = YES;
        // Surfaces carry straight (not premultiplied) alpha, as Direct3D's
        // default blend expects.
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        _pipeline = [_device newRenderPipelineStateWithDescriptor:d error:&error];
        if (!_pipeline) WLOG("err", "pipeline failed: %s", error.localizedDescription.UTF8String);
        MTLSamplerDescriptor *s = [MTLSamplerDescriptor new];
        s.minFilter = MTLSamplerMinMagFilterLinear;
        s.magFilter = MTLSamplerMinMagFilterLinear;
        s.sAddressMode = MTLSamplerAddressModeClampToEdge;
        s.tAddressMode = MTLSamplerAddressModeClampToEdge;
        _sampler = [_device newSamplerStateWithDescriptor:s];
        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:1
                                                                                    height:1
                                                                                 mipmapped:NO];
        _white = [_device newTextureWithDescriptor:t];
        uint32_t px = 0xFFFFFFFF;
        [_white replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&px bytesPerRow:4];
        _vertices = [NSMutableData data];
        _batchTextures = [NSMutableArray array];
        _batchRanges = [NSMutableData data];
    }
    return self;
}

// ---- geometry -----------------------------------------------------------------

static vector_float4 color4(uint32_t argb, float alpha) {
    return (vector_float4){ ((argb >> 16) & 0xFF) / 255.0f, ((argb >> 8) & 0xFF) / 255.0f, (argb & 0xFF) / 255.0f,
                            ((argb >> 24) & 0xFF) / 255.0f * alpha };
}

static uint32_t modulate(uint32_t a, uint32_t b) {
    uint32_t out = 0;
    for (int shift = 0; shift < 32; shift += 8) {
        uint32_t x = (a >> shift) & 0xFF, y = (b >> shift) & 0xFF;
        out |= ((x * y + 127) / 255) << shift;
    }
    return out;
}

- (void)quad:(SpRectF)dst
          uv:(SpRectF)uv
     texture:(id<MTLTexture>)texture
       color:(vector_float4)color
      matrix:(matrix_float4x4)m {
    vector_float2 corners[4] = { { uv.x, uv.y }, { uv.x + uv.w, uv.y }, { uv.x, uv.y + uv.h }, { uv.x + uv.w, uv.y + uv.h } };
    [self quad:dst corners:corners texture:texture color:color matrix:m];
}

// The texture coordinates of a surface's content rectangle, as the four
// corners (top left, top right, bottom left, bottom right) in the pool.
static void surface_corners(SpSurface *s, SpRectF src, vector_float2 out[4]) {
    SpSurfacePool *pool = s.pool;
    float pw = pool.width, ph = pool.height;
    SpRectF loc = s.content;
    float xs[2] = { src.x, src.x + src.w }, ys[2] = { src.y, src.y + src.h };
    for (int i = 0; i < 4; i++) {
        float cx = xs[i & 1], cy = ys[i >> 1];
        if (s.rotated) out[i] = (vector_float2){ (loc.x + loc.w - cy) / pw, (loc.y + cx) / ph };
        else out[i] = (vector_float2){ (loc.x + cx) / pw, (loc.y + cy) / ph };
    }
}

static float gradient_value(const SpActiveGradient *g, float x) {
    if (g->count == 0) return 1;
    if (x <= g->pos[0]) return g->val[0];
    for (int i = 1; i < g->count; i++) {
        if (x <= g->pos[i]) {
            float span = g->pos[i] - g->pos[i - 1];
            return span > 0 ? g->val[i - 1] + (g->val[i] - g->val[i - 1]) * (x - g->pos[i - 1]) / span : g->val[i];
        }
    }
    return g->val[g->count - 1];
}

// The colour of a vertex at window point p, after every active gradient.
- (vector_float4)shade:(vector_float4)color at:(vector_float4)p {
    for (int i = 0; i < _gradientCount; i++) {
        const SpActiveGradient *g = &_gradients[i];
        vector_float4 o = matrix_multiply(g->toOwner, (vector_float4){ p.x, p.y, 0, 1 });
        float keep = gradient_value(g, g->vertical ? o.y : o.x);
        if (keep >= 1) continue;
        color.x *= 1 - g->mask[0] * (1 - keep);
        color.y *= 1 - g->mask[1] * (1 - keep);
        color.z *= 1 - g->mask[2] * (1 - keep);
        color.w *= 1 - g->mask[3] * (1 - keep);
    }
    return color;
}

// Where the gradients' stops cross a quad, in the quad's own 0..1 range
// along x (axis 0) or y (axis 1). Only for gradients whose axes line up with
// the quad's (no rotation between them); others are sampled at the corners.
- (int)cutsAlong:(int)axis dst:(SpRectF)dst matrix:(matrix_float4x4)m into:(float *)cuts max:(int)max {
    int n = 0;
    cuts[n++] = 0;
    for (int i = 0; i < _gradientCount; i++) {
        const SpActiveGradient *g = &_gradients[i];
        matrix_float4x4 t = matrix_multiply(g->toOwner, m);
        if (fabsf(t.columns[0].y) > 1e-4f || fabsf(t.columns[1].x) > 1e-4f) continue;
        // Owner coordinate along the gradient's axis as a function of the quad's x or y.
        float scale = g->vertical ? t.columns[1].y : t.columns[0].x;
        float offset = g->vertical ? t.columns[3].y : t.columns[3].x;
        if ((g->vertical ? 1 : 0) != axis || fabsf(scale) < 1e-6f) continue;
        float start = axis ? dst.y : dst.x, length = axis ? dst.h : dst.w;
        for (int k = 0; k < g->count && n < max - 1; k++) {
            float f = ((g->pos[k] - offset) / scale - start) / length;
            if (f > 0.0005f && f < 0.9995f) cuts[n++] = f;
        }
    }
    cuts[n++] = 1;
    // Sort (few entries) and drop duplicates.
    for (int i = 1; i < n; i++) {
        float v = cuts[i];
        int j = i - 1;
        while (j >= 0 && cuts[j] > v) { cuts[j + 1] = cuts[j]; j--; }
        cuts[j + 1] = v;
    }
    int out = 1;
    for (int i = 1; i < n; i++) if (cuts[i] - cuts[out - 1] > 1e-5f) cuts[out++] = cuts[i];
    return out;
}

- (void)quad:(SpRectF)dst
     corners:(const vector_float2 *)uvs
     texture:(id<MTLTexture>)texture
       color:(vector_float4)color
      matrix:(matrix_float4x4)m {
    if (dst.w == 0 || dst.h == 0) return;
    if (!texture) texture = _white;
    float xc[2 + SP_MAX_GRADIENTS * SP_MAX_STOPS], yc[2 + SP_MAX_GRADIENTS * SP_MAX_STOPS];
    int nx = 2, ny = 2;
    xc[0] = yc[0] = 0;
    xc[1] = yc[1] = 1;
    if (_gradientCount) {
        nx = [self cutsAlong:0 dst:dst matrix:m into:xc max:(int)(sizeof(xc) / sizeof(xc[0]))];
        ny = [self cutsAlong:1 dst:dst matrix:m into:yc max:(int)(sizeof(yc) / sizeof(yc[0]))];
    }
    if (_batchTextures.count == 0 || _batchTextures.lastObject != texture) {
        [_batchTextures addObject:texture];
        SpBatchRange r = { _vertices.length / sizeof(SpVertex), 0 };
        [_batchRanges appendBytes:&r length:sizeof(r)];
    }
    static const int order[6][2] = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 0 }, { 1, 1 }, { 0, 1 } };
    for (int iy = 0; iy + 1 < ny; iy++) {
        for (int ix = 0; ix + 1 < nx; ix++) {
            float fx[2] = { xc[ix], xc[ix + 1] }, fy[2] = { yc[iy], yc[iy + 1] };
            SpVertex v[6];
            BOOL visible = _gradientCount == 0;
            for (int i = 0; i < 6; i++) {
                float u = fx[order[i][0]], w = fy[order[i][1]];
                vector_float4 p = matrix_multiply(m, (vector_float4){ dst.x + dst.w * u, dst.y + dst.h * w, 0, 1 });
                // Pixels (origin top left, y down) to clip space. A point
                // behind the screen plane (z > 0) is further from the eye
                // and so drawn nearer the middle of the window: the divide
                // by w does that, and keeps pictures on tilted quads right.
                float far = _eye > 0 ? 1 + p.z / _eye : 1;
                v[i].pos = (vector_float4){ p.x / _width * 2 - 1, 1 - p.y / _height * 2, _eye > 0 ? far - _near : 0, far };
                vector_float2 top = simd_mix(uvs[0], uvs[1], u), bottom = simd_mix(uvs[2], uvs[3], u);
                v[i].uv = simd_mix(top, bottom, w);
                v[i].color = _gradientCount ? [self shade:color at:p] : color;
                if (v[i].color.w > 0) visible = YES;
            }
            if (!visible) continue;   // wholly faded out: this is the clipped part
            [_vertices appendBytes:v length:sizeof(v)];
            SpBatchRange *ranges = _batchRanges.mutableBytes;
            ranges[_batchTextures.count - 1].count += 6;
            _lastQuads++;
        }
    }
}

// Puts a gradient in force. `m` is the declaring visual's matrix and `size`
// its size: stop positions are measured from its near or far edge.
- (void)pushGradient:(SpGradient *)g matrix:(matrix_float4x4)m size:(SpVec3)size {
    if (_gradientCount >= SP_MAX_GRADIENTS || fabsf(simd_determinant(m)) < 1e-9f) return;
    SpActiveGradient *a = &_gradients[_gradientCount];
    memset(a, 0, sizeof(*a));
    a->toOwner = simd_inverse(m);
    a->vertical = g.orientation == 1;
    float extent = a->vertical ? size.y : size.x;
    for (NSArray<NSNumber *> *stop in g.stops) {
        if (a->count >= SP_MAX_STOPS) break;
        int relative = stop[2].intValue;   // 0 near edge, 1 far edge (2 and 3: the same, of the drawn mesh)
        float pos = stop[1].floatValue + g.offset + ((relative == 1 || relative == 3) ? extent : 0);
        a->pos[a->count] = pos;
        a->val[a->count] = stop[0].floatValue;
        a->count++;
    }
    for (int i = 1; i < a->count; i++) {   // ascending by position
        float p = a->pos[i], v = a->val[i];
        int j = i - 1;
        while (j >= 0 && a->pos[j] > p) { a->pos[j + 1] = a->pos[j]; a->val[j + 1] = a->val[j]; j--; }
        a->pos[j + 1] = p;
        a->val[j + 1] = v;
    }
    uint32_t mask = g.colorMask;
    a->mask[0] = ((mask >> 16) & 0xFF) / 255.0f;
    a->mask[1] = ((mask >> 8) & 0xFF) / 255.0f;
    a->mask[2] = (mask & 0xFF) / 255.0f;
    a->mask[3] = (mask >> 24) / 255.0f;
    _gradientCount++;
}

static matrix_float4x4 translation(float x, float y, float z) {
    matrix_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = (vector_float4){ x, y, z, 1 };
    return m;
}

static matrix_float4x4 scaling(float x, float y, float z) {
    matrix_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = x;
    m.columns[1].y = y;
    m.columns[2].z = z;
    return m;
}

static matrix_float4x4 rotation(SpVec3 axis, float angle) {
    float len = sqrtf(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z);
    if (angle == 0 || len == 0) return matrix_identity_float4x4;
    float x = axis.x / len, y = axis.y / len, z = axis.z / len, c = cosf(angle), s = sinf(angle), t = 1 - c;
    matrix_float4x4 m = matrix_identity_float4x4;
    m.columns[0] = (vector_float4){ t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0 };
    m.columns[1] = (vector_float4){ t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0 };
    m.columns[2] = (vector_float4){ t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0 };
    return m;
}

static matrix_float4x4 visual_matrix(SpVisual *v, matrix_float4x4 parent);

// `size` is the size of the visual (or window) the list belongs to. A
// destination with a negative size means "the whole visual".
- (void)drawOps:(SpRenderBuilder *)rb
           size:(SpVec3)size
         matrix:(matrix_float4x4)m
          alpha:(float)alpha
           tint:(uint32_t)tint {
    // A gradient "drawn" into a visual applies to all of it, whatever the
    // order in the list; the caller removes it after the visual's children.
    for (SpDrawOp *op in rb.ops) {
        if (op.kind == SpDrawGradient) [self pushGradient:op.gradient matrix:m size:size];
    }
    int base = _gradientCount;
    for (SpDrawOp *op in rb.ops) {
        vector_float4 color = color4(modulate(op.color, tint), alpha);
        SpRectF dst = op.dst;
        if (dst.w < 0 || dst.h < 0) dst = (SpRectF){ 0, 0, size.x, size.y };
        switch (op.kind) {
            case SpDrawSolid:
                [self quad:dst uv:(SpRectF){ 0, 0, 1, 1 } texture:nil color:color matrix:m];
                break;
            case SpDrawSurface:
            case SpDrawGrid: {
                SpSurface *s = op.surface;
                SpSurfacePool *pool = s.pool;
                if (!pool.texture) break;
                SpRectF loc = s.content;
                // The content's own size (the pool rectangle is turned for a rotated surface).
                float cw = s.rotated ? loc.h : loc.w, ch = s.rotated ? loc.w : loc.h;
                vector_float2 uvs[4];
                if (op.kind == SpDrawSurface) {
                    SpRectF src = op.src;
                    if (src.w <= 0 || src.h <= 0) src = (SpRectF){ 0, 0, cw, ch };   // (0 or -1: the whole surface)
                    surface_corners(s, src, uvs);
                    [self quad:dst corners:uvs texture:pool.texture color:color matrix:m];
                } else {
                    // Nine-grid: corners keep their size, edges and centre stretch.
                    // The four numbers are insets from the left, right, top
                    // and bottom edges of the image.
                    float left = op.gx1, right = op.gx2, top = op.gy1, bottom = op.gy2;
                    float sx[4] = { 0, left, cw - right, cw }, sy[4] = { 0, top, ch - bottom, ch };
                    float dx[4] = { dst.x, dst.x + left, dst.x + dst.w - right, dst.x + dst.w };
                    float dy[4] = { dst.y, dst.y + top, dst.y + dst.h - bottom, dst.y + dst.h };
                    for (int r = 0; r < 3; r++) {
                        for (int c = 0; c < 3; c++) {
                            SpRectF d = { dx[c], dy[r], dx[c + 1] - dx[c], dy[r + 1] - dy[r] };
                            SpRectF part = { sx[c], sy[r], sx[c + 1] - sx[c], sy[r + 1] - sy[r] };
                            if (d.w <= 0 || d.h <= 0) continue;
                            surface_corners(s, part, uvs);
                            [self quad:d corners:uvs texture:pool.texture color:color matrix:m];
                        }
                    }
                }
                break;
            }
            case SpDrawPool: {
                SpSurfacePool *pool = op.pool;
                if (!pool.texture) break;
                SpRectF uv = { op.src.x / pool.width, op.src.y / pool.height, op.src.w / pool.width,
                               op.src.h / pool.height };
                [self quad:dst uv:uv texture:pool.texture color:color matrix:m];
                break;
            }
            case SpDrawOutline: {
                float t = op.thickness > 0 ? op.thickness : 1;
                SpRectF d = dst, full = { 0, 0, 1, 1 };
                [self quad:(SpRectF){ d.x, d.y, d.w, t } uv:full texture:nil color:color matrix:m];
                [self quad:(SpRectF){ d.x, d.y + d.h - t, d.w, t } uv:full texture:nil color:color matrix:m];
                [self quad:(SpRectF){ d.x, d.y + t, t, d.h - 2 * t } uv:full texture:nil color:color matrix:m];
                [self quad:(SpRectF){ d.x + d.w - t, d.y + t, t, d.h - 2 * t } uv:full texture:nil color:color matrix:m];
                break;
            }
            case SpDrawLine: {
                // Axis-aligned lines are the common case (separators).
                float t = op.thickness > 0 ? op.thickness : 1;
                float x0 = fminf(op.from.x, op.to.x), x1 = fmaxf(op.from.x, op.to.x);
                float y0 = fminf(op.from.y, op.to.y), y1 = fmaxf(op.from.y, op.to.y);
                SpRectF d = { x0, y0, fmaxf(x1 - x0, t), fmaxf(y1 - y0, t) };
                [self quad:d uv:(SpRectF){ 0, 0, 1, 1 } texture:nil color:color matrix:m];
                break;
            }
            case SpDrawGradientPush:
                [self pushGradient:op.gradient matrix:m size:size];
                break;
            case SpDrawGradientPop:
                if (_gradientCount > base) _gradientCount--;
                break;
            default:
                break;   // SpDrawGradient was put in force before the list was drawn
        }
    }
}

- (void)emit:(SpVisual *)v matrix:(matrix_float4x4)parent alpha:(float)alpha tint:(uint32_t)tint depth:(int)depth {
    if (!v.visible || depth > 256) return;
    _lastVisuals++;
    float a = alpha * v.alpha;
    if (a <= 0) return;
    uint32_t t = modulate(tint, v.color);
    matrix_float4x4 m = visual_matrix(v, parent);
    int gradients = _gradientCount;
    if (v.content) [self drawOps:v.content size:v.size matrix:m alpha:a tint:t];
    for (SpVisual *child in v.children) [self emit:child matrix:m alpha:a tint:t depth:depth + 1];
    _gradientCount = gradients;
}

// ---- hit testing ---------------------------------------------------------------
// Which visual is under a window point. A visual's data bits say whether the
// search may go into its children (traverse), whether it can be hit itself
// (hit), and whether it may be reported as the receiver (result): the
// receiver is the hit visual or its nearest ancestor that has that bit.

static matrix_float4x4 visual_matrix(SpVisual *v, matrix_float4x4 parent) {
    SpVec3 size = v.size, cs = v.centerScale, co = v.centerOffset, sc = v.scale;
    float cx = size.x * cs.x + co.x, cy = size.y * cs.y + co.y, cz = size.z * cs.z + co.z;
    matrix_float4x4 m = matrix_multiply(parent, translation(v.position.x, v.position.y, v.position.z));
    if (sc.x != 1 || sc.y != 1 || sc.z != 1 || v.angle != 0) {
        m = matrix_multiply(m, translation(cx, cy, cz));
        m = matrix_multiply(m, rotation(v.axis, v.angle));
        m = matrix_multiply(m, scaling(sc.x, sc.y, sc.z));
        m = matrix_multiply(m, translation(-cx, -cy, -cz));
    }
    return m;
}

static BOOL local_point(matrix_float4x4 m, float x, float y, float out[2]) {
    if (fabsf(simd_determinant(m)) < 1e-9f) return NO;
    vector_float4 p = matrix_multiply(simd_inverse(m), (vector_float4){ x, y, 0, 1 });
    out[0] = p.x;
    out[1] = p.y;
    return YES;
}

static SpVisual *hit_visual(SpVisual *v, matrix_float4x4 parent, float x, float y, uint32_t traverse, uint32_t hit,
                            matrix_float4x4 *found, int depth) {
    if (!v.visible || depth > 256) return nil;
    matrix_float4x4 m = visual_matrix(v, parent);
    if (v.dataBits & traverse) {
        for (SpVisual *child in v.children.reverseObjectEnumerator) {   // front to back
            SpVisual *h = hit_visual(child, m, x, y, traverse, hit, found, depth + 1);
            if (h) return h;
        }
    }
    if (v.dataBits & hit) {
        float p[2];
        if (local_point(m, x, y, p) && p[0] >= 0 && p[1] >= 0 && p[0] < v.size.x && p[1] < v.size.y) {
            *found = m;
            return v;
        }
    }
    return nil;
}

static matrix_float4x4 world_matrix(SpVisual *v) {
    NSMutableArray<SpVisual *> *chain = [NSMutableArray array];
    for (SpVisual *p = v; p; p = p.parent) [chain insertObject:p atIndex:0];
    matrix_float4x4 m = matrix_identity_float4x4;
    for (SpVisual *p in chain) m = visual_matrix(p, m);
    return m;
}

BOOL sp_hit_test(SpWindow *window, float x, float y, float width, float height, uint32_t traverse, uint32_t hit,
                 uint32_t result, uint32_t *subject, float subjectPoint[2], uint32_t *natural, float naturalPoint[2]) {
    *subject = *natural = 0;
    if (!window.root) return NO;
    matrix_float4x4 m;
    SpVisual *v = hit_visual(window.root, matrix_identity_float4x4, x, y, traverse, hit, &m, 0);
    if (!v) return NO;
    *natural = v.handle;
    local_point(m, x, y, naturalPoint);
    SpVisual *receiver = v;
    while (receiver && !(receiver.dataBits & result)) receiver = receiver.parent;
    if (!receiver) receiver = v;
    *subject = receiver.handle;
    if (receiver == v) {
        subjectPoint[0] = naturalPoint[0];
        subjectPoint[1] = naturalPoint[1];
    } else {
        local_point(world_matrix(receiver), x, y, subjectPoint);
    }
    return YES;
}

// ---- drawing ------------------------------------------------------------------

- (void)render:(SpWindow *)window target:(id<MTLTexture>)target commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    _width = target.width;
    _height = target.height;
    _vertices.length = 0;
    _batchRanges.length = 0;
    [_batchTextures removeAllObjects];
    _lastQuads = 0;
    _lastVisuals = 0;
    _gradientCount = 0;
    // The framework gives the eye's place and the near plane in units of
    // its own (-4 and 2 as shipped). The unit is taken to be half the
    // window's width, so the eye is two window widths in front of the
    // screen: nothing on the reference recording shows a tilted visual to
    // check this against.
    _eye = window.zEye != 0 ? fabsf(window.zEye) * _width / 2 : 0;
    _near = window.zEye != 0 && window.zNear > 0 ? fminf(window.zNear / fabsf(window.zEye), 0.95f) : 0;
    if (window.content) {
        [self drawOps:window.content
                 size:(SpVec3){ _width, _height, 0 }
               matrix:matrix_identity_float4x4
                alpha:1
                 tint:0xFFFFFFFF];
    }
    if (window.root) [self emit:window.root matrix:matrix_identity_float4x4 alpha:1 tint:0xFFFFFFFF depth:0];

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    uint32_t bg = window.backgroundColor;
    pass.colorAttachments[0].clearColor =
        MTLClearColorMake(((bg >> 16) & 0xFF) / 255.0, ((bg >> 8) & 0xFF) / 255.0, (bg & 0xFF) / 255.0, 1);
    id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (_vertices.length && _pipeline) {
        id<MTLBuffer> vb = [_device newBufferWithBytes:_vertices.bytes
                                                length:_vertices.length
                                               options:MTLResourceStorageModeShared];
        [enc setRenderPipelineState:_pipeline];
        [enc setVertexBuffer:vb offset:0 atIndex:0];
        [enc setFragmentSamplerState:_sampler atIndex:0];
        const SpBatchRange *ranges = _batchRanges.bytes;
        for (NSUInteger i = 0; i < _batchTextures.count; i++) {
            [enc setFragmentTexture:_batchTextures[i] atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:ranges[i].first vertexCount:ranges[i].count];
        }
    }
    [enc endEncoding];
}

// Writes the scene tree to the log ("scene" channel): what the framework has
// asked the engine to draw.
static void dump_ops(SpRenderBuilder *rb, int indent) {
    static const char *const kinds[] = { "solid", "surface", "grid", "pool", "outline", "line", "gradient-push",
                                         "gradient-pop", "gradient", "notify" };
    for (SpDrawOp *op in rb.ops) {
        if (op.gradient) {
            NSMutableString *stops = [NSMutableString string];
            for (NSArray<NSNumber *> *st in op.gradient.stops) {
                [stops appendFormat:@" %g@%g%s", st[0].floatValue, st[1].floatValue,
                                    (st[2].intValue == 1 || st[2].intValue == 3) ? "(far)" : ""];
            }
            wmc_log("scene", "%*s- %s %s offset %g mask %08x stops%s", indent, "", kinds[op.kind],
                    op.gradient.orientation == 1 ? "vertical" : "horizontal", op.gradient.offset,
                    op.gradient.colorMask, stops.UTF8String);
            continue;
        }
        wmc_log("scene", "%*s- %s color %08x dst %g,%g %gx%g src %g,%g %gx%g%s", indent, "", kinds[op.kind], op.color,
                op.dst.x, op.dst.y, op.dst.w, op.dst.h, op.src.x, op.src.y, op.src.w, op.src.h,
                op.surface ? [NSString stringWithFormat:@" surface %#x at %g,%g %gx%g pool %#x %dx%d", op.surface.handle,
                              op.surface.location.x, op.surface.location.y, op.surface.location.w,
                              op.surface.location.h, op.surface.pool.handle, op.surface.pool.width,
                              op.surface.pool.height].UTF8String : "");
    }
}

static void dump_visual(SpVisual *v, int indent) {
    wmc_log("scene", "%*svisual %#x%s pos %g,%g,%g size %g,%g scale %g,%g alpha %.2f color %08x%s%s%s", indent, "",
            v.handle, v.visible ? "" : " HIDDEN", v.position.x, v.position.y, v.position.z, v.size.x, v.size.y,
            v.scale.x, v.scale.y, v.alpha, v.color, v.angle != 0 ? " rotated" : "", v.debugID.length ? " id " : "",
            v.debugID.length ? v.debugID.UTF8String : "");
    if (v.content) dump_ops(v.content, indent + 2);
    for (SpVisual *c in v.children) dump_visual(c, indent + 2);
}

static BOOL write_png(NSData *bgra, int width, int height, BOOL alpha, NSString *path) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bgra);
    CGImageRef image = CGImageCreate((size_t)width, (size_t)height, 8, 32, (size_t)width * 4, space,
                                     kCGBitmapByteOrder32Little | (alpha ? kCGImageAlphaFirst : kCGImageAlphaNoneSkipFirst),
                                     provider, NULL, false, kCGRenderingIntentDefault);
    BOOL ok = NO;
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    if (dest && image) {
        CGImageDestinationAddImage(dest, image, NULL);
        ok = CGImageDestinationFinalize(dest);
    }
    if (dest) CFRelease(dest);
    if (image) CGImageRelease(image);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    return ok;
}

// Debugging aid (WMC_DUMP_POOLS=<folder>): writes every texture the scene
// draws from, so that what was uploaded can be told apart from how it is drawn.
static void collect_pools(SpVisual *v, NSMutableSet<SpSurfacePool *> *pools) {
    for (SpDrawOp *op in v.content.ops) {
        if (op.surface.pool) [pools addObject:op.surface.pool];
        if (op.pool) [pools addObject:op.pool];
    }
    for (SpVisual *c in v.children) collect_pools(c, pools);
}

static void dump_pools(SpWindow *window, NSString *folder) {
    NSMutableSet<SpSurfacePool *> *pools = [NSMutableSet set];
    if (window.root) collect_pools(window.root, pools);
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    for (SpSurfacePool *pool in pools) {
        if (!pool.texture) continue;
        NSMutableData *px = [NSMutableData dataWithLength:(NSUInteger)pool.width * (NSUInteger)pool.height * 4];
        [pool.texture getBytes:px.mutableBytes
                   bytesPerRow:(NSUInteger)pool.width * 4
                    fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)pool.width, (NSUInteger)pool.height)
                   mipmapLevel:0];
        write_png(px, pool.width, pool.height, YES,
                  [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"pool_%x.png", pool.handle]]);
    }
}

- (BOOL)snapshot:(SpWindow *)window width:(int)width height:(int)height toPath:(NSString *)path {
    if (width <= 0 || height <= 0) return NO;
    if (getenv("WMC_DUMP_POOLS")) dump_pools(window, @(getenv("WMC_DUMP_POOLS")));
    if (wmc_log_enabled("scene")) {
        wmc_log("scene", "window %#x background %08x", window.handle, window.backgroundColor);
        if (window.content) dump_ops(window.content, 2);
        if (window.root) dump_visual(window.root, 2);
    }
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:(NSUInteger)width
                                                                                height:(NSUInteger)height
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [_device newTextureWithDescriptor:d];
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    [self render:window target:target commandBuffer:cb];
    [cb commit];
    [cb waitUntilCompleted];
    NSMutableData *pixels = [NSMutableData dataWithLength:(NSUInteger)width * (NSUInteger)height * 4];
    [target getBytes:pixels.mutableBytes
         bytesPerRow:(NSUInteger)width * 4
          fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
         mipmapLevel:0];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGImageRef image = CGImageCreate((size_t)width, (size_t)height, 8, 32, (size_t)width * 4, space,
                                     kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    BOOL ok = NO;
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    if (dest && image) {
        CGImageDestinationAddImage(dest, image, NULL);
        ok = CGImageDestinationFinalize(dest);
    }
    if (dest) CFRelease(dest);
    if (image) CGImageRelease(image);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    WLOG("sp", "snapshot %dx%d: %d visuals, %d quads -> %s%s", width, height, _lastVisuals, _lastQuads,
         path.UTF8String, ok ? "" : " (FAILED)");
    return ok;
}

@end
