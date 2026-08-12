// Shiki covers the mainstream languages well, but this project deliberately
// goes far beyond the mainstream. These small TextMate grammars provide an
// honest lexical baseline for languages without a maintained bundled grammar.
// They colour the constructs a reader needs first: comments, strings, numbers,
// core keywords, types, and function calls. They do not claim semantic IDE
// knowledge, and can be replaced one-for-one when a stronger grammar appears.

const splitWords = (value = "") => value.trim().split(/\s+/).filter(Boolean);
const escapeRegex = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

const profiles = {
  c: { lineComments: ["//"], blockComments: [["/*", "*/"]] },
  lisp: { lineComments: [";"] },
  ml: { blockComments: [["(*", "*)"]] },
  pascal: {
    blockComments: [
      ["(*", "*)"],
      ["{", "}"],
    ],
  },
};

const specs = {
  seed7: {
    profile: "ml",
    keywords:
      "and begin block case catch const do downto else elsif end exception for func if in include is local not of otherwise proc raise repeat result return step then to until var when while",
    types:
      "array boolean char file float func integer jsonArray jsonObject jsonValue proc string",
  },
  fennel: {
    profile: "lisp",
    keywords:
      "and collect do each eval-compiler fn for global hashfn if include lambda length let local lua macro macrodebug match not not= or partial pick-values quote require set set-forcibly tset values var when while",
    types: "false nil true",
  },
  icon: {
    lineComments: ["#"],
    keywords:
      "break by case create default do else end every fail global if initial link local next not of procedure record repeat return static suspend then to until while",
    types: "co-expression cset file integer list null real set string table",
  },
  rexx: {
    blockComments: [["/*", "*/"]],
    caseInsensitive: true,
    keywords:
      "address arg by call do drop else end exit expose forever forward guard if interpret iterate leave nop numeric options otherwise parse procedure pull push queue reply return say select signal then to trace until upper when while with",
  },
  c3: {
    profile: "c",
    keywords:
      "alias assert asm bitstruct break case catch const continue default defer distinct do else enum extern fault faultdef fn for foreach if import inline interface macro module nextcase return static struct switch try typedef union var while",
    types:
      "any bool char double float int long short uint ulong ushort void String CLongLong",
  },
  snobol4: {
    lineCommentPatterns: ["^\\s*\\*.*$"],
    caseInsensitive: true,
    keywords:
      "abort array code convert copy data define differ dupl eq eval field ge gt ident integer item le lgt local lt ne opsyn prototype remdr replace rewind size sort table time trim unload",
    types: "array code expression integer name pattern real string table",
  },
  lolcode: {
    lineCommentPatterns: ["\\bBTW\\b.*$"],
    blockCommentPatterns: [["\\bOBTW\\b", "\\bTLDR\\b"]],
    caseInsensitive: true,
    keywords:
      "A AN ANY OF BOTH SAEM DIFFRINT EITHER OF FOUND YR GIMMEH GTFO HAI HAS HOW IZ I IF U SAY SO IM IN YR IM OUTTA YR ITZ KTHXBYE MAEK MKAY MEBBE NOT O RLY OIC OMG OMGWTF R SMOOSH SO NO WAI SUM OF TIL UPPIN VISIBLE WTF YA RLY YR",
    types: "BUKKIT FAIL NOOB NUMBAR NUMBR TROOF WIN YARN",
  },
  clean: {
    profile: "c",
    keywords:
      "case class code constructor definition derive dynamic export foreign from generic if implementation import in infix infixl infixr instance let macro module of otherwise special system where with",
    types: "Bool Char File Int Real String World",
  },
  "standard-ml": {
    profile: "ml",
    keywords:
      "abstype and andalso as case datatype do else end eqtype exception fn fun functor handle if in include infix infixr let local nonfix of op open orelse raise rec sharing sig signature struct structure then type val where while with withtype",
    types: "bool char exn int list option real ref string unit vector word",
  },
  ats: {
    lineComments: ["//"],
    blockComments: [
      ["(*", "*)"],
      ["%{", "%}"],
    ],
    keywords:
      "abstype absview absviewtype and as assume begin case classdec datasort datatype dataprop dataview datavtype do dynload else end exception extern fn for fun if implement in include lam let local macdef nonfix of overload praxi prfun stadef staload static then typedef val var viewdef viewtypedef when where while with",
    types:
      "bool char double int lint llint ptr size_t ssize_t string uint ulint ullint void",
  },
  harbour: {
    profile: "c",
    caseInsensitive: true,
    keywords:
      "ANNOUNCE BEGIN SEQUENCE BREAK CASE CLASS CREATE DEFAULT DESCRIPTION DO EACH ELSE ELSEIF END ENDCASE ENDDO ENDFUNCTION ENDIF ENDCLASS ENDSEQUENCE EXIT EXTERNAL FIELD FOR FUNCTION IF INHERIT LOCAL LOOP METHOD NEXT OTHERWISE PRIVATE PROCEDURE PROTECTED PUBLIC RECOVER REQUEST RETURN STATIC STEP SWITCH TO WHILE WITH OBJECT",
    types:
      "ARRAY BLOCK CHARACTER CODEBLOCK DATE HASH LOGICAL NIL NUMERIC OBJECT STRING",
  },
  rebol: {
    lineComments: [";"],
    keywords:
      "alias all any as ask attempt break catch cause-error change collect compose context continue do either else exit export extend foreach forever forskip forall func function get has if import in let loop make module next object parse quote reduce repeat return reverse set switch throw try unless until use while",
    types:
      "binary bitset block char date decimal email error file function get-word hash image integer issue list logic map money none object pair paren path percent port refinement set-path set-word string tag time tuple typeset url vector word",
  },
  bcpl: {
    lineComments: ["//"],
    blockComments: [["/*", "*/"]],
    caseInsensitive: true,
    keywords:
      "AND BE BREAK BY DO ELSE EQ EQV FALSE FINISH FOR GOTO GR IF INTO LET LOOP MANIFEST MATCH NEQV NOT OR REM REPEAT RESULTIS RETURN RV SECTNEEDS STATIC SWITCHON TEST THEN TO TRUE UNLESS UNTIL VALOF VEC WHILE",
  },
  blitzmax: {
    lineComments: ["'"],
    blockCommentPatterns: [["\\bRem\\b", "\\bEnd Rem\\b"]],
    caseInsensitive: true,
    keywords:
      "Abstract Alias And Asc Assert Byte Case Catch Const Continue Data Default Delete Each Else ElseIf End Enum Exit Extern Field Final Finally Float For Forever Framework Function Global If Import Include Incbin In Int Interface Local Long Method Mod Module New Next Not Null Object Or Private Public Read Repeat Return Select Short Step Strict Super Then Throw To Try Type Until Wend While Xor",
    types: "Byte Double Float Int Long Object Short String UInt ULong",
  },
  freebasic: {
    lineComments: ["'"],
    lineCommentPatterns: ["(?i:\\bREM\\b).*"],
    caseInsensitive: true,
    keywords:
      "AS ASM BYREF BYVAL CASE CONST CONTINUE DECLARE DIM DO ELSE ELSEIF END ENUM EXIT EXTERN FOR FUNCTION IF IMPORT LIB LOCAL NAMESPACE NEXT OPERATOR PRIVATE PROPERTY PROTECTED PUBLIC REDIM RETURN SELECT SHARED STATIC STEP SUB THEN TO TYPE UNION UNTIL USING WEND WHILE WITH",
    types:
      "ANY PTR BYTE DOUBLE INTEGER LONG LONGINT SHORT SINGLE STRING UBYTE UINTEGER ULONG ULONGINT USHORT ZSTRING",
  },
  io: {
    profile: "c",
    lineComments: ["//", "#"],
    keywords:
      "and block break catch clone continue do doFile doString else elseif exception for foreach forward getSlot hasSlot if ifError isNil isTrue lazySlot list loop method nil not or pass perform raise return self setSlot super then try updateSlot wait while with",
    types:
      "Block CFunction Call Coroutine Date Duration Exception File List Map Message Number Object Sequence System Vector",
  },
  j: {
    lineCommentPatterns: ["\\bNB\\..*$"],
    keywords:
      "assert break case catch catchd catcht continue do else elseif end fcase for for_i goto if label return select throw try while whilst",
  },
  clu: {
    lineComments: ["%"],
    caseInsensitive: true,
    keywords:
      "any begin break cand cluster continue cor cvt do down except exit exports false for force from has hidden if in is iter iterator nil not null oneof others own proc proctype record rep resignal return returns sequence signal signals struct tagcase then true type up variant when where while yield yields",
    types: "array bool char int null real sequence string",
  },
  hare: {
    profile: "c",
    keywords:
      "abort alloc append as assert bool break case const continue defer delete else enum export fn for free if insert is let match nullable offset return static struct switch type union use vastart vaarg vaend void yield",
    types:
      "bool char done error f32 f64 i16 i32 i64 i8 int never null opaque rune size str u16 u32 u64 u8 uint uintptr valist void",
  },
  pli: {
    blockComments: [["/*", "*/"]],
    caseInsensitive: true,
    keywords:
      "ALLOCATE BEGIN BY CALL CLOSE DECLARE DEFAULT DELETE DESCRIBED DO ELSE END ENTRY EXIT EXTERNAL FILE FINISH FIXED FLOAT FORMAT FREE GET GO GOTO IF INITIAL INPUT LABEL LIKE OPTIONS OUTPUT PROCEDURE PUT READ RETURN RETURNS SELECT SIGNAL STATIC THEN TO UNTIL UPDATE VALUE VARYING WHEN WHILE WRITE",
    types:
      "AREA BINARY BIT CHARACTER COMPLEX DECIMAL FILE FIXED FLOAT LABEL OFFSET PICTURE POINTER VARYING",
  },
  "modula-2": {
    profile: "ml",
    caseInsensitive: true,
    keywords:
      "AND ARRAY BEGIN BY CASE CONST DEFINITION DIV DO ELSE ELSIF END EXIT EXPORT FOR FROM IF IMPLEMENTATION IMPORT IN LOOP MOD MODULE NOT OF OR POINTER PROCEDURE QUALIFIED RECORD REPEAT RETURN SET THEN TO TYPE UNTIL VAR WHILE WITH",
    types: "BITSET BOOLEAN CARDINAL CHAR INTEGER LONGINT LONGREAL REAL WORD",
  },
  ring: {
    profile: "c",
    lineComments: ["#", "//"],
    caseInsensitive: true,
    keywords:
      "again and but bye call case catch changeringkeyword class def do done else elseif end exit for foreach from func function give if import in load loop new next not off ok on or package private put raise return see step switch to try while",
    types: "list number object string",
  },
  mercury: {
    lineComments: ["%"],
    blockComments: [["/*", "*/"]],
    keywords:
      "all_true cc_multi cc_nondet semidet det else end_module erroneous failure func if impure implementation import_module in initialise instance interface is mode module multi nondet pred promise_pure semipure solver_some then type typeclass use_module where",
    types: "bool char float int io list map maybe string uint",
  },
  oberon: {
    profile: "ml",
    caseInsensitive: true,
    keywords:
      "ARRAY BEGIN BY CASE CONST DIV DO ELSE ELSIF END EXIT FOR IF IMPORT IN IS LOOP MOD MODULE NIL OF OR POINTER PROCEDURE RECORD REPEAT RETURN THEN TO TYPE UNTIL VAR WHILE WITH",
    types: "BOOLEAN BYTE CHAR INTEGER LONGINT REAL SET",
  },
  xpl: {
    blockComments: [["/*", "*/"]],
    caseInsensitive: true,
    keywords:
      "BASED BIT CALL CHARACTER DECLARE DO ELSE END EOF GO GOTO IF INITIAL LABEL LITERALLY PROCEDURE RETURN THEN TO WHILE",
    types: "BIT CHARACTER FIXED POINTER",
  },
  algol60: {
    blockCommentPatterns: [["\\bcomment\\b", ";"]],
    caseInsensitive: true,
    keywords:
      "array begin Boolean code comment do else end false for go goto if integer label own procedure real step string switch then true until value while",
    types: "Boolean integer real string",
  },
  simula: {
    blockCommentPatterns: [
      ["\\bcomment\\b", ";"],
      ["!", ";"],
    ],
    caseInsensitive: true,
    keywords:
      "activate after array at before begin boolean character class delay detach do else end external false for go goto hidden if imp label inner inspect integer is in new none notext otherwise prior procedure protected qua reactivate real ref resume simset simulation step switch text then this to true until value virtual when while",
    types: "boolean character integer long real ref text",
  },
  dylan: {
    profile: "c",
    keywords:
      "above afterwards begin below block by case cleanup create define domain dynamic-bind each-subclass else elseif end exception finally for from function handler if in instance let local method otherwise select signal slot subclass then to unless until variable virtual while",
    types:
      "class collection condition false-or float function integer method object sequence string symbol table type union vector",
  },
  forth: {
    lineCommentPatterns: ["\\\\.*$"],
    blockCommentPatterns: [["\\(\\s", "\\)"]],
    caseInsensitive: true,
    keywords:
      "again begin case constant create defer do does else endcase endof execute exit if immediate leave literal loop of postpone recurse repeat then to until value variable while",
    types: "cell char double float number string",
  },
  pony: {
    profile: "c",
    keywords:
      "actor addressof and as be break class compile_error compile_intrinsic consume continue delegate digestof do else elseif embed end error for fun if ifdef in interface is isnt lambda let match new not object or primitive recover ref repeat return tag then this trait trn try type until use var where while with xor",
    types:
      "Array Bool Env F32 F64 I128 I16 I32 I64 I8 Int None String U128 U16 U32 U64 U8 ULong USize",
  },
  idris: {
    lineComments: ["--"],
    blockComments: [["{-", "-}"]],
    keywords:
      "case classdata codata constructor data do else export if implementation implicit import in infix infixl infixr interface let module mutual namespace of parameters partial public record rewrite then total using where with",
    types:
      "Bool Char Double Either IO Int Integer List Maybe Nat String Type Unit Vect",
  },
  agda: {
    lineComments: ["--"],
    blockComments: [["{-", "-}"]],
    keywords:
      "abstract constructor data do eta-equality field forall hiding import in inductive instance interleaved irrelevant let macro module mutual no-eta-equality open overlap pattern postulate primitive private public quote quoteContext quoteGoal quoteTerm record renaming rewrite syntax tactic unquote unquoteDecl unquoteDef unquoteTC using variable where with",
    types: "Bool Char Either IO List Maybe Nat Set String",
  },
  janet: {
    lineComments: ["#"],
    blockComments: [["#|", "|#"]],
    keywords:
      "and as-> break case catch cond def defdyn defglobal defmacro defn defn- do each eachk eachp eachy else elseif ev every fiber fn for forever generate if import in let loop match not or prompt protect quasiquote quote receive repeat resume scan signal splice try unless unquote upscope var when while with with-dyns yield",
    types:
      "array boolean buffer cfunction fiber function keyword nil number string struct symbol table tuple",
  },
  pike: {
    profile: "c",
    keywords:
      "break case catch class constant continue default do else enum extern final for foreach gauge if import inherit inline lambda local mapping mixed multiset object optional predef private protected public return static switch typedef typeof variant while",
    types:
      "array float function int mapping mixed multiset object program string void zero",
  },
  factor: {
    lineComments: ["!"],
    caseInsensitive: false,
    keywords:
      "ALIAS: CONSTANT: DEFER: GENERIC: HOOK: IN: INSTANCE: MAIN: M: MACRO: MEMO: MIXIN: PREDICATE: PRIVATE> SYMBOL: TUPLE: UNION: USING: VAR: VOCAB: \: ; if when unless cond case loop while until each map reduce call execute dip keep bi tri quotation",
    types:
      "array boolean byte-array fixnum float hashtable integer object quotation sequence string tuple word",
  },
  rescript: {
    profile: "c",
    keywords:
      "and as assert async await catch constraint do downto else exception external false for if in include inherit inline lazy let module mutable new nonrec object of open or private rec switch then to true try type unpack use virtual when while with",
    types:
      "array bigint bool date dict error float int list option promise regexp result string unit",
  },
  eiffel: {
    lineComments: ["--"],
    caseInsensitive: true,
    keywords:
      "across agent alias all and as assign attached attribute check class convert create debug deferred detachable do else elseif end ensure expanded export external feature from frozen if imply inherit inspect invariant like local loop note obsolete old once only or precursor redefine rename require rescue retry select separate some strip then undefine until variant when xor",
    types:
      "ANY ARRAY BOOLEAN CHARACTER HASH_TABLE INTEGER NATURAL POINTER REAL STRING TUPLE",
  },
};

function wordPattern(words, caseInsensitive) {
  if (words.length === 0) return null;
  const body = `\\b(?:${words.map(escapeRegex).join("|")})\\b`;
  return caseInsensitive ? `(?i:${body})` : body;
}

function grammarFor(id, spec) {
  const profile = profiles[spec.profile] ?? {};
  const lineComments = [
    ...(profile.lineComments ?? []),
    ...(spec.lineComments ?? []),
  ];
  const lineCommentPatterns = spec.lineCommentPatterns ?? [];
  const blockComments = [
    ...(profile.blockComments ?? []),
    ...(spec.blockComments ?? []),
  ];
  const blockCommentPatterns = spec.blockCommentPatterns ?? [];
  const keywords = wordPattern(splitWords(spec.keywords), spec.caseInsensitive);
  const types = wordPattern(splitWords(spec.types), spec.caseInsensitive);
  const scope = id.replace(/[^a-z0-9-]/g, "-");
  const patterns = [
    ...lineComments.map((marker) => ({
      match: `${escapeRegex(marker)}.*$`,
      name: `comment.line.${scope}`,
    })),
    ...lineCommentPatterns.map((match) => ({
      match,
      name: `comment.line.${scope}`,
    })),
    ...blockComments.map(([begin, end]) => ({
      begin: escapeRegex(begin),
      end: escapeRegex(end),
      name: `comment.block.${scope}`,
    })),
    ...blockCommentPatterns.map(([begin, end]) => ({
      begin,
      end,
      name: `comment.block.${scope}`,
    })),
    {
      begin: '"',
      end: '"',
      name: `string.quoted.double.${scope}`,
      patterns: [
        { match: "\\\\.", name: `constant.character.escape.${scope}` },
      ],
    },
    {
      begin: "'",
      end: "'",
      name: `string.quoted.single.${scope}`,
      patterns: [
        { match: "\\\\.", name: `constant.character.escape.${scope}` },
      ],
    },
    {
      match:
        "(?<![A-Za-z0-9_])(?:0[xX][0-9A-Fa-f]+|0[bB][01]+|(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][+-]?\\d+)?)(?![A-Za-z0-9_])",
      name: `constant.numeric.${scope}`,
    },
    ...(keywords
      ? [{ match: keywords, name: `keyword.control.${scope}` }]
      : []),
    ...(types ? [{ match: types, name: `storage.type.${scope}` }] : []),
    {
      match: "(?i:\\b(?:false|nil|none|null|nothing|true|void)\\b)",
      name: `constant.language.${scope}`,
    },
    {
      match:
        "(?<=\\b(?:class|def|define|fn|fun|func|function|method|proc|procedure|type)\\s+)[A-Za-z_][A-Za-z0-9_.!?-]*",
      name: `entity.name.function.${scope}`,
    },
    {
      match: "[A-Za-z_][A-Za-z0-9_.!?-]*(?=\\s*\\()",
      name: `entity.name.function.call.${scope}`,
    },
    {
      match: "(?<![A-Za-z0-9_]):[A-Za-z_][A-Za-z0-9_.!?-]*",
      name: `constant.other.symbol.${scope}`,
    },
  ];

  return {
    name: id,
    scopeName: `source.${scope}`,
    patterns,
  };
}

export const customLanguageGrammars = Object.fromEntries(
  Object.entries(specs).map(([id, spec]) => [id, grammarFor(id, spec)]),
);

export const customLanguageIds = new Set(Object.keys(customLanguageGrammars));
