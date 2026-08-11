import crypto from "node:crypto";
import http from "node:http";
import net from "node:net";

const websocketPort = 18080;
const adapterHost = process.env.ADAPTER_HOST ?? "c3-adapter";
const adapterPort = 43123;
const payload = "x".repeat(245_000);

function websocketFrame(text) {
  const body = Buffer.from(text);
  const header = Buffer.alloc(10);
  header[0] = 0x81;
  header[1] = 127;
  header.writeBigUInt64BE(BigInt(body.length), 2);
  return Buffer.concat([header, body]);
}

function transition(index) {
  const initial = index === 0;
  return JSON.stringify({
    type: "Transition",
    startVersion: {
      querySet: initial ? 0 : 1,
      identity: 0,
      ts: initial ? "AAAAAAAAAAA=" : `stress-${index - 1}`,
    },
    endVersion: { querySet: 1, identity: 0, ts: `stress-${index}` },
    modifications: [{
      type: "QueryUpdated",
      queryId: 0,
      value: { count: index, payload },
      logLines: [],
    }],
  });
}

const server = http.createServer((_request, response) => {
  response.writeHead(404).end();
});

server.on("upgrade", (request, socket) => {
  const key = request.headers["sec-websocket-key"];
  const accept = crypto
    .createHash("sha1")
    .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );

  // Respect transport backpressure. This keeps memory pressure in the real
  // adapter under test instead of accumulating an unbounded Node write queue.
  let index = 0;
  let reportedBackpressure = false;
  const send = () => {
    while (socket.write(websocketFrame(transition(index++)))) {
      if (index === 10_000) return;
    }
    if (!reportedBackpressure) {
      reportedBackpressure = true;
      console.log(`SERVER_BACKPRESSURE_AFTER=${index}`);
    }
    socket.once("drain", send);
  };
  setTimeout(send, 100);
});

function connectController() {
  const socket = net.connect(adapterPort, adapterHost);
  socket.on("connect", () => {
    socket.write(`${JSON.stringify({
      id: "stress-subscribe",
      op: "subscribe",
      subscriptionId: "stress",
      path: "demo:state",
      args: { room: "memory-stress" },
    })}\n`);
  });
  let reply = "";
  socket.on("data", (chunk) => {
    reply += chunk;
    if (!reply.includes("\n")) return;
    const first = JSON.parse(reply.slice(0, reply.indexOf("\n")));
    if (first.id !== "stress-subscribe" || first.type !== "ack") {
      throw new Error(`unexpected adapter reply: ${reply}`);
    }
    // Stop consuming the adapter's TCP output. Near-limit Live messages now
    // exercise its real blocked-writer memory behaviour.
    socket.pause();
    console.log("CONTROLLER_PAUSED");
  });
  socket.on("error", () => setTimeout(connectController, 50));
}

server.listen(websocketPort, "0.0.0.0", connectController);
