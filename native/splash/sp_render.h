// Draws a window's scene with Metal: into a drawable for the screen, or into
// an offscreen texture for snapshots and tests.
#pragma once
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import "sp_scene.h"

@interface SpRenderer : NSObject
+ (instancetype)shared;
// Renders into `target`, whose size is the window's client size in pixels.
- (void)render:(SpWindow *)window
        target:(id<MTLTexture>)target
 commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
// Renders offscreen and writes a PNG. Returns NO on failure.
- (BOOL)snapshot:(SpWindow *)window width:(int)width height:(int)height toPath:(NSString *)path;
@property (nonatomic, readonly) id<MTLCommandQueue> queue;
// Counts from the last render, for the log and for tests.
@property (nonatomic, readonly) int lastQuads, lastVisuals;
@end
