import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import test from "node:test";
import { parseListenAddress, runAdapter } from "./adapter.js";

test("adapter emits schema-safe ready and close events", async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  let text = "";
  output.on("data", (chunk) => {
    text += chunk.toString();
  });
  runAdapter(input, output, {});
  input.write(
    '{"protocolVersion":1,"id":"hello","op":"hello"}\n{"id":"close","op":"close"}\n',
  );
  await new Promise((resolve) => setTimeout(resolve, 20));
  const events = text
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  assert.deepEqual(events[0], {
    protocolVersion: 1,
    id: "hello",
    type: "ready",
    language: "typescript",
    implementation: events[0].implementation,
    runtime: events[0].runtime,
  });
  assert.deepEqual(events[1], { id: "close", type: "closed" });
  assert.deepEqual(parseListenAddress("127.0.0.1:3210"), {
    host: "127.0.0.1",
    port: 3210,
  });
  assert.throws(() => parseListenAddress("3210"), /host:port/);
});
