// The engine's object model: handles, classes, and the four "Messaging"
// classes every connection starts with (Broker, Context, DataBuffer,
// ContextRelay).
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "sp.h"
#import "sp_classes.h"

// ----------------------------------------------------------- class registry

static NSMutableDictionary<NSString *, Class> *s_classes;

void sp_register_class(NSString *protocolName, Class impl) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s_classes = [NSMutableDictionary dictionary]; });
    @synchronized(s_classes) { s_classes[protocolName] = impl; }
}

Class sp_lookup_class(NSString *protocolName) {
    @synchronized(s_classes) { return s_classes[protocolName]; }
}

const char *sp_message_name(NSString *className, uint32_t msgid) {
    if (!className) return "?";
    const char *name = className.UTF8String;
    for (const SpProtoClass *c = sp_proto_classes; c->class_name; c++) {
        if (strcmp(c->class_name, name) == 0) {
            if ((int)msgid < c->count && c->msg_names[msgid]) return c->msg_names[msgid];
            break;
        }
    }
    return "?";
}

// ------------------------------------------------------------------ SpObject

@implementation SpObject {
    uint64_t _unhandledSeen;
}

- (void)spConstruct:(const SpMessage *)msg {
}

- (void)spMessage:(const SpMessage *)msg {
    [self spUnhandled:msg];
}

- (void)spDestroy {
}

+ (void)spStaticMessage:(const SpMessage *)msg context:(SpRenderContext *)context {
    WLOG("todo", "static message %u for %s is not handled", msg->nMsg, class_getName(self));
}

- (void)spUnhandled:(const SpMessage *)msg {
    uint64_t bit = msg->nMsg < 64 ? (1ull << msg->nMsg) : 0;
    if (bit && (_unhandledSeen & bit)) return;
    _unhandledSeen |= bit;
    WLOG("todo", "%s.%s (msg %u, %u bytes) is not handled", self.spClassName.UTF8String,
         sp_message_name(self.spClassName, msg->nMsg), msg->nMsg, msg->cbSize);
}

@end

@implementation SpClassObject
@end

// Stands in for any remote class nobody has written yet, so that creating
// one and talking to it is logged instead of failing.
@interface SpGenericObject : SpObject
@end
@implementation SpGenericObject
@end

// -------------------------------------------------------------- SpDataBuffer

@implementation SpDataBuffer

- (void)spMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case SpMsg_DataBuffer_RegisterOwner: {
            const struct Sp_RemoteDataBuffer_RegisterOwner *m = (const void *)msg;
            self.cbObject = m->objcb.value;
            self.cbContext = m->ctxcb.value;
            // The bytes were copied when they arrived, so the owner can let
            // go of its copy straight away.
            if (self.data) [self notifyComplete];
            break;
        }
        default:
            [self spUnhandled:msg];
    }
}

- (void)notifyComplete {
    if (!self.cbObject) return;
    struct Sp_LocalDataBufferCallback_OnComplete cb = {0};
    cb.size = sizeof(cb);
    cb.msgid = SpMsg_DataBufferCallback_OnComplete;
    cb.idObjectSubject.value = self.cbObject;
    cb.target.value = self.handle;
    [self.context sendCallback:&cb toContext:self.cbContext];
}

- (void)receiveData:(NSData *)data {
    self.data = data;
    [self notifyComplete];
}

@end

// ----------------------------------------------------------- SpRenderContext

@implementation SpRenderContext {
    NSMutableDictionary<NSNumber *, SpObject *> *_objects;
    NSMutableDictionary<NSNumber *, NSData *> *_earlyData;
    uint32_t _brokerClass;
    int _groupShift;
    uint32_t _groupMask;
    BOOL _inBatch;
}

- (instancetype)initWithArgs:(const SpInitArgs *)args {
    if ((self = [super init])) {
        _contextId = args->idContext;
        _objects = [NSMutableDictionary dictionary];
        _earlyData = [NSMutableDictionary dictionary];
        _brokerClass = args->idObjectBrokerClass;
        _groupShift = args->cItemsPerGroupBits;
        _groupMask = ((1u << args->cGroupBits) - 1) << _groupShift;
        SpClassObject *broker = [SpClassObject new];
        broker.handle = _brokerClass;
        broker.context = self;
        broker.spClassName = @"Splash::Messaging::Broker";
        broker.impl = nil;   // handled inline in -dispatch:
        _objects[@(_brokerClass)] = broker;
    }
    return self;
}

- (id)objectForHandle:(uint32_t)handle {
    return handle ? _objects[@(handle)] : nil;
}

- (void)registerObject:(SpObject *)object {
    _objects[@(object.handle)] = object;
}

- (void)removeObject:(uint32_t)handle {
    SpObject *o = _objects[@(handle)];
    if (!o) return;
    [o spDestroy];
    [_objects removeObjectForKey:@(handle)];
}

- (void)destroyGroup:(uint32_t)group {
    NSMutableArray<NSNumber *> *doomed = [NSMutableArray array];
    for (NSNumber *h in _objects) {
        if (((h.unsignedIntValue & _groupMask) >> _groupShift) == group && h.unsignedIntValue != _brokerClass) {
            [doomed addObject:h];
        }
    }
    for (NSNumber *h in doomed) [self removeObject:h.unsignedIntValue];
}

- (void)sendCallback:(const void *)msg toContext:(uint32_t)contextId {
    const SpMessage *m = msg;
    SpBufferInfo info = {
        .idContextSrc = _contextId,
        .idContextDest = contextId,
        .idBuffer = 0,
        .nFlags = SpBufferCopyData,
        .cbSizeBuffer = m->cbSize,
    };
    sp_post_buffer(info, msg);
}

// A buffer is one of: a single message; one block of a batch (a linked list
// of messages; the last block of a batch has no buffer id); or the bytes of
// a DataBuffer object.
- (void)processBuffer:(SpBufferInfo)info data:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    if (info.nFlags & SpBufferIsBatch) {
        if (!_inBatch) {
            _inBatch = YES;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
        }
        if (data.length >= 8) {
            uint32_t off = *(const uint32_t *)(bytes + 4);   // uOffsetFirstEntry
            int guard = 0;
            while (off && off + 4 + sizeof(SpMessage) <= data.length && guard++ < 1000000) {
                uint32_t next = *(const uint32_t *)(bytes + off);
                const SpMessage *msg = (const SpMessage *)(bytes + off + 4);
                if (off + 4 + msg->cbSize > data.length) {
                    WLOG("err", "batch message overruns its block (%u + %u > %lu)", off, msg->cbSize,
                         (unsigned long)data.length);
                    break;
                }
                [self dispatch:msg];
                off = next;
            }
        }
        if (info.idBuffer == 0) {
            _inBatch = NO;
            [CATransaction commit];
        }
    } else if (info.idBuffer != 0) {
        // A data buffer is not created by a message: sending bytes under a
        // new handle is what creates it. Its owner registers afterwards.
        SpObject *target = [self objectForHandle:info.idBuffer];
        if (!target) {
            SpDataBuffer *buffer = [SpDataBuffer new];
            buffer.handle = info.idBuffer;
            buffer.context = self;
            buffer.spClassName = @"Splash::Messaging::DataBuffer";
            [self registerObject:buffer];
            target = buffer;
        }
        if ([target isKindOfClass:[SpDataBuffer class]]) [(SpDataBuffer *)target receiveData:data];
        WLOG("msg", "data buffer %#x: %lu bytes", info.idBuffer, (unsigned long)data.length);
    } else if (data.length >= sizeof(SpMessage)) {
        [self dispatch:(const SpMessage *)bytes];
    }
}

- (void)dispatch:(const SpMessage *)msg {
    SpObject *target = [self objectForHandle:msg->idObjectSubject];
    if (!target) {
        WLOG("err", "message %u for unknown object %#x", msg->nMsg, msg->idObjectSubject);
        return;
    }
    if (wmc_log_enabled("msg")) {
        wmc_log("msg", "%s%s %#x: %s (%u, %u bytes)", [target isKindOfClass:[SpClassObject class]] ? "class " : "",
                target.spClassName.UTF8String, msg->idObjectSubject,
                sp_message_name(target.spClassName, msg->nMsg), msg->nMsg, msg->cbSize);
    }
    if (msg->idObjectSubject == _brokerClass) {
        [self brokerMessage:msg];
    } else if ([target isKindOfClass:[SpClassObject class]]) {
        SpClassObject *cls = (SpClassObject *)target;
        if ([cls.spClassName isEqualToString:@"Splash::Messaging::Context"]) [self contextMessage:msg];
        else [cls.impl spStaticMessage:msg context:self];
    } else {
        [target spMessage:msg];
    }
}

- (void)brokerMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case SpMsg_Broker_CreateClass: {
            const struct Sp_RemoteBroker_CreateClass *m = (const void *)msg;
            NSString *name = sp_blob_string(msg, m->stClassName.value);
            SpClassObject *cls = [SpClassObject new];
            cls.handle = m->idObjectClass.value;
            cls.context = self;
            cls.spClassName = name;
            cls.impl = sp_lookup_class(name);
            if (!cls.impl) {
                cls.impl = [SpGenericObject class];
                WLOG("todo", "class %s has no implementation yet", name.UTF8String);
            }
            [self registerObject:cls];
            break;
        }
        case SpMsg_Broker_CreateObject: {
            const struct Sp_RemoteBroker_CreateObject *m = (const void *)msg;
            SpClassObject *cls = [self objectForHandle:m->idObjectClass.value];
            if (![cls isKindOfClass:[SpClassObject class]]) {
                WLOG("err", "CreateObject of unknown class %#x", m->idObjectClass.value);
                break;
            }
            uint32_t len = 0;
            const SpMessage *ctor = (const SpMessage *)sp_blob(msg, m->msgConstruction.value, &len);
            SpObject *obj = [[cls.impl alloc] init];
            obj.handle = m->idObjectNew.value;
            obj.context = self;
            obj.spClassName = cls.spClassName;
            [self registerObject:obj];
            if (wmc_log_enabled("msg")) {
                wmc_log("msg", "  new %s %#x via %s", cls.spClassName.UTF8String, obj.handle,
                        len >= sizeof(SpMessage) ? sp_message_name(cls.spClassName, ctor->nMsg) : "(no message)");
            }
            [obj spConstruct:len >= sizeof(SpMessage) ? ctor : NULL];
            if ([obj isKindOfClass:[SpDataBuffer class]]) {
                NSData *early = _earlyData[@(obj.handle)];
                if (early) {
                    [_earlyData removeObjectForKey:@(obj.handle)];
                    [(SpDataBuffer *)obj receiveData:early];
                }
            }
            break;
        }
        case SpMsg_Broker_DestroyObject: {
            const struct Sp_RemoteBroker_DestroyObject *m = (const void *)msg;
            [self removeObject:m->idObject.value];
            break;
        }
        default:
            WLOG("todo", "Broker message %u is not handled", msg->nMsg);
    }
}

- (void)contextMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case SpMsg_Context_ForwardMessage: {
            // The framework asks for a message of its own to be sent back to
            // it once the engine reaches this point: its "batch processed"
            // and "ping" receipts.
            const struct Sp_RemoteContext_ForwardMessage *m = (const void *)msg;
            uint32_t len = 0;
            const uint8_t *inner = sp_blob(msg, m->msgReturn.value, &len);
            SpBufferInfo info = {
                .idContextSrc = _contextId,
                .idContextDest = m->idContextDest.value,
                .nFlags = SpBufferCopyData,
                .cbSizeBuffer = len,
            };
            sp_post_buffer(info, inner);
            break;
        }
        case SpMsg_Context_CreateGroup:
            break;
        case SpMsg_Context_DestroyGroup: {
            const struct Sp_RemoteContext_DestroyGroup *m = (const void *)msg;
            [self destroyGroup:(uint32_t)m->idxGroup];
            break;
        }
        case SpMsg_Context_ReleaseObject:
            break;
        default:
            WLOG("todo", "Context message %u is not handled", msg->nMsg);
    }
}

@end

__attribute__((constructor)) static void register_messaging_classes(void) {
    sp_register_class(@"Splash::Messaging::DataBuffer", [SpDataBuffer class]);
    sp_register_class(@"Splash::Messaging::Context", [SpObject class]);
    sp_register_class(@"Splash::Messaging::ContextRelay", [SpGenericObject class]);
}
