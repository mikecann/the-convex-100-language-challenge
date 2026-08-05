import { randomUUID } from "node:crypto";
import WebSocket from "ws";

const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
const INITIAL_TIMESTAMP = "AAAAAAAAAAA=";
const MAX_PENDING_UPDATES = 16;
export type JsonObject = Record<string, unknown>;
export type CallResult = { value: unknown; logs: string[] };
export type LiveUpdate = {
  value?: unknown;
  logs?: string[];
  error?: ConvexError;
};

export class ConvexError extends Error {
  data?: unknown;
  logs?: string[];
  operation?: string;
  constructor(
    name: string,
    message: string,
    details: Partial<ConvexError> = {},
  ) {
    super(message);
    this.name = name;
    Object.assign(this, details);
  }
}

export class Client {
  private readonly deploymentUrl: string;
  private readonly clientVersion: string;
  private authToken: string;
  private closed = false;
  private live: LiveManager | null = null;
  constructor(
    deploymentUrl: string,
    options: { clientVersion?: string; authToken?: string } = {},
  ) {
    const url = new URL(deploymentUrl);
    if (
      !["http:", "https:"].includes(url.protocol) ||
      url.username ||
      url.password
    )
      throw new TypeError(
        "Convex deployment URL must be an absolute HTTP(S) URL",
      );
    url.search = "";
    url.hash = "";
    url.pathname = url.pathname.replace(/\/$/, "");
    this.deploymentUrl = url.toString().replace(/\/$/, "");
    this.clientVersion = options.clientVersion ?? "typescript-0.1.0";
    this.authToken = options.authToken ?? "";
  }
  setAuth(token: string): void {
    if (this.closed) throw new ConvexError("ClosedError", "client is closed");
    this.authToken = token;
  }
  query(path: string, args: JsonObject = {}): Promise<CallResult> {
    return this.call("query", path, args);
  }
  mutation(path: string, args: JsonObject = {}): Promise<CallResult> {
    return this.call("mutation", path, args);
  }
  action(path: string, args: JsonObject = {}): Promise<CallResult> {
    return this.call("action", path, args);
  }
  private async call(
    operation: string,
    path: string,
    args: JsonObject,
  ): Promise<CallResult> {
    if (!path) throw new TypeError("Convex function path is required");
    if (!args || Array.isArray(args) || typeof args !== "object")
      throw new TypeError("Convex arguments must be a named JSON object");
    if (this.closed) throw new ConvexError("ClosedError", "client is closed");
    let response: Response;
    try {
      response = await fetch(`${this.deploymentUrl}/api/${operation}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          accept: "application/json",
          "Convex-Client": this.clientVersion,
          ...(this.authToken
            ? { authorization: `Bearer ${this.authToken}` }
            : {}),
        },
        body: JSON.stringify({ path, args, format: "json" }),
      });
    } catch (cause) {
      throw new ConvexError(
        "TransportError",
        `${operation} transport failed: ${String(cause)}`,
      );
    }
    const text = await response.text();
    if (Buffer.byteLength(text) > MAX_RESPONSE_BYTES)
      throw new ConvexError(
        "TransportError",
        `${operation} response exceeds ${MAX_RESPONSE_BYTES} bytes`,
      );
    let body: Record<string, unknown>;
    try {
      body = JSON.parse(text) as Record<string, unknown>;
    } catch {
      throw new ConvexError(
        "TransportError",
        `HTTP ${response.status} returned non-Convex JSON`,
      );
    }
    if (body.status === "success" && Object.hasOwn(body, "value"))
      return {
        value: body.value,
        logs: (body.logLines as string[] | undefined) ?? [],
      };
    if (body.status === "error")
      throw new ConvexError(
        "FunctionError",
        String(body.errorMessage ?? "Convex function failed"),
        {
          data: body.errorData,
          logs: (body.logLines as string[] | undefined) ?? [],
          operation,
        },
      );
    throw new ConvexError(
      "ProtocolError",
      `HTTP ${response.status} response has unknown status ${JSON.stringify(body.status)}`,
    );
  }
  subscribe(path: string, args: JsonObject = {}): Subscription {
    if (this.closed) throw new ConvexError("ClosedError", "client is closed");
    this.live ??= new LiveManager(this.deploymentUrl, this.clientVersion);
    return this.live.subscribe(path, args);
  }
  async debugDisconnectForAdapter(): Promise<void> {
    if (!this.live)
      throw new ConvexError(
        "ProtocolError",
        "Live WebSocket has not been started",
      );
    this.live.debugDisconnect();
  }
  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await this.live?.close();
  }
}

type Version = { querySet: number; identity: number; ts: string };
type Modification = {
  type: string;
  queryId: number;
  value?: unknown;
  logLines?: string[];
  errorMessage?: string;
  errorData?: unknown;
};
class LiveManager {
  private readonly url: string;
  private readonly clientVersion: string;
  private subscriptions = new Map<number, Subscription>();
  private nextId = 0;
  private querySetVersion = 0;
  private remoteVersion: Version = zeroVersion();
  private connectionCount = 0;
  private lastCloseReason = "InitialConnect";
  private closed = false;
  private socket: WebSocket | null = null;
  private reconnectDelay = 100;
  private connecting = false;
  private reconnectTimer: NodeJS.Timeout | null = null;
  constructor(deploymentUrl: string, clientVersion: string) {
    const url = new URL(deploymentUrl);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    url.pathname = `${url.pathname.replace(/\/$/, "")}/api/sync`;
    this.url = url.toString();
    this.clientVersion = clientVersion;
  }
  subscribe(path: string, args: JsonObject): Subscription {
    if (!path || !args || Array.isArray(args) || typeof args !== "object")
      throw new TypeError(
        "Live query requires a path and named JSON arguments",
      );
    const subscription = new Subscription(this, this.nextId++, path, args);
    this.subscriptions.set(subscription.id, subscription);
    this.ensureConnection();
    if (this.socket?.readyState === WebSocket.OPEN)
      this.modify([
        { type: "Add", queryId: subscription.id, udfPath: path, args: [args] },
      ]);
    return subscription;
  }
  unsubscribe(subscription: Subscription): void {
    if (!this.subscriptions.delete(subscription.id)) return;
    if (this.socket?.readyState === WebSocket.OPEN)
      this.modify([{ type: "Remove", queryId: subscription.id }]);
  }
  debugDisconnect(): void {
    if (this.socket?.readyState !== WebSocket.OPEN)
      throw new ConvexError(
        "TransportError",
        "Live WebSocket is not connected",
      );
    this.socket.terminate();
  }
  async close(): Promise<void> {
    this.closed = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    for (const subscription of this.subscriptions.values())
      subscription.finish();
    this.subscriptions.clear();
    const socket = this.socket;
    if (!socket || socket.readyState === WebSocket.CLOSED) return;
    await new Promise<void>((resolve) => {
      socket.once("close", () => resolve());
      socket.close();
    });
  }
  private ensureConnection(): void {
    if (
      this.closed ||
      !this.subscriptions.size ||
      this.connecting ||
      (this.socket && this.socket.readyState <= WebSocket.OPEN)
    )
      return;
    this.connecting = true;
    this.socket = new WebSocket(this.url, {
      headers: { "Convex-Client": this.clientVersion },
    });
    this.socket.on("open", () => {
      this.connecting = false;
      this.reconnectDelay = 100;
      this.querySetVersion = 0;
      this.remoteVersion = zeroVersion();
      this.socket?.send(
        JSON.stringify({
          type: "Connect",
          sessionId: randomUUID().replaceAll("-", ""),
          connectionCount: this.connectionCount,
          lastCloseReason: this.lastCloseReason,
          clientTs: 0,
        }),
      );
      const modifications = [...this.subscriptions.values()].map((s) => ({
        type: "Add",
        queryId: s.id,
        udfPath: s.path,
        args: [s.args],
      }));
      if (modifications.length) this.modify(modifications);
    });
    this.socket.on("message", (data) => this.message(data.toString()));
    this.socket.on("error", (error) => {
      this.lastCloseReason = error.message;
    });
    this.socket.on("close", () => {
      this.connecting = false;
      this.connectionCount++;
      this.socket = null;
      if (!this.closed && this.subscriptions.size) {
        const delay = this.reconnectDelay;
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, 15_000);
        this.reconnectTimer = setTimeout(() => this.ensureConnection(), delay);
        this.reconnectTimer.unref();
      }
    });
  }
  private modify(modifications: unknown[]): void {
    if (this.socket?.readyState !== WebSocket.OPEN) return;
    this.socket.send(
      JSON.stringify({
        type: "ModifyQuerySet",
        baseVersion: this.querySetVersion,
        newVersion: this.querySetVersion + 1,
        modifications,
      }),
    );
    this.querySetVersion++;
  }
  private message(raw: string): void {
    let event: {
      type?: string;
      startVersion?: Version;
      endVersion?: Version;
      modifications?: Modification[];
    };
    try {
      event = JSON.parse(raw);
    } catch {
      this.fail(
        new ConvexError("ProtocolError", "Live server sent invalid JSON"),
      );
      return;
    }
    if (event.type !== "Transition") {
      if (
        ["Ping", "MutationResponse", "ActionResponse"].includes(
          event.type ?? "",
        )
      )
        return;
      this.fail(
        new ConvexError(
          "ProtocolError",
          `unsupported Live server message ${event.type}`,
        ),
      );
      return;
    }
    if (
      JSON.stringify(event.startVersion) !== JSON.stringify(this.remoteVersion)
    ) {
      this.fail(
        new ConvexError(
          "ProtocolError",
          "Live transition start version did not match local state",
        ),
      );
      return;
    }
    this.remoteVersion = event.endVersion!;
    for (const change of event.modifications ?? []) {
      const subscription = this.subscriptions.get(change.queryId);
      if (!subscription) continue;
      if (change.type === "QueryUpdated")
        subscription.push({ value: change.value, logs: change.logLines ?? [] });
      else if (change.type === "QueryFailed")
        subscription.push({
          error: new ConvexError(
            "FunctionError",
            change.errorMessage ?? "Live query failed",
            { data: change.errorData, logs: change.logLines ?? [] },
          ),
        });
      else if (change.type !== "QueryRemoved") {
        this.fail(
          new ConvexError(
            "ProtocolError",
            `unsupported Live modification ${change.type}`,
          ),
        );
        return;
      }
    }
  }
  private fail(error: ConvexError): void {
    for (const subscription of this.subscriptions.values())
      subscription.push({ error });
    this.socket?.terminate();
  }
}
export class Subscription implements AsyncIterable<LiveUpdate> {
  private queue: LiveUpdate[] = [];
  private waiter: ((result: IteratorResult<LiveUpdate>) => void) | null = null;
  private done = false;
  constructor(
    private manager: LiveManager,
    readonly id: number,
    readonly path: string,
    readonly args: JsonObject,
  ) {}
  [Symbol.asyncIterator](): AsyncIterator<LiveUpdate> {
    return { next: () => this.next() };
  }
  next(): Promise<IteratorResult<LiveUpdate>> {
    if (this.queue.length)
      return Promise.resolve({ value: this.queue.shift()!, done: false });
    if (this.done) return Promise.resolve({ value: undefined, done: true });
    return new Promise((resolve) => {
      this.waiter = resolve;
    });
  }
  push(update: LiveUpdate): void {
    if (this.done) return;
    if (this.waiter) {
      const resolve = this.waiter;
      this.waiter = null;
      resolve({ value: update, done: false });
      return;
    }
    if (this.queue.length === MAX_PENDING_UPDATES) this.queue.shift();
    this.queue.push(update);
  }
  finish(): void {
    this.done = true;
    this.waiter?.({ value: undefined, done: true });
    this.waiter = null;
  }
  async close(): Promise<void> {
    if (this.done) return;
    this.finish();
    this.manager.unsubscribe(this);
  }
}
function zeroVersion(): Version {
  return { querySet: 0, identity: 0, ts: INITIAL_TIMESTAMP };
}
