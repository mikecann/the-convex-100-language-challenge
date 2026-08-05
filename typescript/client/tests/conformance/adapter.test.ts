import assert from "node:assert/strict";
import { once } from "node:events";
import http, { IncomingMessage, Server } from "node:http";
import net from "node:net";
import { PassThrough, Readable, Writable } from "node:stream";
import test from "node:test";
import { WebSocketServer } from "ws";
import { parseListenAddress, runAdapter, startTcpAdapter } from "./adapter.js";

type Event = Record<string, any>;
type StreamAdapter = {
  input: PassThrough;
  output: PassThrough;
  send: (command: object) => boolean;
  events: (count: number) => Promise<Event[]>;
};
const zeroVersion = { querySet: 0, identity: 0, ts: "AAAAAAAAAAA=" };

test("adapter serialises success, structured HTTP failure, optional IDs, auth, and close", async () => {
  const authorizations: Array<string | undefined> = [];
  const server = http.createServer(async (request, response) => {
    const command = JSON.parse(await readBody(request));
    authorizations.push(request.headers.authorization);
    response.setHeader("content-type", "application/json");
    response.end(
      command.path === "demo:fail"
        ? JSON.stringify({
            status: "error",
            errorMessage: "adapter failure",
            errorData: { code: "ADAPTER_FAIL" },
            logLines: ["adapter log"],
          })
        : JSON.stringify({
            status: "success",
            value: { count: 3, text: "café 🦘" },
          }),
    );
  });
  const adapter = streamAdapter({ CONVEX_URL: await listen(server) });
  try {
    adapter.send({ protocolVersion: 1, id: "hello", op: "hello" });
    adapter.send({ id: "auth", op: "setAuth", token: "adapter-token" });
    adapter.send({
      id: "ok",
      op: "query",
      path: "demo:state",
      args: { nested: { value: "値" } },
    });
    adapter.send({ id: "bad", op: "mutation", path: "demo:fail", args: {} });
    adapter.input.write("not-json\n");
    adapter.send({ id: "close", op: "close" });
    const events = await adapter.events(6);
    assert.equal(events[0].type, "ready");
    assert.equal(events[0].language, "typescript");
    assert.deepEqual(events[1], { id: "auth", type: "ack" });
    assert.deepEqual(events[2], {
      id: "ok",
      type: "result",
      value: { count: 3, text: "café 🦘" },
    });
    assert.deepEqual(events[3], {
      id: "bad",
      type: "error",
      error: {
        name: "FunctionError",
        message: "adapter failure",
        data: { code: "ADAPTER_FAIL" },
      },
      logs: ["adapter log"],
    });
    assert.equal(events[4].type, "error");
    assert.equal(Object.hasOwn(events[4], "id"), false);
    assert.deepEqual(events[5], { id: "close", type: "closed" });
    assert.deepEqual(authorizations, [
      "Bearer adapter-token",
      "Bearer adapter-token",
    ]);
  } finally {
    adapter.input.destroy();
    adapter.output.destroy();
    await closeServer(server);
  }
});

test("adapter serialises subscription errors without an id and acknowledges unsubscribe", async () => {
  const server = http.createServer();
  const webSockets = new WebSocketServer({ server, path: "/api/sync" });
  webSockets.on("connection", (socket) =>
    socket.on("message", (raw) => {
      const message = JSON.parse(raw.toString());
      const add = message.modifications?.find(
        (item: Event) => item.type === "Add",
      );
      if (!add) return;
      socket.send(
        JSON.stringify({
          type: "Transition",
          startVersion: zeroVersion,
          endVersion: { querySet: 1, identity: 0, ts: "MQ==" },
          modifications: [
            {
              type: "QueryFailed",
              queryId: add.queryId,
              errorMessage: "live adapter failure",
              errorData: { code: "LIVE_ADAPTER_FAIL" },
              logLines: ["live adapter log"],
            },
          ],
        }),
      );
    }),
  );
  const adapter = streamAdapter({ CONVEX_URL: await listen(server) });
  try {
    adapter.send({
      id: "subscribe",
      op: "subscribe",
      subscriptionId: "room",
      path: "demo:fail",
      args: {},
    });
    const first = await adapter.events(2);
    assert.deepEqual(first[0], { id: "subscribe", type: "ack" });
    assert.equal(first[1].type, "subscription");
    assert.equal(first[1].subscriptionId, "room");
    assert.equal(Object.hasOwn(first[1], "id"), false);
    assert.equal(first[1].error.name, "FunctionError");
    assert.equal(first[1].error.data.code, "LIVE_ADAPTER_FAIL");
    adapter.send({
      id: "unsubscribe",
      op: "unsubscribe",
      subscriptionId: "room",
    });
    adapter.send({ id: "close", op: "close" });
    const all = await adapter.events(4);
    assert.deepEqual(all[2], { id: "unsubscribe", type: "ack" });
    assert.deepEqual(all[3], { id: "close", type: "closed" });
  } finally {
    adapter.input.destroy();
    adapter.output.destroy();
    webSockets.close();
    await closeServer(server);
  }
});

test("adapter debugDisconnect acknowledges and reconnects the active subscription", async () => {
  const server = http.createServer();
  const webSockets = new WebSocketServer({ server, path: "/api/sync" });
  let connectionCount = 0;
  webSockets.on("connection", (socket) => {
    connectionCount++;
    socket.on("message", (raw) => {
      const message = JSON.parse(raw.toString());
      const add = message.modifications?.find(
        (item: Event) => item.type === "Add",
      );
      if (!add) return;
      socket.send(
        JSON.stringify({
          type: "Transition",
          startVersion: zeroVersion,
          endVersion: {
            querySet: 1,
            identity: 0,
            ts: Buffer.from(String(connectionCount)).toString("base64"),
          },
          modifications: [
            {
              type: "QueryUpdated",
              queryId: add.queryId,
              value: { connectionCount },
            },
          ],
        }),
      );
    });
  });
  const adapter = streamAdapter({ CONVEX_URL: await listen(server) });
  try {
    adapter.send({
      id: "subscribe",
      op: "subscribe",
      subscriptionId: "room",
      path: "demo:state",
      args: {},
    });
    let events = await adapter.events(2);
    assert.equal(events[1].value.connectionCount, 1);
    adapter.send({ id: "disconnect", op: "debugDisconnect" });
    events = await adapter.events(4);
    assert.deepEqual(events[2], { id: "disconnect", type: "ack" });
    assert.equal(events[3].value.connectionCount, 2);
    adapter.send({
      id: "unsubscribe",
      op: "unsubscribe",
      subscriptionId: "room",
    });
    adapter.send({ id: "close", op: "close" });
    events = await adapter.events(6);
    assert.deepEqual(events[4], { id: "unsubscribe", type: "ack" });
    assert.deepEqual(events[5], { id: "close", type: "closed" });
  } finally {
    adapter.input.destroy();
    adapter.output.destroy();
    webSockets.close();
    await closeServer(server);
  }
});

test("ADAPTER_LISTEN serves a real TCP lifecycle without filesystem writes", async () => {
  assert.deepEqual(parseListenAddress("127.0.0.1:3210"), {
    host: "127.0.0.1",
    port: 3210,
  });
  assert.throws(() => parseListenAddress("3210"), /host:port/);
  const server = startTcpAdapter("127.0.0.1:0", {});
  await once(server, "listening");
  const address = server.address();
  if (!address || typeof address === "string")
    throw new Error("TCP adapter did not expose an address");
  const socket = net.createConnection({
    host: "127.0.0.1",
    port: address.port,
  });
  await once(socket, "connect");
  const lines = collectLines(socket);
  socket.write('{"protocolVersion":1,"id":"hello","op":"hello"}\n');
  socket.write('{"id":"close","op":"close"}\n');
  const events = await lines.waitFor(2);
  assert.equal(events[0].type, "ready");
  assert.deepEqual(events[1], { id: "close", type: "closed" });
  socket.destroy();
});

function streamAdapter(environment: NodeJS.ProcessEnv): StreamAdapter {
  const input = new PassThrough();
  const output = new PassThrough();
  const lines = collectLines(output);
  runAdapter(input, output, environment);
  return {
    input,
    output,
    send: (command) => input.write(`${JSON.stringify(command)}\n`),
    events: lines.waitFor,
  };
}
function collectLines(stream: Readable): {
  waitFor: (count: number) => Promise<Event[]>;
} {
  const values: Event[] = [];
  const waiters: Array<() => void> = [];
  let pending = "";
  stream.on("data", (chunk) => {
    pending += chunk.toString();
    const lines = pending.split("\n");
    pending = lines.pop() ?? "";
    for (const line of lines) if (line) values.push(JSON.parse(line));
    for (const waiter of waiters.splice(0)) waiter();
  });
  return {
    waitFor: async (count) => {
      const deadline = Date.now() + 2_000;
      while (values.length < count) {
        if (Date.now() > deadline)
          throw new Error("timed out waiting for adapter event");
        await new Promise<void>((resolve) => {
          waiters.push(resolve);
          setTimeout(resolve, 25);
        });
      }
      return values;
    },
  };
}
async function listen(server: Server): Promise<string> {
  server.listen({ host: "127.0.0.1", port: 0 });
  await once(server, "listening");
  const address = server.address();
  if (!address || typeof address === "string")
    throw new Error("server did not expose a TCP address");
  return `http://127.0.0.1:${address.port}`;
}
async function closeServer(server: Server): Promise<void> {
  if (!server.listening) return;
  server.close();
  await once(server, "close");
}
async function readBody(request: IncomingMessage): Promise<string> {
  let body = "";
  for await (const chunk of request) body += chunk;
  return body;
}
