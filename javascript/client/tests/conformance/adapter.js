#!/usr/local/bin/node
import net from "node:net";
import readline from "node:readline";
import { pathToFileURL } from "node:url";
import { Client, ConvexError } from "../../convex.js";

const runtime = `node-${process.versions.node}`;

export function runAdapter(input, output, environment = process.env) {
  let client;
  const subscriptions = new Map();
  const write = (event) => output.write(`${JSON.stringify(event)}\n`);
  const failure = (id, error, subscriptionId) => {
    const event = subscriptionId
      ? {
          type: "subscription",
          subscriptionId,
          error: serialiseError(error),
          ...(error.logs?.length ? { logs: error.logs } : {}),
        }
      : {
          type: "error",
          ...(id ? { id } : {}),
          error: serialiseError(error),
          ...(error.logs?.length ? { logs: error.logs } : {}),
        };
    write(event);
  };
  const getClient = () => {
    if (client) return client;
    if (!environment.CONVEX_URL) throw new Error("CONVEX_URL is required");
    client = new Client(environment.CONVEX_URL, {
      authToken: environment.CONVEX_AUTH_TOKEN ?? "",
    });
    return client;
  };
  const reader = readline.createInterface({ input, crlfDelay: Infinity });
  let commandChain = Promise.resolve();
  reader.on("line", (line) => {
    commandChain = commandChain.then(async () => {
      let command;
      try {
        command = JSON.parse(line);
      } catch (error) {
        failure(undefined, error);
        return;
      }
      try {
        if (command.op === "hello") {
          if (command.protocolVersion !== 1) {
            throw new Error(
              `unsupported adapter protocol version ${command.protocolVersion}`,
            );
          }
          write({
            protocolVersion: 1,
            id: command.id,
            type: "ready",
            language: "javascript",
            implementation: `native-javascript-${runtime}`,
            runtime,
          });
        } else if (["query", "mutation", "action"].includes(command.op)) {
          const result = await getClient()[command.op](
            command.path,
            command.args ?? {},
          );
          write({
            id: command.id,
            type: "result",
            value: result.value,
            ...(result.logs.length ? { logs: result.logs } : {}),
          });
        } else if (command.op === "setAuth") {
          getClient().setAuth(command.token);
          write({ id: command.id, type: "ack" });
        } else if (command.op === "subscribe") {
          if (!command.subscriptionId) {
            throw new Error("subscriptionId is required");
          }
          await subscriptions.get(command.subscriptionId)?.close();
          const subscription = getClient().subscribe(
            command.path,
            command.args ?? {},
          );
          subscriptions.set(command.subscriptionId, subscription);
          write({ id: command.id, type: "ack" });
          void forwardSubscription(
            command.subscriptionId,
            subscription,
            write,
            failure,
          );
        } else if (command.op === "unsubscribe") {
          await subscriptions.get(command.subscriptionId)?.close();
          subscriptions.delete(command.subscriptionId);
          write({ id: command.id, type: "ack" });
        } else if (command.op === "debugDisconnect") {
          await getClient().debugDisconnectForAdapter();
          write({ id: command.id, type: "ack" });
        } else if (command.op === "close") {
          for (const subscription of subscriptions.values()) {
            await subscription.close();
          }
          subscriptions.clear();
          await client?.close();
          write({ id: command.id, type: "closed" });
          reader.close();
          if (input !== process.stdin) input.destroy();
        } else {
          throw new Error(`unknown operation ${JSON.stringify(command.op)}`);
        }
      } catch (error) {
        failure(command.id, error);
      }
    });
  });
  return commandChain;
}

export function parseListenAddress(value) {
  if (!value) throw new Error("ADAPTER_LISTEN is required");
  if (!value.includes(":")) {
    throw new Error("ADAPTER_LISTEN must use host:port");
  }
  let parsed;
  try {
    parsed = new URL(`tcp://${value}`);
  } catch {
    throw new Error("ADAPTER_LISTEN must use host:port");
  }
  const port = Number(parsed.port);
  if (
    !parsed.hostname ||
    !Number.isInteger(port) ||
    port < 0 ||
    port > 65_535
  ) {
    throw new Error("ADAPTER_LISTEN must use host:port");
  }
  return { host: parsed.hostname, port };
}

export function startTcpAdapter(listenAddress, environment = process.env) {
  const address = parseListenAddress(listenAddress);
  const server = net.createServer((socket) => {
    server.close();
    runAdapter(socket, socket, environment);
  });
  server.listen(address);
  return server;
}

async function forwardSubscription(
  subscriptionId,
  subscription,
  write,
  failure,
) {
  for await (const update of subscription) {
    if (update.error) {
      failure(undefined, update.error, subscriptionId);
    } else {
      write({
        type: "subscription",
        subscriptionId,
        value: update.value,
        ...(update.logs?.length ? { logs: update.logs } : {}),
      });
    }
  }
}

function serialiseError(error) {
  return {
    name: error instanceof ConvexError ? error.name : "Error",
    message: error.message,
    ...(error.data !== undefined ? { data: error.data } : {}),
  };
}

const isMain =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  if (process.env.ADAPTER_LISTEN) {
    startTcpAdapter(process.env.ADAPTER_LISTEN);
  } else {
    runAdapter(process.stdin, process.stdout);
  }
}
