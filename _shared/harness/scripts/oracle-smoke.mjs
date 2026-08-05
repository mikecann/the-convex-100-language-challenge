import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { AdapterProcess } from "./adapter-process.mjs";

const adapterPath = fileURLToPath(
  new URL("../reference-js/adapter.mjs", import.meta.url),
);
const adapter = new AdapterProcess(process.execPath, [adapterPath]).start();
const room = `oracle-${Date.now()}`;

await adapter.request({ protocolVersion: 1, id: "hello", op: "hello" });

const initial = await adapter.request({
  id: "initial",
  op: "query",
  path: "demo:state",
  args: { room },
});
assert.equal(initial.type, "result");
assert.equal(initial.value.count, 0);

const greet = await adapter.request({
  id: "greet",
  op: "action",
  path: "demo:greet",
  args: { language: "JavaScript" },
});
assert.equal(greet.value.language, "JavaScript");

await adapter.request({
  id: "subscribe",
  op: "subscribe",
  subscriptionId: "room",
  path: "demo:state",
  args: { room },
});
assert.equal((await adapter.nextSubscription("room")).value.count, 0);

await adapter.request({
  id: "increment-1",
  op: "mutation",
  path: "demo:increment",
  args: { room, language: "javascript", runId: `${room}-1` },
});
assert.equal((await adapter.nextSubscription("room")).value.count, 1);

await adapter.request({ id: "disconnect", op: "debugDisconnect" });
await adapter.request({
  id: "increment-2",
  op: "mutation",
  path: "demo:increment",
  args: { room, language: "javascript", runId: `${room}-2` },
});
assert.equal((await adapter.nextSubscription("room", 15_000)).value.count, 2);

await adapter.request({
  id: "unsubscribe",
  op: "unsubscribe",
  subscriptionId: "room",
});
await adapter.request({ id: "close", op: "close" });
const exit = await adapter.exitPromise;
assert.equal(exit.code, 0);

console.log(`PASS official JavaScript oracle against ${process.env.CONVEX_URL}`);
