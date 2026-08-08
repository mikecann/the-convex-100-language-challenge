// convex_opcodes.vh - the CMD_* constants every caller of
// transport.xport_call uses, kept textually in sync with the `enum` of
// the same name in client/native.c. Neither side can `include` the
// other's language, so this pairing is manual; a mismatch here would
// make a request silently dispatch to the wrong native.c handler, so any
// change to one side must be mirrored in the other in the same commit.

`ifndef CONVEX_OPCODES_VH
`define CONVEX_OPCODES_VH

`define CMD_NOP               0
`define CMD_HOST_RESET        1
`define CMD_HOST_PUSH         2
`define CMD_CONNECT           3
`define CMD_CLOSE             4
`define CMD_WRITE_BYTE        5
`define CMD_WRITE_FLUSH       6
`define CMD_READ_BYTE         7
`define CMD_STDOUT_WRITE_BYTE 16
`define CMD_STDOUT_FLUSH      17
`define CMD_STDERR_WRITE_BYTE 18

`endif
