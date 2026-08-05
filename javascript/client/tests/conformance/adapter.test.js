import assert from "node:assert/strict";
import { once } from "node:events";
import http from "node:http";
import net from "node:net";
import { PassThrough } from "node:stream";
import test from "node:test";
import { WebSocketServer } from "ws";
import { parseListenAddress, runAdapter, startTcpAdapter } from "./adapter.js";

const zeroVersion = { querySet: 0, identity: 0, ts: "AAAAAAAAAAA=" };

test("adapter serialises success, structured HTTP failure, optional IDs, and close", async () => {
  const server = http.createServer(async (request, response) => {
    const command = JSON.parse(await readBody(request));
    response.setHeader("content-type", "application/json");
    response.end(
      command.path === "demo:fail"
        ? JSON.stringify({
            status: "error",
            errorMessage: "adapter failure",
            errorData: { code: "ADAPTER_FAIL" },
            logLines: ["adapter log"],
          })
        : JSON.stringify({ status: "success", value: { count: 3 } }),
    );
  });
  const deploymentUrl = await listen(server);
  const adapter = streamAdapter({ CONVEX_URL: deploymentUrl });
  try {
    adapter.send({ protocolVersion: 1, id: "hello", op: "hello" });
    adapter.send({ id: "ok", op: "query", path: "demo:state", args: {} });
    adapter.send({ id: "bad", op: "mutation", path: "demo:fail", args: {} });
    adapter.input.write("not-json\n");
    adapter.send({ id: "close", op: "close" });
    const events = await adapter.events(5);
    assert.equal(events[0].type, "ready");
    assert.equal(events[0].language, "javascript");
    assert.deepEqual(events[1], {
      id: "ok",
      type: "result",
      value: { count: 3 },
    });
    assert.deepEqual(events[2], {
      id: "bad",
      type: "error",
      error: {
        name: "FunctionError",
        message: "adapter failure",
        data: { code: "ADAPTER_FAIL" },
      },
      logs: ["adapter log"],
    });
    assert.equal(events[3].type, "error");
    assert.equal(Object.hasOwn(events[3], "id"), false);
    assert.deepEqual(events[4], { id: "close", type: "closed" });
  } finally {
    adapter.input.destroy();
    adapter.output.destroy();
    await closeServer(server);
  }
});

test("adapter serialises subscription errors without an id and acknowledges unsubscribe", async () => {
  const server = http.createServer();
  const webSockets = new WebSocketServer({ server, path: "/api/sync" });
  webSockets.on("connection", (socket) => {
    socket.on("message", (raw) => {
      const message = JSON.parse(raw.toString());
      const add = message.modifications?.find((item) => item.type === "Add");
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
    });
  });
  const deploymentUrl = await listen(server);
  const adapter = streamAdapter({ CONVEX_URL: deploymentUrl });
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
      const add = message.modifications?.find((item) => item.type === "Add");
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
  const deploymentUrl = await listen(server);
  const adapter = streamAdapter({ CONVEX_URL: deploymentUrl });
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

test("ADAPTER_LISTEN parses host:port and serves a real TCP lifecycle without filesystem writes", async () => {
  assert.deepEqual(parseListenAddress("127.0.0.1:3210"), {
    host: "127.0.0.1",
    port: 3210,
  });
  assert.throws(() => parseListenAddress("3210"), /host:port/);

  const server = startTcpAdapter("127.0.0.1:0", {});
  await once(server, "listening");
  const socket = net.createConnection(server.address());
  await once(socket, "connect");
  const lines = collectLines(socket);
  socket.write('{"protocolVersion":1,"id":"hello","op":"hello"}\n');
  socket.write('{"id":"close","op":"close"}\n');
  const events = await lines.waitFor(2);
  assert.equal(events[0].type, "ready");
  assert.deepEqual(events[1], { id: "close", type: "closed" });
  socket.destroy();
});

function streamAdapter(environment) {
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

function collectLines(stream) {
  const values = [];
  const waiters = [];
  let pending = "";
  stream.on("data", (chunk) => {
    pending += chunk.toString();
    const lines = pending.split("\n");
    pending = lines.pop();
    for (const line of lines) {
      if (line) values.push(JSON.parse(line));
    }
    for (const waiter of waiters.splice(0)) waiter();
  });
  return {
    waitFor: async (count) => {
      const deadline = Date.now() + 2_000;
      while (values.length < count) {
        if (Date.now() > deadline)
          throw new Error("timed out waiting for adapter event");
        await new Promise((resolve) => {
          waiters.push(resolve);
          setTimeout(resolve, 25);
        });
      }
      return values;
    },
  };
}

async function listen(server) {
  server.listen({ host: "127.0.0.1", port: 0 });
  await once(server, "listening");
  return `http://127.0.0.1:${server.address().port}`;
}

async function closeServer(server) {
  if (!server.listening) return;
  server.close();
  await once(server, "close");
}

async function readBody(request) {
  let body = "";
  for await (const chunk of request) body += chunk;
  return body;
}
