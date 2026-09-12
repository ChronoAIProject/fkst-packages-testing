'use strict';

const fs = require('fs');

const MAX_MARKER_BYTES = 8 * 1024;

function fail(message) {
  process.stderr.write(`lock-holder: ${message}\n`);
  process.exit(2);
}

function readMarker(markerPath) {
  const fd = fs.openSync(markerPath, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const before = fs.fstatSync(fd, { bigint: true });
    const linked = fs.lstatSync(markerPath, { bigint: true });
    if (!before.isFile() || !linked.isFile() || linked.isSymbolicLink()
      || before.dev !== linked.dev || before.ino !== linked.ino
      || before.size > BigInt(MAX_MARKER_BYTES)) fail('takeover marker is invalid');
    const buffer = Buffer.alloc(Number(before.size));
    let offset = 0;
    while (offset < buffer.length) {
      const count = fs.readSync(fd, buffer, offset, buffer.length - offset, offset);
      if (count === 0) break;
      offset += count;
    }
    const after = fs.fstatSync(fd, { bigint: true });
    if (offset !== buffer.length || after.size !== before.size
      || after.mtimeNs !== before.mtimeNs || after.ctimeNs !== before.ctimeNs) {
      fail('takeover marker changed while reading');
    }
    return JSON.parse(buffer.toString('utf8'));
  } finally {
    fs.closeSync(fd);
  }
}

function removeStaleMarker(markerPath) {
  try {
    const stat = fs.lstatSync(markerPath);
    if (stat.isSymbolicLink() || !stat.isFile()) fail('takeover marker is not a regular file');
  } catch (error) {
    if (error && error.code === 'ENOENT') return;
    throw error;
  }
  // The system guard is already exclusive, so any pre-existing marker belongs to a prior holder.
  fs.unlinkSync(markerPath);
}

const [mode, lockPath, markerPath, token] = process.argv.slice(2);
if (!['linux', 'darwin'].includes(mode) || !lockPath || !markerPath
  || !/^[0-9a-f]{32}$/.test(String(token || ''))) fail('arguments are invalid');
let darwinGuard = null;
if (mode === 'darwin') {
  const O_EXLOCK = 0x00000020;
  darwinGuard = fs.openSync(lockPath,
    fs.constants.O_RDWR | fs.constants.O_CREAT | (fs.constants.O_NOFOLLOW || 0) | O_EXLOCK, 0o600);
  const opened = fs.fstatSync(darwinGuard);
  const current = fs.lstatSync(lockPath);
  if (!opened.isFile() || current.isSymbolicLink() || !current.isFile()
    || opened.dev !== current.dev || opened.ino !== current.ino) {
    fs.closeSync(darwinGuard);
    fail('Darwin takeover guard identity changed');
  }
}

removeStaleMarker(markerPath);
fs.writeFileSync(markerPath, `${JSON.stringify({ pid: process.pid, token })}\n`, {
  flag: 'wx',
  mode: 0o600,
});

let cleaned = false;
function cleanup() {
  if (cleaned) return;
  cleaned = true;
  try {
    const marker = readMarker(markerPath);
    if (marker.pid === process.pid && marker.token === token) fs.unlinkSync(markerPath);
  } catch (_error) {}
  if (darwinGuard !== null) fs.closeSync(darwinGuard);
}

for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.once(signal, () => {
    cleanup();
    process.exit(0);
  });
}
process.stdin.resume();
process.stdin.once('end', () => {
  cleanup();
  process.exit(0);
});
process.stdin.once('error', () => {
  cleanup();
  process.exit(0);
});
