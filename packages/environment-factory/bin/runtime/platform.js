'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { processStartIdentity, sleep } = require('./common');

function directCommand(argv, options = {}) {
  return spawnSync(argv[0], argv.slice(1), {
    cwd: options.cwd,
    env: options.env,
    shell: false,
    encoding: 'utf8',
    timeout: options.timeoutMs || 2_000,
    maxBuffer: options.outputBytes || 1024 * 1024,
  });
}

function parsePsTime(value) {
  const text = String(value || '').trim();
  const dayParts = text.split('-');
  let days = 0;
  let clock = text;
  if (dayParts.length === 2) {
    days = Number(dayParts[0]);
    clock = dayParts[1];
  }
  const parts = clock.split(':').map(Number);
  if (parts.some((item) => !Number.isFinite(item)) || parts.length < 2 || parts.length > 3) return null;
  const seconds = parts.length === 3
    ? (parts[0] * 3600) + (parts[1] * 60) + parts[2]
    : (parts[0] * 60) + parts[1];
  return Math.round(((days * 86400) + seconds) * 1000);
}

function processTable() {
  const result = directCommand(['ps', '-axo', 'pid=,pgid=,rss=,time='], {
    timeoutMs: 2_000,
    outputBytes: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) return null;
  const rows = [];
  for (const line of String(result.stdout || '').split('\n')) {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/);
    if (!match) continue;
    const cpuMillis = parsePsTime(match[4]);
    if (cpuMillis === null) return null;
    rows.push({
      pid: Number(match[1]),
      pgid: Number(match[2]),
      rssBytes: Number(match[3]) * 1024,
      cpuMillis,
    });
  }
  return rows.length > 0 ? rows : null;
}

function processGroupUsage(pgids) {
  const wanted = new Set((pgids || []).filter((value) => Number.isInteger(value) && value > 0));
  const rows = processTable();
  if (!rows) return { supported: false };
  const members = rows.filter((row) => wanted.has(row.pgid));
  return {
    supported: true,
    processes: members.length,
    rssBytes: members.reduce((sum, row) => sum + row.rssBytes, 0),
    cpuMillis: members.reduce((sum, row) => sum + row.cpuMillis, 0),
    members,
  };
}

function linuxAddressClass(hex, family) {
  const value = String(hex || '').toUpperCase();
  if (/^0+$/.test(value)) return 'wildcard';
  if (family === 4 && value.length === 8) {
    const bytes = value.match(/../g).reverse().map((item) => Number.parseInt(item, 16));
    return bytes[0] === 127 ? 'loopback' : 'other';
  }
  if (family === 6 && (value === '00000000000000000000000001000000'
    || value === '00000000000000000000000000000001')) return 'loopback';
  return 'other';
}

function linuxListenerRows() {
  const rows = [];
  for (const [filePath, family] of [['/proc/net/tcp', 4], ['/proc/net/tcp6', 6]]) {
    let body;
    try { body = fs.readFileSync(filePath, 'utf8'); } catch (_error) { return null; }
    for (const line of body.split('\n').slice(1)) {
      const fields = line.trim().split(/\s+/);
      if (fields.length < 10 || fields[3] !== '0A') continue;
      const local = fields[1].split(':');
      const port = Number.parseInt(local[1], 16);
      if (!Number.isInteger(port)) continue;
      rows.push({
        inode: fields[9],
        port,
        addressClass: linuxAddressClass(local[0], family),
      });
    }
  }
  return rows;
}

function linuxIpv4Address(hex) {
  const value = String(hex || '').toUpperCase();
  if (value.length !== 8) return null;
  const bytes = value.match(/../g).reverse().map((item) => Number.parseInt(item, 16));
  if (bytes.some((item) => !Number.isInteger(item))) return null;
  return bytes.join('.');
}

function linuxEstablishedRows() {
  let body;
  try { body = fs.readFileSync('/proc/net/tcp', 'utf8'); } catch (_error) { return null; }
  const rows = [];
  for (const line of body.split('\n').slice(1)) {
    const fields = line.trim().split(/\s+/);
    if (fields.length < 10 || fields[3] !== '01') continue;
    const local = fields[1].split(':');
    const remote = fields[2].split(':');
    const localAddress = linuxIpv4Address(local[0]);
    const remoteAddress = linuxIpv4Address(remote[0]);
    const localPort = Number.parseInt(local[1], 16);
    const remotePort = Number.parseInt(remote[1], 16);
    if (!localAddress || !remoteAddress || !Number.isInteger(localPort) || !Number.isInteger(remotePort)) continue;
    rows.push({
      inode: fields[9], localAddress, localPort, remoteAddress, remotePort,
    });
  }
  return rows;
}

function socketOwnersForPids(inodes, pids) {
  const wanted = new Set(inodes);
  const owners = new Map([...wanted].map((inode) => [inode, new Set()]));
  for (const pid of pids) {
    const fdRoot = path.join('/proc', String(pid), 'fd');
    let descriptors;
    try { descriptors = fs.readdirSync(fdRoot); } catch (_error) { continue; }
    for (const descriptor of descriptors) {
      let target;
      try { target = fs.readlinkSync(path.join(fdRoot, descriptor)); } catch (_error) { continue; }
      const match = target.match(/^socket:\[(\d+)\]$/);
      if (match && owners.has(match[1])) owners.get(match[1]).add(pid);
    }
  }
  return owners;
}

function linuxListenersForPids(pids) {
  const rows = linuxListenerRows();
  if (rows === null) return { supported: false, listeners: [] };
  const owners = socketOwnersForPids(rows.map((row) => row.inode), pids);
  return {
    supported: true,
    listeners: rows.filter((row) => owners.get(row.inode).size > 0)
      .map((row) => ({ ...row, pids: [...owners.get(row.inode)] })),
  };
}

function parseLsofName(value) {
  const text = String(value || '').replace(/\s+\(LISTEN\)$/, '');
  const match = text.match(/^(.*):(\d+)$/);
  if (!match) return null;
  const host = match[1].replace(/^\[/, '').replace(/\]$/, '').toLowerCase();
  let addressClass = 'other';
  if (host === '127.0.0.1' || host === '::1' || host === 'localhost') addressClass = 'loopback';
  else if (host === '*' || host === '0.0.0.0' || host === '::') addressClass = 'wildcard';
  return { port: Number(match[2]), addressClass };
}

function lsofListenersForPids(pids) {
  if (pids.length === 0) return { supported: true, listeners: [] };
  const candidates = process.platform === 'darwin' ? ['/usr/sbin/lsof', 'lsof'] : ['lsof'];
  for (const command of candidates) {
    const result = directCommand([
      command, '-nP', '-a', '-p', pids.join(','), '-iTCP', '-sTCP:LISTEN', '-Fpn',
    ], { timeoutMs: 2_000, outputBytes: 1024 * 1024 });
    if (result.error && result.error.code === 'ENOENT') continue;
    if (result.error) return { supported: false, listeners: [] };
    if (result.status !== 0 && String(result.stdout || '').trim() === '') return { supported: true, listeners: [] };
    if (result.status !== 0) return { supported: false, listeners: [] };
    const listeners = [];
    let pid = null;
    for (const line of String(result.stdout || '').split('\n')) {
      if (/^p\d+$/.test(line)) pid = Number(line.slice(1));
      if (line.startsWith('n')) {
        const parsed = parseLsofName(line.slice(1));
        if (parsed && Number.isInteger(pid)) listeners.push({ ...parsed, pids: [pid] });
      }
    }
    return { supported: true, listeners };
  }
  return { supported: false, listeners: [] };
}

function listenersForPids(pids) {
  if (process.platform === 'linux') {
    const result = linuxListenersForPids(pids);
    if (result.supported) return result;
  }
  if (process.platform === 'darwin' || process.platform === 'linux') return lsofListenersForPids(pids);
  return { supported: false, listeners: [] };
}

function listenerOwners(port) {
  if (!Number.isInteger(port) || port < 1 || port > 65535) return { supported: false, pids: [] };
  if (process.platform === 'darwin') {
    const result = directCommand([
      '/usr/sbin/lsof', '-nP', `-iTCP:${port}`, '-sTCP:LISTEN', '-Fp',
    ], { timeoutMs: 2_000, outputBytes: 256 * 1024 });
    if (result.error) return { supported: false, pids: [] };
    if (result.status !== 0 && String(result.stdout || '').trim() === '') return { supported: true, pids: [] };
    if (result.status !== 0) return { supported: false, pids: [] };
    const pids = String(result.stdout || '').split('\n')
      .filter((line) => /^p\d+$/.test(line))
      .map((line) => Number(line.slice(1)));
    return { supported: true, pids: [...new Set(pids)] };
  }
  const rows = processTable();
  if (!rows) return { supported: false, pids: [] };
  const result = listenersForPids(rows.map((row) => row.pid));
  if (!result.supported) return { supported: false, pids: [] };
  const pids = new Set();
  for (const listener of result.listeners) {
    if (listener.port === port) for (const pid of listener.pids) pids.add(pid);
  }
  return { supported: true, pids: [...pids] };
}

function parseEstablishedLsofName(value) {
  const text = String(value || '').replace(/\s+\(ESTABLISHED\)$/, '');
  const match = text.match(/^127\.0\.0\.1:(\d+)->127\.0\.0\.1:(\d+)$/);
  if (!match) return null;
  return { localPort: Number(match[1]), remotePort: Number(match[2]) };
}

function lsofEstablishedRows() {
  const candidates = process.platform === 'darwin' ? ['/usr/sbin/lsof', 'lsof'] : ['lsof'];
  for (const command of candidates) {
    const result = directCommand([
      command, '-nP', '-iTCP', '-sTCP:ESTABLISHED', '-Fpn',
    ], { timeoutMs: 1_000, outputBytes: 4 * 1024 * 1024 });
    if (result.error && result.error.code === 'ENOENT') continue;
    if (result.error) return null;
    if (result.status !== 0 && String(result.stdout || '').trim() === '') return [];
    if (result.status !== 0) return null;
    const rows = [];
    let pid = null;
    for (const line of String(result.stdout || '').split('\n')) {
      if (/^p\d+$/.test(line)) pid = Number(line.slice(1));
      if (line.startsWith('n')) {
        const parsed = parseEstablishedLsofName(line.slice(1));
        if (parsed && Number.isInteger(pid)) rows.push({ ...parsed, pid });
      }
    }
    return rows;
  }
  return null;
}

function connectionOwnedByProcessGroup(socket, pgid) {
  const localAddress = socket && socket.localAddress;
  const remoteAddress = socket && socket.remoteAddress;
  const localPort = Number(socket && socket.localPort);
  const remotePort = Number(socket && socket.remotePort);
  if (localAddress !== '127.0.0.1' || remoteAddress !== '127.0.0.1'
    || !Number.isInteger(localPort) || !Number.isInteger(remotePort)
    || !Number.isInteger(pgid) || pgid < 1) {
    return { supported: true, owned: false, reason: 'connection-tuple-invalid', pids: [] };
  }
  const processes = processTable();
  if (!processes) return { supported: false, owned: false, reason: 'process-table-unavailable', pids: [] };
  let pids;
  if (process.platform === 'linux') {
    const rows = linuxEstablishedRows();
    if (rows === null) {
      return { supported: false, owned: false, reason: 'connection-inspection-unavailable', pids: [] };
    }
    const matches = rows.filter((row) => row.localAddress === remoteAddress
      && row.localPort === remotePort && row.remoteAddress === localAddress
      && row.remotePort === localPort);
    const owners = socketOwnersForPids(matches.map((row) => row.inode), processes.map((row) => row.pid));
    pids = [...new Set(matches.flatMap((row) => [...(owners.get(row.inode) || [])]))];
  } else if (process.platform === 'darwin') {
    const rows = lsofEstablishedRows();
    if (rows === null) {
      return { supported: false, owned: false, reason: 'connection-inspection-unavailable', pids: [] };
    }
    pids = [...new Set(rows.filter((row) => row.localPort === remotePort
      && row.remotePort === localPort).map((row) => row.pid))];
  } else {
    return { supported: false, owned: false, reason: 'connection-inspection-unsupported', pids: [] };
  }
  if (pids.length === 0) {
    return { supported: true, owned: false, reason: 'connection-not-visible', pids: [] };
  }
  const groups = new Map(processes.map((row) => [row.pid, row.pgid]));
  if (pids.some((pid) => groups.get(pid) !== pgid)) {
    return { supported: true, owned: false, reason: 'foreign-connection', pids };
  }
  return { supported: true, owned: true, pids };
}

function listenersOwnedByProcessGroup(ports, pgid) {
  const rows = processTable();
  if (!rows) return { supported: false, owned: false, reason: 'process-table-unavailable' };
  const members = rows.filter((row) => row.pgid === pgid).map((row) => row.pid);
  const result = listenersForPids(members);
  if (!result.supported) return { supported: false, owned: false, reason: 'listener-ownership-unavailable' };
  const expected = new Map((ports || []).map((item) => [item.port, item]));
  const counts = new Map();
  for (const listener of result.listeners) {
    if (listener.addressClass !== 'loopback') {
      return { supported: true, owned: false, reason: `non-loopback-listener:${listener.port}` };
    }
    if (!expected.has(listener.port)) {
      return { supported: true, owned: false, reason: `extra-listener:${listener.port}` };
    }
    counts.set(listener.port, (counts.get(listener.port) || 0) + 1);
  }
  for (const item of ports || []) {
    const count = counts.get(item.port) || 0;
    if (count === 0) {
      const owners = listenerOwners(item.port);
      if (!owners.supported) return { supported: false, owned: false, reason: 'listener-ownership-unavailable' };
      return {
        supported: true,
        owned: false,
        reason: owners.pids.length > 0 ? `foreign-listener:${item.port}` : `listener-missing:${item.port}`,
      };
    }
    if (count !== 1) return { supported: true, owned: false, reason: `duplicate-listener:${item.port}` };
    const owners = listenerOwners(item.port);
    if (!owners.supported) return { supported: false, owned: false, reason: 'listener-ownership-unavailable' };
    const groups = new Map(rows.map((row) => [row.pid, row.pgid]));
    if (owners.pids.some((pid) => groups.get(pid) !== pgid)) {
      return { supported: true, owned: false, reason: `foreign-listener:${item.port}` };
    }
  }
  return { supported: true, owned: true };
}

function processGroupState(resource) {
  const pgid = Number(resource && (resource.pgid || resource.pid));
  if (!Number.isInteger(pgid) || pgid < 1) return { supported: true, alive: false };
  const usage = processGroupUsage([pgid]);
  if (!usage.supported) return { supported: false, alive: true };
  if (usage.processes === 0) return { supported: true, alive: false };
  const leader = usage.members.find((item) => item.pid === resource.pid);
  if (leader && typeof resource.process_start_identity === 'string'
    && processStartIdentity(resource.pid) !== resource.process_start_identity) {
    return { supported: true, alive: false, foreign: true };
  }
  return { supported: true, alive: true };
}

function terminateProcessGroup(resource, timeoutMs = 5_000) {
  const pgid = Number(resource && (resource.pgid || resource.pid));
  let state = processGroupState(resource);
  if (!state.supported) return { released: false, reason: 'process-group-inspection-unavailable' };
  if (state.foreign) return { released: false, reason: 'process-group-ownership-changed' };
  if (!state.alive) return { released: true };
  try { process.kill(-pgid, 'SIGTERM'); } catch (_error) {
    try { process.kill(resource.pid, 'SIGTERM'); } catch (_ignored) {}
  }
  const deadline = Date.now() + Math.max(1, Number(timeoutMs) || 1);
  while (Date.now() < deadline) {
    state = processGroupState(resource);
    if (!state.supported || !state.alive || state.foreign) break;
    sleep(25);
  }
  state = processGroupState(resource);
  if (!state.supported) return { released: false, reason: 'process-group-inspection-unavailable' };
  if (state.foreign) return { released: false, reason: 'process-group-ownership-changed' };
  if (state.alive) {
    try { process.kill(-pgid, 'SIGKILL'); } catch (_error) {
      try { process.kill(resource.pid, 'SIGKILL'); } catch (_ignored) {}
    }
    const killDeadline = Date.now() + 2_000;
    while (Date.now() < killDeadline) {
      state = processGroupState(resource);
      if (!state.supported || !state.alive || state.foreign) break;
      sleep(25);
    }
  }
  state = processGroupState(resource);
  if (!state.supported) return { released: false, reason: 'process-group-inspection-unavailable' };
  if (state.foreign) return { released: false, reason: 'process-group-ownership-changed' };
  return state.alive ? { released: false, reason: 'process-group-still-alive' } : { released: true };
}

function listenersReleased(ports) {
  for (const item of ports || []) {
    const owners = listenerOwners(item.port);
    if (!owners.supported) return { supported: false, released: false };
    if (owners.pids.length > 0) return { supported: true, released: false, port: item.port };
  }
  return { supported: true, released: true };
}

function directoryBytes(directory) {
  const result = directCommand(['du', '-sk', directory], { timeoutMs: 5_000, outputBytes: 64 * 1024 });
  if (result.error || result.status !== 0) return { supported: false };
  const match = String(result.stdout || '').match(/^\s*(\d+)/);
  if (!match) return { supported: false };
  return { supported: true, bytes: Number(match[1]) * 1024 };
}

module.exports = {
  connectionOwnedByProcessGroup,
  directoryBytes,
  listenerOwners,
  listenersOwnedByProcessGroup,
  listenersReleased,
  parsePsTime,
  processGroupState,
  processGroupUsage,
  processTable,
  terminateProcessGroup,
};
