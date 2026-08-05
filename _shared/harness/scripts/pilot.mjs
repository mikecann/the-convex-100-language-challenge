import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { AdapterProcess } from "./adapter-process.mjs";

const deploymentUrl = process.env.CONVEX_URL;
if (!deploymentUrl) throw new Error("CONVEX_URL is required");

const artifacts = process.env.ARTIFACTS_DIR ?? "/artifacts";
const goAdapterTCP = process.env.CLIENT_ADAPTER_TCP;
if (!goAdapterTCP) throw new Error("CLIENT_ADAPTER_TCP is required");
const referenceAdapterPath = fileURLToPath(
  new URL("../reference-js/adapter.mjs", import.meta.url),
);
const startedAt = new Date();
const testResults = [];
let sequence = 0;
let goRuntime = "unknown";

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

const oracle = new AdapterProcess(process.execPath, [referenceAdapterPath]).start();
const go = new AdapterProcess(null, [], { tcp: goAdapterTCP }).start();

function nextId(prefix) {
  sequence += 1;
  return `${prefix}-${sequence}`;
}

async function test(name, fn) {
  const start = performance.now();
  const transcriptStart = {
    oracle: oracle.transcript.length,
    go: go.transcript.length,
  };
  let result;
  try {
    await fn();
    result = {
      name,
      status: "pass",
      durationMs: Math.round(performance.now() - start),
    };
    console.log(`PASS ${name}`);
  } catch (error) {
    result = {
      name,
      status: "fail",
      durationMs: Math.round(performance.now() - start),
      detail: error.stack ?? error.message ?? String(error),
    };
    console.error(`FAIL ${name}: ${error.stack ?? error}`);
  }
  const evidence = {
    oracle: oracle.transcript.slice(transcriptStart.oracle),
    go: go.transcript.slice(transcriptStart.go),
  };
  result.evidenceHash = sha256(JSON.stringify(evidence));
  testResults.push(result);
}

async function hello(adapter, label) {
  const response = await adapter.request({
    protocolVersion: 1,
    id: nextId(`${label}-hello`),
    op: "hello",
  });
  assert.equal(response.type, "ready");
  return response;
}

async function call(adapter, op, functionPath, args) {
  const response = await adapter.request({
    id: nextId(op),
    op,
    path: functionPath,
    args,
  });
  assert.equal(response.type, "result", JSON.stringify(response));
  return response;
}

async function subscribe(adapter, subscriptionId, functionPath, args) {
  const response = await adapter.request({
    id: nextId("subscribe"),
    op: "subscribe",
    subscriptionId,
    path: functionPath,
    args,
  });
  assert.equal(response.type, "ack", JSON.stringify(response));
}

async function unsubscribe(adapter, subscriptionId) {
  const response = await adapter.request({
    id: nextId("unsubscribe"),
    op: "unsubscribe",
    subscriptionId,
  });
  assert.equal(response.type, "ack", JSON.stringify(response));
}

async function setAuth(adapter, token) {
  const response = await adapter.request({
    id: nextId("set-auth"),
    op: "setAuth",
    token,
  });
  assert.equal(response.type, "ack", JSON.stringify(response));
}

async function externalIncrement(room, runId) {
  return call(oracle, "mutation", "demo:increment", {
    room,
    language: "javascript-oracle",
    runId,
  });
}

async function runHTTP(label, adapter, { expectLogs }) {
  const room = `${label}-http-${Date.now()}`;

  await test(`${label}/http/query`, async () => {
    const response = await call(adapter, "query", "demo:state", { room });
    assert.deepEqual(response.value, {
      room,
      count: 0,
      lastLanguage: null,
      latestRunId: null,
      updatedAt: null,
    });
  });

  await test(`${label}/http/nested-json-and-logs`, async () => {
    const value = {
      unicode: "Hello, 世界 👋",
      nested: { booleans: [true, false], number: 42.5, nil: null },
    };
    const response = await call(adapter, "query", "demo:echo", { value });
    assert.deepEqual(response.value, value);
    if (expectLogs) {
      assert.ok(response.logs?.some((line) => line.includes("demo:echo")));
    }
  });

  await test(`${label}/http/mutation`, async () => {
    const response = await call(adapter, "mutation", "demo:increment", {
      room,
      language: label,
      runId: `${room}-once`,
    });
    assert.equal(response.value.applied, true);
    assert.equal(response.value.state.count, 1);
  });

  await test(`${label}/http/idempotent-mutation`, async () => {
    const response = await call(adapter, "mutation", "demo:increment", {
      room,
      language: label,
      runId: `${room}-once`,
    });
    assert.equal(response.value.applied, false);
    assert.equal(response.value.state.count, 1);
  });

  await test(`${label}/http/document-id-string`, async () => {
    const idResponse = await call(adapter, "query", "demo:roomId", { room });
    assert.equal(typeof idResponse.value, "string");
    assert.ok(idResponse.value.length > 8);
    const echoResponse = await call(adapter, "query", "demo:echo", {
      value: idResponse.value,
    });
    assert.equal(echoResponse.value, idResponse.value);
  });

  await test(`${label}/http/action`, async () => {
    const response = await call(adapter, "action", "demo:greet", {
      language: label === "go" ? "Go" : "JavaScript",
    });
    assert.match(response.value.message, /Convex is responding/);
  });

  await test(`${label}/http/structured-error`, async () => {
    const code = `${label.toUpperCase()}_EXPECTED`;
    const response = await adapter.request({
      id: nextId("failure"),
      op: "query",
      path: "demo:fail",
      args: { code },
    });
    assert.equal(response.type, "error", JSON.stringify(response));
    assert.equal(response.error?.data?.code, code);
  });

  await test(`${label}/http/utf8-round-trip`, async () => {
    const response = await call(adapter, "query", "demo:echo", {
      value: ["Καλημέρα", "مرحبا", "kia ora", "🟨🟩🟦"],
    });
    assert.equal(response.value[3], "🟨🟩🟦");
  });

  if (label === "go") {
    await test("go/http/bearer-token-lifecycle", async () => {
      await setAuth(adapter, "invalid-token-one");
      let response = await adapter.request({
        id: nextId("invalid-auth"),
        op: "query",
        path: "demo:state",
        args: { room: `${room}-invalid-auth` },
      });
      assert.equal(response.type, "error", JSON.stringify(response));

      await setAuth(adapter, "invalid-token-two");
      response = await adapter.request({
        id: nextId("replaced-auth"),
        op: "query",
        path: "demo:state",
        args: { room: `${room}-replaced-auth` },
      });
      assert.equal(response.type, "error", JSON.stringify(response));

      await setAuth(adapter, "");
      response = await call(adapter, "query", "demo:state", {
        room: `${room}-cleared-auth`,
      });
      assert.equal(response.value.count, 0);
    });
  }
}

async function runLive(label, adapter) {
  const base = `${label}-live-${Date.now()}`;

  await test(`${label}/live/initial-result`, async () => {
    const subscriptionId = `${label}-initial`;
    await subscribe(adapter, subscriptionId, "demo:state", { room: `${base}-initial` });
    const update = await adapter.nextSubscription(subscriptionId);
    assert.equal(update.value.count, 0);
    await unsubscribe(adapter, subscriptionId);
  });

  await test(`${label}/live/external-update`, async () => {
    const room = `${base}-external`;
    const subscriptionId = `${label}-external`;
    await subscribe(adapter, subscriptionId, "demo:state", { room });
    await adapter.nextSubscription(subscriptionId);
    await externalIncrement(room, `${room}-1`);
    const update = await adapter.nextSubscription(subscriptionId);
    assert.equal(update.value.count, 1);
    await unsubscribe(adapter, subscriptionId);
  });

  await test(`${label}/live/unsubscribe`, async () => {
    const room = `${base}-unsubscribe`;
    const subscriptionId = `${label}-unsubscribe`;
    await subscribe(adapter, subscriptionId, "demo:state", { room });
    await adapter.nextSubscription(subscriptionId);
    await unsubscribe(adapter, subscriptionId);
    await externalIncrement(room, `${room}-1`);
    await adapter.expectNoSubscription(subscriptionId);
  });

  await test(`${label}/live/reconnect-five-times`, async () => {
    for (let attempt = 1; attempt <= 5; attempt += 1) {
      const room = `${base}-reconnect-${attempt}`;
      const subscriptionId = `${label}-reconnect-${attempt}`;
      await subscribe(adapter, subscriptionId, "demo:state", { room });
      await adapter.nextSubscription(subscriptionId);
      const disconnected = await adapter.request({
        id: nextId("disconnect"),
        op: "debugDisconnect",
      });
      assert.equal(disconnected.type, "ack", JSON.stringify(disconnected));
      await externalIncrement(room, `${room}-1`);
      const update = await adapter.nextSubscription(subscriptionId, 20_000);
      assert.equal(update.value.count, 1);
      await unsubscribe(adapter, subscriptionId);
    }
  });

  await test(`${label}/live/query-error-recovery`, async () => {
    const room = `${base}-repair`;
    const subscriptionId = `${label}-repair`;
    await subscribe(adapter, subscriptionId, "demo:requiresNonzero", { room });
    const failed = await adapter.nextSubscription(subscriptionId);
    assert.equal(failed.error?.data?.code, "ROOM_EMPTY", JSON.stringify(failed));
    await externalIncrement(room, `${room}-1`);
    const repaired = await adapter.nextSubscription(subscriptionId);
    assert.equal(repaired.value.count, 1);
    await unsubscribe(adapter, subscriptionId);
  });
}

await test("oracle/adapter/hello", async () => {
  await hello(oracle, "oracle");
});
await test("go/adapter/hello", async () => {
  const response = await hello(go, "go");
  goRuntime = response.runtime ?? "unknown";
});

await runHTTP("oracle", oracle, { expectLogs: false });
await runLive("oracle", oracle);
await runHTTP("go", go, { expectLogs: true });
await runLive("go", go);

await test("go/live/clean-close", async () => {
  const response = await go.request({ id: nextId("go-close"), op: "close" });
  assert.equal(response.type, "closed", JSON.stringify(response));
  assert.equal((await go.exitPromise).code, 0);
});

await test("oracle/live/clean-close", async () => {
  const response = await oracle.request({ id: nextId("oracle-close"), op: "close" });
  assert.equal(response.type, "closed", JSON.stringify(response));
  assert.equal((await oracle.exitPromise).code, 0);
});

const requiredOracleTests = [
  "oracle/adapter/hello",
  "oracle/http/query",
  "oracle/http/nested-json-and-logs",
  "oracle/http/mutation",
  "oracle/http/idempotent-mutation",
  "oracle/http/document-id-string",
  "oracle/http/action",
  "oracle/http/structured-error",
  "oracle/http/utf8-round-trip",
  "oracle/live/initial-result",
  "oracle/live/external-update",
  "oracle/live/unsubscribe",
  "oracle/live/reconnect-five-times",
  "oracle/live/query-error-recovery",
  "oracle/live/clean-close",
];
const requiredGoHTTPTests = [
  "go/adapter/hello",
  "go/http/query",
  "go/http/nested-json-and-logs",
  "go/http/mutation",
  "go/http/idempotent-mutation",
  "go/http/document-id-string",
  "go/http/action",
  "go/http/structured-error",
  "go/http/utf8-round-trip",
  "go/http/bearer-token-lifecycle",
];
const requiredGoLiveTests = [
  "go/live/initial-result",
  "go/live/external-update",
  "go/live/unsubscribe",
  "go/live/reconnect-five-times",
  "go/live/query-error-recovery",
  "go/live/clean-close",
];

function requiredTestsPassed(requiredNames) {
  return requiredNames.every((name) => {
    const matches = testResults.filter((entry) => entry.name === name);
    return matches.length === 1 && matches[0].status === "pass";
  });
}

const oraclePassed = requiredTestsPassed(requiredOracleTests);
const goHTTPPassed = oraclePassed && requiredTestsPassed(requiredGoHTTPTests);
const goLivePassed = goHTTPPassed && requiredTestsPassed(requiredGoLiveTests);

const earnedCapabilities = [];
if (oraclePassed && goHTTPPassed) earnedCapabilities.push("http");
if (oraclePassed && goLivePassed) earnedCapabilities.push("live");

let backendVersion = "unknown";
try {
  const response = await fetch(`${deploymentUrl.replace(/\/$/, "")}/version`);
  if (response.ok) backendVersion = await response.text();
} catch {
  // The individual calls already provide better failure evidence.
}

const transcript = { oracle: oracle.transcript, go: go.transcript };
const transcriptJSON = `${JSON.stringify(transcript, null, 2)}\n`;
const result = {
  schemaVersion: 1,
  language: "go",
  sourceCommit: process.env.SOURCE_COMMIT ?? "unknown",
  dirty: process.env.SOURCE_DIRTY === "true",
  provenance: "native",
  runtimeVersion: goRuntime,
  platform: process.env.TEST_PLATFORM ?? "linux/amd64",
  imageDigest: process.env.CLIENT_IMAGE_DIGEST ?? "unknown",
  clientTreeHash: process.env.CLIENT_TREE_HASH ?? "unknown",
  baseImageDigests: [
    "sha256:f4490d7b261d73af4543c46ac6597d7d101b6e1755bcdd8c5159fda7046b6b3e",
    "sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce",
  ],
  backend: {
    kind: process.env.BACKEND_KIND ?? "self-hosted",
    url: deploymentUrl,
    version: backendVersion.trim() || "unknown",
    imageDigest: process.env.BACKEND_IMAGE_DIGEST || null,
  },
  protocol: "convex-rs-0.10.4-unversioned-sync",
  revisions: {
    harnessTreeHash: process.env.HARNESS_TREE_HASH ?? "unknown",
    backendTreeHash: process.env.BACKEND_TREE_HASH ?? "unknown",
    protocolSourceCommit: "6f1df8a8ba1665084ec001e307ca841ca17074d7",
  },
  evidence: {
    channel: process.env.EVIDENCE_CHANNEL ?? "local",
    runUrl: process.env.EVIDENCE_RUN_URL || null,
    ociArchive: process.env.EVIDENCE_OCI_ARCHIVE || null,
    transcriptSha256: sha256(transcriptJSON),
  },
  startedAt: startedAt.toISOString(),
  finishedAt: new Date().toISOString(),
  tests: testResults,
  earnedCapabilities,
};

fs.mkdirSync(artifacts, { recursive: true });
const resultSchema = JSON.parse(fs.readFileSync("/schemas/result.schema.json", "utf8"));
const ajv = new Ajv2020({ allErrors: true });
addFormats(ajv);
const validateResult = ajv.compile(resultSchema);
if (!validateResult(result)) {
  throw new Error(`generated invalid result: ${ajv.errorsText(validateResult.errors)}`);
}
fs.writeFileSync(path.join(artifacts, "go-pilot-transcript.json"), transcriptJSON);
fs.writeFileSync(path.join(artifacts, "go-pilot-result.json"), `${JSON.stringify(result, null, 2)}\n`);

if (testResults.some((entry) => entry.status === "fail")) process.exitCode = 1;
console.log(`Earned capabilities: ${earnedCapabilities.join(", ") || "none"}`);
