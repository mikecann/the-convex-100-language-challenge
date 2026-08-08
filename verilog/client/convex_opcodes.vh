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
`define CMD_RANDOM_BYTE       8

// Added for the conformance adapter and canonical example, which (unlike
// every gate proof and unit test before them) must read commands from a
// real stdin or an accepted ADAPTER_LISTEN connection, read CONVEX_URL
// from the environment, and shut down with a real process exit code -
// mirroring vhdl/client/convex_native.vhdl's CMD_GETENV_*/CMD_WAIT_READY*/
// CMD_STDIN_READ_BYTE/CMD_EXIT/CMD_LISTEN/CMD_ACCEPT set exactly, opcode
// numbers included, since nothing about their shape is Verilog-specific.
`define CMD_GETENV_RESET      9
`define CMD_GETENV_PUSH       10
`define CMD_GETENV_LOOKUP     11
`define CMD_GETENV_BYTE       12
`define CMD_WAIT_READY        13
`define CMD_WAIT_READY_STDIN  14
`define CMD_STDIN_READ_BYTE   15

`define CMD_STDOUT_WRITE_BYTE 16
`define CMD_STDOUT_FLUSH      17
`define CMD_STDERR_WRITE_BYTE 18

`define CMD_EXIT              19
`define CMD_LISTEN            20
`define CMD_ACCEPT            21

`endif
