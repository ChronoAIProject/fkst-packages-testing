#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const path = require('path');
const {
  acquireLock,
  artifactPath,
  boundedText,
  isSafeArtifactPath,
  minimalEnvironment,
  parseArgs,
  readJson,
  sha256,
  stableStringify,
  validateArgv,
  writeJsonAtomic,
  writeJsonImmutable,
} = require('../../../packages/environment-factory/bin/runtime/common');
const { runMeasuredCommand } = require('../../../packages/environment-factory/bin/runtime/measured-command');
const { processGroupUsage } = require('../../../packages/environment-factory/bin/runtime/platform');
const { resolveWorkspace } = require('../../../packages/environment-factory/bin/runtime/workspace');

function durableRoot() {
  return path.resolve(process.env.FKST_DURABLE_ROOT || path.join('.testing', 'durable'));
}

function runtimeConfig(payload) {
  const config = readJson(artifactPath(payload.runtime_config_ref));
  if (config.schema !== 'testing-runtime.structured-execution-config.v1') {
    throw new Error('invalid structured execution runtime config schema');
  }
  if (typeof config.state_auth_key !== 'string' || config.state_auth_key.length < 32
    || config.state_auth_key.length > 512) {
    throw new Error('structured execution config requires a bounded state_auth_key');
  }
  if (typeof config.state_mac_generation !== 'string' || config.state_mac_generation === ''
    || config.state_mac_generation.length > 180) {
    throw new Error('structured execution config requires state_mac_generation');
  }
  return config;
}

function artifactRef(value) {
  if (!value || value.kind !== 'artifact' || !isSafeArtifactPath(value.ref)) {
    throw new Error('safe artifact pointer is required');
  }
  return value;
}

function readArtifact(ref) {
  const pointer = artifactRef(ref);
  const raw = fs.readFileSync(artifactPath(pointer), 'utf8');
  return { raw, digest: sha256(raw), value: JSON.parse(raw) };
}

function writeArtifact(ref, value) {
  const pointer = artifactRef(ref);
  const target = artifactPath(pointer);
  const body = `${stableStringify(value)}\n`;
  if (fs.existsSync(target)) {
    if (fs.readFileSync(target, 'utf8') !== body) throw new Error('immutable artifact differs');
    return { written: true, replayed: true, digest: sha256(body) };
  }
  writeJsonImmutable(target, value);
  return { written: true, replayed: false, digest: sha256(body) };
}

function samePointer(left, right) {
  return Boolean(left && right && left.kind === right.kind && left.ref === right.ref);
}

function sameAuthority(left, right) {
  return samePointer(left, right);
}

function verifyGrant(payload) {
  const config = runtimeConfig(payload);
  for (const entry of config.grant_attestations || []) {
    if (entry.grant_sha256 === payload.grant_sha256
      && sameAuthority(entry.authority, payload.grant.authority)
      && entry.policy_revision === payload.grant.policy_revision
      && samePointer(entry.evidence_ref, payload.grant.evidence_ref)) {
      return {
        grant_sha256: entry.grant_sha256,
        authority: entry.authority,
        policy_revision: entry.policy_revision,
        evidence_ref: entry.evidence_ref,
      };
    }
  }
  return { authenticated: false };
}

function replayPath(grantId) {
  return path.join(durableRoot(), 'testing-runner', 'structured-execution', `${sha256(grantId)}.json`);
}

function replayMac(config, value) {
  return crypto.createHmac('sha256', config.state_auth_key)
    .update(`${config.state_mac_generation}\0${stableStringify(value)}`).digest('hex');
}

function replayBinding(payload) {
  return {
    grant_id: payload.grant_id,
    grant_sha256: payload.grant_sha256,
    parent_authorization_sha256: payload.parent_authorization_sha256,
    plan_sha256: payload.plan_sha256,
    environment_receipt_sha256: payload.environment_receipt_sha256,
    repository: payload.repository,
    operation_id: payload.operation_id,
    artifact_root: payload.artifact_root,
    trace_id: payload.trace_id,
    dedup_key: payload.dedup_key,
  };
}

function readReplay(config, grantId) {
  const target = replayPath(grantId);
  if (!fs.existsSync(target)) return null;
  const envelope = readJson(target);
  if (envelope.schema !== 'testing-runtime.structured-execution-replay.v1'
    || envelope.mac !== replayMac(config, envelope.value)) {
    throw new Error('structured execution replay state authentication failed');
  }
  return envelope.value;
}

function writeReplay(config, grantId, value) {
  writeJsonAtomic(replayPath(grantId), {
    schema: 'testing-runtime.structured-execution-replay.v1',
    value,
    mac: replayMac(config, value),
  });
}

function sameRepository(left, right) {
  return Boolean(left && right && left.url === right.url && left.commit_sha === right.commit_sha);
}

function validateExecutionArtifact(payload, binding, expectedDigest) {
  if (!isSafeArtifactPath(payload.result_ref)
    || payload.result_ref !== `${binding.artifact_root}/execution.json`) {
    throw new Error('replay result_ref is outside the claimed structured execution root');
  }
  const artifact = readArtifact({ kind: 'artifact', ref: payload.result_ref });
  if (expectedDigest && artifact.digest !== expectedDigest) throw new Error('completed execution result digest differs');
  const value = artifact.value;
  const statuses = new Set(['passed', 'failed', 'blocked', 'degraded']);
  const counts = ['case_count', 'passed_count', 'failed_count', 'skipped_count', 'error_count'];
  if (!value || value.schema !== 'testing-structured-execution.v1'
    || value.operation_id !== binding.operation_id
    || !statuses.has(value.status) || typeof value.classification !== 'string'
    || !sameRepository(value.repository, binding.repository)
    || value.environment_receipt_sha256 !== binding.environment_receipt_sha256
    || value.trace_id !== binding.trace_id || value.dedup_key !== binding.dedup_key
    || value.test_plan_path !== `${binding.artifact_root}/test-plan.json`
    || value.case_results_path !== `${binding.artifact_root}/case-results.json`
    || value.execution_path !== payload.result_ref
    || counts.some((field) => !Number.isInteger(value[field]) || value[field] < 0)
    || value.case_count !== value.passed_count + value.failed_count + value.skipped_count + value.error_count) {
    throw new Error('completed execution result binding is invalid');
  }
  return artifact;
}

function replayGuard(payload) {
  const config = runtimeConfig(payload);
  const target = replayPath(payload.grant_id);
  const release = acquireLock(`${target}.lock`);
  try {
    const binding = replayBinding(payload);
    const existing = readReplay(config, payload.grant_id);
    if (existing) {
      if (stableStringify(existing.binding) !== stableStringify(binding)) {
        throw new Error('structured execution replay binding differs');
      }
      if (existing.status === 'completed') {
        if (!/^[0-9a-f]{64}$/.test(String(existing.result_sha256 || ''))) {
          throw new Error('completed replay result digest is unavailable');
        }
        return {
          status: 'completed',
          result_ref: existing.result_ref,
          result_sha256: existing.result_sha256,
        };
      }
      return { status: 'in-progress' };
    }
    const claimId = `structured-execution-claim-${replayMac(config, binding).slice(0, 32)}`;
    writeReplay(config, payload.grant_id, { status: 'claimed', claim_id: claimId, binding });
    return { status: 'claimed', claim_id: claimId, grant_id: payload.grant_id };
  } finally {
    release();
  }
}

function completeReplay(payload) {
  const config = runtimeConfig(payload);
  const claim = payload.claim || {};
  if (typeof claim.claim_id !== 'string' || claim.claim_id === ''
    || typeof claim.grant_id !== 'string' || claim.grant_id === '') {
    throw new Error('replay claim is required');
  }
  const target = replayPath(claim.grant_id);
  const release = acquireLock(`${target}.lock`);
  try {
    const current = readReplay(config, claim.grant_id);
    if (!current || current.status !== 'claimed' || current.claim_id !== claim.claim_id) {
      throw new Error('replay completion claim differs');
    }
    const suppliedBinding = replayBinding({ ...current.binding, ...payload, grant_id: claim.grant_id });
    if (stableStringify(current.binding) !== stableStringify(suppliedBinding)) {
      throw new Error('replay completion binding differs');
    }
    const artifact = validateExecutionArtifact(payload, current.binding);
    writeReplay(config, claim.grant_id, {
      ...current,
      status: 'completed',
      result_ref: payload.result_ref,
      result_sha256: artifact.digest,
    });
    return { completed: true, result_sha256: artifact.digest };
  } finally {
    release();
  }
}

function boundedOutput(config) {
  return Math.max(1024, Math.min(Number(config.output_bytes) || 64 * 1024, 1024 * 1024));
}

function exactKeys(value, keys, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || Object.keys(value).sort().join(',') !== [...keys].sort().join(',')) {
    throw new Error(`${label} fields are invalid`);
  }
}

function boundArtifact(ref, digest) {
  if (!isSafeArtifactPath(ref) || !/^[0-9a-f]{64}$/.test(String(digest || ''))) {
    throw new Error('authorization input binding is malformed');
  }
  const artifact = readArtifact({ kind: 'artifact', ref });
  if (artifact.digest !== digest) throw new Error('authorization input digest differs');
  return artifact;
}

function argvWithin(argv, capabilities) {
  return Array.isArray(argv) && (capabilities || []).some((capability) =>
    capability && Array.isArray(capability.argv_prefix)
    && capability.argv_prefix.length > 0 && capability.argv_prefix.length <= argv.length
    && capability.argv_prefix.every((item, index) => item === argv[index]));
}

function authorizationPath(receiptId) {
  return path.join(durableRoot(), 'testing-runner', 'cli-effect-authorization', `${sha256(receiptId)}.json`);
}

function receiptTag(config, receipt) {
  const unsigned = { ...receipt };
  delete unsigned.auth_tag;
  return crypto.createHmac('sha256', config.state_auth_key)
    .update(`${config.state_mac_generation}\0cli-effect-receipt\0${stableStringify(unsigned)}`).digest('hex');
}

function authorizationReceipt(config, envelope, decision, reasonCode, inputs, now) {
  const envelopeSha256 = sha256(stableStringify(envelope));
  const receipt = {
    schema: 'testing-effect-authorization-receipt.v1', decision, reason_code: reasonCode,
    receipt_id: `cli-effect-${envelopeSha256.slice(0, 40)}`,
    envelope_sha256: envelopeSha256,
    evaluated_input_digests: inputs,
    issued_at: now.toISOString(), expires_at: envelope.expires_at,
    fence_id: envelope.fence_id, trace_id: envelope.trace_id, dedup_key: envelope.dedup_key,
  };
  receipt.auth_tag = receiptTag(config, receipt);
  return receipt;
}

function validateEnvelope(envelope) {
  exactKeys(envelope, [
    'schema', 'effect_kind', 'capability', 'profile_ref', 'profile_artifact_sha256', 'profile_sha256',
    'validation_receipt_ref', 'validation_receipt_sha256', 'preauthorization_ref',
    'preauthorization_sha256', 'repository', 'run_id', 'operation_id',
    'environment_receipt_ref', 'environment_receipt_sha256', 'workspace_ref',
    'plan_ref', 'plan_sha256', 'grant_ref', 'grant_sha256', 'case', 'resource_bounds',
    'attempt', 'trace_id', 'dedup_key', 'expires_at', 'fence_id',
  ], 'CLI action envelope');
  exactKeys(envelope.repository, ['url', 'commit_sha'], 'action repository');
  exactKeys(envelope.workspace_ref, ['kind', 'ref'], 'action workspace');
  exactKeys(envelope.resource_bounds, ['output_bytes'], 'action resource bounds');
  exactKeys(envelope.case, ['case_id', 'kind', 'argv', 'timeout_seconds', 'assertions'], 'action case');
  if (!Array.isArray(envelope.case.assertions) || envelope.case.assertions.length < 1
    || envelope.case.assertions.length > 16
    || envelope.case.assertions.some((assertion) => !assertion
      || Object.keys(assertion).sort().join(',') !== 'expected,type'
      || assertion.type !== 'exit-code' || !Number.isInteger(assertion.expected)
      || assertion.expected < 0 || assertion.expected > 255)) {
    throw new Error('CLI action assertions are malformed');
  }
  if (envelope.schema !== 'testing-cli-action-envelope.v1' || envelope.effect_kind !== 'cli'
    || envelope.capability !== 'direct-argv' || envelope.attempt !== 1
    || envelope.run_id !== envelope.operation_id || envelope.case.kind !== 'cli'
    || envelope.workspace_ref.kind !== 'workspace'
    || !Number.isInteger(envelope.case.timeout_seconds) || envelope.case.timeout_seconds < 1
    || envelope.case.timeout_seconds > 300
    || !Number.isInteger(envelope.resource_bounds.output_bytes)
    || envelope.resource_bounds.output_bytes < 1024 || envelope.resource_bounds.output_bytes > 1024 * 1024
    || !Number.isFinite(Date.parse(envelope.expires_at))) {
    throw new Error('CLI action envelope is malformed');
  }
  validateArgv(envelope.case.argv);
  return envelope;
}

function evaluateCliEnvelope(config, envelope, now) {
  validateEnvelope(envelope);
  const profile = boundArtifact(envelope.profile_ref, envelope.profile_artifact_sha256);
  const validation = boundArtifact(envelope.validation_receipt_ref, envelope.validation_receipt_sha256);
  const preauthorization = boundArtifact(envelope.preauthorization_ref, envelope.preauthorization_sha256);
  const environment = boundArtifact(envelope.environment_receipt_ref, envelope.environment_receipt_sha256);
  const plan = boundArtifact(envelope.plan_ref, envelope.plan_sha256);
  const grant = boundArtifact(envelope.grant_ref, envelope.grant_sha256);
  const inputs = {
    profile: profile.digest, validation_receipt: validation.digest,
    preauthorization: preauthorization.digest, environment_receipt: environment.digest,
    plan: plan.digest, grant: grant.digest,
  };
  const sameRun = (value) => value && value.trace_id === envelope.trace_id
    && value.dedup_key === envelope.dedup_key;
  if (profile.value.schema !== 'testing-project-profile.v1'
    || profile.value.revision !== validation.value.profile_revision
    || validation.value.schema !== 'testing-project-profile-validation-receipt.v1'
    || sha256(stableStringify(profile.value)) !== envelope.profile_sha256
    || validation.value.profile_sha256 !== envelope.profile_sha256
    || preauthorization.value.schema !== 'testing-structured-execution-authorization.v1'
    || preauthorization.value.profile_sha256 !== envelope.profile_sha256
    || environment.value.schema !== 'environment-factory.receipt.v2'
    || environment.value.status !== 'ready' || environment.value.operation_id !== envelope.operation_id
    || environment.value.profile_sha256 !== envelope.profile_sha256
    || stableStringify(environment.value.workspace_ref) !== stableStringify(envelope.workspace_ref)
    || plan.value.schema !== 'testing-structured-plan.v2'
    || plan.value.environment_receipt_sha256 !== environment.digest
    || grant.value.schema !== 'testing-structured-execution-grant.v1'
    || grant.value.parent_authorization_sha256 !== preauthorization.digest
    || grant.value.plan_sha256 !== plan.digest
    || grant.value.environment_receipt_sha256 !== environment.digest
    || grant.value.max_uses !== 1 || !sameRun(validation.value) || !sameRun(preauthorization.value)
    || !sameRun(environment.value) || !sameRun(plan.value) || !sameRun(grant.value)
    || !sameRepository(profile.value.repository, envelope.repository)
    || !sameRepository(validation.value.repository, envelope.repository)
    || !sameRepository(preauthorization.value.repository, envelope.repository)
    || !sameRepository(environment.value.repository, envelope.repository)
    || !sameRepository(plan.value.repository, envelope.repository)
    || !sameRepository(grant.value.repository, envelope.repository)) {
    throw new Error('authorization input bindings differ');
  }
  if (profile.value.working_directory !== '.' || !profile.value.mutation_policy
    || profile.value.mutation_policy.mode !== 'read-only'
    || !profile.value.resource_budgets
    || profile.value.resource_budgets.output_bytes !== envelope.resource_bounds.output_bytes) {
    throw new Error('project profile policy denies CLI effect');
  }
  const planned = (plan.value.cases || []).find((item) => item.case_id === envelope.case.case_id);
  if (!planned || stableStringify(planned) !== stableStringify(envelope.case)) {
    throw new Error('approved plan scope differs');
  }
  if (!argvWithin(envelope.case.argv, preauthorization.value.capabilities && preauthorization.value.capabilities.cli)
    || !argvWithin(envelope.case.argv, grant.value.cli_capabilities)) {
    throw new Error('CLI capability is not authorized');
  }
  const attested = (config.grant_attestations || []).some((entry) => entry.grant_sha256 === grant.digest
    && sameAuthority(entry.authority, grant.value.authority)
    && entry.policy_revision === grant.value.policy_revision
    && samePointer(entry.evidence_ref, grant.value.evidence_ref));
  if (!attested || now >= new Date(grant.value.expires_at) || now >= new Date(envelope.expires_at)) {
    throw new Error('execution grant is unauthenticated or expired');
  }
  const replay = readReplay(config, grant.value.grant_id);
  if (!replay || replay.status !== 'claimed' || replay.claim_id !== envelope.fence_id) {
    throw new Error('replay fence is not owned by this effect');
  }
  return inputs;
}

function authorizeCliEffect(payload) {
  const config = runtimeConfig(payload);
  const envelope = payload.action_envelope || {};
  const now = new Date();
  let inputs = {
    profile: '0'.repeat(64), validation_receipt: '0'.repeat(64),
    preauthorization: '0'.repeat(64), environment_receipt: '0'.repeat(64),
    plan: '0'.repeat(64), grant: '0'.repeat(64),
  };
  try {
    inputs = evaluateCliEnvelope(config, envelope, now);
    const receipt = authorizationReceipt(config, envelope, 'allow', 'authorized', inputs, now);
    const target = authorizationPath(receipt.receipt_id);
    const release = acquireLock(`${target}.lock`);
    try {
      if (fs.existsSync(target)) {
        const current = readJson(target);
        if (current.status !== 'issued' || stableStringify(current.receipt) !== stableStringify(receipt)) {
          return authorizationReceipt(config, envelope, 'deny', 'replayed', inputs, now);
        }
        return current.receipt;
      }
      writeJsonAtomic(target, { status: 'issued', receipt });
      return receipt;
    } finally { release(); }
  } catch (error) {
    const message = String(error && error.message || error);
    const reason = message.includes('digest') ? 'digest-mismatch'
      : message.includes('expired') ? 'expired'
        : message.includes('fence') ? 'foreign-fence'
          : message.includes('capability') || message.includes('plan scope') ? 'scope-denied'
            : message.includes('profile policy') ? 'profile-policy-denied'
              : message.includes('fields') || message.includes('malformed') ? 'malformed-envelope'
                : 'foreign-binding';
    const safeEnvelope = {
      expires_at: Number.isFinite(Date.parse(envelope.expires_at)) ? envelope.expires_at : new Date(now.getTime() + 1000).toISOString(),
      fence_id: typeof envelope.fence_id === 'string' ? envelope.fence_id : 'invalid-fence',
      trace_id: typeof envelope.trace_id === 'string' ? envelope.trace_id : 'invalid-trace',
      dedup_key: typeof envelope.dedup_key === 'string' ? envelope.dedup_key : 'invalid-dedup',
    };
    return authorizationReceipt(config, safeEnvelope, 'deny', reason, inputs, now);
  }
}

async function execArgv(payload) {
  const config = runtimeConfig(payload);
  const envelope = validateEnvelope(payload.action_envelope);
  const receipt = payload.authorization_receipt;
  exactKeys(receipt, [
    'schema', 'decision', 'reason_code', 'receipt_id', 'envelope_sha256',
    'evaluated_input_digests', 'issued_at', 'expires_at', 'fence_id', 'trace_id',
    'dedup_key', 'auth_tag',
  ], 'CLI authorization receipt');
  exactKeys(receipt.evaluated_input_digests, [
    'profile', 'validation_receipt', 'preauthorization', 'environment_receipt', 'plan', 'grant',
  ], 'evaluated authorization inputs');
  if (Object.values(receipt.evaluated_input_digests)
    .some((digest) => !/^[0-9a-f]{64}$/.test(String(digest || '')))) {
    throw new Error('evaluated authorization input digests are malformed');
  }
  if (receipt.schema !== 'testing-effect-authorization-receipt.v1' || receipt.decision !== 'allow'
    || receipt.reason_code !== 'authorized' || receipt.envelope_sha256 !== sha256(stableStringify(envelope))
    || receipt.auth_tag !== receiptTag(config, receipt) || receipt.fence_id !== envelope.fence_id
    || receipt.trace_id !== envelope.trace_id || receipt.dedup_key !== envelope.dedup_key
    || Date.now() >= Date.parse(receipt.expires_at)) {
    throw new Error('CLI authorization receipt is missing, denied, malformed, expired, or foreign');
  }
  const target = authorizationPath(receipt.receipt_id);
  const release = acquireLock(`${target}.lock`);
  try {
    const current = fs.existsSync(target) ? readJson(target) : null;
    if (!current || current.status !== 'issued'
      || stableStringify(current.receipt) !== stableStringify(receipt)) {
      throw new Error('CLI authorization receipt was replayed or is unavailable');
    }
    writeJsonAtomic(target, { status: 'consumed', receipt });
    const workspace = resolveWorkspace({
      operation_id: envelope.operation_id, repository: envelope.repository,
      environment_receipt_sha256: envelope.environment_receipt_sha256,
      workspace_ref: envelope.workspace_ref, require_clean: true,
    });
    const result = await runMeasuredCommand(validateArgv(envelope.case.argv), {
    cwd: workspace.cwd,
    env: minimalEnvironment(config.command_environment || {}),
      timeoutMs: envelope.case.timeout_seconds * 1000,
      outputBytes: Math.min(boundedOutput(config), envelope.resource_bounds.output_bytes),
    });
    if (result.timedOut) throw new Error('structured CLI effect timed out');
    if (result.outputExceeded) throw new Error('structured CLI effect exceeded output bound');
    if (result.error) throw result.error;
    const remaining = processGroupUsage([result.pgid]);
    if (!remaining.supported) throw new Error('structured CLI process cleanup verification is unavailable');
    if (remaining.processes > 0) {
      try { process.kill(-result.pgid, 'SIGKILL'); } catch (_error) {}
      throw new Error('structured CLI effect left a surviving process group');
    }
    return { exit_code: result.exitCode, stdout: result.stdout, stderr: result.stderr };
  } finally { release(); }
}

function localOrigin(value) {
  const parsed = new URL(value);
  if (parsed.protocol !== 'http:' || parsed.username || parsed.password
    || !['127.0.0.1', 'localhost', '::1', '[::1]'].includes(parsed.hostname)) {
    throw new Error('HTTP effect must use loopback HTTP');
  }
  return parsed.origin.toLowerCase();
}

function httpRequest(payload) {
  const config = runtimeConfig(payload);
  const allowedMethods = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE']);
  if (!payload.request || !allowedMethods.has(payload.request.method)
    || !Array.isArray(payload.request.headers) || payload.request.headers.length !== 0) {
    throw new Error('HTTP effect request is invalid');
  }
  const target = new URL(payload.request.url);
  if (target.search || target.hash) throw new Error('HTTP effect URL must not contain query or fragment');
  if (localOrigin(target.toString()) !== localOrigin(payload.base_url)) {
    throw new Error('HTTP effect origin differs from ready environment');
  }
  const maximum = Math.max(1024, Math.min(Number(config.http_response_bytes) || 256 * 1024, 1024 * 1024));
  return new Promise((resolve, reject) => {
    const request = http.request({
      hostname: target.hostname,
      port: target.port,
      path: `${target.pathname}${target.search}`,
      method: payload.request.method,
      headers: {},
      timeout: Math.max(1, Number(payload.timeout_seconds) || 1) * 1000,
    }, (response) => {
      const chunks = [];
      let size = 0;
      response.on('data', (chunk) => {
        size += chunk.length;
        if (size > maximum) request.destroy(new Error('HTTP response exceeded bound'));
        else chunks.push(chunk);
      });
      response.on('end', () => resolve({
        status: response.statusCode,
        body: Buffer.concat(chunks).toString('utf8'),
        headers: {},
      }));
    });
    request.on('timeout', () => request.destroy(new Error('HTTP effect timed out')));
    request.on('error', reject);
    request.end();
  });
}

function loadResult(payload) {
  if (!/^[0-9a-f]{64}$/.test(String(payload.result_sha256 || ''))) {
    throw new Error('completed execution result digest is required');
  }
  const binding = {
    artifact_root: payload.artifact_root,
    operation_id: payload.operation_id,
    repository: payload.repository,
    environment_receipt_sha256: payload.environment_receipt_sha256,
    trace_id: payload.trace_id,
    dedup_key: payload.dedup_key,
  };
  const artifact = validateExecutionArtifact(payload, binding, payload.result_sha256);
  const execution = artifact.value;
  return {
    schema: 'testing-runner.structured-execution-summary.v1',
    status: execution.status,
    classification: execution.classification,
    mode: 'structured-api-cli',
    artifact_root: payload.artifact_root,
    case_count: execution.case_count,
    passed_count: execution.passed_count,
    failed_count: execution.failed_count,
    skipped_count: execution.skipped_count,
    error_count: execution.error_count,
    test_plan_path: execution.test_plan_path,
    case_results_path: execution.case_results_path,
    execution_path: execution.execution_path,
  };
}

async function dispatch(name, payload) {
  if (name === 'load-artifact') return readArtifact(payload.artifact_ref);
  if (name === 'write-artifact') return writeArtifact(payload.artifact_ref, payload.value);
  if (name === 'now') {
    runtimeConfig(payload);
    return { now: new Date().toISOString() };
  }
  if (name === 'verify-grant') return verifyGrant(payload);
  if (name === 'replay-guard') return replayGuard(payload);
  if (name === 'authorize-cli-effect') return authorizeCliEffect(payload);
  if (name === 'complete-replay') return completeReplay(payload);
  if (name === 'exec-argv') return execArgv(payload);
  if (name === 'http-request') return httpRequest(payload);
  if (name === 'load-result') return loadResult(payload);
  throw new Error(`unknown effect: ${name}`);
}

function runtimeIoPath(value) {
  if (!isSafeArtifactPath(value)) throw new Error('runtime IO path must stay under .testing');
  return artifactPath({ kind: 'artifact', ref: value });
}

async function main(argv) {
  if (argv[0] !== 'effect') throw new Error('expected effect command');
  const options = parseArgs(argv.slice(1));
  if (Object.keys(options).sort().join(',') !== 'name,request,response') {
    throw new Error('effect command requires name, request, and response');
  }
  const payload = readJson(runtimeIoPath(options.request));
  const result = await dispatch(options.name, payload);
  writeJsonAtomic(runtimeIoPath(options.response), { ok: true, result: result === undefined ? null : result });
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`fkst-structured-execution-runtime: ${boundedText(error && error.stack ? error.stack : error, 4096)}\n`);
    process.exitCode = 1;
  });
}

module.exports = { dispatch, localOrigin, runtimeConfig };
