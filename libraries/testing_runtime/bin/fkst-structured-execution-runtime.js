#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
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
const {
  listenerOwners,
  processGroupState,
  processGroupUsage,
  processTable,
} = require('../../../packages/environment-factory/bin/runtime/platform');
const {
  ownedLoopbackHttpRequest,
} = require('../../../packages/environment-factory/bin/runtime/owned-loopback-http');
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

function boundedString(value, maximum = 180) {
  return typeof value === 'string' && value !== '' && value.length <= maximum
    && !/[\x00-\x20\x7f]/.test(value);
}

function validDigest(value) {
  return typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
}

const supportedHttpMethods = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE']);

function validHttpPath(value) {
  if (!boundedString(value, 512) || !value.startsWith('/') || value.includes('?')
    || value.includes('#') || value.includes('\\') || value.includes('%')) return false;
  return !value.split('/').some((segment) => segment === '.' || segment === '..');
}

function validateCliCapabilities(value, label) {
  if (!Array.isArray(value) || value.length > 64) throw new Error(`${label} are malformed`);
  for (const capability of value) {
    exactKeys(capability, ['argv_prefix'], `${label} entry`);
    if (!Array.isArray(capability.argv_prefix) || capability.argv_prefix.length < 1
      || capability.argv_prefix.length > 32) throw new Error(`${label} entry is malformed`);
    validateArgv(capability.argv_prefix);
  }
}

function validateHttpCapabilities(value, label) {
  if (!Array.isArray(value) || value.length > 64) throw new Error(`${label} are malformed`);
  for (const capability of value) {
    exactKeys(capability, ['origin', 'methods', 'path_prefixes'], `${label} entry`);
    let origin;
    try { origin = new URL(capability.origin); } catch (_error) { throw new Error(`${label} origin is malformed`); }
    if (!['http:', 'https:'].includes(origin.protocol) || origin.username || origin.password
      || origin.origin !== capability.origin || !Array.isArray(capability.methods)
      || capability.methods.length < 1 || capability.methods.length > 8
      || new Set(capability.methods).size !== capability.methods.length
      || capability.methods.some((method) => !supportedHttpMethods.has(method))
      || !Array.isArray(capability.path_prefixes) || capability.path_prefixes.length < 1
      || capability.path_prefixes.length > 16
      || new Set(capability.path_prefixes).size !== capability.path_prefixes.length
      || capability.path_prefixes.some((prefix) => !validHttpPath(prefix))) {
      throw new Error(`${label} entry is malformed`);
    }
  }
}

function validatePointer(value, label) {
  exactKeys(value, ['kind', 'ref'], label);
  if (!boundedString(value.kind) || !boundedString(value.ref)) throw new Error(`${label} is malformed`);
}

function validateAuthorizationWindow(value, now, label) {
  const issuedAt = Date.parse(value.issued_at);
  const expiresAt = Date.parse(value.expires_at);
  if (!Number.isFinite(issuedAt) || !Number.isFinite(expiresAt) || issuedAt >= expiresAt) {
    throw new Error(`${label} validity window is malformed`);
  }
  if (now.getTime() < issuedAt || now.getTime() >= expiresAt) throw new Error(`${label} is expired`);
}

function validatePreauthorization(preauthorization, plan, grant, envelope, now) {
  exactKeys(preauthorization, [
    'schema', 'authorization_id', 'repository', 'profile_sha256', 'case_catalog_sha256',
    'capabilities', 'authority', 'policy_revision', 'evidence_ref', 'issued_at',
    'expires_at', 'max_uses', 'trace_id', 'dedup_key',
  ], 'preauthorization');
  exactKeys(preauthorization.repository, ['url', 'commit_sha'], 'preauthorization repository');
  if (!preauthorization.capabilities || typeof preauthorization.capabilities !== 'object'
    || Array.isArray(preauthorization.capabilities)
    || Object.keys(preauthorization.capabilities).some((key) => key !== 'cli' && key !== 'http')) {
    throw new Error('preauthorization capabilities are malformed');
  }
  validateCliCapabilities(preauthorization.capabilities.cli || [], 'preauthorization CLI capabilities');
  validateHttpCapabilities(preauthorization.capabilities.http || [], 'preauthorization HTTP capabilities');
  validateCliCapabilities(grant.cli_capabilities || [], 'grant CLI capabilities');
  validateHttpCapabilities(grant.http_capabilities || [], 'grant HTTP capabilities');
  validatePointer(preauthorization.authority, 'preauthorization authority');
  validatePointer(preauthorization.evidence_ref, 'preauthorization evidence');
  if (preauthorization.schema !== 'testing-structured-execution-authorization.v1'
    || !boundedString(preauthorization.authorization_id)
    || !boundedString(preauthorization.policy_revision)
    || !validDigest(preauthorization.profile_sha256)
    || !validDigest(preauthorization.case_catalog_sha256)
    || preauthorization.case_catalog_sha256 !== plan.case_catalog_sha256
    || preauthorization.max_uses !== 1
    || !sameAuthority(preauthorization.authority, grant.authority)
    || preauthorization.policy_revision !== grant.policy_revision) {
    throw new Error('preauthorization binding is malformed');
  }
  validateAuthorizationWindow(preauthorization, now, 'preauthorization');
  validateAuthorizationWindow(grant, now, 'execution grant');
  if (grant.max_uses !== 1 || envelope.expires_at !== grant.expires_at) {
    throw new Error('execution grant binding is malformed');
  }
}

function validateProfileAuthorization(config, profileArtifact, validationArtifact, now) {
  const profile = profileArtifact.value;
  const validation = validationArtifact.value;
  exactKeys(validation, [
    'schema', 'profile_schema', 'profile_revision', 'canonicalization', 'profile_sha256',
    'repository', 'approval_ref', 'approval_id', 'approval_sha256', 'authority',
    'policy_revision', 'evidence_ref', 'issued_at', 'trace_id', 'dedup_key',
  ], 'profile validation receipt');
  validatePointer(validation.approval_ref, 'profile approval reference');
  const approvalArtifact = readArtifact(validation.approval_ref);
  const approval = approvalArtifact.value;
  exactKeys(approval, [
    'schema', 'approval_id', 'canonicalization', 'profile_sha256', 'repository',
    'authority', 'policy_revision', 'evidence_ref', 'issued_at', 'expires_at',
    'max_uses', 'trace_id', 'dedup_key',
  ], 'profile approval');
  validatePointer(approval.authority, 'profile approval authority');
  validatePointer(approval.evidence_ref, 'profile approval evidence');
  validatePointer(validation.authority, 'validation receipt authority');
  validatePointer(validation.evidence_ref, 'validation receipt evidence');
  const approvalIssued = Date.parse(approval.issued_at);
  const approvalExpires = Date.parse(approval.expires_at);
  const receiptIssued = Date.parse(validation.issued_at);
  const receiptTtl = Number(profile.timeouts && profile.timeouts.receipt_ttl_seconds);
  if (approval.schema !== 'testing-project-profile-approval.v1'
    || approval.canonicalization !== 'fkst-project-profile-canonical-json.v1'
    || approval.max_uses !== 1 || validation.schema !== 'testing-project-profile-validation-receipt.v1'
    || validation.profile_schema !== profile.schema || validation.profile_revision !== profile.revision
    || validation.canonicalization !== approval.canonicalization
    || validation.profile_sha256 !== sha256(stableStringify(profile))
    || approval.profile_sha256 !== validation.profile_sha256
    || validation.approval_sha256 !== sha256(stableStringify(approval))
    || !sameRepository(approval.repository, profile.repository)
    || !sameRepository(validation.repository, profile.repository)
    || validation.approval_id !== approval.approval_id
    || !samePointer(validation.authority, approval.authority)
    || validation.policy_revision !== approval.policy_revision
    || !samePointer(validation.evidence_ref, approval.evidence_ref)
    || validation.trace_id !== approval.trace_id || validation.dedup_key !== approval.dedup_key
    || !Number.isFinite(approvalIssued) || !Number.isFinite(approvalExpires)
    || approvalExpires <= approvalIssued || approvalExpires - approvalIssued > 24 * 60 * 60 * 1000
    || now.getTime() < approvalIssued || now.getTime() >= approvalExpires
    || !Number.isFinite(receiptIssued) || receiptIssued < approvalIssued || receiptIssued > now.getTime()
    || !Number.isInteger(receiptTtl) || receiptTtl < 1
    || now.getTime() - receiptIssued > receiptTtl * 1000) {
    throw new Error('profile approval or validation receipt binding is malformed');
  }
  const authenticated = (config.profile_approval_attestations || []).some((entry) =>
    entry.approval_sha256 === validation.approval_sha256
      && sameAuthority(entry.authority, approval.authority)
      && entry.policy_revision === approval.policy_revision
      && samePointer(entry.evidence_ref, approval.evidence_ref));
  if (!authenticated) throw new Error('profile approval is unauthenticated');
}

function processResources(operationId) {
  const root = path.join(durableRoot(), 'environment-factory', 'resources');
  let entries;
  try {
    entries = fs.readdirSync(root);
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
  return entries.flatMap((entry) => {
    let resource;
    try { resource = readJson(path.join(root, entry)); } catch (_error) { return []; }
    if (!resource || resource.schema !== 'environment-factory.resource.v1'
      || resource.kind !== 'process' || resource.operation_id !== operationId
      || resource.cleaned === true) return [];
    return [resource];
  });
}

function assertOwnedApplicationListener(operationId, port) {
  const expected = [{ name: 'application', port }];
  const matches = [];
  for (const resource of processResources(operationId)) {
    if (!Number.isInteger(resource.pid) || resource.pid < 1
      || !Number.isInteger(resource.pgid) || resource.pgid < 1
      || typeof resource.process_start_identity !== 'string'
      || resource.process_start_identity === '' || resource.process_start_identity.length > 512
      || !boundedString(resource.ownership_token, 512)
      || stableStringify(resource.runtime_ports) !== stableStringify(expected)) continue;
    const state = processGroupState(resource);
    if (!state.supported) throw new Error('HTTP listener process ownership is unavailable');
    if (!state.alive || state.foreign) continue;
    const ownership = listenerOwners(port);
    const processes = processTable();
    if (!ownership.supported || !processes) {
      throw new Error('HTTP listener ownership inspection is unavailable');
    }
    const groups = new Map(processes.map((entry) => [entry.pid, entry.pgid]));
    if (ownership.pids.length > 0
      && ownership.pids.every((pid) => groups.get(pid) === resource.pgid)) matches.push(resource);
  }
  if (matches.length !== 1) throw new Error('HTTP listener is not owned by the ready environment');
  return matches[0];
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

function receiptDomain(envelope) {
  return envelope && envelope.schema === 'testing-cli-action-envelope.v1'
    ? 'cli-effect-receipt' : 'effect-receipt';
}

function receiptTag(config, receipt, envelope) {
  const unsigned = { ...receipt };
  delete unsigned.auth_tag;
  return crypto.createHmac('sha256', config.state_auth_key)
    .update(`${config.state_mac_generation}\0${receiptDomain(envelope)}\0${stableStringify(unsigned)}`).digest('hex');
}

function authorizationReceipt(config, envelope, decision, reasonCode, inputs, now) {
  const envelopeSha256 = sha256(stableStringify(envelope));
  const legacy = envelope && envelope.schema === 'testing-cli-action-envelope.v1';
  const receipt = {
    schema: 'testing-effect-authorization-receipt.v1', decision, reason_code: reasonCode,
    receipt_id: `${legacy ? 'cli-effect' : 'effect'}-${envelopeSha256.slice(0, 40)}`,
    envelope_sha256: envelopeSha256,
    evaluated_input_digests: inputs,
    issued_at: now.toISOString(), expires_at: envelope.expires_at,
    fence_id: envelope.fence_id, trace_id: envelope.trace_id, dedup_key: envelope.dedup_key,
  };
  receipt.auth_tag = receiptTag(config, receipt, envelope);
  return receipt;
}

function validateAssertions(assertions, kind) {
  if (!Array.isArray(assertions) || assertions.length < 1 || assertions.length > 16) {
    throw new Error('action assertions are malformed');
  }
  for (const assertion of assertions) {
    exactKeys(assertion, ['expected', 'type'], 'action assertion');
    if (kind === 'cli') {
      if (assertion.type !== 'exit-code' || !Number.isInteger(assertion.expected)
        || assertion.expected < 0 || assertion.expected > 255) {
        throw new Error('CLI action assertions are malformed');
      }
    } else if (assertion.type === 'status-code') {
      if (!Number.isInteger(assertion.expected) || assertion.expected < 100 || assertion.expected > 599) {
        throw new Error('HTTP status assertion is malformed');
      }
    } else if (assertion.type !== 'body-contains' || typeof assertion.expected !== 'string'
      || assertion.expected === '' || assertion.expected.length > 512) {
      throw new Error('HTTP action assertions are malformed');
    }
  }
}

function validateLegacyCliEnvelope(envelope) {
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
  validateAssertions(envelope.case.assertions, 'cli');
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

function strictHttpOrigin(value) {
  const match = /^http:\/\/127\.0\.0\.1:([0-9]+)$/.exec(String(value || ''));
  if (!match) throw new Error('HTTP action origin must use numeric loopback and an explicit port');
  const port = Number(match[1]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('HTTP action port is malformed');
  return port;
}

function localReadyOrigin(value) {
  let parsed;
  try { parsed = new URL(value); } catch (_error) { throw new Error('action ready origin is malformed'); }
  if (parsed.protocol !== 'http:' || parsed.username || parsed.password
    || !['127.0.0.1', 'localhost', '::1', '[::1]'].includes(parsed.hostname)
    || parsed.origin.toLowerCase() !== String(value).toLowerCase()) {
    throw new Error('action ready origin must be an exact loopback HTTP origin');
  }
  return parsed.origin.toLowerCase();
}

function emptyHeaders(value) {
  return Array.isArray(value) ? value.length === 0
    : Boolean(value && typeof value === 'object' && Object.keys(value).length === 0);
}

function validateActionEnvelope(envelope) {
  exactKeys(envelope, [
    'schema', 'effect_kind', 'capability', 'profile_ref', 'profile_artifact_sha256', 'profile_sha256',
    'validation_receipt_ref', 'validation_receipt_sha256', 'preauthorization_ref',
    'preauthorization_sha256', 'repository', 'run_id', 'operation_id',
    'environment_receipt_ref', 'environment_receipt_sha256', 'workspace_ref', 'ready_origin',
    'plan_ref', 'plan_sha256', 'grant_ref', 'grant_sha256', 'effect', 'resource_bounds',
    'attempt', 'trace_id', 'dedup_key', 'expires_at', 'fence_id',
  ], 'action envelope');
  exactKeys(envelope.repository, ['url', 'commit_sha'], 'action repository');
  exactKeys(envelope.workspace_ref, ['kind', 'ref'], 'action workspace');
  localReadyOrigin(envelope.ready_origin);
  const digestFields = [
    'profile_artifact_sha256', 'profile_sha256', 'validation_receipt_sha256',
    'preauthorization_sha256', 'environment_receipt_sha256', 'plan_sha256', 'grant_sha256',
  ];
  const artifactRefs = [
    'profile_ref', 'validation_receipt_ref', 'preauthorization_ref',
    'environment_receipt_ref', 'plan_ref', 'grant_ref',
  ];
  if (envelope.schema !== 'testing-action-envelope.v1' || envelope.attempt !== 1
    || envelope.run_id !== envelope.operation_id || envelope.workspace_ref.kind !== 'workspace'
    || !boundedString(envelope.run_id, 180) || !/^[A-Za-z0-9._-]+$/.test(envelope.run_id)
    || !boundedString(envelope.trace_id, 180) || !boundedString(envelope.dedup_key, 180)
    || !boundedString(envelope.fence_id, 180) || !boundedString(envelope.expires_at, 64)
    || !boundedString(envelope.workspace_ref.ref, 2048)
    || !boundedString(envelope.repository.url, 2048)
    || !/^[0-9a-f]{40}$/.test(String(envelope.repository.commit_sha || ''))
    || digestFields.some((field) => !validDigest(envelope[field]))
    || artifactRefs.some((field) => !isSafeArtifactPath(envelope[field]))
    || !Number.isFinite(Date.parse(envelope.expires_at))) {
    throw new Error('action envelope is malformed');
  }
  if (envelope.effect_kind === 'cli') {
    if (envelope.capability !== 'direct-argv') throw new Error('CLI action capability is unsupported');
    exactKeys(envelope.effect, ['kind', 'case_id', 'argv', 'timeout_seconds', 'assertions'], 'CLI action effect');
    exactKeys(envelope.resource_bounds, ['output_bytes'], 'CLI action resource bounds');
    validateAssertions(envelope.effect.assertions, 'cli');
    if (envelope.effect.kind !== 'cli') throw new Error('CLI action effect is malformed');
    validateArgv(envelope.effect.argv);
  } else if (envelope.effect_kind === 'http') {
    if (envelope.capability !== 'direct-loopback-http') throw new Error('HTTP action capability is unsupported');
    exactKeys(envelope.effect, [
      'kind', 'case_id', 'origin', 'host', 'port', 'method', 'path', 'headers',
      'redirect_mode', 'proxy_mode', 'address_mode', 'timeout_seconds', 'assertions',
    ], 'HTTP action effect');
    exactKeys(envelope.resource_bounds, ['network_requests', 'output_bytes'], 'HTTP action resource bounds');
    validateAssertions(envelope.effect.assertions, 'http');
    const port = strictHttpOrigin(envelope.effect.origin);
    if (envelope.effect.kind !== 'http' || envelope.effect.origin !== envelope.ready_origin
      || envelope.effect.host !== '127.0.0.1' || envelope.effect.port !== port
      || !supportedHttpMethods.has(envelope.effect.method) || !validHttpPath(envelope.effect.path)
      || !emptyHeaders(envelope.effect.headers)
      || envelope.effect.redirect_mode !== 'error' || envelope.effect.proxy_mode !== 'disabled'
      || envelope.effect.address_mode !== 'numeric-loopback'
      || envelope.resource_bounds.network_requests !== 1) {
      throw new Error('HTTP action effect is malformed');
    }
  } else {
    throw new Error('action effect kind is unsupported');
  }
  if (!Number.isInteger(envelope.effect.timeout_seconds) || envelope.effect.timeout_seconds < 1
    || envelope.effect.timeout_seconds > 300
    || !Number.isInteger(envelope.resource_bounds.output_bytes)
    || envelope.resource_bounds.output_bytes < 1024 || envelope.resource_bounds.output_bytes > 1024 * 1024) {
    throw new Error('action bounds are malformed');
  }
  return envelope;
}

function validateEnvelope(envelope) {
  if (envelope && envelope.schema === 'testing-cli-action-envelope.v1') {
    return validateLegacyCliEnvelope(envelope);
  }
  return validateActionEnvelope(envelope);
}

function envelopeCase(envelope) {
  if (envelope.schema === 'testing-cli-action-envelope.v1') return envelope.case;
  const effect = envelope.effect;
  if (effect.kind === 'cli') {
    return {
      case_id: effect.case_id, kind: 'cli', argv: effect.argv,
      timeout_seconds: effect.timeout_seconds, assertions: effect.assertions,
    };
  }
  return {
    case_id: effect.case_id, kind: 'http',
    request: { method: effect.method, url: `${effect.origin}${effect.path}`, headers: effect.headers },
    timeout_seconds: effect.timeout_seconds, assertions: effect.assertions,
  };
}

function httpWithin(effect, capabilities) {
  return (capabilities || []).some((capability) => capability
    && capability.origin === effect.origin
    && Array.isArray(capability.methods) && capability.methods.includes(effect.method)
    && Array.isArray(capability.path_prefixes)
    && capability.path_prefixes.some((prefix) => effect.path.startsWith(prefix)));
}

function evaluateEnvelope(config, envelope, request, now) {
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
  validateProfileAuthorization(config, profile, validation, now);
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
  validatePreauthorization(preauthorization.value, plan.value, grant.value, envelope, now);
  if (profile.value.working_directory !== '.' || !profile.value.mutation_policy
    || profile.value.mutation_policy.mode !== 'read-only'
    || !profile.value.resource_budgets
    || profile.value.resource_budgets.output_bytes !== envelope.resource_bounds.output_bytes) {
    throw new Error('project profile policy denies effect');
  }
  if (envelope.schema === 'testing-action-envelope.v1'
    && localOrigin(environment.value.base_url) !== envelope.ready_origin) {
    throw new Error('ready environment origin differs');
  }
  const actionCase = envelopeCase(envelope);
  const planned = (plan.value.cases || []).find((item) => item.case_id === actionCase.case_id);
  if (!planned || stableStringify(planned) !== stableStringify(actionCase)) {
    throw new Error('approved plan scope differs');
  }
  if (actionCase.kind === 'cli') {
    if (!argvWithin(actionCase.argv, preauthorization.value.capabilities && preauthorization.value.capabilities.cli)
      || !argvWithin(actionCase.argv, grant.value.cli_capabilities)) {
      throw new Error('CLI capability is not authorized');
    }
  } else {
    const profileOrigins = profile.value.allowed_origins;
    const runtimePorts = environment.value.runtime_ports;
    if (!Array.isArray(profileOrigins) || !profileOrigins.includes(envelope.effect.origin)
      || !Number.isInteger(profile.value.resource_budgets.network_requests)
      || profile.value.resource_budgets.network_requests < envelope.resource_bounds.network_requests
      || !Array.isArray(runtimePorts)
      || !runtimePorts.some((entry) => entry && entry.name === 'application'
        && entry.port === envelope.effect.port)
      || !httpWithin(envelope.effect, preauthorization.value.capabilities && preauthorization.value.capabilities.http)
      || !httpWithin(envelope.effect, grant.value.http_capabilities)) {
      throw new Error('HTTP capability is not authorized');
    }
  }
  const attested = (config.grant_attestations || []).some((entry) => entry.grant_sha256 === grant.digest
    && sameAuthority(entry.authority, grant.value.authority)
    && entry.policy_revision === grant.value.policy_revision
    && samePointer(entry.evidence_ref, grant.value.evidence_ref));
  if (!attested) throw new Error('execution grant is unauthenticated');
  const replay = readReplay(config, grant.value.grant_id);
  const expectedReplayBinding = replayBinding({
    grant_id: grant.value.grant_id,
    grant_sha256: grant.digest,
    parent_authorization_sha256: preauthorization.digest,
    plan_sha256: plan.digest,
    environment_receipt_sha256: environment.digest,
    repository: envelope.repository,
    operation_id: envelope.operation_id,
    artifact_root: request.artifact_root,
    trace_id: envelope.trace_id,
    dedup_key: envelope.dedup_key,
  });
  if (!replay || replay.status !== 'claimed' || replay.claim_id !== envelope.fence_id
    || stableStringify(replay.binding) !== stableStringify(expectedReplayBinding)) {
    throw new Error('replay fence is not owned by this effect');
  }
  if (actionCase.kind === 'http') assertOwnedApplicationListener(envelope.operation_id, envelope.effect.port);
  return inputs;
}

function authorizeEffect(payload) {
  const config = runtimeConfig(payload);
  const envelope = payload.action_envelope || {};
  const now = new Date();
  let inputs = {
    profile: '0'.repeat(64), validation_receipt: '0'.repeat(64),
    preauthorization: '0'.repeat(64), environment_receipt: '0'.repeat(64),
    plan: '0'.repeat(64), grant: '0'.repeat(64),
  };
  try {
    inputs = evaluateEnvelope(config, envelope, payload, now);
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
      expires_at: boundedString(envelope.expires_at, 64) && Number.isFinite(Date.parse(envelope.expires_at))
        ? envelope.expires_at : new Date(now.getTime() + 1000).toISOString(),
      fence_id: boundedString(envelope.fence_id, 180) ? envelope.fence_id : 'invalid-fence',
      trace_id: boundedString(envelope.trace_id, 180) ? envelope.trace_id : 'invalid-trace',
      dedup_key: boundedString(envelope.dedup_key, 180) ? envelope.dedup_key : 'invalid-dedup',
    };
    return authorizationReceipt(config, safeEnvelope, 'deny', reason, inputs, now);
  }
}

function validateAllowReceipt(config, envelope, receipt, label) {
  exactKeys(receipt, [
    'schema', 'decision', 'reason_code', 'receipt_id', 'envelope_sha256',
    'evaluated_input_digests', 'issued_at', 'expires_at', 'fence_id', 'trace_id',
    'dedup_key', 'auth_tag',
  ], `${label} authorization receipt`);
  exactKeys(receipt.evaluated_input_digests, [
    'profile', 'validation_receipt', 'preauthorization', 'environment_receipt', 'plan', 'grant',
  ], 'evaluated authorization inputs');
  if (Object.values(receipt.evaluated_input_digests)
    .some((digest) => !/^[0-9a-f]{64}$/.test(String(digest || '')))) {
    throw new Error('evaluated authorization input digests are malformed');
  }
  const issuedAt = Date.parse(receipt.issued_at);
  const expiresAt = Date.parse(receipt.expires_at);
  if (receipt.schema !== 'testing-effect-authorization-receipt.v1' || receipt.decision !== 'allow'
    || receipt.reason_code !== 'authorized' || receipt.envelope_sha256 !== sha256(stableStringify(envelope))
    || receipt.auth_tag !== receiptTag(config, receipt, envelope) || receipt.fence_id !== envelope.fence_id
    || receipt.trace_id !== envelope.trace_id || receipt.dedup_key !== envelope.dedup_key
    || receipt.expires_at !== envelope.expires_at || !Number.isFinite(issuedAt)
    || !Number.isFinite(expiresAt) || issuedAt >= expiresAt || Date.now() < issuedAt || Date.now() >= expiresAt) {
    throw new Error(`${label} authorization receipt is missing, denied, malformed, expired, or foreign`);
  }
  return receipt;
}

function consumeAuthorization(config, envelope, receipt, label) {
  validateAllowReceipt(config, envelope, receipt, label);
  const target = authorizationPath(receipt.receipt_id);
  const release = acquireLock(`${target}.lock`);
  try {
    const current = fs.existsSync(target) ? readJson(target) : null;
    if (!current || current.status !== 'issued'
      || stableStringify(current.receipt) !== stableStringify(receipt)) {
      throw new Error(`${label} authorization receipt was replayed or is unavailable`);
    }
    writeJsonAtomic(target, { status: 'consumed', receipt });
    return release;
  } catch (error) {
    release();
    throw error;
  }
}

async function execArgv(payload) {
  const config = runtimeConfig(payload);
  const envelope = validateEnvelope(payload.action_envelope);
  const actionCase = envelopeCase(envelope);
  if (actionCase.kind !== 'cli') throw new Error('CLI gateway requires a CLI action envelope');
  const release = consumeAuthorization(config, envelope, payload.authorization_receipt, 'CLI');
  try {
    const workspace = resolveWorkspace({
      operation_id: envelope.operation_id, repository: envelope.repository,
      environment_receipt_sha256: envelope.environment_receipt_sha256,
      workspace_ref: envelope.workspace_ref, require_clean: true,
    });
    const result = await runMeasuredCommand(validateArgv(actionCase.argv), {
      cwd: workspace.cwd,
      env: minimalEnvironment(config.command_environment || {}),
      timeoutMs: actionCase.timeout_seconds * 1000,
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

async function httpRequest(payload) {
  const config = runtimeConfig(payload);
  const envelope = validateActionEnvelope(payload.action_envelope);
  if (envelope.effect_kind !== 'http') throw new Error('HTTP gateway requires an HTTP action envelope');
  const release = consumeAuthorization(config, envelope, payload.authorization_receipt, 'HTTP');
  const effect = envelope.effect;
  const resource = assertOwnedApplicationListener(envelope.operation_id, effect.port);
  const maximum = Math.min(
    Math.max(1024, Math.min(Number(config.http_response_bytes) || 256 * 1024, 1024 * 1024)),
    envelope.resource_bounds.output_bytes,
  );
  try {
    return await ownedLoopbackHttpRequest({
      resource,
      effect,
      outputBytes: maximum,
      verifyOwner: () => assertOwnedApplicationListener(envelope.operation_id, effect.port),
    });
  } finally { release(); }
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
  if (name === 'authorize-effect') return authorizeEffect(payload);
  if (name === 'authorize-cli-effect') {
    const envelope = payload && payload.action_envelope;
    if (!envelope || envelope.schema !== 'testing-cli-action-envelope.v1'
      || envelope.effect_kind !== 'cli') {
      throw new Error('legacy CLI authorization accepts only legacy CLI envelopes');
    }
    return authorizeEffect(payload);
  }
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
