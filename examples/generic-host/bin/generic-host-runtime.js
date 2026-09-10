#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { execute: storeExecute, stable } = require('./durable-host-store');
const lineageContract = require('./authorization-lineage');

function environmentRuntimeHelper(name) {
  const candidates = [
    path.resolve(__dirname, '../../../packages/environment-factory/bin/runtime', name),
    path.resolve(__dirname, '../../environment-factory/bin/runtime', name),
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(`${candidate}.js`)) return require(candidate);
  }
  fail(`environment-factory runtime helper is unavailable: ${name}`);
}

const {
  minimalEnvironment, pathIdentity, releaseWorkerEnvironment,
  releaseWorkerEnvironmentLease, removeOwnedDirectory, samePathIdentity, sleep,
  verifyWorkerEnvironment, verifyWorkerEnvironmentLease,
} = environmentRuntimeHelper('common');
const { validateTargetExecutionBoundary } = environmentRuntimeHelper('target-execution-boundary');
const { startOrRecoverSupervisedProcess } = environmentRuntimeHelper('supervised-process');
const {
  listenerOwners, listenersOwnedByProcessGroup, listenersReleased, processGroupState, terminateProcessGroup,
} = environmentRuntimeHelper('platform');

function fail(message) {
  throw new Error(`generic-host runtime: ${message}`);
}

function sha256(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

function childProcessEnvironment(cwd, reservation = null) {
  return minimalEnvironment({}, {
    schema: 'generic-host.worker-isolation.v1',
    cwd_sha256: sha256(path.resolve(cwd)),
  }, reservation && reservation.reservation_id);
}

function durableRoot() {
  const value = process.env.FKST_GENERIC_HOST_DURABLE_ROOT || process.env.FKST_DURABLE_ROOT;
  if (typeof value !== 'string' || !path.isAbsolute(value)) fail('generic Host durable root must be absolute');
  return path.resolve(value);
}

function safeArtifactPath(value) {
  return typeof value === 'string' && value.startsWith('.testing/runs/')
    && !value.includes('\0') && !value.includes('\\')
    && value.split('/').every((segment) => segment !== '' && segment !== '.' && segment !== '..');
}

function readRuntimeConfig(payload) {
  const ref = payload.runtime_config_ref;
  if (ref == null) return { project_root: process.cwd() };
  if (!ref || ref.kind !== 'artifact' || typeof ref.ref !== 'string'
    || !ref.ref.startsWith('.testing/') || ref.ref.includes('..') || path.isAbsolute(ref.ref)) {
    fail('runtime config ref is invalid');
  }
  const target = path.resolve(process.cwd(), ref.ref);
  const testingRoot = path.resolve(process.cwd(), '.testing');
  if (target !== testingRoot && !target.startsWith(`${testingRoot}${path.sep}`)) fail('runtime config escaped .testing');
  const config = JSON.parse(fs.readFileSync(target, 'utf8'));
  if (config.schema !== 'generic-host.runtime-config.v1' || typeof config.project_root !== 'string') {
    fail('runtime config schema is invalid');
  }
  return config;
}

function hostRoot() {
  return path.join(durableRoot(), 'generic-host');
}

function runRoot(runId) {
  if (typeof runId !== 'string' || !/^[A-Za-z0-9._-]+$/.test(runId)) fail('run_id is invalid');
  return path.join(hostRoot(), runId);
}

function recordRead(root, key) {
  const result = storeExecute({ root, operation: 'record-read', key });
  return result.found ? result.value : null;
}

function recordList(root, prefix) {
  return storeExecute({ root, operation: 'record-list', prefix }).entries;
}

function recordImmutable(root, key, value) {
  return storeExecute({ root, operation: 'record-immutable', key, value });
}

function recordCas(root, key, value, expectedVersion) {
  return storeExecute({ root, operation: 'record-cas', key, value, expected_version: expectedVersion });
}

function recordClaim(root, key, value) {
  return storeExecute({ root, operation: 'record-claim', key, value });
}

function runIdFromPath(value) {
  if (typeof value !== 'string') return null;
  const match = /^\.testing\/runs\/([^/]+)/.exec(value);
  return match && match[1];
}

function candidatePaths(payload) {
  const values = [payload.path, payload.artifact_root, payload.artifact_ref, payload.receipt_ref,
    payload.result_ref, payload.ledger_ref, payload.aggregate_report_ref, payload.cleanup_receipt_ref];
  for (const value of Object.values(payload)) {
    if (value && typeof value === 'object' && typeof value.ref === 'string') values.push(value.ref);
  }
  return values;
}

function runIdFor(payload) {
  if (typeof payload.run_id === 'string') return payload.run_id;
  if (payload.request && typeof payload.request.run_id === 'string') return payload.request.run_id;
  if (payload.source_ref && typeof payload.source_ref.ref === 'string'
    && /^[A-Za-z0-9._-]+$/.test(payload.source_ref.ref)) return payload.source_ref.ref;
  for (const value of candidatePaths(payload)) {
    const runId = runIdFromPath(value);
    if (runId) return runId;
  }
  if (typeof payload.dedup_key === 'string' && /^[A-Za-z0-9._-]+$/.test(payload.dedup_key)) {
    return payload.dedup_key;
  }
  fail('run_id cannot be derived from request');
}

function loadConfig(projectRoot, runId) {
  const config = recordRead(runRoot(runId), 'generic-host/config');
  if (!config || config.schema !== 'generic-host.durable-workflow-qa.v1'
    || config.run_id !== runId || path.resolve(config.project_root) !== path.resolve(projectRoot)) {
    fail('durable run config is unavailable or foreign');
  }
  validateTargetExecutionBoundary(config.target_execution_boundary, config.profile.repository);
  return config;
}

function expectedProfileReplayBinding(config) {
  const repository = config.profile && config.profile.repository;
  const approval = config.approval;
  const receipt = config.validation_receipt;
  if (!validRepository(repository) || !approval || !receipt
    || !sameRepository(repository, approval.repository)
    || approval.approval_id !== receipt.approval_id
    || !validDigest(receipt.approval_sha256)
    || !validDigest(receipt.profile_sha256)
    || approval.max_uses !== 1
    || approval.trace_id !== receipt.trace_id
    || approval.dedup_key !== receipt.dedup_key) {
    fail('trusted Profile replay binding is unavailable');
  }
  return {
    approval_id: approval.approval_id,
    approval_sha256: receipt.approval_sha256,
    profile_sha256: receipt.profile_sha256,
    repository: { url: repository.url, commit_sha: repository.commit_sha },
    trace_id: receipt.trace_id,
    dedup_key: receipt.dedup_key,
    max_uses: approval.max_uses,
  };
}

function artifactFile(projectRoot, logicalPath) {
  if (!safeArtifactPath(logicalPath)) fail('artifact path is invalid');
  const target = path.resolve(projectRoot, logicalPath);
  const testingRoot = path.resolve(projectRoot, '.testing');
  if (!target.startsWith(`${testingRoot}${path.sep}`)) fail('artifact path escaped project root');
  return target;
}

function atomicWrite(filePath, body) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const temporary = `${filePath}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
  const fd = fs.openSync(temporary, 'wx', 0o600);
  try {
    fs.writeFileSync(fd, body, 'utf8');
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(temporary, filePath);
}

function stableDirectoryIdentity(boundary, directory) {
  const root = path.resolve(boundary);
  const target = path.resolve(directory);
  if (target !== root && !target.startsWith(`${root}${path.sep}`)) {
    fail('materialized artifact directory escaped its boundary');
  }
  let cursor = root;
  const segments = path.relative(root, target).split(path.sep).filter(Boolean);
  for (const segment of ['', ...segments]) {
    if (segment !== '') cursor = path.join(cursor, segment);
    try {
      fs.mkdirSync(cursor, { mode: 0o700 });
    } catch (error) {
      if (!error || error.code !== 'EEXIST') throw error;
    }
    const stat = fs.lstatSync(cursor);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      fail('materialized artifact directory is not a physical directory');
    }
  }
  const stat = fs.lstatSync(target);
  return { dev: stat.dev, ino: stat.ino };
}

function sameDirectoryIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

function withAnchoredMaterializedDirectory(boundary, directory, operation) {
  const expected = stableDirectoryIdentity(boundary, directory);
  const original = process.cwd();
  let anchored = false;
  try {
    process.chdir(directory);
    anchored = true;
    if (!sameDirectoryIdentity(expected, fs.statSync('.'))) {
      fail('materialized artifact directory identity changed');
    }
    const result = operation();
    if (!sameDirectoryIdentity(expected, fs.statSync('.'))) {
      fail('materialized artifact directory identity changed');
    }
    return result;
  } finally {
    if (anchored) process.chdir(original);
  }
}

function readAnchoredPhysicalFile(name) {
  if (path.basename(name) !== name || name === '.' || name === '..') {
    fail('materialized artifact filename is invalid');
  }
  if (typeof fs.constants.O_NOFOLLOW !== 'number') {
    fail('no-follow materialized artifact reads are unsupported');
  }
  let fd;
  try {
    fd = fs.openSync(name, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  } catch (error) {
    if (error && error.code === 'ENOENT') return null;
    throw error;
  }
  try {
    const before = fs.fstatSync(fd);
    if (!before.isFile() || before.isSymbolicLink()) {
      fail('materialized artifact is not a physical file');
    }
    const body = fs.readFileSync(fd, 'utf8');
    const after = fs.fstatSync(fd);
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size) {
      fail('materialized artifact identity changed while reading');
    }
    return body;
  } finally {
    fs.closeSync(fd);
  }
}

function verifyMaterializedImmutable(filePath, body, boundary = path.dirname(filePath)) {
  return withAnchoredMaterializedDirectory(boundary, path.dirname(filePath), () => {
    const materialized = readAnchoredPhysicalFile(path.basename(filePath));
    if (materialized === null) return false;
    if (materialized !== body) fail('materialized artifact differs');
    return true;
  });
}

function materializeImmutableNoReplace(filePath, body, boundary = path.dirname(filePath)) {
  const directory = path.dirname(filePath);
  const name = path.basename(filePath);
  return withAnchoredMaterializedDirectory(boundary, directory, () => {
    const temporary = `.${name}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
    const fd = fs.openSync(temporary, 'wx', 0o600);
    try {
      fs.writeFileSync(fd, body, 'utf8');
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    try {
      fs.linkSync(temporary, name);
    } catch (error) {
      if (!error || error.code !== 'EEXIST') throw error;
      const materialized = readAnchoredPhysicalFile(name);
      if (materialized !== body) fail('materialized artifact differs');
      return false;
    } finally {
      fs.unlinkSync(temporary);
    }
    return true;
  });
}

function generatedArtifactDigestPath(config, logicalPath) {
  const request = config && config.request;
  const design = request && request.design_module_start;
  const execution = request && request.structured_execution;
  const allowed = [];
  if (design && typeof design.artifact_root === 'string') {
    allowed.push(`${design.artifact_root}/test-plan.json`);
  }
  if (execution && typeof execution.structured_plan_ref === 'string') {
    allowed.push(execution.structured_plan_ref);
  }
  return allowed.includes(logicalPath);
}

function artifactRead(projectRoot, logicalPath, expectedDigest, options = {}) {
  const runId = runIdFromPath(logicalPath);
  if (!runId) fail('artifact path has no run id');
  const config = loadConfig(projectRoot, runId);
  let result = storeExecute({ root: runRoot(runId), operation: 'artifact-read', path: logicalPath });
  if (!result.found) {
    if (options.durableOnly === true) return null;
    const unboundDigestImport = options.allowGeneratedDigestImport === true
      && generatedArtifactDigestPath(config, logicalPath);
    if (!validDigest(expectedDigest) && !unboundDigestImport) {
      fail(`unbound materialized artifact import is denied: ${logicalPath}`);
    }
    const target = artifactFile(projectRoot, logicalPath);
    const boundary = path.resolve(projectRoot, '.testing');
    const body = withAnchoredMaterializedDirectory(boundary, path.dirname(target), () =>
      readAnchoredPhysicalFile(path.basename(target)));
    if (body === null) return null;
    const observedDigest = sha256(body);
    if (expectedDigest && observedDigest !== expectedDigest) {
      fail('materialized artifact import digest differs');
    }
    const imported = storeExecute({
      root: runRoot(runId), operation: 'artifact-write', path: logicalPath, body,
    });
    if (!imported.written || imported.digest !== observedDigest) {
      fail('materialized artifact import differs');
    }
    result = { found: true, body, digest: imported.digest };
  }
  if (expectedDigest && result.digest !== expectedDigest) fail('artifact digest binding differs');
  const target = artifactFile(projectRoot, logicalPath);
  const boundary = path.resolve(projectRoot, '.testing');
  if (!verifyMaterializedImmutable(target, result.body, boundary)) {
    materializeImmutableNoReplace(target, result.body, boundary);
  }
  let value;
  try { value = JSON.parse(result.body); } catch (_error) { value = result.body; }
  return { value, raw: result.body, digest: result.digest };
}

function artifactWrite(projectRoot, logicalPath, value) {
  const runId = runIdFromPath(logicalPath);
  if (!runId) fail('artifact path has no run id');
  loadConfig(projectRoot, runId);
  const body = `${stable(value)}\n`;
  const result = storeExecute({ root: runRoot(runId), operation: 'artifact-write', path: logicalPath, body });
  if (!result.written) fail('immutable artifact differs');
  const target = artifactFile(projectRoot, logicalPath);
  const boundary = path.resolve(projectRoot, '.testing');
  if (!verifyMaterializedImmutable(target, body, boundary)) {
    materializeImmutableNoReplace(target, body, boundary);
  }
  return { written: true, replayed: result.replayed === true, digest: result.digest };
}

function artifactWriteRaw(projectRoot, logicalPath, body) {
  const runId = runIdFromPath(logicalPath);
  if (!runId) fail('artifact path has no run id');
  loadConfig(projectRoot, runId);
  const result = storeExecute({ root: runRoot(runId), operation: 'artifact-write', path: logicalPath, body });
  if (!result.written) fail('immutable artifact differs');
  const target = artifactFile(projectRoot, logicalPath);
  const boundary = path.resolve(projectRoot, '.testing');
  if (!verifyMaterializedImmutable(target, body, boundary)) {
    materializeImmutableNoReplace(target, body, boundary);
  }
  return { written: true, replayed: result.replayed === true, digest: result.digest };
}

const lineagePaths = lineageContract.paths;
const lineageSchemas = lineageContract.schemas;

function lineageRoot(config) {
  const expected = `.testing/runs/${config.run_id}`;
  if (config.artifact_root !== expected) fail('authorization lineage requires the canonical run root');
  return expected;
}

function lineagePath(config, name) {
  if (!lineagePaths[name]) fail(`unsupported authorization lineage receipt ${name}`);
  return `${lineageRoot(config)}/${lineagePaths[name]}`;
}

function claimFingerprint(config, domain, privateClaimId) {
  if (typeof privateClaimId !== 'string' || privateClaimId === '') fail('authorization claim id is unavailable');
  if (typeof config.lineage_projection_secret !== 'string'
    || config.lineage_projection_secret.length < 32) fail('lineage projection secret is unavailable');
  const inner = sha256(`${config.lineage_projection_secret}\0${domain}\0${privateClaimId}`);
  return sha256(`fkst-authorization-lineage.v1\0${domain}\0${inner}`);
}

function lineageEnvelope(config, schema, status, receiptId, recordedAt, fields) {
  return {
    schema, status, receipt_id: receiptId,
    repository: { url: config.repository.url, commit_sha: config.repository.commit_sha },
    run_id: config.run_id, trace_id: config.request.trace_id, dedup_key: config.request.dedup_key,
    recorded_at: recordedAt, source_max_uses: 1, evidence_role: 'audit-only',
    authorization_capability: false, reusable: false, ...fields,
  };
}

function writeLineageReceipt(projectRoot, config, name, value, expected) {
  lineageContract.validateReceipt(name, value, expected);
  const logicalPath = lineagePath(config, name);
  const body = stable(value);
  const written = artifactWriteRaw(projectRoot, logicalPath, body);
  const persisted = artifactRead(projectRoot, logicalPath);
  if (!persisted || persisted.raw !== body || persisted.digest !== sha256(body)
    || stable(persisted.value) !== body) fail(`authorization lineage receipt differs: ${name}`);
  lineageContract.validateReceipt(name, persisted.value, expected);
  return { ref: logicalPath, sha256: persisted.digest, value: persisted.value,
    expected, replayed: written.replayed === true };
}

function boundLineageArtifact(projectRoot, ref, expectedDigest, label) {
  const artifact = artifactRead(projectRoot, ref, expectedDigest);
  if (!artifact || (expectedDigest && artifact.digest !== expectedDigest)) {
    fail(`${label} artifact binding differs`);
  }
  return artifact;
}

function lineageSource(config, fields) {
  return {
    repository: { url: config.repository.url, commit_sha: config.repository.commit_sha },
    run_id: config.run_id,
    trace_id: config.request.trace_id,
    dedup_key: config.request.dedup_key,
    ...fields,
  };
}

function legacyPreauthorizationBinding(request) {
  return {
    authorization_id: request.authorization_id,
    preauthorization_sha256: request.preauthorization_sha256,
    repository: request.repository,
    plan_sha256: request.plan_sha256,
    environment_receipt_sha256: request.environment_receipt_sha256,
    trace_id: request.trace_id,
    dedup_key: request.dedup_key,
  };
}

function canonicalPreauthorizationBinding(request) {
  return {
    authorization_id: request.authorization_id,
    preauthorization_ref: request.preauthorization_ref,
    preauthorization_sha256: request.preauthorization_sha256,
    repository: request.repository,
    plan_ref: request.plan_ref,
    plan_sha256: request.plan_sha256,
    environment_receipt_ref: request.environment_receipt_ref,
    environment_receipt_sha256: request.environment_receipt_sha256,
    trace_id: request.trace_id,
    dedup_key: request.dedup_key,
  };
}

function trustedPreauthorizationRefs(config) {
  const request = config && config.request;
  const structured = request && request.structured_execution;
  const environment = request && request.environment_start;
  if (!structured || !environment || typeof structured.preauthorization_ref !== 'string'
    || typeof structured.structured_plan_ref !== 'string'
    || typeof environment.artifact_root !== 'string') return null;
  return {
    preauthorization_ref: structured.preauthorization_ref,
    plan_ref: structured.structured_plan_ref,
    environment_receipt_ref: `${environment.artifact_root}/environment-receipt-ready.json`,
  };
}

function compatibleStoredPreauthorizationBinding(stored) {
  if (!stored || typeof stored !== 'object' || Array.isArray(stored)
    || !Object.prototype.hasOwnProperty.call(stored, 'runtime_config_ref')) return stored;
  if (stable(stored.runtime_config_ref) !== stable({
    kind: 'artifact', ref: '.testing/generic-host-runtime.json',
  })) return stored;
  const normalized = { ...stored };
  delete normalized.runtime_config_ref;
  return normalized;
}

function preauthorizationBindingMatches(stored, request, trustedRefs) {
  if (!trustedRefs || request.preauthorization_ref !== trustedRefs.preauthorization_ref
    || request.plan_ref !== trustedRefs.plan_ref
    || request.environment_receipt_ref !== trustedRefs.environment_receipt_ref) return false;
  const normalized = compatibleStoredPreauthorizationBinding(stored);
  return stable(normalized) === stable(canonicalPreauthorizationBinding(request))
    || stable(normalized) === stable(legacyPreauthorizationBinding(request));
}

function completePreauthorizationRequest(preauthorization, request) {
  return {
    authorization_id: preauthorization.value.authorization_id,
    preauthorization_ref: request.preauthorization_ref,
    preauthorization_sha256: preauthorization.digest,
    repository: request.repository,
    plan_ref: request.plan_ref,
    plan_sha256: request.plan_sha256,
    environment_receipt_ref: request.environment_receipt_ref,
    environment_receipt_sha256: request.environment_receipt_sha256,
    trace_id: request.trace_id,
    dedup_key: request.dedup_key,
  };
}

function durableProfileClaim(config) {
  const claim = recordRead(runRoot(config.run_id), `generic-host/profile-approval/${config.run_id}`);
  if (!claim || typeof claim.claim_id !== 'string') fail('durable Profile claim is unavailable');
  return claim;
}

function durablePreauthorizationClaim(config, authorizationId) {
  const claim = recordRead(runRoot(config.run_id),
    `generic-host/preauthorization/${sha256(stable(authorizationId))}`);
  if (!claim || typeof claim.claim_id !== 'string') fail('durable Preauthorization claim is unavailable');
  return claim;
}

function durableGrantVerification(config, grantDigest) {
  const verification = recordRead(runRoot(config.run_id),
    `testing-runner/grant-verifications/${sha256(grantDigest)}`);
  if (!verification || !verification.binding) fail('durable Grant verification is unavailable');
  return verification;
}

function durableExecutionClaim(config) {
  const entries = recordList(runRoot(config.run_id), 'testing-runner/replay');
  if (entries.length !== 1 || !entries[0].value || typeof entries[0].value.claim_id !== 'string') {
    fail('durable execution claim is unavailable');
  }
  return entries[0].value;
}

function writeProfileClaimReceipt(projectRoot, config, durableClaim) {
  const claimedAt = durableClaim && (durableClaim.claimed_at || config.authorization_now);
  if (!durableClaim
    || stable(durableClaim.binding) !== stable(expectedProfileReplayBinding(config))
    || typeof durableClaim.claim_id !== 'string' || durableClaim.claim_id === ''
    || typeof claimedAt !== 'string' || claimedAt === '') {
    fail('environment authorization approval claim is unavailable');
  }
  const start = config.request.environment_start;
  const profile = boundLineageArtifact(projectRoot, start.profile_ref.ref, null, 'profile');
  const approval = boundLineageArtifact(projectRoot, start.approval_ref.ref, null, 'profile approval');
  const validation = boundLineageArtifact(projectRoot, start.validation_receipt_ref.ref, null, 'profile validation');
  if (profile.value.revision !== validation.value.profile_revision
    || approval.value.approval_id !== validation.value.approval_id
    || validation.value.profile_sha256 !== config.validation_receipt.profile_sha256
    || validation.value.approval_sha256 !== config.validation_receipt.approval_sha256) {
    fail('profile claim source artifacts differ');
  }
  const fingerprint = claimFingerprint(config, 'project-profile-approval-claim', durableClaim.claim_id);
  const source = lineageSource(config, {
      profile_source_ref: config.profile_source_ref,
      profile_artifact_ref: start.profile_ref.ref, profile_artifact_sha256: profile.digest,
      profile_sha256: validation.value.profile_sha256, profile_revision: profile.value.revision,
      approval_artifact_ref: start.approval_ref.ref, approval_artifact_sha256: approval.digest,
      approval_id: approval.value.approval_id, approval_sha256: validation.value.approval_sha256,
      approval_authority: approval.value.authority, policy_revision: approval.value.policy_revision,
      evidence_ref: approval.value.evidence_ref,
      validation_receipt_ref: start.validation_receipt_ref.ref,
      validation_receipt_sha256: validation.digest,
      claim_fingerprint_sha256: fingerprint, claimed_at: claimedAt,
    });
  const value = lineageEnvelope(config, lineageSchemas.profile_claim, 'claimed',
    `profile-claim-${fingerprint.slice(0, 32)}`, claimedAt, source);
  return writeLineageReceipt(projectRoot, config, 'profile_claim', value, source);
}

function writePreauthorizationClaimReceipt(projectRoot, config, request, durableClaim) {
  const claimedAt = durableClaim.claimed_at || config.execution_authorization_now;
  if (!preauthorizationBindingMatches(
    durableClaim.binding, request, trustedPreauthorizationRefs(config),
  )) {
    fail('durable Preauthorization claim binding differs');
  }
  const profileReceipt = writeProfileClaimReceipt(projectRoot, config, durableProfileClaim(config));
  const preauthorization = boundLineageArtifact(projectRoot, request.preauthorization_ref,
    request.preauthorization_sha256, 'preauthorization');
  const catalogRef = config.request.structured_execution.case_catalog_ref;
  const catalog = boundLineageArtifact(projectRoot, catalogRef,
    config.request.structured_execution.case_catalog_sha256, 'case catalog');
  const plan = boundLineageArtifact(projectRoot, request.plan_ref, request.plan_sha256, 'structured plan');
  const environment = boundLineageArtifact(projectRoot, request.environment_receipt_ref,
    request.environment_receipt_sha256, 'environment receipt');
  if (preauthorization.value.authorization_id !== request.authorization_id
    || preauthorization.value.profile_sha256 !== profileReceipt.value.profile_sha256
    || preauthorization.value.case_catalog_sha256 !== catalog.digest
    || plan.value.environment_receipt_sha256 !== environment.digest) {
    fail('preauthorization lineage source differs');
  }
  const fingerprint = claimFingerprint(config, 'structured-preauthorization-claim', durableClaim.claim_id);
  const source = lineageSource(config, {
      profile_claim_receipt_ref: profileReceipt.ref,
      profile_claim_receipt_sha256: profileReceipt.sha256,
      preauthorization_ref: request.preauthorization_ref,
      preauthorization_sha256: preauthorization.digest,
      authorization_id: preauthorization.value.authorization_id,
      profile_sha256: preauthorization.value.profile_sha256,
      case_catalog_ref: catalogRef, case_catalog_sha256: catalog.digest,
      plan_ref: request.plan_ref, plan_sha256: plan.digest,
      environment_receipt_ref: request.environment_receipt_ref,
      environment_receipt_sha256: environment.digest,
      authority: preauthorization.value.authority,
      policy_revision: preauthorization.value.policy_revision,
      evidence_ref: preauthorization.value.evidence_ref,
      claim_fingerprint_sha256: fingerprint, claimed_at: claimedAt,
    });
  const value = lineageEnvelope(config, lineageSchemas.preauthorization_claim, 'claimed',
    `preauthorization-claim-${fingerprint.slice(0, 32)}`, claimedAt, source);
  return writeLineageReceipt(projectRoot, config, 'preauthorization_claim', value, source);
}

function writeGrantVerificationReceipt(projectRoot, config, request) {
  const preauthorization = boundLineageArtifact(projectRoot, request.preauthorization_ref,
    request.preauthorization_sha256, 'preauthorization');
  const grant = boundLineageArtifact(projectRoot, request.grant_ref, request.grant_sha256, 'execution grant');
  const plan = boundLineageArtifact(projectRoot, request.plan_ref, request.plan_sha256, 'structured plan');
  const environment = boundLineageArtifact(projectRoot, request.environment_receipt_ref,
    request.environment_receipt_sha256, 'environment receipt');
  if (grant.value.parent_authorization_sha256 !== preauthorization.digest
    || grant.value.plan_sha256 !== plan.digest
    || grant.value.environment_receipt_sha256 !== environment.digest
    || stable(grant.value.repository) !== stable(request.repository)) {
    fail('grant verification source differs');
  }
  assertStructuredGrantDerivation(config, request, preauthorization, plan, environment, grant);
  const preauthorizationRequest = completePreauthorizationRequest(preauthorization, request);
  const preauthorizationReceipt = writePreauthorizationClaimReceipt(projectRoot, config,
    preauthorizationRequest,
    durablePreauthorizationClaim(config, preauthorization.value.authorization_id));
  const verificationId = `grant-verification-${grant.digest.slice(0, 32)}`;
  const root = runRoot(config.run_id);
  const durable = recordImmutable(root, `testing-runner/grant-verifications/${sha256(grant.digest)}`, {
    binding: {
      grant_ref: request.grant_ref, grant_sha256: grant.digest,
      preauthorization_ref: request.preauthorization_ref, preauthorization_sha256: preauthorization.digest,
      plan_ref: request.plan_ref, plan_sha256: plan.digest,
      environment_receipt_ref: request.environment_receipt_ref,
      environment_receipt_sha256: environment.digest, repository: request.repository,
      trace_id: request.trace_id, dedup_key: request.dedup_key,
    },
    verification_id: verificationId, verified_at: config.execution_authorization_now,
  });
  if (!durable.written && !durable.replayed) fail('grant verification durable record differs');
  const source = lineageSource(config, {
      preauthorization_claim_receipt_ref: preauthorizationReceipt.ref,
      preauthorization_claim_receipt_sha256: preauthorizationReceipt.sha256,
      grant_ref: request.grant_ref, grant_sha256: grant.digest, grant_id: grant.value.grant_id,
      parent_authorization_ref: request.preauthorization_ref,
      parent_authorization_sha256: preauthorization.digest,
      plan_ref: request.plan_ref, plan_sha256: plan.digest,
      environment_receipt_ref: request.environment_receipt_ref,
      environment_receipt_sha256: environment.digest,
      authority: grant.value.authority, policy_revision: grant.value.policy_revision,
      evidence_ref: grant.value.evidence_ref, verifier_ref: config.grant_verifier_ref,
      verification_id: verificationId, verified_at: durable.value.verified_at,
    });
  const value = lineageEnvelope(config, lineageSchemas.grant_verification, 'authenticated',
    verificationId, durable.value.verified_at, source);
  return writeLineageReceipt(projectRoot, config, 'grant_verification', value, source);
}

function writeExecutionClaimReceipt(projectRoot, config, request, durableClaim) {
  const claimedAt = durableClaim && (durableClaim.claimed_at || config.execution_authorization_now);
  if (!durableClaim || stable(durableClaim.binding) !== stable(request)
    || typeof durableClaim.claim_id !== 'string' || typeof claimedAt !== 'string'
    || durableClaim.fence_id !== claimFingerprint(
      config, 'structured-execution-fence', durableClaim.claim_id,
    )) {
    fail('execution claim durable binding differs');
  }
  const verification = durableGrantVerification(config, request.grant_sha256);
  const grantReceipt = writeGrantVerificationReceipt(projectRoot, config, verification.binding);
  const preauthorization = boundLineageArtifact(projectRoot, request.preauthorization_ref,
    request.preauthorization_sha256, 'preauthorization');
  const preauthorizationRequest = completePreauthorizationRequest(preauthorization, verification.binding);
  const preauthorizationReceipt = writePreauthorizationClaimReceipt(projectRoot, config,
    preauthorizationRequest,
    durablePreauthorizationClaim(config, preauthorization.value.authorization_id));
  const fingerprint = claimFingerprint(config, 'structured-execution-claim', durableClaim.claim_id);
  const source = lineageSource(config, {
      grant_verification_receipt_ref: grantReceipt.ref,
      grant_verification_receipt_sha256: grantReceipt.sha256,
      preauthorization_claim_receipt_ref: preauthorizationReceipt.ref,
      preauthorization_claim_receipt_sha256: preauthorizationReceipt.sha256,
      grant_ref: request.grant_ref, grant_sha256: request.grant_sha256,
      grant_id: request.grant_id, plan_ref: request.plan_ref, plan_sha256: request.plan_sha256,
      environment_receipt_ref: request.environment_receipt_ref,
      environment_receipt_sha256: request.environment_receipt_sha256,
      artifact_root: request.artifact_root, operation_id: request.operation_id,
      claim_fingerprint_sha256: fingerprint, claimed_at: claimedAt,
    });
  const value = lineageEnvelope(config, lineageSchemas.execution_claim, 'claimed',
    `execution-claim-${fingerprint.slice(0, 32)}`, claimedAt, source);
  return writeLineageReceipt(projectRoot, config, 'execution_claim', value, source);
}

function assertExecutionMatchesClaim(execution, claimBinding) {
  if (!execution || typeof execution !== 'object' || Array.isArray(execution)
    || !claimBinding || typeof claimBinding !== 'object' || Array.isArray(claimBinding)
    || !validDigest(execution.plan_sha256) || !validDigest(claimBinding.plan_sha256)
    || execution.plan_sha256 !== claimBinding.plan_sha256) {
    fail('completed execution Plan binding differs from the durable claim');
  }
  return true;
}

function writeExecutionCompletionReceipt(projectRoot, config, durableClaim) {
  const completedAt = durableClaim && durableClaim.completion
    && (durableClaim.completion.completed_at || config.execution_authorization_now);
  if (!durableClaim || durableClaim.status !== 'completed' || !durableClaim.completion
    || typeof completedAt !== 'string') {
    fail('execution completion durable binding differs');
  }
  const executionClaim = writeExecutionClaimReceipt(projectRoot, config,
    durableClaim.binding, durableClaim);
  const completion = durableClaim.completion;
  const artifacts = structuredExecutionArtifacts(projectRoot, completion.result_ref,
    completion.result_sha256);
  if (!artifacts.caseResultSet || !artifacts.evidenceManifest
    || artifacts.execution.digest !== completion.result_sha256) {
    fail('canonical execution completion artifacts are unavailable');
  }
  assertExecutionMatchesClaim(artifacts.execution.value, durableClaim.binding);
  const source = lineageSource(config, {
      execution_claim_receipt_ref: executionClaim.ref,
      execution_claim_receipt_sha256: executionClaim.sha256,
      result_ref: completion.result_ref, result_sha256: artifacts.execution.digest,
      case_result_set_ref: artifacts.execution.value.case_result_set_path,
      case_result_set_artifact_sha256: artifacts.caseResultSet.digest,
      evidence_manifest_ref: artifacts.execution.value.evidence_manifest_path,
      evidence_manifest_artifact_sha256: artifacts.evidenceManifest.digest,
      completed_at: completedAt,
    });
  const value = lineageEnvelope(config, lineageSchemas.execution_completion, 'completed',
    `execution-completion-${artifacts.execution.digest.slice(0, 32)}`, completedAt, source);
  const receipt = writeLineageReceipt(projectRoot, config, 'execution_completion', value, source);
  writeLineageIndex(projectRoot, config, completedAt, receipt);
  return receipt;
}

function writeLineageIndex(projectRoot, config, recordedAt, completionReceipt) {
  const preauthorization = boundLineageArtifact(projectRoot,
    config.request.structured_execution.preauthorization_ref,
    config.request.structured_execution.preauthorization_sha256, 'preauthorization');
  const grant = boundLineageArtifact(projectRoot, config.request.structured_execution.grant_ref,
    null, 'execution grant');
  const grantVerification = durableGrantVerification(config, grant.digest);
  const preauthorizationRequest = completePreauthorizationRequest(
    preauthorization, grantVerification.binding);
  const executionClaim = durableExecutionClaim(config);
  if (executionClaim.status !== 'completed') fail('durable completed execution claim is unavailable');
  const artifacts = {
    profile_claim: writeProfileClaimReceipt(projectRoot, config, durableProfileClaim(config)),
    preauthorization_claim: writePreauthorizationClaimReceipt(projectRoot, config,
      preauthorizationRequest,
      durablePreauthorizationClaim(config, preauthorization.value.authorization_id)),
    grant_verification: writeGrantVerificationReceipt(projectRoot, config, grantVerification.binding),
    execution_claim: writeExecutionClaimReceipt(projectRoot, config,
      executionClaim.binding, executionClaim),
    execution_completion: completionReceipt,
  };
  const expected = {};
  const receipts = {};
  for (const name of lineageContract.receiptNames) {
    expected[name] = artifacts[name].expected;
    receipts[name] = { ref: artifacts[name].ref, sha256: artifacts[name].sha256 };
  }
  const value = {
    schema: lineageSchemas.lineage_index, status: 'complete',
    repository: { url: config.repository.url, commit_sha: config.repository.commit_sha },
    run_id: config.run_id, trace_id: config.request.trace_id, dedup_key: config.request.dedup_key,
    recorded_at: recordedAt, receipts, lineage_complete: true, source_max_uses: 1,
    evidence_role: 'audit-only', authorization_capability: false, reusable: false,
  };
  lineageContract.validateLineageIndex(value, artifacts, expected);
  const path = `${lineageRoot(config)}/authorization-lineage/index.json`;
  const body = stable(value);
  artifactWriteRaw(projectRoot, path, body);
  const persisted = artifactRead(projectRoot, path);
  if (!persisted || persisted.raw !== body || persisted.digest !== sha256(body)) {
    fail('authorization lineage index differs');
  }
  lineageContract.validateLineageIndex(persisted.value, artifacts, expected);
  return { ref: path, sha256: persisted.digest, value: persisted.value };
}

function listIndexedRuns(projectRoot) {
  const runs = [];
  for (const entry of recordList(hostRoot(), 'runs')) {
    const value = entry.value;
    if (value && value.schema === 'generic-host.durable-workflow-qa-index.v1'
      && path.resolve(value.project_root) === path.resolve(projectRoot)
      && typeof value.run_id === 'string') runs.push(value.run_id);
  }
  return runs.sort();
}

function requestFor(projectRoot, runId) {
  loadConfig(projectRoot, runId);
  return recordRead(runRoot(runId), `workflow-qa/requests/${runId}`);
}

function pendingRequests(projectRoot, limit) {
  if (!Number.isInteger(limit) || limit < 1 || limit > 64) fail('pending run limit must be from 1 to 64');
  const pending = [];
  for (const runId of listIndexedRuns(projectRoot)) {
    const request = requestFor(projectRoot, runId);
    const state = recordRead(runRoot(runId), `workflow-qa/state/${runId}`);
    const terminal = recordRead(runRoot(runId), `generic-host/terminal/${runId}`);
    if (request && state && (state.phase !== 'terminal' || !terminal)) pending.push(request);
    if (pending.length >= limit) break;
  }
  return pending;
}

function crashBarrier(projectRoot, runId, name, details) {
  const config = loadConfig(projectRoot, runId);
  const barrier = config.crash_barrier;
  if (!barrier || barrier.name !== name || typeof barrier.token !== 'string'
    || process.env.FKST_DURABLE_CRASH_BARRIER !== barrier.token) return;
  const root = runRoot(runId);
  const witness = recordImmutable(root, `generic-host/barriers/${name}`, {
    schema: 'generic-host.crash-barrier.v1', run_id: runId, name,
    token_sha256: sha256(barrier.token), details,
  });
  if (!witness.written && !witness.replayed) fail('crash barrier witness differs');
  while (true) sleep(1000);
}

function publicationResult(projectRoot, payload) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  loadConfig(projectRoot, runId);
  const key = `test-publication/effects/${sha256(stable(payload))}`;
  const existing = recordRead(root, key);
  if (existing) {
    if (stable(existing.binding) !== stable(payload)) fail('publication binding differs');
    return existing.result;
  }
  let result;
  if (payload.channel === 'filesystem-dry-run-v1') {
    const artifactRoot = `.testing/runs/${runId}`;
    const receiptRef = `${artifactRoot}/published/${payload.stage}-${payload.attempt}-materialization.json`;
    const receipt = {
      schema: 'test-publication.qa-materialization-receipt.v1',
      status: 'materialized',
      channel: 'filesystem-dry-run-v1',
      run_id: runId,
      stage: payload.stage,
      attempt: payload.attempt,
      artifact_ref: payload.artifact_ref,
      digest: payload.digest,
      source_commit: payload.repository.commit_sha,
      receipt_ref: receiptRef,
      trace_id: payload.trace_id,
      dedup_key: payload.dedup_key,
    };
    const written = artifactWrite(projectRoot, receiptRef, receipt);
    result = {
      status: 'materialized', artifact_ref: payload.artifact_ref, digest: payload.digest,
      source_commit: payload.repository.commit_sha, receipt_ref: receiptRef,
      receipt_sha256: written.digest,
    };
  } else {
    result = {
      status: 'published',
      remote_url: `https://github.com/${payload.repository.slug}/blob/${payload.repository.commit_sha}/qa/${payload.stage}-${payload.attempt}.json`,
      digest: payload.digest,
      source_commit: payload.repository.commit_sha,
      receipt_ref: `.testing/runs/${runId}/published/${payload.stage}-${payload.attempt}.json`,
    };
  }
  const stored = recordImmutable(root, key, { binding: payload, result });
  if (!stored.written && !stored.replayed) fail('publication commit conflict');
  return result;
}

function directExec(argv, cwd, timeoutSeconds, outputBytes) {
  if (!Array.isArray(argv) || argv.length === 0 || argv.some((item) => typeof item !== 'string')) {
    fail('argv must be a non-empty string list');
  }
  const environment = childProcessEnvironment(cwd);
  try {
    verifyWorkerEnvironment(environment);
    const options = {
      cwd,
      encoding: 'utf8',
      timeout: Math.max(1, Number(timeoutSeconds) || 30) * 1000,
      env: environment,
    };
    if (Number.isInteger(outputBytes) && outputBytes >= 1024) options.maxBuffer = outputBytes;
    const result = spawnSync(argv[0], argv.slice(1), options);
    return {
      exit_code: result.status == null ? -1 : result.status,
      stdout: result.stdout || '',
      stderr: result.stderr || (result.error ? String(result.error.message || result.error) : ''),
    };
  } finally {
    releaseWorkerEnvironment(environment);
  }
}

function environmentStateKey(ref) {
  if (!ref || typeof ref.ref !== 'string') fail('environment state ref is required');
  return `environment-factory/state/${sha256(stable(ref.ref))}`;
}

function environmentResourceKey(ref) {
  return `environment-factory/resources/${sha256(stable(ref))}`;
}

function exactRuntimePorts(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 32) fail('runtime_ports are invalid');
  const names = new Set();
  const ports = new Set();
  return value.map((item) => {
    const port = Number(item && item.port);
    if (!item || typeof item.name !== 'string' || item.name === '' || item.name.length > 180
      || !Number.isInteger(port) || port < 1 || port > 65535 || names.has(item.name) || ports.has(port)) {
      fail('runtime_ports are invalid');
    }
    names.add(item.name);
    ports.add(port);
    return { name: item.name, port };
  });
}

function samePorts(left, right) {
  return stable(exactRuntimePorts(left)) === stable(exactRuntimePorts(right));
}

function resourceRecord(root, ref) {
  const resource = recordRead(root, environmentResourceKey(ref));
  if (!resource || resource.schema !== 'generic-host.environment-resource.v1'
    || stable(resource.cleanup_ref) !== stable(ref)) fail('environment resource is unavailable or malformed');
  return resource;
}

function workspaceResource(root, ref) {
  const resource = recordRead(root, environmentResourceKey(ref));
  if (!resource || resource.schema !== 'generic-host.environment-resource.v1'
    || resource.kind !== 'workspace' || stable(resource.workspace_ref) !== stable(ref)) {
    fail('workspace resource is unavailable or malformed');
  }
  return resource;
}

function verifyWorkspace(config, resource) {
  if (resource.operation_id !== config.run_id || resource.path !== config.workspace_root
    || typeof resource.ownership_token !== 'string' || resource.ownership_token === '') {
    fail('workspace ownership binding differs');
  }
  if (!fs.existsSync(resource.path)) return { owned: false, reason: 'workspace-missing' };
  const identity = pathIdentity(resource.path);
  if (!samePathIdentity(identity, resource.path_identity)) return { owned: false, reason: 'workspace-identity-changed' };
  return { owned: true, identity };
}

function registerWorkspace(projectRoot, payload) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  const config = loadConfig(projectRoot, runId);
  if (payload.operation_id !== runId || !payload.workspace_ref || !payload.cleanup_ref
    || payload.workspace_ref.ref !== `${runId}-workspace` || payload.cleanup_ref.ref !== `${runId}-workspace`
    || payload.path !== config.workspace_root || payload.repository.commit_sha !== config.commit_sha) {
    fail('workspace registration binding differs');
  }
  const identity = pathIdentity(payload.path);
  const resource = {
    schema: 'generic-host.environment-resource.v1', kind: 'workspace', operation_id: runId,
    workspace_ref: payload.workspace_ref, cleanup_ref: payload.cleanup_ref, path: payload.path,
    path_identity: identity, repository: payload.repository,
    ownership_token: crypto.randomBytes(16).toString('hex'),
  };
  for (const ref of [payload.workspace_ref, payload.cleanup_ref]) {
    const stored = recordImmutable(root, environmentResourceKey(ref), resource);
    if (!stored.written && !stored.replayed) fail('workspace resource binding differs');
  }
  return { registered: true, path_identity: identity };
}

function startApplication(projectRoot, payload) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  const config = loadConfig(projectRoot, runId);
  const ports = exactRuntimePorts(payload.runtime_ports);
  if (payload.operation_id !== runId || payload.effect_id == null || !payload.workspace_ref
    || payload.workspace_ref.ref !== `${runId}-workspace` || !payload.cleanup_ref
    || payload.cleanup_ref.ref !== `${runId}-application` || !Array.isArray(payload.argv)
    || payload.argv.length === 0 || !samePorts(ports, [{ name: 'application', port: config.port }])) {
    fail('application start binding differs');
  }
  const workspace = workspaceResource(root, payload.workspace_ref);
  const workspaceState = verifyWorkspace(config, workspace);
  if (!workspaceState.owned) fail(`workspace ownership failed: ${workspaceState.reason}`);
  const binding = {
    schema: 'generic-host.environment-resource.v1', kind: 'process', operation_id: runId,
    effect_id: payload.effect_id, cleanup_ref: payload.cleanup_ref, workspace_ref: payload.workspace_ref,
    workspace_path: workspace.path, workspace_identity: workspace.path_identity,
    argv_sha256: sha256(stable(payload.argv)),
    ownership_token: sha256(stable({
      schema: 'generic-host.process-ownership.v1', run_id: runId,
      effect_id: payload.effect_id, cleanup_ref: payload.cleanup_ref,
    })),
    runtime_ports: ports, repository: config.profile.repository,
  };
  const existing = recordRead(root, environmentResourceKey(payload.cleanup_ref));
  if (existing) {
    const volatile = new Set([
      'startup_state', 'startup_token_sha256', 'pid', 'pgid',
      'process_start_identity', 'worker_environment_lease',
    ]);
    const existingBinding = Object.fromEntries(
      Object.entries(existing).filter(([key]) => !volatile.has(key)),
    );
    if (stable(existingBinding) !== stable(binding)) fail('application replay binding differs');
    try {
      verifyWorkerEnvironmentLease(existing.worker_environment_lease);
    } catch (_error) {
      fail('application replay worker environment binding changed');
    }
    const group = processGroupState(existing);
    if (!group.supported || group.foreign) fail('application replay process ownership cannot be verified');
    if (!group.alive) {
      return { status: 'blocked', cleanup_ref: payload.cleanup_ref, early_exit: true, runtime_ports: ports };
    }
    const listenerState = listenersOwnedByProcessGroup(ports, existing.pgid);
    if (!listenerState.supported || !listenerState.owned) {
      fail(`application replay listener ownership failed: ${listenerState.reason}`);
    }
    return { status: 'running', cleanup_ref: payload.cleanup_ref, early_exit: false, runtime_ports: ports };
  }
  const startupClaimPath = path.join(root, 'private', 'supervised-process-startup.json');
  const launch = startOrRecoverSupervisedProcess({
      claimPath: startupClaimPath,
      argv: payload.argv,
      cwd: workspace.path,
      createEnvironment: (reservation) => childProcessEnvironment(workspace.path, reservation),
      binding,
  });
  if (launch.interrupted || !launch.resource) fail('application startup was interrupted before registration');
  const resource = launch.resource;
  if (launch.state !== 'running') {
    const stored = recordImmutable(root, environmentResourceKey(payload.cleanup_ref), resource);
    if (!stored.written && !stored.replayed) fail('application resource binding differs');
    return { status: 'blocked', cleanup_ref: payload.cleanup_ref, early_exit: true, runtime_ports: ports };
  }
  const deadline = Date.now() + 5_000;
  let listenerState = null;
  while (Date.now() < deadline) {
    listenerState = listenersOwnedByProcessGroup(ports, resource.pgid);
    if (listenerState.supported && listenerState.owned) break;
    sleep(25);
  }
  if (!listenerState || !listenerState.supported || !listenerState.owned) {
    terminateProcessGroup(resource, 500);
    releaseWorkerEnvironmentLease(resource.worker_environment_lease);
    const stored = recordImmutable(root, environmentResourceKey(payload.cleanup_ref), resource);
    if (!stored.written && !stored.replayed) fail('application resource binding differs');
    fail(`application ownership could not be verified: ${listenerState && listenerState.reason || 'process-start-failed'}`);
  }
  const stored = recordImmutable(root, environmentResourceKey(payload.cleanup_ref), resource);
  if (!stored.written && !stored.replayed) fail('application resource binding differs');
  return { status: 'running', cleanup_ref: payload.cleanup_ref, early_exit: false, runtime_ports: ports };
}

function inspectResources(projectRoot, payload) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  const config = loadConfig(projectRoot, runId);
  const workspaceRef = { kind: 'workspace', ref: `${runId}-workspace` };
  const processRef = { kind: 'process-cleanup', ref: `${runId}-application` };
  const workspace = workspaceResource(root, workspaceRef);
  const process = resourceRecord(root, processRef);
  const workspaceState = verifyWorkspace(config, workspace);
  if (!workspaceState.owned) return { owned: false, reason: workspaceState.reason };
  if (process.kind !== 'process' || process.operation_id !== runId
    || process.workspace_path !== workspace.path || !samePathIdentity(process.workspace_identity, workspace.path_identity)
    || typeof process.ownership_token !== 'string' || process.ownership_token === '') {
    return { owned: false, reason: 'process-binding-changed' };
  }
  try {
    verifyWorkerEnvironmentLease(process.worker_environment_lease);
  } catch (_error) {
    return { owned: false, reason: 'worker-environment-binding-changed' };
  }
  const group = processGroupState(process);
  if (!group.supported || !group.alive || group.foreign) return { owned: false, reason: 'process-group-not-owned' };
  const listeners = listenersOwnedByProcessGroup(process.runtime_ports, process.pgid);
  if (!listeners.supported || !listeners.owned) return { owned: false, reason: listeners.reason || 'listeners-not-owned' };
  return {
    owned: true, pid: process.pid, pgid: process.pgid, process_start_identity: process.process_start_identity,
    ownership_token: process.ownership_token, runtime_ports: process.runtime_ports,
    workspace_path: workspace.path, workspace_identity: workspace.path_identity,
  };
}

function releasedResources(projectRoot, payload) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  const config = loadConfig(projectRoot, runId);
  const process = resourceRecord(root, { kind: 'process-cleanup', ref: `${runId}-application` });
  const group = processGroupState(process);
  const listeners = listenersReleased(process.runtime_ports);
  return {
    process_group_absent: group.supported === true && group.alive === false,
    listeners_closed: listeners.supported === true && listeners.released === true,
    workspace_absent: !fs.existsSync(config.workspace_root),
    worker_environment_absent: !process.worker_environment_lease
      || !fs.existsSync(process.worker_environment_lease.home),
  };
}

function releaseOwnedProcessResource(resource, timeoutMs) {
  const group = processGroupState(resource);
  if (!group.supported || group.foreign) fail('process cleanup ownership cannot be verified');
  if (group.alive) {
    const owned = listenersOwnedByProcessGroup(resource.runtime_ports, resource.pgid);
    if (!owned.supported || !owned.owned) fail(`process listener ownership cannot be verified: ${owned.reason}`);
    const stopped = terminateProcessGroup(resource, timeoutMs);
    if (!stopped.released) fail(`process cleanup failed: ${stopped.reason}`);
  }
  const listeners = listenersReleased(resource.runtime_ports);
  if (!listeners.supported || !listeners.released) fail('process listeners remain after cleanup');
  if (!releaseWorkerEnvironmentLease(resource.worker_environment_lease)) {
    fail('process worker environment cleanup failed');
  }
  return true;
}

function cleanupResource(projectRoot, payload) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  const config = loadConfig(projectRoot, runId);
  const cleanupRef = payload.cleanup_ref || {};
  const resource = resourceRecord(root, cleanupRef);
  if (payload.operation_id !== runId || resource.operation_id !== runId
    || typeof resource.ownership_token !== 'string' || resource.ownership_token === '') {
    fail('resource cleanup ownership binding differs');
  }
  if (resource.kind === 'process') {
    const workspace = workspaceResource(root, resource.workspace_ref);
    const workspaceState = verifyWorkspace(config, workspace);
    if (!workspaceState.owned || !samePathIdentity(resource.workspace_identity, workspace.path_identity)) {
      fail('process cleanup workspace ownership differs');
    }
    releaseOwnedProcessResource(resource, Math.max(1, Number(payload.timeout_seconds) || 5) * 1000);
  } else if (resource.kind === 'workspace') {
    const process = resourceRecord(root, { kind: 'process-cleanup', ref: `${runId}-application` });
    const group = processGroupState(process);
    if (!group.supported || group.alive) fail('workspace cleanup requires a released process group');
    const listeners = listenersReleased(process.runtime_ports);
    if (!listeners.supported || !listeners.released) fail('workspace cleanup requires released listeners');
    const workspaceState = verifyWorkspace(config, resource);
    if (!workspaceState.owned) fail(`workspace cleanup ownership cannot be verified: ${workspaceState.reason}`);
    if (!removeOwnedDirectory(resource.path, resource.path_identity, config.temp_root)) {
      fail('workspace cleanup did not remove the owned workspace');
    }
  } else if (resource.kind === 'ports') {
    const listeners = listenersReleased(resource.runtime_ports);
    if (!listeners.supported || !listeners.released) fail('port cleanup requires released listeners');
  } else {
    fail('unsupported resource cleanup kind');
  }
  return { status: 'cleaned' };
}

function environmentEffect(projectRoot, payload, produce) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  loadConfig(projectRoot, runId);
  if (typeof payload.effect_id !== 'string' || payload.effect_id === '') fail('environment effect_id is required');
  const key = `environment-factory/effects/${sha256(stable(payload.effect_id))}`;
  const binding = { ...payload };
  delete binding.runtime_config_ref;
  const existing = recordRead(root, key);
  if (existing) {
    if (stable(existing.binding) !== stable(binding)) fail('environment effect binding differs');
    return existing.result;
  }
  const result = produce(runId, root);
  const stored = recordImmutable(root, key, { binding, result });
  if (!stored.written && !stored.replayed) fail('environment effect commit conflict');
  return result;
}

function waitForHttp(url, timeoutSeconds) {
  const script = [
    "const http=require('http'),https=require('https'),url=process.argv[1],end=Date.now()+Number(process.argv[2])*1000;",
    "function poll(){const client=url.startsWith('https:')?https:http;const req=client.get(url,res=>{res.resume();process.exit(res.statusCode>=200&&res.statusCode<500?0:1)});",
    "req.on('error',()=>{if(Date.now()>=end)process.exit(1);setTimeout(poll,20)});req.setTimeout(500,()=>req.destroy())}poll();",
  ].join('');
  return directExec([process.execPath, '-e', script, url, String(timeoutSeconds || 30)], process.cwd(), timeoutSeconds).exit_code === 0;
}

function structuredReplayKey(grantId) {
  return `testing-runner/replay/${sha256(stable(grantId))}`;
}

const { structuredExecutionArtifacts } = require('./structured-execution-artifacts').create({
  artifactRead, boundedString, exactKeys, fail, path, safeArtifactPath, samePointer,
  sha256, stableStringify: stable, validDigest, validRepository,
});

function structuredAuthorizationKey(receiptId) {
  return `testing-runner/effect-authorizations/${sha256(stable(receiptId))}`;
}

function structuredConsumptionKey(receiptId) {
  return `testing-runner/effect-consumptions/${sha256(stable(receiptId))}`;
}

function localHttpRequest(request, timeoutSeconds) {
  const script = [
    "const http=require('http'),url=process.argv[1],method=process.argv[2],timeout=Number(process.argv[3])*1000;",
    "const req=http.request(url,{method},res=>{const chunks=[];res.on('data',chunk=>chunks.push(chunk));",
    "res.on('end',()=>process.stdout.write(JSON.stringify({status:res.statusCode,headers:{'content-type':String(res.headers['content-type']||'')},body:Buffer.concat(chunks).toString('utf8')})))});",
    "req.on('error',error=>{process.stderr.write(String(error.message||error));process.exit(1)});",
    "req.setTimeout(timeout,()=>req.destroy(new Error('request-timeout')));req.end();",
  ].join('');
  const executed = directExec([process.execPath, '-e', script, request.url, request.method,
    String(timeoutSeconds || 30)], process.cwd(), timeoutSeconds);
  if (executed.exit_code !== 0) fail('structured HTTP request failed');
  try { return JSON.parse(executed.stdout); } catch (_error) { fail('structured HTTP response is malformed'); }
}

function inventoryAcceptanceReport(projectRoot, config, terminal) {
  if (config.fixture_name !== 'downstream-inventory') return;
  const completed = recordList(runRoot(config.run_id), 'testing-runner/replay')
    .filter((entry) => entry.value && entry.value.status === 'completed');
  if (completed.length !== 1) fail('inventory completed replay is unavailable');
  const artifacts = structuredExecutionArtifacts(projectRoot, completed[0].value.result_ref,
    completed[0].value.result_sha256);
  if (artifacts.execution.digest !== completed[0].value.result_sha256) {
    fail('inventory completed replay result differs');
  }
  const definitions = [
    ['inventory-initial-state', 'GET inventory', 'HTTP 200 with initial inventory'],
    ['inventory-reserve-three', 'Reserve three', 'Exit 0 with reserved inventory'],
    ['inventory-state-after-reserve', 'GET inventory', 'HTTP 200 with reserved inventory'],
    ['inventory-over-reserve-rejected', 'Reserve three again', 'Exit 4 with insufficient availability'],
    ['inventory-state-after-rejection', 'GET inventory', 'HTTP 200 with unchanged inventory'],
  ];
  if (!artifacts.caseResultSet || !artifacts.evidenceManifest) {
    fail('inventory canonical execution artifacts are required');
  }
  const canonicalCases = artifacts.caseResultSet.value.cases;
  const legacy = artifacts.caseResults.value;
  if (legacy.schema !== 'testing-structured-case-results.v1'
    || legacy.plan_sha256 !== artifacts.caseResultSet.value.plan_sha256
    || !Array.isArray(legacy.cases) || legacy.cases.length !== canonicalCases.length
    || canonicalCases.length !== definitions.length) {
    fail('inventory canonical and legacy result sets differ');
  }
  const manifestEntries = new Map(artifacts.evidenceManifest.value.entries
    .map((entry) => [entry.evidence_id, entry]));
  const evidencePaths = new Map();
  const byId = new Map();
  for (let index = 0; index < canonicalCases.length; index += 1) {
    const result = canonicalCases[index];
    const projected = legacy.cases[index];
    const expectedCaseId = definitions[index][0];
    let expectedStatus;
    let expectedClassification;
    if (result.execution_status === 'passed' && result.classification === 'deterministic') {
      expectedStatus = 'passed'; expectedClassification = 'passed';
    } else if (result.execution_status === 'failed' && result.classification === 'assertion_failure') {
      expectedStatus = 'failed'; expectedClassification = 'product-defect';
    } else if (result.execution_status === 'skipped' && result.classification === 'not_applicable') {
      expectedStatus = 'skipped'; expectedClassification = result.non_execution_reason;
    } else if (result.execution_status === 'error' && result.classification === 'execution_error'
      && result.error && boundedString(result.error.code, 96)) {
      expectedStatus = 'error'; expectedClassification = result.error.code;
    } else {
      fail('inventory canonical result outcome is not compatible with v1');
    }
    if (result.case_id !== expectedCaseId || !projected || projected.case_id !== result.case_id
      || projected.kind !== result.execution_mode || projected.status !== expectedStatus
      || projected.classification !== expectedClassification
      || !Array.isArray(projected.assertions) || projected.assertions.length !== result.assertions.length) {
      fail('inventory canonical and legacy case result differ');
    }
    for (let assertionIndex = 0; assertionIndex < result.assertions.length; assertionIndex += 1) {
      const assertion = result.assertions[assertionIndex];
      const legacyAssertion = projected.assertions[assertionIndex];
      if (!legacyAssertion || assertion.type !== legacyAssertion.type
        || legacyAssertion.passed !== (assertion.status === 'passed')) {
        fail('inventory canonical and legacy assertion result differ');
      }
    }
    if (!Array.isArray(result.evidence_refs) || result.evidence_refs.length !== 1
      || result.evidence_refs[0].kind !== 'evidence') {
      fail('inventory canonical case evidence is ambiguous');
    }
    const manifestEntry = manifestEntries.get(result.evidence_refs[0].ref);
    if (!manifestEntry || manifestEntry.case_id !== result.case_id
      || projected.evidence_ref !== manifestEntry.artifact_ref.ref) {
      fail('inventory canonical and legacy evidence pointer differ');
    }
    evidencePaths.set(result.case_id, manifestEntry.artifact_ref.ref);
    byId.set(result.case_id, result);
  }

  const effects = new Map();
  const effectEntries = recordList(runRoot(config.run_id), 'testing-runner/target-effects');
  if (effectEntries.length !== definitions.length) fail('inventory target effects must occur exactly once');
  for (const entry of effectEntries) {
    const binding = entry.value && entry.value.binding;
    const envelope = binding && binding.action_envelope;
    const caseId = binding && (binding.case_id || (envelope && envelope.case && envelope.case.case_id));
    if (!definitions.some(([expected]) => expected === caseId) || effects.has(caseId)) {
      fail('inventory target effects must occur exactly once');
    }
    effects.set(caseId, entry.value.result);
  }
  const lines = [
    '| Case ID | Action | Expected result | Actual result | Status | Evidence |',
    '| --- | --- | --- | --- | --- | --- |',
  ];
  for (const [caseId, action, expected] of definitions) {
    const result = byId.get(caseId);
    const effect = effects.get(caseId) || {};
    const actual = result && result.execution_mode === 'cli'
      ? `exit ${effect.exit_code}; stdout ${JSON.stringify(effect.stdout || '')}; stderr ${JSON.stringify(effect.stderr || '')}`
      : `HTTP ${effect.status}; body ${JSON.stringify(effect.body || '')}`;
    lines.push(`| ${caseId} | ${action} | ${expected} | ${actual} | ${result && result.execution_status || 'missing'} | ${evidencePaths.get(caseId) || 'missing'} |`);
  }
  const passed = terminal.status === 'passed' && terminal.counts && terminal.counts.planned === 5
    && definitions.every(([caseId]) => byId.get(caseId)
      && byId.get(caseId).execution_status === 'passed'
      && byId.get(caseId).classification === 'deterministic');
  lines.push('', passed ? 'Verdict: downstream business acceptance passed' : 'Verdict: not ready', '');
  artifactWriteRaw(projectRoot, `.testing/runs/${config.run_id}/acceptance-report.md`, lines.join('\n'));
}

function exactKeys(value, expected) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  return Object.keys(value).sort().join('\0') === [...expected].sort().join('\0');
}

function sha256Bytes(payload) {
  const fields = payload && payload.runtime_config_ref === undefined
    ? ['bytes'] : ['bytes', 'runtime_config_ref'];
  if (!exactKeys(payload, fields)) fail('sha256-bytes payload fields are invalid');
  if (typeof payload.bytes !== 'string' || Buffer.byteLength(payload.bytes, 'utf8') > 1024 * 1024) {
    fail('sha256-bytes requires a string no larger than 1 MiB');
  }
  return { sha256: sha256(payload.bytes) };
}

function boundedString(value, limit) {
  return typeof value === 'string' && value.length > 0 && value.length <= limit
    && !/[\0-\x1f\x7f]/.test(value);
}

function validDigest(value) {
  return typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
}

function validRepository(value) {
  return exactKeys(value, ['url', 'commit_sha'])
    && boundedString(value.url, 2048) && /^https:\/\/[^/@]+\/[^?#]+$/.test(value.url)
    && !value.url.includes('@') && /^[0-9a-f]{40}$/.test(value.commit_sha);
}

function sameRepository(left, right) {
  return validRepository(left) && validRepository(right)
    && left.url === right.url && left.commit_sha === right.commit_sha;
}

function samePointer(left, right) {
  return exactKeys(left, ['kind', 'ref']) && exactKeys(right, ['kind', 'ref'])
    && left.kind === right.kind && left.ref === right.ref;
}

const shellExecutables = new Set([
  'sh', 'bash', 'dash', 'zsh', 'fish', 'ksh', 'csh', 'tcsh', 'cmd', 'cmd.exe',
  'powershell', 'powershell.exe', 'pwsh', 'pwsh.exe',
]);

function executableName(argv) {
  let index = 0;
  let name = path.basename(String(argv[index] || '')).toLowerCase();
  if (name === 'env') {
    index += 1;
    while (typeof argv[index] === 'string' && /^[A-Za-z_][A-Za-z0-9_]*=/.test(argv[index])) index += 1;
    name = path.basename(String(argv[index] || '')).toLowerCase();
  }
  return name;
}

function validArgv(argv) {
  return Array.isArray(argv) && argv.length > 0 && argv.length <= 32
    && argv.every((item) => boundedString(item, 512)) && !shellExecutables.has(executableName(argv));
}

function validCliCapabilities(value) {
  return Array.isArray(value) && value.length <= 64 && value.every((capability) =>
    exactKeys(capability, ['argv_prefix']) && validArgv(capability.argv_prefix));
}

function argvAllowed(argv, capabilities) {
  return validArgv(argv) && validCliCapabilities(capabilities) && capabilities.some((capability) =>
    capability.argv_prefix.length <= argv.length
      && capability.argv_prefix.every((item, index) => item === argv[index]));
}

const httpMethods = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE']);

function validHttpCapabilities(value) {
  return Array.isArray(value) && value.length <= 64 && value.every((capability) =>
    exactKeys(capability, ['origin', 'methods', 'path_prefixes'])
      && boundedString(capability.origin, 512)
      && /^https?:\/\/[^\/@]+$/.test(capability.origin)
      && Array.isArray(capability.methods) && capability.methods.length > 0
      && capability.methods.length <= 8 && capability.methods.every((method) => httpMethods.has(method))
      && Array.isArray(capability.path_prefixes) && capability.path_prefixes.length > 0
      && capability.path_prefixes.length <= 16
      && capability.path_prefixes.every((prefix) => boundedString(prefix, 512)
        && prefix.startsWith('/') && !prefix.includes('?') && !prefix.includes('#')));
}

function splitHttpUrl(value) {
  if (!boundedString(value, 2048) || value.includes('?') || value.includes('#')) return null;
  const match = /^(https?:\/\/[^/]+)(\/.*)?$/.exec(value);
  if (!match || match[1].includes('@')) return null;
  return { origin: match[1], path: match[2] || '/' };
}

function httpAllowed(request, capabilities) {
  const target = request && splitHttpUrl(request.url);
  return target !== null && httpMethods.has(request.method) && validHttpCapabilities(capabilities)
    && capabilities.some((capability) => capability.origin === target.origin
      && capability.methods.includes(request.method)
      && capability.path_prefixes.some((prefix) => target.path.startsWith(prefix)));
}

function planWithinCapabilities(plan, capabilities) {
  if (!plan || plan.schema !== 'testing-structured-plan.v2'
    || plan.execution_mode !== 'structured-api-cli'
    || !exactKeys(capabilities, ['cli', 'http'])
    || !validCliCapabilities(capabilities.cli) || !validHttpCapabilities(capabilities.http)
    || !Array.isArray(plan.cases) || plan.cases.length === 0 || plan.cases.length > 64) return false;
  return plan.cases.every((planned) => planned && (
    typeof planned.skip_reason === 'string' && boundedString(planned.skip_reason, 512)
      || planned.kind === 'cli' && argvAllowed(planned.argv, capabilities.cli)
      || planned.kind === 'http' && httpAllowed(planned.request, capabilities.http)
  ));
}

function hostStructuredGrantValues(config) {
  return {
    grant_id: `${config.run_id}-grant`,
    evidence_ref: { kind: 'signed-attestation', ref: `${config.run_id}-execution-grant` },
    issued_at: '2026-07-22T00:15:00Z',
    expires_at: '2026-07-22T00:45:00Z',
    now: '2026-07-22T00:20:00Z',
  };
}

function assertStructuredGrantDerivation(config, request, preauthorization, plan, environment, grant) {
  const authorization = preauthorization && preauthorization.value;
  const structuredPlan = plan && plan.value;
  const readyEnvironment = environment && environment.value;
  const persistedGrant = grant && grant.value;
  const values = hostStructuredGrantValues(config);
  if (config.execution_authorization_now !== undefined
      && config.execution_authorization_now !== values.now
    || !authorization || authorization.schema !== 'testing-structured-execution-authorization.v1'
    || authorization.max_uses !== 1 || !validWindow(authorization, values.now)
    || !sameRepository(authorization.repository, request.repository)
    || !structuredPlan || !sameRepository(structuredPlan.repository, request.repository)
    || authorization.case_catalog_sha256 !== structuredPlan.case_catalog_sha256
    || structuredPlan.environment_receipt_sha256 !== environment.digest
    || authorization.trace_id !== request.trace_id || authorization.dedup_key !== request.dedup_key
    || structuredPlan.trace_id !== request.trace_id || structuredPlan.dedup_key !== request.dedup_key
    || !readyEnvironment || readyEnvironment.status !== 'ready'
    || !sameRepository(readyEnvironment.repository, request.repository)
    || readyEnvironment.trace_id !== request.trace_id || readyEnvironment.dedup_key !== request.dedup_key
    || !planWithinCapabilities(structuredPlan, authorization.capabilities)) {
    fail('grant derivation source differs');
  }
  const expected = {
    schema: 'testing-structured-execution-grant.v1',
    grant_id: values.grant_id,
    parent_authorization_sha256: preauthorization.digest,
    plan_sha256: plan.digest,
    environment_receipt_sha256: environment.digest,
    repository: structuredPlan.repository,
    cli_capabilities: authorization.capabilities.cli,
    http_capabilities: authorization.capabilities.http,
    authority: authorization.authority,
    policy_revision: authorization.policy_revision,
    evidence_ref: values.evidence_ref,
    issued_at: values.issued_at,
    expires_at: values.expires_at,
    max_uses: 1,
    trace_id: request.trace_id,
    dedup_key: request.dedup_key,
  };
  if (!persistedGrant || stable(persistedGrant) !== stable(expected)
    || request.grant !== undefined && stable(request.grant) !== stable(persistedGrant)
    || request.grant_raw !== undefined && (typeof request.grant_raw !== 'string'
      || sha256(request.grant_raw) !== grant.digest)
    || request.now !== undefined && request.now !== values.now) {
    fail('grant differs from authenticated derivation');
  }
  return expected;
}

function validWindow(value, now) {
  const issued = Date.parse(value && value.issued_at);
  const expires = Date.parse(value && value.expires_at);
  const current = Date.parse(now);
  return Number.isFinite(issued) && Number.isFinite(expires) && expires > issued
    && Number.isFinite(current) && current >= issued && current < expires;
}

function validActionEnvelope(envelope, expectedKind) {
  const commonFields = [
    'schema', 'effect_kind', 'capability', 'profile_ref', 'profile_artifact_sha256',
    'profile_sha256', 'validation_receipt_ref', 'validation_receipt_sha256',
    'preauthorization_ref', 'preauthorization_sha256', 'repository', 'run_id',
    'operation_id', 'environment_receipt_ref', 'environment_receipt_sha256',
    'workspace_ref', 'plan_ref', 'plan_sha256', 'grant_ref', 'grant_sha256', 'case',
    'resource_bounds', 'attempt', 'trace_id', 'dedup_key', 'expires_at', 'fence_id',
  ];
  const kind = envelope && envelope.effect_kind;
  const fields = kind === 'http' ? [...commonFields, 'base_url'] : commonFields;
  const digestFields = [
    'profile_artifact_sha256', 'profile_sha256', 'validation_receipt_sha256',
    'preauthorization_sha256', 'environment_receipt_sha256', 'plan_sha256', 'grant_sha256',
  ];
  const pointerFields = [
    'profile_ref', 'validation_receipt_ref', 'preauthorization_ref',
    'environment_receipt_ref', 'plan_ref', 'grant_ref',
  ];
  const action = envelope && envelope.case;
  const assertions = action && action.assertions;
  return exactKeys(envelope, fields)
    && (expectedKind === undefined || kind === expectedKind)
    && (kind === 'cli' || kind === 'http')
    && envelope.schema === (kind === 'cli'
      ? 'testing-cli-action-envelope.v1' : 'testing-http-action-envelope.v1')
    && envelope.capability === (kind === 'cli' ? 'direct-argv' : 'loopback-http')
    && envelope.run_id === envelope.operation_id && envelope.attempt === 1
    && boundedString(envelope.run_id, 180) && /^[A-Za-z0-9._-]+$/.test(envelope.run_id)
    && boundedString(envelope.trace_id, 180) && boundedString(envelope.dedup_key, 180)
    && boundedString(envelope.fence_id, 180) && Number.isFinite(Date.parse(envelope.expires_at))
    && validRepository(envelope.repository) && samePointer(envelope.workspace_ref, envelope.workspace_ref)
    && envelope.workspace_ref.kind === 'workspace' && boundedString(envelope.workspace_ref.ref, 2048)
    && pointerFields.every((field) => safeArtifactPath(envelope[field]))
    && digestFields.every((field) => validDigest(envelope[field]))
    && exactKeys(envelope.resource_bounds, ['output_bytes'])
    && Number.isInteger(envelope.resource_bounds.output_bytes)
    && envelope.resource_bounds.output_bytes >= 1024
    && envelope.resource_bounds.output_bytes <= 1024 * 1024
    && boundedString(action.case_id, 180) && /^[A-Za-z0-9._-]+$/.test(action.case_id)
    && action.kind === kind
    && Number.isInteger(action.timeout_seconds) && action.timeout_seconds >= 1
    && action.timeout_seconds <= 300 && Array.isArray(assertions)
    && assertions.length > 0 && assertions.length <= 16
    && (kind === 'cli'
      ? exactKeys(action, ['case_id', 'kind', 'argv', 'timeout_seconds', 'assertions'])
        && validArgv(action.argv)
        && assertions.every((assertion) => exactKeys(assertion, ['type', 'expected'])
          && assertion.type === 'exit-code' && Number.isInteger(assertion.expected)
          && assertion.expected >= 0 && assertion.expected <= 255)
      : exactKeys(action, ['case_id', 'kind', 'request', 'timeout_seconds', 'assertions'])
        && exactKeys(action.request, ['method', 'url', 'headers'])
        && httpMethods.has(action.request.method) && Array.isArray(action.request.headers)
        && action.request.headers.length === 0 && splitHttpUrl(envelope.base_url) !== null
        && splitHttpUrl(action.request.url) !== null
        && splitHttpUrl(action.request.url).origin === splitHttpUrl(envelope.base_url).origin
        && assertions.every((assertion) => {
          if (assertion && assertion.type === 'status-code') {
            return exactKeys(assertion, ['type', 'expected']) && Number.isInteger(assertion.expected)
              && assertion.expected >= 100 && assertion.expected <= 599;
          }
          if (assertion && assertion.type === 'body-contains') {
            return exactKeys(assertion, ['type', 'expected']) && boundedString(assertion.expected, 512);
          }
          return assertion && assertion.type === 'json-path-equals'
            && exactKeys(assertion, ['type', 'path', 'expected'])
            && boundedString(assertion.path, 512)
            && assertion.path.split('.').every((part) => /^[A-Za-z_][A-Za-z0-9_-]*$/.test(part))
            && ['string', 'number', 'boolean'].includes(typeof assertion.expected);
        }));
}

function activeStructuredRequest(root, runId) {
  const state = recordRead(root, `workflow-qa/state/${runId}`);
  if (!state || state.phase !== 'structured-execution-pending' || !Array.isArray(state.pending_actions)) return null;
  const action = state.pending_actions.find((item) => item && item.queue === 'testing-runner.structured_execution_request');
  return action && action.payload || null;
}

function structuredCaseSequence(projectRoot, request, caseId) {
  const plan = request && artifactRead(projectRoot, request.test_plan_ref, request.test_plan_sha256);
  const cases = plan && plan.value && plan.value.cases;
  if (!Array.isArray(cases)) fail('structured test plan is unavailable');
  const index = cases.findIndex((value) => value && value.case_id === caseId);
  if (index < 0) fail('structured case is absent from the test plan');
  return index + 1;
}

function envelopeMatchesRequest(envelope, request, payload) {
  return request && payload.artifact_root === request.artifact_root
    && envelope.run_id === request.source_ref.ref && envelope.operation_id === request.source_ref.ref
    && sameRepository(envelope.repository, request.repository)
    && envelope.profile_ref === request.project_profile_ref
    && envelope.profile_artifact_sha256 === request.project_profile_artifact_sha256
    && envelope.profile_sha256 === request.profile_sha256
    && envelope.validation_receipt_ref === request.validation_receipt_ref
    && envelope.validation_receipt_sha256 === request.validation_receipt_sha256
    && envelope.preauthorization_ref === request.preauthorization_ref
    && envelope.preauthorization_sha256 === request.preauthorization_sha256
    && envelope.environment_receipt_ref === request.environment_receipt_ref
    && envelope.environment_receipt_sha256 === request.environment_receipt_sha256
    && envelope.plan_ref === request.test_plan_ref && envelope.plan_sha256 === request.test_plan_sha256
    && envelope.grant_ref === request.execution_grant_ref
    && envelope.grant_sha256 === request.execution_grant_sha256
    && envelope.trace_id === request.trace_id && envelope.dedup_key === request.dedup_key;
}

function structuredAuthorizationReceipt(runId, envelope, decision, reasonCode, inputs) {
  const envelopeSha256 = sha256(stable(envelope));
  const issuedAt = '2026-07-22T00:20:00Z';
  const expiresAt = Number.isFinite(Date.parse(envelope && envelope.expires_at))
    && Date.parse(envelope.expires_at) > Date.parse(issuedAt)
    ? envelope.expires_at : '2026-07-22T00:21:00Z';
  return {
    schema: 'testing-effect-authorization-receipt.v1', decision, reason_code: reasonCode,
    receipt_id: `durable-${envelope.effect_kind || 'invalid'}-effect-${envelopeSha256.slice(0, 32)}`,
    envelope_sha256: envelopeSha256, evaluated_input_digests: inputs, issued_at: issuedAt,
    expires_at: expiresAt,
    fence_id: typeof envelope.fence_id === 'string' ? envelope.fence_id : 'invalid-fence',
    trace_id: typeof envelope.trace_id === 'string' ? envelope.trace_id : 'invalid-trace',
    dedup_key: typeof envelope.dedup_key === 'string' ? envelope.dedup_key : 'invalid-dedup',
    auth_tag: sha256(`${runId}\0${envelopeSha256}\0${decision}`),
  };
}

function authorizeEffect(projectRoot, payload, expectedKind) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  const config = loadConfig(projectRoot, runId);
  const envelope = payload.action_envelope || {};
  const empty = {
    profile: '0'.repeat(64), validation_receipt: '0'.repeat(64),
    preauthorization: '0'.repeat(64), environment_receipt: '0'.repeat(64),
    plan: '0'.repeat(64), grant: '0'.repeat(64),
  };
  const deny = (reason, inputs = empty) =>
    structuredAuthorizationReceipt(runId, envelope, 'deny', reason, inputs);
  try {
    if (!validActionEnvelope(envelope, expectedKind)) return deny('malformed-envelope');
    const request = activeStructuredRequest(root, runId);
    if (!envelopeMatchesRequest(envelope, request, payload)) return deny('foreign-binding');
    const profile = artifactRead(projectRoot, envelope.profile_ref, envelope.profile_artifact_sha256);
    const validation = artifactRead(projectRoot, envelope.validation_receipt_ref,
      envelope.validation_receipt_sha256);
    const preauthorization = artifactRead(projectRoot, envelope.preauthorization_ref,
      envelope.preauthorization_sha256);
    const environment = artifactRead(projectRoot, envelope.environment_receipt_ref,
      envelope.environment_receipt_sha256);
    const plan = artifactRead(projectRoot, envelope.plan_ref, envelope.plan_sha256);
    const grant = artifactRead(projectRoot, envelope.grant_ref, envelope.grant_sha256);
    const inputs = {
      profile: profile && profile.digest || empty.profile,
      validation_receipt: validation && validation.digest || empty.validation_receipt,
      preauthorization: preauthorization && preauthorization.digest || empty.preauthorization,
      environment_receipt: environment && environment.digest || empty.environment_receipt,
      plan: plan && plan.digest || empty.plan,
      grant: grant && grant.digest || empty.grant,
    };
    if (!profile || !validation || !preauthorization || !environment || !plan || !grant) {
      return deny('missing-input', inputs);
    }
    const values = [profile.value, validation.value, preauthorization.value,
      environment.value, plan.value, grant.value];
    if (values.some((value) => !value || typeof value !== 'object' || Array.isArray(value))) {
      return deny('malformed-input', inputs);
    }
    const sameRun = (value) => value.trace_id === envelope.trace_id
      && value.dedup_key === envelope.dedup_key;
    const planned = Array.isArray(plan.value.cases)
      ? plan.value.cases.find((item) => item && item.case_id === envelope.case.case_id) : null;
    const expectedEvidence = { kind: 'signed-attestation', ref: `${runId}-execution-grant` };
    const replay = recordRead(root, structuredReplayKey(grant.value.grant_id));
    const replayBinding = replay && replay.binding;
    const now = '2026-07-22T00:20:00Z';
    const schemasValid = profile.value.schema === 'testing-project-profile.v1'
      && validation.value.schema === 'testing-project-profile-validation-receipt.v1'
      && preauthorization.value.schema === 'testing-structured-execution-authorization.v1'
      && environment.value.schema === 'environment-factory.receipt.v2'
      && plan.value.schema === 'testing-structured-plan.v2'
      && grant.value.schema === 'testing-structured-execution-grant.v1';
    if (!schemasValid) return deny('malformed-input', inputs);
    const preauthorizationValid = preauthorization.value.max_uses === 1
      && validWindow(preauthorization.value, now)
      && validCliCapabilities(preauthorization.value.capabilities && preauthorization.value.capabilities.cli)
      && validHttpCapabilities(preauthorization.value.capabilities && preauthorization.value.capabilities.http);
    if (!preauthorizationValid) return deny('stale-preauthorization', inputs);
    const grantValid = grant.value.max_uses === 1 && validWindow(grant.value, now)
      && validCliCapabilities(grant.value.cli_capabilities)
      && validHttpCapabilities(grant.value.http_capabilities);
    if (!grantValid) return deny('stale-grant', inputs);
    if (!sameRun(validation.value) || !sameRun(preauthorization.value) || !sameRun(environment.value)
      || !sameRun(plan.value) || !sameRun(grant.value)) return deny('foreign-binding', inputs);
    const repositoriesValid = sameRepository(profile.value.repository, envelope.repository)
      && sameRepository(validation.value.repository, envelope.repository)
      && sameRepository(preauthorization.value.repository, envelope.repository)
      && sameRepository(environment.value.repository, envelope.repository)
      && sameRepository(plan.value.repository, envelope.repository)
      && sameRepository(grant.value.repository, envelope.repository);
    if (!repositoriesValid) return deny('malformed-input', inputs);
    if (!profile.value.resource_budgets
      || envelope.resource_bounds.output_bytes !== profile.value.resource_budgets.output_bytes) {
      return deny('profile-policy-denied', inputs);
    }
    const artifactBindings = profile.digest === envelope.profile_artifact_sha256
      && sha256(stable(profile.value)) === envelope.profile_sha256
      && validation.digest === envelope.validation_receipt_sha256
      && validation.value.profile_revision === profile.value.revision
      && validation.value.profile_sha256 === envelope.profile_sha256
      && preauthorization.digest === envelope.preauthorization_sha256
      && preauthorization.value.profile_sha256 === envelope.profile_sha256
      && environment.digest === envelope.environment_receipt_sha256
      && environment.value.status === 'ready' && environment.value.operation_id === envelope.operation_id
      && environment.value.profile_sha256 === envelope.profile_sha256
      && samePointer(environment.value.workspace_ref, envelope.workspace_ref)
      && plan.value.environment_receipt_sha256 === environment.digest
      && plan.digest === envelope.plan_sha256 && grant.digest === envelope.grant_sha256
      && grant.value.parent_authorization_sha256 === preauthorization.digest
      && grant.value.plan_sha256 === plan.digest
      && grant.value.environment_receipt_sha256 === environment.digest;
    if (!artifactBindings) return deny('foreign-binding', inputs);
    const authenticated = samePointer(grant.value.authority, preauthorization.value.authority)
      && grant.value.policy_revision === preauthorization.value.policy_revision
      && samePointer(grant.value.evidence_ref, expectedEvidence);
    if (!authenticated) return deny('foreign-binding', inputs);
    const effectAllowed = envelope.effect_kind === 'cli'
      ? argvAllowed(envelope.case.argv, preauthorization.value.capabilities.cli)
        && argvAllowed(envelope.case.argv, grant.value.cli_capabilities)
      : envelope.base_url === environment.value.base_url
        && httpAllowed(envelope.case.request, preauthorization.value.capabilities.http)
        && httpAllowed(envelope.case.request, grant.value.http_capabilities);
    if (stable(planned) !== stable(envelope.case) || !effectAllowed) {
      return deny('scope-denied', inputs);
    }
    const replayOwned = replay && replay.status === 'claimed' && replay.fence_id === envelope.fence_id
      && replayBinding && replayBinding.grant_id === grant.value.grant_id
      && replayBinding.grant_sha256 === grant.digest
      && replayBinding.plan_sha256 === plan.digest
      && replayBinding.environment_receipt_sha256 === environment.digest
      && sameRepository(replayBinding.repository, envelope.repository)
      && replayBinding.operation_id === envelope.operation_id
      && replayBinding.artifact_root === request.artifact_root
      && replayBinding.trace_id === envelope.trace_id && replayBinding.dedup_key === envelope.dedup_key;
    if (!replayOwned) return deny('foreign-fence', inputs);
    const fixturePolicy = config.runtime_pep_denial;
    if (fixturePolicy !== undefined && envelope.effect_kind === 'cli') {
      const token = process.env.FKST_GENERIC_HOST_FIXTURE_CLI_DENY_TOKEN;
      const fixturePolicyValid = exactKeys(fixturePolicy, ['reason_code', 'token'])
        && fixturePolicy.reason_code === 'profile-policy-denied'
        && boundedString(fixturePolicy.token, 256) && token === fixturePolicy.token;
      if (!fixturePolicyValid) return deny('malformed-input', inputs);
      return deny(fixturePolicy.reason_code, inputs);
    }
    const receipt = structuredAuthorizationReceipt(runId, envelope, 'allow', 'authorized', inputs);
    const authorization = { receipt, grant_id: grant.value.grant_id, fence_id: envelope.fence_id };
    const stored = recordImmutable(root, structuredAuthorizationKey(receipt.receipt_id), authorization);
    if (!stored.written && !stored.replayed) fail('durable effect authorization receipt conflict');
    return receipt;
  } catch (_error) {
    return deny('malformed-input');
  }
}

function dispatch(name, payload, projectRoot) {
  switch (name) {
    case 'sha256-bytes':
      return sha256Bytes(payload);
    case 'workflow-load-state': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      if (payload.path !== config.request.state_ref) return null;
      return recordRead(runRoot(runId), `workflow-qa/state/${runId}`);
    }
    case 'workflow-load-run': {
      for (const runId of listIndexedRuns(projectRoot)) {
        const request = requestFor(projectRoot, runId);
        if (request && request.trace_id === payload.trace_id && request.dedup_key === payload.dedup_key) return request;
      }
      return null;
    }
    case 'workflow-load-run-by-id':
      return requestFor(projectRoot, payload.run_id);
    case 'workflow-list-pending-runs':
      return pendingRequests(projectRoot, payload.limit);
    case 'workflow-save-state': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      if (payload.path !== config.request.state_ref) return { saved: false };
      if (payload.value && payload.value.phase === 'structured-execution-pending') {
        crashBarrier(projectRoot, runId, 'workflow-before-state-save', {
          command: 'workflow-save-state', expected_version: payload.expected_version,
          next_version: payload.value.version, next_phase: payload.value.phase,
        });
      }
      const saved = recordCas(runRoot(runId), `workflow-qa/state/${runId}`, payload.value, payload.expected_version);
      if (saved.saved === true && payload.value && payload.value.phase === 'structured-execution-pending') {
        crashBarrier(projectRoot, runId, 'workflow-after-state-save', {
          command: 'workflow-save-state', expected_version: payload.expected_version,
          saved_version: payload.value.version, saved_phase: payload.value.phase,
        });
      }
      return saved;
    }
    case 'artifact-load': {
      if (payload.expected_digest !== undefined && payload.expected_digest !== null
        && !validDigest(payload.expected_digest)) fail('artifact expected digest is invalid');
      if (payload.durable_only !== undefined && typeof payload.durable_only !== 'boolean') {
        fail('artifact durable-only option is invalid');
      }
      return artifactRead(projectRoot, payload.path, payload.expected_digest, {
        durableOnly: payload.durable_only === true,
      });
    }
    case 'artifact-write':
      return artifactWrite(projectRoot, payload.path, payload.value);
    case 'artifact-digest': {
      const artifact = artifactRead(projectRoot, payload.path, undefined, {
        allowGeneratedDigestImport: true,
      });
      return { digest: artifact && artifact.digest || null };
    }
    case 'publication-load-ledger': {
      const runId = runIdFor(payload);
      return recordRead(runRoot(runId), `test-publication/ledgers/${sha256(stable(payload.path))}`);
    }
    case 'publication-save-ledger': {
      const runId = runIdFor(payload);
      return recordCas(runRoot(runId), `test-publication/ledgers/${sha256(stable(payload.path))}`,
        payload.value, payload.expected_version);
    }
    case 'publication-publish-artifact': {
      const result = publicationResult(projectRoot, payload);
      if (payload.stage === 'aggregate-report') {
        crashBarrier(projectRoot, runIdFor(payload), 'publication-after-effect', {
          command: 'publication-publish-artifact', stage: payload.stage,
          attempt: payload.attempt, receipt_ref: result.receipt_ref,
        });
      }
      return result;
    }
    case 'publication-write-report': {
      const written = artifactWrite(projectRoot, payload.path, payload.value);
      return { status: 'written', digest: written.digest };
    }
    case 'host-claim-qa-run-intake': {
      const runId = runIdFor(payload);
      loadConfig(projectRoot, runId);
      const claimed = recordClaim(runRoot(runId), `generic-host/local-qa-intake/${runId}`, {
        binding: payload, claim_id: `${runId}-local-qa-intake`,
      });
      if (!claimed.claimed) return { status: 'blocked' };
      return { status: 'claimed', claim_id: claimed.value.claim_id, replayed: claimed.replayed === true };
    }
    case 'host-claim-preauthorization': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      const root = runRoot(runId);
      const key = `generic-host/preauthorization/${sha256(stable(payload.authorization_id))}`;
      const existing = recordRead(root, key);
      const claimed = existing ? {
        claimed: preauthorizationBindingMatches(existing.binding, payload, trustedPreauthorizationRefs(config)),
        replayed: true,
        value: existing,
      } : recordClaim(root, key, {
        binding: canonicalPreauthorizationBinding(payload),
        claim_id: `private-claim-${crypto.randomBytes(32).toString('hex')}`,
        claimed_at: config.execution_authorization_now,
      });
      if (!claimed.claimed) return { status: 'blocked' };
      writePreauthorizationClaimReceipt(projectRoot, config, payload, claimed.value);
      return { status: 'claimed', claim_id: claimed.value.claim_id, replayed: claimed.replayed === true };
    }
    case 'host-reconcile-preauthorization-claim': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      const preauthorization = boundLineageArtifact(projectRoot, payload.preauthorization_ref,
        payload.preauthorization_sha256, 'preauthorization');
      const request = { ...payload, authorization_id: preauthorization.value.authorization_id };
      const claimed = recordRead(runRoot(runId),
        `generic-host/preauthorization/${sha256(stable(request.authorization_id))}`);
      if (!claimed || !preauthorizationBindingMatches(
        claimed.binding, request, trustedPreauthorizationRefs(config),
      )) {
        return { reconciled: false };
      }
      writePreauthorizationClaimReceipt(projectRoot, config, request, claimed);
      return { reconciled: true };
    }
    case 'host-grant-values': {
      const runId = runIdFor(payload.request || {});
      return hostStructuredGrantValues(loadConfig(projectRoot, runId));
    }
    case 'host-record-terminal': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      inventoryAcceptanceReport(projectRoot, config, payload);
      const stored = recordImmutable(runRoot(runId), `generic-host/terminal/${runId}`, payload);
      return { recorded: stored.written === true || stored.replayed === true };
    }
    case 'load-authorization-bundle': {
      const start = payload.start;
      const runId = runIdFor(start || {});
      const config = loadConfig(projectRoot, runId);
      const expected = config.request.environment_start;
      if (!start || start.operation_id !== runId
        || stable(start.profile_ref) !== stable(expected.profile_ref)
        || stable(start.approval_ref) !== stable(expected.approval_ref)
        || stable(start.validation_receipt_ref) !== stable(expected.validation_receipt_ref)) {
        fail('environment authorization request binding differs');
      }
      return {
        profile: config.profile,
        approval: config.approval,
        receipt: config.validation_receipt,
        context: {
          now: config.authorization_now,
          approval_ref: config.authorization_approval_ref,
          trusted_authorities: [{
            authenticated: true,
            approval_sha256: config.validation_receipt.approval_sha256,
            source_ref: config.approval.authority,
            policy_revision: config.approval.policy_revision,
            evidence_ref: config.approval.evidence_ref,
          }],
        },
      };
    }
    case 'sha256':
      loadConfig(projectRoot, runIdFor(payload));
      if (typeof payload.value !== 'string') fail('sha256 value must be a string');
      return { digest: sha256(payload.value) };
    case 'plan-listener-claim': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      const runtimePorts = exactRuntimePorts(payload.runtime_ports);
      if (!samePorts(runtimePorts, [{ name: 'application', port: config.port }])) {
        fail('listener claim plan binding differs');
      }
      return {
        status: 'planned',
        needs_claim: [],
        already_owned: runtimePorts,
        runtime_owned: true,
      };
    }
    case 'lookup-effect': {
      const runId = runIdFor(payload);
      const root = runRoot(runId);
      loadConfig(projectRoot, runId);
      const existing = recordRead(root, `environment-factory/effects/${sha256(stable(payload.effect_id))}`);
      if (!existing) return { found: false };
      const binding = payload.lookup_binding || {};
      if (!existing.binding || existing.binding.effect_id !== payload.effect_id
        || stable(existing.binding.request_binding) !== stable(binding.request_binding)
        || stable(existing.binding.runtime_ports) !== stable(binding.runtime_ports)) {
        fail('environment authorization effect binding differs');
      }
      return { found: true, outcome: existing.result };
    }
    case 'authorize-claim-ports': {
      const runId = runIdFor(payload);
      const root = runRoot(runId);
      const config = loadConfig(projectRoot, runId);
      const expectedReplayBinding = expectedProfileReplayBinding(config);
      const key = `environment-factory/effects/${sha256(stable(payload.effect_id))}`;
      const existing = recordRead(root, key);
      const binding = payload.lookup_binding || {};
      if (existing) {
        if (!existing.binding || existing.binding.effect_id !== payload.effect_id
          || stable(existing.binding.request_binding) !== stable(binding.request_binding)
          || stable(existing.binding.runtime_ports) !== stable(payload.runtime_ports)
          || stable(existing.result.profile_snapshot) !== stable(payload.profile_snapshot)) {
          fail('environment authorization claim replay differs');
        }
        const profileClaim = recordRead(root, `generic-host/profile-approval/${runId}`);
        if (!profileClaim || stable(profileClaim.binding) !== stable(expectedReplayBinding)
          || typeof profileClaim.claim_id !== 'string') {
          fail('environment authorization approval claim is unavailable');
        }
        writeProfileClaimReceipt(projectRoot, config, profileClaim);
        return { ...existing.result, claim_id: profileClaim.claim_id };
      }
      if (stable(payload.replay_claim) !== stable(expectedReplayBinding)
        || stable(payload.profile_snapshot) !== stable(config.profile)) {
        fail('environment authorization claim replay differs');
      }
      const approvalClaim = recordClaim(root, `generic-host/profile-approval/${runId}`, {
        binding: payload.replay_claim,
        claim_id: `private-claim-${crypto.randomBytes(32).toString('hex')}`,
        claimed_at: config.authorization_now,
      });
      if (!approvalClaim.claimed || !approvalClaim.value
        || typeof approvalClaim.value.claim_id !== 'string') {
        fail('environment authorization approval claim was not acquired');
      }
      writeProfileClaimReceipt(projectRoot, config, approvalClaim.value);
      const runtimePorts = exactRuntimePorts(payload.runtime_ports);
      if (!Array.isArray(payload.listener_claimed_ports) || payload.listener_claimed_ports.length !== 0
        || !samePorts(exactRuntimePorts(payload.listener_already_owned_ports), runtimePorts)) {
        fail('environment authorization listener ownership differs');
      }
      const cleanupRef = { kind: 'port-lease', ref: `${runId}-ports` };
      const resource = recordImmutable(root, environmentResourceKey(cleanupRef), {
        schema: 'generic-host.environment-resource.v1', kind: 'ports', operation_id: runId,
        cleanup_ref: cleanupRef, runtime_ports: runtimePorts,
        ownership_token: sha256(`${runId}\0ports\0${payload.effect_id}`),
      });
      if (!resource.written && !resource.replayed) fail('port resource binding differs');
      const result = {
        status: 'passed', profile_snapshot: payload.profile_snapshot, cleanup_ref: cleanupRef,
        runtime_ports: runtimePorts, deadline_epoch_seconds: 1784685600,
        request_binding: binding.request_binding,
      };
      const stored = recordImmutable(root, key, { binding: {
        effect_id: payload.effect_id, request_binding: binding.request_binding, runtime_ports: runtimePorts,
      }, result });
      if (!stored.written && !stored.replayed) fail('environment authorization effect commit conflict');
      return { ...result, claim_id: approvalClaim.value.claim_id };
    }
    case 'remaining-budget':
      loadConfig(projectRoot, runIdFor(payload));
      return { remaining_seconds: 120 };
    case 'checkout': {
      const runId = runIdFor(payload);
      const root = runRoot(runId);
      const config = loadConfig(projectRoot, runId);
      return environmentEffect(projectRoot, payload, () => {
        if (payload.operation_id !== runId || stable(payload.repository) !== stable(config.profile.repository)
          || payload.working_directory !== config.profile.working_directory) {
          fail('environment checkout binding differs');
        }
        const workspaceRoot = path.resolve(config.workspace_root);
        const tempRoot = path.resolve(config.temp_root);
        if (workspaceRoot === tempRoot || !workspaceRoot.startsWith(`${tempRoot}${path.sep}`)) {
          fail('environment checkout workspace escaped the durable temp root');
        }
        fs.rmSync(config.workspace_root, { recursive: true, force: true });
        const cloned = directExec(['git', 'clone', '--quiet', config.source_root, config.workspace_root], config.temp_root,
          payload.timeout_seconds);
        if (cloned.exit_code !== 0) fail('environment checkout clone failed');
        const checkedOut = directExec(['git', 'checkout', '--quiet', config.commit_sha], config.workspace_root,
          payload.timeout_seconds);
        if (checkedOut.exit_code !== 0) fail('environment checkout revision failed');
        const resolved = directExec(['git', 'rev-parse', 'HEAD'], config.workspace_root, payload.timeout_seconds);
        const commit = String(resolved.stdout || '').trim();
        if (resolved.exit_code !== 0 || commit !== config.commit_sha) fail('environment checkout resolved commit differs');
        const workspaceRef = { kind: 'workspace', ref: `${runId}-workspace` };
        const cleanupRef = { kind: 'workspace-cleanup', ref: `${runId}-workspace` };
        registerWorkspace(projectRoot, {
          run_id: runId, operation_id: runId, workspace_ref: workspaceRef, cleanup_ref: cleanupRef,
          path: config.workspace_root, repository: config.repository,
        });
        return { status: 'passed', resolved_commit: commit, workspace_ref: workspaceRef, cleanup_ref: cleanupRef };
      });
    }
    case 'load-state': {
      const runId = runIdFor(payload);
      loadConfig(projectRoot, runId);
      const value = recordRead(runRoot(runId), environmentStateKey(payload.ref));
      if (!value) return null;
      return { authenticated: true, state: value.state, revision: value.version };
    }
    case 'save-state': {
      const runId = runIdFor(payload);
      loadConfig(projectRoot, runId);
      const saved = recordCas(runRoot(runId), environmentStateKey(payload.ref), {
        version: payload.expected_revision + 1,
        state: payload.state,
      }, payload.expected_revision);
      return { saved: saved.saved === true, stale: saved.stale === true, revision: saved.version };
    }
    case 'create-readiness-attempt':
      return environmentEffect(projectRoot, payload, (runId) => {
        const attemptRef = `${payload.artifact_root}/readiness-attempts/attempt-1.json`;
        const written = artifactWrite(projectRoot, attemptRef, {
          schema: 'canonical-qa.readiness-attempt.v1', operation_id: payload.operation_id,
          base_url: payload.base_url, sessions: payload.sessions,
          trace_id: payload.trace_id, dedup_key: payload.dedup_key,
        });
        return {
          status: 'passed', attempt_id: 'attempt-1', attempt_ref: { kind: 'artifact', ref: attemptRef },
          attempt_sha256: written.digest,
        };
      });
    case 'run-argv':
      return environmentEffect(projectRoot, payload, (runId, root) => {
        const workspace = workspaceResource(root, payload.workspace_ref);
        if (payload.mode === 'supervised') {
          return startApplication(projectRoot, {
            ...payload, run_id: runId,
            cleanup_ref: { kind: 'process-cleanup', ref: `${runId}-application` },
          });
        }
        const executed = directExec(payload.argv, workspace.path, payload.timeout_seconds);
        const result = { status: executed.exit_code === 0 ? 'passed' : 'blocked' };
        if (payload.requires_frozen_dependencies) result.frozen_dependencies_enforced = true;
        return result;
      });
    case 'wait-readiness':
      return environmentEffect(projectRoot, payload, (_runId, root) => {
        for (const check of payload.checks || []) {
          if (check.type === 'http') {
            if (!waitForHttp(check.url, payload.timeout_seconds)) return { status: 'blocked' };
          } else if (check.type === 'argv') {
            const workspace = workspaceResource(root, payload.workspace_ref);
            if (directExec(check.argv, workspace.path, payload.timeout_seconds).exit_code !== 0) {
              return { status: 'blocked' };
            }
          } else {
            return { status: 'blocked' };
          }
        }
        return { status: 'ready' };
      });
    case 'cleanup': {
      const result = environmentEffect(projectRoot, payload, () => cleanupResource(projectRoot, payload));
      if (payload.cleanup_ref && payload.cleanup_ref.kind === 'port-lease') {
        crashBarrier(projectRoot, runIdFor(payload), 'cleanup-after-effect', {
          command: 'cleanup', effect_id: payload.effect_id,
          cleanup_ref: payload.cleanup_ref, status: result.status,
        });
      }
      return result;
    }
    case 'write-receipt':
      return environmentEffect(projectRoot, payload, () => {
        const written = artifactWrite(projectRoot, payload.receipt_ref.ref, payload.receipt);
        return { status: written.written ? 'passed' : 'blocked' };
      });
    case 'load-artifact':
      return artifactRead(projectRoot, payload.artifact_ref.ref);
    case 'write-artifact':
      return artifactWrite(projectRoot, payload.artifact_ref.ref, payload.value);
    case 'now':
      loadConfig(projectRoot, runIdFor(payload));
      return { now: '2026-07-22T00:20:00Z' };
    case 'verify-grant': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      writeGrantVerificationReceipt(projectRoot, config, payload);
      return {
        grant_sha256: payload.grant_sha256,
        authority: payload.grant.authority,
        policy_revision: payload.grant.policy_revision,
        evidence_ref: payload.grant.evidence_ref,
      };
    }
    case 'replay-guard': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      const claimId = `private-claim-${crypto.randomBytes(32).toString('hex')}`;
      const fenceId = claimFingerprint(config, 'structured-execution-fence', claimId);
      const claimed = recordClaim(runRoot(runId), structuredReplayKey(payload.grant_id), {
        status: 'claimed', claim_id: claimId, fence_id: fenceId, binding: payload,
        claimed_at: config.execution_authorization_now,
      });
      if (!claimed.claimed) return null;
      writeExecutionClaimReceipt(projectRoot, config, payload, claimed.value);
      if (claimed.value.status === 'completed') {
        writeExecutionCompletionReceipt(projectRoot, config, claimed.value);
        return { status: 'completed', result_ref: claimed.value.result_ref,
          result_sha256: claimed.value.result_sha256 };
      }
      if (claimed.replayed) return { status: 'in-progress' };
      return { status: 'claimed', claim_id: fenceId };
    }
    case 'authorize-cli-effect':
      return authorizeEffect(projectRoot, payload, 'cli');
    case 'authorize-http-effect':
      return authorizeEffect(projectRoot, payload, 'http');
    case 'exec-argv': {
      const runId = runIdFor(payload);
      const root = runRoot(runId);
      const config = loadConfig(projectRoot, runId);
      const envelope = payload.action_envelope;
      const receipt = payload.authorization_receipt;
      const request = activeStructuredRequest(root, runId);
      const validReceipt = validActionEnvelope(envelope, 'cli') && envelopeMatchesRequest(envelope, request, payload)
        && exactKeys(receipt, [
          'schema', 'decision', 'reason_code', 'receipt_id', 'envelope_sha256',
          'evaluated_input_digests', 'issued_at', 'expires_at', 'fence_id', 'trace_id',
          'dedup_key', 'auth_tag',
        ])
        && exactKeys(receipt.evaluated_input_digests, [
          'profile', 'validation_receipt', 'preauthorization', 'environment_receipt', 'plan', 'grant',
        ])
        && Object.values(receipt.evaluated_input_digests).every(validDigest)
        && receipt.schema === 'testing-effect-authorization-receipt.v1'
        && receipt.decision === 'allow' && receipt.reason_code === 'authorized'
        && receipt.envelope_sha256 === sha256(stable(envelope))
        && receipt.auth_tag === sha256(`${runId}\0${receipt.envelope_sha256}\0allow`)
        && receipt.fence_id === envelope.fence_id && receipt.trace_id === envelope.trace_id
        && receipt.dedup_key === envelope.dedup_key && receipt.expires_at === envelope.expires_at
        && receipt.issued_at === '2026-07-22T00:20:00Z'
        && Date.parse(receipt.expires_at) > Date.parse('2026-07-22T00:20:00Z');
      const authorization = validReceipt
        ? recordRead(root, structuredAuthorizationKey(receipt.receipt_id)) : null;
      const grant = validReceipt
        ? artifactRead(projectRoot, envelope.grant_ref, envelope.grant_sha256) : null;
      const replay = grant && grant.value
        ? recordRead(root, structuredReplayKey(grant.value.grant_id)) : null;
      if (!validReceipt || !authorization || !grant || !grant.value || typeof grant.value !== 'object'
        || stable(authorization.receipt) !== stable(receipt)
        || authorization.grant_id !== grant.value.grant_id || authorization.fence_id !== envelope.fence_id
        || grant.digest !== envelope.grant_sha256 || !replay || replay.status !== 'claimed'
        || replay.fence_id !== envelope.fence_id) {
        fail('durable structured CLI authorization receipt is unavailable');
      }
      if (envelope.operation_id !== runId || envelope.workspace_ref.ref !== `${runId}-workspace`
        || envelope.repository.commit_sha !== config.commit_sha) fail('structured CLI request binding differs');
      const workspace = workspaceResource(root, envelope.workspace_ref);
      const ownership = verifyWorkspace(config, workspace);
      if (ownership.owned !== true) fail(`structured workspace is not owned: ${ownership.reason}`);
      const consumed = recordClaim(root, structuredConsumptionKey(receipt.receipt_id), {
        binding: receipt, receipt_id: receipt.receipt_id, grant_id: grant.value.grant_id,
      });
      if (!consumed.claimed || consumed.replayed) fail('durable structured CLI authorization receipt is replayed');
      artifactWrite(projectRoot, `${payload.artifact_root}/authorization/${envelope.case.case_id}-consumption.json`, {
        schema: 'generic-host.cli-effect-consumption.v1', case_id: envelope.case.case_id,
        receipt_id: receipt.receipt_id, grant_id: grant.value.grant_id,
        consumption_fingerprint_sha256: claimFingerprint(
          config, 'structured-execution-consumption', envelope.fence_id,
        ),
      });
      const result = directExec(envelope.case.argv, workspace.path, envelope.case.timeout_seconds,
        envelope.resource_bounds.output_bytes);
      const sequence = structuredCaseSequence(projectRoot, request, envelope.case.case_id);
      const stored = recordImmutable(root, `testing-runner/target-effects/${sha256(stable(payload))}`, {
        sequence, binding: payload, result,
      });
      if (!stored.written && !stored.replayed) fail('structured CLI target effect conflict');
      return result;
    }
    case 'http-request': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      const request = activeStructuredRequest(runRoot(runId), runId);
      const envelope = payload.action_envelope;
      const receipt = payload.authorization_receipt;
      const validReceipt = validActionEnvelope(envelope, 'http')
        && envelopeMatchesRequest(envelope, request, payload)
        && exactKeys(receipt, [
          'schema', 'decision', 'reason_code', 'receipt_id', 'envelope_sha256',
          'evaluated_input_digests', 'issued_at', 'expires_at', 'fence_id', 'trace_id',
          'dedup_key', 'auth_tag',
        ])
        && exactKeys(receipt.evaluated_input_digests, [
          'profile', 'validation_receipt', 'preauthorization', 'environment_receipt', 'plan', 'grant',
        ])
        && Object.values(receipt.evaluated_input_digests).every(validDigest)
        && receipt.schema === 'testing-effect-authorization-receipt.v1'
        && receipt.decision === 'allow' && receipt.reason_code === 'authorized'
        && receipt.envelope_sha256 === sha256(stable(envelope))
        && receipt.auth_tag === sha256(`${runId}\0${receipt.envelope_sha256}\0allow`)
        && receipt.fence_id === envelope.fence_id && receipt.trace_id === envelope.trace_id
        && receipt.dedup_key === envelope.dedup_key && receipt.expires_at === envelope.expires_at
        && receipt.issued_at === '2026-07-22T00:20:00Z'
        && Date.parse(receipt.expires_at) > Date.parse('2026-07-22T00:20:00Z');
      const authorization = validReceipt
        ? recordRead(runRoot(runId), structuredAuthorizationKey(receipt.receipt_id)) : null;
      const grant = validReceipt
        ? artifactRead(projectRoot, envelope.grant_ref, envelope.grant_sha256) : null;
      const replay = grant && grant.value
        ? recordRead(runRoot(runId), structuredReplayKey(grant.value.grant_id)) : null;
      if (!validReceipt || !authorization || !grant || !grant.value || typeof grant.value !== 'object'
        || stable(authorization.receipt) !== stable(receipt)
        || authorization.grant_id !== grant.value.grant_id || authorization.fence_id !== envelope.fence_id
        || grant.digest !== envelope.grant_sha256 || !replay || replay.status !== 'claimed'
        || replay.fence_id !== envelope.fence_id) {
        fail('durable structured HTTP authorization receipt is unavailable');
      }
      if (envelope.operation_id !== runId || envelope.base_url !== config.base_url
        || envelope.case.request.url !== config.base_url) fail('structured HTTP request binding differs');
      const consumed = recordClaim(runRoot(runId), structuredConsumptionKey(receipt.receipt_id), {
        binding: receipt, receipt_id: receipt.receipt_id, grant_id: grant.value.grant_id,
      });
      if (!consumed.claimed || consumed.replayed) fail('durable structured HTTP authorization receipt is replayed');
      artifactWrite(projectRoot, `${payload.artifact_root}/authorization/${envelope.case.case_id}-consumption.json`, {
        schema: 'generic-host.http-effect-consumption.v1', case_id: envelope.case.case_id,
        receipt_id: receipt.receipt_id, grant_id: grant.value.grant_id,
        consumption_fingerprint_sha256: claimFingerprint(
          config, 'structured-execution-consumption', envelope.fence_id,
        ),
      });
      const result = localHttpRequest(envelope.case.request, envelope.case.timeout_seconds);
      const sequence = structuredCaseSequence(projectRoot, request, envelope.case.case_id);
      const stored = recordImmutable(runRoot(runId), `testing-runner/target-effects/${sha256(stable(payload))}`, {
        sequence, binding: payload, result,
      });
      if (!stored.written && !stored.replayed) fail('structured HTTP target effect conflict');
      return result;
    }
    case 'load-result': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      if (!validDigest(payload.result_sha256)) fail('completed execution result digest is required');
      const artifacts = structuredExecutionArtifacts(projectRoot, payload.result_ref,
        payload.result_sha256);
      if (artifacts.execution.digest !== payload.result_sha256) {
        fail('completed execution result digest differs');
      }
      const value = artifacts.execution.value;
      const durableClaim = durableExecutionClaim(config);
      assertExecutionMatchesClaim(value, durableClaim.binding);
      if (payload.result_ref !== `${payload.artifact_root}/execution.json`
        || value.operation_id !== payload.operation_id
        || value.environment_receipt_sha256 !== payload.environment_receipt_sha256
        || !sameRepository(value.repository, payload.repository)
        || value.trace_id !== payload.trace_id || value.dedup_key !== payload.dedup_key) return null;
      const recovered = recordImmutable(runRoot(runId), 'generic-host/recovery/execution', {
        schema: 'generic-host.completed-execution-recovery.v1', run_id: runId,
        result_ref: payload.result_ref, result_sha256: artifacts.execution.digest, replayed: true,
      });
      if (!recovered.written && !recovered.replayed) fail('execution recovery witness differs');
      const result = {
        schema: 'testing-runner.structured-execution-summary.v1', status: value.status,
        classification: value.classification, mode: 'structured-api-cli',
        artifact_root: config.request.structured_execution.artifact_root,
        case_count: value.case_count, passed_count: value.passed_count, failed_count: value.failed_count,
        skipped_count: value.skipped_count, error_count: value.error_count,
        test_plan_path: value.test_plan_path,
        execution_path: value.execution_path, replayed: true,
      };
      if (artifacts.caseResults) result.case_results_path = value.case_results_path;
      if (artifacts.caseResultSet) {
        result.case_result_set_path = value.case_result_set_path;
        result.case_result_set_artifact_sha256 = value.case_result_set_artifact_sha256;
        result.evidence_manifest_path = value.evidence_manifest_path;
        result.evidence_manifest_artifact_sha256 = value.evidence_manifest_artifact_sha256;
      }
      return result;
    }
    case 'complete-replay': {
      const runId = runIdFor(payload);
      const root = runRoot(runId);
      loadConfig(projectRoot, runId);
      let current = null;
      for (const entry of recordList(root, 'testing-runner/replay')) {
        if (entry.value && payload.claim && entry.value.fence_id === payload.claim.claim_id) {
          current = entry;
          break;
        }
      }
      if (!current || current.value.status !== 'claimed') return { completed: false };
      const binding = current.value.binding;
      if (binding.artifact_root !== payload.artifact_root || binding.operation_id !== payload.operation_id
        || binding.environment_receipt_sha256 !== payload.environment_receipt_sha256
        || stable(binding.repository) !== stable(payload.repository)
        || binding.trace_id !== payload.trace_id || binding.dedup_key !== payload.dedup_key) {
        return { completed: false };
      }
      const artifacts = structuredExecutionArtifacts(projectRoot, payload.result_ref);
      const execution = artifacts.execution.value;
      assertExecutionMatchesClaim(execution, binding);
      if (payload.result_ref !== `${binding.artifact_root}/execution.json`
        || execution.operation_id !== binding.operation_id
        || execution.environment_receipt_sha256 !== binding.environment_receipt_sha256
        || !sameRepository(execution.repository, binding.repository)
        || execution.trace_id !== binding.trace_id || execution.dedup_key !== binding.dedup_key) {
        return { completed: false };
      }
      const config = loadConfig(projectRoot, runId);
      const completion = { ...payload, result_sha256: artifacts.execution.digest,
        completed_at: config.execution_authorization_now };
      delete completion.claim;
      const completed = storeExecute({ root, operation: 'replay-complete', key: current.key,
        claim_id: current.value.claim_id, completion });
      if (!completed.completed) return completed;
      const verified = structuredExecutionArtifacts(projectRoot, payload.result_ref,
        artifacts.execution.digest);
      const canonicalChanged = Boolean(verified.caseResultSet) !== Boolean(artifacts.caseResultSet)
        || (artifacts.caseResultSet && (verified.caseResultSet.digest !== artifacts.caseResultSet.digest
          || verified.evidenceManifest.digest !== artifacts.evidenceManifest.digest));
      const compatibilityChanged = Boolean(verified.caseResults) !== Boolean(artifacts.caseResults)
        || (artifacts.caseResults && verified.caseResults.digest !== artifacts.caseResults.digest);
      if (verified.execution.digest !== artifacts.execution.digest
        || verified.testPlan.digest !== artifacts.testPlan.digest
        || compatibilityChanged || canonicalChanged
        || completed.value.result_sha256 !== artifacts.execution.digest) {
        fail('completed replay result artifact is unavailable or changed');
      }
      writeExecutionCompletionReceipt(projectRoot, config, completed.value);
      const arm = config.completed_replay_failpoint;
      if (completed.replayed !== true && arm && arm.name === 'post-completed-replay'
        && typeof arm.token === 'string'
        && process.env.FKST_DURABLE_COMPLETED_REPLAY_FAILPOINT === arm.token) {
        const barrier = {
          schema: 'generic-host.completed-replay-barrier.v1', run_id: runId,
          failpoint: arm.name, arm_token_sha256: sha256(arm.token),
          result_ref: payload.result_ref, result_sha256: artifacts.execution.digest,
          test_plan_ref: artifacts.execution.value.test_plan_path,
          test_plan_sha256: artifacts.testPlan.digest,
          replay_status: completed.value.status,
        };
        if (artifacts.caseResults) {
          barrier.case_results_ref = artifacts.execution.value.case_results_path;
          barrier.case_results_sha256 = artifacts.caseResults.digest;
        }
        if (artifacts.caseResultSet) {
          barrier.case_result_set_ref = artifacts.execution.value.case_result_set_path;
          barrier.case_result_set_artifact_sha256 = artifacts.caseResultSet.digest;
          barrier.evidence_manifest_ref = artifacts.execution.value.evidence_manifest_path;
          barrier.evidence_manifest_artifact_sha256 = artifacts.evidenceManifest.digest;
        }
        const witness = recordImmutable(root, 'generic-host/barriers/post-replay-complete', barrier);
        if (!witness.written && !witness.replayed) fail('completed replay barrier witness differs');
        while (true) sleep(1000);
      }
      return completed;
    }
    case 'fixture-register-workspace':
      return registerWorkspace(projectRoot, payload);
    case 'fixture-start-application':
      return startApplication(projectRoot, payload);
    case 'fixture-resource-status':
      return inspectResources(projectRoot, payload);
    case 'fixture-release-status':
      return releasedResources(projectRoot, payload);
    default:
      fail(`unknown effect ${name}`);
  }
}

function parseArgs(argv) {
  if (argv[2] !== 'effect') fail('effect command is required');
  const values = {};
  for (let index = 3; index < argv.length; index += 2) {
    const key = argv[index];
    if (!['--name', '--request', '--response'].includes(key) || index + 1 >= argv.length) fail('invalid arguments');
    values[key.slice(2)] = argv[index + 1];
  }
  if (!values.name || !values.request || !values.response) fail('name, request, and response are required');
  return values;
}

function writeResponse(target, value) {
  atomicWrite(path.resolve(target), `${stable(value)}\n`);
}

function main() {
  const args = parseArgs(process.argv);
  let requestId = null;
  try {
    const transport = JSON.parse(fs.readFileSync(args.request, 'utf8'));
    requestId = transport && transport.request_id;
    if (typeof requestId !== 'string' || requestId === '' || requestId.length > 512) {
      fail('request_id is invalid');
    }
    const payload = { ...transport };
    delete payload.request_id;
    const config = readRuntimeConfig(payload);
    const projectRoot = path.resolve(config.project_root);
    const result = dispatch(args.name, payload, projectRoot);
    writeResponse(args.response, result === null
      ? { ok: true, request_id: requestId }
      : { ok: true, request_id: requestId, result });
  } catch (error) {
    writeResponse(args.response, {
      ok: false,
      request_id: requestId,
      error: String(error && error.message || error),
    });
    process.exitCode = 1;
  }
}

if (require.main === module) main();

module.exports = {
  assertStructuredGrantDerivation,
  assertExecutionMatchesClaim,
  childProcessEnvironment,
  hostStructuredGrantValues,
  materializeImmutableNoReplace,
  preauthorizationBindingMatches,
  releaseOwnedProcessResource,
  trustedPreauthorizationRefs,
  verifyMaterializedImmutable,
};
