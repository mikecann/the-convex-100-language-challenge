import { randomUUID } from "node:crypto";
import WebSocket from "ws";

const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
const INITIAL_TIMESTAMP = "AAAAAAAAAAA=";
const MAX_PENDING_UPDATES = 16;

export class ConvexError extends Error {
  constructor(name, message, details = {}) {
    super(message);
    this.name = name;
    Object.assign(this, details);
  }
}

export class Client {
  constructor(
    deploymentUrl,
    { clientVersion = "javascript-0.1.0", authToken = "" } = {},
  ) {
    const url = new URL(deploymentUrl);
    if (
      !["http:", "https:"].includes(url.protocol) ||
      url.username ||
      url.password
    ) {
      throw new TypeError(
        "Convex deployment URL must be an absolute HTTP(S) URL",
      );
    }
    url.search = "";
    url.hash = "";
    url.pathname = url.pathname.replace(/\/$/, "");
    this.deploymentUrl = url.toString().replace(/\/$/, "");
    this.clientVersion = clientVersion;
    this.authToken = authToken;
    this.closed = false;
    this.live = null;
  }

  setAuth(token) {
    if (this.closed) throw new ConvexError("ClosedError", "client is closed");
    this.authToken = token;
  }

  query(path, args = {}) {
    return this.#call("query", path, args);
  }

  mutation(path, args = {}) {
    return this.#call("mutation", path, args);
  }

  action(path, args = {}) {
    return this.#call("action", path, args);
  }

  async #call(operation, path, args) {
    if (!path) throw new TypeError("Convex function path is required");
    if (!args || Array.isArray(args) || typeof args !== "object") {
      throw new TypeError("Convex arguments must be a named JSON object");
    }
    if (this.closed) throw new ConvexError("ClosedError", "client is closed");

    let response;
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
        `${operation} transport failed: ${cause.message}`,
        { cause },
      );
    }

    const text = await response.text();
    if (Buffer.byteLength(text) > MAX_RESPONSE_BYTES) {
      throw new ConvexError(
        "TransportError",
        `${operation} response exceeds ${MAX_RESPONSE_BYTES} bytes`,
      );
    }
    let body;
    try {
      body = JSON.parse(text);
    } catch (cause) {
      throw new ConvexError(
        "TransportError",
        `HTTP ${response.status} returned non-Convex JSON`,
        { cause },
      );
    }
    if (body.status === "success" && Object.hasOwn(body, "value")) {
      return { value: body.value, logs: body.logLines ?? [] };
    }
    if (body.status === "error") {
      throw new ConvexError(
        "FunctionError",
        body.errorMessage || "Convex function failed",
        {
          data: body.errorData,
          logs: body.logLines ?? [],
          operation,
        },
      );
    }
    throw new ConvexError(
      "ProtocolError",
      `HTTP ${response.status} response has unknown status ${JSON.stringify(body.status)}`,
    );
  }

  subscribe(path, args = {}) {
    if (this.closed) throw new ConvexError("ClosedError", "client is closed");
    this.live ??= new LiveManager(this.deploymentUrl, this.clientVersion);
    return this.live.subscribe(path, args);
  }

  async debugDisconnectForAdapter() {
    if (!this.live) {
      throw new ConvexError(
        "ProtocolError",
        "Live WebSocket has not been started",
      );
    }
    this.live.debugDisconnect();
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    await this.live?.close();
  }
}

class LiveManager {
  constructor(deploymentUrl, clientVersion) {
    const url = new URL(deploymentUrl);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    url.pathname = `${url.pathname.replace(/\/$/, "")}/api/sync`;
    this.url = url.toString();
    this.clientVersion = clientVersion;
    this.subscriptions = new Map();
    this.nextId = 0;
    this.querySetVersion = 0;
    this.remoteVersion = zeroVersion();
    this.connectionCount = 0;
    this.lastCloseReason = "InitialConnect";
    this.closed = false;
    this.socket = null;
    this.reconnectDelay = 100;
    this.connecting = false;
    this.reconnectTimer = null;
  }

  subscribe(path, args) {
    if (!path || !args || Array.isArray(args) || typeof args !== "object") {
      throw new TypeError(
        "Live query requires a path and named JSON arguments",
      );
    }
    const subscription = new Subscription(this, this.nextId++, path, args);
    this.subscriptions.set(subscription.id, subscription);
    this.#ensureConnection();
    if (this.socket?.readyState === WebSocket.OPEN) {
      this.#modify([
        {
          type: "Add",
          queryId: subscription.id,
          udfPath: path,
          args: [args],
        },
      ]);
    }
    return subscription;
  }

  unsubscribe(subscription) {
    if (!this.subscriptions.delete(subscription.id)) return;
    if (this.socket?.readyState === WebSocket.OPEN) {
      this.#modify([{ type: "Remove", queryId: subscription.id }]);
    }
  }

  debugDisconnect() {
    if (this.socket?.readyState !== WebSocket.OPEN) {
      throw new ConvexError(
        "TransportError",
        "Live WebSocket is not connected",
      );
    }
    this.socket.terminate();
  }

  async close() {
    this.closed = true;
    clearTimeout(this.reconnectTimer);
    for (const subscription of this.subscriptions.values())
      subscription.finish();
    this.subscriptions.clear();
    const socket = this.socket;
    if (!socket || socket.readyState === WebSocket.CLOSED) return;
    await new Promise((resolve) => {
      socket.once("close", resolve);
      socket.close();
    });
  }

  #ensureConnection() {
    if (
      this.closed ||
      !this.subscriptions.size ||
      this.connecting ||
      (this.socket && this.socket.readyState <= WebSocket.OPEN)
    ) {
      return;
    }
    this.connecting = true;
    this.socket = new WebSocket(this.url, {
      headers: { "Convex-Client": this.clientVersion },
    });
    this.socket.on("open", () => {
      this.connecting = false;
      this.reconnectDelay = 100;
      this.querySetVersion = 0;
      this.remoteVersion = zeroVersion();
      this.socket.send(
        JSON.stringify({
          type: "Connect",
          sessionId: randomUUID().replaceAll("-", ""),
          connectionCount: this.connectionCount,
          lastCloseReason: this.lastCloseReason,
          clientTs: 0,
        }),
      );
      const modifications = [...this.subscriptions.values()].map(
        (subscription) => ({
          type: "Add",
          queryId: subscription.id,
          udfPath: subscription.path,
          args: [subscription.args],
        }),
      );
      if (modifications.length) this.#modify(modifications);
    });
    this.socket.on("message", (data) => this.#message(data));
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
        this.reconnectTimer = setTimeout(() => this.#ensureConnection(), delay);
        this.reconnectTimer.unref();
      }
    });
  }

  #modify(modifications) {
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

  #message(data) {
    let event;
    try {
      event = JSON.parse(data.toString());
    } catch {
      this.#fail(
        new ConvexError("ProtocolError", "Live server sent invalid JSON"),
      );
      return;
    }
    if (event.type !== "Transition") {
      if (["Ping", "MutationResponse", "ActionResponse"].includes(event.type)) {
        return;
      }
      this.#fail(
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
      this.#fail(
        new ConvexError(
          "ProtocolError",
          "Live transition start version did not match local state",
        ),
      );
      return;
    }
    this.remoteVersion = event.endVersion;
    for (const change of event.modifications ?? []) {
      const subscription = this.subscriptions.get(change.queryId);
      if (!subscription) continue;
      if (change.type === "QueryUpdated") {
        subscription.push({ value: change.value, logs: change.logLines ?? [] });
      } else if (change.type === "QueryFailed") {
        subscription.push({
          error: new ConvexError(
            "FunctionError",
            change.errorMessage || "Live query failed",
            { data: change.errorData, logs: change.logLines ?? [] },
          ),
        });
      } else if (change.type !== "QueryRemoved") {
        this.#fail(
          new ConvexError(
            "ProtocolError",
            `unsupported Live modification ${change.type}`,
          ),
        );
        return;
      }
    }
  }

  #fail(error) {
    for (const subscription of this.subscriptions.values()) {
      subscription.push({ error });
    }
    this.socket?.terminate();
  }
}

class Subscription {
  constructor(manager, id, path, args) {
    this.manager = manager;
    this.id = id;
    this.path = path;
    this.args = args;
    this.queue = [];
    this.waiter = null;
    this.done = false;
  }

  [Symbol.asyncIterator]() {
    return { next: () => this.next() };
  }

  next() {
    if (this.queue.length) {
      return Promise.resolve({ value: this.queue.shift(), done: false });
    }
    if (this.done) return Promise.resolve({ done: true });
    return new Promise((resolve) => {
      this.waiter = resolve;
    });
  }

  push(update) {
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

  finish() {
    this.done = true;
    this.waiter?.({ done: true });
    this.waiter = null;
  }

  async close() {
    if (this.done) return;
    this.finish();
    this.manager.unsubscribe(this);
  }
}

function zeroVersion() {
  return { querySet: 0, identity: 0, ts: INITIAL_TIMESTAMP };
}
