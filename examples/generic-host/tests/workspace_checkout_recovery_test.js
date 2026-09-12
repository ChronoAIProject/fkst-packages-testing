'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const store = require('../bin/durable-host-store');
const { dispatch } = require('../bin/generic-host-runtime');
const common = require('../../../packages/environment-factory/bin/runtime/common');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'generic-host-workspace-recovery-'));
const durable = path.join(root, 'durable');
const runtime = path.join(root, 'runtime');
const projectRoot = path.join(root, 'project');
const sourceRoot = path.join(root, 'source');
fs.mkdirSync(projectRoot);
fs.mkdirSync(sourceRoot);
process.env.FKST_DURABLE_ROOT = durable;
process.env.FKST_GENERIC_HOST_DURABLE_ROOT = durable;
process.env.FKST_RUNTIME_ROOT = runtime;
const cleanupBroker = path.resolve(
  __dirname, '..', '..', '..', 'packages', 'environment-factory', 'bin',
  'object-bound-cleanup-broker.py',
);
process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER = cleanupBroker;
process.env.FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256 = common.sha256(fs.readFileSync(cleanupBroker));

function git(argv, cwd = sourceRoot) {
  const result = spawnSync('git', argv, { cwd, encoding: 'utf8', shell: false });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return String(result.stdout || '').trim();
}

git(['init', '--quiet']);
git(['config', 'user.email', 'workspace-recovery@example.invalid']);
git(['config', 'user.name', 'Workspace Recovery']);
fs.writeFileSync(path.join(sourceRoot, 'fixture.txt'), 'immutable fixture\n');
git(['add', 'fixture.txt']);
git(['commit', '--quiet', '-m', 'fixture']);
const repository = {
  url: 'https://example.invalid/testing/generic-host-workspace.git',
  commit_sha: git(['rev-parse', 'HEAD']),
};
fs.writeFileSync(path.join(sourceRoot, 'fixture.txt'), 'alternate fixture\n');
git(['commit', '--quiet', '-am', 'alternate fixture']);
const alternateCommit = git(['rev-parse', 'HEAD']);
const boundary = {
  schema: 'testing-host.target-execution-boundary.v1',
  mode: 'trusted-fixture-exact',
  target_class: 'host-owned-exact-trusted-fixture',
  repository,
  authority: { kind: 'host-policy', ref: 'fixtures/generic-host-workspace-recovery' },
  policy_revision: 'generic-host-workspace-recovery-v1',
  human_approval_required: false,
  authorization_capability: false,
  execution_authorized: false,
  promotion_authorized: false,
};

function initializeRun(label) {
  const runId = `workspace-recovery-${label}`;
  const tempRoot = path.join(runtime, runId);
  const workspaceRoot = path.join(tempRoot, 'checkout');
  const runRoot = path.join(durable, 'generic-host', runId);
  const config = {
    schema: 'generic-host.durable-workflow-qa.v1',
    project_root: projectRoot,
    run_id: runId,
    artifact_root: `.testing/runs/${runId}`,
    temp_root: tempRoot,
    workspace_root: workspaceRoot,
    source_root: sourceRoot,
    commit_sha: repository.commit_sha,
    port: 43191,
    repository,
    profile: { repository, working_directory: '.' },
    target_execution_boundary: boundary,
    command_environment: {},
  };
  const stored = store.execute({
    root: runRoot, operation: 'record-immutable', key: 'generic-host/config', value: config,
  });
  assert.equal(stored.written, true);
  const base = {
    operation_id: runId,
    repository,
    artifact_root: config.artifact_root,
    runtime_config_ref: { kind: 'artifact', ref: '.testing/host/generic-host-runtime.json' },
    timeout_seconds: 20,
  };
  const ledger = dispatch('initialize-worker-home-ledger', {
    ...base, effect_id: `${runId}/worker-home-ledger`,
  }, projectRoot);
  return {
    config,
    payload: {
      ...base,
      effect_id: `${runId}/checkout`,
      worker_home_ledger_ref: ledger.cleanup_ref,
      working_directory: '.',
    },
  };
}

try {
  const interruptions = [
    ['afterWorkspaceDirectoryCreated', 'directory-created'],
    ['afterWorkspaceResourceRegistered', 'allocation-registered'],
    ['afterSuccessfulCheckout', 'checkout-succeeded'],
    ['afterFinalWorkspaceResourceRegistered', 'resource-registered'],
  ];
  for (const [hookName, label] of interruptions) {
    const { config, payload } = initializeRun(label);
    assert.throws(() => dispatch('checkout', payload, projectRoot, {
      [hookName]() { throw new Error(`simulated checkout interruption: ${label}`); },
    }), new RegExp(`simulated checkout interruption: ${label}`));
    const recovered = dispatch('checkout', payload, projectRoot);
    assert.equal(recovered.status, 'passed');
    assert.equal(recovered.resolved_commit, repository.commit_sha);
    assert.deepEqual(dispatch('checkout', payload, projectRoot), recovered);
    assert.equal(git(['rev-parse', 'HEAD'], config.workspace_root), repository.commit_sha);
    assert.equal(git(['status', '--porcelain', '--untracked-files=no'], config.workspace_root), '');
  }

  const missing = initializeRun('allocated-path-missing');
  assert.throws(() => dispatch('checkout', missing.payload, projectRoot, {
    afterWorkspaceResourceRegistered() {
      throw new Error('simulated interruption after workspace identity persistence');
    },
  }), /simulated interruption after workspace identity persistence/);
  fs.rmSync(missing.config.workspace_root, { recursive: true });
  assert.throws(
    () => dispatch('checkout', missing.payload, projectRoot),
    /workspace reserved object is missing without release proof/,
  );

  const released = initializeRun('released-before-reallocation');
  assert.throws(() => dispatch('checkout', released.payload, projectRoot, {
    afterWorkspaceResourceRegistered() {
      throw new Error('simulated interruption after workspace identity persistence');
    },
  }), /simulated interruption after workspace identity persistence/);
  assert.throws(() => dispatch('checkout', released.payload, projectRoot, {
    afterWorkspaceRecoveryReleased() {
      throw new Error('simulated interruption after workspace release proof');
    },
  }), /simulated interruption after workspace release proof/);
  assert.equal(fs.existsSync(released.config.workspace_root), false);
  const releasedRecovery = dispatch('checkout', released.payload, projectRoot);
  assert.equal(releasedRecovery.status, 'passed');
  assert.equal(releasedRecovery.resolved_commit, repository.commit_sha);

  const changedHead = initializeRun('registered-head-changed');
  assert.throws(() => dispatch('checkout', changedHead.payload, projectRoot, {
    afterFinalWorkspaceResourceRegistered() {
      throw new Error('simulated interruption after final workspace registration');
    },
  }), /simulated interruption after final workspace registration/);
  git(['checkout', '--quiet', alternateCommit], changedHead.config.workspace_root);
  assert.throws(
    () => dispatch('checkout', changedHead.payload, projectRoot),
    /workspace resolved commit differs from its durable binding/,
  );

  const changedContent = initializeRun('registered-content-changed');
  assert.throws(() => dispatch('checkout', changedContent.payload, projectRoot, {
    afterFinalWorkspaceResourceRegistered() {
      throw new Error('simulated interruption after final workspace registration');
    },
  }), /simulated interruption after final workspace registration/);
  fs.appendFileSync(path.join(changedContent.config.workspace_root, 'fixture.txt'), 'tampered\n');
  assert.throws(
    () => dispatch('checkout', changedContent.payload, projectRoot),
    /workspace tracked working tree differs from its durable binding/,
  );

  const application = initializeRun('application-content-changed');
  const applicationCheckout = dispatch('checkout', application.payload, projectRoot);
  fs.appendFileSync(path.join(application.config.workspace_root, 'fixture.txt'), 'tampered\n');
  assert.throws(() => dispatch('fixture-start-application', {
    ...application.payload,
    effect_id: `${application.config.run_id}/application`,
    workspace_ref: applicationCheckout.workspace_ref,
    cleanup_ref: { kind: 'process-cleanup', ref: `${application.config.run_id}-application` },
    argv: [process.execPath, '-e', 'setInterval(() => {}, 1000)'],
    runtime_ports: [{ name: 'application', port: application.config.port }],
  }, projectRoot), /workspace tracked working tree differs from its durable binding/);

  const applicationHead = initializeRun('application-head-changed');
  const applicationHeadCheckout = dispatch('checkout', applicationHead.payload, projectRoot);
  git(['checkout', '--quiet', alternateCommit], applicationHead.config.workspace_root);
  assert.throws(() => dispatch('fixture-start-application', {
    ...applicationHead.payload,
    effect_id: `${applicationHead.config.run_id}/application`,
    workspace_ref: applicationHeadCheckout.workspace_ref,
    cleanup_ref: { kind: 'process-cleanup', ref: `${applicationHead.config.run_id}-application` },
    argv: [process.execPath, '-e', 'setInterval(() => {}, 1000)'],
    runtime_ports: [{ name: 'application', port: applicationHead.config.port }],
  }, projectRoot), /workspace resolved commit differs from its durable binding/);
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
