const fs = require('fs');
const http = require('http');
const path = require('path');

const port = Number(process.argv[2]);
const preparedPath = path.join(process.cwd(), '.prepared', 'build.json');
const statePath = path.join(process.cwd(), 'state', 'inventory.json');

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('inventory fixture requires a valid listener port');
}
if (!fs.existsSync(preparedPath) || !fs.existsSync(statePath)) {
  throw new Error('inventory fixture preparation is incomplete');
}

const server = http.createServer((request, response) => {
  if (request.method !== 'GET' || request.url !== '/inventory/SKU-001') {
    response.writeHead(404, { 'content-type': 'application/json' });
    response.end('{"error":"not-found"}\n');
    return;
  }

  const body = fs.readFileSync(statePath, 'utf8');
  response.writeHead(200, { 'content-type': 'application/json' });
  response.end(body);
});

function shutdown() {
  server.close(() => process.exit(0));
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
server.listen(port, '127.0.0.1');
