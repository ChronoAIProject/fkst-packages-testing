'use strict';

const crypto = require('crypto');
const http = require('http');
const net = require('net');

function localHost(value) {
  const host = String(value || '').toLowerCase();
  return host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || host === '::1';
}

function assertLocalHttpUrl(value, label) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch (_err) {
    throw new Error(`${label} must be a valid URL`);
  }
  if (parsed.protocol !== 'http:'
    || !localHost(parsed.hostname)
    || parsed.username !== ''
    || parsed.password !== ''
    || parsed.port === '0') {
    throw new Error(`${label} must be local http without credentials`);
  }
  return parsed;
}

function assertLocalWsUrl(value, label) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch (_err) {
    throw new Error(`${label} must be a valid URL`);
  }
  if (parsed.protocol !== 'ws:'
    || !localHost(parsed.hostname)
    || parsed.username !== ''
    || parsed.password !== ''
    || parsed.hash !== ''
    || parsed.port === '0') {
    throw new Error(`${label} must be local ws without credentials or fragments`);
  }
  return parsed;
}

function httpJson(url, method = 'GET') {
  const parsed = new URL(url);
  return new Promise((resolve, reject) => {
    const request = http.request({
      hostname: parsed.hostname,
      port: parsed.port || 80,
      path: `${parsed.pathname}${parsed.search}`,
      method,
      timeout: 5000,
    }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => { body += chunk; });
      response.on('end', () => {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          reject(new Error(`CDP HTTP ${method} request returned ${response.statusCode}`));
          return;
        }
        try {
          resolve(JSON.parse(body));
        } catch (error) {
          reject(error);
        }
      });
    });
    request.on('error', () => reject(new Error('CDP HTTP request failed')));
    request.on('timeout', () => request.destroy());
    request.end();
  });
}

function websocketFrame(payload) {
  const data = Buffer.from(payload);
  let header;
  if (data.length < 126) {
    header = Buffer.alloc(6);
    header[0] = 0x81;
    header[1] = 0x80 | data.length;
    crypto.randomBytes(4).copy(header, 2);
  } else if (data.length < 65536) {
    header = Buffer.alloc(8);
    header[0] = 0x81;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(data.length, 2);
    crypto.randomBytes(4).copy(header, 4);
  } else {
    throw new Error('websocket payload too large');
  }
  const mask = header.subarray(header.length - 4);
  const masked = Buffer.alloc(data.length);
  for (let index = 0; index < data.length; index += 1) masked[index] = data[index] ^ mask[index % 4];
  return Buffer.concat([header, masked]);
}

class CdpSocket {
  constructor(wsUrl) {
    this.wsUrl = assertLocalWsUrl(wsUrl, 'CDP websocket URL');
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
  }

  async connect() {
    const key = crypto.randomBytes(16).toString('base64');
    const port = Number(this.wsUrl.port || 80);
    this.socket = net.createConnection({ host: this.wsUrl.hostname, port });
    await new Promise((resolve, reject) => {
      const onError = (error) => reject(error);
      this.socket.once('error', onError);
      this.socket.once('connect', () => {
        this.socket.write([
          `GET ${this.wsUrl.pathname}${this.wsUrl.search} HTTP/1.1`,
          `Host: ${this.wsUrl.host}`,
          'Upgrade: websocket',
          'Connection: Upgrade',
          `Sec-WebSocket-Key: ${key}`,
          'Sec-WebSocket-Version: 13',
          '',
          '',
        ].join('\r\n'));
      });
      let response = Buffer.alloc(0);
      const onData = (chunk) => {
        response = Buffer.concat([response, chunk]);
        const marker = response.indexOf('\r\n\r\n');
        if (marker === -1) return;
        const header = response.subarray(0, marker).toString('utf8');
        if (!header.startsWith('HTTP/1.1 101') && !header.startsWith('HTTP/1.0 101')) {
          reject(new Error(`websocket handshake failed: ${header.split('\r\n')[0]}`));
          return;
        }
        this.socket.off('data', onData);
        this.socket.off('error', onError);
        const rest = response.subarray(marker + 4);
        if (rest.length > 0) this.handleData(rest);
        this.socket.on('data', (data) => this.handleData(data));
        this.socket.on('error', (error) => this.rejectAll(error));
        this.socket.on('close', () => this.rejectAll(new Error('websocket closed')));
        resolve();
      };
      this.socket.on('data', onData);
    });
  }

  close() {
    if (this.socket) this.socket.end();
  }

  rejectAll(error) {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }

  send(method, params = {}) {
    const id = this.nextId++;
    this.socket.write(websocketFrame(JSON.stringify({ id, method, params })));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP command timed out: ${method}`));
      }, 10000);
      this.pending.set(id, { resolve, reject, timer });
    });
  }

  takeEvents() {
    const events = this.events;
    this.events = [];
    return events;
  }

  handleData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 2) {
      const first = this.buffer[0];
      const second = this.buffer[1];
      const opcode = first & 0x0f;
      let length = second & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        throw new Error('large websocket frames are not supported');
      }
      const masked = (second & 0x80) !== 0;
      const maskLength = masked ? 4 : 0;
      if (this.buffer.length < offset + maskLength + length) return;
      let payload = this.buffer.subarray(offset + maskLength, offset + maskLength + length);
      if (masked) {
        const mask = this.buffer.subarray(offset, offset + 4);
        const unmasked = Buffer.alloc(payload.length);
        for (let index = 0; index < payload.length; index += 1) unmasked[index] = payload[index] ^ mask[index % 4];
        payload = unmasked;
      }
      this.buffer = this.buffer.subarray(offset + maskLength + length);
      if (opcode === 0x8) this.close();
      else if (opcode === 0x1) this.handleMessage(payload.toString('utf8'));
    }
  }

  handleMessage(text) {
    const message = JSON.parse(text);
    if (message.id && this.pending.has(message.id)) {
      const pending = this.pending.get(message.id);
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(message.error.message || 'CDP command failed'));
      else pending.resolve(message.result || {});
      return;
    }
    this.events.push(message);
  }
}

async function acquireTarget(cdpUrl, baseUrl) {
  const clean = assertLocalHttpUrl(cdpUrl, 'CDP URL').toString().replace(/\/+$/, '');
  let targets = [];
  try {
    targets = await httpJson(`${clean}/json/list`);
  } catch (_error) {
    targets = [];
  }
  const page = Array.isArray(targets) ? targets.find((target) => target.type === 'page' && target.webSocketDebuggerUrl) : null;
  if (page) return assertLocalWsUrl(page.webSocketDebuggerUrl, 'CDP websocket URL').toString();
  const created = await httpJson(`${clean}/json/new?${encodeURIComponent(baseUrl)}`, 'PUT');
  if (!created.webSocketDebuggerUrl) throw new Error('CDP target did not provide websocket URL');
  return assertLocalWsUrl(created.webSocketDebuggerUrl, 'CDP websocket URL').toString();
}

async function acquireTargetById(cdpUrl, targetId) {
  const clean = assertLocalHttpUrl(cdpUrl, 'CDP URL').toString().replace(/\/+$/, '');
  if (typeof targetId !== 'string' || targetId === '' || targetId.length > 256) {
    throw new Error('target ID must be bounded');
  }
  const targets = await httpJson(`${clean}/json/list`);
  const matches = Array.isArray(targets)
    ? targets.filter((target) => target.id === targetId && target.type === 'page' && target.webSocketDebuggerUrl)
    : [];
  if (matches.length !== 1) throw new Error('exact approved CDP target is unavailable');
  return {
    id: matches[0].id,
    url: String(matches[0].url || ''),
    webSocketDebuggerUrl: assertLocalWsUrl(matches[0].webSocketDebuggerUrl, 'CDP websocket URL').toString(),
  };
}

function pageStateReady(state, previousTimeOrigin) {
  if (!state || (state.readyState !== 'interactive' && state.readyState !== 'complete')) return false;
  return previousTimeOrigin === undefined || state.timeOrigin !== previousTimeOrigin;
}

async function waitForPage(cdp, previousTimeOrigin) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const result = await cdp.send('Runtime.evaluate', {
      expression: '({ readyState: document.readyState, timeOrigin: performance.timeOrigin })',
      returnByValue: true,
    });
    const state = result.result && result.result.value;
    if (pageStateReady(state, previousTimeOrigin)) return state;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error('document did not become ready');
}

module.exports = {
  CdpSocket,
  acquireTarget,
  acquireTargetById,
  assertLocalHttpUrl,
  assertLocalWsUrl,
  localHost,
  pageStateReady,
  waitForPage,
};
