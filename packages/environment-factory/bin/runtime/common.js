'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const MAX_JSON_BYTES = 2 * 1024 * 1024;
const MAX_LOCK_METADATA_BYTES = 8 * 1024;
const MAX_CLEANUP_BROKER_BYTES = 256 * 1024;
const DEFAULT_OUTPUT_BYTES = 64 * 1024;
const LOCK_TIMEOUT_MS = 10_000;
const OBJECT_BOUND_CLEANUP_UNAVAILABLE = 'OBJECT_BOUND_CLEANUP_UNAVAILABLE';
const CLEANUP_CAPTURE_SCHEMA = 'environment-factory.object-bound-cleanup-capture-state.v1';
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

function readBoundedRegularFile(filePath, maximumBytes = MAX_JSON_BYTES) {
  if (!Number.isInteger(maximumBytes) || maximumBytes < 1 || maximumBytes > MAX_JSON_BYTES) {
    throw new Error('bounded file limit is invalid');
  }
  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0);
  const fd = fs.openSync(filePath, flags);
  try {
    const before = fs.fstatSync(fd, { bigint: true });
    const linkedBefore = fs.lstatSync(filePath, { bigint: true });
    if (!before.isFile() || !linkedBefore.isFile() || linkedBefore.isSymbolicLink()
      || before.dev !== linkedBefore.dev || before.ino !== linkedBefore.ino
      || before.size > BigInt(maximumBytes)) {
      throw new Error(`bounded regular file is invalid: ${filePath}`);
    }
    const realpath = fs.realpathSync(filePath);
    const size = Number(before.size);
    const buffer = Buffer.alloc(size);
    let offset = 0;
    while (offset < size) {
      const count = fs.readSync(fd, buffer, offset, size - offset, offset);
      if (count === 0) break;
      offset += count;
    }
    const after = fs.fstatSync(fd, { bigint: true });
    const linkedAfter = fs.lstatSync(filePath, { bigint: true });
    if (offset !== size || after.dev !== before.dev || after.ino !== before.ino
      || after.size !== before.size || after.mtimeNs !== before.mtimeNs || after.ctimeNs !== before.ctimeNs
      || linkedAfter.dev !== before.dev || linkedAfter.ino !== before.ino
      || linkedAfter.isSymbolicLink() || !linkedAfter.isFile()
      || fs.realpathSync(filePath) !== realpath) {
      throw new Error(`bounded regular file changed while reading: ${filePath}`);
    }
    return {
      body: buffer.toString('utf8'),
      identity: {
        realpath,
        device: String(before.dev),
        inode: String(before.ino),
      },
    };
  } finally {
    fs.closeSync(fd);
  }
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

function pathEntryExists(target) {
  try {
    fs.lstatSync(target);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

function configuredObjectBoundBroker(pathKey, digestKey, label) {
  const sourcePath = process.env[pathKey];
  const expectedSha256 = process.env[digestKey];
  if (sourcePath === undefined && expectedSha256 === undefined) return null;
  if (typeof sourcePath !== 'string' || !path.isAbsolute(sourcePath)
    || typeof expectedSha256 !== 'string' || !/^[0-9a-f]{64}$/.test(expectedSha256)) {
    throw new Error(`object-bound ${label} broker configuration is invalid`);
  }
  const source = readBoundedRegularFile(sourcePath, MAX_CLEANUP_BROKER_BYTES).body;
  if (sha256(source) !== expectedSha256) {
    throw new Error(`object-bound ${label} broker digest differs`);
  }
  return source;
}

function configuredObjectBoundCleanupBroker() {
  return configuredObjectBoundBroker(
    'FKST_OBJECT_BOUND_CLEANUP_BROKER', 'FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256', 'cleanup',
  );
}

function configuredObjectBoundAllocationBroker() {
  const configured = configuredObjectBoundBroker(
    'FKST_OBJECT_BOUND_ALLOCATION_BROKER', 'FKST_OBJECT_BOUND_ALLOCATION_BROKER_SHA256',
    'allocation',
  );
  return configured === null ? configuredObjectBoundCleanupBroker() : configured;
}

function invokeObjectBoundCleanupBroker(
  target, targetIdentity, containmentRoot, rootIdentity, captureId, operation,
) {
  const source = configuredObjectBoundCleanupBroker();
  if (source === null) return null;
  const python = process.platform === 'win32' ? null : '/usr/bin/python3';
  if (python === null || !fs.existsSync(python)) return null;
  const request = {
    schema: 'environment-factory.object-bound-cleanup-request.v1',
    operation,
    capture_id: captureId,
    target,
    target_identity: targetIdentity,
    containment_root: containmentRoot,
    containment_root_identity: rootIdentity,
  };
  const environment = Object.create(null);
  for (const key of ['LANG', 'LC_ALL']) {
    if (typeof process.env[key] === 'string') environment[key] = process.env[key];
  }
  const result = spawnSync(python, ['-I', '-c', source], {
    input: `${stableStringify(request)}\n`,
    env: environment,
    shell: false,
    encoding: 'utf8',
    timeout: 30_000,
    maxBuffer: MAX_LOCK_METADATA_BYTES,
  });
  if (result.status !== 0) return null;
  let receipt;
  try { receipt = JSON.parse(String(result.stdout || '')); } catch (_error) { return null; }
  const expectedStatus = {
    'capture-delete': 'captured-cleaned',
    finalize: 'finalized',
    'release-proof': 'released',
  }[operation];
  if (expectedStatus === undefined) return null;
  return receipt
    && receipt.schema === 'environment-factory.object-bound-cleanup-receipt.v1'
    && receipt.status === expectedStatus
    && receipt.capture_id === captureId
    && receipt.target_removed === true
    && String(receipt.target_device) === targetIdentity.device
    && String(receipt.target_inode) === targetIdentity.inode
    && String(receipt.containment_root_device) === rootIdentity.device
    && String(receipt.containment_root_inode) === rootIdentity.inode
    ? receipt : null;
}

function allocateOwnedDirectory(
  target, containmentRoot, rootIdentity, allocationId, markerName, markerBody,
  childDirectories = [],
) {
  if (typeof target !== 'string' || !path.isAbsolute(target)
    || typeof containmentRoot !== 'string' || !path.isAbsolute(containmentRoot)
    || path.dirname(target) !== containmentRoot
    || !samePathIdentity(pathIdentity(containmentRoot), rootIdentity)
    || !/^[0-9a-f]{64}$/.test(String(allocationId || ''))
    || typeof markerName !== 'string' || markerName === '' || path.basename(markerName) !== markerName
    || typeof markerBody !== 'string' || !markerBody.endsWith('\n')
    || !Array.isArray(childDirectories)) {
    throw new Error('object-bound directory allocation binding is invalid');
  }
  const source = configuredObjectBoundAllocationBroker();
  const python = process.platform === 'win32' ? null : '/usr/bin/python3';
  if (source === null || python === null || !fs.existsSync(python)) {
    throw new Error('OBJECT_BOUND_DIRECTORY_ALLOCATION_UNAVAILABLE');
  }
  const request = {
    schema: 'environment-factory.object-bound-directory-allocation-request.v1',
    operation: 'allocate-directory',
    allocation_id: allocationId,
    target: path.join(rootIdentity.realpath, path.basename(target)),
    containment_root: rootIdentity.realpath,
    containment_root_identity: rootIdentity,
    marker_name: markerName,
    marker_body: markerBody,
    child_directories: childDirectories,
  };
  const environment = Object.create(null);
  for (const key of ['LANG', 'LC_ALL']) {
    if (typeof process.env[key] === 'string') environment[key] = process.env[key];
  }
  const result = spawnSync(python, ['-I', '-c', source], {
    input: `${stableStringify(request)}\n`,
    env: environment,
    shell: false,
    encoding: 'utf8',
    timeout: 30_000,
    maxBuffer: MAX_LOCK_METADATA_BYTES,
  });
  if (result.status !== 0) throw new Error('OBJECT_BOUND_DIRECTORY_ALLOCATION_FAILED');
  let receipt;
  try { receipt = JSON.parse(String(result.stdout || '')); } catch (_error) {
    throw new Error('OBJECT_BOUND_DIRECTORY_ALLOCATION_FAILED');
  }
  const identity = receipt && {
    realpath: receipt.target_realpath,
    device: String(receipt.target_device),
    inode: String(receipt.target_inode),
  };
  if (!receipt
    || receipt.schema !== 'environment-factory.object-bound-directory-allocation-receipt.v1'
    || receipt.status !== 'allocated' || receipt.allocation_id !== allocationId
    || receipt.target_realpath !== request.target
    || String(receipt.containment_root_device) !== rootIdentity.device
    || String(receipt.containment_root_inode) !== rootIdentity.inode
    || !samePathIdentity(pathIdentity(target), identity)
    || !samePathIdentity(pathIdentity(containmentRoot), rootIdentity)) {
    throw new Error('OBJECT_BOUND_DIRECTORY_ALLOCATION_FAILED');
  }
  return identity;
}

function retireOwnedDirectoryMarker(
  target, targetIdentity, containmentRoot, rootIdentity, allocationId, markerName, markerBody,
) {
  if (!samePathIdentity(pathIdentity(target), targetIdentity)
    || !samePathIdentity(pathIdentity(containmentRoot), rootIdentity)) {
    throw new Error('object-bound marker retirement identity changed');
  }
  const source = configuredObjectBoundAllocationBroker();
  const python = process.platform === 'win32' ? null : '/usr/bin/python3';
  if (source === null || python === null || !fs.existsSync(python)) {
    throw new Error('OBJECT_BOUND_MARKER_RETIREMENT_UNAVAILABLE');
  }
  const request = {
    schema: 'environment-factory.object-bound-marker-retirement-request.v1',
    operation: 'retire-marker',
    allocation_id: allocationId,
    target: targetIdentity.realpath,
    target_identity: targetIdentity,
    containment_root: rootIdentity.realpath,
    containment_root_identity: rootIdentity,
    marker_name: markerName,
    marker_body: markerBody,
  };
  const environment = Object.create(null);
  for (const key of ['LANG', 'LC_ALL']) {
    if (typeof process.env[key] === 'string') environment[key] = process.env[key];
  }
  const result = spawnSync(python, ['-I', '-c', source], {
    input: stableStringify(request) + '\n',
    env: environment,
    shell: false,
    encoding: 'utf8',
    timeout: 30_000,
    maxBuffer: MAX_LOCK_METADATA_BYTES,
  });
  if (result.status !== 0) throw new Error('OBJECT_BOUND_MARKER_RETIREMENT_FAILED');
  let receipt;
  try { receipt = JSON.parse(String(result.stdout || '')); } catch (_error) {
    throw new Error('OBJECT_BOUND_MARKER_RETIREMENT_FAILED');
  }
  if (!receipt || receipt.schema !== 'environment-factory.object-bound-marker-retirement-receipt.v1'
    || receipt.status !== 'retired' || receipt.allocation_id !== allocationId
    || String(receipt.target_device) !== targetIdentity.device
    || String(receipt.target_inode) !== targetIdentity.inode
    || String(receipt.containment_root_device) !== rootIdentity.device
    || String(receipt.containment_root_inode) !== rootIdentity.inode
    || !samePathIdentity(pathIdentity(target), targetIdentity)
    || !samePathIdentity(pathIdentity(containmentRoot), rootIdentity)) {
    throw new Error('OBJECT_BOUND_MARKER_RETIREMENT_FAILED');
  }
}

function cleanupCaptureStatePath(captureId) {
  const durableRoot = requireOwnedDirectory(path.resolve(
    process.env.FKST_OBJECT_BOUND_CLEANUP_STATE_ROOT
      || process.env.FKST_DURABLE_ROOT
      || path.join('.testing', 'durable'),
  ));
  const stateRoot = requireOwnedDirectory(
    path.join(durableRoot, 'cleanup-captures'),
    { privateDirectory: true },
  );
  return path.join(stateRoot, `${captureId}.json`);
}

function cleanupCaptureBinding(target, expectedIdentity, containmentRoot, rootIdentity, captureId) {
  return {
    schema: CLEANUP_CAPTURE_SCHEMA,
    capture_id: captureId,
    target,
    target_identity: expectedIdentity,
    containment_root: containmentRoot,
    containment_root_identity: rootIdentity,
  };
}

function ownedDirectoryReleaseProven(target, expectedIdentity, containmentRoot, captureId) {
  if (typeof target !== 'string' || typeof containmentRoot !== 'string'
    || !/^[0-9a-f]{64}$/.test(String(captureId || ''))) return false;
  try {
    const root = fs.realpathSync(containmentRoot);
    const requestedTarget = path.resolve(target);
    const targetParent = fs.realpathSync(path.dirname(requestedTarget));
    const canonicalTarget = path.join(targetParent, path.basename(requestedTarget));
    if (!expectedIdentity || targetParent !== root || expectedIdentity.realpath !== canonicalTarget
      || canonicalTarget === root || !canonicalTarget.startsWith(`${root}${path.sep}`)) return false;
    const binding = cleanupCaptureBinding(
      canonicalTarget, expectedIdentity, root, pathIdentity(root), captureId,
    );
    const state = readOptionalJson(cleanupCaptureStatePath(captureId));
    return state !== null
      && stableStringify(state) === stableStringify({ ...binding, state: 'released' })
      && !pathEntryExists(canonicalTarget);
  } catch (_error) {
    return false;
  }
}

function readOptionalJson(filePath) {
  try {
    return readJson(filePath);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

function removeOwnedDirectory(target, expectedIdentity, containmentRoot, captureId) {
  if (typeof target !== 'string' || typeof containmentRoot !== 'string') {
    throw new Error('owned directory paths are invalid');
  }
  if (!/^[0-9a-f]{64}$/.test(String(captureId || ''))) {
    throw new Error('owned directory cleanup capture identity is invalid');
  }
  const root = fs.realpathSync(containmentRoot);
  const requestedTarget = path.resolve(target);
  const targetParent = fs.realpathSync(path.dirname(requestedTarget));
  const targetName = path.basename(requestedTarget);
  const canonicalTarget = path.join(targetParent, targetName);
  if (!expectedIdentity || targetParent !== root || expectedIdentity.realpath !== canonicalTarget) {
    throw new Error('owned directory cleanup identity is malformed');
  }
  if (expectedIdentity.realpath === root || !expectedIdentity.realpath.startsWith(`${root}${path.sep}`)) {
    throw new Error('owned directory escaped containment root');
  }
  const rootIdentity = pathIdentity(root);
  target = canonicalTarget;
  const binding = cleanupCaptureBinding(target, expectedIdentity, root, rootIdentity, captureId);
  const statePath = cleanupCaptureStatePath(captureId);
  const release = acquireLock(`${statePath}.lock`);
  try {
    let state = readOptionalJson(statePath);
    if (state === null) {
      if (!pathEntryExists(target)) return false;
      const identity = pathIdentity(target);
      if (!samePathIdentity(identity, expectedIdentity)) {
        throw new Error('owned directory identity changed');
      }
      state = { ...binding, state: 'pending' };
      writeJsonAtomic(statePath, state);
    } else {
      const expected = { ...binding, state: state.state };
      if (stableStringify(state) !== stableStringify(expected)
        || !['pending', 'captured-cleaned', 'finalized', 'released'].includes(state.state)) {
        throw new Error('owned directory cleanup capture binding differs');
      }
    }
    if (state.state === 'pending') {
      const captured = invokeObjectBoundCleanupBroker(
        binding.target, binding.target_identity, binding.containment_root,
        binding.containment_root_identity, captureId, 'capture-delete',
      );
      if (captured === null) return false;
      state = { ...binding, state: 'captured-cleaned' };
      writeJsonAtomic(statePath, state);
    }
    if (state.state === 'captured-cleaned') {
      const finalized = invokeObjectBoundCleanupBroker(
        binding.target, binding.target_identity, binding.containment_root,
        binding.containment_root_identity, captureId, 'finalize',
      );
      if (finalized === null) return false;
      state = { ...binding, state: 'finalized' };
      writeJsonAtomic(statePath, state);
    }
    if (state.state === 'finalized') {
      const released = invokeObjectBoundCleanupBroker(
        binding.target, binding.target_identity, binding.containment_root,
        binding.containment_root_identity, captureId, 'release-proof',
      );
      if (released === null) return false;
      state = { ...binding, state: 'released' };
      writeJsonAtomic(statePath, state);
    }
    return state.state === 'released' && !pathEntryExists(target);
  } finally {
    release();
  }
}

function readLockOwner(lockPath) {
  try {
    const lockIdentity = lockPathIdentity(lockPath);
    const lockStat = fs.lstatSync(lockPath);
    const ownerPath = lockStat.isDirectory() ? path.join(lockPath, 'owner.json') : lockPath;
    const metadata = readBoundedRegularFile(ownerPath, MAX_LOCK_METADATA_BYTES);
    if (!lockPathStillMatches(lockPath, lockIdentity)
      || (!lockStat.isDirectory() && !samePathIdentity(lockIdentity, metadata.identity))) return null;
    const owner = JSON.parse(metadata.body);
    if (!owner || owner.schema !== 'environment-factory.lock-owner.v1'
      || !Number.isInteger(owner.pid) || owner.pid < 1
      || typeof owner.process_start_identity !== 'string' || owner.process_start_identity === ''
      || typeof owner.token !== 'string' || owner.token === '') return null;
    return owner;
  } catch (_error) { return null; }
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

function lockPathIdentity(lockPath) {
  const stat = fs.lstatSync(lockPath);
  if ((!stat.isDirectory() && !stat.isFile()) || stat.isSymbolicLink()) {
    throw new Error(`lock path is not a real file or directory: ${lockPath}`);
  }
  return pathIdentity(lockPath);
}

function lockPathStillMatches(lockPath, expectedIdentity) {
  try {
    return samePathIdentity(lockPathIdentity(lockPath), expectedIdentity);
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

function sameObjectIdentity(left, right) {
  return Boolean(left && right && left.device === right.device && left.inode === right.inode);
}

function createLockQuarantine(filePath) {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const root = `${filePath}.retired-${process.pid}-${crypto.randomBytes(16).toString('hex')}`;
    try {
      fs.mkdirSync(root, { mode: 0o700 });
      return { root, entry: path.join(root, 'entry') };
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
  }
  throw new Error(`could not allocate private lock quarantine: ${filePath}`);
}

function restoreQuarantinedLockEntry(filePath, quarantine) {
  const movedStat = fs.lstatSync(quarantine.entry);
  if (!movedStat.isFile() || movedStat.isSymbolicLink()) {
    throw new Error(`lock replacement retained in quarantine: ${quarantine.entry}`);
  }
  try {
    fs.linkSync(quarantine.entry, filePath);
  } catch (error) {
    if (error.code === 'EEXIST') {
      throw new Error(`lock replacement could not be restored; retained in quarantine: ${quarantine.entry}`);
    }
    throw error;
  }
  const restored = pathIdentity(filePath);
  const moved = pathIdentity(quarantine.entry);
  if (!sameObjectIdentity(restored, moved)) {
    throw new Error(`restored lock replacement identity differs; retained in quarantine: ${quarantine.entry}`);
  }
  fs.unlinkSync(quarantine.entry);
  fs.rmdirSync(quarantine.root);
}

function retireObservedLockFile(filePath, observed) {
  const quarantine = createLockQuarantine(filePath);
  try {
    fs.renameSync(filePath, quarantine.entry);
  } catch (error) {
    fs.rmdirSync(quarantine.root);
    if (error.code === 'ENOENT') return false;
    throw error;
  }

  let moved;
  try {
    moved = readBoundedRegularFile(quarantine.entry, MAX_LOCK_METADATA_BYTES);
  } catch (_error) {
    restoreQuarantinedLockEntry(filePath, quarantine);
    return false;
  }
  if (!sameObjectIdentity(moved.identity, observed.identity) || moved.body !== observed.body) {
    restoreQuarantinedLockEntry(filePath, quarantine);
    return false;
  }
  fs.unlinkSync(quarantine.entry);
  fs.rmdirSync(quarantine.root);
  return true;
}

function removeLockPath(lockPath, expectedIdentity, expectedOwner) {
  const stat = fs.lstatSync(lockPath);
  if (stat.isDirectory()) {
    const error = new Error(`legacy lock directory cleanup requires an object-bound broker: ${lockPath}`);
    error.code = 'OBJECT_BOUND_CLEANUP_UNAVAILABLE';
    throw error;
  }
  const observed = readBoundedRegularFile(lockPath, MAX_LOCK_METADATA_BYTES);
  if (!sameObjectIdentity(observed.identity, expectedIdentity)
    || observed.body !== lockOwnerBody(expectedOwner)) return false;
  return retireObservedLockFile(lockPath, observed);
}

function lockOwnerBody(owner) {
  return `${stableStringify(owner)}\n`;
}

function pendingLockOwnerPath(lockPath, owner) {
  return `${lockPath}.owner.${owner.pid}.${owner.token}`;
}

function removeMatchingPendingLockOwner(lockPath, owner) {
  const pendingPath = pendingLockOwnerPath(lockPath, owner);
  try {
    const metadata = readBoundedRegularFile(pendingPath, MAX_LOCK_METADATA_BYTES);
    if (metadata.body !== lockOwnerBody(owner)
      || !samePathIdentity(pathIdentity(pendingPath), metadata.identity)) return false;
    return retireObservedLockFile(pendingPath, metadata);
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

function createAtomicLock(lockPath, identity) {
  const owner = {
    schema: 'environment-factory.lock-owner.v1',
    pid: process.pid,
    process_start_identity: identity,
    token: crypto.randomBytes(16).toString('hex'),
  };
  const ownerBody = lockOwnerBody(owner);
  const pendingPath = pendingLockOwnerPath(lockPath, owner);
  try {
    fs.writeFileSync(pendingPath, ownerBody, { flag: 'wx', mode: 0o600 });
    fs.linkSync(pendingPath, lockPath);
  } catch (error) {
    try { fs.unlinkSync(pendingPath); } catch (_cleanupError) {}
    throw error;
  }
  const lockIdentity = lockPathIdentity(lockPath);
  if (readLockOwner(lockPath) === null || fs.readFileSync(lockPath, 'utf8') !== ownerBody) {
    try { removeLockPath(lockPath, lockIdentity, owner); } catch (_cleanupError) {}
    try { fs.unlinkSync(pendingPath); } catch (_cleanupError) {}
    throw new Error(`atomic lock publication failed: ${lockPath}`);
  }
  try {
    fs.unlinkSync(pendingPath);
  } catch (error) {
    try { removeLockPath(lockPath, lockIdentity, owner); } catch (_cleanupError) {}
    throw error;
  }
  let released = false;
  return {
    owner,
    lockIdentity,
    release() {
      if (released) return;
      const recorded = readLockOwner(lockPath);
      if (sameLockOwner(recorded, owner)
        && samePathIdentity(lockPathIdentity(lockPath), lockIdentity)) {
        removeLockPath(lockPath, lockIdentity, owner);
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
  for (const key of [
    'FKST_OBJECT_BOUND_CLEANUP_BROKER',
    'FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256',
  ]) {
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
      const marker = JSON.parse(readBoundedRegularFile(markerPath, MAX_LOCK_METADATA_BYTES).body);
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
      const acquired = createAtomicLock(lockPath, identity);
      if (fs.existsSync(takeoverMarkerPath)) {
        acquired.release();
        continue;
      }
      return acquired.release;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
    let observedIdentity;
    try {
      observedIdentity = lockPathIdentity(lockPath);
    } catch (error) {
      if (error.code === 'ENOENT') continue;
      throw error;
    }
    let observedOwner = readLockOwner(lockPath);
    if (observedOwner === null) {
      if (!lockPathStillMatches(lockPath, observedIdentity)) continue;
      sleep(10);
      if (!lockPathStillMatches(lockPath, observedIdentity)) continue;
      observedOwner = readLockOwner(lockPath);
      if (observedOwner !== null) continue;
      if (!lockPathStillMatches(lockPath, observedIdentity)) continue;
      throw new Error(`ownerless or malformed lock cannot be recovered safely: ${lockPath}`);
    }
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
          const confirmedOwner = readLockOwner(lockPath);
          if (sameLockOwner(confirmedOwner, observedOwner)
            && lockPathStillMatches(lockPath, observedIdentity)
            && lockOwnerIsStale(confirmedOwner)) {
            if (!removeLockPath(lockPath, observedIdentity, confirmedOwner)) continue;
            removeMatchingPendingLockOwner(lockPath, confirmedOwner);
            while (true) {
              try {
                const acquired = createAtomicLock(lockPath, identity);
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
    'FKST_WORKER_RUNTIME_ROOT',
    'FKST_OBJECT_BOUND_ALLOCATION_BROKER', 'FKST_OBJECT_BOUND_ALLOCATION_BROKER_SHA256',
    'FKST_OBJECT_BOUND_CLEANUP_BROKER', 'FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256',
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

function workerEnvironmentInputs(extra, isolationKey) {
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
  return { env, identityBody: stableStringify(identity) };
}

function workerEnvironmentRoots() {
  const configuredRuntimeRoot = path.resolve(
    process.env.FKST_WORKER_RUNTIME_ROOT
      || process.env.FKST_RUNTIME_ROOT
      || path.join('.testing', 'runtime'),
  );
  fs.mkdirSync(configuredRuntimeRoot, { recursive: true, mode: 0o700 });
  const runtimeRoot = requireOwnedDirectory(configuredRuntimeRoot, { privateDirectory: true });
  const homesRoot = requireOwnedDirectory(path.join(runtimeRoot, 'worker-homes'), { privateDirectory: true });
  return { runtimeRoot, homesRoot };
}

function workerHomeMarker(identitySha256, leaseId) {
  return `${stableStringify({
    schema: 'fkst.worker-home-identity.v1',
    identity_sha256: identitySha256,
    lease_id: leaseId,
  })}\n`;
}

function buildWorkerEnvironmentReservation(identityBody, homesRoot, reservationId) {
  if (reservationId !== null && !/^[0-9a-f]{32}$/.test(String(reservationId))) {
    throw new Error('worker environment reservation is invalid');
  }
  const identitySha256 = sha256(identityBody);
  const leaseId = reservationId || crypto.randomBytes(16).toString('hex');
  const home = path.join(homesRoot, `reserved-${leaseId}`);
  const marker = workerHomeMarker(identitySha256, leaseId);
  return {
    schema: 'fkst.worker-home-reservation.v1',
    lease_id: leaseId,
    home,
    homes_root: homesRoot,
    homes_root_identity: pathIdentity(homesRoot),
    marker_sha256: sha256(marker),
    identity_sha256: identitySha256,
    cleanup_capture_id: sha256(`worker-home-cleanup\0${marker}`),
  };
}

function workerEnvironmentReservation(extra, isolationKey, reservationId) {
  if (!/^[0-9a-f]{32}$/.test(String(reservationId || ''))) {
    throw new Error('durable worker environment reservation is invalid');
  }
  const { identityBody } = workerEnvironmentInputs(extra, isolationKey);
  const { homesRoot } = workerEnvironmentRoots();
  return buildWorkerEnvironmentReservation(identityBody, homesRoot, reservationId);
}

function reservationMatchesLease(reservation, lease) {
  return Boolean(reservation && lease
    && reservation.schema === 'fkst.worker-home-reservation.v1'
    && lease.schema === 'fkst.worker-home-lease.v1'
    && reservation.lease_id === lease.lease_id
    && reservation.home === lease.home
    && reservation.homes_root === lease.homes_root
    && samePathIdentity(reservation.homes_root_identity, lease.homes_root_identity)
    && reservation.marker_sha256 === lease.marker_sha256
    && reservation.identity_sha256 === lease.identity_sha256
    && reservation.cleanup_capture_id === lease.cleanup_capture_id);
}

function verifyWorkerEnvironmentReservation(reservation) {
  if (!reservation || reservation.schema !== 'fkst.worker-home-reservation.v1'
    || !/^[0-9a-f]{32}$/.test(String(reservation.lease_id || ''))
    || typeof reservation.home !== 'string' || !path.isAbsolute(reservation.home)
    || typeof reservation.homes_root !== 'string' || !path.isAbsolute(reservation.homes_root)
    || !/^[0-9a-f]{64}$/.test(String(reservation.marker_sha256 || ''))
    || !/^[0-9a-f]{64}$/.test(String(reservation.identity_sha256 || ''))
    || !/^[0-9a-f]{64}$/.test(String(reservation.cleanup_capture_id || ''))
    || path.dirname(reservation.home) !== reservation.homes_root
    || path.basename(reservation.home) !== `reserved-${reservation.lease_id}`
    || !samePathIdentity(pathIdentity(reservation.homes_root), reservation.homes_root_identity)) {
    throw new Error('worker environment reservation binding changed');
  }
  const marker = workerHomeMarker(reservation.identity_sha256, reservation.lease_id);
  if (sha256(marker) !== reservation.marker_sha256
    || sha256(`worker-home-cleanup\0${marker}`) !== reservation.cleanup_capture_id) {
    throw new Error('worker environment reservation marker binding changed');
  }
  return reservation;
}

function releaseWorkerEnvironmentReservation(reservation) {
  verifyWorkerEnvironmentReservation(reservation);
  // A missing pathname is not proof that allocation never published. The
  // directory may have been displaced before its inode-bearing lease was
  // durably recorded, so cleanup must retain the reservation for audit.
  if (!pathEntryExists(reservation.home)) return false;
  const marker = workerHomeMarker(reservation.identity_sha256, reservation.lease_id);
  const markerPath = path.join(reservation.home, '.fkst-worker-home.json');
  if (!pathEntryExists(markerPath)
    || readBoundedRegularFile(markerPath, MAX_LOCK_METADATA_BYTES).body !== marker) {
    throw new Error('worker environment reservation is not recoverable');
  }
  const lease = {
    schema: 'fkst.worker-home-lease.v1',
    lease_id: reservation.lease_id,
    home: reservation.home,
    home_identity: pathIdentity(reservation.home),
    homes_root: reservation.homes_root,
    homes_root_identity: reservation.homes_root_identity,
    marker_sha256: reservation.marker_sha256,
    identity_sha256: reservation.identity_sha256,
    cleanup_capture_id: reservation.cleanup_capture_id,
  };
  verifyWorkerEnvironmentLease(lease);
  return releaseWorkerEnvironmentLease(lease);
}

function minimalEnvironment(extra = {}, isolationKey = 'shared-runtime-command', reservationId = null, hooks = {}) {
  const { env, identityBody } = workerEnvironmentInputs(extra, isolationKey);
  const { homesRoot } = workerEnvironmentRoots();
  const reservation = buildWorkerEnvironmentReservation(identityBody, homesRoot, reservationId);
  const identitySha256 = reservation.identity_sha256;
  const leaseId = reservation.lease_id;
  const home = reservation.home;
  const marker = workerHomeMarker(identitySha256, leaseId);
  const homeIdentity = allocateOwnedDirectory(
    home,
    reservation.homes_root,
    reservation.homes_root_identity,
    reservation.cleanup_capture_id,
    '.fkst-worker-home.json',
    marker,
    ['.config', '.config/gh'],
  );
  if (typeof hooks.afterHomeDirectoryCreated === 'function') {
    hooks.afterHomeDirectoryCreated({ home, reservation: { ...reservation } });
  }
  if (!samePathIdentity(pathIdentity(home), homeIdentity)) {
    throw new Error('worker environment home identity changed after allocation');
  }
  const configHome = path.join(home, '.config');
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
      lease_id: leaseId,
      home,
      home_identity: homeIdentity,
      homes_root: homesRoot,
      homes_root_identity: pathIdentity(homesRoot),
      marker_sha256: sha256(marker),
      identity_sha256: identitySha256,
      cleanup_capture_id: reservation.cleanup_capture_id,
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
    lease_id: lease.lease_id,
    home: lease.home,
    home_identity: { ...lease.home_identity },
    homes_root: lease.homes_root,
    homes_root_identity: { ...lease.homes_root_identity },
    marker_sha256: lease.marker_sha256,
    identity_sha256: lease.identity_sha256,
    cleanup_capture_id: lease.cleanup_capture_id,
  };
}

function verifyWorkerEnvironmentLease(lease) {
  if (!lease || lease.schema !== 'fkst.worker-home-lease.v1'
    || typeof lease.lease_id !== 'string' || !/^[0-9a-f]{32}$/.test(lease.lease_id)
    || typeof lease.home !== 'string' || typeof lease.homes_root !== 'string'
    || !/^[0-9a-f]{64}$/.test(String(lease.cleanup_capture_id || ''))) {
    throw new Error('worker environment lease identity changed');
  }
  let identitiesMatch = false;
  try {
    identitiesMatch = samePathIdentity(pathIdentity(lease.homes_root), lease.homes_root_identity)
      && samePathIdentity(pathIdentity(lease.home), lease.home_identity);
  } catch (_error) {}
  if (!identitiesMatch) throw new Error('worker environment lease identity changed');
  const root = fs.realpathSync(lease.homes_root);
  const home = fs.realpathSync(lease.home);
  if (!home.startsWith(`${root}${path.sep}`)) throw new Error('worker environment home escaped its lease root');
  const markerPath = path.join(home, '.fkst-worker-home.json');
  const marker = readBoundedRegularFile(markerPath, MAX_LOCK_METADATA_BYTES).body;
  if (sha256(marker) !== lease.marker_sha256) throw new Error('worker environment marker changed');
  const value = JSON.parse(marker);
  if (value.schema !== 'fkst.worker-home-identity.v1'
    || value.identity_sha256 !== lease.identity_sha256
    || value.lease_id !== lease.lease_id) {
    throw new Error('worker environment marker binding changed');
  }
  if (lease.cleanup_capture_id !== sha256(`worker-home-cleanup\0${marker}`)) {
    throw new Error('worker environment cleanup capture binding changed');
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
  if (pathEntryExists(lease.home)) verifyWorkerEnvironmentLease(lease);
  return removeOwnedDirectory(
    lease.home, lease.home_identity, lease.homes_root, lease.cleanup_capture_id,
  );
}

function workerEnvironmentReleaseProven(lease) {
  if (!lease || lease.schema !== 'fkst.worker-home-lease.v1') return false;
  return ownedDirectoryReleaseProven(
    lease.home, lease.home_identity, lease.homes_root, lease.cleanup_capture_id,
  );
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
  if (options.env === undefined) throw new Error('commandResult requires a durable worker environment');
  verifyWorkerEnvironment(options.env);
  const result = spawnSync(argv[0], argv.slice(1), {
    cwd: options.cwd, env: options.env, shell: false, encoding: 'utf8',
    timeout: Math.max(1, Number(options.timeoutMs) || 30_000), maxBuffer: outputBytes,
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
  OBJECT_BOUND_CLEANUP_UNAVAILABLE,
  acquireLock,
  allocateOwnedDirectory,
  artifactPath,
  authorizationArtifact,
  boundedText,
  commandResult,
  isSafeArtifactPath,
  minimalEnvironment,
  ownedDirectoryReleaseProven,
  parseArgs,
  pathEntryExists,
  pathIdentity,
  processAlive,
  processStartIdentity,
  readJson,
  readBoundedRegularFile,
  requireOwnedDirectory,
  removeOwnedDirectory,
  retireOwnedDirectoryMarker,
  releaseWorkerEnvironment,
  releaseWorkerEnvironmentLease,
  releaseWorkerEnvironmentReservation,
  reservationMatchesLease,
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
  verifyWorkerEnvironmentReservation,
  workerEnvironmentReservation,
  workerEnvironmentLease,
  workerEnvironmentReleaseProven,
  writeJsonAtomic,
  writeJsonImmutable,
};
