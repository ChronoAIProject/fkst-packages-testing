'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const MAX_JSON_BYTES = 2 * 1024 * 1024;
const DEFAULT_OUTPUT_BYTES = 64 * 1024;
const LOCK_TIMEOUT_MS = 10_000;
const sleepCell = new Int32Array(new SharedArrayBuffer(4));
const WORKER_ENVIRONMENT_LEASE = Symbol('fkst.worker-environment-lease');

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
  if (process.platform === 'linux') {
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
      const close = stat.lastIndexOf(')');
      if (close < 0) return null;
      const fields = stat.slice(close + 2).trim().split(/\s+/);
      if (fields[0] === 'Z') return null;
      const startTicks = fields[19];
      const bootId = fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim();
      if (!/^\d+$/.test(startTicks) || !/^[0-9a-f-]{36}$/.test(bootId)) return null;
      return `linux-proc-v1:${bootId}:${startTicks}`;
    } catch (_error) {
      return null;
    }
  }
  const result = spawnSync('ps', ['-o', 'stat=', '-o', 'lstart=', '-o', 'command=', '-p', String(pid)], {
    shell: false,
    encoding: 'utf8',
    timeout: 1_000,
    maxBuffer: 64 * 1024,
  });
  const identity = result.status === 0 ? String(result.stdout || '').trim() : '';
  const parsed = identity.match(/^(\S+)\s+(.+)$/s);
  if (!parsed || parsed[1].startsWith('Z')) return null;
  return `${process.platform}-ps-command-v1:${sha256(parsed[2])}`;
}

function processAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
}

function pathIdentity(target) {
  const realpath = fs.realpathSync(target);
  const stat = fs.statSync(realpath);
  return {
    realpath,
    device: String(stat.dev),
    inode: String(stat.ino),
  };
}

function samePathIdentity(left, right) {
  return Boolean(left && right && left.realpath === right.realpath
    && left.device === right.device && left.inode === right.inode);
}

function removeOwnedDirectory(target, expectedIdentity, containmentRoot) {
  if (typeof target !== 'string' || typeof containmentRoot !== 'string') {
    throw new Error('owned directory paths are invalid');
  }
  const root = fs.realpathSync(containmentRoot);
  const identity = pathIdentity(target);
  if (!samePathIdentity(identity, expectedIdentity)) throw new Error('owned directory identity changed');
  if (identity.realpath === root || !identity.realpath.startsWith(`${root}${path.sep}`)) {
    throw new Error('owned directory escaped containment root');
  }
  fs.rmSync(identity.realpath, { recursive: true, force: false });
  return !fs.existsSync(identity.realpath);
}

function readLockOwner(lockPath) {
  try { return readJson(path.join(lockPath, 'owner.json')); } catch (_error) { return null; }
}

function lockOwnerIsStale(owner) {
  if (!owner || !Number.isInteger(owner.pid) || typeof owner.process_start_identity !== 'string'
    || typeof owner.token !== 'string') return false;
  if (!processAlive(owner.pid)) return true;
  const current = processStartIdentity(owner.pid);
  return current !== null && current !== owner.process_start_identity;
}

function sameLockOwner(left, right) {
  return Boolean(left && right && left.pid === right.pid
    && left.process_start_identity === right.process_start_identity && left.token === right.token);
}

function createDirectoryLock(lockPath, identity) {
  fs.mkdirSync(lockPath);
  const directoryIdentity = pathIdentity(lockPath);
  const owner = {
    schema: 'environment-factory.lock-owner.v1',
    pid: process.pid,
    process_start_identity: identity,
    token: crypto.randomBytes(16).toString('hex'),
  };
  try {
    fs.writeFileSync(path.join(lockPath, 'owner.json'), `${stableStringify(owner)}\n`, { flag: 'wx' });
  } catch (error) {
    if (samePathIdentity(pathIdentity(lockPath), directoryIdentity)) {
      fs.rmSync(directoryIdentity.realpath, { recursive: true, force: true });
    }
    throw error;
  }
  let released = false;
  return {
    owner,
    directoryIdentity,
    release() {
      if (released) return;
      const recorded = readLockOwner(lockPath);
      if (sameLockOwner(recorded, owner)
        && samePathIdentity(pathIdentity(lockPath), directoryIdentity)) {
        fs.rmSync(directoryIdentity.realpath, { recursive: true, force: true });
      }
      released = true;
    },
  };
}

function executablePath(candidates) {
  for (const candidate of candidates) {
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch (_error) {}
  }
  return null;
}

function acquireTakeoverGuard(lockPath, timeoutMs) {
  if (process.platform !== 'linux' && process.platform !== 'darwin') {
    throw new Error('lock stale takeover is unsupported on this platform');
  }
  const holderPath = path.join(__dirname, 'lock-holder.js');
  const guardPath = `${lockPath}.takeover.lock`;
  const markerPath = `${lockPath}.takeover.active`;
  const token = crypto.randomBytes(16).toString('hex');
  const environment = Object.create(null);
  for (const key of ['LANG', 'LC_ALL', 'PATH', 'SystemRoot', 'WINDIR']) {
    if (typeof process.env[key] === 'string') environment[key] = process.env[key];
  }
  let argv;
  if (process.platform === 'linux') {
    const flock = executablePath(['/usr/bin/flock', '/bin/flock']);
    if (flock === null) throw new Error('lock stale takeover requires flock');
    argv = [flock, '-x', '-w', String(Math.max(1, Math.ceil(timeoutMs / 1000))), '-F', guardPath,
      process.execPath, holderPath, 'linux', guardPath, markerPath, token, String(timeoutMs)];
  } else {
    argv = [process.execPath, holderPath, 'darwin', guardPath, markerPath, token];
  }
  const child = spawn(argv[0], argv.slice(1), {
    env: environment,
    shell: false,
    stdio: ['pipe', 'ignore', 'ignore'],
  });
  child.once('error', () => {});
  const deadline = Date.now() + timeoutMs;
  let holderIdentity = null;
  const held = () => {
    const currentIdentity = processStartIdentity(child.pid);
    if (currentIdentity === null) return false;
    try {
      const marker = JSON.parse(fs.readFileSync(markerPath, 'utf8'));
      if (marker.pid !== child.pid || marker.token !== token) return false;
      if (holderIdentity === null) holderIdentity = currentIdentity;
      return currentIdentity === holderIdentity;
    } catch (_error) {
      return false;
    }
  };
  while (!held()) {
    if (processStartIdentity(child.pid) === null) {
      throw new Error(`lock takeover holder exited: ${lockPath}`);
    }
    if (Date.now() >= deadline) {
      try { child.kill('SIGKILL'); } catch (_error) {}
      throw new Error(`lock takeover timeout: ${lockPath}`);
    }
    sleep(10);
  }
  let released = false;
  return {
    markerPath,
    assertHeld() {
      if (released || !held()) throw new Error(`lock takeover ownership changed: ${lockPath}`);
    },
    release() {
      if (released) return;
      released = true;
      try { child.kill('SIGTERM'); } catch (_error) {}
      const releaseDeadline = Date.now() + 2_000;
      while (fs.existsSync(markerPath) && Date.now() < releaseDeadline) sleep(10);
      if (fs.existsSync(markerPath)) {
        try { child.kill('SIGKILL'); } catch (_error) {}
        throw new Error(`lock takeover release could not be verified: ${lockPath}`);
      }
    },
  };
}

function acquireLock(lockPath, timeoutMs = LOCK_TIMEOUT_MS, options = {}) {
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  const deadline = Date.now() + timeoutMs;
  const identity = processStartIdentity(process.pid);
  if (identity === null) throw new Error('lock owner identity is unavailable');
  const takeoverMarkerPath = `${lockPath}.takeover.active`;
  while (true) {
    if (fs.existsSync(takeoverMarkerPath)) {
      const cleanup = acquireTakeoverGuard(lockPath, Math.max(1, deadline - Date.now()));
      cleanup.assertHeld();
      cleanup.release();
      continue;
    }
    try {
      const acquired = createDirectoryLock(lockPath, identity);
      if (fs.existsSync(takeoverMarkerPath)) {
        acquired.release();
        continue;
      }
      return acquired.release;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
    const observedOwner = readLockOwner(lockPath);
    if (lockOwnerIsStale(observedOwner)) {
      let takeover;
      try {
        takeover = acquireTakeoverGuard(lockPath, Math.max(1, deadline - Date.now()));
      } catch (error) {
        if (Date.now() >= deadline) throw error;
      }
      if (takeover) {
        try {
          if (typeof options.afterTakeoverAcquired === 'function') options.afterTakeoverAcquired(takeover);
          takeover.assertHeld();
          const currentOwner = readLockOwner(lockPath);
          if (sameLockOwner(currentOwner, observedOwner) && lockOwnerIsStale(currentOwner)) {
            const staleIdentity = pathIdentity(lockPath);
            const confirmedOwner = readLockOwner(lockPath);
            if (sameLockOwner(confirmedOwner, currentOwner)
              && samePathIdentity(pathIdentity(lockPath), staleIdentity)) {
              takeover.assertHeld();
              fs.rmSync(staleIdentity.realpath, { recursive: true, force: true });
              while (true) {
                try {
                  const acquired = createDirectoryLock(lockPath, identity);
                  try {
                    takeover.assertHeld();
                  } catch (error) {
                    acquired.release();
                    throw error;
                  }
                  takeover.release();
                  return acquired.release;
                } catch (error) {
                  if (error.code !== 'EEXIST') throw error;
                  if (Date.now() >= deadline) throw new Error(`lock takeover timeout: ${lockPath}`);
                  sleep(10);
                }
              }
            }
          }
        } finally {
          takeover.release();
        }
      }
    }
    if (Date.now() >= deadline) throw new Error(`lock timeout: ${lockPath}`);
    sleep(10);
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

function forbiddenWorkerEnvironmentKey(key) {
  const upper = key.toUpperCase();
  const exact = new Set([
    'HOME', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'APPDATA', 'LOCALAPPDATA',
    'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'GH_CONFIG_DIR',
  ]);
  return exact.has(upper) || upper.startsWith('GH_') || upper.startsWith('GITHUB_')
    || upper.startsWith('GIT_') || upper.startsWith('SSH_')
    || upper.includes('ASKPASS') || upper.includes('CREDENTIAL_HELPER');
}

function requireOwnedDirectory(directory, { privateDirectory = false } = {}) {
  let created = false;
  try {
    fs.mkdirSync(directory, { mode: privateDirectory ? 0o700 : 0o755 });
    created = true;
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    throw new Error(`worker environment directory is not a real directory: ${directory}`);
  }
  if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
    throw new Error(`worker environment directory has a foreign owner: ${directory}`);
  }
  if (privateDirectory && process.platform !== 'win32') {
    if (!created && (stat.mode & 0o077) !== 0) {
      throw new Error(`worker environment directory permissions are too broad: ${directory}`);
    }
    fs.chmodSync(directory, 0o700);
  }
  return fs.realpathSync(directory);
}

function minimalEnvironment(extra = {}, isolationKey = 'shared-runtime-command') {
  if (!extra || typeof extra !== 'object' || Array.isArray(extra)) {
    throw new Error('command environment must be an object');
  }
  const allowed = ['LANG', 'LC_ALL', 'PATH', 'PATHEXT', 'SystemRoot', 'TEMP', 'TMP', 'TMPDIR', 'WINDIR'];
  const env = Object.create(null);
  for (const key of allowed) {
    if (typeof process.env[key] === 'string') env[key] = process.env[key];
  }
  for (const [key, value] of Object.entries(extra)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(key) || forbiddenWorkerEnvironmentKey(key)) {
      throw new Error(`command environment contains a forbidden worker authority key: ${key}`);
    }
    if (typeof value !== 'string' || /[\x00]/.test(value)) throw new Error('command environment contains an invalid value');
    env[key] = value;
  }
  const identity = typeof isolationKey === 'string' ? { scope: isolationKey } : isolationKey;
  if (!identity || typeof identity !== 'object' || Array.isArray(identity)) {
    throw new Error('worker isolation identity is invalid');
  }
  const identityBody = stableStringify(identity);
  const configuredRuntimeRoot = path.resolve(
    process.env.FKST_RUNTIME_ROOT || path.join('.testing', 'runtime'),
  );
  fs.mkdirSync(configuredRuntimeRoot, { recursive: true });
  const runtimeRoot = requireOwnedDirectory(configuredRuntimeRoot);
  const homesRoot = requireOwnedDirectory(path.join(runtimeRoot, 'worker-homes'), { privateDirectory: true });
  const home = fs.mkdtempSync(path.join(homesRoot, `${sha256(identityBody).slice(0, 24)}-`));
  if (process.platform !== 'win32') fs.chmodSync(home, 0o700);
  const marker = `${stableStringify({
    schema: 'fkst.worker-home-identity.v1',
    identity_sha256: sha256(identityBody),
    lease_id: crypto.randomBytes(16).toString('hex'),
  })}\n`;
  const markerPath = path.join(home, '.fkst-worker-home.json');
  fs.writeFileSync(markerPath, marker, { flag: 'wx', mode: 0o600 });
  const configHome = path.join(home, '.config');
  requireOwnedDirectory(configHome, { privateDirectory: true });
  requireOwnedDirectory(path.join(configHome, 'gh'), { privateDirectory: true });
  const nullDevice = process.platform === 'win32' ? 'NUL' : '/dev/null';
  Object.assign(env, {
    HOME: home,
    USERPROFILE: home,
    XDG_CONFIG_HOME: configHome,
    XDG_DATA_HOME: path.join(home, '.local', 'share'),
    XDG_STATE_HOME: path.join(home, '.local', 'state'),
    GH_CONFIG_DIR: path.join(configHome, 'gh'),
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: nullDevice,
    GIT_CONFIG_COUNT: '4',
    GIT_CONFIG_KEY_0: 'credential.helper',
    GIT_CONFIG_VALUE_0: '',
    GIT_CONFIG_KEY_1: 'core.askPass',
    GIT_CONFIG_VALUE_1: '',
    GIT_CONFIG_KEY_2: 'core.fsmonitor',
    GIT_CONFIG_VALUE_2: 'false',
    GIT_CONFIG_KEY_3: 'core.hooksPath',
    GIT_CONFIG_VALUE_3: nullDevice,
    GIT_TERMINAL_PROMPT: '0',
    GCM_INTERACTIVE: 'Never',
  });
  Object.defineProperty(env, WORKER_ENVIRONMENT_LEASE, {
    configurable: false,
    enumerable: false,
    writable: false,
    value: {
      schema: 'fkst.worker-home-lease.v1',
      home,
      home_identity: pathIdentity(home),
      homes_root: homesRoot,
      homes_root_identity: pathIdentity(homesRoot),
      marker_sha256: sha256(marker),
      identity_sha256: sha256(identityBody),
      released: false,
    },
  });
  return env;
}

function workerEnvironmentLease(environment) {
  const lease = environment && environment[WORKER_ENVIRONMENT_LEASE];
  if (!lease || lease.schema !== 'fkst.worker-home-lease.v1') {
    throw new Error('worker environment lease is unavailable');
  }
  return {
    schema: lease.schema,
    home: lease.home,
    home_identity: { ...lease.home_identity },
    homes_root: lease.homes_root,
    homes_root_identity: { ...lease.homes_root_identity },
    marker_sha256: lease.marker_sha256,
    identity_sha256: lease.identity_sha256,
  };
}

function verifyWorkerEnvironmentLease(lease) {
  if (!lease || lease.schema !== 'fkst.worker-home-lease.v1'
    || typeof lease.home !== 'string' || typeof lease.homes_root !== 'string'
    || !samePathIdentity(pathIdentity(lease.homes_root), lease.homes_root_identity)
    || !samePathIdentity(pathIdentity(lease.home), lease.home_identity)) {
    throw new Error('worker environment lease identity changed');
  }
  const root = fs.realpathSync(lease.homes_root);
  const home = fs.realpathSync(lease.home);
  if (!home.startsWith(`${root}${path.sep}`)) throw new Error('worker environment home escaped its lease root');
  const markerPath = path.join(home, '.fkst-worker-home.json');
  const markerStat = fs.lstatSync(markerPath);
  if (!markerStat.isFile() || markerStat.isSymbolicLink()) throw new Error('worker environment marker is invalid');
  const marker = fs.readFileSync(markerPath, 'utf8');
  if (sha256(marker) !== lease.marker_sha256) throw new Error('worker environment marker changed');
  const value = JSON.parse(marker);
  if (value.schema !== 'fkst.worker-home-identity.v1'
    || value.identity_sha256 !== lease.identity_sha256
    || typeof value.lease_id !== 'string' || !/^[0-9a-f]{32}$/.test(value.lease_id)) {
    throw new Error('worker environment marker binding changed');
  }
  for (const directory of [path.join(home, '.config'), path.join(home, '.config', 'gh')]) {
    const stat = fs.lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('worker environment config directory changed');
  }
  return true;
}

function verifyWorkerEnvironment(environment) {
  const lease = workerEnvironmentLease(environment);
  if (environment.HOME !== lease.home || environment.USERPROFILE !== lease.home
    || environment.XDG_CONFIG_HOME !== path.join(lease.home, '.config')
    || environment.GH_CONFIG_DIR !== path.join(lease.home, '.config', 'gh')) {
    throw new Error('worker environment variables differ from the owned lease');
  }
  return verifyWorkerEnvironmentLease(lease);
}

function releaseWorkerEnvironmentLease(lease) {
  if (!lease || lease.schema !== 'fkst.worker-home-lease.v1') {
    throw new Error('worker environment lease is invalid');
  }
  if (!fs.existsSync(lease.home)) return true;
  verifyWorkerEnvironmentLease(lease);
  return removeOwnedDirectory(lease.home, lease.home_identity, lease.homes_root);
}

function releaseWorkerEnvironment(environment) {
  const lease = environment && environment[WORKER_ENVIRONMENT_LEASE];
  if (!lease) return false;
  if (lease.released) return true;
  const released = releaseWorkerEnvironmentLease(lease);
  lease.released = released;
  return released;
}

function commandResult(argv, options = {}) {
  validateArgv(argv);
  const outputBytes = Math.max(1, Math.min(Number(options.outputBytes) || DEFAULT_OUTPUT_BYTES, MAX_JSON_BYTES));
  const ownedEnvironment = options.env === undefined;
  const environment = options.env || minimalEnvironment();
  try {
    verifyWorkerEnvironment(environment);
    const result = spawnSync(argv[0], argv.slice(1), {
      cwd: options.cwd,
      env: environment,
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
  } finally {
    if (ownedEnvironment) releaseWorkerEnvironment(environment);
  }
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
  pathIdentity,
  processAlive,
  processStartIdentity,
  readJson,
  removeOwnedDirectory,
  releaseWorkerEnvironment,
  releaseWorkerEnvironmentLease,
  runtimeConfig,
  sameArray,
  samePathIdentity,
  samePointer,
  sha256,
  sleep,
  stableStringify,
  validateArgv,
  verifyWorkerEnvironment,
  verifyWorkerEnvironmentLease,
  workerEnvironmentLease,
  writeJsonAtomic,
  writeJsonImmutable,
};
