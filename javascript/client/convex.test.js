import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";
import { once } from "node:events";
import { WebSocketServer } from "ws";
import { Client, ConvexError } from "./convex.js";

const zeroVersion = { querySet: 0, identity: 0, ts: "AAAAAAAAAAA=" };

test("HTTP calls preserve success values, logs, auth, and structured failures", async () => {
  const requests = [];
  const server = http.createServer(async (request, response) => {
    const body = JSON.parse(await readBody(request));
    requests.push({ url: request.url, headers: request.headers, body });
    response.setHeader("content-type", "application/json");
    if (body.path === "demo:fail") {
      response.end(
        JSON.stringify({
          status: "error",
          errorMessage: "deliberate failure",
          errorData: { code: "EXPECTED" },
          logLines: ["failure log"],
        }),
      );
    } else {
      response.end(
        JSON.stringify({
          status: "success",
          value: { operation: request.url },
          logLines: ["success log"],
        }),
      );
    }
  });
  const url = await listen(server);
  const client = new Client(url, { authToken: "test-token" });
  try {
    const result = await client.query("demo:ok", { room: "one" });
    assert.deepEqual(result, {
      value: { operation: "/api/query" },
      logs: ["success log"],
    });
    await assert.rejects(
      client.mutation("demo:fail", {}),
      (error) =>
        error instanceof ConvexError &&
        error.name === "FunctionError" &&
        error.message === "deliberate failure" &&
        error.data.code === "EXPECTED" &&
        error.logs[0] === "failure log",
    );
    assert.equal(requests[0].headers.authorization, "Bearer test-token");
    assert.equal(requests[0].headers["convex-client"], "javascript-0.1.0");
    assert.deepEqual(requests[0].body, {
      path: "demo:ok",
      args: { room: "one" },
      format: "json",
    });
  } finally {
    await client.close();
    await closeServer(server);
  }
});

test("rejects invalid arguments and operations after close", async () => {
  const client = new Client("https://example.test");
  await assert.rejects(client.query("demo:state", []), /named JSON object/);
  await client.close();
  await assert.rejects(
    client.query("demo:state"),
    (error) => error instanceof ConvexError && error.name === "ClosedError",
  );
});

test("Live reconnects after debugDisconnect and unsubscribe sends Remove", async () => {
  const messages = [];
  let connectionCount = 0;
  const { server, sockets, url } = await liveServer(
    (socket, message) => {
      messages.push(message);
      if (message.type !== "ModifyQuerySet") return;
      const add = message.modifications.find((item) => item.type === "Add");
      if (!add) return;
      sendTransition(socket, zeroVersion, version(connectionCount), [
        { type: "QueryUpdated", queryId: add.queryId, value: connectionCount },
      ]);
    },
    () => {
      connectionCount++;
    },
  );
  const client = new Client(url);
  const subscription = client.subscribe("demo:state", { room: "reconnect" });
  try {
    assert.equal((await nextValue(subscription)).value, 1);
    await client.debugDisconnectForAdapter();
    assert.equal((await nextValue(subscription)).value, 2);
    await subscription.close();
    await waitFor(() =>
      messages.some((message) =>
        message.modifications?.some((item) => item.type === "Remove"),
      ),
    );
    assert.deepEqual(await subscription.next(), { done: true });
  } finally {
    await client.close();
    for (const socket of sockets) socket.terminate();
    await closeServer(server);
  }
});

test("Live serialises query failures and bounds a slow consumer to 16 newest values", async () => {
  const remoteVersions = new WeakMap();
  const { server, sockets, url } = await liveServer((socket, message) => {
    if (message.type !== "ModifyQuerySet") return;
    const add = message.modifications.find((item) => item.type === "Add");
    if (!add) return;
    let start = remoteVersions.get(socket) ?? zeroVersion;
    if (add.udfPath === "demo:fail") {
      const end = version(1);
      sendTransition(socket, start, end, [
        {
          type: "QueryFailed",
          queryId: add.queryId,
          errorMessage: "subscription failed",
          errorData: { code: "LIVE_FAIL" },
          logLines: ["live log"],
        },
      ]);
      remoteVersions.set(socket, end);
      return;
    }
    for (let count = 0; count < 18; count++) {
      const end = version(count + 1);
      sendTransition(socket, start, end, [
        { type: "QueryUpdated", queryId: add.queryId, value: count },
      ]);
      start = end;
    }
    remoteVersions.set(socket, start);
  });
  const client = new Client(url);
  try {
    const failed = client.subscribe("demo:fail", {});
    const failure = (await failed.next()).value.error;
    assert.equal(failure.name, "FunctionError");
    assert.equal(failure.data.code, "LIVE_FAIL");
    assert.deepEqual(failure.logs, ["live log"]);
    await failed.close();

    const slow = client.subscribe("demo:many", {});
    await waitFor(async () => {
      await new Promise((resolve) => setTimeout(resolve, 25));
      return true;
    });
    const values = [];
    for (let index = 0; index < 16; index++) {
      values.push((await nextValue(slow)).value);
    }
    assert.deepEqual(
      values,
      Array.from({ length: 16 }, (_, index) => index + 2),
    );
    await slow.close();
  } finally {
    await client.close();
    for (const socket of sockets) socket.terminate();
    await closeServer(server);
  }
});

async function liveServer(onMessage, onConnection = () => {}) {
  const server = http.createServer();
  const webSockets = new WebSocketServer({ server, path: "/api/sync" });
  const sockets = new Set();
  webSockets.on("connection", (socket) => {
    sockets.add(socket);
    onConnection();
    socket.on("message", (raw) =>
      onMessage(socket, JSON.parse(raw.toString())),
    );
    socket.on("close", () => sockets.delete(socket));
  });
  const url = await listen(server);
  return { server, sockets, url };
}

function sendTransition(socket, startVersion, endVersion, modifications) {
  socket.send(
    JSON.stringify({
      type: "Transition",
      startVersion,
      endVersion,
      modifications,
    }),
  );
}

function version(number) {
  return {
    querySet: 1,
    identity: 0,
    ts: Buffer.from(`${number}`).toString("base64"),
  };
}

async function nextValue(subscription) {
  return Promise.race([
    subscription.next().then((item) => {
      assert.equal(item.done, false);
      if (item.value.error) throw item.value.error;
      return item.value;
    }),
    new Promise((_, reject) =>
      setTimeout(
        () => reject(new Error("timed out waiting for Live value")),
        2_000,
      ),
    ),
  ]);
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

async function waitFor(predicate) {
  const deadline = Date.now() + 2_000;
  while (!(await predicate())) {
    if (Date.now() > deadline) throw new Error("condition was not met");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
