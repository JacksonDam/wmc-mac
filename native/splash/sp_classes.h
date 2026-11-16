// Interfaces of the engine classes that other engine classes need to see.
#pragma once
#import "sp.h"

// Splash::Messaging::DataBuffer: bulk bytes (pixels, samples) sent beside
// the message stream and referenced from later messages by handle.
@interface SpDataBuffer : SpObject
@property (nonatomic, strong) NSData *data;
- (void)receiveData:(NSData *)data;
@end
