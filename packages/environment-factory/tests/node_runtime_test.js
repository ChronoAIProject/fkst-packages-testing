'use strict';

const assert = require('assert');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const {
  acquireLock,
  authorizationArtifact,
  minimalEnvironment,
  ownedDirectoryReleaseProven,
  pathIdentity,
  readBoundedRegularFile,
  removeOwnedDirectory,
  releaseWorkerEnvironment,
  releaseWorkerEnvironmentLease,
  stableStringify,
  verifyWorkerEnvironment,
  workerEnvironmentReleaseProven,
  workerEnvironmentLease,
} = require('../bin/runtime/common');
const { validateTargetExecutionBoundary } = require('../bin/runtime/target-execution-boundary');
const { startOrRecoverSupervisedProcess } = require('../bin/runtime/supervised-process');
const {
  allocateDurableWorkerEnvironment,
  initializeWorkerHomeLedger,
  recordWorkerEnvironmentRelease,
  verifyPersistedWorkerEnvironment,
} = require('../bin/runtime/worker-home-resource');
const { runMeasuredCommand } = require('../bin/runtime/measured-command');
const {
  listenersOwnedByProcessGroup,
  processGroupState,
  terminateProcessGroup,
} = require('../bin/runtime/platform');
const {
  checkout: checkoutWithHooks, dispatch, initialReadinessState, resourceIsReleased, sha256,
} = require('../bin/environment-factory-runtime');

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const cleanupRaceHarness = String.raw`
import importlib.util
import json
import os
import stat
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("object_bound_cleanup_broker", sys.argv[1])
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)
fixture = json.loads(sys.argv[2])
request = fixture["request"]
scenario = fixture["scenario"]
external = fixture["external"]
original_rename_noreplace = broker.rename_noreplace
injected = False

def write_relative(directory_fd, name, body):
    descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=directory_fd)
    try:
        os.write(descriptor, body.encode("utf-8"))
    finally:
        os.close(descriptor)

def injected_rename(source_name, source_fd, destination_name, destination_fd):
    global injected
    target_name = os.path.basename(request["target"])
    should_inject = (
        (scenario == "file-replacement" and source_name == "victim.txt")
        or (scenario == "child-move" and source_name == "child")
        or (scenario in ("target-move", "root-move") and source_name == target_name)
    )
    if should_inject and not injected:
        injected = True
        if scenario == "file-replacement":
            os.rename(source_name, external, src_dir_fd=source_fd)
            write_relative(source_fd, source_name, "external-replacement\n")
        elif scenario in ("child-move", "target-move"):
            os.rename(source_name, external, src_dir_fd=source_fd)
        else:
            os.rename(request["containment_root"], external)
    return original_rename_noreplace(source_name, source_fd, destination_name, destination_fd)

broker.rename_noreplace = injected_rename
outcome = "cleaned"
reason = None
retry_outcome = "not-run"
try:
    broker.cleanup(request)
except (broker.CleanupBlocked, FileNotFoundError, NotADirectoryError, PermissionError, OSError) as error:
    outcome = "blocked"
    reason = str(error)
    try:
        broker.cleanup(request)
        retry_outcome = "cleaned"
    except (broker.CleanupBlocked, FileNotFoundError, NotADirectoryError, PermissionError, OSError):
        retry_outcome = "blocked"

bodies = []
for current_root, directories, files in os.walk(fixture["audit_root"], followlinks=False):
    directories.sort()
    files.sort()
    for name in files:
        candidate = os.path.join(current_root, name)
        linked = os.lstat(candidate)
        if stat.S_ISREG(linked.st_mode) and linked.st_size <= 1024:
            with open(candidate, "r", encoding="utf-8") as handle:
                bodies.append(handle.read())
print(json.dumps({
    "outcome": outcome,
    "retry_outcome": retry_outcome,
    "reason": reason,
    "injected": injected,
    "bodies": bodies,
}))
`;

function runCleanupRace(cleanupBroker, fixture) {
  const environment = Object.create(null);
  for (const key of ['LANG', 'LC_ALL']) {
    if (typeof process.env[key] === 'string') environment[key] = process.env[key];
  }
  const result = spawnSync('/usr/bin/python3', [
    '-I', '-c', cleanupRaceHarness, cleanupBroker, JSON.stringify(fixture),
  ], {
    env: environment,
    shell: false,
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 64 * 1024,
  });
  assert.strictEqual(result.status, 0, result.stderr || result.stdout);
  return JSON.parse(result.stdout);
}

function runCleanupBroker(cleanupBroker, request) {
  const environment = Object.create(null);
  for (const key of ['LANG', 'LC_ALL']) {
    if (typeof process.env[key] === 'string') environment[key] = process.env[key];
  }
  const result = spawnSync('/usr/bin/python3', ['-I', cleanupBroker], {
    input: `${stableStringify(request)}\n`,
    env: environment,
    shell: false,
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 64 * 1024,
  });
  return {
    status: result.status,
    value: JSON.parse(result.stdout),
    stderr: result.stderr,
  };
}

function captureLeaseBeforeCallerStateUpdate(cleanupBroker, lease) {
  const request = {
    schema: 'environment-factory.object-bound-cleanup-request.v1',
    operation: 'capture-delete',
    capture_id: lease.cleanup_capture_id,
    target: lease.home_identity.realpath,
    target_identity: lease.home_identity,
    containment_root: lease.homes_root_identity.realpath,
    containment_root_identity: lease.homes_root_identity,
  };
  const stateRoot = path.join(process.env.FKST_DURABLE_ROOT, 'cleanup-captures');
  fs.mkdirSync(stateRoot, { recursive: true, mode: 0o700 });
  const statePath = path.join(stateRoot, `${lease.cleanup_capture_id}.json`);
  const pendingState = {
    schema: 'environment-factory.object-bound-cleanup-capture-state.v1',
    capture_id: lease.cleanup_capture_id,
    target: lease.home_identity.realpath,
    target_identity: lease.home_identity,
    containment_root: lease.homes_root_identity.realpath,
    containment_root_identity: lease.homes_root_identity,
    state: 'pending',
  };
  if (fs.existsSync(statePath)) {
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(statePath, 'utf8')), pendingState);
  } else {
    fs.writeFileSync(statePath, `${stableStringify(pendingState)}\n`, { flag: 'wx' });
  }
  const captured = runCleanupBroker(cleanupBroker, request);
  assert.strictEqual(captured.status, 0, captured.stderr);
  assert.strictEqual(captured.value.status, 'captured-cleaned');
  assert.strictEqual(fs.existsSync(lease.home), false);
}

function cleanupRaceFixture(root, target, scenario, external) {
  const rootIdentity = pathIdentity(root);
  const targetIdentity = pathIdentity(target);
  return {
    scenario,
    external,
    audit_root: path.dirname(root),
    request: {
      schema: 'environment-factory.object-bound-cleanup-request.v1',
      operation: 'capture-delete',
      capture_id: 'a'.repeat(64),
      target: targetIdentity.realpath,
      target_identity: targetIdentity,
      containment_root: rootIdentity.realpath,
      containment_root_identity: rootIdentity,
    },
  };
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
  const previousWorkerRuntime = process.env.FKST_WORKER_RUNTIME_ROOT;
  const previousCleanupBroker = process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER;
  const previousCleanupBrokerSha256 = process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256;
  process.env.FKST_DURABLE_ROOT = path.join(temp, 'durable');
  process.env.FKST_RUNTIME_ROOT = path.join(temp, 'runtime');
  process.env.FKST_WORKER_RUNTIME_ROOT = path.join(temp, 'worker-runtime');
  fs.rmSync(artifactRoot, { recursive: true, force: true });
  fs.rmSync(hostRoot, { recursive: true, force: true });
  let crashWindowResource = null;
  let firstStartupEnvironment = null;
  let firstLease = null;
  try {
    const cleanupBroker = path.resolve(__dirname, '..', 'bin', 'object-bound-cleanup-broker.py');
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER = cleanupBroker;
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256 = sha256(fs.readFileSync(cleanupBroker));
    const ambientHome = path.join(temp, 'ambient-home');
    fs.mkdirSync(ambientHome);
    const isolated = minimalEnvironment({ FKST_SAFE_MARKER: 'present' }, 'node-runtime-isolation');
    assert.notStrictEqual(isolated.HOME, ambientHome);
    assert.strictEqual(path.basename(path.dirname(isolated.HOME)), 'worker-homes');
    assert.strictEqual(path.dirname(path.dirname(isolated.HOME)),
      fs.realpathSync(process.env.FKST_WORKER_RUNTIME_ROOT));
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
    const brokerEnvironment = minimalEnvironment({}, 'node-runtime-broker-cleanup');
    const externalDirectory = path.join(temp, 'external-cleanup-sentinel');
    fs.mkdirSync(externalDirectory);
    const brokerExternalSentinel = path.join(externalDirectory, 'sentinel.txt');
    fs.writeFileSync(brokerExternalSentinel, 'preserve\n');
    fs.writeFileSync(path.join(brokerEnvironment.HOME, 'worker-output.txt'), 'generated\n');
    fs.symlinkSync(externalDirectory, path.join(brokerEnvironment.HOME, 'external-link'));
    assert.strictEqual(releaseWorkerEnvironment(brokerEnvironment), true);
    assert.strictEqual(fs.existsSync(brokerEnvironment.HOME), false);
    assert.strictEqual(fs.readFileSync(brokerExternalSentinel, 'utf8'), 'preserve\n');

    const finalizeRecoveryRoot = path.join(temp, 'broker-finalize-recovery', 'containment');
    const finalizeRecoveryTarget = path.join(finalizeRecoveryRoot, 'target');
    fs.mkdirSync(finalizeRecoveryTarget, { recursive: true });
    fs.writeFileSync(path.join(finalizeRecoveryTarget, 'owned.txt'), 'owned\n');
    const finalizeRecoveryRootIdentity = pathIdentity(finalizeRecoveryRoot);
    const finalizeRecoveryTargetIdentity = pathIdentity(finalizeRecoveryTarget);
    const finalizeRecoveryCaptureId = sha256(`finalize-recovery\0${process.pid}`);
    const finalizeRecoveryRequest = {
      schema: 'environment-factory.object-bound-cleanup-request.v1',
      capture_id: finalizeRecoveryCaptureId,
      target: finalizeRecoveryTargetIdentity.realpath,
      target_identity: finalizeRecoveryTargetIdentity,
      containment_root: finalizeRecoveryRootIdentity.realpath,
      containment_root_identity: finalizeRecoveryRootIdentity,
    };
    const captureResult = runCleanupBroker(cleanupBroker, {
      ...finalizeRecoveryRequest, operation: 'capture-delete',
    });
    assert.strictEqual(captureResult.status, 0, captureResult.stderr);
    assert.strictEqual(captureResult.value.status, 'captured-cleaned');
    assert.strictEqual(fs.existsSync(finalizeRecoveryTarget), false);
    assert.strictEqual(ownedDirectoryReleaseProven(
      finalizeRecoveryTarget,
      finalizeRecoveryTargetIdentity,
      finalizeRecoveryRoot,
      finalizeRecoveryCaptureId,
    ), false);
    const finalizeResult = runCleanupBroker(cleanupBroker, {
      ...finalizeRecoveryRequest, operation: 'finalize',
    });
    assert.strictEqual(finalizeResult.status, 0, finalizeResult.stderr);
    assert.strictEqual(finalizeResult.value.status, 'finalized');
    const proofPath = path.join(
      path.dirname(finalizeRecoveryRootIdentity.realpath),
      `.fkst-object-cleanup-${finalizeRecoveryCaptureId}`,
    );
    assert.strictEqual(fs.existsSync(path.join(proofPath, 'finalized')), true);
    const captureStateRoot = path.join(process.env.FKST_DURABLE_ROOT, 'cleanup-captures');
    fs.mkdirSync(captureStateRoot, { recursive: true, mode: 0o700 });
    fs.writeFileSync(
      path.join(captureStateRoot, `${finalizeRecoveryCaptureId}.json`),
      `${stableStringify({
        schema: 'environment-factory.object-bound-cleanup-capture-state.v1',
        capture_id: finalizeRecoveryCaptureId,
        target: finalizeRecoveryTargetIdentity.realpath,
        target_identity: finalizeRecoveryTargetIdentity,
        containment_root: finalizeRecoveryRootIdentity.realpath,
        containment_root_identity: finalizeRecoveryRootIdentity,
        state: 'captured-cleaned',
      })}\n`,
      { flag: 'wx' },
    );
    assert.strictEqual(ownedDirectoryReleaseProven(
      finalizeRecoveryTarget,
      finalizeRecoveryTargetIdentity,
      finalizeRecoveryRoot,
      finalizeRecoveryCaptureId,
    ), false);
    assert.strictEqual(removeOwnedDirectory(
      finalizeRecoveryTarget,
      finalizeRecoveryTargetIdentity,
      finalizeRecoveryRoot,
      finalizeRecoveryCaptureId,
    ), true);
    assert.strictEqual(fs.existsSync(proofPath), false);
    assert.strictEqual(
      JSON.parse(fs.readFileSync(
        path.join(captureStateRoot, `${finalizeRecoveryCaptureId}.json`), 'utf8',
      )).state,
      'released',
    );
    assert.strictEqual(ownedDirectoryReleaseProven(
      finalizeRecoveryTarget,
      finalizeRecoveryTargetIdentity,
      finalizeRecoveryRoot,
      finalizeRecoveryCaptureId,
    ), true);

    const missingProofRoot = path.join(temp, 'broker-missing-proof', 'containment');
    const missingProofTarget = path.join(missingProofRoot, 'target');
    fs.mkdirSync(missingProofTarget, { recursive: true });
    const missingProofRequest = {
      schema: 'environment-factory.object-bound-cleanup-request.v1',
      operation: 'finalize',
      capture_id: sha256(`missing-proof\0${process.pid}`),
      target: pathIdentity(missingProofTarget).realpath,
      target_identity: pathIdentity(missingProofTarget),
      containment_root: pathIdentity(missingProofRoot).realpath,
      containment_root_identity: pathIdentity(missingProofRoot),
    };
    const missingProofResult = runCleanupBroker(cleanupBroker, missingProofRequest);
    assert.strictEqual(missingProofResult.status, 2);
    assert.strictEqual(missingProofResult.value.status, 'blocked');

    const fileRaceRoot = path.join(temp, 'broker-file-replacement', 'containment');
    const fileRaceTarget = path.join(fileRaceRoot, 'target');
    const fileRaceExternal = path.join(path.dirname(fileRaceRoot), 'moved-owned-file.txt');
    fs.mkdirSync(fileRaceTarget, { recursive: true });
    fs.writeFileSync(path.join(fileRaceTarget, 'victim.txt'), 'owned-file\n');
    const fileRace = runCleanupRace(cleanupBroker, cleanupRaceFixture(
      fileRaceRoot, fileRaceTarget, 'file-replacement', fileRaceExternal,
    ));
    assert.strictEqual(fileRace.outcome, 'blocked');
    assert.strictEqual(fileRace.retry_outcome, 'blocked');
    assert.strictEqual(fileRace.injected, true, JSON.stringify(fileRace));
    assert.strictEqual(fs.readFileSync(fileRaceExternal, 'utf8'), 'owned-file\n');
    assert.ok(fileRace.bodies.includes('external-replacement\n'));

    const childRaceRoot = path.join(temp, 'broker-child-move', 'containment');
    const childRaceTarget = path.join(childRaceRoot, 'target');
    const childRaceExternal = path.join(path.dirname(childRaceRoot), 'moved-child');
    fs.mkdirSync(path.join(childRaceTarget, 'child'), { recursive: true });
    fs.writeFileSync(path.join(childRaceTarget, 'child', 'sentinel.txt'), 'child-preserved\n');
    const childRace = runCleanupRace(cleanupBroker, cleanupRaceFixture(
      childRaceRoot, childRaceTarget, 'child-move', childRaceExternal,
    ));
    assert.strictEqual(childRace.outcome, 'blocked');
    assert.strictEqual(childRace.retry_outcome, 'blocked');
    assert.strictEqual(childRace.injected, true, JSON.stringify(childRace));
    assert.strictEqual(
      fs.readFileSync(path.join(childRaceExternal, 'sentinel.txt'), 'utf8'),
      'child-preserved\n',
    );

    const targetRaceRoot = path.join(temp, 'broker-target-move', 'containment');
    const targetRaceTarget = path.join(targetRaceRoot, 'target');
    const targetRaceExternal = path.join(path.dirname(targetRaceRoot), 'moved-target');
    fs.mkdirSync(targetRaceTarget, { recursive: true });
    fs.writeFileSync(path.join(targetRaceTarget, 'sentinel.txt'), 'target-preserved\n');
    const targetRace = runCleanupRace(cleanupBroker, cleanupRaceFixture(
      targetRaceRoot, targetRaceTarget, 'target-move', targetRaceExternal,
    ));
    assert.strictEqual(targetRace.outcome, 'blocked');
    assert.strictEqual(targetRace.retry_outcome, 'blocked');
    assert.strictEqual(targetRace.injected, true, JSON.stringify(targetRace));
    assert.strictEqual(
      fs.readFileSync(path.join(targetRaceExternal, 'sentinel.txt'), 'utf8'),
      'target-preserved\n',
    );

    const rootRaceRoot = path.join(temp, 'broker-root-move', 'containment');
    const rootRaceTarget = path.join(rootRaceRoot, 'target');
    const rootRaceExternal = path.join(path.dirname(rootRaceRoot), 'moved-containment');
    fs.mkdirSync(rootRaceTarget, { recursive: true });
    fs.writeFileSync(path.join(rootRaceTarget, 'sentinel.txt'), 'root-preserved\n');
    const rootRace = runCleanupRace(cleanupBroker, cleanupRaceFixture(
      rootRaceRoot, rootRaceTarget, 'root-move', rootRaceExternal,
    ));
    assert.strictEqual(rootRace.outcome, 'blocked');
    assert.strictEqual(rootRace.retry_outcome, 'blocked');
    assert.strictEqual(rootRace.injected, true, JSON.stringify(rootRace));
    assert.strictEqual(
      fs.readFileSync(path.join(rootRaceExternal, 'target', 'sentinel.txt'), 'utf8'),
      'root-preserved\n',
    );

    const mismatchedBrokerEnvironment = minimalEnvironment({}, 'node-runtime-broker-digest-mismatch');
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256 = '0'.repeat(64);
    assert.throws(() => releaseWorkerEnvironment(mismatchedBrokerEnvironment), /broker digest differs/);
    assert.strictEqual(fs.existsSync(mismatchedBrokerEnvironment.HOME), true);
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256 = sha256(fs.readFileSync(cleanupBroker));
    const workerRequest = {
      operation_id: `node-operation-${process.pid}`,
      repository: { url: 'https://github.com/example/repo.git', commit_sha: 'a'.repeat(40) },
      artifact_root: artifactRoot,
    };
    const ledger = initializeWorkerHomeLedger(workerRequest);
    const operationWorker = allocateDurableWorkerEnvironment({
      ...workerRequest,
      effect_id: `node-operation-${process.pid}/checkout`,
      worker_home_ledger_ref: ledger.cleanup_ref,
    }, 'checkout');
    const operationWorkerReplay = allocateDurableWorkerEnvironment({
      ...workerRequest,
      effect_id: `node-operation-${process.pid}/checkout`,
      worker_home_ledger_ref: ledger.cleanup_ref,
    }, 'checkout');
    const readinessWorker = allocateDurableWorkerEnvironment({
      ...workerRequest,
      effect_id: `node-operation-${process.pid}/readiness`,
      worker_home_ledger_ref: ledger.cleanup_ref,
    }, 'readiness');
    let interruptedWorkerHome = null;
    assert.throws(() => allocateDurableWorkerEnvironment({
      ...workerRequest,
      effect_id: `node-operation-${process.pid}/interrupted-allocation`,
      worker_home_ledger_ref: ledger.cleanup_ref,
    }, 'interrupted-allocation', {}, null, {
      afterEnvironmentCreated(environment) {
        interruptedWorkerHome = environment.HOME;
        throw new Error('simulated crash after worker HOME creation');
      },
    }), /simulated crash/);
    assert.strictEqual(fs.existsSync(interruptedWorkerHome), true);
    assert.throws(() => allocateDurableWorkerEnvironment({
      ...workerRequest,
      effect_id: `node-operation-${process.pid}/interrupted-allocation`,
      worker_home_ledger_ref: ledger.cleanup_ref,
    }, 'interrupted-allocation'), /worker-home allocation has no durable lease or release proof/);
    assert.strictEqual(operationWorker.environment.HOME, operationWorkerReplay.environment.HOME);
    assert.strictEqual(operationWorker.slot_id, operationWorkerReplay.slot_id);
    assert.notStrictEqual(operationWorker.environment.HOME, readinessWorker.environment.HOME);
    const generationRequest = {
      ...workerRequest,
      effect_id: `node-operation-${process.pid}/generation-retry`,
      worker_home_ledger_ref: ledger.cleanup_ref,
    };
    const generationOne = allocateDurableWorkerEnvironment(generationRequest, 'generation-retry');
    assert.strictEqual(recordWorkerEnvironmentRelease(generationOne), true);
    const generationTwo = allocateDurableWorkerEnvironment(generationRequest, 'generation-retry');
    assert.notStrictEqual(generationTwo.environment.HOME, generationOne.environment.HOME);
    assert.notStrictEqual(generationTwo.lease.cleanup_capture_id, generationOne.lease.cleanup_capture_id);
    assert.strictEqual(recordWorkerEnvironmentRelease(generationTwo), true);
    const supervisedRequest = {
      ...workerRequest,
      effect_id: `node-operation-${process.pid}/supervised-reservation`,
      worker_home_ledger_ref: ledger.cleanup_ref,
    };
    const supervisedReservationId = 'b'.repeat(32);
    const supervised = allocateDurableWorkerEnvironment(
      supervisedRequest, 'supervised-reservation', {}, supervisedReservationId,
    );
    assert.strictEqual(recordWorkerEnvironmentRelease(supervised), true);
    assert.throws(
      () => allocateDurableWorkerEnvironment(
        supervisedRequest, 'supervised-reservation', {}, supervisedReservationId,
      ),
      /released worker-home slot cannot reuse a supervised reservation/,
    );
    delete process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER;
    delete process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256;
    assert.strictEqual(recordWorkerEnvironmentRelease(operationWorker), false);
    assert.strictEqual(recordWorkerEnvironmentRelease(readinessWorker), false);
    const workerCleanup = await dispatch('cleanup', {
      effect_id: `node-operation-${process.pid}/cleanup/worker-homes`,
      operation_id: `node-operation-${process.pid}`,
      artifact_root: artifactRoot,
      cleanup_ref: ledger.cleanup_ref,
      worker_home_ledger_ref: ledger.cleanup_ref,
      timeout_seconds: 1,
    });
    assert.strictEqual(workerCleanup.status, 'blocked');
    assert.match(workerCleanup.resource_detail_sha256, /^[0-9a-f]{64}$/);
    assert.strictEqual(workerCleanup.remaining_count, 3);
    assert.strictEqual(fs.existsSync(operationWorker.environment.HOME), true);
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER = cleanupBroker;
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256 = sha256(fs.readFileSync(cleanupBroker));
    captureLeaseBeforeCallerStateUpdate(cleanupBroker, operationWorker.lease);
    assert.strictEqual(fs.existsSync(operationWorker.lease.home), false);
    assert.strictEqual(workerEnvironmentReleaseProven(operationWorker.lease), false);
    captureLeaseBeforeCallerStateUpdate(cleanupBroker, readinessWorker.lease);
    const recoveredWorkerCleanup = await dispatch('cleanup', {
      effect_id: `node-operation-${process.pid}/cleanup/worker-homes`,
      operation_id: `node-operation-${process.pid}`,
      artifact_root: artifactRoot,
      cleanup_ref: ledger.cleanup_ref,
      worker_home_ledger_ref: ledger.cleanup_ref,
      timeout_seconds: 1,
    });
    assert.strictEqual(recoveredWorkerCleanup.status, 'cleaned');
    assert.strictEqual(fs.existsSync(interruptedWorkerHome), false);

    const interruptedAllocationRequest = {
      operation_id: `node-interrupted-allocation-${process.pid}`,
      repository: workerRequest.repository,
      artifact_root: artifactRoot,
    };
    const interruptedAllocationLedger = initializeWorkerHomeLedger(interruptedAllocationRequest);
    let interruptedAllocatedHome = null;
    assert.throws(() => allocateDurableWorkerEnvironment({
      ...interruptedAllocationRequest,
      effect_id: `${interruptedAllocationRequest.operation_id}/checkout`,
      worker_home_ledger_ref: interruptedAllocationLedger.cleanup_ref,
    }, 'checkout', {}, null, {
      afterHomeDirectoryCreated({ home }) {
        interruptedAllocatedHome = home;
        throw new Error('simulated crash after atomic worker HOME publication');
      },
    }), /simulated crash after atomic worker HOME publication/);
    assert.strictEqual(fs.existsSync(interruptedAllocatedHome), true);
    assert.strictEqual(
      fs.existsSync(path.join(interruptedAllocatedHome, '.fkst-worker-home.json')), true,
    );
    const interruptedAllocationCleanup = await dispatch('cleanup', {
      effect_id: `${interruptedAllocationRequest.operation_id}/cleanup/worker-homes`,
      operation_id: interruptedAllocationRequest.operation_id,
      artifact_root: artifactRoot,
      cleanup_ref: interruptedAllocationLedger.cleanup_ref,
      worker_home_ledger_ref: interruptedAllocationLedger.cleanup_ref,
      timeout_seconds: 1,
    });
    assert.strictEqual(interruptedAllocationCleanup.status, 'cleaned');
    assert.strictEqual(fs.existsSync(interruptedAllocatedHome), false);

    const replacementRequest = {
      operation_id: `node-worker-home-replacement-${process.pid}`,
      repository: workerRequest.repository,
      artifact_root: artifactRoot,
    };
    const replacementLedger = initializeWorkerHomeLedger(replacementRequest);
    const externalWorkerHome = path.join(temp, 'external-worker-home');
    fs.mkdirSync(path.join(externalWorkerHome, '.config', 'gh'), { recursive: true, mode: 0o700 });
    const externalCredential = path.join(externalWorkerHome, '.config', 'gh', 'hosts.yml');
    fs.writeFileSync(externalCredential, 'external-credential-sentinel\n');
    let displacedWorkerHome = null;
    assert.throws(() => allocateDurableWorkerEnvironment({
      ...replacementRequest,
      effect_id: `${replacementRequest.operation_id}/checkout`,
      worker_home_ledger_ref: replacementLedger.cleanup_ref,
    }, 'checkout', {}, null, {
      afterHomeDirectoryCreated({ home }) {
        displacedWorkerHome = `${home}.displaced`;
        fs.renameSync(home, displacedWorkerHome);
        fs.symlinkSync(externalWorkerHome, home);
      },
    }), /worker environment home identity changed after allocation/);
    assert.strictEqual(fs.readFileSync(externalCredential, 'utf8'), 'external-credential-sentinel\n');
    const replacementHome = displacedWorkerHome.slice(0, -'.displaced'.length);
    assert.strictEqual(fs.lstatSync(replacementHome).isSymbolicLink(), true);
    fs.unlinkSync(replacementHome);
    const replacementCleanup = await dispatch('cleanup', {
      effect_id: `${replacementRequest.operation_id}/cleanup/worker-homes`,
      operation_id: replacementRequest.operation_id,
      artifact_root: artifactRoot,
      cleanup_ref: replacementLedger.cleanup_ref,
      worker_home_ledger_ref: replacementLedger.cleanup_ref,
      timeout_seconds: 1,
    });
    assert.strictEqual(replacementCleanup.status, 'blocked');
    assert.strictEqual(replacementCleanup.remaining_count, 1);
    assert.strictEqual(fs.existsSync(displacedWorkerHome), true);
    assert.strictEqual(fs.readFileSync(externalCredential, 'utf8'), 'external-credential-sentinel\n');

    const missingReservationRequest = {
      operation_id: `node-worker-home-missing-${process.pid}`,
      repository: workerRequest.repository,
      artifact_root: artifactRoot,
    };
    const missingReservationLedger = initializeWorkerHomeLedger(missingReservationRequest);
    let missingReservedHome = null;
    const missingAllocation = {
      ...missingReservationRequest,
      effect_id: `${missingReservationRequest.operation_id}/checkout`,
      worker_home_ledger_ref: missingReservationLedger.cleanup_ref,
    };
    assert.throws(() => allocateDurableWorkerEnvironment(
      missingAllocation, 'checkout', {}, null, {
        afterEnvironmentCreated(environment) {
          missingReservedHome = environment.HOME;
          throw new Error('simulated crash before worker HOME lease persistence');
        },
      },
    ), /simulated crash before worker HOME lease persistence/);
    fs.rmSync(missingReservedHome, { recursive: true });
    const missingReservationCleanup = await dispatch('cleanup', {
      effect_id: `${missingReservationRequest.operation_id}/cleanup/worker-homes`,
      operation_id: missingReservationRequest.operation_id,
      artifact_root: artifactRoot,
      cleanup_ref: missingReservationLedger.cleanup_ref,
      worker_home_ledger_ref: missingReservationLedger.cleanup_ref,
      timeout_seconds: 1,
    });
    assert.strictEqual(missingReservationCleanup.status, 'blocked');
    assert.strictEqual(missingReservationCleanup.remaining_count, 1);
    assert.throws(
      () => allocateDurableWorkerEnvironment(missingAllocation, 'checkout'),
      /worker-home allocation has no durable lease or release proof/,
    );

    const retainedProcessResource = {
      kind: 'process', pid: 2147483647, pgid: 2147483647,
      process_start_identity: 'not-running', worker_environment_lease: operationWorker.lease,
      cleaned: false,
    };
    assert.strictEqual(resourceIsReleased(retainedProcessResource), false);
    assert.strictEqual(resourceIsReleased(retainedProcessResource, true), true);
    assert.strictEqual(resourceIsReleased({ ...retainedProcessResource, cleaned: true }), true);
    const linkedHomeEnvironment = minimalEnvironment({}, 'linked-home-isolation');
    const linkedHomeLease = workerEnvironmentLease(linkedHomeEnvironment);
    delete process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER;
    delete process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256;
    const originalLinkedHome = `${linkedHomeLease.home}.original`;
    const missingLinkedHomeTarget = `${linkedHomeLease.home}.missing`;
    fs.renameSync(linkedHomeLease.home, originalLinkedHome);
    fs.symlinkSync(missingLinkedHomeTarget, linkedHomeLease.home);
    assert.throws(
      () => releaseWorkerEnvironmentLease(linkedHomeLease),
      /worker environment lease identity changed/,
    );
    assert.strictEqual(fs.lstatSync(linkedHomeLease.home).isSymbolicLink(), true);
    fs.unlinkSync(linkedHomeLease.home);
    fs.renameSync(originalLinkedHome, linkedHomeLease.home);
    assert.strictEqual(releaseWorkerEnvironment(linkedHomeEnvironment), false);
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER = cleanupBroker;
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256 = sha256(fs.readFileSync(cleanupBroker));
    for (const key of [
      'HOME', 'USERPROFILE', 'XDG_CONFIG_HOME', 'GH_CONFIG_DIR', 'GH_TOKEN', 'GITHUB_TOKEN',
      'GIT_CONFIG_GLOBAL', 'GIT_ASKPASS', 'SSH_AUTH_SOCK', 'SSH_ASKPASS', 'CREDENTIAL_HELPER',
      'FKST_WORKER_RUNTIME_ROOT',
      'FKST_OBJECT_BOUND_ALLOCATION_BROKER', 'FKST_OBJECT_BOUND_ALLOCATION_BROKER_SHA256',
      'FKST_OBJECT_BOUND_CLEANUP_BROKER', 'FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256',
    ]) {
      assert.throws(() => minimalEnvironment({ [key]: 'forbidden' }, 'node-runtime-isolation'),
        /forbidden worker authority key/);
    }
    const symlinkRuntime = path.join(temp, 'symlink-runtime');
    const symlinkTarget = path.join(temp, 'symlink-runtime-target');
    fs.mkdirSync(symlinkTarget);
    fs.symlinkSync(symlinkTarget, symlinkRuntime);
    process.env.FKST_WORKER_RUNTIME_ROOT = symlinkRuntime;
    assert.throws(() => minimalEnvironment({}, 'symlink-runtime'), /not a real directory/);
    process.env.FKST_WORKER_RUNTIME_ROOT = path.join(temp, 'worker-runtime');

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
      human_approval_required: false,
      authorization_capability: false,
      execution_authorized: false,
      promotion_authorized: false,
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
      ...boundary, human_approval_required: true,
    }, trustedRepository), /non-authorizing admission prerequisite/);
    assert.throws(() => validateTargetExecutionBoundary({
      ...boundary, authorization_capability: true,
    }, trustedRepository), /non-authorizing admission prerequisite/);
    assert.throws(() => validateTargetExecutionBoundary({
      ...boundary, execution_authorized: true,
    }, trustedRepository), /non-authorizing admission prerequisite/);
    assert.throws(() => validateTargetExecutionBoundary({
      ...boundary, promotion_authorized: true,
    }, trustedRepository), /non-authorizing admission prerequisite/);
    assert.throws(() => validateTargetExecutionBoundary(boundary, trustedRepository, {
      runtimeConfigRef: { kind: 'artifact', ref: `${artifactRoot}/runtime-config.json` },
      artifactRoot,
    }), /Host control namespace/);

    const checkoutSource = path.join(temp, 'workspace-recovery-source');
    fs.mkdirSync(checkoutSource);
    const git = (argv, cwd = checkoutSource) => {
      const result = spawnSync('git', argv, { cwd, encoding: 'utf8', shell: false });
      assert.strictEqual(result.status, 0, result.stderr || result.stdout);
      return String(result.stdout || '').trim();
    };
    git(['init', '--quiet']);
    git(['config', 'user.email', 'workspace-recovery@example.invalid']);
    git(['config', 'user.name', 'Workspace Recovery']);
    fs.writeFileSync(path.join(checkoutSource, 'fixture.txt'), 'immutable fixture\n');
    git(['add', 'fixture.txt']);
    git(['commit', '--quiet', '-m', 'fixture']);
    const checkoutRepository = {
      url: 'https://example.invalid/testing/workspace-recovery.git',
      commit_sha: git(['rev-parse', 'HEAD']),
    };
    const checkoutConfigRef = {
      kind: 'artifact', ref: `${hostRoot}/workspace-recovery-runtime-config.json`,
    };
    fs.mkdirSync(path.dirname(checkoutConfigRef.ref), { recursive: true });
    fs.writeFileSync(checkoutConfigRef.ref, `${stableStringify({
      schema: 'environment-factory.runtime-config.v1',
      state_auth_key: 'workspace-recovery-state-key-which-is-long-enough',
      state_mac_generation: 'workspace-recovery-v1',
      repository_mirrors: { [checkoutRepository.url]: checkoutSource },
      command_environment: {},
      target_execution_boundary: {
        ...boundary,
        repository: checkoutRepository,
        authority: { kind: 'host-policy', ref: 'fixtures/workspace-recovery' },
      },
    })}\n`);
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER = cleanupBroker;
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256 = sha256(fs.readFileSync(cleanupBroker));
    const checkoutInterruptions = [
      ['afterWorkspaceDirectoryCreated', 'directory-created'],
      ['afterWorkspaceResourceRegistered', 'allocation-registered'],
      ['afterSuccessfulCheckout', 'checkout-succeeded'],
    ];
    for (const [hookName, label] of checkoutInterruptions) {
      const operationId = `workspace-recovery-${label}-${process.pid}`;
      const ledgerResult = await dispatch('initialize-worker-home-ledger', {
        effect_id: `${operationId}/worker-home-ledger`, operation_id: operationId,
        repository: checkoutRepository, artifact_root: artifactRoot,
        runtime_config_ref: checkoutConfigRef, timeout_seconds: 20,
      });
      const payload = {
        effect_id: `${operationId}/checkout`, operation_id: operationId,
        repository: checkoutRepository, worker_home_ledger_ref: ledgerResult.cleanup_ref,
        working_directory: '.', artifact_root: artifactRoot,
        runtime_config_ref: checkoutConfigRef, timeout_seconds: 20, output_bytes: 65536,
        resource_budgets: {
          cpu_millis: 60000, memory_mb: 256, disk_mb: 128,
          processes: 8, network_requests: 0, output_bytes: 65536,
        },
      };
      let interrupted = 0;
      await assert.rejects(() => checkoutWithHooks(payload, {
        [hookName]() {
          interrupted += 1;
          throw new Error(`simulated checkout interruption: ${label}`);
        },
      }), new RegExp(`simulated checkout interruption: ${label}`));
      assert.strictEqual(interrupted, 1);
      const recovered = await checkoutWithHooks(payload);
      assert.strictEqual(recovered.status, 'passed');
      assert.strictEqual(recovered.resolved_commit, checkoutRepository.commit_sha);
      const replayed = await checkoutWithHooks(payload);
      assert.deepStrictEqual(replayed, recovered);
    }
    const replacementOperationId = `workspace-replacement-${process.pid}`;
    const replacementWorkspaceLedger = await dispatch('initialize-worker-home-ledger', {
      effect_id: `${replacementOperationId}/worker-home-ledger`,
      operation_id: replacementOperationId, repository: checkoutRepository,
      artifact_root: artifactRoot, runtime_config_ref: checkoutConfigRef, timeout_seconds: 20,
    });
    const externalWorkspace = path.join(temp, 'external-workspace-replacement');
    fs.mkdirSync(externalWorkspace, { mode: 0o700 });
    const externalWorkspaceSentinel = path.join(externalWorkspace, 'sentinel.txt');
    fs.writeFileSync(externalWorkspaceSentinel, 'external-workspace-sentinel\n');
    let replacementWorkspacePath = null;
    let displacedWorkspacePath = null;
    await assert.rejects(() => checkoutWithHooks({
      effect_id: `${replacementOperationId}/checkout`, operation_id: replacementOperationId,
      repository: checkoutRepository,
      worker_home_ledger_ref: replacementWorkspaceLedger.cleanup_ref,
      working_directory: '.', artifact_root: artifactRoot, runtime_config_ref: checkoutConfigRef,
      timeout_seconds: 20, output_bytes: 65536,
      resource_budgets: {
        cpu_millis: 60000, memory_mb: 256, disk_mb: 128, processes: 8,
        network_requests: 0, output_bytes: 65536,
      },
    }, {
      afterWorkspaceDirectoryCreated({ reservation }) {
        replacementWorkspacePath = reservation.path;
        displacedWorkspacePath = `${reservation.path}.displaced`;
        fs.renameSync(reservation.path, displacedWorkspacePath);
        fs.symlinkSync(externalWorkspace, reservation.path);
      },
    }), /workspace identity changed after allocation/);
    assert.strictEqual(
      fs.readFileSync(externalWorkspaceSentinel, 'utf8'), 'external-workspace-sentinel\n',
    );
    assert.strictEqual(fs.lstatSync(replacementWorkspacePath).isSymbolicLink(), true);
    fs.unlinkSync(replacementWorkspacePath);
    await assert.rejects(() => checkoutWithHooks({
      effect_id: `${replacementOperationId}/checkout`, operation_id: replacementOperationId,
      repository: checkoutRepository,
      worker_home_ledger_ref: replacementWorkspaceLedger.cleanup_ref,
      working_directory: '.', artifact_root: artifactRoot, runtime_config_ref: checkoutConfigRef,
      timeout_seconds: 20, output_bytes: 65536,
      resource_budgets: {
        cpu_millis: 60000, memory_mb: 256, disk_mb: 128, processes: 8,
        network_requests: 0, output_bytes: 65536,
      },
    }), /workspace allocation identity is unavailable for recovery/);
    assert.strictEqual(fs.existsSync(displacedWorkspacePath), true);
    assert.strictEqual(
      fs.readFileSync(externalWorkspaceSentinel, 'utf8'), 'external-workspace-sentinel\n',
    );
    delete process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER;
    delete process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256;

    const lockPath = path.join(temp, 'stale.lock');
    fs.mkdirSync(lockPath);
    fs.writeFileSync(path.join(lockPath, 'owner.json'), `${JSON.stringify({
      schema: 'environment-factory.lock-owner.v1',
      pid: 2147483647,
      process_start_identity: 'dead process',
      token: 'stale-owner-token',
    })}\n`);
    assert.throws(
      () => acquireLock(lockPath, 250),
      /legacy lock directory cleanup requires an object-bound broker/,
    );
    assert.strictEqual(fs.lstatSync(lockPath).isDirectory(), true);
    assert.strictEqual(
      JSON.parse(fs.readFileSync(path.join(lockPath, 'owner.json'), 'utf8')).token,
      'stale-owner-token',
    );

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

    const releaseRaceLockPath = path.join(temp, 'release-race.lock');
    const releaseRaceDisplacedPath = path.join(temp, 'release-race.displaced');
    const releaseRace = acquireLock(releaseRaceLockPath, 250);
    const releaseRaceOwner = JSON.parse(fs.readFileSync(releaseRaceLockPath, 'utf8'));
    const releaseRaceSuccessor = {
      ...releaseRaceOwner,
      token: '2'.repeat(32),
    };
    const originalRenameSync = fs.renameSync;
    let releaseRaceInjected = false;
    fs.renameSync = (sourcePath, destinationPath) => {
      if (!releaseRaceInjected && sourcePath === releaseRaceLockPath) {
        releaseRaceInjected = true;
        originalRenameSync(sourcePath, releaseRaceDisplacedPath);
        fs.writeFileSync(sourcePath, `${stableStringify(releaseRaceSuccessor)}\n`, { flag: 'wx' });
      }
      return originalRenameSync(sourcePath, destinationPath);
    };
    try {
      releaseRace();
    } finally {
      fs.renameSync = originalRenameSync;
    }
    assert.strictEqual(releaseRaceInjected, true);
    assert.strictEqual(fs.readFileSync(releaseRaceLockPath, 'utf8'),
      `${stableStringify(releaseRaceSuccessor)}\n`);
    assert.strictEqual(fs.existsSync(releaseRaceDisplacedPath), true);
    fs.unlinkSync(releaseRaceLockPath);

    const takeoverRaceLockPath = path.join(temp, 'takeover-race.lock');
    const takeoverRaceDisplacedPath = path.join(temp, 'takeover-race.displaced');
    const takeoverRaceStaleOwner = {
      schema: 'environment-factory.lock-owner.v1',
      pid: 2147483647,
      process_start_identity: 'dead process',
      token: '3'.repeat(32),
    };
    const takeoverRaceSuccessor = {
      ...releaseRaceOwner,
      token: '4'.repeat(32),
    };
    fs.writeFileSync(takeoverRaceLockPath, `${stableStringify(takeoverRaceStaleOwner)}\n`);
    let takeoverRaceInjected = false;
    fs.renameSync = (sourcePath, destinationPath) => {
      if (!takeoverRaceInjected && sourcePath === takeoverRaceLockPath) {
        takeoverRaceInjected = true;
        originalRenameSync(sourcePath, takeoverRaceDisplacedPath);
        fs.writeFileSync(sourcePath, `${stableStringify(takeoverRaceSuccessor)}\n`, { flag: 'wx' });
      }
      return originalRenameSync(sourcePath, destinationPath);
    };
    try {
      assert.throws(() => acquireLock(takeoverRaceLockPath, 250), /lock timeout/);
    } finally {
      fs.renameSync = originalRenameSync;
    }
    assert.strictEqual(takeoverRaceInjected, true);
    assert.strictEqual(fs.readFileSync(takeoverRaceLockPath, 'utf8'),
      `${stableStringify(takeoverRaceSuccessor)}\n`);
    assert.strictEqual(fs.existsSync(takeoverRaceDisplacedPath), true);
    fs.unlinkSync(takeoverRaceLockPath);

    const pendingRaceLockPath = path.join(temp, 'pending-race.lock');
    const pendingRaceStaleOwner = {
      schema: 'environment-factory.lock-owner.v1',
      pid: 2147483647,
      process_start_identity: 'dead process',
      token: '5'.repeat(32),
    };
    const pendingRacePath = `${pendingRaceLockPath}.owner.${pendingRaceStaleOwner.pid}.${pendingRaceStaleOwner.token}`;
    const pendingRaceDisplacedPath = path.join(temp, 'pending-race.displaced');
    const pendingRaceSuccessor = `${stableStringify(pendingRaceStaleOwner)}\n`;
    fs.writeFileSync(pendingRacePath, `${stableStringify(pendingRaceStaleOwner)}\n`);
    fs.linkSync(pendingRacePath, pendingRaceLockPath);
    let pendingRaceInjected = false;
    fs.renameSync = (sourcePath, destinationPath) => {
      if (!pendingRaceInjected && sourcePath === pendingRacePath) {
        pendingRaceInjected = true;
        originalRenameSync(sourcePath, pendingRaceDisplacedPath);
        fs.writeFileSync(sourcePath, pendingRaceSuccessor, { flag: 'wx' });
      }
      return originalRenameSync(sourcePath, destinationPath);
    };
    let releasePendingRace;
    try {
      releasePendingRace = acquireLock(pendingRaceLockPath, 250);
    } finally {
      fs.renameSync = originalRenameSync;
    }
    assert.strictEqual(pendingRaceInjected, true);
    assert.strictEqual(fs.readFileSync(pendingRacePath, 'utf8'), pendingRaceSuccessor);
    assert.strictEqual(fs.existsSync(pendingRaceDisplacedPath), true);
    releasePendingRace();
    assert.strictEqual(fs.existsSync(pendingRaceLockPath), false);
    fs.unlinkSync(pendingRacePath);

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

    const oversizedMetadataPath = path.join(temp, 'oversized-lock-metadata.json');
    fs.writeFileSync(oversizedMetadataPath, 'x'.repeat(8193));
    assert.throws(
      () => readBoundedRegularFile(oversizedMetadataPath, 8192),
      /bounded regular file is invalid/,
    );
    const linkedMetadataPath = path.join(temp, 'linked-lock-metadata.json');
    fs.symlinkSync(oversizedMetadataPath, linkedMetadataPath);
    assert.throws(() => readBoundedRegularFile(linkedMetadataPath, 8192));
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER = cleanupBroker;
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256 = sha256(fs.readFileSync(cleanupBroker));

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
    const supervisedWorkerRequest = {
      operation_id: `supervised-node-operation-${process.pid}`,
      effect_id: 'crash-window-effect',
      repository: trustedRepository,
    };
    const supervisedLedger = initializeWorkerHomeLedger(supervisedWorkerRequest);
    supervisedWorkerRequest.worker_home_ledger_ref = supervisedLedger.cleanup_ref;
    const supervisedPurpose = 'supervised:crash-window-effect';
    let launchedSupervisorPid = null;
    let firstStartupAllocation = null;
    const interrupted = startOrRecoverSupervisedProcess({
      claimPath: startupClaim,
      argv: startupArgv,
      cwd: temp,
      createEnvironment(reservation) {
        firstStartupAllocation = allocateDurableWorkerEnvironment(
          supervisedWorkerRequest, supervisedPurpose, {}, reservation.reservation_id,
        );
        firstStartupEnvironment = firstStartupAllocation.environment;
        firstLease = workerEnvironmentLease(firstStartupEnvironment);
        return {
          environment: firstStartupEnvironment,
          worker_home_slot_id: firstStartupAllocation.slot_id,
        };
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
    assert.strictEqual(recoveredStartup.resource.worker_home_slot_id, firstStartupAllocation.slot_id);
    assert.deepStrictEqual(
      verifyPersistedWorkerEnvironment(
        supervisedWorkerRequest,
        supervisedPurpose,
        {},
        recoveredStartup.resource.worker_home_slot_id,
        recoveredStartup.resource.worker_environment_lease,
      ),
      {
        identity: firstStartupAllocation.identity,
        lease: firstStartupAllocation.lease,
        slot_id: firstStartupAllocation.slot_id,
      },
    );
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
    assert.strictEqual(replayedStartup.resource.worker_home_slot_id, firstStartupAllocation.slot_id);
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

    let synchronizedSubstitutionLease = null;
    const synchronizedSubstitutionMarker = path.join(temp, 'supervised-synchronized-substitution.txt');
    const synchronizedClaimPath = path.join(temp, 'supervised-synchronized-substitution', 'claim.json');
    const synchronizedSubstitution = startOrRecoverSupervisedProcess({
      claimPath: synchronizedClaimPath,
      argv: [process.execPath, '-e', 'process.exit(0)'],
      cwd: temp,
      createEnvironment(reservation) {
        const environment = minimalEnvironment(
          {}, 'supervised-synchronized-substitution', reservation.reservation_id,
        );
        synchronizedSubstitutionLease = workerEnvironmentLease(environment);
        return environment;
      },
      binding: { ...startupBinding, effect_id: 'synchronized-substitution-effect' },
      registrationTimeoutMs: 250,
      beforeSupervisorLaunch(claim) {
        const replacement = {
          schema: 'fkst.supervised-process-launch.v1',
          startup_token: claim.startup_token,
          binding_sha256: claim.binding_sha256,
          claim_path: synchronizedClaimPath,
          argv: [process.execPath, '-e',
            `require('fs').writeFileSync(${JSON.stringify(synchronizedSubstitutionMarker)}, 'bad')`],
          cwd: temp,
          inherited_fd_count: 0,
          inherited_fd_identities: [],
        };
        const replacementBody = `${stableStringify(replacement)}\n`;
        fs.unlinkSync(claim.launch_spec_path);
        fs.writeFileSync(claim.launch_spec_path, replacementBody, { flag: 'wx', mode: 0o600 });
        const stat = fs.lstatSync(claim.launch_spec_path);
        const substitutedClaim = JSON.parse(fs.readFileSync(synchronizedClaimPath, 'utf8'));
        substitutedClaim.launch_spec_identity = {
          device: String(stat.dev), inode: String(stat.ino), size: stat.size, mode: stat.mode,
        };
        substitutedClaim.launch_spec_sha256 = sha256(replacementBody);
        substitutedClaim.argv_sha256 = sha256(stableStringify(replacement.argv));
        substitutedClaim.worker_environment_reservation.binding_sha256 = sha256(stableStringify({
          binding_sha256: substitutedClaim.binding_sha256,
          argv_sha256: substitutedClaim.argv_sha256,
          cwd: substitutedClaim.cwd,
          inherited_fd_identities: substitutedClaim.inherited_fd_identities,
        }));
        fs.writeFileSync(synchronizedClaimPath, `${stableStringify(substitutedClaim)}\n`);
      },
    });
    assert.strictEqual(synchronizedSubstitution.state, 'revoked');
    assert.strictEqual(fs.existsSync(synchronizedSubstitutionMarker), false);
    assert.strictEqual(fs.existsSync(synchronizedSubstitutionLease.home), false);

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

    const anchoredCwd = path.join(temp, 'anchored-command-cwd');
    const movedAnchoredCwd = path.join(temp, 'anchored-command-cwd-moved');
    fs.mkdirSync(anchoredCwd);
    fs.writeFileSync(path.join(anchoredCwd, 'identity.txt'), 'validated-object\n');
    const anchoredCwdIdentity = pathIdentity(anchoredCwd);
    const anchoredResult = await runMeasuredCommand(['/bin/cat', 'identity.txt'], {
      cwd: anchoredCwd,
      cwdIdentity: anchoredCwdIdentity,
      timeoutMs: 2_000,
      outputBytes: 1024,
      afterCwdAnchored() {
        fs.renameSync(anchoredCwd, movedAnchoredCwd);
        fs.mkdirSync(anchoredCwd);
        fs.writeFileSync(path.join(anchoredCwd, 'identity.txt'), 'replacement-object\n');
      },
    });
    assert.strictEqual(anchoredResult.exitCode, 0, anchoredResult.stderr);
    assert.strictEqual(anchoredResult.stdout, 'validated-object\n');

    const supervisedCwd = path.join(temp, 'supervised-cwd-race');
    const movedSupervisedCwd = path.join(temp, 'supervised-cwd-race-moved');
    const supervisedCwdOutput = path.join(temp, 'supervised-cwd-race-output.txt');
    fs.mkdirSync(supervisedCwd);
    const supervisedCwdIdentity = pathIdentity(supervisedCwd);
    let supervisedCwdLease = null;
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER = cleanupBroker;
    process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256 = sha256(fs.readFileSync(cleanupBroker));
    const supervisedCwdRace = startOrRecoverSupervisedProcess({
      claimPath: path.join(temp, 'supervised-cwd-race-claim.json'),
      argv: [process.execPath, '-e', `require('fs').writeFileSync(${JSON.stringify(supervisedCwdOutput)}, 'ran')`],
      cwd: supervisedCwd,
      cwdIdentity: supervisedCwdIdentity,
      createEnvironment(reservation) {
        const environment = minimalEnvironment({}, 'supervised-cwd-race', reservation.reservation_id);
        supervisedCwdLease = workerEnvironmentLease(environment);
        return environment;
      },
      binding: { ...startupBinding, effect_id: 'supervised-cwd-race' },
      registrationTimeoutMs: 250,
      beforeSupervisorLaunch() {
        fs.renameSync(supervisedCwd, movedSupervisedCwd);
        fs.mkdirSync(supervisedCwd);
      },
    });
    assert.strictEqual(supervisedCwdRace.state, 'revoked');
    assert.strictEqual(fs.existsSync(supervisedCwdOutput), false);
    assert.strictEqual(fs.existsSync(supervisedCwdLease.home), false);
    delete process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER;
    delete process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256;

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

    const substitutedWorkspace = path.join(temp, 'substituted-workspace');
    const originalWorkspace = `${substitutedWorkspace}.original`;
    fs.mkdirSync(substitutedWorkspace);
    const substitutedResourceRef = `substituted-workspace-${process.pid}`;
    const substitutedResourcePath = path.join(
      process.env.FKST_DURABLE_ROOT,
      'environment-factory',
      'resources',
      `${sha256(substitutedResourceRef)}.json`,
    );
    const substitutedOperationId = `substituted-${process.pid}`;
    fs.writeFileSync(substitutedResourcePath, `${JSON.stringify({
      schema: 'environment-factory.resource.v1',
      kind: 'workspace',
      operation_id: substitutedOperationId,
      ref: substitutedResourceRef,
      path: substitutedWorkspace,
      path_identity: pathIdentity(substitutedWorkspace),
      containment_root: temp,
      containment_root_identity: pathIdentity(temp),
      cleanup_capture_id: 'b'.repeat(64),
      cleaned: false,
    })}\n`);
    fs.renameSync(substitutedWorkspace, originalWorkspace);
    fs.mkdirSync(substitutedWorkspace);
    const externalSentinel = path.join(substitutedWorkspace, 'external-sentinel.txt');
    fs.writeFileSync(externalSentinel, 'externally-owned\n');
    await assert.rejects(() => dispatch('cleanup', {
      effect_id: `${substitutedOperationId}/cleanup/workspace`,
      operation_id: substitutedOperationId,
      artifact_root: artifactRoot,
      cleanup_ref: { kind: 'resource-cleanup', ref: substitutedResourceRef },
      timeout_seconds: 1,
    }), /owned directory identity changed/);
    assert.strictEqual(fs.readFileSync(externalSentinel, 'utf8'), 'externally-owned\n');
    assert.strictEqual(fs.existsSync(originalWorkspace), true);

    const linkedWorkspace = path.join(temp, 'linked-workspace');
    const linkedWorkspaceTarget = path.join(temp, 'missing-external-workspace');
    fs.mkdirSync(linkedWorkspace);
    const linkedResourceRef = `linked-workspace-${process.pid}`;
    const linkedResourcePath = path.join(
      process.env.FKST_DURABLE_ROOT,
      'environment-factory',
      'resources',
      `${sha256(linkedResourceRef)}.json`,
    );
    const linkedOperationId = `linked-${process.pid}`;
    fs.writeFileSync(linkedResourcePath, `${JSON.stringify({
      schema: 'environment-factory.resource.v1',
      kind: 'workspace',
      operation_id: linkedOperationId,
      ref: linkedResourceRef,
      path: linkedWorkspace,
      path_identity: pathIdentity(linkedWorkspace),
      containment_root: temp,
      containment_root_identity: pathIdentity(temp),
      cleanup_capture_id: 'c'.repeat(64),
      cleaned: false,
    })}\n`);
    fs.rmdirSync(linkedWorkspace);
    fs.symlinkSync(linkedWorkspaceTarget, linkedWorkspace);
    await assert.rejects(() => dispatch('cleanup', {
      effect_id: `${linkedOperationId}/cleanup/workspace`,
      operation_id: linkedOperationId,
      artifact_root: artifactRoot,
      cleanup_ref: { kind: 'resource-cleanup', ref: linkedResourceRef },
      timeout_seconds: 1,
    }));
    assert.strictEqual(fs.lstatSync(linkedWorkspace).isSymbolicLink(), true);

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
    if (previousWorkerRuntime === undefined) delete process.env.FKST_WORKER_RUNTIME_ROOT;
    else process.env.FKST_WORKER_RUNTIME_ROOT = previousWorkerRuntime;
    if (previousCleanupBroker === undefined) delete process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER;
    else process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER = previousCleanupBroker;
    if (previousCleanupBrokerSha256 === undefined) delete process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256;
    else process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256 = previousCleanupBrokerSha256;
    await removeTreeEventually(temp);
    await removeTreeEventually(artifactRoot);
    await removeTreeEventually(hostRoot);
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
