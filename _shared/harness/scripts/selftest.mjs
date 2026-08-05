import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { AdapterProcess } from "./adapter-process.mjs";

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
console.log("PASS harness rejects wrong values, hangs, and dirty exits");
