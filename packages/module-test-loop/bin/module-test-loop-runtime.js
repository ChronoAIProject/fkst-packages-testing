'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const request = JSON.parse(process.env.FKST_MODULE_TEST_LOOP_REQUEST_JSON || '{}');
const operation = process.argv[2];
const workspace = process.cwd();

function fail(message) {
  process.stderr.write(`module-test-loop-runtime: ${message}\n`);
  process.exit(1);
}

function safePath(value, field) {
  if (typeof value !== 'string' || !value.startsWith('.testing/runs/') || value.includes('\\')) {
    fail(`${field} must be under .testing/runs/`);
  }
  const normalized = path.posix.normalize(value);
  if (normalized !== value || normalized.split('/').includes('..')) {
    fail(`${field} is not normalized`);
  }
  const absolute = path.resolve(workspace, value);
  const root = path.resolve(workspace, '.testing', 'runs');
  if (absolute !== root && !absolute.startsWith(`${root}${path.sep}`)) {
    fail(`${field} escapes the testing root`);
  }
  return absolute;
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    if (error && error.code === 'ENOENT') return null;
    throw error;
  }
}

function atomicWrite(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const temp = `${filePath}.tmp-${process.pid}`;
  fs.writeFileSync(temp, `${JSON.stringify(value)}\n`, { encoding: 'utf8', flag: 'wx', mode: 0o600 });
  fs.renameSync(temp, filePath);
}

function withLock(filePath, callback) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const lockPath = `${filePath}.lock`;
  let handle;
  try {
    handle = fs.openSync(lockPath, 'wx', 0o600);
  } catch (error) {
    if (error && error.code === 'EEXIST') return { saved: false, stale: true };
    throw error;
  }
  try {
    return callback();
  } finally {
    fs.closeSync(handle);
    fs.rmSync(lockPath, { force: true });
  }
}

function loadState() {
  const statePath = safePath(request.state_ref, 'state_ref');
  const state = readJson(statePath);
  return { ok: true, found: state !== null, result: state || undefined };
}

function saveState() {
  const statePath = safePath(request.state_ref, 'state_ref');
  const expected = request.expected_revision;
  const state = request.state;
  if (!Number.isInteger(expected) || expected < 0 || !state || state.version !== expected + 1) {
    fail('save-state revision is invalid');
  }
  const outcome = withLock(statePath, () => {
    const current = readJson(statePath);
    const currentRevision = current && Number.isInteger(current.version) ? current.version : 0;
    if (currentRevision !== expected) return { saved: false, stale: true };
    atomicWrite(statePath, state);
    return { saved: true, revision: state.version };
  });
  return { ok: true, ...outcome };
}

function collectPending(directory, output, limit, depth) {
  if (output.length >= limit || depth > 8 || !fs.existsSync(directory)) return;
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (output.length >= limit) break;
    if (entry.isSymbolicLink()) continue;
    const item = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      collectPending(item, output, limit, depth + 1);
    } else if (entry.isFile() && entry.name === 'module-loop-state.json') {
      const state = readJson(item);
      if (state && state.phase !== 'terminal') {
        output.push(path.relative(workspace, item).split(path.sep).join('/'));
      }
    }
  }
}

function listPendingStates() {
  const limit = request.limit;
  if (!Number.isInteger(limit) || limit < 1 || limit > 64) fail('limit must be from 1 to 64');
  const output = [];
  collectPending(path.resolve(workspace, '.testing', 'runs'), output, limit, 0);
  output.sort();
  return { ok: true, result: output.slice(0, limit) };
}

function artifactDigest() {
  const artifactPath = safePath(request.pointer, 'pointer');
  try {
    const digest = crypto.createHash('sha256').update(fs.readFileSync(artifactPath)).digest('hex');
    return { ok: true, found: true, digest };
  } catch (error) {
    if (error && error.code === 'ENOENT') return { ok: true, found: false };
    throw error;
  }
}

try {
  const handlers = {
    'load-state': loadState,
    'save-state': saveState,
    'list-pending-states': listPendingStates,
    'artifact-digest': artifactDigest,
  };
  if (!handlers[operation]) fail('unknown operation');
  process.stdout.write(`${JSON.stringify(handlers[operation]())}\n`);
} catch (error) {
  fail(error && error.message ? error.message : String(error));
}
