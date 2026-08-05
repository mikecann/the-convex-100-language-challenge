import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { parse } from "yaml";
import { targetRuntimeError } from "./target-runtime-policy.mjs";

const root = process.env.REPO_ROOT ?? "/repo";
const languageId = process.argv[2];

if (!languageId || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(languageId)) {
  throw new Error("a valid language id is required");
}

const manifestPath = path.join(root, languageId, "manifest.yaml");
const manifest = parse(fs.readFileSync(manifestPath, "utf8"), { uniqueKeys: true });
const error = targetRuntimeError(languageId, manifest);

if (error) throw new Error(error);
process.stdout.write(manifest.targetRuntimeCommand ?? "");
