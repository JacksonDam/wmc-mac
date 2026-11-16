// The render engine stand-in ("Splash" is the protocol's own name for it).
//
// Media Center's UI framework never draws. It describes the scene to a
// separate render engine in fixed-layout messages: create a class, create an
// object of it, set a visual's position, start an animation. On Windows the
// engine is EhUI.dll drawing with Direct3D 9. Here it is this folder, drawing
// with Core Animation. The message layouts come from the framework's own
// metadata (build/gen/splash_protocol.h).
//
// Threads: the framework's "application" thread sends buffers; everything in
// the engine runs on the Mac's main thread, which also owns AppKit.
#pragma once
#import <Foundation/Foundation.h>
#include "wmc.h"
#include "threadq.h"
#include "splash_protocol.h"

typedef struct {
    uint32_t cbSize;
    uint32_t nMsg;
    uint32_t idObjectSubject;
} SpMessage;

typedef struct {
    uint32_t idContextSrc;
    uint32_t idContextDest;
    uint32_t idBuffer;
    uint32_t nFlags;
    uint32_t cbSizeBuffer;
} SpBufferInfo;

enum { SpBufferIsBatch = 1, SpBufferCopyData = 2, SpBufferHeapFree = 4 };

typedef int32_t (*SpProcessBufferProc)(void *pData, uint32_t hContext, SpBufferInfo *info, void *data);

// RenderApi.InitArgs as Mono marshals it.
typedef struct {
    uint32_t cbSize;
    uint32_t idContext;
    int32_t cItemsPerGroupBits;
    int32_t cGroupBits;
    void *pfnProcessBuffer;
    void *pvProcessData;
    uint32_t idObjectBrokerClass;
    void (*pfnTimeout)(void *);
    void *pvTimeoutData;
    uint32_t nTimeOutSec;
} SpInitArgs;

// Inline data ("blobs") follow a message's fixed part. A reference is
// offset-from-message-start in the low word and byte length in the high word.
static inline const uint8_t *sp_blob(const void *msg, uint32_t ref, uint32_t *len) {
    if (len) *len = ref >> 16;
    return (const uint8_t *)msg + (ref & 0xFFFF);
}
NSString *sp_blob_string(const void *msg, uint32_t ref);   // UTF-16 with terminator

@class SpRenderContext;

// Base of every engine-side object the framework can create.
@interface SpObject : NSObject
@property (nonatomic) uint32_t handle;
@property (nonatomic, weak) SpRenderContext *context;
@property (nonatomic, copy) NSString *spClassName;
// Where to send this object's callbacks: an object on the application side
// and the context it lives in. Zero when the class has no callbacks.
@property (nonatomic) uint32_t cbObject;
@property (nonatomic) uint32_t cbContext;
- (void)spConstruct:(const SpMessage *)msg;
- (void)spMessage:(const SpMessage *)msg;
- (void)spDestroy;
+ (void)spStaticMessage:(const SpMessage *)msg context:(SpRenderContext *)context;
// Logs a message this class does not handle yet (once per message id).
- (void)spUnhandled:(const SpMessage *)msg;
@end

// A registered remote class: maps a handle to the Objective-C class that
// implements it.
@interface SpClassObject : SpObject
@property (nonatomic, strong) Class impl;
@end

@interface SpRenderContext : NSObject
@property (nonatomic, readonly) uint32_t contextId;
- (instancetype)initWithArgs:(const SpInitArgs *)args;
- (id)objectForHandle:(uint32_t)handle;
- (void)registerObject:(SpObject *)object;
- (void)removeObject:(uint32_t)handle;
- (void)destroyGroup:(uint32_t)group;
- (void)processBuffer:(SpBufferInfo)info data:(NSData *)data;
- (void)dispatch:(const SpMessage *)msg;
// Sends a callback message (cbSize bytes are copied) to an application context.
- (void)sendCallback:(const void *)msg toContext:(uint32_t)contextId;
@end

// Engine classes register themselves by protocol name from +load.
void sp_register_class(NSString *protocolName, Class impl);
Class sp_lookup_class(NSString *protocolName);

// Message names for logging (build/gen/splash_protocol_names.c).
typedef struct {
    const char *class_name;
    const char *const *msg_names;
    int count;
} SpProtoClass;
extern const SpProtoClass sp_proto_classes[];
const char *sp_message_name(NSString *className, uint32_t msgid);

// Send a buffer to whichever context owns the id. Used by SpBufferOpen and
// by message forwarding.
HRESULT sp_post_buffer(SpBufferInfo info, const void *data);

// Runs a block on the main thread and waits; runs inline if already there.
void sp_main_sync(void (^block)(void));
