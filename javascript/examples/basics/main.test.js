import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
test("canonical example explains each Convex step", async () => { const source = await readFile(new URL("./main.js", import.meta.url), "utf8"); for (const phrase of ["HTTP query", "Start Live", "idempotency key", "next Live value"]) assert.match(source, new RegExp(phrase)); });
