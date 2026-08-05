#!/usr/local/bin/node
import net from "node:net";
import readline from "node:readline";
// Runtime images install the client at this fixed path while test images use
// the source-relative fallback below.
import { Client, ConvexError } from "../../convex.js";

const runtime = `node-${process.versions.node}`;
function run(input, output) {
  let client; const subscriptions = new Map();
  const write = (event) => output.write(`${JSON.stringify(event)}\n`);
  const failure = (id, error, subscriptionId) => write(subscriptionId ? { type: "subscription", subscriptionId, error: serialiseError(error), ...(error.logs ? { logs: error.logs } : {}) } : { type: "error", ...(id ? { id } : {}), error: serialiseError(error), ...(error.logs ? { logs: error.logs } : {}) });
  const getClient = () => client ??= new Client(requiredUrl(), { authToken: process.env.CONVEX_AUTH_TOKEN ?? "" });
  readline.createInterface({ input, crlfDelay: Infinity }).on("line", async (line) => {
    let command; try { command = JSON.parse(line); } catch (error) { failure(undefined, error); return; }
    try {
      if (command.op === "hello") { if (command.protocolVersion !== 1) throw new Error(`unsupported adapter protocol version ${command.protocolVersion}`); write({ protocolVersion: 1, id: command.id, type: "ready", language: "javascript", implementation: `native-javascript-${runtime}`, runtime }); return; }
      if (["query", "mutation", "action"].includes(command.op)) { const result = await getClient()[command.op](command.path, command.args ?? {}); write({ id: command.id, type: "result", value: result.value, ...(result.logs.length ? { logs: result.logs } : {}) }); return; }
      if (command.op === "setAuth") { getClient().setAuth(command.token); write({ id: command.id, type: "ack" }); return; }
      if (command.op === "subscribe") { if (!command.subscriptionId) throw new Error("subscriptionId is required"); const previous = subscriptions.get(command.subscriptionId); await previous?.close(); const sub = getClient().subscribe(command.path, command.args ?? {}); subscriptions.set(command.subscriptionId, sub); write({ id: command.id, type: "ack" }); (async () => { for await (const update of sub) { if (update.error) failure(undefined, update.error, command.subscriptionId); else write({ type: "subscription", subscriptionId: command.subscriptionId, value: update.value, ...(update.logs?.length ? { logs: update.logs } : {}) }); } })(); return; }
      if (command.op === "unsubscribe") { await subscriptions.get(command.subscriptionId)?.close(); subscriptions.delete(command.subscriptionId); write({ id: command.id, type: "ack" }); return; }
      if (command.op === "debugDisconnect") { await getClient().debugDisconnectForAdapter(); write({ id: command.id, type: "ack" }); return; }
      if (command.op === "close") { for (const sub of subscriptions.values()) await sub.close(); await client?.close(); write({ id: command.id, type: "closed" }); input.destroy(); return; }
      throw new Error(`unknown operation ${JSON.stringify(command.op)}`);
    } catch (error) { failure(command.id, error); }
  });
}
function requiredUrl() { if (!process.env.CONVEX_URL) throw new Error("CONVEX_URL is required"); return process.env.CONVEX_URL; }
function serialiseError(error) { return { name: error instanceof ConvexError ? error.name : "Error", message: error.message, ...(error.data !== undefined ? { data: error.data } : {}) }; }
if (process.env.ADAPTER_LISTEN) { const server = net.createServer((socket) => { server.close(); run(socket, socket); }); server.listen(process.env.ADAPTER_LISTEN); } else run(process.stdin, process.stdout);
