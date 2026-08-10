import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { parse } from "yaml";
import { AdapterProcess } from "./adapter-process.mjs";
import { earnedCapabilitiesFor } from "./required-tests.mjs";

const deploymentUrl = process.env.CONVEX_URL;
if (!deploymentUrl) throw new Error("CONVEX_URL is required");

const languageId = process.env.CLIENT_LANGUAGE;
if (!languageId) throw new Error("CLIENT_LANGUAGE is required");

const clientAdapterTCP = process.env.CLIENT_ADAPTER_TCP;
if (!clientAdapterTCP) throw new Error("CLIENT_ADAPTER_TCP is required");

const repositoryRoot = process.env.REPO_ROOT ?? "/repo";
const languageDirectory = path.join(repositoryRoot, languageId);
const manifest = parse(
  fs.readFileSync(path.join(languageDirectory, "manifest.yaml"), "utf8"),
);
if (manifest.id !== languageId) {
  throw new Error(`CLIENT_LANGUAGE ${languageId} does not match manifest ${manifest.id}`);
}

const intendedCapabilities = new Set(manifest.intendedCapabilities ?? []);
const wantsLive = intendedCapabilities.has("live");
if (wantsLive && !manifest.syncProfile) {
  throw new Error(`${languageId}: Live intent requires a pinned syncProfile`);
}

const artifacts = process.env.ARTIFACTS_DIR ?? "/artifacts";
const referenceAdapterPath = fileURLToPath(
  new URL("../reference-js/adapter.mjs", import.meta.url),
);
const startedAt = new Date();
const testResults = [];
const runNonce = `${languageId}-${Date.now()}-${randomBytes(6).toString("hex")}`;
let sequence = 0;
let clientRuntime = "unknown";

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function pinnedBaseImageDigests() {
  const dockerfile = fs.readFileSync(path.join(languageDirectory, "Dockerfile"), "utf8");
  const digests = new Set();
  for (const line of dockerfile.split(/\r?\n/)) {
    // The Dockerfile frontend is build machinery, not one of the resulting
    // image's base layers, so it does not belong in this evidence field.
    if (line.trimStart().startsWith("# syntax=")) continue;
    for (const match of line.matchAll(/@sha256:([0-9a-f]{64})/g)) {
      digests.add(`sha256:${match[1]}`);
    }
  }
  if (digests.size === 0) {
    throw new Error(`${languageId}: Dockerfile has no pinned base image digest`);
  }
  return [...digests];
}

const oracle = new AdapterProcess(process.execPath, [referenceAdapterPath]).start();
const client = new AdapterProcess(null, [], { tcp: clientAdapterTCP }).start();

function nextId(prefix) {
  sequence += 1;
  return `${prefix}-${sequence}`;
}

async function test(name, fn) {
  const start = performance.now();
  const transcriptStart = {
    oracle: oracle.transcript.length,
    client: client.transcript.length,
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
    client: client.transcript.slice(transcriptStart.client),
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
  assert.equal(response.protocolVersion, 1);
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

async function runHTTP(label, adapter, { expectLogs, languageName, testAuth }) {
  const room = `${runNonce}-${label}-http`;

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
      language: languageName,
      runId: `${room}-once`,
    });
    assert.equal(response.value.applied, true);
    assert.equal(response.value.state.count, 1);
  });

  await test(`${label}/http/idempotent-mutation`, async () => {
    const response = await call(adapter, "mutation", "demo:increment", {
      room,
      language: languageName,
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
      language: languageName,
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

  if (testAuth) {
    await test(`${label}/http/bearer-token-lifecycle`, async () => {
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
  const base = `${runNonce}-${label}-live`;

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
  const response = await hello(oracle, "oracle");
  assert.equal(response.language, "javascript");
  assert.ok(response.implementation);
  assert.ok(response.runtime);
});
await test("client/adapter/hello", async () => {
  const response = await hello(client, "client");
  assert.equal(response.language, languageId);
  assert.ok(response.implementation);
  assert.ok(response.runtime);
  clientRuntime = response.runtime;
});

await runHTTP("oracle", oracle, {
  expectLogs: false,
  languageName: "JavaScript",
  testAuth: false,
});
await runHTTP("client", client, {
  expectLogs: true,
  languageName: manifest.displayName,
  testAuth: true,
});

if (wantsLive) {
  await runLive("oracle", oracle);
  await runLive("client", client);
}

await test("client/adapter/clean-close", async () => {
  const response = await client.request({ id: nextId("client-close"), op: "close" });
  assert.equal(response.type, "closed", JSON.stringify(response));
  assert.equal((await client.waitForExit()).code, 0);
});
await client.stop();

await test("oracle/adapter/clean-close", async () => {
  const response = await oracle.request({ id: nextId("oracle-close"), op: "close" });
  assert.equal(response.type, "closed", JSON.stringify(response));
  assert.equal((await oracle.waitForExit()).code, 0);
});
await oracle.stop();

const earnedCapabilities = earnedCapabilitiesFor(testResults);

let backendVersion = "unknown";
try {
  const response = await fetch(`${deploymentUrl.replace(/\/$/, "")}/version`);
  if (response.ok) backendVersion = await response.text();
} catch {
  // The individual calls already provide better failure evidence.
}

const transcript = { oracle: oracle.transcript, client: client.transcript };
const transcriptJSON = `${JSON.stringify(transcript, null, 2)}\n`;
const result = {
  schemaVersion: 1,
  language: languageId,
  sourceCommit: process.env.SOURCE_COMMIT ?? "unknown",
  dirty: process.env.SOURCE_DIRTY === "true",
  provenance: manifest.implementation.provenance,
  runtimeVersion: clientRuntime,
  platform: process.env.TEST_PLATFORM ?? "linux/amd64",
  imageDigest: process.env.CLIENT_IMAGE_DIGEST ?? "unknown",
  clientTreeHash: process.env.CLIENT_TREE_HASH ?? "unknown",
  baseImageDigests: pinnedBaseImageDigests(),
  backend: {
    kind: process.env.BACKEND_KIND ?? "self-hosted",
    url: deploymentUrl,
    version: backendVersion.trim() || "unknown",
    imageDigest: process.env.BACKEND_IMAGE_DIGEST || null,
  },
  protocol: manifest.syncProfile?.id ?? "documented-http-json",
  revisions: {
    harnessTreeHash: process.env.HARNESS_TREE_HASH ?? "unknown",
    backendTreeHash: process.env.BACKEND_TREE_HASH ?? "unknown",
    protocolSourceCommit: manifest.syncProfile?.sourceCommit ?? null,
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
fs.writeFileSync(
  path.join(artifacts, `${languageId}-pilot-transcript.json`),
  transcriptJSON,
);
fs.writeFileSync(
  path.join(artifacts, `${languageId}-pilot-result.json`),
  `${JSON.stringify(result, null, 2)}\n`,
);

if (testResults.some((entry) => entry.status === "fail")) process.exitCode = 1;
console.log(`Earned capabilities: ${earnedCapabilities.join(", ") || "none"}`);
