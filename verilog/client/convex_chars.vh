// convex_chars.vh - byte constants for characters that cannot be spelled
// safely inside a SystemVerilog `string` literal on this project's
// pinned Icarus Verilog 11.0.
//
// Probed directly: `s = "a\"b"; $display(s.len());` prints 6, not 3 -
// Icarus's `string`-literal lexer expands `\"` into the four literal
// source characters of its own octal-escape spelling (backslash, '0',
// '4', '2') instead of the single byte 0x22 the SystemVerilog LRM
// requires. The same bug affects `\\` (a lone backslash). Every other
// standard escape (`\n`, `\r`, `\t`) was not affected by this bug, but
// this client avoids all of them here too and spells every one of these
// bytes as an explicit constant, concatenated into a `string` with
// `{ "literal ", `DQUOTE, " more literal" }`, rather than risk a second
// undiscovered case of the same class.
`ifndef CONVEX_CHARS_VH
`define CONVEX_CHARS_VH

`define DQUOTE    8'h22
`define BACKSLASH 8'h5c
`define CR        8'h0d
`define LF        8'h0a
`define TAB       8'h09

`endif
