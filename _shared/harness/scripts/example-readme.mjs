import fs from "node:fs";
import path from "node:path";

const beginPrefix = "<!-- BEGIN GENERATED EXAMPLE: ";
const endMarker = "<!-- END GENERATED EXAMPLE -->";
const blockPattern = /<!-- BEGIN GENERATED EXAMPLE: ([^\r\n]+) -->\r?\n[\s\S]*?<!-- END GENERATED EXAMPLE -->/g;

const fenceLanguages = {
  ".adb": "ada",
  ".ads": "ada",
  ".agda": "agda",
  ".alg": "algol",
  ".asm": "nasm",
  ".awk": "awk",
  ".bal": "ballerina",
  ".bas": "freebasic",
  ".bmx": "blitzmax",
  ".c": "c",
  ".cbl": "cobol",
  ".cc": "cpp",
  ".chpl": "chapel",
  ".clj": "clojure",
  ".cob": "cobol",
  ".coffee": "coffeescript",
  ".cr": "crystal",
  ".cs": "csharp",
  ".dart": "dart",
  ".d": "d",
  ".e": "eiffel",
  ".el": "emacs-lisp",
  ".elm": "elm",
  ".erl": "erlang",
  ".ex": "elixir",
  ".exs": "elixir",
  ".factor": "factor",
  ".f90": "fortran",
  ".fth": "forth",
  ".fs": "fsharp",
  ".fsx": "fsharp",
  ".gd": "gdscript",
  ".gleam": "gleam",
  ".go": "go",
  ".groovy": "groovy",
  ".ha": "hare",
  ".hs": "haskell",
  ".hx": "haxe",
  ".idr": "idris",
  ".io": "io",
  ".java": "java",
  ".janet": "janet",
  ".jl": "julia",
  ".js": "javascript",
  ".jsx": "jsx",
  ".kt": "kotlin",
  ".kts": "kotlin",
  ".lean": "lean",
  ".lisp": "common-lisp",
  ".lua": "lua",
  ".m": "objective-c",
  ".ml": "ocaml",
  ".mli": "ocaml",
  ".mbt": "moonbit",
  ".mod": "modula2",
  ".mojo": "mojo",
  ".pli": "pli",
  ".nim": "nim",
  ".obn": "oberon",
  ".odin": "odin",
  ".pas": "pascal",
  ".pl": "perl",
  ".php": "php",
  ".pike": "pike",
  ".pony": "pony",
  ".prg": "harbour",
  ".prolog": "prolog",
  ".ps1": "powershell",
  ".purs": "purescript",
  ".py": "python",
  ".r": "r",
  ".raku": "raku",
  ".rb": "ruby",
  ".res": "rescript",
  ".rkt": "racket",
  ".rs": "rust",
  ".scala": "scala",
  ".scm": "scheme",
  ".sh": "bash",
  ".sim": "simula",
  ".sml": "sml",
  ".sno": "snobol4",
  ".sol": "solidity",
  ".st": "smalltalk",
  ".swift": "swift",
  ".tcl": "tcl",
  ".ts": "typescript",
  ".tsx": "tsx",
  ".v": "v",
  ".vala": "vala",
  ".vb": "vbnet",
  ".zig": "zig",
};

// Some ecosystems intentionally share an extension. Resolve the roster
// language first so a MATLAB .m file is never presented as Objective-C, while
// retaining the simple extension table for unambiguous examples.
const languageFenceOverrides = {
  matlab: "matlab",
  mumps: "mumps",
  "objective-c": "objective-c",
  "wolfram-language": "mathematica",
};

export function fenceLanguageFor(languageId, sourcePath) {
  if (languageId in languageFenceOverrides) {
    return languageFenceOverrides[languageId];
  }
  return fenceLanguages[path.extname(sourcePath).toLowerCase()] ?? "text";
}

function renderExampleBlock(languageDirectory, relativeSource) {
  const sourcePath = path.resolve(languageDirectory, relativeSource);
  if (!sourcePath.startsWith(`${languageDirectory}${path.sep}`)) {
    throw new Error(`generated example escapes language directory: ${relativeSource}`);
  }
  if (!fs.existsSync(sourcePath) || !fs.statSync(sourcePath).isFile()) {
    throw new Error(`generated example source does not exist: ${relativeSource}`);
  }

  const source = fs.readFileSync(sourcePath, "utf8").trimEnd();
  const fence = fenceLanguageFor(path.basename(languageDirectory), sourcePath);
  return `${beginPrefix}${relativeSource} -->\n\`\`\`${fence}\n${source}\n\`\`\`\n${endMarker}`;
}

export function projectReadmeExamples(readmePath) {
  const languageDirectory = path.dirname(readmePath);
  const original = fs.readFileSync(readmePath, "utf8");
  const beginCount = original.split(beginPrefix).length - 1;
  const endCount = original.split(endMarker).length - 1;
  const errors = [];
  const sources = [];
  let markerCount = 0;

  if (beginCount !== endCount) {
    errors.push("generated example markers are unbalanced");
  }

  let projected = original;
  try {
    projected = original.replace(blockPattern, (_block, relativeSource) => {
      markerCount += 1;
      const source = relativeSource.trim();
      sources.push(source);
      return renderExampleBlock(languageDirectory, source);
    });
  } catch (error) {
    errors.push(error.message);
  }

  if (markerCount !== beginCount) {
    errors.push("generated example marker is malformed");
  }

  return { original, projected, markerCount, sources, errors };
}
