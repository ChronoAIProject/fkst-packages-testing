'use strict';

const http = require('node:http');
const net = require('node:net');
const {
  connectionOwnedByProcessGroup,
  processGroupState,
} = require('./platform');

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function remaining(deadline) {
  return Math.max(0, deadline - Date.now());
}

async function connect(effect, deadline) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({
      host: '127.0.0.1',
      family: 4,
      port: effect.port,
    });
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error('owned loopback HTTP connection timed out'));
    }, Math.max(1, remaining(deadline)));
    socket.once('connect', () => {
      clearTimeout(timer);
      socket.pause();
      resolve(socket);
    });
    socket.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

async function verifyConnection(socket, resource, deadline) {
  const visibilityDeadline = Math.min(deadline, Date.now() + 1_000);
  while (true) {
    const ownership = connectionOwnedByProcessGroup(socket, resource.pgid);
    if (!ownership.supported) {
      throw new Error(`owned loopback HTTP connection inspection failed: ${ownership.reason}`);
    }
    if (ownership.owned) return ownership;
    if (ownership.reason !== 'connection-not-visible' || Date.now() >= visibilityDeadline) {
      throw new Error(`owned loopback HTTP connection is not owned: ${ownership.reason}`);
    }
    await delay(Math.min(25, Math.max(1, remaining(visibilityDeadline))));
  }
}

async function requestOnSocket(socket, effect, outputBytes, deadline) {
  return new Promise((resolve, reject) => {
    const agent = new http.Agent({ keepAlive: false, maxSockets: 1 });
    let settled = false;
    agent.createConnection = () => socket;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) {
        socket.destroy();
        agent.destroy();
        reject(error);
        return;
      }
      agent.destroy();
      resolve(value);
    };
    const timer = setTimeout(() => {
      finish(new Error('owned loopback HTTP request timed out'));
    }, Math.max(1, remaining(deadline)));
    const request = http.request({
      protocol: 'http:',
      hostname: '127.0.0.1',
      family: 4,
      port: effect.port,
      method: effect.method,
      path: effect.path,
      headers: {},
      agent,
    }, (response) => {
      if (response.statusCode >= 300 && response.statusCode < 400) {
        response.resume();
        finish(new Error('owned loopback HTTP redirect response is forbidden'));
        return;
      }
      const chunks = [];
      let bytes = 0;
      response.on('data', (chunk) => {
        const value = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        bytes += value.length;
        if (bytes > outputBytes) {
          request.destroy(new Error('owned loopback HTTP response exceeded output bound'));
          return;
        }
        chunks.push(value);
      });
      response.once('end', () => finish(null, {
        status: Number(response.statusCode) || 0,
        body: Buffer.concat(chunks, bytes).toString('utf8'),
        headers: {},
      }));
      response.once('error', finish);
    });
    request.once('error', finish);
    socket.resume();
    request.end();
  });
}

async function ownedLoopbackHttpRequest(options) {
  const resource = options && options.resource;
  const effect = options && options.effect;
  const outputBytes = Number(options && options.outputBytes);
  const timeoutSeconds = Number(effect && effect.timeout_seconds);
  if (!resource || !Number.isInteger(resource.pid) || resource.pid < 1
    || !Number.isInteger(resource.pgid) || resource.pgid < 1
    || !effect || effect.host !== '127.0.0.1'
    || !Number.isInteger(effect.port) || effect.port < 1 || effect.port > 65535
    || !Number.isInteger(timeoutSeconds) || timeoutSeconds < 1
    || !Number.isInteger(outputBytes) || outputBytes < 1) {
    throw new Error('owned loopback HTTP request binding is malformed');
  }
  const deadline = Date.now() + timeoutSeconds * 1000;
  const socket = await connect(effect, deadline);
  try {
    await verifyConnection(socket, resource, deadline);
    const state = processGroupState(resource);
    if (!state.supported || !state.alive || state.foreign) {
      throw new Error('owned loopback HTTP process ownership changed');
    }
    if (typeof options.verifyOwner === 'function') await options.verifyOwner();
    if (remaining(deadline) <= 0) throw new Error('owned loopback HTTP request timed out');
    return await requestOnSocket(socket, effect, outputBytes, deadline);
  } catch (error) {
    socket.destroy();
    throw error;
  }
}

module.exports = { ownedLoopbackHttpRequest };
