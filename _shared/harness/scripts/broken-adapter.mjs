import readline from "node:readline";

const mode = process.argv[2];
const lines = readline.createInterface({ input: process.stdin });

lines.on("line", (line) => {
  const command = JSON.parse(line);
  if (command.op === "hello") {
    process.stdout.write(
      `${JSON.stringify({ protocolVersion: 1, id: command.id, type: "ready" })}\n`,
    );
    return;
  }

  if (mode === "wrong") {
    process.stdout.write(
      `${JSON.stringify({ id: command.id, type: "result", value: "wrong" })}\n`,
    );
  } else if (mode === "dirty-exit") {
    process.exit(17);
  } else if (mode === "exit-hang" && command.op === "close") {
    process.stdout.write(`${JSON.stringify({ id: command.id, type: "closed" })}\n`);
  }
  // The hang modes deliberately remain alive after their relevant response.
});
