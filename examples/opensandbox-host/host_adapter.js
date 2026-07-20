import { createHash } from 'node:crypto';

export const HOST_REQUEST_PATH = '/run/fkst/host-run-request.v1.json';
export const TRUSTED_LAUNCHER_COMMAND = `/opt/fkst/bin/host-launcher --request ${HOST_REQUEST_PATH}`;

const RUN_SCHEMA = 'fkst-opensandbox-host.run-config.v1';
const RECEIPT_SCHEMA = 'fkst-opensandbox-host.receipt.v1';
const REQUEST_SCHEMA = 'fkst-opensandbox-host.launch-request.v1';
const TERMINAL_STATUSES = new Set(['passed', 'failed', 'blocked', 'timed-out', 'cancelled', 'interrupted']);
const TOP_LEVEL_FIELDS = new Set([
  'schema',
  'image',
  'snapshot_id',
  'ttl_seconds',
  'resource_limits',
  'network_policy',
  'repository_ref',
  'project_profile_ref',
  'project_profile_approval_ref',
  'runtime_config_ref',
  'artifact_destination',
  'required_artifacts',
  'trace_id',
  'dedup_key',
]);

function fail(message) {
  throw new Error(`opensandbox-host: ${message}`);
}

function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function boundedString(value, maximum = 512) {
  return typeof value === 'string' && value.length > 0 && value.length <= maximum && !/[\0-\x1f\x7f]/u.test(value);
}

function onlyFields(value, allowed, label) {
  if (!isObject(value)) fail(`${label} must be an object`);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) fail(`${label} has unsupported field: ${key}`);
  }
}

function validateSourceRef(value, label) {
  onlyFields(value, new Set(['kind', 'ref']), label);
  if (!boundedString(value.kind, 64) || !boundedString(value.ref)) fail(`${label} must contain bounded kind/ref strings`);
  return value;
}

function validateResourceLimits(value) {
  onlyFields(value, new Set(['cpu', 'memory', 'disk']), 'resource_limits');
  for (const field of ['cpu', 'memory', 'disk']) {
    if (!boundedString(value[field], 32)) fail(`resource_limits.${field} must be a bounded string`);
  }
}

function validateNetworkPolicy(value) {
  onlyFields(value, new Set(['default_action', 'rules']), 'network_policy');
  if (value.default_action !== 'deny') fail('network_policy.default_action must be deny');
  if (!Array.isArray(value.rules) || value.rules.length > 32) fail('network_policy.rules must be a bounded dense list');
  for (const [index, rule] of value.rules.entries()) {
    onlyFields(rule, new Set(['action', 'target']), `network_policy.rules[${index}]`);
    if (rule.action !== 'allow' || !boundedString(rule.target, 253)) fail(`network_policy.rules[${index}] is invalid`);
    const labels = rule.target.split('.');
    if (labels.some((label) => !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/u.test(label))) {
      fail(`network_policy.rules[${index}].target is invalid`);
    }
  }
}

function artifactRoot(requiredArtifacts) {
  const match = requiredArtifacts[0].path.match(/^(\.testing\/runs\/[^/]+)/u);
  if (!match) fail('required_artifacts paths must be under one .testing/runs/<run>/ root');
  const root = match[1];
  for (const item of requiredArtifacts) {
    if (item.path !== root && !item.path.startsWith(`${root}/`)) {
      fail('required_artifacts paths must share one artifact root');
    }
  }
  return root;
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (isObject(value)) {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function configDigest(config) {
  return createHash('sha256').update(canonicalJson(config)).digest('hex');
}

export function validateRunConfig(value) {
  onlyFields(value, TOP_LEVEL_FIELDS, 'run configuration');
  if (value.schema !== RUN_SCHEMA) fail(`schema must be ${RUN_SCHEMA}`);
  if ((value.image === undefined) === (value.snapshot_id === undefined)) fail('exactly one pinned image or snapshot_id is required');
  if (value.image !== undefined && !/^[A-Za-z0-9._:/-]+@sha256:[0-9a-f]{64}$/u.test(value.image)) fail('image must be a pinned image digest');
  if (value.snapshot_id !== undefined && !boundedString(value.snapshot_id, 256)) fail('snapshot_id must be bounded');
  if (!Number.isInteger(value.ttl_seconds) || value.ttl_seconds < 60 || value.ttl_seconds > 86_400) fail('ttl_seconds must be an integer from 60 to 86400');
  validateResourceLimits(value.resource_limits);
  validateNetworkPolicy(value.network_policy);
  validateSourceRef(value.repository_ref, 'repository_ref');
  validateSourceRef(value.project_profile_ref, 'project_profile_ref');
  validateSourceRef(value.project_profile_approval_ref, 'project_profile_approval_ref');
  validateSourceRef(value.runtime_config_ref, 'runtime_config_ref');
  onlyFields(value.artifact_destination, new Set(['kind', 'root']), 'artifact_destination');
  if (!boundedString(value.artifact_destination.kind, 64) || !boundedString(value.artifact_destination.root)) {
    fail('artifact_destination must contain bounded kind/root strings');
  }
  if (!Array.isArray(value.required_artifacts) || value.required_artifacts.length === 0 || value.required_artifacts.length > 64) {
    fail('required_artifacts must be a non-empty bounded dense list');
  }
  for (const [index, item] of value.required_artifacts.entries()) {
    onlyFields(item, new Set(['path', 'max_bytes']), `required_artifacts[${index}]`);
    if (!boundedString(item.path) || item.path.includes('..') || !item.path.startsWith('.testing/runs/')) {
      fail(`required_artifacts[${index}].path must be safe`);
    }
    if (!Number.isInteger(item.max_bytes) || item.max_bytes < 1 || item.max_bytes > 100 * 1024 * 1024) {
      fail(`required_artifacts[${index}].max_bytes is invalid`);
    }
  }
  artifactRoot(value.required_artifacts);
  if (!boundedString(value.trace_id) || !boundedString(value.dedup_key)) fail('trace_id and dedup_key must be bounded strings');
  return value;
}

function launchRequest(config) {
  return {
    schema: REQUEST_SCHEMA,
    execution_mode: 'in-sandbox-local',
    repository_ref: config.repository_ref,
    project_profile_ref: config.project_profile_ref,
    project_profile_approval_ref: config.project_profile_approval_ref,
    runtime_config_ref: config.runtime_config_ref,
    artifact_root: artifactRoot(config.required_artifacts),
    trace_id: config.trace_id,
    dedup_key: config.dedup_key,
  };
}

function createOptions(config) {
  return {
    ...(config.image === undefined ? { snapshotId: config.snapshot_id } : { image: config.image }),
    timeoutSeconds: config.ttl_seconds,
    resource: config.resource_limits,
    networkPolicy: {
      defaultAction: config.network_policy.default_action,
      egress: config.network_policy.rules,
    },
    metadata: {
      'fkst.trace-id': config.trace_id,
      'fkst.dedup-key': config.dedup_key,
    },
  };
}

function initialReceipt(config, sandboxId, digest) {
  return {
    schema: RECEIPT_SCHEMA,
    status: 'created',
    sandbox_id: sandboxId,
    trace_id: config.trace_id,
    dedup_key: config.dedup_key,
    config_sha256: digest,
    artifacts: [],
    destroyed: false,
  };
}

function lifecycleStatus(receipt, phase, status) {
  return {
    schema: 'fkst-opensandbox-host.lifecycle-status.v1',
    phase,
    status,
    sandbox_id: receipt.sandbox_id,
    trace_id: receipt.trace_id,
    dedup_key: receipt.dedup_key,
  };
}

function isAlreadyDestroyed(error) {
  return error?.code === 'NOT_FOUND' || error?.status === 404;
}

function classifyExecutionFailure(error) {
  if (error?.code === 'FKST_TIMEOUT') return { status: 'timed-out', failure: { code: 'launcher-timed-out' } };
  if (error?.code === 'ABORT_ERR') return { status: 'cancelled', failure: { code: 'launcher-cancelled' } };
  if (error?.code === 'FKST_INTERRUPTED') return { status: 'interrupted', failure: { code: 'launcher-interrupted' } };
  return { status: 'failed', failure: { code: 'launcher-failed' } };
}

export class OpenSandboxHostAdapter {
  constructor({ sdk, ledger, publisher }) {
    if (!sdk || !ledger || !publisher) fail('sdk, ledger, and publisher are required');
    this.sdk = sdk;
    this.ledger = ledger;
    this.publisher = publisher;
  }

  async run(rawConfig) {
    const config = validateRunConfig(rawConfig);
    const digest = configDigest(config);
    let receipt = await this.ledger.load(config.dedup_key);
    if (receipt && receipt.config_sha256 !== digest) fail('persisted receipt configuration digest does not match this run');
    if (receipt && receipt.destroyed === true && TERMINAL_STATUSES.has(receipt.status)) return receipt;

    let sandbox;
    const recoveringTerminal = receipt && TERMINAL_STATUSES.has(receipt.status);
    if (receipt) {
      if (receipt.trace_id !== config.trace_id || !boundedString(receipt.sandbox_id)) fail('persisted receipt does not match the logical run');
      sandbox = await this.sdk.connect(receipt.sandbox_id);
    } else {
      sandbox = await this.sdk.find({
        'fkst.trace-id': config.trace_id,
        'fkst.dedup-key': config.dedup_key,
      });
      if (!sandbox) sandbox = await this.sdk.create(createOptions(config));
      receipt = initialReceipt(config, sandbox.id, digest);
      try {
        await this.ledger.save(receipt);
      } catch {
        try {
          await sandbox.kill();
        } catch {
        }
        throw new Error('OpenSandbox FKST run failed: initial receipt persistence failed');
      }
    }

    if (!recoveringTerminal) {
      let executionOutcome = null;
      try {
        receipt.status = 'bootstrapping';
        await this.ledger.save(receipt);
        await this.ledger.append(lifecycleStatus(receipt, 'bootstrap', 'running'));
        await sandbox.files.writeFiles([{ path: HOST_REQUEST_PATH, data: `${JSON.stringify(launchRequest(config))}\n` }]);

        receipt.status = 'running';
        await this.ledger.save(receipt);
        await this.ledger.append(lifecycleStatus(receipt, 'workflow', 'running'));
        const execution = await sandbox.commands.run(TRUSTED_LAUNCHER_COMMAND, {
          workingDirectory: '/',
          timeoutSeconds: config.ttl_seconds,
        });
        if (execution.exitCode !== 0) executionOutcome = { status: 'failed', failure: { code: 'launcher-exit-nonzero' } };
      } catch (error) {
        executionOutcome = classifyExecutionFailure(error);
      }

      try {
        const published = [];
        for (const item of config.required_artifacts) {
          const bytes = Buffer.from(await sandbox.files.readBytes(item.path, { limit: item.max_bytes + 1 }));
          if (bytes.byteLength > item.max_bytes) throw new Error('artifact exceeds configured bound');
          const sha256 = createHash('sha256').update(bytes).digest('hex');
          const relativePath = item.path.slice(artifactRoot(config.required_artifacts).length + 1);
          const publishedRef = await this.publisher.publish({
            destination: config.artifact_destination,
            relative_path: relativePath,
            bytes,
            sha256,
            trace_id: config.trace_id,
            dedup_key: config.dedup_key,
          });
          published.push({ path: item.path, sha256, bytes: bytes.byteLength, published_ref: publishedRef });
        }
        receipt.artifacts = published;
        receipt.status = executionOutcome?.status ?? 'passed';
        if (executionOutcome) receipt.failure = executionOutcome.failure;
        await this.ledger.save(receipt);
        await this.ledger.append(lifecycleStatus(receipt, 'publication', receipt.status));
      } catch {
        receipt.status = 'blocked';
        receipt.failure = { code: 'artifact-publication-failed' };
        await this.ledger.save(receipt);
        await this.ledger.append(lifecycleStatus(receipt, 'publication', 'blocked'));
      }
    }

    try {
      await sandbox.kill();
    } catch (error) {
      if (!isAlreadyDestroyed(error)) {
        receipt.status = 'blocked';
        receipt.failure = { code: 'sandbox-destroy-failed' };
        await this.ledger.save(receipt);
        throw new Error('OpenSandbox FKST run failed: sandbox destroy failed');
      }
    }
    receipt.destroyed = true;
    await this.ledger.save(receipt);
    await this.ledger.append(lifecycleStatus(receipt, 'teardown', 'destroyed'));

    if (receipt.status !== 'passed') throw new Error(`OpenSandbox FKST run failed: ${receipt.failure.code}`);
    return receipt;
  }
}
