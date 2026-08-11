import crypto from "node:crypto";
import http from "node:http";

let count = 0;
let liveSocket;
let timestamp = "AAAAAAAAAAA=";

function frame(message) {
  const body = Buffer.from(JSON.stringify(message));
  const header = Buffer.alloc(body.length < 126 ? 2 : body.length <= 0xffff ? 4 : 10);
  header[0] = 0x81;
  if (body.length < 126) {
    header[1] = body.length;
  } else if (body.length <= 0xffff) {
    header[1] = 126;
    header.writeUInt16BE(body.length, 2);
  } else {
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(body.length), 2);
  }
  return Buffer.concat([header, body]);
}

function sendUpdate(nextTimestamp) {
  if (!liveSocket) return;
  liveSocket.write(frame({
    type: "Transition",
    startVersion: { querySet: timestamp === "AAAAAAAAAAA=" ? 0 : 1, identity: 0, ts: timestamp },
    endVersion: { querySet: 1, identity: 0, ts: nextTimestamp },
    modifications: [{
      type: "QueryUpdated",
      queryId: 0,
      value: { count },
      logLines: [],
    }],
  }));
  timestamp = nextTimestamp;
}

const server = http.createServer((request, response) => {
  let body = "";
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    const operation = JSON.parse(body);
    response.setHeader("content-type", "application/json");
    if (request.url === "/api/query") {
      response.end(JSON.stringify({ status: "success", value: { count }, logLines: [] }));
      return;
    }
    if (request.url === "/api/mutation") {
      count = 1;
      response.end(JSON.stringify({
        status: "success",
        value: { applied: true, state: { count } },
        logLines: [],
      }));
      setTimeout(() => sendUpdate("example-updated"), 10);
      return;
    }
    response.writeHead(404).end(JSON.stringify({ operation }));
  });
});

server.on("upgrade", (request, socket) => {
  const accept = crypto
    .createHash("sha1")
    .update(`${request.headers["sec-websocket-key"]}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  liveSocket = socket;
  socket.on("error", () => {});
  // Give the client time to send Connect and Add before the first Transition.
  setTimeout(() => sendUpdate("example-initial"), 100);
});

server.listen(18080, "0.0.0.0", () => console.log("EXAMPLE_FIXTURE_READY"));
