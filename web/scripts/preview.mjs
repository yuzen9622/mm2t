import http from "node:http";
import { createReadStream, existsSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../out/", import.meta.url));
if (!existsSync(path.join(root, "index.html"))) {
  console.error("Build the site first: pnpm build");
  process.exit(1);
}
const types = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".json": "application/json", ".txt": "text/plain", ".png": "image/png", ".webp": "image/webp", ".svg": "image/svg+xml", ".woff2": "font/woff2", ".mp4": "video/mp4", ".vtt": "text/vtt; charset=utf-8" };
const port = Number(process.env.PORT || 3000);
const server = http.createServer((req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, { Allow: "GET, HEAD" });
    return res.end();
  }
  let file;
  try {
    const pathname = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
    file = path.resolve(root, `.${pathname}`);
    if (!file.startsWith(root)) throw new Error("Invalid path");
    if (statSync(file).isDirectory()) file = path.join(file, "index.html");
  } catch {
    res.statusCode = 404;
    file = path.join(root, "404.html");
  }
  if (!existsSync(file)) { res.writeHead(404); return res.end("Not found"); }
  const size = statSync(file).size;
  res.setHeader("Content-Type", types[path.extname(file)] || "application/octet-stream");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Accept-Ranges", "bytes");
  let start = 0, end = size - 1;
  if (req.headers.range) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range);
    if (match && (match[1] || match[2])) {
      start = match[1] ? Number(match[1]) : Math.max(0, size - Number(match[2]));
      end = match[1] && match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
    }
    if (!match || (!match[1] && !match[2]) || start > end || start >= size) {
      res.writeHead(416, { "Content-Range": `bytes */${size}` });
      return res.end();
    }
    res.statusCode = 206;
    res.setHeader("Content-Range", `bytes ${start}-${end}/${size}`);
  }
  res.setHeader("Content-Length", end - start + 1);
  if (req.method === "HEAD") return res.end();
  const stream = createReadStream(file, { start, end });
  stream.on("error", () => res.destroy());
  res.on("close", () => stream.destroy());
  stream.pipe(res);
});
server.on("error", error => { console.error(`Preview failed: ${error.message}`); process.exit(1); });
server.listen(port, "127.0.0.1", () => console.log(`mm2t preview: http://localhost:${port}`));
