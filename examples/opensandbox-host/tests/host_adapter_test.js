import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  HOST_REQUEST_PATH,
  TRUSTED_LAUNCHER_COMMAND,
  OpenSandboxHostAdapter,
  validateRunConfig,
} from '../host_adapter.js';
import { FilesystemArtifactPublisher, FilesystemRunLedger } from '../filesystem_host.js';

function runConfig(overrides = {}) {
  return {
    schema: 'fkst-opensandbox-host.run-config.v1',
    image: 'ghcr.io/chronoai/fkst-qa@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ttl_seconds: 1800,
    resource_limits: { cpu: '2', memory: '4Gi', disk: '10Gi' },
    network_policy: {
      default_action: 'deny',
      rules: [
        { action: 'allow', target: 'github.com' },
        { action: 'allow', target: 'registry.npmjs.org' },
      ],
    },
    repository_ref: { kind: 'github-repository', ref: 'ChronoAIProject/NyxID@0123456789012345678901234567890123456789' },
    project_profile_ref: { kind: 'artifact', ref: 'approvals/nyxid/project-profile.v1.json' },
    project_profile_approval_ref: { kind: 'artifact', ref: 'approvals/nyxid/project-profile-approval.v1.json' },
    runtime_config_ref: { kind: 'artifact', ref: 'approvals/nyxid/runtime-config.v1.json' },
    artifact_destination: { kind: 'filesystem', root: '/tmp/fkst-opensandbox-published' },
    required_artifacts: [
      { path: '.testing/runs/nyxid/metadata.json', max_bytes: 4096 },
      { path: '.testing/runs/nyxid/final-receipt.json', max_bytes: 4096 },
    ],
    trace_id: 'trace-nyxid-opensandbox',
    dedup_key: 'nyxid-opensandbox-run',
    ...overrides,
  };
}

function fakeHarness(options = {}) {
  const calls = [];
  let saveCount = 0;
  const receipts = new Map();
  const artifacts = new Map([
    ['.testing/runs/nyxid/metadata.json', Buffer.from('{"status":"passed"}\n')],
    ['.testing/runs/nyxid/final-receipt.json', Buffer.from('{"status":"passed"}\n')],
  ]);
  const sandbox = {
    id: 'sandbox-108',
    files: {
      async writeFiles(entries) { calls.push(['writeFiles', entries]); },
      async readBytes(path) {
        calls.push(['readBytes', path]);
        if (!artifacts.has(path)) throw new Error(`missing artifact: ${path}`);
        return artifacts.get(path);
      },
    },
    commands: {
      async run(command, commandOptions) {
        calls.push(['run', command, commandOptions]);
        if (options.runError) throw options.runError;
        return { exitCode: options.exitCode ?? 0 };
      },
    },
    async kill() { calls.push(['kill']); },
  };
  const sdk = {
    async find(metadata) { calls.push(['find', metadata]); return options.existingSandbox ? sandbox : null; },
    async create(createOptions) { calls.push(['create', createOptions]); return sandbox; },
    async connect(sandboxId) { calls.push(['connect', sandboxId]); return sandbox; },
  };
  const ledger = {
    async load(dedupKey) { calls.push(['ledger.load', dedupKey]); return receipts.get(dedupKey) ?? null; },
    async save(receipt) {
      saveCount += 1;
      calls.push(['ledger.save', structuredClone(receipt)]);
      if (options.saveErrorAt === saveCount) throw new Error('durable ledger unavailable');
      receipts.set(receipt.dedup_key, structuredClone(receipt));
    },
    async append(status) { calls.push(['ledger.append', structuredClone(status)]); },
  };
  const publisher = {
    async publish(item) { calls.push(['publish', { ...item, bytes: Buffer.from(item.bytes) }]); return { kind: 'artifact', ref: `${item.destination.root}/${item.relative_path}` }; },
  };
  return { calls, receipts, sdk, ledger, publisher };
}

test('validates pinned provider-neutral run configuration', () => {
  assert.equal(validateRunConfig(runConfig()).schema, 'fkst-opensandbox-host.run-config.v1');
  assert.throws(() => validateRunConfig(runConfig({ image: 'ghcr.io/chronoai/fkst-qa:latest' })), /pinned image/);
  assert.throws(() => validateRunConfig(runConfig({ image: `user:secret@registry/fkst@sha256:${'a'.repeat(64)}` })), /pinned image/);
  assert.throws(() => validateRunConfig(runConfig({ credential: 'secret' })), /unsupported field/);
  assert.throws(() => validateRunConfig(runConfig({ network_policy: { default_action: 'allow', rules: [] } })), /default_action/);
});

test('filesystem host durably stores bounded ledger entries and verified artifacts', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'fkst-opensandbox-host-'));
  try {
    const ledger = new FilesystemRunLedger(path.join(root, 'ledger'));
    const receipt = {
      schema: 'fkst-opensandbox-host.receipt.v1',
      status: 'created',
      sandbox_id: 'sandbox-108',
      trace_id: 'trace-filesystem-host',
      dedup_key: 'filesystem-host',
      config_sha256: 'a'.repeat(64),
      artifacts: [],
      destroyed: false,
    };
    await ledger.save(receipt);
    assert.deepEqual(await ledger.load(receipt.dedup_key), receipt);
    await ledger.append({ schema: 'fkst-opensandbox-host.lifecycle-status.v1', status: 'running', dedup_key: receipt.dedup_key });

    const publisher = new FilesystemArtifactPublisher();
    const bytes = Buffer.from('verified artifact\n');
    const sha256 = 'b968f651d921bbdd1a3765457ef6ecaaf1cb0e2b0e525f1d92731d3f2e6bc886';
    const published = await publisher.publish({
      destination: { kind: 'filesystem', root: path.join(root, 'published') },
      relative_path: 'metadata.json',
      bytes,
      sha256,
      trace_id: receipt.trace_id,
      dedup_key: receipt.dedup_key,
    });
    assert.equal(await readFile(published.ref, 'utf8'), 'verified artifact\n');
    await assert.rejects(() => publisher.publish({
      destination: { kind: 'filesystem', root },
      relative_path: '../escape',
      bytes,
      sha256,
      trace_id: receipt.trace_id,
      dedup_key: receipt.dedup_key,
    }), /unsafe/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('creates one sandbox, uses the trusted launcher, publishes artifacts, then destroys', async () => {
  const harness = fakeHarness();
  const adapter = new OpenSandboxHostAdapter(harness);
  const receipt = await adapter.run(runConfig());

  assert.equal(receipt.status, 'passed');
  assert.equal(receipt.sandbox_id, 'sandbox-108');
  assert.equal(receipt.destroyed, true);
  assert.match(receipt.config_sha256, /^[0-9a-f]{64}$/);
  assert.equal(receipt.artifacts.length, 2);
  assert.match(receipt.artifacts[0].sha256, /^[0-9a-f]{64}$/);

  const create = harness.calls.find(([name]) => name === 'create');
  assert.deepEqual(create[1], {
    image: runConfig().image,
    timeoutSeconds: 1800,
    resource: { cpu: '2', memory: '4Gi', disk: '10Gi' },
    networkPolicy: {
      defaultAction: 'deny',
      egress: runConfig().network_policy.rules,
    },
    metadata: {
      'fkst.trace-id': 'trace-nyxid-opensandbox',
      'fkst.dedup-key': 'nyxid-opensandbox-run',
    },
  });

  const write = harness.calls.find(([name]) => name === 'writeFiles');
  assert.equal(write[1][0].path, HOST_REQUEST_PATH);
  const request = JSON.parse(write[1][0].data);
  assert.deepEqual(Object.keys(request).sort(), [
    'artifact_root',
    'dedup_key',
    'execution_mode',
    'project_profile_approval_ref',
    'project_profile_ref',
    'repository_ref',
    'runtime_config_ref',
    'schema',
    'trace_id',
  ]);

  const command = harness.calls.find(([name]) => name === 'run');
  assert.equal(command[1], TRUSTED_LAUNCHER_COMMAND);
  const killIndex = harness.calls.findIndex(([name]) => name === 'kill');
  const lastPublishIndex = harness.calls.findLastIndex(([name]) => name === 'publish');
  const finalSaveIndex = harness.calls.findLastIndex(([name]) => name === 'ledger.save');
  assert.equal(lastPublishIndex < killIndex, true);
  assert.equal(killIndex < finalSaveIndex, true);
  assert.equal(harness.calls.filter(([name]) => name === 'create').length, 1);
});

test('reuses a persisted sandbox receipt and does not create a second sandbox', async () => {
  const harness = fakeHarness();
  harness.receipts.set('nyxid-opensandbox-run', {
    schema: 'fkst-opensandbox-host.receipt.v1',
    status: 'running',
    sandbox_id: 'sandbox-108',
    trace_id: 'trace-nyxid-opensandbox',
    dedup_key: 'nyxid-opensandbox-run',
    config_sha256: 'placeholder',
    artifacts: [],
    destroyed: false,
  });
  const firstAdapter = new OpenSandboxHostAdapter(fakeHarness());
  const expected = await firstAdapter.run(runConfig());
  harness.receipts.get('nyxid-opensandbox-run').config_sha256 = expected.config_sha256;
  const adapter = new OpenSandboxHostAdapter(harness);
  await adapter.run(runConfig());

  assert.equal(harness.calls.filter(([name]) => name === 'create').length, 0);
  assert.equal(harness.calls.filter(([name]) => name === 'connect').length, 1);
});

test('recovers a sandbox found by trace and dedup metadata before creating another', async () => {
  const harness = fakeHarness({ existingSandbox: true });
  const adapter = new OpenSandboxHostAdapter(harness);
  const receipt = await adapter.run(runConfig());

  assert.equal(receipt.sandbox_id, 'sandbox-108');
  assert.equal(harness.calls.filter(([name]) => name === 'create').length, 0);
  assert.equal(harness.calls.filter(([name]) => name === 'find').length, 1);
});

test('destroys a newly allocated sandbox when the initial receipt cannot be persisted', async () => {
  const harness = fakeHarness({ saveErrorAt: 1 });
  const adapter = new OpenSandboxHostAdapter(harness);

  await assert.rejects(() => adapter.run(runConfig()), /receipt persistence failed/);
  assert.equal(harness.calls.filter(([name]) => name === 'create').length, 1);
  assert.equal(harness.calls.filter(([name]) => name === 'kill').length, 1);
});

test('rejects reuse of a dedup key with changed run configuration', async () => {
  const seed = fakeHarness();
  await new OpenSandboxHostAdapter(seed).run(runConfig());
  const stored = seed.receipts.get('nyxid-opensandbox-run');
  stored.destroyed = false;
  seed.receipts.set('nyxid-opensandbox-run', stored);

  await assert.rejects(
    () => new OpenSandboxHostAdapter(seed).run(runConfig({ ttl_seconds: 1900 })),
    /configuration digest/,
  );
});

test('destroys and records a bounded failed receipt when execution fails', async () => {
  const harness = fakeHarness({ runError: new Error('raw provider log with secret material') });
  const adapter = new OpenSandboxHostAdapter(harness);

  await assert.rejects(() => adapter.run(runConfig()), /OpenSandbox FKST run failed/);
  assert.equal(harness.calls.filter(([name]) => name === 'kill').length, 1);
  const receipt = harness.receipts.get('nyxid-opensandbox-run');
  assert.equal(receipt.status, 'failed');
  assert.equal(receipt.destroyed, true);
  assert.equal(receipt.failure.code, 'launcher-failed');
  assert.equal('message' in receipt.failure, false);
  const lifecycle = harness.calls.filter(([name]) => name === 'ledger.append').map(([, value]) => value);
  assert.equal(lifecycle.every((value) => JSON.stringify(value).length <= 2048), true);
  assert.equal(JSON.stringify(lifecycle).includes('secret material'), false);
});

test('classifies timed-out, cancelled, and interrupted terminal paths and always destroys', async () => {
  for (const [code, expectedStatus] of [
    ['FKST_TIMEOUT', 'timed-out'],
    ['ABORT_ERR', 'cancelled'],
    ['FKST_INTERRUPTED', 'interrupted'],
  ]) {
    const error = new Error('raw execution detail');
    error.code = code;
    const harness = fakeHarness({ runError: error });
    const adapter = new OpenSandboxHostAdapter(harness);
    await assert.rejects(() => adapter.run(runConfig({ dedup_key: `run-${code}` })), /OpenSandbox FKST run failed/);
    const receipt = harness.receipts.get(`run-${code}`);
    assert.equal(receipt.status, expectedStatus);
    assert.equal(receipt.destroyed, true);
    assert.equal(harness.calls.filter(([name]) => name === 'kill').length, 1);
  }
});

test('a recovered terminal receipt retries teardown without relaunching the workflow', async () => {
  const harness = fakeHarness();
  harness.receipts.set('nyxid-opensandbox-run', {
    schema: 'fkst-opensandbox-host.receipt.v1',
    status: 'passed',
    sandbox_id: 'sandbox-108',
    trace_id: 'trace-nyxid-opensandbox',
    dedup_key: 'nyxid-opensandbox-run',
    config_sha256: 'placeholder',
    artifacts: [{ path: '.testing/runs/nyxid/metadata.json', sha256: 'a'.repeat(64), bytes: 20 }],
    destroyed: false,
  });
  const expected = await new OpenSandboxHostAdapter(fakeHarness()).run(runConfig());
  harness.receipts.get('nyxid-opensandbox-run').config_sha256 = expected.config_sha256;
  const adapter = new OpenSandboxHostAdapter(harness);
  const receipt = await adapter.run(runConfig());

  assert.equal(receipt.destroyed, true);
  assert.equal(harness.calls.filter(([name]) => name === 'run').length, 0);
  assert.equal(harness.calls.filter(([name]) => name === 'publish').length, 0);
  assert.equal(harness.calls.filter(([name]) => name === 'kill').length, 1);
});
