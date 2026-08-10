import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import readline from "node:readline";
import Ajv2020 from "ajv/dist/2020.js";

const adapterSchema = JSON.parse(fs.readFileSync("/schemas/adapter.schema.json", "utf8"));
const validateAdapterMessage = new Ajv2020({ allErrors: true }).compile(adapterSchema);

export class AdapterProcess {
  constructor(command, args = [], options = {}) {
    this.command = command;
    this.args = args;
    this.options = options;
    this.pending = new Map();
    this.subscriptionQueues = new Map();
    this.subscriptionWaiters = new Map();
    this.stderr = "";
    this.transcript = [];
    this.exited = false;
    this.fatalError = null;
  }

  start() {
    if (this.options.tcp) return this.#startTCP();

    this.child = spawn(this.command, this.args, {
      env: { ...process.env, ...this.options.env },
      stdio: ["pipe", "pipe", "pipe"],
    });

    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk) => {
      this.stderr += chunk;
    });

    const lines = readline.createInterface({ input: this.child.stdout });
    lines.on("line", (line) => this.#handleLine(line));

    this.input = this.child.stdin;
    this.transportReady = Promise.resolve();

    this.exitPromise = new Promise((resolve) => {
      this.child.once("exit", (code, signal) => {
        const error = new Error(
          `adapter exited code=${code ?? "null"} signal=${signal ?? "null"}: ${this.stderr.trim()}`,
        );
        this.#markExited(error);
        resolve({ code, signal });
      });
    });

    return this;
  }

  #startTCP() {
    const separator = this.options.tcp.lastIndexOf(":");
    if (separator < 1) throw new Error(`invalid adapter TCP address: ${this.options.tcp}`);
    const host = this.options.tcp.slice(0, separator);
    const port = Number(this.options.tcp.slice(separator + 1));

    let resolveExit;
    this.exitPromise = new Promise((resolve) => {
      resolveExit = resolve;
    });
    this.transportReady = this.#connectWithRetry(host, port).then((socket) => {
      this.socket = socket;
      this.input = socket;
      const lines = readline.createInterface({ input: socket });
      lines.on("line", (line) => this.#handleLine(line));
      socket.once("close", (hadError) => {
        const error = new Error(
          hadError ? "adapter TCP connection failed" : "adapter TCP connection closed",
        );
        this.#markExited(error);
        resolveExit({ code: hadError ? 1 : 0, signal: null });
      });
      socket.once("error", (error) => this.#failAll(error));
    }).catch((error) => {
      this.#markExited(error);
      resolveExit({ code: 1, signal: null });
      throw error;
    });
    return this;
  }

  async #connectWithRetry(host, port) {
    let lastError;
    for (let attempt = 0; attempt < 50; attempt += 1) {
      try {
        return await new Promise((resolve, reject) => {
          const socket = net.createConnection({ host, port });
          socket.once("connect", () => resolve(socket));
          socket.once("error", reject);
        });
      } catch (error) {
        lastError = error;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    }
    throw new Error(`could not connect to adapter at ${host}:${port}: ${lastError}`);
  }

  #markExited(error) {
    if (this.exited) return;
    this.exited = true;
    this.#failAll(error);
    for (const waiters of this.subscriptionWaiters.values()) {
      for (const waiter of waiters) waiter.reject(error);
    }
    this.subscriptionWaiters.clear();
  }

  #handleLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      this.#failAll(new Error(`adapter wrote non-JSON stdout: ${line}`));
      return;
    }
    if (!validateAdapterMessage(message)) {
      this.#failAll(new Error(
        `adapter wrote an invalid protocol message: ${JSON.stringify(validateAdapterMessage.errors)}`,
      ));
      return;
    }

    this.transcript.push({ direction: "out", message });

    if (message.type === "subscription") {
      const id = message.subscriptionId;
      const waiters = this.subscriptionWaiters.get(id) ?? [];
      if (waiters.length > 0) {
        const waiter = waiters.shift();
        clearTimeout(waiter.timer);
        waiter.resolve(message);
        this.subscriptionWaiters.set(id, waiters);
      } else {
        const queue = this.subscriptionQueues.get(id) ?? [];
        queue.push(message);
        this.subscriptionQueues.set(id, queue);
      }
      return;
    }

    if (message.id && this.pending.has(message.id)) {
      const pending = this.pending.get(message.id);
      clearTimeout(pending.timer);
      this.pending.delete(message.id);
      pending.resolve(message);
    }
  }

  #failAll(error) {
    this.fatalError ??= error;
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }

  async request(command, timeoutMs = 10_000) {
    if (this.fatalError) return Promise.reject(this.fatalError);
    if (this.exited) return Promise.reject(new Error("adapter already exited"));
    if (!command.id) return Promise.reject(new Error("command is missing id"));
    if (this.pending.has(command.id)) {
      return Promise.reject(new Error(`duplicate request id: ${command.id}`));
    }

    const recordedCommand = command.op === "setAuth"
      ? { ...command, token: "[redacted]" }
      : command;
    this.transcript.push({ direction: "in", message: recordedCommand });
    await this.transportReady;

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(command.id);
        reject(new Error(`adapter request timed out: ${command.id}`));
      }, timeoutMs);
      this.pending.set(command.id, { resolve, reject, timer });
      this.input.write(`${JSON.stringify(command)}\n`);
    });
  }

  nextSubscription(subscriptionId, timeoutMs = 10_000) {
    const queue = this.subscriptionQueues.get(subscriptionId) ?? [];
    if (queue.length > 0) return Promise.resolve(queue.shift());

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const waiters = this.subscriptionWaiters.get(subscriptionId) ?? [];
        this.subscriptionWaiters.set(
          subscriptionId,
          waiters.filter((waiter) => waiter.reject !== reject),
        );
        reject(new Error(`subscription timed out: ${subscriptionId}`));
      }, timeoutMs);
      const waiters = this.subscriptionWaiters.get(subscriptionId) ?? [];
      waiters.push({ resolve, reject, timer });
      this.subscriptionWaiters.set(subscriptionId, waiters);
    });
  }

  async expectNoSubscription(subscriptionId, timeoutMs = 750) {
    try {
      await this.nextSubscription(subscriptionId, timeoutMs);
    } catch (error) {
      if (error.message.startsWith("subscription timed out:")) return;
      throw error;
    }
    throw new Error(`unexpected subscription event: ${subscriptionId}`);
  }

  async waitForExit(timeoutMs = 10_000) {
    let timer;
    try {
      return await Promise.race([
        this.exitPromise,
        new Promise((_, reject) => {
          timer = setTimeout(() => {
            reject(new Error(`adapter exit timed out after ${timeoutMs}ms`));
          }, timeoutMs);
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  }

  async stop() {
    if (!this.exited && this.socket) {
      this.socket.destroy();
    } else if (!this.exited) {
      this.child.kill("SIGTERM");
    }
    return this.exitPromise;
  }
}
