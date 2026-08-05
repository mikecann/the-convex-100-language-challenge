import fs from "node:fs";
import http from "node:http";
import path from "node:path";

const root = path.resolve(process.env.SITE_ROOT ?? "/site");
const port = Number(process.env.PORT ?? 4173);
const contentTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
};

const server = http.createServer((request, response) => {
  const requestPath = new URL(request.url ?? "/", "http://localhost").pathname;
  const relativePath = requestPath === "/" ? "index.html" : requestPath.slice(1);
  const filePath = path.resolve(root, relativePath);

  if (!filePath.startsWith(`${root}${path.sep}`) || !fs.existsSync(filePath)) {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("Not found\n");
    return;
  }

  response.writeHead(200, {
    "Cache-Control": "no-store",
    "Content-Type": contentTypes[path.extname(filePath)] ?? "application/octet-stream",
  });
  fs.createReadStream(filePath).pipe(response);
});

server.listen(port, "0.0.0.0", () => {
  console.log(`Evidence site listening on port ${port}`);
});
