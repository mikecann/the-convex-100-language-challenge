import assert from "node:assert/strict";
import test from "node:test";
import { Client, ConvexError } from "./convex.js";

test("client validates URLs, named arguments, and close lifecycle", async () => {
  assert.throws(() => new Client("ftp://example.test"), /HTTP/);
  const client = new Client("https://example.test");
  await assert.rejects(
    client.query("demo:state", [] as unknown as Record<string, unknown>),
    /named JSON object/,
  );
  await client.close();
  await assert.rejects(
    client.query("demo:state"),
    (error: unknown) =>
      error instanceof ConvexError && error.name === "ClosedError",
  );
});
