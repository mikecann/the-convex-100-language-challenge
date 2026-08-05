import test from "node:test";
import assert from "node:assert/strict";
import { Client, ConvexError } from "./convex.js";

test("rejects non-object arguments before networking", async () => {
  const client = new Client("https://example.test");
  await assert.rejects(client.query("demo:state", []), /named JSON object/);
});
test("reports a closed client", async () => {
  const client = new Client("https://example.test"); await client.close();
  await assert.rejects(client.query("demo:state"), (error) => error instanceof ConvexError && error.name === "ClosedError");
});
