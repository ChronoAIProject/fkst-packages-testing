const fs = require("fs");
const http = require("http");

if (!fs.existsSync("dist/build.json")) {
  process.stderr.write("fixture has not been built\n");
  process.exit(2);
}

const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  process.stderr.write("a valid port is required\n");
  process.exit(3);
}

const server = http.createServer((request, response) => {
  if (request.method === "GET" && request.url === "/health") {
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
