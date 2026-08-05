import fs from "node:fs";
import path from "node:path";

const beginPrefix = "<!-- BEGIN GENERATED EXAMPLE: ";
const endMarker = "<!-- END GENERATED EXAMPLE -->";
const blockPattern = /<!-- BEGIN GENERATED EXAMPLE: ([^\r\n]+) -->\r?\n[\s\S]*?<!-- END GENERATED EXAMPLE -->/g;

const fenceLanguages = {
  ".cc": "cpp",
  ".cs": "csharp",
  ".fs": "fsharp",
  ".fsx": "fsharp",
  ".go": "go",
  ".js": "javascript",
  ".jsx": "jsx",
  ".kt": "kotlin",
  ".kts": "kotlin",
  ".py": "python",
  ".rb": "ruby",
  ".rs": "rust",
  ".ts": "typescript",
  ".tsx": "tsx",
};

function renderExampleBlock(languageDirectory, relativeSource) {
  const sourcePath = path.resolve(languageDirectory, relativeSource);
  if (!sourcePath.startsWith(`${languageDirectory}${path.sep}`)) {
    throw new Error(`generated example escapes language directory: ${relativeSource}`);
  }
  if (!fs.existsSync(sourcePath) || !fs.statSync(sourcePath).isFile()) {
    throw new Error(`generated example source does not exist: ${relativeSource}`);
  }

  const source = fs.readFileSync(sourcePath, "utf8").trimEnd();
  const fence = fenceLanguages[path.extname(sourcePath).toLowerCase()] ?? "text";
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
