/*
 * RFC 6455 opcode and size-limit constants shared between convexws.prg
 * (frame encode/decode) and convexlive.prg (the Live sync state machine
 * that reads decoded frames). Harbour's #define is scoped to the single
 * .prg file the compiler is preprocessing, not to the whole build the way
 * a C #define spanning translation units linked together would be, so
 * every file that tests a frame's opcode needs its own #include of this
 * header rather than relying on convexws.prg's copy.
 */

#ifndef CONVEXWS_CH_
#define CONVEXWS_CH_

#define CONVEX_WS_OP_CONTINUATION 0
#define CONVEX_WS_OP_TEXT 1
#define CONVEX_WS_OP_BINARY 2
#define CONVEX_WS_OP_CLOSE 8
#define CONVEX_WS_OP_PING 9
#define CONVEX_WS_OP_PONG 10

/* One 2^21-byte frame cap and one 2^22-byte reassembled-message cap: both
 * comfortably above any real Convex sync message, both small enough that
 * a hostile or broken peer cannot make this client allocate without
 * bound. */
#define CONVEX_WS_MAX_FRAME 2097152
#define CONVEX_WS_MAX_MESSAGE 4194304

#endif
