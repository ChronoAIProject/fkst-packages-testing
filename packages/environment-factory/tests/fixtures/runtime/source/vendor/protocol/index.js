'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');

const packageName = 'fixture-protocol';

function inheritedListenerFd(expectedName) {
  if (process.env.FKST_LISTEN_FDS !== '1') {
    throw new Error(`${expectedName} requires exactly one inherited listener`);
  }
  if (process.env.FKST_LISTEN_FDNAMES !== expectedName) {
    throw new Error(`${expectedName} listener name is invalid`);
  }
  return 3;
}

function listenInherited(server, expectedName) {
  server.listen({ fd: inheritedListenerFd(expectedName) });
}

function requestJson(port, requestPath, options = {}) {
  return new Promise((resolve, reject) => {
    const outgoing = http.request({
      method: options.method || 'GET',
      host: '127.0.0.1',
      port,
      path: requestPath,
      timeout: options.timeout || 1500,
    }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => { body += chunk; });
      response.on('end', () => {
        let json = null;
        if (body !== '') json = JSON.parse(body);
        resolve({ status: response.statusCode, body, json });
      });
    });
    outgoing.once('timeout', () => outgoing.destroy(new Error('fixture request timeout')));
    outgoing.once('error', reject);
    outgoing.end();
  });
}

function writeEvidence(name, value) {
  const root = process.env.FKST_FIXTURE_EVIDENCE_DIR;
  if (!root) throw new Error('FKST_FIXTURE_EVIDENCE_DIR is required');
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(path.join(root, name), `${JSON.stringify(value)}\n`);
}

function installShutdown(server, evidenceName) {
  process.on('SIGTERM', () => {
    writeEvidence(evidenceName, { pid: process.pid, protocol_package: packageName });
    server.close(() => process.exit(0));
  });
}

module.exports = {
  inheritedListenerFd,
  installShutdown,
  listenInherited,
  packageName,
  requestJson,
  writeEvidence,
};
