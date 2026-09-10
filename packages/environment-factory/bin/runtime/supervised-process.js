'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const {
  acquireLock,
  boundedText,
  processAlive,
  processStartIdentity,
  releaseWorkerEnvironmentLease,
  sha256,
  sleep,
  stableStringify,
  validateArgv,
  verifyWorkerEnvironment,
  verifyWorkerEnvironmentLease,
  workerEnvironmentLease,
  writeJsonAtomic,
} = require('./common');

const CLAIM_SCHEMA = 'fkst.supervised-process-startup.v1';
const SPEC_SCHEMA = 'fkst.supervised-process-launch.v1';
const MAX_METADATA_BYTES = 2 * 1024 * 1024;

function readDescriptorBounded(descriptor, label) {
  const buffer = Buffer.allocUnsafe(MAX_METADATA_BYTES + 1);
  let length = 0;
  while (length < buffer.length) {
    const count = fs.readSync(descriptor, buffer, length, buffer.length - length, null);
    if (count === 0) break;
    length += count;
  }
  if (length > MAX_METADATA_BYTES) throw new Error(`${label} exceeds its read bound`);
  return buffer.subarray(0, length);
}

function readIfExists(filePath) {
  try {
    return readJsonNoFollow(filePath);
  } catch (error) {
    if (error && error.code === 'ENOENT') return null;
    throw error;
  }
}

function readJsonNoFollow(filePath) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const before = fs.lstatSync(filePath);
    if (!before.isFile() || before.isSymbolicLink() || before.size > MAX_METADATA_BYTES) {
      throw new Error('supervised startup claim is not a bounded regular file');
    }
    const descriptor = fs.openSync(filePath, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    try {
      const openedBefore = fs.fstatSync(descriptor);
      if (!sameFileIdentity(fileIdentity(before), fileIdentity(openedBefore))) {
        sleep(2);
        continue;
      }
      const body = readDescriptorBounded(descriptor, 'supervised startup claim');
      const openedAfter = fs.fstatSync(descriptor);
      const after = fs.lstatSync(filePath);
      if (!sameFileIdentity(fileIdentity(openedBefore), fileIdentity(openedAfter))
        || !sameFileIdentity(fileIdentity(openedAfter), fileIdentity(after))) {
        sleep(2);
        continue;
      }
      return JSON.parse(body.toString('utf8'));
    } finally {
      fs.closeSync(descriptor);
    }
  }
  throw new Error('supervised startup claim did not stabilize while reading');
}

function writeClaimAtomic(filePath, value) {
  writeJsonAtomic(filePath, value);
  fs.chmodSync(filePath, 0o600);
}

function requireAbsoluteFile(filePath, label) {
  if (typeof filePath !== 'string' || !path.isAbsolute(filePath) || path.basename(filePath) === '') {
    throw new Error(`${label} must be an absolute file path`);
  }
  return path.resolve(filePath);
}

function validClaim(claim, bindingSha256) {
  const state = claim && claim.state;
  const leasePending = state === 'allocating';
  return Boolean(claim && claim.schema === CLAIM_SCHEMA && claim.version === 1
    && /^[0-9a-f]{32}$/.test(String(claim.startup_token || ''))
    && claim.binding_sha256 === bindingSha256
    && Number.isInteger(claim.created_at_epoch_ms)
    && Number.isInteger(claim.registration_deadline_epoch_ms)
    && typeof claim.launch_spec_path === 'string'
    && /^[0-9a-f]{64}$/.test(String(claim.launch_spec_sha256 || ''))
    && /^[0-9a-f]{64}$/.test(String(claim.argv_sha256 || ''))
    && typeof claim.cwd === 'string' && path.isAbsolute(claim.cwd)
    && claim.cwd_identity && typeof claim.cwd_identity === 'object'
    && Number.isInteger(claim.inherited_fd_count) && claim.inherited_fd_count >= 0
    && Array.isArray(claim.inherited_fd_identities)
    && claim.inherited_fd_identities.length === claim.inherited_fd_count
    && claim.worker_environment_reservation
    && claim.worker_environment_reservation.schema === 'fkst.worker-home-reservation.v1'
    && claim.worker_environment_reservation.reservation_id === claim.startup_token
    && claim.worker_environment_reservation.binding_sha256 === sha256(stableStringify({
      binding_sha256: claim.binding_sha256,
      argv_sha256: claim.argv_sha256,
      cwd: claim.cwd,
      inherited_fd_identities: claim.inherited_fd_identities,
    }))
    && (leasePending
      ? claim.worker_environment_lease === null && claim.worker_environment_lease_sha256 === null
      : claim.worker_environment_lease
        && /^[0-9a-f]{64}$/.test(String(claim.worker_environment_lease_sha256 || '')))
    && ['allocating', 'preparing', 'prepared', 'registered', 'running', 'exited', 'failed', 'revoked'].includes(state)
    && (state === 'allocating' || state === 'preparing' || sameFileIdentityShape(claim.launch_spec_identity)));
}

function sameFileIdentityShape(identity) {
  return Boolean(identity && typeof identity === 'object'
    && typeof identity.device === 'string' && typeof identity.inode === 'string'
    && Number.isInteger(identity.size) && identity.size >= 0
    && Number.isInteger(identity.mode));
}

function fileIdentity(stat) {
  return {
    device: String(stat.dev),
    inode: String(stat.ino),
    size: stat.size,
    mode: stat.mode,
  };
}

function sameFileIdentity(left, right) {
  return sameFileIdentityShape(left) && sameFileIdentityShape(right)
    && left.device === right.device && left.inode === right.inode
    && left.size === right.size && left.mode === right.mode;
}

function sameNodeIdentity(left, right) {
  return sameFileIdentityShape(left) && sameFileIdentityShape(right)
    && left.device === right.device && left.inode === right.inode
    && (left.mode & fs.constants.S_IFMT) === (right.mode & fs.constants.S_IFMT);
}

function descriptorIdentities(descriptors) {
  return descriptors.map((descriptor) => fileIdentity(fs.fstatSync(descriptor)));
}

function readBoundFile(filePath, expectedIdentity) {
  const before = fs.lstatSync(filePath);
  if (!before.isFile() || before.isSymbolicLink() || before.size > MAX_METADATA_BYTES
    || expectedIdentity.size > MAX_METADATA_BYTES) {
    throw new Error('supervised launch spec is not a regular file');
  }
  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0);
  const descriptor = fs.openSync(filePath, flags);
  try {
    const openedBefore = fs.fstatSync(descriptor);
    if (!sameFileIdentity(fileIdentity(before), fileIdentity(openedBefore))
      || !sameFileIdentity(fileIdentity(openedBefore), expectedIdentity)) {
      throw new Error('supervised launch spec identity changed');
    }
    const body = readDescriptorBounded(descriptor, 'supervised launch spec');
    const openedAfter = fs.fstatSync(descriptor);
    const after = fs.lstatSync(filePath);
    if (!sameFileIdentity(fileIdentity(openedBefore), fileIdentity(openedAfter))
      || !sameFileIdentity(fileIdentity(openedAfter), fileIdentity(after))) {
      throw new Error('supervised launch spec changed while reading');
    }
    return body;
  } finally {
    fs.closeSync(descriptor);
  }
}

function publishLaunchSpecNoReplace(filePath, body) {
  const pendingPath = `${filePath}.pending.${process.pid}.${crypto.randomBytes(16).toString('hex')}`;
  let pendingCreated = false;
  try {
    fs.writeFileSync(pendingPath, body, { flag: 'wx', mode: 0o600 });
    pendingCreated = true;
    try {
      fs.linkSync(pendingPath, filePath);
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
  } finally {
    if (pendingCreated) {
      try { fs.unlinkSync(pendingPath); } catch (_error) {}
    }
  }
  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_METADATA_BYTES) {
    throw new Error('supervised launch spec is not a bounded regular file');
  }
  const identity = fileIdentity(stat);
  if (!readBoundFile(filePath, identity).equals(Buffer.from(body))) {
    throw new Error('supervised launch spec immutable content differs');
  }
  return identity;
}

function transitionClaim(claimPath, token, allowedStates, update) {
  const release = acquireLock(`${claimPath}.lock`);
  try {
    const current = readJsonNoFollow(claimPath);
    if (current.schema !== CLAIM_SCHEMA || current.startup_token !== token) return false;
    if (!allowedStates.includes(current.state)) return false;
    writeClaimAtomic(claimPath, { ...current, ...update });
    return true;
  } finally {
    release();
  }
}

function resourceFromClaim(binding, claim) {
  return {
    ...binding,
    startup_state: claim.state,
    startup_token_sha256: sha256(claim.startup_token),
    pid: Number.isInteger(claim.pid) ? claim.pid : null,
    pgid: Number.isInteger(claim.pgid) ? claim.pgid : null,
    process_start_identity: typeof claim.process_start_identity === 'string'
      ? claim.process_start_identity : null,
    worker_environment_lease: claim.worker_environment_lease,
  };
}

function startOrRecoverSupervisedProcess(options) {
  const claimPath = requireAbsoluteFile(options.claimPath, 'supervised startup claim');
  const argv = validateArgv(options.argv);
  const cwd = fs.realpathSync(path.resolve(options.cwd));
  const cwdIdentity = (() => {
    const stat = fs.statSync(cwd);
    if (!stat.isDirectory()) throw new Error('supervised process cwd is not a directory');
    return fileIdentity(stat);
  })();
  const binding = options.binding;
  if (!binding || typeof binding !== 'object' || Array.isArray(binding)) {
    throw new Error('supervised process binding is invalid');
  }
  const bindingSha256 = sha256(stableStringify(binding));
  const inheritedStdio = Array.isArray(options.inheritedStdio) ? options.inheritedStdio : [];
  if (inheritedStdio.some((fd, index) => !Number.isInteger(fd) || fd !== index + 3)) {
    throw new Error('supervised inherited descriptors are invalid');
  }
  const inheritedFdIdentities = descriptorIdentities(inheritedStdio);
  const registrationTimeoutMs = Math.max(250, Math.min(Number(options.registrationTimeoutMs) || 5_000, 30_000));
  let created = false;
  let suppliedLease = null;
  let environment = null;
  const release = acquireLock(`${claimPath}.lock`);
  try {
    let claim = readIfExists(claimPath);
    if (claim !== null && !validClaim(claim, bindingSha256)) {
      throw new Error('supervised startup claim binding differs');
    }
    if (claim === null) {
      const token = crypto.randomBytes(16).toString('hex');
      const launchSpecPath = `${claimPath}.launch-${token}.json`;
      const spec = {
        schema: SPEC_SCHEMA,
        startup_token: token,
        binding_sha256: bindingSha256,
        claim_path: claimPath,
        argv,
        cwd,
        inherited_fd_count: inheritedStdio.length,
        inherited_fd_identities: inheritedFdIdentities,
      };
      const specBody = `${stableStringify(spec)}\n`;
      const now = Date.now();
      const reservation = {
        schema: 'fkst.worker-home-reservation.v1',
        reservation_id: token,
        binding_sha256: sha256(stableStringify({
          binding_sha256: bindingSha256,
          argv_sha256: sha256(stableStringify(argv)),
          cwd,
          inherited_fd_identities: inheritedFdIdentities,
        })),
      };
      claim = {
        schema: CLAIM_SCHEMA,
        version: 1,
        state: 'allocating',
        startup_token: token,
        binding_sha256: bindingSha256,
        created_at_epoch_ms: now,
        registration_deadline_epoch_ms: now + registrationTimeoutMs,
        launch_spec_path: launchSpecPath,
        launch_spec_sha256: sha256(specBody),
        launch_spec_identity: null,
        argv_sha256: sha256(stableStringify(argv)),
        cwd,
        cwd_identity: cwdIdentity,
        inherited_fd_count: inheritedStdio.length,
        inherited_fd_identities: inheritedFdIdentities,
        worker_environment_reservation: reservation,
        worker_environment_lease: null,
        worker_environment_lease_sha256: null,
        pid: null,
        pgid: null,
        process_start_identity: null,
      };
      fs.mkdirSync(path.dirname(claimPath), { recursive: true });
      if (typeof options.beforeClaimPersist === 'function') options.beforeClaimPersist();
      writeClaimAtomic(claimPath, claim);
    }
    if (claim.state === 'allocating' || claim.state === 'preparing') {
      if (options.environment || typeof options.createEnvironment !== 'function') {
        throw new Error('recoverable supervised process environment factory is required');
      }
      environment = options.createEnvironment({
        reservation_id: claim.worker_environment_reservation.reservation_id,
        binding_sha256: claim.worker_environment_reservation.binding_sha256,
      });
      if (!environment) throw new Error('supervised process environment is required for a new launch');
      verifyWorkerEnvironment(environment);
      suppliedLease = workerEnvironmentLease(environment);
      if (suppliedLease.lease_id !== claim.worker_environment_reservation.reservation_id) {
        releaseWorkerEnvironmentLease(suppliedLease);
        suppliedLease = null;
        throw new Error('supervised worker environment reservation differs');
      }
      if (claim.state === 'allocating') {
        if (typeof options.afterEnvironmentCreated === 'function'
          && options.afterEnvironmentCreated(environment, claim) === false) {
          return { interrupted: true, environment_retained: true };
        }
        claim = {
          ...claim,
          state: 'preparing',
          worker_environment_lease: suppliedLease,
          worker_environment_lease_sha256: sha256(stableStringify(suppliedLease)),
        };
        writeClaimAtomic(claimPath, claim);
      } else if (stableStringify(suppliedLease) !== stableStringify(claim.worker_environment_lease)) {
        releaseWorkerEnvironmentLease(suppliedLease);
        suppliedLease = null;
        throw new Error('supervised worker environment lease differs');
      }
    }
    if (claim.state === 'preparing') {
      const spec = {
        schema: SPEC_SCHEMA,
        startup_token: claim.startup_token,
        binding_sha256: bindingSha256,
        claim_path: claimPath,
        argv,
        cwd,
        inherited_fd_count: inheritedStdio.length,
        inherited_fd_identities: inheritedFdIdentities,
      };
      const specBody = `${stableStringify(spec)}\n`;
      let launched = false;
      try {
        if (typeof options.beforeLaunchSpecPublish === 'function') {
          options.beforeLaunchSpecPublish(claim, specBody);
        }
        const launchSpecIdentity = publishLaunchSpecNoReplace(claim.launch_spec_path, specBody);
        claim = { ...claim, state: 'prepared', launch_spec_identity: launchSpecIdentity };
        writeClaimAtomic(claimPath, claim);
        if (typeof options.beforeSupervisorLaunch === 'function') options.beforeSupervisorLaunch(claim);
        const supervisor = spawn(process.execPath, [__filename, 'child', claim.launch_spec_path], {
          cwd,
          env: environment,
          shell: false,
          detached: true,
          stdio: ['ignore', 'ignore', 'ignore', ...inheritedStdio],
        });
        supervisor.once('error', () => {});
        supervisor.unref();
        launched = true;
        created = true;
        if (typeof options.afterLaunch === 'function' && options.afterLaunch(supervisor.pid) === false) {
          return { interrupted: true, environment_retained: true };
        }
      } catch (error) {
        if (!launched) {
          claim = {
            ...claim,
            state: 'revoked',
            failure_reason: 'supervisor-launch-failed',
            failed_at_epoch_ms: Date.now(),
          };
          writeClaimAtomic(claimPath, claim);
          if (suppliedLease) releaseWorkerEnvironmentLease(suppliedLease);
        }
        throw error;
      }
    }
  } finally {
    release();
  }

  const deadline = Date.now() + registrationTimeoutMs;
  while (Date.now() < deadline) {
    let claim = readJsonNoFollow(claimPath);
    if (!validClaim(claim, bindingSha256)) throw new Error('supervised startup claim binding differs');
    if (claim.state === 'registered' || claim.state === 'running') {
      verifyWorkerEnvironmentLease(claim.worker_environment_lease);
      if (!Number.isInteger(claim.pid) || claim.pid < 1
        || !processAlive(claim.pid)
        || processStartIdentity(claim.pid) !== claim.process_start_identity) {
        transitionClaim(claimPath, claim.startup_token, ['registered', 'running'], {
          state: 'failed',
          failure_reason: 'registered-process-unavailable',
          failed_at_epoch_ms: Date.now(),
        });
        claim = readJsonNoFollow(claimPath);
      }
    }
    if (claim.state !== 'preparing' && claim.state !== 'prepared' && claim.state !== 'registered') {
      if (claim.state !== 'revoked') verifyWorkerEnvironmentLease(claim.worker_environment_lease);
      return {
        interrupted: false,
        state: claim.state,
        resource: resourceFromClaim(binding, claim),
        environment_retained: created && suppliedLease && suppliedLease.home === claim.worker_environment_lease.home,
      };
    }
    sleep(25);
  }

  const revoke = acquireLock(`${claimPath}.lock`);
  let revoked;
  try {
    const claim = readJsonNoFollow(claimPath);
    if (!validClaim(claim, bindingSha256)) throw new Error('supervised startup claim binding differs');
    if (claim.state === 'preparing' || claim.state === 'prepared') {
      revoked = { ...claim, state: 'revoked', failure_reason: 'launcher-registration-timeout' };
      writeClaimAtomic(claimPath, revoked);
    } else {
      revoked = claim;
    }
  } finally {
    revoke();
  }
  if (revoked.state === 'revoked') releaseWorkerEnvironmentLease(revoked.worker_environment_lease);
  return {
    interrupted: false,
    state: revoked.state,
    resource: resourceFromClaim(binding, revoked),
    environment_retained: false,
  };
}

function childMain(specPath) {
  const absoluteSpec = requireAbsoluteFile(specPath, 'supervised launch spec');
  const claimPathGuess = absoluteSpec.replace(/\.launch-[0-9a-f]{32}\.json$/, '');
  if (claimPathGuess === absoluteSpec) throw new Error('supervised launch spec path is invalid');
  const initialClaim = readJsonNoFollow(claimPathGuess);
  if (!validClaim(initialClaim, initialClaim && initialClaim.binding_sha256)
    || initialClaim.state !== 'prepared' || initialClaim.launch_spec_path !== absoluteSpec) {
    throw new Error('supervised startup claim is unavailable or revoked');
  }
  const specBody = readBoundFile(absoluteSpec, initialClaim.launch_spec_identity);
  if (sha256(specBody) !== initialClaim.launch_spec_sha256) {
    throw new Error('supervised launch spec digest differs');
  }
  const spec = JSON.parse(specBody.toString('utf8'));
  if (!spec || spec.schema !== SPEC_SCHEMA || spec.claim_path !== claimPathGuess
    || spec.startup_token !== initialClaim.startup_token
    || spec.binding_sha256 !== initialClaim.binding_sha256
    || !Number.isInteger(spec.inherited_fd_count) || spec.inherited_fd_count < 0
    || spec.inherited_fd_count > 32
    || sha256(`${stableStringify(spec)}\n`) !== initialClaim.launch_spec_sha256
    || sha256(stableStringify(validateArgv(spec.argv))) !== initialClaim.argv_sha256
    || path.resolve(spec.cwd) !== initialClaim.cwd
    || !sameNodeIdentity(fileIdentity(fs.statSync(spec.cwd)), initialClaim.cwd_identity)
    || spec.inherited_fd_count !== initialClaim.inherited_fd_count
    || stableStringify(spec.inherited_fd_identities) !== stableStringify(initialClaim.inherited_fd_identities)
    || sha256(stableStringify(initialClaim.worker_environment_lease))
      !== initialClaim.worker_environment_lease_sha256) {
    throw new Error('supervised launch spec is invalid or unbound');
  }
  const actualFdIdentities = descriptorIdentities(
    Array.from({ length: spec.inherited_fd_count }, (_item, index) => index + 3),
  );
  if (stableStringify(actualFdIdentities) !== stableStringify(initialClaim.inherited_fd_identities)) {
    throw new Error('supervised inherited descriptor identity differs');
  }
  const claimPath = claimPathGuess;
  const release = acquireLock(`${claimPath}.lock`);
  let child;
  let inherited = [];
  const closeInherited = () => {
    for (const fd of inherited) {
      try { fs.closeSync(fd); } catch (_error) {}
    }
    inherited = [];
  };
  try {
    const claim = readJsonNoFollow(claimPath);
    if (!validClaim(claim, spec.binding_sha256) || claim.state !== 'prepared'
      || claim.startup_token !== spec.startup_token || claim.launch_spec_path !== absoluteSpec) {
      throw new Error('supervised startup claim is unavailable or revoked');
    }
    const identity = processStartIdentity(process.pid);
    if (identity === null) throw new Error('supervised process identity is unavailable');
    writeClaimAtomic(claimPath, {
      ...claim,
      state: 'registered',
      pid: process.pid,
      pgid: process.pid,
      process_start_identity: identity,
      registered_at_epoch_ms: Date.now(),
    });
    inherited = Array.from({ length: spec.inherited_fd_count }, (_item, index) => index + 3);
    child = spawn(validateArgv(spec.argv)[0], spec.argv.slice(1), {
      cwd: path.resolve(spec.cwd),
      env: process.env,
      shell: false,
      detached: false,
      stdio: ['ignore', 'ignore', 'ignore', ...inherited],
    });
    closeInherited();
    child.once('error', (error) => {
      transitionClaim(claimPath, spec.startup_token, ['registered', 'running'], {
        state: 'failed',
        failure_reason: boundedText(error && error.message, 256) || 'target-spawn-failed',
        failed_at_epoch_ms: Date.now(),
      });
      process.exitCode = 1;
    });
    writeClaimAtomic(claimPath, {
      ...readJsonNoFollow(claimPath),
      state: 'running',
      target_pid: child.pid,
      started_at_epoch_ms: Date.now(),
    });
  } finally {
    closeInherited();
    release();
  }
  child.once('exit', (code, signal) => {
    transitionClaim(claimPath, spec.startup_token, ['running'], {
      state: 'exited',
      exit_code: Number.isInteger(code) ? code : null,
      exit_signal: typeof signal === 'string' ? signal : null,
      exited_at_epoch_ms: Date.now(),
    });
    process.exitCode = Number.isInteger(code) ? code : 1;
  });
}

if (require.main === module) {
  if (process.argv.length !== 4 || process.argv[2] !== 'child') {
    process.stderr.write('supervised-process: expected child launch spec\n');
    process.exitCode = 2;
  } else {
    try {
      childMain(process.argv[3]);
    } catch (error) {
      process.stderr.write(`supervised-process: ${boundedText(error && error.message, 1024)}\n`);
      process.exitCode = 1;
    }
  }
}

module.exports = {
  CLAIM_SCHEMA,
  SPEC_SCHEMA,
  startOrRecoverSupervisedProcess,
};
