import { spawn } from "node:child_process";
import readline from "node:readline";

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
  }

  start() {
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

    this.exitPromise = new Promise((resolve) => {
      this.child.once("exit", (code, signal) => {
        this.exited = true;
        const error = new Error(
          `adapter exited code=${code ?? "null"} signal=${signal ?? "null"}: ${this.stderr.trim()}`,
        );
        for (const pending of this.pending.values()) pending.reject(error);
        this.pending.clear();
        for (const waiters of this.subscriptionWaiters.values()) {
          for (const waiter of waiters) waiter.reject(error);
        }
        this.subscriptionWaiters.clear();
        resolve({ code, signal });
      });
    });

    return this;
  }

  #handleLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      this.#failAll(new Error(`adapter wrote non-JSON stdout: ${line}`));
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
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }

  request(command, timeoutMs = 10_000) {
    if (this.exited) return Promise.reject(new Error("adapter already exited"));
    if (!command.id) return Promise.reject(new Error("command is missing id"));
    if (this.pending.has(command.id)) {
      return Promise.reject(new Error(`duplicate request id: ${command.id}`));
    }

    this.transcript.push({ direction: "in", message: command });
    this.child.stdin.write(`${JSON.stringify(command)}\n`);

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(command.id);
        reject(new Error(`adapter request timed out: ${command.id}`));
      }, timeoutMs);
      this.pending.set(command.id, { resolve, reject, timer });
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

  async stop() {
    if (!this.exited) {
      this.child.kill("SIGTERM");
    }
    return this.exitPromise;
  }
}
