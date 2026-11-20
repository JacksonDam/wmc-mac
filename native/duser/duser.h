// XP Media Center Edition 2002's engine (ehui.dll's DirectUser "Smooth"
// renderer, and ehuihlp.dll's drawing objects), built only for 2002
// (WMC_XP2002). The other Media Centers use the Splash engine (native/splash).
//
// The framework (EhCM.dll, "Fast") makes three remote classes by name,
// DUser::Smooth::RenderAgent, ::FormWindow and ::AnimationHelper, and is told
// the number of each method by DUserSmoothFindClass. It posts messages to a
// proxy (DUserPostMethod): RenderAgent's own, or any object's wrapped by the
// "MessageForwarderProxy" method with a trailer naming the object and its
// method; batches are lists of messages in its own memory, given back with a
// "batch completed" callback. Callbacks go to the framework's listener
// gadget as event 0x8400, addressed to an object's handle (its "cookie").
//
// Here a visual is a Core Animation layer: a rectangle in its parent, shown
// or not, faded, scaled about a point, drawn with a list of render
// operations (pictures, text, fills) made through ehuihlp.dll's functions.
// Everything the engine does runs on the main thread.
#pragma once
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include "wmc.h"
#include "threadq.h"
#include "duser_protocol.h"

enum { DU_CALLBACK = 0x8400 };          // the event a callback arrives as

// ---- gadgets (duser_core.m) ----------------------------------------------------

typedef uint32_t (*DuGadgetProc)(void *hgad, int32_t data, void *msg);

// Delivers a message to a gadget's procedure on the thread that made the
// gadget (a copy of `size` bytes; the message's hgadMsg is set).
void du_gadget_post(void *hgad, const void *msg, uint32_t size);

// ---- objects (duser_agent.m) -----------------------------------------------------

// A render operation: what ehuihlp.dll's *CreateRenderOperation functions
// return, and what a visual is drawn with. Reference counted by the
// framework (EhObjectAddRef/Release); kept alive here while drawn.
typedef NS_ENUM(int, DuOpKind) { DuOpImage, DuOpText, DuOpFill, DuOpSurface };

@interface DuImage : NSObject
@property (nonatomic) CGImageRef image;      // (retained)
@property (nonatomic) int width, height;
@end

@interface DuText : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *face;
@property (nonatomic) CGFloat px;            // font size in pixels
@property (nonatomic) BOOL bold, italic;
@property (nonatomic) uint32_t color, bkColor;   // COLORREF (0x00BBGGRR)
@property (nonatomic) int flags;
@property (nonatomic) CGFloat scaleX, scaleY, spacing;
- (CGSize)measure:(int)maxWidth;
- (CGImageRef)render:(CGSize *)size;         // (caller releases)
@end

@interface DuOp : NSObject
@property (nonatomic) DuOpKind kind;
@property (nonatomic, strong) DuImage *image;
@property (nonatomic, strong) DuText *text;
@property (nonatomic) uint32_t color;        // fills: 0xAARRGGBB
@property (nonatomic) CGRect src, dst;       // empty: the whole picture / visual
@property (nonatomic) BOOL hasSrc, hasDst;
@property (nonatomic) int surface;           // video: its surface (duser_video.m)
@end

// Video surfaces (duser_video.m): small numbers, not objects.
bool du_is_surface(const void *p);
void du_video_attach(CALayer *layer, int surface, CGRect source, bool hasSource);
void du_video_tick(void);

// The objects the framework counts references to (sessions, pictures, text,
// operations) are handed out as retained pointers.
void *du_object_out(id object);
id du_object_in(void *pointer);

// Reports to the framework (duser_core.m).
// A callback record the caller has built (its ownerCookie, ownerMessage and
// fields): the header is filled in and it is posted to the listener.
void du_callback_post(void *record, uint32_t size);
// One that carries nothing more.
void du_callback(uint32_t cookie, uint32_t ownerMessage);

void du_agent_dispatch(const struct Du_DUser_Msg *msg);   // main thread
void du_agent_start(uint32_t rootCookie);                  // main thread
void du_agent_stop(void);

// The method numbers the framework is given, one per known method.
enum {
    DU_RA_FORWARD = 1, DU_RA_BATCH, DU_RA_CREATE_GROUP, DU_RA_DELETE_GROUP, DU_RA_DELETE_OBJECT, DU_RA_SHUTDOWN,
    DU_RA_SHELL_EXEC, DU_RA_CREATE_FORM, DU_RA_CREATE_VISUAL, DU_RA_CREATE_ANIMATION, DU_RA_SET_STYLE,
    DU_RA_SET_PARENT, DU_RA_SET_RECT, DU_RA_SET_DESCRIPTION, DU_RA_SET_ALPHA, DU_RA_SET_SCALE, DU_RA_SET_CENTER,
    DU_RA_SET_LIGHT, DU_RA_REMOVE_LIGHT, DU_RA_SET_OPS,
    DU_FW_CREATE_ROOT = 101, DU_FW_SET_OPTIONS, DU_FW_SET_MOUSE_IDLE, DU_FW_SET_STYLES, DU_FW_SET_CURSORS,
    DU_FW_SET_ICON, DU_FW_SET_SIZE, DU_FW_SET_POSITION, DU_FW_SET_VISIBLE, DU_FW_SET_MODE, DU_FW_RESTORE,
    DU_FW_FORCE_MOUSE_IDLE, DU_FW_TAKE_FOCUS, DU_FW_SET_FOREGROUND, DU_FW_UPDATE, DU_FW_CLOSE, DU_FW_SET_TEXT,
    DU_FW_SHOW_HELP, DU_FW_SET_SYS_COMMAND, DU_FW_SET_CAPTURE, DU_FW_SET_BACKGROUND, DU_FW_SET_PRE_ROS,
    DU_AH_ADD_LIGHT = 201, DU_AH_ADD_RECT, DU_AH_ADD_ALPHA, DU_AH_ADD_SCALE, DU_AH_PLAY, DU_AH_STOP,
};

// A blob a message carries: offset from the message's start in the low
// word, length in the high word.
static inline const uint8_t *du_blob(const void *msg, uint32_t ref, uint32_t *len) {
    if (len) *len = ref >> 16;
    return (const uint8_t *)msg + (ref & 0xFFFF);
}
NSString *du_blob_string(const void *msg, uint32_t ref);   // UTF-16, terminated
