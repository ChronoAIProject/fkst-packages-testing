'use strict';

const assert = require('assert');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const {
  acquireLock,
  authorizationArtifact,
  minimalEnvironment,
  releaseWorkerEnvironment,
  releaseWorkerEnvironmentLease,
  stableStringify,
  verifyWorkerEnvironment,
  workerEnvironmentLease,
} = require('../bin/runtime/common');
const { validateTargetExecutionBoundary } = require('../bin/runtime/target-execution-boundary');
const { startOrRecoverSupervisedProcess } = require('../bin/runtime/supervised-process');
const { runMeasuredCommand } = require('../bin/runtime/measured-command');
const {
  listenersOwnedByProcessGroup,
  processGroupState,
  terminateProcessGroup,
} = require('../bin/runtime/platform');
const { dispatch, initialReadinessState, sha256 } = require('../bin/environment-factory-runtime');

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function removeTreeEventually(target, timeoutMs = 2_000) {
  const deadline = Date.now() + timeoutMs;
  while (true) {
    try {
      fs.rmSync(target, { recursive: true, force: true });
      return;
    } catch (error) {
      if (!['ENOTEMPTY', 'EEXIST'].includes(error && error.code) || Date.now() >= deadline) throw error;
      await delay(10);
    }
  }
}

function stopGroup(child) {
  if (!child || !Number.isInteger(child.pid)) return;
  try { process.kill(-child.pid, 'SIGKILL'); } catch (_error) {
    try { process.kill(child.pid, 'SIGKILL'); } catch (_ignored) {}
  }
}

async function spawnListener(addresses, temp) {
  const readyPath = path.join(temp, `listener-${process.pid}-${Date.now()}-${Math.random()}.json`);
  const source = `
    const fs = require('fs');
    const net = require('net');
    const addresses = JSON.parse(process.argv[1]);
    const readyPath = process.argv[2];
    const ports = new Array(addresses.length);
    let remaining = addresses.length;
    const publish = (value) => {
      const pendingPath = readyPath + '.tmp';
      fs.writeFileSync(pendingPath, JSON.stringify(value));
      fs.renameSync(pendingPath, readyPath);
    };
    const fail = (error) => {
      publish({ error: error.message });
      process.exit(1);
    };
    addresses.forEach((address, index) => {
      const server = net.createServer();
      server.once('error', fail);
      server.listen(0, address, () => {
        ports[index] = server.address().port;
        remaining -= 1;
        if (remaining === 0) publish({ ports });
      });
    });
    setInterval(() => {}, 1000);
  `;
  const child = spawn(process.execPath, ['-e', source, JSON.stringify(addresses), readyPath], {
    detached: true,
    stdio: 'ignore',
  });
  child.unref();
  const deadline = Date.now() + 5_000;
  while (!fs.existsSync(readyPath)) {
    if (Date.now() >= deadline) {
      stopGroup(child);
      throw new Error(`listener readiness timed out: ${readyPath}`);
    }
    await delay(10);
  }
  const ready = JSON.parse(fs.readFileSync(readyPath, 'utf8'));
  fs.rmSync(readyPath, { force: true });
  if (ready.error) {
    stopGroup(child);
    throw new Error(`listener startup failed: ${ready.error}`);
  }
  return { child, ports: ready.ports };
}

async function main() {
  assert.throws(() => stableStringify({ value: undefined }), /rejects undefined/);
  assert.throws(() => stableStringify([undefined]), /rejects undefined/);
  assert.throws(() => stableStringify({ value: () => true }), /rejects function/);
  assert.strictEqual(stableStringify({ b: 2, a: 1 }), '{"a":1,"b":2}');

  const networkCheck = [{ type: 'http' }];
  assert.deepStrictEqual(initialReadinessState({ network_requests: 0 }, networkCheck), {
    attempts: 0, probes: 0, reason: 'network-request-budget-exceeded',
  });
  assert.deepStrictEqual(initialReadinessState({ network_requests: 1 }, networkCheck), {
    attempts: 0, probes: 0, reason: null,
  });
  assert.deepStrictEqual(initialReadinessState({ network_requests: 100000 }, networkCheck), {
    attempts: 0, probes: 0, reason: null,
  });
  assert.deepStrictEqual(initialReadinessState({ network_requests: 0 }, [{ type: 'argv' }]), {
    attempts: 0, probes: 0, reason: null,
  });

  const source = { kind: 'artifact', ref: '.testing/runs/op/profile.json' };
  assert.throws(() => authorizationArtifact({ authorization_sources: [] }, source), /not materialized/);
  assert.deepStrictEqual(authorizationArtifact({
    authorization_sources: [{ source_ref: source, artifact_ref: source }],
  }, source), source);

  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'environment-runtime-node-test-'));
  const artifactRoot = `.testing/runs/environment-node-runtime-${process.pid}`;
  const hostRoot = `.testing/host/environment-factory/environment-node-runtime-${process.pid}`;
  const previousDurable = process.env.FKST_DURABLE_ROOT;
  const previousRuntime = process.env.FKST_RUNTIME_ROOT;
  process.env.FKST_DURABLE_ROOT = path.join(temp, 'durable');
  process.env.FKST_RUNTIME_ROOT = path.join(temp, 'runtime');
  fs.rmSync(artifactRoot, { recursive: true, force: true });
  fs.rmSync(hostRoot, { recursive: true, force: true });
  let crashWindowResource = null;
  let firstStartupEnvironment = null;
  let firstLease = null;
  try {
    const ambientHome = path.join(temp, 'ambient-home');
    fs.mkdirSync(ambientHome);
    const isolated = minimalEnvironment({ FKST_SAFE_MARKER: 'present' }, 'node-runtime-isolation');
    assert.notStrictEqual(isolated.HOME, ambientHome);
    assert.strictEqual(path.basename(path.dirname(isolated.HOME)), 'worker-homes');
    assert.strictEqual(isolated.FKST_SAFE_MARKER, 'present');
    assert.strictEqual(isolated.GIT_CONFIG_NOSYSTEM, '1');
    assert.strictEqual(isolated.GIT_CONFIG_GLOBAL, process.platform === 'win32' ? 'NUL' : '/dev/null');
    assert.strictEqual(isolated.GIT_TERMINAL_PROMPT, '0');
    assert.strictEqual(isolated.GIT_CONFIG_COUNT, '4');
    assert.strictEqual(isolated.GIT_CONFIG_KEY_2, 'core.fsmonitor');
    assert.strictEqual(isolated.GIT_CONFIG_VALUE_2, 'false');
    assert.strictEqual(isolated.GIT_CONFIG_KEY_3, 'core.hooksPath');
    assert.strictEqual(isolated.GIT_CONFIG_VALUE_3, process.platform === 'win32' ? 'NUL' : '/dev/null');
    assert.strictEqual(verifyWorkerEnvironment(isolated), true);
    const secondIsolated = minimalEnvironment({}, 'node-runtime-isolation');
    assert.notStrictEqual(secondIsolated.HOME, isolated.HOME);
    assert.strictEqual(path.dirname(secondIsolated.HOME), path.dirname(isolated.HOME));
    assert.strictEqual(fs.lstatSync(secondIsolated.HOME).isSymbolicLink(), false);
    if (process.platform !== 'win32') {
      assert.strictEqual(fs.lstatSync(secondIsolated.HOME).mode & 0o077, 0);
    }
    const isolatedHome = isolated.HOME;
    const secondIsolatedHome = secondIsolated.HOME;
    assert.strictEqual(releaseWorkerEnvironment(isolated), true);
    assert.strictEqual(releaseWorkerEnvironment(secondIsolated), true);
    assert.strictEqual(fs.existsSync(isolatedHome), false);
    assert.strictEqual(fs.existsSync(secondIsolatedHome), false);
    for (const key of [
      'HOME', 'USERPROFILE', 'XDG_CONFIG_HOME', 'GH_CONFIG_DIR', 'GH_TOKEN', 'GITHUB_TOKEN',
      'GIT_CONFIG_GLOBAL', 'GIT_ASKPASS', 'SSH_AUTH_SOCK', 'SSH_ASKPASS', 'CREDENTIAL_HELPER',
    ]) {
      assert.throws(() => minimalEnvironment({ [key]: 'forbidden' }, 'node-runtime-isolation'),
        /forbidden worker authority key/);
    }
    const symlinkRuntime = path.join(temp, 'symlink-runtime');
    const symlinkTarget = path.join(temp, 'symlink-runtime-target');
    fs.mkdirSync(symlinkTarget);
    fs.symlinkSync(symlinkTarget, symlinkRuntime);
    process.env.FKST_RUNTIME_ROOT = symlinkRuntime;
    assert.throws(() => minimalEnvironment({}, 'symlink-runtime'), /not a real directory/);
    process.env.FKST_RUNTIME_ROOT = path.join(temp, 'runtime');

    const trustedRepository = {
      url: 'https://example.invalid/testing/trusted-fixture.git',
      commit_sha: '1'.repeat(40),
    };
    const boundary = {
      schema: 'testing-host.target-execution-boundary.v1',
      mode: 'trusted-fixture-exact',
      target_class: 'host-owned-exact-trusted-fixture',
      repository: trustedRepository,
      authority: { kind: 'host-policy', ref: 'fixtures/runtime-target-boundary' },
      policy_revision: 'runtime-test-boundary-v1',
      authorization_capability: false,
      execution_authorized: false,
    };
    assert.deepStrictEqual(validateTargetExecutionBoundary(boundary, trustedRepository, {
      runtimeConfigRef: { kind: 'artifact', ref: `${hostRoot}/runtime-config.json` },
      artifactRoot,
    }), boundary);
    assert.throws(() => validateTargetExecutionBoundary(boundary, {
      ...trustedRepository, commit_sha: '2'.repeat(40),
    }), /HOST_RUNTIME_ISOLATION_REQUIRED/);
    assert.throws(() => validateTargetExecutionBoundary({ ...boundary, mode: 'isolated-runtime' }),
      /HOST_RUNTIME_ISOLATION_REQUIRED/);
    assert.throws(() => validateTargetExecutionBoundary(undefined, trustedRepository),
      /HOST_RUNTIME_ISOLATION_REQUIRED/);
    assert.throws(() => validateTargetExecutionBoundary({ ...boundary, repository: {
      url: 'git@example.invalid:testing/trusted-fixture.git', commit_sha: '1'.repeat(40),
    } }, trustedRepository), /HOST_RUNTIME_ISOLATION_REQUIRED/);
    assert.throws(() => validateTargetExecutionBoundary({
      ...boundary, authorization_capability: true,
    }, trustedRepository), /non-authorizing admission prerequisite/);
    assert.throws(() => validateTargetExecutionBoundary(boundary, trustedRepository, {
      runtimeConfigRef: { kind: 'artifact', ref: `${artifactRoot}/runtime-config.json` },
      artifactRoot,
    }), /Host control namespace/);

    const lockPath = path.join(temp, 'stale.lock');
    fs.mkdirSync(lockPath);
    fs.writeFileSync(path.join(lockPath, 'owner.json'), `${JSON.stringify({
      schema: 'environment-factory.lock-owner.v1',
      pid: 2147483647,
      process_start_identity: 'dead process',
      token: 'stale-owner-token',
    })}\n`);
    const release = acquireLock(lockPath, 250);
    const recovered = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
    assert.strictEqual(recovered.pid, process.pid);
    release();
    assert.strictEqual(fs.existsSync(lockPath), false);

    const staleAtomicLockPath = path.join(temp, 'stale-atomic.lock');
    const staleAtomicOwner = {
      schema: 'environment-factory.lock-owner.v1',
      pid: 2147483647,
      process_start_identity: 'dead process',
      token: '1'.repeat(32),
    };
    const staleAtomicPendingPath = `${staleAtomicLockPath}.owner.${staleAtomicOwner.pid}.${staleAtomicOwner.token}`;
    fs.writeFileSync(staleAtomicPendingPath, `${stableStringify(staleAtomicOwner)}\n`);
    fs.linkSync(staleAtomicPendingPath, staleAtomicLockPath);
    const releaseStaleAtomic = acquireLock(staleAtomicLockPath, 250);
    assert.strictEqual(fs.existsSync(staleAtomicPendingPath), false);
    releaseStaleAtomic();
    assert.strictEqual(fs.existsSync(staleAtomicLockPath), false);

    const ownerlessLockPath = path.join(temp, 'ownerless.lock');
    fs.mkdirSync(ownerlessLockPath);
    assert.throws(() => acquireLock(ownerlessLockPath, 250), /cannot be recovered safely/);
    assert.strictEqual(fs.lstatSync(ownerlessLockPath).isDirectory(), true);
    fs.rmSync(ownerlessLockPath, { recursive: true });

    const malformedOwnerLockPath = path.join(temp, 'malformed-owner.lock');
    fs.mkdirSync(malformedOwnerLockPath);
    fs.writeFileSync(path.join(malformedOwnerLockPath, 'owner.json'), '{}\n');
    assert.throws(() => acquireLock(malformedOwnerLockPath, 250), /cannot be recovered safely/);
    assert.strictEqual(fs.lstatSync(malformedOwnerLockPath).isDirectory(), true);
    fs.rmSync(malformedOwnerLockPath, { recursive: true });

    const concurrentLockPath = path.join(temp, 'concurrent-stale.lock');
    const concurrentActivePath = path.join(temp, 'concurrent-stale.active');
    const concurrentEntriesPath = path.join(temp, 'concurrent-stale.entries');
    const concurrentViolationPath = path.join(temp, 'concurrent-stale.violation');
    fs.mkdirSync(concurrentLockPath);
    fs.writeFileSync(path.join(concurrentLockPath, 'owner.json'), `${JSON.stringify({
      schema: 'environment-factory.lock-owner.v1',
      pid: 2147483647,
      process_start_identity: 'dead process',
      token: 'concurrent-stale-owner-token',
    })}\n`);
    const lockModulePath = path.resolve(__dirname, '../bin/runtime/common.js');
    const contenderSource = [
      "'use strict';",
      "const fs = require('fs');",
      'const { acquireLock } = require(process.argv[1]);',
      'const lockPath = process.argv[2];',
      'const activePath = process.argv[3];',
      'const entriesPath = process.argv[4];',
      'const violationPath = process.argv[5];',
      'const release = acquireLock(lockPath, 5000);',
      'let ownsActive = false;',
      'try {',
      "  fs.writeFileSync(activePath, String(process.pid), { flag: 'wx' });",
      '  ownsActive = true;',
      "  fs.appendFileSync(entriesPath, String(process.pid) + '\\n');",
      '  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);',
      '} catch (error) {',
      "  fs.appendFileSync(violationPath, String(process.pid) + ':' + error.code + '\\n');",
      '  process.exitCode = 1;',
      '} finally {',
      '  if (ownsActive) fs.unlinkSync(activePath);',
      '  release();',
      '}',
    ].join('\n');
    const contenders = Array.from({ length: 4 }, () => new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [
        '-e', contenderSource, lockModulePath, concurrentLockPath, concurrentActivePath,
        concurrentEntriesPath, concurrentViolationPath,
      ], { stdio: ['ignore', 'ignore', 'pipe'] });
      let stderr = '';
      child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
      child.once('error', reject);
      child.once('close', (code) => {
        if (code === 0) resolve();
        else reject(new Error(`concurrent stale-lock contender failed: ${stderr}`));
      });
    }));
    await Promise.all(contenders);
    assert.strictEqual(fs.existsSync(concurrentViolationPath), false);
    assert.strictEqual(fs.readFileSync(concurrentEntriesPath, 'utf8').trim().split('\n').length, 4);
    assert.strictEqual(fs.existsSync(concurrentLockPath), false);
    assert.strictEqual(fs.existsSync(`${concurrentLockPath}.takeover.active`), false);

    const crashedTakeoverLockPath = path.join(temp, 'crashed-takeover.lock');
    const crashedTakeoverReadyPath = path.join(temp, 'crashed-takeover.ready');
    const crashedTakeoverEnteredPath = path.join(temp, 'crashed-takeover.entered');
    fs.mkdirSync(crashedTakeoverLockPath);
    fs.writeFileSync(path.join(crashedTakeoverLockPath, 'owner.json'), `${JSON.stringify({
      schema: 'environment-factory.lock-owner.v1',
      pid: 2147483647,
      process_start_identity: 'dead process',
      token: 'crashed-takeover-stale-owner-token',
    })}\n`);
    const crashedTakeoverSource = [
      "'use strict';",
      "const fs = require('fs');",
      'const { acquireLock } = require(process.argv[1]);',
      'const release = acquireLock(process.argv[2], 5000, {',
      '  afterTakeoverAcquired() {',
      "    fs.writeFileSync(process.argv[3], 'ready', { flag: 'wx' });",
      '    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1000);',
      '  },',
      '});',
      "fs.writeFileSync(process.argv[4], 'entered', { flag: 'wx' });",
      'release();',
    ].join('\n');
    const crashedTakeover = spawn(process.execPath, [
      '-e', crashedTakeoverSource, lockModulePath, crashedTakeoverLockPath,
      crashedTakeoverReadyPath, crashedTakeoverEnteredPath,
    ], { stdio: ['ignore', 'ignore', 'pipe'] });
    let crashedTakeoverStderr = '';
    crashedTakeover.stderr.on('data', (chunk) => { crashedTakeoverStderr += chunk.toString(); });
    const readyDeadline = Date.now() + 5_000;
    while (!fs.existsSync(crashedTakeoverReadyPath) && Date.now() < readyDeadline) await delay(10);
    assert.strictEqual(fs.existsSync(crashedTakeoverReadyPath), true);
    const takeoverMarkerPath = `${crashedTakeoverLockPath}.takeover.active`;
    const takeoverOwner = JSON.parse(fs.readFileSync(takeoverMarkerPath, 'utf8'));
    process.kill(takeoverOwner.pid, 'SIGKILL');
    const crashedTakeoverExit = await new Promise((resolve, reject) => {
      crashedTakeover.once('error', reject);
      crashedTakeover.once('close', (code) => resolve(code));
    });
    assert.notStrictEqual(crashedTakeoverExit, 0, crashedTakeoverStderr);
    assert.strictEqual(fs.existsSync(crashedTakeoverEnteredPath), false);
    const recoveredAfterGuardCrash = acquireLock(crashedTakeoverLockPath, 5_000);
    recoveredAfterGuardCrash();
    assert.strictEqual(fs.existsSync(crashedTakeoverLockPath), false);
    assert.strictEqual(fs.existsSync(takeoverMarkerPath), false);

    const startupCounter = path.join(temp, 'supervised-startup-count.txt');
    const startupClaim = path.join(temp, 'supervised-startup', 'claim.json');
    const startupBinding = {
      schema: 'environment-factory.resource.v1',
      kind: 'process',
      operation_id: 'crash-window-operation',
      ref: 'crash-window-process',
      effect_id: 'crash-window-effect',
      argv_sha256: sha256('crash-window-argv'),
      ownership_token: sha256('crash-window-owner'),
      runtime_ports: [],
      repository: trustedRepository,
      cleaned: false,
    };
    const startupArgv = [process.execPath, '-e', [
      "const fs = require('fs');",
      `fs.appendFileSync(${JSON.stringify(startupCounter)}, 'started\\n');`,
      'setInterval(() => {}, 1000);',
    ].join('')];
    let launchedSupervisorPid = null;
    const interrupted = startOrRecoverSupervisedProcess({
      claimPath: startupClaim,
      argv: startupArgv,
      cwd: temp,
      createEnvironment(reservation) {
        firstStartupEnvironment = minimalEnvironment(
          {}, 'supervised-crash-window-first', reservation.reservation_id,
        );
        firstLease = workerEnvironmentLease(firstStartupEnvironment);
        return firstStartupEnvironment;
      },
      binding: startupBinding,
      afterLaunch(pid) {
        launchedSupervisorPid = pid;
        return false;
      },
    });
    assert.strictEqual(interrupted.interrupted, true);
    assert.strictEqual(fs.existsSync(startupClaim), true);
    assert.strictEqual(fs.existsSync(firstLease.home), true);

    let recoveryEnvironmentCreated = false;
    const recoveredStartup = startOrRecoverSupervisedProcess({
      claimPath: startupClaim,
      argv: startupArgv,
      cwd: temp,
      createEnvironment(reservation) {
        recoveryEnvironmentCreated = true;
        return minimalEnvironment(
          {}, 'supervised-crash-window-recovery', reservation.reservation_id,
        );
      },
      binding: startupBinding,
    });
    assert.strictEqual(recoveredStartup.interrupted, false);
    assert.strictEqual(recoveredStartup.state, 'running');
    assert.strictEqual(recoveredStartup.resource.pid, launchedSupervisorPid);
    assert.strictEqual(recoveredStartup.resource.worker_environment_lease.home, firstLease.home);
    assert.strictEqual(recoveredStartup.environment_retained, false);
    assert.strictEqual(recoveryEnvironmentCreated, false);
    crashWindowResource = recoveredStartup.resource;

    const counterDeadline = Date.now() + 2_000;
    while (Date.now() < counterDeadline) {
      if (fs.existsSync(startupCounter) && fs.readFileSync(startupCounter, 'utf8') === 'started\n') break;
      await delay(10);
    }
    assert.strictEqual(fs.readFileSync(startupCounter, 'utf8'), 'started\n');
    let replayEnvironmentCreated = false;
    const replayedStartup = startOrRecoverSupervisedProcess({
      claimPath: startupClaim,
      argv: startupArgv,
      cwd: temp,
      createEnvironment(reservation) {
        replayEnvironmentCreated = true;
        return minimalEnvironment(
          {}, 'supervised-crash-window-replay', reservation.reservation_id,
        );
      },
      binding: startupBinding,
    });
    assert.strictEqual(replayedStartup.resource.pid, launchedSupervisorPid);
    assert.strictEqual(replayedStartup.resource.worker_environment_lease.home, firstLease.home);
    assert.strictEqual(replayEnvironmentCreated, false);
    await delay(50);
    assert.strictEqual(fs.readFileSync(startupCounter, 'utf8'), 'started\n');
    assert.strictEqual(processGroupState(replayedStartup.resource).alive, true);
    assert.strictEqual(terminateProcessGroup(replayedStartup.resource, 2_000).released, true);
    crashWindowResource = null;
    assert.strictEqual(releaseWorkerEnvironmentLease(firstLease), true);
    assert.strictEqual(fs.existsSync(firstLease.home), false);
    assert.strictEqual(releaseWorkerEnvironment(firstStartupEnvironment), true);

    let failedLaunchLease = null;
    const failedLaunchClaim = path.join(temp, 'supervised-failed-launch', 'claim.json');
    assert.throws(() => startOrRecoverSupervisedProcess({
      claimPath: failedLaunchClaim,
      argv: [process.execPath, '-e', 'process.exit(0)'],
      cwd: temp,
      createEnvironment(reservation) {
        const environment = minimalEnvironment(
          {}, 'supervised-failed-launch', reservation.reservation_id,
        );
        failedLaunchLease = workerEnvironmentLease(environment);
        return environment;
      },
      binding: { ...startupBinding, effect_id: 'failed-launch-effect' },
      registrationTimeoutMs: 250,
      beforeSupervisorLaunch() {
        throw new Error('simulated supervisor launch failure');
      },
    }), /simulated supervisor launch failure/);
    assert.strictEqual(JSON.parse(fs.readFileSync(failedLaunchClaim, 'utf8')).state, 'revoked');
    assert.strictEqual(fs.existsSync(failedLaunchLease.home), false);

    let failedClaimLease = null;
    assert.throws(() => startOrRecoverSupervisedProcess({
      claimPath: path.join(temp, 'supervised-failed-claim', 'claim.json'),
      argv: [process.execPath, '-e', 'process.exit(0)'],
      cwd: temp,
      createEnvironment(reservation) {
        const environment = minimalEnvironment({}, 'supervised-failed-claim');
        failedClaimLease = workerEnvironmentLease(environment);
        return environment;
      },
      binding: { ...startupBinding, effect_id: 'failed-claim-effect' },
      beforeClaimPersist() {
        throw new Error('simulated startup claim persistence failure');
      },
    }), /simulated startup claim persistence failure/);
    assert.strictEqual(failedClaimLease, null);

    const preClaimCrashClaim = path.join(temp, 'supervised-pre-claim-crash', 'claim.json');
    const preClaimCrashReady = path.join(temp, 'supervised-pre-claim-crash.ready.json');
    const preClaimCrashBinding = { ...startupBinding, effect_id: 'pre-claim-crash-effect' };
    const preClaimCrashArgv = [process.execPath, '-e', 'process.exit(0)'];
    const supervisorModulePath = path.resolve(__dirname, '../bin/runtime/supervised-process.js');
    const commonModulePath = path.resolve(__dirname, '../bin/runtime/common.js');
    const preClaimCrashSource = [
      "'use strict';",
      "const fs = require('fs');",
      'const { startOrRecoverSupervisedProcess } = require(process.argv[1]);',
      'const { minimalEnvironment } = require(process.argv[2]);',
      'const claimPath = process.argv[3];',
      'const cwd = process.argv[4];',
      'const readyPath = process.argv[5];',
      'const binding = JSON.parse(process.argv[6]);',
      'const argv = JSON.parse(process.argv[7]);',
      'startOrRecoverSupervisedProcess({',
      '  claimPath, argv, cwd, binding,',
      '  createEnvironment(reservation) {',
      "    return minimalEnvironment({}, 'supervised-pre-claim-hard-crash', reservation.reservation_id);",
      '  },',
      '  afterEnvironmentCreated(environment) {',
      "    fs.writeFileSync(readyPath, JSON.stringify({ home: environment.HOME }), { flag: 'wx' });",
      '    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10000);',
      '  },',
      '});',
    ].join('\n');
    const preClaimCrash = spawn(process.execPath, [
      '-e', preClaimCrashSource, supervisorModulePath, commonModulePath,
      preClaimCrashClaim, temp, preClaimCrashReady, JSON.stringify(preClaimCrashBinding),
      JSON.stringify(preClaimCrashArgv),
    ], { stdio: ['ignore', 'ignore', 'pipe'] });
    let preClaimCrashStderr = '';
    preClaimCrash.stderr.on('data', (chunk) => { preClaimCrashStderr += chunk.toString(); });
    const preClaimReadyDeadline = Date.now() + 5_000;
    while (!fs.existsSync(preClaimCrashReady) && Date.now() < preClaimReadyDeadline) await delay(10);
    assert.strictEqual(fs.existsSync(preClaimCrashReady), true, preClaimCrashStderr);
    const reservedHome = JSON.parse(fs.readFileSync(preClaimCrashReady, 'utf8')).home;
    const allocatingClaim = JSON.parse(fs.readFileSync(preClaimCrashClaim, 'utf8'));
    assert.strictEqual(allocatingClaim.state, 'allocating');
    assert.strictEqual(allocatingClaim.worker_environment_lease, null);
    process.kill(preClaimCrash.pid, 'SIGKILL');
    await new Promise((resolve, reject) => {
      preClaimCrash.once('error', reject);
      preClaimCrash.once('close', resolve);
    });
    let recoveredPreClaimEnvironment = null;
    const recoveredPreClaim = startOrRecoverSupervisedProcess({
      claimPath: preClaimCrashClaim,
      argv: preClaimCrashArgv,
      cwd: temp,
      binding: preClaimCrashBinding,
      createEnvironment(reservation) {
        recoveredPreClaimEnvironment = minimalEnvironment(
          {}, 'supervised-pre-claim-hard-crash', reservation.reservation_id,
        );
        return recoveredPreClaimEnvironment;
      },
    });
    assert.notStrictEqual(recoveredPreClaim.state, 'allocating');
    assert.strictEqual(recoveredPreClaim.resource.worker_environment_lease.home, reservedHome);
    assert.strictEqual(workerEnvironmentLease(recoveredPreClaimEnvironment).home, reservedHome);
    assert.strictEqual(releaseWorkerEnvironmentLease(
      recoveredPreClaim.resource.worker_environment_lease,
    ), true);
    assert.strictEqual(fs.existsSync(reservedHome), false);
    assert.strictEqual(releaseWorkerEnvironment(recoveredPreClaimEnvironment), true);

    let noClobberLease = null;
    let foreignLaunchSpecPath = null;
    const foreignLaunchSpecBody = 'externally-created-launch-spec\n';
    assert.throws(() => startOrRecoverSupervisedProcess({
      claimPath: path.join(temp, 'supervised-launch-spec-no-clobber', 'claim.json'),
      argv: [process.execPath, '-e', 'process.exit(0)'],
      cwd: temp,
      createEnvironment(reservation) {
        const environment = minimalEnvironment(
          {}, 'supervised-launch-spec-no-clobber', reservation.reservation_id,
        );
        noClobberLease = workerEnvironmentLease(environment);
        return environment;
      },
      binding: { ...startupBinding, effect_id: 'launch-spec-no-clobber-effect' },
      beforeLaunchSpecPublish(claim) {
        foreignLaunchSpecPath = claim.launch_spec_path;
        fs.writeFileSync(foreignLaunchSpecPath, foreignLaunchSpecBody, { flag: 'wx' });
      },
    }), /immutable content differs/);
    assert.strictEqual(fs.readFileSync(foreignLaunchSpecPath, 'utf8'), foreignLaunchSpecBody);
    assert.strictEqual(fs.existsSync(noClobberLease.home), false);

    let oversizedLaunchLease = null;
    const oversizedTargetMarker = path.join(temp, 'supervised-oversized-target.txt');
    const oversizedClaimPath = path.join(temp, 'supervised-oversized-launch', 'claim.json');
    const oversizedLaunch = startOrRecoverSupervisedProcess({
      claimPath: oversizedClaimPath,
      argv: [process.execPath, '-e', `require('fs').writeFileSync(${JSON.stringify(oversizedTargetMarker)}, 'bad')`],
      cwd: temp,
      createEnvironment(reservation) {
        const environment = minimalEnvironment(
          {}, 'supervised-oversized-launch', reservation.reservation_id,
        );
        oversizedLaunchLease = workerEnvironmentLease(environment);
        return environment;
      },
      binding: { ...startupBinding, effect_id: 'oversized-launch-effect' },
      registrationTimeoutMs: 250,
      beforeSupervisorLaunch(claim) {
        const oversizedBody = Buffer.alloc(2 * 1024 * 1024 + 1, 0x61);
        fs.unlinkSync(claim.launch_spec_path);
        fs.writeFileSync(claim.launch_spec_path, oversizedBody, { flag: 'wx', mode: 0o600 });
        const stat = fs.lstatSync(claim.launch_spec_path);
        const substitutedClaim = JSON.parse(fs.readFileSync(oversizedClaimPath, 'utf8'));
        substitutedClaim.launch_spec_identity = {
          device: String(stat.dev), inode: String(stat.ino), size: stat.size, mode: stat.mode,
        };
        substitutedClaim.launch_spec_sha256 = sha256(oversizedBody);
        fs.writeFileSync(oversizedClaimPath, `${stableStringify(substitutedClaim)}\n`);
      },
    });
    assert.strictEqual(oversizedLaunch.state, 'revoked');
    assert.strictEqual(fs.existsSync(oversizedTargetMarker), false);
    assert.strictEqual(fs.existsSync(oversizedLaunchLease.home), false);

    let substitutedLaunchLease = null;
    const substitutedMarker = path.join(temp, 'supervised-substituted-command.txt');
    const substitutedLaunch = startOrRecoverSupervisedProcess({
      claimPath: path.join(temp, 'supervised-substituted-launch', 'claim.json'),
      argv: [process.execPath, '-e', 'process.exit(0)'],
      cwd: temp,
      createEnvironment(reservation) {
        const environment = minimalEnvironment(
          {}, 'supervised-substituted-launch', reservation.reservation_id,
        );
        substitutedLaunchLease = workerEnvironmentLease(environment);
        return environment;
      },
      binding: { ...startupBinding, effect_id: 'substituted-launch-effect' },
      registrationTimeoutMs: 250,
      beforeSupervisorLaunch(claim) {
        const substituted = {
          schema: 'fkst.supervised-process-launch.v1',
          startup_token: claim.startup_token,
          binding_sha256: claim.binding_sha256,
          claim_path: path.join(temp, 'supervised-substituted-launch', 'claim.json'),
          argv: [process.execPath, '-e', `require('fs').writeFileSync(${JSON.stringify(substitutedMarker)}, 'bad')`],
          cwd: temp,
          inherited_fd_count: 0,
          inherited_fd_identities: [],
        };
        fs.writeFileSync(claim.launch_spec_path, `${stableStringify(substituted)}\n`);
      },
    });
    assert.strictEqual(substitutedLaunch.state, 'revoked');
    assert.strictEqual(fs.existsSync(substitutedMarker), false);
    assert.strictEqual(fs.existsSync(substitutedLaunchLease.home), false);

    let symlinkedLaunchLease = null;
    const symlinkedMarker = path.join(temp, 'supervised-symlinked-command.txt');
    const symlinkedLaunch = startOrRecoverSupervisedProcess({
      claimPath: path.join(temp, 'supervised-symlinked-launch', 'claim.json'),
      argv: [process.execPath, '-e', `require('fs').writeFileSync(${JSON.stringify(symlinkedMarker)}, 'bad')`],
      cwd: temp,
      createEnvironment(reservation) {
        const environment = minimalEnvironment(
          {}, 'supervised-symlinked-launch', reservation.reservation_id,
        );
        symlinkedLaunchLease = workerEnvironmentLease(environment);
        return environment;
      },
      binding: { ...startupBinding, effect_id: 'symlinked-launch-effect' },
      registrationTimeoutMs: 250,
      beforeSupervisorLaunch(claim) {
        const original = `${claim.launch_spec_path}.original`;
        fs.renameSync(claim.launch_spec_path, original);
        fs.symlinkSync(original, claim.launch_spec_path);
      },
    });
    assert.strictEqual(symlinkedLaunch.state, 'revoked');
    assert.strictEqual(fs.existsSync(symlinkedMarker), false);
    assert.strictEqual(fs.existsSync(symlinkedLaunchLease.home), false);

    for (let index = 0; index < 10; index += 1) {
      const result = await runMeasuredCommand([process.execPath, '-e', 'process.exit(0)'], {
        timeoutMs: 2_000,
        outputBytes: 1024,
      });
      assert.strictEqual(result.exitCode, 0);
      assert.strictEqual(result.metricsSupported, true);
      assert.strictEqual(result.processMetricsSupported, true);
      assert.strictEqual(result.maxProcesses >= 1, true);
    }

    const bounded = await runMeasuredCommand([
      process.execPath,
      '-e',
      "process.stdout.write('a'.repeat(700));process.stderr.write('b'.repeat(700))",
    ], { timeoutMs: 2_000, outputBytes: 1024 });
    assert.strictEqual(bounded.outputExceeded, true);
    assert.strictEqual(Buffer.byteLength(bounded.stdout) + Buffer.byteLength(bounded.stderr) <= 1024, true);

    const extra = await spawnListener(['127.0.0.1', '127.0.0.1'], temp);
    const extraResult = listenersOwnedByProcessGroup(
      [{ name: 'expected', port: extra.ports[0] }],
      extra.child.pid,
    );
    stopGroup(extra.child);
    assert.strictEqual(extraResult.supported, true);
    assert.strictEqual(extraResult.owned, false);
    assert.match(extraResult.reason, /^extra-listener:/);

    const wildcard = await spawnListener(['0.0.0.0'], temp);
    const wildcardResult = listenersOwnedByProcessGroup(
      [{ name: 'expected', port: wildcard.ports[0] }],
      wildcard.child.pid,
    );
    stopGroup(wildcard.child);
    assert.strictEqual(wildcardResult.supported, true);
    assert.strictEqual(wildcardResult.owned, false);
    assert.match(wildcardResult.reason, /^non-loopback-listener:/);

    const effectPayload = {
      effect_id: `node-runtime-${process.pid}/readiness-attempt`,
      operation_id: `node-runtime-${process.pid}`,
      artifact_root: artifactRoot,
      operation_state_ref: { kind: 'artifact', ref: `${artifactRoot}/operation-state.json` },
      base_url: 'http://127.0.0.1:4312/health',
      sessions: [{ role: 'browser', cdp_url: 'http://127.0.0.1:9222' }],
      trace_id: 'trace-node-runtime',
      dedup_key: 'dedup-node-runtime',
    };
    const readinessAttempt = await dispatch('create-readiness-attempt', effectPayload);
    assert.strictEqual(readinessAttempt.status, 'passed');
    assert.match(readinessAttempt.attempt_ref.ref, /\/readiness-attempts\/environment-readiness-/);
    assert.match(readinessAttempt.attempt_sha256, /^[0-9a-f]{64}$/);
    assert.strictEqual(readinessAttempt.target_id, undefined);

    const cdpServer = http.createServer((request, response) => {
      if (request.url !== '/json/list') {
        response.writeHead(404).end();
        return;
      }
      const origin = `http://127.0.0.1:${cdpServer.address().port}`;
      response.setHeader('content-type', 'application/json');
      response.end(JSON.stringify([{
        id: 'exact-page-target', type: 'page', url: `${origin}/app`,
        webSocketDebuggerUrl: 'ws://127.0.0.1/devtools/page/exact-page-target',
      }]));
    });
    await new Promise((resolve) => cdpServer.listen(0, '127.0.0.1', resolve));
    const cdpOrigin = `http://127.0.0.1:${cdpServer.address().port}`;
    const exactAttempt = await dispatch('create-readiness-attempt', {
      ...effectPayload,
      effect_id: `node-runtime-${process.pid}/exact-readiness-attempt`,
      base_url: `${cdpOrigin}/health`,
      sessions: [{ role: 'browser', cdp_url: cdpOrigin }],
    });
    await new Promise((resolve) => cdpServer.close(resolve));
    assert.strictEqual(exactAttempt.target_id, 'exact-page-target');
    assert.strictEqual(exactAttempt.target_sha256, sha256('exact-page-target'));
    assert.match(exactAttempt.attempt_sha256, /^[0-9a-f]{64}$/);

    await assert.rejects(() => dispatch('create-readiness-attempt', {
      ...effectPayload,
      operation_state_ref: { kind: 'artifact', ref: `${artifactRoot}/foreign-state.json` },
    }), /effect request binding differs/);

    const ownedWorkspace = path.join(temp, 'owned-workspace');
    fs.mkdirSync(ownedWorkspace);
    const ownedResourceRef = `owned-workspace-${process.pid}`;
    const ownedResourcePath = path.join(
      process.env.FKST_DURABLE_ROOT,
      'environment-factory',
      'resources',
      `${sha256(ownedResourceRef)}.json`,
    );
    fs.mkdirSync(path.dirname(ownedResourcePath), { recursive: true });
    fs.writeFileSync(ownedResourcePath, `${JSON.stringify({
      schema: 'environment-factory.resource.v1',
      kind: 'workspace',
      operation_id: `owner-${process.pid}`,
      ref: ownedResourceRef,
      path: ownedWorkspace,
      cleaned: false,
    })}\n`);
    await assert.rejects(() => dispatch('cleanup', {
      effect_id: `foreign-${process.pid}/cleanup/workspace`,
      operation_id: `foreign-${process.pid}`,
      artifact_root: artifactRoot,
      cleanup_ref: { kind: 'resource-cleanup', ref: ownedResourceRef },
      timeout_seconds: 1,
    }), /resource ownership binding is invalid/);
    assert.strictEqual(fs.existsSync(ownedWorkspace), true);

    const runtimeConfigRef = { kind: 'artifact', ref: `${hostRoot}/runtime-config.json` };
    const stateRef = { kind: 'artifact', ref: `${artifactRoot}/operation-state.json` };
    fs.mkdirSync(hostRoot, { recursive: true });
    fs.writeFileSync(runtimeConfigRef.ref, `${JSON.stringify({
      schema: 'environment-factory.runtime-config.v1',
      revision: 'node-runtime-test-1',
      state_auth_key: 'node-runtime-state-auth-key-which-is-long-enough',
      state_mac_generation: 'node-runtime-key-1',
    })}\n`);
    const firstSave = await dispatch('save-state', {
      ref: stateRef,
      state: { schema: 'environment-factory.operation-state.v1', value: 1 },
      expected_revision: 0,
      runtime_config_ref: runtimeConfigRef,
    });
    assert.deepStrictEqual(firstSave, { saved: true, revision: 1 });
    const staleSave = await dispatch('save-state', {
      ref: stateRef,
      state: { schema: 'environment-factory.operation-state.v1', value: 2 },
      expected_revision: 0,
      runtime_config_ref: runtimeConfigRef,
    });
    assert.deepStrictEqual(staleSave, { saved: false, stale: true, revision: 1 });
    const loaded = await dispatch('load-state', { ref: stateRef, runtime_config_ref: runtimeConfigRef });
    assert.strictEqual(loaded.authenticated, true);
    assert.strictEqual(loaded.revision, 1);
    assert.strictEqual(loaded.state.value, 1);

    fs.writeFileSync(runtimeConfigRef.ref, `${JSON.stringify({
      schema: 'environment-factory.runtime-config.v1',
      revision: 'node-runtime-test-2',
      state_auth_key: 'node-runtime-state-auth-key-which-is-long-enough',
      state_mac_generation: 'node-runtime-key-2',
    })}\n`);
    const rotated = await dispatch('load-state', { ref: stateRef, runtime_config_ref: runtimeConfigRef });
    assert.strictEqual(rotated.authenticated, false);
  } finally {
    if (crashWindowResource) terminateProcessGroup(crashWindowResource, 2_000);
    if (firstLease) releaseWorkerEnvironmentLease(firstLease);
    if (firstStartupEnvironment) releaseWorkerEnvironment(firstStartupEnvironment);
    if (previousDurable === undefined) delete process.env.FKST_DURABLE_ROOT;
    else process.env.FKST_DURABLE_ROOT = previousDurable;
    if (previousRuntime === undefined) delete process.env.FKST_RUNTIME_ROOT;
    else process.env.FKST_RUNTIME_ROOT = previousRuntime;
    await removeTreeEventually(temp);
    await removeTreeEventually(artifactRoot);
    await removeTreeEventually(hostRoot);
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
