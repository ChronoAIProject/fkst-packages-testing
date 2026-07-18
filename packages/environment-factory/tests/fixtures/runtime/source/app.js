'use strict';

const http = require('http');
const protocol = require('fixture-protocol');

const middlewarePort = Number(process.argv[2]);

const server = http.createServer((request, response) => {
  if (request.url !== '/health') {
    response.statusCode = 404;
    response.end('not found\n');
    return;
  }
  protocol.requestJson(middlewarePort, '/state').then(({ status, json: state }) => {
    const ready = status === 200 && state.migrated === true && state.seeded === true
      && state.message === 'seeded-through-sql' && state.via === 'middleware'
      && state.protocol_package === protocol.packageName;
    response.statusCode = ready ? 200 : 503;
    response.setHeader('content-type', 'text/plain');
    response.end(ready ? 'ready\n' : 'blocked\n');
  }).catch(() => {
    response.statusCode = 503;
    response.end('blocked\n');
  });
});

protocol.listenInherited(server, 'application');
protocol.installShutdown(server, 'application-stopped.json');
