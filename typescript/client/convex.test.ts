import assert from "node:assert/strict";
import { once } from "node:events";
import http, { IncomingMessage, Server, ServerResponse } from "node:http";
import test from "node:test";
import WebSocket, { WebSocketServer } from "ws";
import { Client, ConvexError, Subscription } from "./convex.js";

type Message = Record<string, any>;
type Version = { querySet: number; identity: number; ts: string };
const zeroVersion: Version = { querySet: 0, identity: 0, ts: "AAAAAAAAAAA=" };

test("HTTP formats query, mutation, and action requests with auth, logs, nested UTF-8, and structured errors", async () => {
  const requests: Array<{
    url?: string;
    headers: IncomingMessage["headers"];
    body: Message;
  }> = [];
  const server = http.createServer(async (request, response) => {
    const body = JSON.parse(await readBody(request));
    requests.push({ url: request.url, headers: request.headers, body });
    response.setHeader("content-type", "application/json");
    if (body.path === "demo:fail") {
      response.end(
        JSON.stringify({
          status: "error",
          errorMessage: "deliberate failure",
          errorData: { code: "EXPECTED", nested: { text: "café 🦘" } },
          logLines: ["failure log"],
        }),
      );
    } else {
      response.end(
        JSON.stringify({
          status: "success",
          value: { operation: request.url, nested: body.args },
          logLines: ["success log"],
        }),
      );
    }
  });
  const client = new Client(await listen(server), { authToken: "first-token" });
  try {
    const nested = { text: "café 🦘", values: [1, true, { deep: "値" }] };
    assert.deepEqual(await client.query("demo:ok", nested), {
      value: { operation: "/api/query", nested },
      logs: ["success log"],
    });
    client.setAuth("second-token");
    await client.action("demo:ok", { action: true });
    await assert.rejects(client.mutation("demo:fail", {}), (error: unknown) => {
      assert(error instanceof ConvexError);
      assert.equal(error.name, "FunctionError");
      assert.equal(error.message, "deliberate failure");
      assert.deepEqual(error.data, {
        code: "EXPECTED",
        nested: { text: "café 🦘" },
      });
      assert.deepEqual(error.logs, ["failure log"]);
      return true;
    });
    assert.deepEqual(
      requests.map((request) => request.url),
      ["/api/query", "/api/action", "/api/mutation"],
    );
    assert.equal(requests[0].headers.authorization, "Bearer first-token");
    assert.equal(requests[1].headers.authorization, "Bearer second-token");
    assert.equal(requests[0].headers["convex-client"], "typescript-0.1.0");
    assert.deepEqual(requests[0].body, {
      path: "demo:ok",
      args: nested,
      format: "json",
    });
  } finally {
    await client.close();
    await closeServer(server);
  }
});

test("rejects invalid arguments and operations after clean close", async () => {
  const client = new Client("https://example.test");
  await assert.rejects(
    client.query("demo:state", [] as unknown as Record<string, unknown>),
    /named JSON object/,
  );
  await client.close();
  await client.close();
  await assert.rejects(
    client.query("demo:state"),
    (error: unknown) =>
      error instanceof ConvexError && error.name === "ClosedError",
  );
});

test("Live delivers initial and updated values, reconnects with backoff, resubscribes, and sends Remove", async () => {
  const messages: Message[] = [];
  const connectionTimes: number[] = [];
  let connectionCount = 0;
  const live = await liveServer(
    (socket, message) => {
      messages.push(message);
      if (message.type !== "ModifyQuerySet") return;
      const add = message.modifications.find(
        (item: Message) => item.type === "Add",
      );
      if (!add) return;
      sendTransition(socket, zeroVersion, version(connectionCount), [
        {
          type: "QueryUpdated",
          queryId: add.queryId,
          value: { count: connectionCount - 1 },
        },
      ]);
    },
    () => {
      connectionCount++;
      connectionTimes.push(Date.now());
    },
  );
  const client = new Client(live.url);
  const subscription = client.subscribe("demo:state", { room: "reconnect" });
  try {
    assert.deepEqual((await nextValue(subscription)).value, { count: 0 });
    const disconnectedAt = Date.now();
    await client.debugDisconnectForAdapter();
    assert.deepEqual((await nextValue(subscription)).value, { count: 1 });
    assert(
      connectionTimes[1] - disconnectedAt >= 75,
      "reconnect should honour the 100ms initial backoff",
    );
    assert(
      connectionTimes[1] - disconnectedAt < 1_000,
      "reconnect backoff should remain responsive",
    );
    assert.equal(
      messages.filter((message) => message.type === "Connect").length,
      2,
    );
    assert.equal(
      messages.filter((message) =>
        message.modifications?.some((item: Message) => item.type === "Add"),
      ).length,
      2,
    );
    await subscription.close();
    await waitFor(() =>
      messages.some((message) =>
        message.modifications?.some((item: Message) => item.type === "Remove"),
      ),
    );
    assert.deepEqual(await subscription.next(), {
      value: undefined,
      done: true,
    });
  } finally {
    await client.close();
    for (const socket of live.sockets) socket.terminate();
    await closeServer(live.server);
  }
});

test("Live recovers after a query error and bounds a slow consumer to the newest 16 values", async () => {
  const remoteVersions = new WeakMap<WebSocket, Version>();
  const live = await liveServer((socket, message) => {
    if (message.type !== "ModifyQuerySet") return;
    const add = message.modifications.find(
      (item: Message) => item.type === "Add",
    );
    if (!add) return;
    let start = remoteVersions.get(socket) ?? zeroVersion;
    if (add.udfPath === "demo:fail") {
      const failedVersion = version(1);
      sendTransition(socket, start, failedVersion, [
        {
          type: "QueryFailed",
          queryId: add.queryId,
          errorMessage: "subscription failed",
          errorData: { code: "LIVE_FAIL" },
          logLines: ["live log"],
        },
      ]);
      remoteVersions.set(socket, failedVersion);
      setTimeout(() => {
        const recoveredVersion = version(2);
        sendTransition(socket, failedVersion, recoveredVersion, [
          {
            type: "QueryUpdated",
            queryId: add.queryId,
            value: { recovered: true },
            logLines: ["recovery log"],
          },
        ]);
        remoteVersions.set(socket, recoveredVersion);
      }, 10);
      return;
    }
    for (let count = 0; count < 18; count++) {
      const end = version(count + 3);
      sendTransition(socket, start, end, [
        { type: "QueryUpdated", queryId: add.queryId, value: count },
      ]);
      start = end;
    }
    remoteVersions.set(socket, start);
  });
  const client = new Client(live.url);
  try {
    const failed = client.subscribe("demo:fail", {});
    const failedItem = await failed.next();
    assert.equal(failedItem.done, false);
    const failure = failedItem.value.error!;
    assert.equal(failure.name, "FunctionError");
    assert.deepEqual(failure.data, { code: "LIVE_FAIL" });
    assert.deepEqual(failure.logs, ["live log"]);
    const recovered = await nextValue(failed);
    assert.deepEqual(recovered, {
      value: { recovered: true },
      logs: ["recovery log"],
    });
    await failed.close();
    const slow = client.subscribe("demo:many", {});
    await new Promise((resolve) => setTimeout(resolve, 40));
    const values: unknown[] = [];
    for (let index = 0; index < 16; index++)
      values.push((await nextValue(slow)).value);
    assert.deepEqual(
      values,
      Array.from({ length: 16 }, (_, index) => index + 2),
    );
    await slow.close();
  } finally {
    await client.close();
    for (const socket of live.sockets) socket.terminate();
    await closeServer(live.server);
  }
});

async function liveServer(
  onMessage: (socket: WebSocket, message: Message) => void,
  onConnection: () => void = () => {},
) {
  const server = http.createServer();
  const webSockets = new WebSocketServer({ server, path: "/api/sync" });
  const sockets = new Set<WebSocket>();
  webSockets.on("connection", (socket) => {
    sockets.add(socket);
    onConnection();
    socket.on("message", (raw) =>
      onMessage(socket, JSON.parse(raw.toString())),
    );
    socket.on("close", () => sockets.delete(socket));
  });
  return { server, webSockets, sockets, url: await listen(server) };
}
function sendTransition(
  socket: WebSocket,
  startVersion: Version,
  endVersion: Version,
  modifications: Message[],
): void {
  socket.send(
    JSON.stringify({
      type: "Transition",
      startVersion,
      endVersion,
      modifications,
    }),
  );
}
function version(number: number): Version {
  return {
    querySet: 1,
    identity: 0,
    ts: Buffer.from(String(number)).toString("base64"),
  };
}
async function nextValue(subscription: Subscription) {
  return Promise.race([
    subscription.next().then((item) => {
      assert.equal(item.done, false);
      if (item.value.error) throw item.value.error;
      return item.value;
    }),
    new Promise<never>((_, reject) =>
      setTimeout(
        () => reject(new Error("timed out waiting for Live value")),
        2_000,
      ),
    ),
  ]);
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
async function waitFor(
  predicate: () => boolean | Promise<boolean>,
): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (!(await predicate())) {
    if (Date.now() > deadline) throw new Error("condition was not met");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
