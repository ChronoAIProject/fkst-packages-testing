'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const MAX_JSON_BYTES = 2 * 1024 * 1024;
const DEFAULT_OUTPUT_BYTES = 64 * 1024;
const LOCK_TIMEOUT_MS = 10_000;
const sleepCell = new Int32Array(new SharedArrayBuffer(4));

function stableStringify(value) {
  const active = new Set();
  const encode = (item) => {
    if (item === null) return 'null';
    if (typeof item === 'string' || typeof item === 'boolean') return JSON.stringify(item);
    if (typeof item === 'number') {
      if (!Number.isFinite(item)) throw new Error('stable JSON rejects non-finite numbers');
      return JSON.stringify(item);
    }
    if (typeof item !== 'object') throw new Error(`stable JSON rejects ${typeof item}`);
    if (active.has(item)) throw new Error('stable JSON rejects cyclic values');
    active.add(item);
    let result;
    if (Array.isArray(item)) {
      result = `[${item.map((value) => encode(value)).join(',')}]`;
    } else {
      result = `{${Object.keys(item).sort().map((key) => `${JSON.stringify(key)}:${encode(item[key])}`).join(',')}}`;
    }
    active.delete(item);
    return result;
  };
  return encode(value);
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const item = argv[index];
    const value = argv[index + 1];
    if (!item || !item.startsWith('--') || typeof value !== 'string' || values[item.slice(2)] !== undefined) {
      throw new Error('invalid effect command arguments');
    }
    values[item.slice(2)] = value;
  }
  return values;
}

function boundedText(value, limit = 512) {
  return String(value || '').replace(/[\x00-\x1f\x7f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, limit);
}

function readJson(filePath) {
  const stat = fs.statSync(filePath);
  if (stat.size > MAX_JSON_BYTES) throw new Error(`JSON input exceeds ${MAX_JSON_BYTES} bytes`);
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function mkdirFor(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function writeJsonAtomic(filePath, value) {
  mkdirFor(filePath);
  const temp = `${filePath}.tmp.${process.pid}.${crypto.randomBytes(6).toString('hex')}`;
  fs.writeFileSync(temp, `${stableStringify(value)}\n`, { flag: 'wx' });
  fs.renameSync(temp, filePath);
}

function writeJsonImmutable(filePath, value) {
  mkdirFor(filePath);
  const body = `${stableStringify(value)}\n`;
  try {
    fs.writeFileSync(filePath, body, { flag: 'wx' });
    return;
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }
  if (fs.readFileSync(filePath, 'utf8') !== body) throw new Error(`immutable artifact differs: ${filePath}`);
}

function sleep(ms) {
  Atomics.wait(sleepCell, 0, 0, ms);
}

function processStartIdentity(pid) {
  if (!Number.isInteger(pid) || pid < 1) return null;
  const result = spawnSync('ps', ['-o', 'lstart=', '-p', String(pid)], {
    shell: false,
    encoding: 'utf8',
    timeout: 1_000,
    maxBuffer: 1024,
  });
  const identity = result.status === 0 ? String(result.stdout || '').trim() : '';
  return identity || null;
}

function processAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
}

function readLockOwner(lockPath) {
  try { return readJson(path.join(lockPath, 'owner.json')); } catch (_error) { return null; }
}

function recordedOwnerIsStale(lockPath) {
  const owner = readLockOwner(lockPath);
  if (!owner || !Number.isInteger(owner.pid) || typeof owner.process_start_identity !== 'string'
    || typeof owner.token !== 'string') return false;
  if (!processAlive(owner.pid)) return true;
  const current = processStartIdentity(owner.pid);
  return current !== null && current !== owner.process_start_identity;
}

function acquireLock(lockPath, timeoutMs = LOCK_TIMEOUT_MS) {
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  const deadline = Date.now() + timeoutMs;
  const identity = processStartIdentity(process.pid);
  if (identity === null) throw new Error('lock owner identity is unavailable');
  while (true) {
    try {
      fs.mkdirSync(lockPath);
      const owner = {
        schema: 'environment-factory.lock-owner.v1',
        pid: process.pid,
        process_start_identity: identity,
        token: crypto.randomBytes(16).toString('hex'),
      };
      try {
        fs.writeFileSync(path.join(lockPath, 'owner.json'), `${stableStringify(owner)}\n`, { flag: 'wx' });
      } catch (error) {
        fs.rmSync(lockPath, { recursive: true, force: true });
        throw error;
      }
      return () => {
        const recorded = readLockOwner(lockPath);
        if (recorded && recorded.pid === owner.pid && recorded.process_start_identity === owner.process_start_identity
          && recorded.token === owner.token) fs.rmSync(lockPath, { recursive: true, force: true });
      };
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      if (recordedOwnerIsStale(lockPath)) {
        fs.rmSync(lockPath, { recursive: true, force: true });
        continue;
      }
      if (Date.now() >= deadline) throw new Error(`lock timeout: ${lockPath}`);
      sleep(10);
    }
  }
}

function isSafeArtifactPath(value) {
  const text = String(value || '');
  if (!text.startsWith('.testing/') || path.isAbsolute(text) || text.includes('\\') || /[\x00-\x20\x7f]/.test(text)) return false;
  return text.split('/').every((segment) => segment !== '' && segment !== '.' && segment !== '..');
}

function artifactPath(pointer) {
  if (!pointer || pointer.kind !== 'artifact' || !isSafeArtifactPath(pointer.ref)) {
    throw new Error('safe artifact pointer is required');
  }
  const testingRoot = path.resolve(process.cwd(), '.testing');
  const resolved = path.resolve(process.cwd(), pointer.ref);
  if (resolved !== testingRoot && !resolved.startsWith(`${testingRoot}${path.sep}`)) {
    throw new Error('artifact pointer escaped .testing');
  }
  if (fs.existsSync(testingRoot) && fs.lstatSync(testingRoot).isSymbolicLink()) {
    throw new Error('artifact root is a symbolic link');
  }
  const relative = path.relative(testingRoot, resolved);
  let current = testingRoot;
  for (const segment of relative.split(path.sep).filter((item) => item !== '')) {
    current = path.join(current, segment);
    if (fs.existsSync(current) && fs.lstatSync(current).isSymbolicLink()) {
      throw new Error('artifact pointer traverses a symbolic link');
    }
  }
  return resolved;
}

function runtimeConfig(payload) {
  const config = readJson(artifactPath(payload.runtime_config_ref));
  if (config.schema !== 'environment-factory.runtime-config.v1') throw new Error('invalid runtime config schema');
  if (typeof config.state_auth_key !== 'string' || config.state_auth_key.length < 32 || config.state_auth_key.length > 512) {
    throw new Error('runtime config requires a bounded state_auth_key');
  }
  if (typeof config.state_mac_generation !== 'string' || config.state_mac_generation.length < 1
    || config.state_mac_generation.length > 180 || /[\x00-\x20\x7f]/.test(config.state_mac_generation)) {
    throw new Error('runtime config requires a bounded state_mac_generation');
  }
  return config;
}

function samePointer(left, right) {
  return Boolean(left && right && left.kind === right.kind && left.ref === right.ref);
}

function authorizationArtifact(config, sourcePointer) {
  for (const entry of config.authorization_sources || []) {
    if (samePointer(entry && entry.source_ref, sourcePointer)) return entry.artifact_ref;
  }
  throw new Error('authorization source is not materialized by the host runtime config');
}

function validateArgv(argv) {
  if (!Array.isArray(argv) || argv.length === 0 || argv.length > 128) throw new Error('direct argv is required');
  for (const item of argv) {
    if (typeof item !== 'string' || item.length === 0 || item.length > 4096 || /[\x00-\x1f\x7f]/.test(item)) {
      throw new Error('argv contains an invalid item');
    }
  }
  return argv;
}

function minimalEnvironment(extra = {}) {
  const allowed = ['HOME', 'LANG', 'LC_ALL', 'PATH', 'PATHEXT', 'SystemRoot', 'TEMP', 'TMP', 'TMPDIR', 'WINDIR'];
  const env = {};
  for (const key of allowed) {
    if (typeof process.env[key] === 'string') env[key] = process.env[key];
  }
  for (const [key, value] of Object.entries(extra)) {
    if (typeof value !== 'string' || /[\x00]/.test(value)) throw new Error('command environment contains an invalid value');
    env[key] = value;
  }
  return env;
}

function commandResult(argv, options = {}) {
  validateArgv(argv);
  const outputBytes = Math.max(1, Math.min(Number(options.outputBytes) || DEFAULT_OUTPUT_BYTES, MAX_JSON_BYTES));
  const result = spawnSync(argv[0], argv.slice(1), {
    cwd: options.cwd,
    env: options.env || minimalEnvironment(),
    shell: false,
    encoding: 'utf8',
    timeout: Math.max(1, Number(options.timeoutMs) || 30_000),
    maxBuffer: outputBytes,
  });
  return {
    exitCode: Number.isInteger(result.status) ? result.status : -1,
    stdout: String(result.stdout || '').slice(0, outputBytes),
    stderr: boundedText(result.stderr || (result.error && result.error.message), outputBytes),
    error: result.error,
  };
}

function sameArray(left, right) {
  return stableStringify(left) === stableStringify(right);
}

module.exports = {
  DEFAULT_OUTPUT_BYTES,
  MAX_JSON_BYTES,
  acquireLock,
  artifactPath,
  authorizationArtifact,
  boundedText,
  commandResult,
  isSafeArtifactPath,
  minimalEnvironment,
  parseArgs,
  readJson,
  runtimeConfig,
  sameArray,
  samePointer,
  sha256,
  stableStringify,
  validateArgv,
  writeJsonAtomic,
  writeJsonImmutable,
};
