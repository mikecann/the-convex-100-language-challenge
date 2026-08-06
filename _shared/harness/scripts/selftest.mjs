import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { AdapterProcess } from "./adapter-process.mjs";
import { projectReadmeExamples } from "./example-readme.mjs";
import {
  earnedCapabilitiesFor,
  requiredHTTPTests,
  requiredLiveTests,
} from "./required-tests.mjs";
import { targetRuntimeError } from "./target-runtime-policy.mjs";

const broken = fileURLToPath(new URL("./broken-adapter.mjs", import.meta.url));
const hello = { protocolVersion: 1, id: "hello", op: "hello" };
const query = { id: "query", op: "query", path: "demo:state", args: {} };

function checkExampleFence(extension, expectedFence) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "convex-example-fence-"));
  try {
    const source = `examples/basics/main${extension}`;
    fs.mkdirSync(path.join(directory, "examples", "basics"), { recursive: true });
    fs.writeFileSync(path.join(directory, source), "example source\n");
    fs.writeFileSync(
      path.join(directory, "README.md"),
      `<!-- BEGIN GENERATED EXAMPLE: ${source} -->\n\`\`\`text\nstale\n\`\`\`\n<!-- END GENERATED EXAMPLE -->\n`,
    );

    const projection = projectReadmeExamples(path.join(directory, "README.md"));
    assert.deepEqual(projection.errors, []);
    assert.ok(projection.projected.includes(`\n\`\`\`${expectedFence}\nexample source\n`));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

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

// New languages must keep projecting their real example source without losing
// the syntax name that GitHub and the generated site use for highlighting.
checkExampleFence(".zig", "zig");
checkExampleFence(".e", "eiffel");
checkExampleFence(".factor", "factor");
checkExampleFence(".sml", "sml");
checkExampleFence(".lean", "lean");

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
