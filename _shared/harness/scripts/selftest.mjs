import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { AdapterProcess } from "./adapter-process.mjs";
import { fenceLanguageFor } from "./example-readme.mjs";
import {
  earnedCapabilitiesFor,
  requiredHTTPTests,
  requiredLiveTests,
} from "./required-tests.mjs";
import { targetRuntimeError } from "./target-runtime-policy.mjs";

const broken = fileURLToPath(new URL("./broken-adapter.mjs", import.meta.url));
const hello = { protocolVersion: 1, id: "hello", op: "hello" };
const query = { id: "query", op: "query", path: "demo:state", args: {} };

async function checkWrongValue() {
  const adapter = new AdapterProcess(process.execPath, [broken, "wrong"]).start();
  await adapter.request(hello);
  const result = await adapter.request(query);
  assert.throws(() => assert.deepEqual(result.value, { count: 0 }));
  await adapter.stop();
}

async function checkHang() {
  const adapter = new AdapterProcess(process.execPath, [broken, "hang"]).start();
  await adapter.request(hello);
  await assert.rejects(adapter.request(query, 100), /timed out/);
  await adapter.stop();
}

async function checkDirtyExit() {
  const adapter = new AdapterProcess(process.execPath, [broken, "dirty-exit"]).start();
  await adapter.request(hello);
  await assert.rejects(adapter.request(query), /code=17/);
  await adapter.stop();
}

await checkWrongValue();
await checkHang();
await checkDirtyExit();

// These are the ambiguous or easily mistyped additions. Keep the unit check
// pure so `./run validate` can retain its read-only filesystem contract.
assert.equal(fenceLanguageFor("assembly-x86-64", "main.asm"), "nasm");
assert.equal(fenceLanguageFor("freebasic", "main.bas"), "freebasic");
assert.equal(fenceLanguageFor("c", "main.c"), "c");
assert.equal(fenceLanguageFor("groovy", "main.groovy"), "groovy");
assert.equal(fenceLanguageFor("julia", "main.jl"), "julia");
assert.equal(fenceLanguageFor("objective-c", "main.m"), "objective-c");
assert.equal(fenceLanguageFor("matlab", "main.m"), "matlab");
assert.equal(fenceLanguageFor("wolfram-language", "main.m"), "mathematica");
assert.equal(fenceLanguageFor("moonbit", "main.mbt"), "moonbit");
assert.equal(fenceLanguageFor("rescript", "main.res"), "rescript");
assert.equal(fenceLanguageFor("v", "main.v"), "v");
assert.equal(fenceLanguageFor("visual-basic-dotnet", "main.vb"), "vbnet");
assert.equal(fenceLanguageFor("zig", "main.zig"), "zig");

// A synthetic second language catches accidental Go-specific names in the
// capability evaluator before real language work starts.
const syntheticElixirTests = [...requiredHTTPTests, ...requiredLiveTests].map((name) => ({
  name,
  status: "pass",
}));
assert.deepEqual(earnedCapabilitiesFor(syntheticElixirTests), ["http", "live"]);
assert.ok(
  [...requiredHTTPTests, ...requiredLiveTests].every((name) => !name.includes("go/")),
);

assert.equal(
  targetRuntimeError("python", {
    implementation: { status: "attempting" },
    targetRuntimeCommand: "python3",
  }),
  null,
);
assert.equal(
  targetRuntimeError("typescript", {
    implementation: { status: "attempting" },
    targetRuntimeCommand: "node",
  }),
  null,
);
assert.equal(
  targetRuntimeError("php", {
    implementation: { status: "attempting" },
    targetRuntimeCommand: "php",
  }),
  null,
);
assert.match(
  targetRuntimeError("php", {
    implementation: { status: "attempting" },
    targetRuntimeCommand: "composer",
  }),
  /must declare/,
);
assert.match(
  targetRuntimeError("typescript", {
    implementation: { status: "attempting" },
    targetRuntimeCommand: "javascript",
  }),
  /must declare/,
);
assert.match(
  targetRuntimeError("python", { implementation: { status: "attempting" } }),
  /must declare/,
);
assert.match(
  targetRuntimeError("go", {
    implementation: { status: "attempting" },
    targetRuntimeCommand: "node",
  }),
  /not approved/,
);
assert.match(
  targetRuntimeError("javascript", {
    implementation: { status: "planned" },
    targetRuntimeCommand: "node",
  }),
  /planned client/,
);

console.log(
  "PASS harness rejects bad adapters, language-specific test names, and undeclared target runtimes",
);
