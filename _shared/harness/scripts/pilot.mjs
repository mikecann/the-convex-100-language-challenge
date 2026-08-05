import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { AdapterProcess } from "./adapter-process.mjs";

const deploymentUrl = process.env.CONVEX_URL;
if (!deploymentUrl) throw new Error("CONVEX_URL is required");

const artifacts = process.env.ARTIFACTS_DIR ?? "/artifacts";
const goAdapterPath = process.env.CLIENT_ADAPTER ?? "/client/convex-go-adapter";
const referenceAdapterPath = fileURLToPath(
  new URL("../reference-js/adapter.mjs", import.meta.url),
);
const startedAt = new Date();
const testResults = [];
let sequence = 0;
let goRuntime = "unknown";

const oracle = new AdapterProcess(process.execPath, [referenceAdapterPath]).start();
const go = new AdapterProcess(goAdapterPath).start();

function nextId(prefix) {
  sequence += 1;
  return `${prefix}-${sequence}`;
}

async function test(name, fn) {
  const start = performance.now();
  try {
    await fn();
    testResults.push({
      name,
      status: "pass",
      durationMs: Math.round(performance.now() - start),
    });
    console.log(`PASS ${name}`);
  } catch (error) {
    testResults.push({
      name,
      status: "fail",
      durationMs: Math.round(performance.now() - start),
      detail: error.stack ?? error.message ?? String(error),
    });
    console.error(`FAIL ${name}: ${error.stack ?? error}`);
  }
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

const goHTTPPassed = testResults
  .filter((entry) => entry.name.startsWith("go/http/"))
  .every((entry) => entry.status === "pass");
const goLivePassed =
  goHTTPPassed &&
  testResults
    .filter((entry) => entry.name.startsWith("go/live/"))
    .every((entry) => entry.status === "pass");
const oraclePassed = testResults
  .filter((entry) => entry.name.startsWith("oracle/"))
  .every((entry) => entry.status === "pass");

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

const result = {
  schemaVersion: 1,
  language: "go",
  sourceCommit: process.env.SOURCE_COMMIT ?? "unknown",
  dirty: process.env.SOURCE_DIRTY === "true",
  provenance: "native",
  runtimeVersion: goRuntime,
  platform: process.env.TEST_PLATFORM ?? "linux/amd64",
  imageDigest: process.env.CLIENT_IMAGE_DIGEST ?? "unknown",
  backend: {
    kind: process.env.BACKEND_KIND ?? "self-hosted",
    url: deploymentUrl,
    version: backendVersion.trim() || "unknown",
  },
  protocol: "convex-rs-0.10.4-unversioned-sync",
  startedAt: startedAt.toISOString(),
  finishedAt: new Date().toISOString(),
  tests: testResults,
  earnedCapabilities,
};

fs.mkdirSync(artifacts, { recursive: true });
fs.writeFileSync(path.join(artifacts, "go-pilot-result.json"), `${JSON.stringify(result, null, 2)}\n`);
fs.writeFileSync(
  path.join(artifacts, "go-pilot-transcript.json"),
  `${JSON.stringify({ oracle: oracle.transcript, go: go.transcript }, null, 2)}\n`,
);

if (testResults.some((entry) => entry.status === "fail")) process.exitCode = 1;
console.log(`Earned capabilities: ${earnedCapabilities.join(", ") || "none"}`);
