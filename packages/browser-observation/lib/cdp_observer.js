'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const net = require('net');
const os = require('os');
const path = require('path');

const DEFAULT_BASE_URL = 'http://localhost:3000';
const DEFAULT_CDP_URL = 'http://127.0.0.1:9222';
const DEFAULT_ARTIFACT_ROOT = '.testing/runs/browser-observation';
const DEFAULT_ID_PREFIX = 'observed';
const DEFAULT_MANIFEST_SCHEMA = 'browser-observation.observations.v1';
const DEFAULT_EVIDENCE_SCHEMA = 'browser-observation.evidence.v1';
const DEFAULT_OBSERVATION_LIMIT = 16;
const DEFAULT_PAGE_LIMIT = 12;
const TEXT_LIMIT = 120;
const LINK_LIMIT = 40;
const HEADING_LIMIT = 5;
const FORBIDDEN_PAYLOAD_TERMS = ['raw_dom', 'screenshot_body', 'model_transcript', 'browser_storage', 'localstorage', 'sessionstorage', 'cookie', 'token', 'password'];

function optionList(value) {
  if (Array.isArray(value)) return value.filter((item) => String(item || '').trim() !== '');
  if (value instanceof Set) return Array.from(value).filter((item) => String(item || '').trim() !== '');
  if (value === undefined || value === null || value === '') return [];
  return [String(value)];
}

function boundedInteger(value, fallback, min, max, label) {
  const selected = value === undefined || value === null || value === '' ? fallback : Number(value);
  if (!Number.isInteger(selected) || selected < min || selected > max) throw new Error(`${label} must be an integer from ${min} to ${max}`);
  return selected;
}

function observerOptions(input = {}) {
  return {
    baseUrl: input.baseUrl || DEFAULT_BASE_URL,
    cdpUrl: input.cdpUrl || DEFAULT_CDP_URL,
    artifactRoot: input.artifactRoot || DEFAULT_ARTIFACT_ROOT,
    idPrefix: input.idPrefix || DEFAULT_ID_PREFIX,
    manifestSchema: input.manifestSchema || DEFAULT_MANIFEST_SCHEMA,
    evidenceSchema: input.evidenceSchema || DEFAULT_EVIDENCE_SCHEMA,
    observationLimit: boundedInteger(input.observationLimit, DEFAULT_OBSERVATION_LIMIT, 1, 64, 'observation limit'),
    pageLimit: boundedInteger(input.pageLimit, DEFAULT_PAGE_LIMIT, 1, 64, 'page limit'),
    blockPrefixes: optionList(input.blockPrefixes),
    blockSegments: new Set(optionList(input.blockSegments).map((item) => item.toLowerCase())),
  };
}

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
  if (parsed.protocol !== 'http:' || !localHost(parsed.hostname)) {
    throw new Error(`${label} must be local http`);
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
  if (parsed.protocol !== 'ws:' || !localHost(parsed.hostname)) {
    throw new Error(`${label} must be local ws`);
  }
  return parsed;
}

function safeArtifactRoot(value) {
  const text = String(value || '');
  if (!text.startsWith('.testing/runs/')) return false;
  if (text.startsWith('/') || text.includes('\\') || /\s/.test(text)) return false;
  if (!/^[A-Za-z0-9._\-/#]+$/.test(text)) return false;
  return text.split('/').every((segment) => segment !== '.' && segment !== '..');
}

function cleanText(value, fallback) {
  const text = String(value || '')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  const selected = text || fallback || '';
  return selected.length > TEXT_LIMIT ? selected.slice(0, TEXT_LIMIT) : selected;
}

function routeFromUrl(value, baseUrl, options) {
  let parsed;
  try {
    parsed = new URL(value, baseUrl);
  } catch (_err) {
    return null;
  }
  const base = new URL(baseUrl);
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
  if (parsed.origin.toLowerCase() !== base.origin.toLowerCase()) return null;
  let route = parsed.pathname || '/';
  if (!route.startsWith('/')) route = `/${route}`;
  route = route.replace(/\/+/g, '/');
  if (route.length > 1) route = route.replace(/\/+$/g, '');
  route = route || '/';
  return options !== undefined && isBlockedRoute(route, options) ? null : route;
}

function hasForbiddenPayloadTerm(value) {
  const text = String(value || '').toLowerCase();
  return FORBIDDEN_PAYLOAD_TERMS.some((term) => text.includes(term));
}

function safeEvidenceText(value) {
  const text = cleanText(value, '');
  return hasForbiddenPayloadTerm(text) ? '' : text;
}

function isBlockedRoute(route, options = observerOptions()) {
  const text = String(route || '').toLowerCase();
  if (!text.startsWith('/') || hasForbiddenPayloadTerm(text)) return true;
  for (const prefixValue of options.blockPrefixes || []) {
    const prefix = String(prefixValue || '').toLowerCase();
    if (prefix !== '' && (text === prefix || text.startsWith(`${prefix}/`))) return true;
  }
  const segments = text.split('/').filter(Boolean);
  const blockedSegments = options.blockSegments || new Set();
  return segments.some((segment) => blockedSegments.has(segment));
}

function slug(value) {
  let text = String(value || 'module').replace(/^\//, 'root');
  text = text.replace(/[^A-Za-z0-9._-]+/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '');
  if (!text) text = 'module';
  return text.length > 80 ? text.slice(0, 80) : text;
}

function observationId(route, options) {
  return `${options.idPrefix}-${slug(route)}`;
}

function observationName(route, projection, linkLabel) {
  const heading = Array.isArray(projection.headings) ? projection.headings[0] : null;
  return cleanText(linkLabel || heading || projection.title, route === '/' ? 'Landing page' : route.split('/').filter(Boolean).join(' '));
}

function entryUrl(baseUrl, route) {
  return new URL(route, baseUrl).toString().replace(/\/$/, route === '/' ? '/' : '');
}

function makeObservation(baseUrl, route, projection, source, linkLabel, options) {
  const id = observationId(route, options);
  const name = observationName(route, projection || {}, linkLabel);
  return {
    id,
    name,
    entry_url: entryUrl(baseUrl, route),
    route,
    visible_label: cleanText(linkLabel || name, name),
    discovery_source: source,
    confidence: source === 'nav-link' ? 'medium' : 'high',
    evidence_pointer: `${options.artifactRoot}/evidence/discovery/${id}.json`,
  };
}

function safeProjection(value) {
  const projection = value && typeof value === 'object' ? value : {};
  return {
    title: cleanText(projection.title, ''),
    headings: Array.isArray(projection.headings) ? projection.headings.map((item) => cleanText(item, '')).filter(Boolean).slice(0, HEADING_LIMIT) : [],
    links: Array.isArray(projection.links)
      ? projection.links.map((item) => ({
        label: cleanText(item && item.label, ''),
        href: cleanText(item && item.href, ''),
        nav: Boolean(item && item.nav),
      })).filter((item) => item.href).slice(0, LINK_LIMIT)
      : [],
  };
}

function forbiddenPayloadText(payload) {
  const text = JSON.stringify(payload).toLowerCase();
  return FORBIDDEN_PAYLOAD_TERMS.filter((item) => text.includes(item));
}

function safeObservation(observation) {
  return observation && forbiddenPayloadText(observation).length === 0 ? observation : null;
}

function observationFromLink(baseUrl, link, projection, options) {
  const route = routeFromUrl(link.href, baseUrl, options);
  if (route === null || hasForbiddenPayloadTerm(link.label)) return null;
  const source = link.nav ? 'nav-link' : 'browser-visible';
  return safeObservation(makeObservation(baseUrl, route, projection, source, link.label, options));
}

function dedupeObservations(observations, options) {
  const seen = new Set();
  const out = [];
  for (const observation of observations) {
    if (!observation || seen.has(observation.route)) continue;
    seen.add(observation.route);
    out.push(observation);
    if (out.length >= options.observationLimit) break;
  }
  return out;
}

function luaString(value) {
  return String(value)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\n/g, '\\n')
    .replace(/\r/g, '\\r')
    .replace(/[\u0000-\u001f\u007f]/g, ' ');
}

function writeLua(filePath, observations) {
  const fields = ['id', 'name', 'entry_url', 'route', 'visible_label', 'discovery_source', 'confidence', 'evidence_pointer'];
  const lines = ['return {'];
  for (const observation of observations) {
    lines.push('  {');
    for (const field of fields) lines.push(`    ${field} = "${luaString(observation[field])}",`);
    lines.push('  },');
  }
  lines.push('}');
  lines.push('');
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, lines.join('\n'));
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`);
}

function writeEvidence(repoRoot, observations, projectionsByRoute, options) {
  for (const observation of observations) {
    const projection = projectionsByRoute.get(observation.route) || {};
    const evidence = {
      schema: options.evidenceSchema,
      observation_id: observation.id,
      route: observation.route,
      title: safeEvidenceText(projection.title),
      heading: Array.isArray(projection.headings) ? safeEvidenceText(projection.headings[0]) : '',
      visible_label: observation.visible_label,
      discovery_source: observation.discovery_source,
    };
    const bad = forbiddenPayloadText(evidence);
    if (bad.length > 0) throw new Error(`forbidden evidence terms leaked: ${bad.join(', ')}`);
    writeJson(path.join(repoRoot, observation.evidence_pointer), evidence);
  }
}

function httpJson(url, method = 'GET') {
  const parsed = new URL(url);
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: parsed.hostname,
      port: parsed.port || 80,
      path: `${parsed.pathname}${parsed.search}`,
      method,
      timeout: 5000,
    }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(`CDP HTTP ${method} ${url} returned ${res.statusCode}`));
          return;
        }
        try {
          resolve(JSON.parse(body));
        } catch (err) {
          reject(err);
        }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error(`CDP HTTP timeout for ${url}`)));
    req.end();
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
    this.wsUrl = new URL(wsUrl);
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
      const onError = (err) => reject(err);
      this.socket.once('error', onError);
      this.socket.once('connect', () => {
        const request = [
          `GET ${this.wsUrl.pathname}${this.wsUrl.search} HTTP/1.1`,
          `Host: ${this.wsUrl.host}`,
          'Upgrade: websocket',
          'Connection: Upgrade',
          `Sec-WebSocket-Key: ${key}`,
          'Sec-WebSocket-Version: 13',
          '',
          '',
        ].join('\r\n');
        this.socket.write(request);
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
        this.socket.on('error', (err) => this.rejectAll(err));
        this.socket.on('close', () => this.rejectAll(new Error('websocket closed')));
        resolve();
      };
      this.socket.on('data', onData);
    });
  }

  close() {
    if (this.socket) this.socket.end();
  }

  rejectAll(err) {
    for (const item of this.pending.values()) item.reject(err);
    this.pending.clear();
  }

  send(method, params = {}) {
    const id = this.nextId++;
    const message = JSON.stringify({ id, method, params });
    this.socket.write(websocketFrame(message));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP command timed out: ${method}`));
      }, 10000);
      this.pending.set(id, { resolve, reject, timer });
    });
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
  const clean = cdpUrl.replace(/\/+$/, '');
  let targets = [];
  try {
    targets = await httpJson(`${clean}/json/list`);
  } catch (_err) {
    targets = [];
  }
  const page = Array.isArray(targets) ? targets.find((target) => target.type === 'page' && target.webSocketDebuggerUrl) : null;
  if (page) return assertLocalWsUrl(page.webSocketDebuggerUrl, 'CDP websocket URL').toString();
  const created = await httpJson(`${clean}/json/new?${encodeURIComponent(baseUrl)}`, 'PUT');
  if (!created.webSocketDebuggerUrl) throw new Error('CDP target did not provide websocket URL');
  return assertLocalWsUrl(created.webSocketDebuggerUrl, 'CDP websocket URL').toString();
}

async function waitForPage(cdp) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const result = await cdp.send('Runtime.evaluate', { expression: 'document.readyState', returnByValue: true });
    const state = result.result && result.result.value;
    if (state === 'interactive' || state === 'complete') return;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}

const projectionExpression = `(() => {
  const text = (node) => String((node && (node.innerText || node.textContent)) || '').replace(/\\s+/g, ' ').trim().slice(0, 120);
  const visible = (node) => !!node && !!(node.offsetWidth || node.offsetHeight || node.getClientRects().length);
  const headings = Array.from(document.querySelectorAll('h1,h2,[role="heading"]')).filter(visible).map(text).filter(Boolean).slice(0, 5);
  const navNodes = new Set(Array.from(document.querySelectorAll('nav a[href], [role="navigation"] a[href], header a[href]')));
  const links = Array.from(document.querySelectorAll('a[href]'))
    .filter(visible)
    .map((node) => ({ label: text(node), href: node.href, nav: navNodes.has(node) }))
    .filter((item) => item.href && item.label)
    .slice(0, 40);
  return { title: String(document.title || '').slice(0, 120), headings, links };
})()`;

async function waitForProjection(cdp) {
  let projection = safeProjection({});
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const result = await cdp.send('Runtime.evaluate', { expression: projectionExpression, returnByValue: true });
    projection = safeProjection(result.result && result.result.value);
    if (projection.links.length > 0 || projection.headings.length > 0) return projection;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return projection;
}

async function collect(baseUrl, cdpUrl, inputOptions = {}) {
  const options = observerOptions(inputOptions);
  assertLocalHttpUrl(baseUrl, 'base URL');
  assertLocalHttpUrl(cdpUrl, 'CDP URL');
  if (!safeArtifactRoot(options.artifactRoot)) throw new Error('artifact root must be a safe .testing/runs/... path');
  const wsUrl = await acquireTarget(cdpUrl, baseUrl);
  const cdp = new CdpSocket(wsUrl);
  await cdp.connect();
  try {
    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    const queue = ['/'];
    const queued = new Set(queue);
    const visited = new Set();
    const observations = [];
    const projectionsByRoute = new Map();
    while (queue.length > 0 && visited.size < options.pageLimit && observations.length < options.observationLimit) {
      const route = queue.shift();
      if (visited.has(route) || isBlockedRoute(route, options)) continue;
      visited.add(route);
      await cdp.send('Page.navigate', { url: new URL(route, baseUrl).toString() });
      await waitForPage(cdp);
      const projection = await waitForProjection(cdp);
      projectionsByRoute.set(route, projection);
      const pageObservation = safeObservation(makeObservation(baseUrl, route, projection, route === '/' ? 'browser-visible' : 'a11y-visible', undefined, options));
      if (pageObservation) observations.push(pageObservation);
      for (const link of projection.links) {
        const nextRoute = routeFromUrl(link.href, baseUrl, options);
        const linkObservation = observationFromLink(baseUrl, link, projection, options);
        if (linkObservation) observations.push(linkObservation);
        if (nextRoute !== null && !queued.has(nextRoute) && !visited.has(nextRoute)) {
          queued.add(nextRoute);
          queue.push(nextRoute);
        }
        if (observations.length >= options.observationLimit) break;
      }
    }
    return { observations: dedupeObservations(observations, options), projectionsByRoute };
  } finally {
    cdp.close();
  }
}

function manifest(baseUrl, observations, options) {
  return {
    schema: options.manifestSchema,
    base_url: baseUrl,
    artifact_root: options.artifactRoot,
    observation_count: observations.length,
    observations,
  };
}

async function run(config) {
  const options = observerOptions(config);
  if (!config.jsonOut || !config.luaOut) throw new Error('--json-out and --lua-out are required');
  const repoRoot = config.repoRoot || process.cwd();
  const { observations, projectionsByRoute } = await collect(options.baseUrl, options.cdpUrl, options);
  if (observations.length === 0) throw new Error('observer produced zero observations');
  const payload = manifest(options.baseUrl, observations, options);
  const bad = forbiddenPayloadText(payload);
  if (bad.length > 0) throw new Error(`forbidden payload terms leaked: ${bad.join(', ')}`);
  writeJson(config.jsonOut, payload);
  writeEvidence(repoRoot, observations, projectionsByRoute, options);
  writeLua(config.luaOut, observations);
  return payload;
}

async function runSelfTest() {
  const options = observerOptions({
    baseUrl: DEFAULT_BASE_URL,
    cdpUrl: DEFAULT_CDP_URL,
    artifactRoot: '.testing/runs/browser-observation-self-test',
    idPrefix: 'self-test-observed',
    blockPrefixes: ['/admin'],
    blockSegments: ['create'],
  });
  const projection = safeProjection({
    title: ' Local Home ',
    headings: [' Welcome '],
    links: [
      { label: 'Docs', href: 'http://localhost:3000/docs?x=1#top', nav: true },
      { label: 'Admin', href: 'http://localhost:3000/admin', nav: true },
      { label: 'Create', href: 'http://localhost:3000/items/create', nav: false },
      { label: 'External', href: 'https://example.com/', nav: true },
      { label: 'Bad', href: 'javascript:alert(1)', nav: false },
      { label: 'Cookie settings', href: 'http://localhost:3000/preferences', nav: false },
    ],
  });
  const docsRoute = routeFromUrl(projection.links[0].href, options.baseUrl);
  const docs = observationFromLink(options.baseUrl, projection.links[0], projection, options);
  if (docsRoute !== '/docs' || !docs || docs.route !== '/docs' || docs.entry_url !== 'http://localhost:3000/docs') throw new Error('route normalization failed');
  if (routeFromUrl(projection.links[1].href, options.baseUrl, options) !== null) throw new Error('blocked route normalization was not blocked');
  if (observationFromLink(options.baseUrl, projection.links[1], projection, options) !== null) throw new Error('blocked prefix route was not blocked');
  if (observationFromLink(options.baseUrl, projection.links[2], projection, options) !== null) throw new Error('blocked segment route was not blocked');
  if (observationFromLink(options.baseUrl, projection.links[3], projection, options) !== null) throw new Error('external route was not blocked');
  if (observationFromLink(options.baseUrl, projection.links[4], projection, options) !== null) throw new Error('unsafe scheme was not blocked');
  if (observationFromLink(options.baseUrl, projection.links[5], projection, options) !== null) throw new Error('forbidden label was not blocked');
  try {
    assertLocalHttpUrl('https://example.com', 'base URL');
    throw new Error('non-local URL was not rejected');
  } catch (err) {
    if (!String(err.message).includes('local http')) throw err;
  }
  try {
    assertLocalWsUrl('wss://example.com/devtools/page/1', 'CDP websocket URL');
    throw new Error('non-local websocket URL was not rejected');
  } catch (err) {
    if (!String(err.message).includes('local ws')) throw err;
  }
  const output = [makeObservation(options.baseUrl, '/', projection, 'browser-visible', undefined, options), docs];
  const payload = manifest(options.baseUrl, output, options);
  if (forbiddenPayloadText(payload).length > 0) throw new Error('forbidden payload term leaked into manifest');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-observer-self-test.'));
  try {
    const luaOut = path.join(tmp, 'observations.lua');
    const jsonOut = path.join(tmp, 'observations.json');
    const projections = new Map([['/docs', { title: 'Cookie banner', headings: ['Password prompt'] }]]);
    writeLua(luaOut, output);
    writeJson(jsonOut, payload);
    writeEvidence(tmp, [docs], projections, options);
    const combined = [luaOut, jsonOut, path.join(tmp, docs.evidence_pointer)].map((file) => fs.readFileSync(file, 'utf8')).join('\n').toLowerCase();
    for (const term of FORBIDDEN_PAYLOAD_TERMS) {
      if (combined.includes(term)) throw new Error(`forbidden generated output term leaked: ${term}`);
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

module.exports = {
  DEFAULT_BASE_URL,
  DEFAULT_CDP_URL,
  DEFAULT_ARTIFACT_ROOT,
  DEFAULT_ID_PREFIX,
  DEFAULT_MANIFEST_SCHEMA,
  DEFAULT_EVIDENCE_SCHEMA,
  FORBIDDEN_PAYLOAD_TERMS,
  observerOptions,
  assertLocalHttpUrl,
  assertLocalWsUrl,
  cleanText,
  routeFromUrl,
  isBlockedRoute,
  safeProjection,
  observationFromLink,
  makeObservation,
  collect,
  forbiddenPayloadText,
  writeLua,
  writeJson,
  writeEvidence,
  manifest,
  run,
  runSelfTest,
};
