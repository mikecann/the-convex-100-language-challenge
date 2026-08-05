import net from "node:net";
import readline from "node:readline";
import { pathToFileURL } from "node:url";
import { Client, ConvexError, Subscription } from "../../convex.js";

const runtime = `node-${process.versions.node}`;
type Command = {
  id?: string;
  op: string;
  protocolVersion?: number;
  path?: string;
  args?: Record<string, unknown>;
  token?: string;
  subscriptionId?: string;
};

export function runAdapter(
  input: NodeJS.ReadableStream,
  output: NodeJS.WritableStream,
  environment: NodeJS.ProcessEnv = process.env,
): void {
  let client: Client | undefined;
  const subscriptions = new Map<string, Subscription>();
  const write = (event: object) => output.write(`${JSON.stringify(event)}\n`);
  const failure = (
    id: string | undefined,
    error: unknown,
    subscriptionId?: string,
  ) => {
    const convex =
      error instanceof ConvexError ? error : new Error(String(error));
    const serialised = {
      name: convex instanceof ConvexError ? convex.name : "Error",
      message: convex.message,
      ...(convex instanceof ConvexError && convex.data !== undefined
        ? { data: convex.data }
        : {}),
    };
    write(
      subscriptionId
        ? {
            type: "subscription",
            subscriptionId,
            error: serialised,
            ...(convex instanceof ConvexError && convex.logs?.length
              ? { logs: convex.logs }
              : {}),
          }
        : {
            type: "error",
            ...(id ? { id } : {}),
            error: serialised,
            ...(convex instanceof ConvexError && convex.logs?.length
              ? { logs: convex.logs }
              : {}),
          },
    );
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
      let command: Command;
      try {
        command = JSON.parse(line) as Command;
      } catch (error) {
        failure(undefined, error);
        return;
      }
      try {
        if (command.op === "hello") {
          if (command.protocolVersion !== 1)
            throw new Error(
              `unsupported adapter protocol version ${command.protocolVersion}`,
            );
          write({
            protocolVersion: 1,
            id: command.id,
            type: "ready",
            language: "typescript",
            implementation: `native-typescript-${runtime}`,
            runtime,
          });
        } else if (["query", "mutation", "action"].includes(command.op)) {
          const result = await getClient()[
            command.op as "query" | "mutation" | "action"
          ](command.path!, command.args ?? {});
          write({
            id: command.id,
            type: "result",
            value: result.value,
            ...(result.logs.length ? { logs: result.logs } : {}),
          });
        } else if (command.op === "setAuth") {
          getClient().setAuth(command.token!);
          write({ id: command.id, type: "ack" });
        } else if (command.op === "subscribe") {
          if (!command.subscriptionId)
            throw new Error("subscriptionId is required");
          await subscriptions.get(command.subscriptionId)?.close();
          const subscription = getClient().subscribe(
            command.path!,
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
          await subscriptions.get(command.subscriptionId!)?.close();
          subscriptions.delete(command.subscriptionId!);
          write({ id: command.id, type: "ack" });
        } else if (command.op === "debugDisconnect") {
          await getClient().debugDisconnectForAdapter();
          write({ id: command.id, type: "ack" });
        } else if (command.op === "close") {
          for (const subscription of subscriptions.values())
            await subscription.close();
          subscriptions.clear();
          await client?.close();
          write({ id: command.id, type: "closed" });
          reader.close();
          if (input !== process.stdin) (input as NodeJS.ReadStream).destroy();
        } else
          throw new Error(`unknown operation ${JSON.stringify(command.op)}`);
      } catch (error) {
        failure(command.id, error);
      }
    });
  });
}
async function forwardSubscription(
  subscriptionId: string,
  subscription: Subscription,
  write: (event: object) => boolean,
  failure: (
    id: string | undefined,
    error: unknown,
    subscriptionId?: string,
  ) => void,
): Promise<void> {
  for await (const update of subscription) {
    if (update.error) failure(undefined, update.error, subscriptionId);
    else
      write({
        type: "subscription",
        subscriptionId,
        value: update.value,
        ...(update.logs?.length ? { logs: update.logs } : {}),
      });
  }
}
export function parseListenAddress(value: string | undefined): {
  host: string;
  port: number;
} {
  if (!value || !value.includes(":"))
    throw new Error("ADAPTER_LISTEN must use host:port");
  let parsed: URL;
  try {
    parsed = new URL(`tcp://${value}`);
  } catch {
    throw new Error("ADAPTER_LISTEN must use host:port");
  }
  const port = Number(parsed.port);
  if (!parsed.hostname || !Number.isInteger(port) || port < 0 || port > 65535)
    throw new Error("ADAPTER_LISTEN must use host:port");
  return { host: parsed.hostname, port };
}
export function startTcpAdapter(
  listenAddress: string,
  environment: NodeJS.ProcessEnv = process.env,
): net.Server {
  const address = parseListenAddress(listenAddress);
  const server = net.createServer((socket) => {
    server.close();
    runAdapter(socket, socket, environment);
  });
  server.listen(address);
  return server;
}
const isMain =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  if (process.env.ADAPTER_LISTEN) startTcpAdapter(process.env.ADAPTER_LISTEN);
  else runAdapter(process.stdin, process.stdout);
}
