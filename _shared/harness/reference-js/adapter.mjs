import readline from "node:readline";
import { ConvexClient, ConvexHttpClient } from "convex/browser";
import { makeFunctionReference } from "convex/server";

const deploymentUrl = process.env.CONVEX_URL;
if (!deploymentUrl) throw new Error("CONVEX_URL is required");

let trackedSocket = null;
const NativeWebSocket = globalThis.WebSocket;
class TrackedWebSocket extends NativeWebSocket {
  constructor(...args) {
    super(...args);
    trackedSocket = this;
  }
}

const http = new ConvexHttpClient(deploymentUrl, { logger: false });
const live = new ConvexClient(deploymentUrl, {
  logger: false,
  webSocketConstructor: TrackedWebSocket,
});
const subscriptions = new Map();

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function serializeError(error) {
  return {
    name: error?.name ?? "Error",
    message: error?.message ?? String(error),
    data: error?.data ?? null,
  };
}

async function handle(command) {
  try {
    if (command.op === "hello") {
      if (command.protocolVersion !== 1) {
        throw new Error(`unsupported protocol version: ${command.protocolVersion}`);
      }
      send({
        protocolVersion: 1,
        id: command.id,
        type: "ready",
        language: "javascript",
        implementation: "official-convex-js-1.43.0",
      });
      return;
    }

    if (["query", "mutation", "action"].includes(command.op)) {
      const reference = makeFunctionReference(command.path);
      const value = await http[command.op](reference, command.args);
      send({ id: command.id, type: "result", value, logs: [] });
      return;
    }

    if (command.op === "subscribe") {
      const reference = makeFunctionReference(command.path);
      const unsubscribe = live.onUpdate(
        reference,
        command.args,
        (value) => {
          send({
            type: "subscription",
            subscriptionId: command.subscriptionId,
            value,
            logs: [],
          });
        },
        (error) => {
          send({
            type: "subscription",
            subscriptionId: command.subscriptionId,
            error: serializeError(error),
          });
        },
      );
      subscriptions.set(command.subscriptionId, unsubscribe);
      send({ id: command.id, type: "ack" });
      return;
    }

    if (command.op === "unsubscribe") {
      subscriptions.get(command.subscriptionId)?.();
      subscriptions.delete(command.subscriptionId);
      send({ id: command.id, type: "ack" });
      return;
    }

    if (command.op === "debugDisconnect") {
      if (!trackedSocket) throw new Error("no active WebSocket to disconnect");
      trackedSocket.close(4000, "conformance disconnect");
      send({ id: command.id, type: "ack" });
      return;
    }

    if (command.op === "close") {
      for (const unsubscribe of subscriptions.values()) unsubscribe();
      subscriptions.clear();
      await live.close();
      send({ id: command.id, type: "closed" });
      process.exit(0);
    }

    throw new Error(`unknown operation: ${command.op}`);
  } catch (error) {
    send({ id: command.id, type: "error", error: serializeError(error) });
  }
}

const lines = readline.createInterface({ input: process.stdin });
lines.on("line", (line) => {
  let command;
  try {
    command = JSON.parse(line);
  } catch (error) {
    send({ type: "error", error: serializeError(error) });
    return;
  }
  void handle(command);
});
