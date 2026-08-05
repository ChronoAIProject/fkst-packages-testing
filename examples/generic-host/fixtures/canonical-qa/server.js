const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const path = require("path");

if (!fs.existsSync("dist/build.json")) {
  process.stderr.write("fixture has not been built\n");
  process.exit(2);
}

const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  process.stderr.write("a valid port is required\n");
  process.exit(3);
}

let counterPath = null;
let redirectHealth = false;
for (let index = 3; index < process.argv.length; index += 1) {
  const argument = process.argv[index];
  if (argument === "--count-effect") {
    counterPath = process.argv[index + 1];
    if (!counterPath) {
      process.stderr.write("HTTP effect counter path is required\n");
      process.exit(4);
    }
    index += 1;
  } else if (argument === "--redirect-health") {
    redirectHealth = true;
  } else {
    process.stderr.write(`unknown argument: ${argument}\n`);
    process.exit(4);
  }
}

function recordHttpEffect(request) {
  if (!counterPath) return;
  fs.mkdirSync(counterPath, { recursive: true });
  const recordPath = path.join(counterPath,
    `invocation-${process.pid}-${crypto.randomBytes(8).toString("hex")}.json`);
  fs.writeFileSync(recordPath, `${JSON.stringify({
    pid: process.pid, method: request.method, url: request.url,
  })}\n`, { flag: "wx" });
}

const server = http.createServer((request, response) => {
  if (request.method === "GET" && request.url === "/ready") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ status: "ready", fixture: "canonical-qa" }));
    return;
  }
  recordHttpEffect(request);
  if (request.method === "GET" && request.url === "/health") {
    if (redirectHealth) {
      response.writeHead(302, { location: "/redirected" });
      response.end();
      return;
    }
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ status: "healthy", fixture: "canonical-qa" }));
    return;
  }
  response.writeHead(404, { "content-type": "text/plain" });
  response.end("not found");
});

if (process.env.FKST_LISTEN_FDS === "1" && process.env.FKST_LISTEN_FDNAMES === "application") {
  server.listen({ fd: 3 });
} else {
  server.listen(port, "127.0.0.1");
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
