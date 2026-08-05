import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { parse } from "yaml";
import { projectReadmeExamples } from "./example-readme.mjs";

const root = process.env.REPO_ROOT ?? "/repo";
const roster = parse(fs.readFileSync(path.join(root, "roster/languages.yaml"), "utf8"));
let changed = 0;

for (const language of roster.languages) {
  const readmePath = path.join(root, language.id, "README.md");
  if (!fs.existsSync(readmePath)) continue;

  const projection = projectReadmeExamples(readmePath);
  if (projection.errors.length > 0) {
    throw new Error(`${language.id}: ${projection.errors.join("; ")}`);
  }
  if (projection.original !== projection.projected) {
    fs.writeFileSync(readmePath, projection.projected);
    changed += 1;
    console.log(`SYNC ${language.id}/README.md`);
  }
}

console.log(`PASS synchronized ${changed} README example block${changed === 1 ? "" : "s"}`);
