import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import http from "node:http";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "ws";

const zeroVersion = { querySet: 0, identity: 0, ts: "AAAAAAAAAAA=" };

test("canonical source prints only the six-line journey and closes Live", async () => {
  let liveSocket;
  let liveClosed = false;
  let remoteVersion = zeroVersion;
  const server = http.createServer(async (request, response) => {
    const body = JSON.parse(await readBody(request));
    response.setHeader("content-type", "application/json");
    if (request.url === "/api/query") {
      response.end(JSON.stringify({ status: "success", value: { count: 0 } }));
      return;
    }
    assert.equal(request.url, "/api/mutation");
    assert.equal(body.path, "demo:increment");
    assert.equal(body.args.language, "javascript");
    assert.match(body.args.runId, /^[0-9a-f-]{36}$/);
    response.end(
      JSON.stringify({
        status: "success",
        value: { applied: true, state: { count: 1 } },
      }),
    );
    const end = { querySet: 1, identity: 0, ts: "Mg==" };
    sendValue(liveSocket, remoteVersion, end, 0, 1);
    remoteVersion = end;
  });
  const webSockets = new WebSocketServer({ server, path: "/api/sync" });
  webSockets.on("connection", (socket) => {
    liveSocket = socket;
    socket.on("close", () => {
      liveClosed = true;
    });
    socket.on("message", (raw) => {
      const message = JSON.parse(raw.toString());
      const add = message.modifications?.find((item) => item.type === "Add");
      if (!add) return;
      const end = { querySet: 1, identity: 0, ts: "MQ==" };
      sendValue(socket, remoteVersion, end, add.queryId, 0);
      remoteVersion = end;
    });
  });
  server.listen({ host: "127.0.0.1", port: 0 });
  await once(server, "listening");

  try {
    const child = spawn(
      process.execPath,
      [fileURLToPath(new URL("./main.js", import.meta.url)), "test-room"],
      {
        env: {
          ...process.env,
          CONVEX_URL: `http://127.0.0.1:${server.address().port}`,
        },
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    const [exitCode] = await once(child, "exit");
    assert.equal(exitCode, 0, stderr);
    assert.deepEqual(stdout.trimEnd().split("\n"), [
      "current count: 0",
      "live initial count: 0",
      "mutation applied: true",
      "mutation count: 1",
      "live updated count: 1",
      "verified count: 0 -> 1",
    ]);
    assert.equal(liveClosed, true, "the example must close its Live WebSocket");
  } finally {
    liveSocket?.terminate();
    webSockets.close();
    server.close();
    await once(server, "close");
  }
});

function sendValue(socket, startVersion, endVersion, queryId, count) {
  socket.send(
    JSON.stringify({
      type: "Transition",
      startVersion,
      endVersion,
      modifications: [{ type: "QueryUpdated", queryId, value: { count } }],
    }),
  );
}

async function readBody(request) {
  let body = "";
  for await (const chunk of request) body += chunk;
  return body;
}
