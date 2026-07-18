'use strict';

const http = require('http');
const protocol = require('fixture-protocol');

const databasePort = Number(process.argv[2]);

const server = http.createServer((request, response) => {
  if (request.method === 'GET' && request.url === '/ready') {
    protocol.requestJson(databasePort, '/ready').then(({ status }) => {
      response.statusCode = status === 200 ? 200 : 503;
      response.end(status === 200 ? 'ready\n' : 'blocked\n');
    }).catch(() => {
      response.statusCode = 503;
      response.end('blocked\n');
    });
    return;
  }
  if (request.method === 'GET' && request.url === '/state') {
    protocol.requestJson(databasePort, '/state').then(({ status, json }) => {
      response.statusCode = status;
      response.setHeader('content-type', 'application/json');
      response.end(`${JSON.stringify({
        ...json,
        via: 'middleware',
        protocol_package: protocol.packageName,
      })}\n`);
    }).catch(() => {
      response.statusCode = 503;
      response.end(`${JSON.stringify({ error: 'database-unavailable' })}\n`);
    });
    return;
  }
  response.statusCode = 404;
  response.end('not found\n');
});

protocol.listenInherited(server, 'middleware');
protocol.installShutdown(server, 'middleware-stopped.json');
