'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const store = require('../bin/durable-host-store');
const { releaseWorkspaceResource } = require('../bin/generic-host-runtime');
const common = require('../../../packages/environment-factory/bin/runtime/common');
const { create } = require('../bin/worker-home-ledger');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'generic-host-worker-ledger-'));
const durable = path.join(root, 'durable');
const runtime = path.join(root, 'runtime');
process.env.FKST_RUNTIME_ROOT = runtime;
process.env.FKST_DURABLE_ROOT = durable;
const cleanupBroker = path.resolve(
  __dirname, '..', '..', '..', 'packages', 'environment-factory', 'bin',
  'object-bound-cleanup-broker.py',
);
process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER = cleanupBroker;
process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256 = common.sha256(fs.readFileSync(cleanupBroker));
const stable = store.stable;
const sha256 = (value) => crypto.createHash('sha256').update(String(value)).digest('hex');
const records = new Map();
const copy = (value) => value == null ? value : JSON.parse(stable(value));
const read = (key) => copy(records.get(key) || null);
const cas = (key, value, version) => {
  const current = records.get(key);
  const currentVersion = current ? current.version : 0;
  if (currentVersion !== version) {
    return { saved: false, stale: true, version: currentVersion, value: copy(current) };
  }
  records.set(key, copy(value));
  return { saved: true, stale: false, version: value.version, value: copy(value) };
};
const immutable = (key, value) => {
  const current = records.get(key);
  if (current) return { written: false, replayed: stable(current) === stable(value), value: copy(current) };
  records.set(key, copy(value));
  return { written: true, replayed: false, value: copy(value) };
};
const resourceKey = (ref) => `environment-factory/resources/${sha256(stable(ref))}`;
const artifacts = new Map();
const ledger = create({
  artifactWrite: (_projectRoot, ref, value) => {
    const body = `${stable(value)}\n`;
    const digest = sha256(body);
    const prior = artifacts.get(ref);
    if (prior && prior.body !== body) throw new Error('immutable artifact differs');
    artifacts.set(ref, { body, value, digest });
    return { written: true, replayed: Boolean(prior), digest };
  },
  fail: (message) => { throw new Error(message); },
  minimalEnvironment: common.minimalEnvironment,
  recordCas: (_root, key, value, version) => cas(key, value, version),
  recordImmutable: (_root, key, value) => immutable(key, value),
  recordRead: (_root, key) => read(key),
  releaseWorkerEnvironmentLease: common.releaseWorkerEnvironmentLease,
  releaseWorkerEnvironmentReservation: common.releaseWorkerEnvironmentReservation,
  reservationMatchesLease: common.reservationMatchesLease,
  resourceKey,
  sha256,
  stable,
  verifyWorkerEnvironmentLease: common.verifyWorkerEnvironmentLease,
  workerEnvironmentLease: common.workerEnvironmentLease,
  workerEnvironmentReleaseProven: common.workerEnvironmentReleaseProven,
  workerEnvironmentReservation: common.workerEnvironmentReservation,
});

const repository = { url: 'https://example.invalid/fixture.git', commit_sha: 'a'.repeat(40) };
const base = { operation_id: 'worker-ledger-test', repository };
const initialized = ledger.initialize(durable, base);
assert.equal(initialized.status, 'passed');
assert.match(initialized.ledger_id, /^[0-9a-f]{64}$/);

for (const key of ['GH_TOKEN', 'GITHUB_TOKEN', 'SSH_AUTH_SOCK', 'GIT_ASKPASS', 'SSH_ASKPASS']) {
  process.env[key] = 'must-not-be-inherited';
}
const checkoutRequest = {
  ...base, effect_id: 'checkout-effect', worker_home_ledger_ref: initialized.cleanup_ref,
};
const checkout = ledger.allocate(durable, checkoutRequest, 'checkout', {});
const replay = ledger.allocate(durable, checkoutRequest, 'checkout', {});
const readiness = ledger.allocate(durable, {
  ...base, effect_id: 'readiness-effect', worker_home_ledger_ref: initialized.cleanup_ref,
}, 'readiness:1:http', {});
let interruptedWorkerHome = null;
assert.throws(() => ledger.allocate(durable, {
  ...base, effect_id: 'interrupted-allocation', worker_home_ledger_ref: initialized.cleanup_ref,
}, 'interrupted-allocation', {}, null, {
  afterEnvironmentCreated(environment) {
    interruptedWorkerHome = environment.HOME;
    throw new Error('simulated crash after worker HOME creation');
  },
}), /simulated crash/);
assert.equal(fs.existsSync(interruptedWorkerHome), true);
const externalWorkerHome = path.join(root, 'external-worker-home');
fs.mkdirSync(path.join(externalWorkerHome, '.config', 'gh'), { recursive: true, mode: 0o700 });
const externalCredential = path.join(externalWorkerHome, '.config', 'gh', 'hosts.yml');
fs.writeFileSync(externalCredential, 'external-credential-sentinel\n');
let displacedWorkerHome = null;
assert.throws(() => ledger.allocate(durable, {
  ...base, effect_id: 'displaced-allocation', worker_home_ledger_ref: initialized.cleanup_ref,
}, 'displaced-allocation', {}, null, {
  afterHomeDirectoryCreated({ home }) {
    displacedWorkerHome = `${home}.displaced`;
    fs.renameSync(home, displacedWorkerHome);
    fs.symlinkSync(externalWorkerHome, home);
  },
}), /worker environment home identity changed after allocation/);
const displacedExpectedHome = displacedWorkerHome.slice(0, -'.displaced'.length);
assert.equal(fs.lstatSync(displacedExpectedHome).isSymbolicLink(), true);
assert.equal(fs.readFileSync(externalCredential, 'utf8'), 'external-credential-sentinel\n');
assert.equal(checkout.slot_id, replay.slot_id);
assert.equal(checkout.environment.HOME, replay.environment.HOME);
assert.notEqual(checkout.environment.HOME, readiness.environment.HOME);
for (const environment of [checkout.environment, readiness.environment]) {
  for (const key of ['GH_TOKEN', 'GITHUB_TOKEN', 'SSH_AUTH_SOCK', 'GIT_ASKPASS', 'SSH_ASKPASS']) {
    assert.equal(Object.hasOwn(environment, key), false);
  }
  assert.equal(common.verifyWorkerEnvironment(environment), true);
}

const current = read('environment-factory/worker-home-ledger');
assert.equal(current.entries.length, 4);
assert.equal(current.entries.filter((entry) => entry.state === 'allocated').length, 2);
assert.equal(current.entries.filter((entry) => entry.state === 'reserved').length, 2);

const resource = read(resourceKey(initialized.cleanup_ref));
assert.equal(ledger.releaseProven(
  durable, checkoutRequest, checkout.slot_id, checkout.lease,
), false);
delete process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER;
delete process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256;
const cleanup = ledger.cleanup(durable, root, {
  ...base,
  artifact_root: '.testing/runs/worker-ledger-test/environment',
  cleanup_ref: initialized.cleanup_ref,
}, resource);
assert.equal(cleanup.cleaned, false);
assert.equal(cleanup.remaining_count >= 1, true);
const snapshot = artifacts.get(cleanup.resource_detail_ref.ref).value;
assert.equal(snapshot.schema, 'environment-factory.worker-home-retention.v1');
assert.equal(snapshot.operation_id, base.operation_id);
assert.equal(snapshot.ledger_id, initialized.ledger_id);
assert.equal(snapshot.remaining_count, cleanup.remaining_count);
assert.equal(stable(snapshot).includes(root), false);
assert.equal(Object.hasOwn(snapshot.entries[0], 'home'), false);

process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER = cleanupBroker;
process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256 = sha256(fs.readFileSync(cleanupBroker));
fs.unlinkSync(displacedExpectedHome);
const recoveredCleanup = ledger.cleanup(durable, root, {
  ...base,
  artifact_root: '.testing/runs/worker-ledger-test/environment',
  cleanup_ref: initialized.cleanup_ref,
}, resource);
assert.equal(recoveredCleanup.cleaned, false);
const recoveredLedger = read('environment-factory/worker-home-ledger');
assert.equal(recoveredCleanup.remaining_count, 1, stable(recoveredLedger));
assert.equal(fs.existsSync(interruptedWorkerHome), false);
assert.equal(fs.existsSync(displacedWorkerHome), true);
assert.equal(fs.readFileSync(externalCredential, 'utf8'), 'external-credential-sentinel\n');
assert.equal(ledger.releaseProven(
  durable, checkoutRequest, checkout.slot_id, checkout.lease,
), true);
const workspaceRoot = path.join(root, 'workspaces');
const workspace = path.join(workspaceRoot, 'run-workspace');
fs.mkdirSync(workspace, { recursive: true });
fs.writeFileSync(path.join(workspace, 'owned.txt'), 'owned\n');
const workspaceIdentity = common.pathIdentity(workspace);
const workspaceRootIdentity = common.pathIdentity(workspaceRoot);
const cleanupCaptureId = sha256('generic-host-workspace-cleanup-recovery');
const captureRequest = {
  schema: 'environment-factory.object-bound-cleanup-request.v1',
  operation: 'capture-delete',
  capture_id: cleanupCaptureId,
  target: workspaceIdentity.realpath,
  target_identity: workspaceIdentity,
  containment_root: workspaceRootIdentity.realpath,
  containment_root_identity: workspaceRootIdentity,
};
const captureStateRoot = path.join(durable, 'cleanup-captures');
fs.mkdirSync(captureStateRoot, { recursive: true, mode: 0o700 });
fs.writeFileSync(path.join(captureStateRoot, `${cleanupCaptureId}.json`), `${stable({
  schema: 'environment-factory.object-bound-cleanup-capture-state.v1',
  capture_id: cleanupCaptureId,
  target: workspaceIdentity.realpath,
  target_identity: workspaceIdentity,
  containment_root: workspaceRootIdentity.realpath,
  containment_root_identity: workspaceRootIdentity,
  state: 'pending',
})}\n`, { flag: 'wx' });
const brokerResult = spawnSync('/usr/bin/python3', ['-I', cleanupBroker], {
  input: `${stable(captureRequest)}\n`, encoding: 'utf8', env: {}, shell: false,
});
assert.equal(brokerResult.status, 0, brokerResult.stderr || brokerResult.stdout);
assert.equal(fs.existsSync(workspace), false);
assert.equal(common.ownedDirectoryReleaseProven(
  workspace, workspaceIdentity, workspaceRoot, cleanupCaptureId,
), false);
assert.equal(releaseWorkspaceResource({
  run_id: base.operation_id, workspace_root: workspace, temp_root: workspaceRoot,
}, {
  operation_id: base.operation_id,
  path: workspace,
  path_identity: workspaceIdentity,
  ownership_token: 'owned-workspace-token',
  cleanup_capture_id: cleanupCaptureId,
}), true);
assert.equal(JSON.parse(fs.readFileSync(
  path.join(captureStateRoot, `${cleanupCaptureId}.json`), 'utf8',
)).state, 'released');
assert.equal(common.ownedDirectoryReleaseProven(
  workspace, workspaceIdentity, workspaceRoot, cleanupCaptureId,
), true);

fs.rmSync(root, { recursive: true, force: true });
