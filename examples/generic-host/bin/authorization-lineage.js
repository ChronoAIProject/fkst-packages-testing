'use strict';

const crypto = require('node:crypto');
const { stable } = require('./durable-host-store');

const schemas = Object.freeze({
  profile_claim: 'testing-project-profile-approval-claim-receipt.v1',
  preauthorization_claim: 'testing-structured-preauthorization-claim-receipt.v1',
  grant_verification: 'testing-structured-execution-grant-verification-receipt.v1',
  execution_claim: 'testing-structured-execution-claim-receipt.v1',
  execution_completion: 'testing-structured-execution-completion-receipt.v1',
  lineage_index: 'testing-execution-authorization-lineage-index.v1',
});

const paths = Object.freeze({
  profile_claim: 'authorization-lineage/profile-approval-claim.json',
  preauthorization_claim: 'authorization-lineage/preauthorization-claim.json',
  grant_verification: 'authorization-lineage/grant-verification.json',
  execution_claim: 'authorization-lineage/execution-claim.json',
  execution_completion: 'authorization-lineage/execution-completion.json',
});

const receiptNames = Object.freeze(Object.keys(paths));
const commonFields = [
  'schema', 'status', 'receipt_id', 'repository', 'run_id', 'trace_id', 'dedup_key',
  'recorded_at', 'source_max_uses', 'evidence_role', 'human_approval_required',
  'authorization_capability', 'reusable',
  'execution_authorized', 'promotion_authorized',
];

const definitions = Object.freeze({
  profile_claim: {
    status: 'claimed', event: 'claimed_at',
    fields: [
      'profile_source_ref', 'profile_artifact_ref', 'profile_artifact_sha256', 'profile_sha256',
      'profile_revision', 'approval_artifact_ref', 'approval_artifact_sha256', 'approval_id',
      'approval_sha256', 'approval_authority', 'policy_revision', 'evidence_ref',
      'validation_receipt_ref', 'validation_receipt_sha256', 'claim_fingerprint_sha256', 'claimed_at',
    ],
    sources: [
      'repository', 'run_id', 'trace_id', 'dedup_key', 'profile_source_ref',
      'profile_artifact_ref', 'profile_artifact_sha256', 'profile_sha256', 'profile_revision',
      'approval_artifact_ref', 'approval_artifact_sha256', 'approval_id', 'approval_sha256',
      'approval_authority', 'policy_revision', 'evidence_ref', 'validation_receipt_ref',
      'validation_receipt_sha256', 'claim_fingerprint_sha256', 'claimed_at',
    ],
    pointers: ['profile_artifact_ref', 'approval_artifact_ref', 'validation_receipt_ref'],
    digests: [
      'profile_artifact_sha256', 'profile_sha256', 'approval_artifact_sha256',
      'approval_sha256', 'validation_receipt_sha256', 'claim_fingerprint_sha256',
    ],
  },
  preauthorization_claim: {
    status: 'claimed', event: 'claimed_at',
    fields: [
      'profile_claim_receipt_ref', 'profile_claim_receipt_sha256', 'preauthorization_ref',
      'preauthorization_sha256', 'authorization_id', 'profile_sha256', 'case_catalog_ref',
      'case_catalog_sha256', 'plan_ref', 'plan_sha256', 'environment_receipt_ref',
      'environment_receipt_sha256', 'authority', 'policy_revision', 'evidence_ref',
      'claim_fingerprint_sha256', 'claimed_at',
    ],
    sources: [
      'repository', 'run_id', 'trace_id', 'dedup_key', 'profile_claim_receipt_ref',
      'profile_claim_receipt_sha256', 'preauthorization_ref', 'preauthorization_sha256',
      'authorization_id', 'profile_sha256', 'case_catalog_ref', 'case_catalog_sha256',
      'plan_ref', 'plan_sha256', 'environment_receipt_ref', 'environment_receipt_sha256',
      'authority', 'policy_revision', 'evidence_ref', 'claim_fingerprint_sha256', 'claimed_at',
    ],
    pointers: [
      'profile_claim_receipt_ref', 'preauthorization_ref', 'case_catalog_ref', 'plan_ref',
      'environment_receipt_ref',
    ],
    digests: [
      'profile_claim_receipt_sha256', 'preauthorization_sha256', 'profile_sha256',
      'case_catalog_sha256', 'plan_sha256', 'environment_receipt_sha256',
      'claim_fingerprint_sha256',
    ],
  },
  grant_verification: {
    status: 'authenticated', event: 'verified_at',
    fields: [
      'preauthorization_claim_receipt_ref', 'preauthorization_claim_receipt_sha256',
      'grant_ref', 'grant_sha256', 'grant_id', 'parent_authorization_ref',
      'parent_authorization_sha256', 'plan_ref', 'plan_sha256', 'environment_receipt_ref',
      'environment_receipt_sha256', 'authority', 'policy_revision', 'evidence_ref',
      'verifier_ref', 'verification_id', 'verified_at',
    ],
    sources: [
      'repository', 'run_id', 'trace_id', 'dedup_key', 'preauthorization_claim_receipt_ref',
      'preauthorization_claim_receipt_sha256', 'grant_ref', 'grant_sha256', 'grant_id',
      'parent_authorization_ref', 'parent_authorization_sha256', 'plan_ref', 'plan_sha256',
      'environment_receipt_ref', 'environment_receipt_sha256', 'authority', 'policy_revision',
      'evidence_ref', 'verifier_ref', 'verification_id', 'verified_at',
    ],
    pointers: [
      'preauthorization_claim_receipt_ref', 'grant_ref', 'parent_authorization_ref',
      'plan_ref', 'environment_receipt_ref',
    ],
    digests: [
      'preauthorization_claim_receipt_sha256', 'grant_sha256', 'parent_authorization_sha256',
      'plan_sha256', 'environment_receipt_sha256',
    ],
  },
  execution_claim: {
    status: 'claimed', event: 'claimed_at',
    fields: [
      'grant_verification_receipt_ref', 'grant_verification_receipt_sha256',
      'preauthorization_claim_receipt_ref', 'preauthorization_claim_receipt_sha256',
      'grant_ref', 'grant_sha256', 'grant_id', 'plan_ref', 'plan_sha256',
      'environment_receipt_ref', 'environment_receipt_sha256', 'artifact_root',
      'operation_id', 'claim_fingerprint_sha256', 'claimed_at',
    ],
    sources: [
      'repository', 'run_id', 'trace_id', 'dedup_key', 'grant_verification_receipt_ref',
      'grant_verification_receipt_sha256', 'preauthorization_claim_receipt_ref',
      'preauthorization_claim_receipt_sha256', 'grant_ref', 'grant_sha256', 'grant_id',
      'plan_ref', 'plan_sha256', 'environment_receipt_ref', 'environment_receipt_sha256',
      'artifact_root', 'operation_id', 'claim_fingerprint_sha256', 'claimed_at',
    ],
    pointers: [
      'grant_verification_receipt_ref', 'preauthorization_claim_receipt_ref', 'grant_ref',
      'plan_ref', 'environment_receipt_ref', 'artifact_root',
    ],
    digests: [
      'grant_verification_receipt_sha256', 'preauthorization_claim_receipt_sha256',
      'grant_sha256', 'plan_sha256', 'environment_receipt_sha256', 'claim_fingerprint_sha256',
    ],
  },
  execution_completion: {
    status: 'completed', event: 'completed_at',
    fields: [
      'execution_claim_receipt_ref', 'execution_claim_receipt_sha256', 'result_ref',
      'result_sha256', 'case_result_set_ref', 'case_result_set_artifact_sha256',
      'evidence_manifest_ref', 'evidence_manifest_artifact_sha256', 'completed_at',
    ],
    sources: [
      'repository', 'run_id', 'trace_id', 'dedup_key', 'execution_claim_receipt_ref',
      'execution_claim_receipt_sha256', 'result_ref', 'result_sha256', 'case_result_set_ref',
      'case_result_set_artifact_sha256', 'evidence_manifest_ref',
      'evidence_manifest_artifact_sha256', 'completed_at',
    ],
    pointers: [
      'execution_claim_receipt_ref', 'result_ref', 'case_result_set_ref', 'evidence_manifest_ref',
    ],
    digests: [
      'execution_claim_receipt_sha256', 'result_sha256', 'case_result_set_artifact_sha256',
      'evidence_manifest_artifact_sha256',
    ],
  },
});

function fail(message) {
  throw new Error(`authorization-lineage contract: ${message}`);
}

function object(value, field) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${field} must be an object`);
  return value;
}

function exactKeys(value, keys, field) {
  object(value, field);
  const expected = [...keys].sort();
  const actual = Object.keys(value).sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    fail(`${field} fields are not closed`);
  }
}

function bounded(value, field, limit = 1024) {
  if (typeof value !== 'string' || value === '' || Buffer.byteLength(value, 'utf8') > limit
    || /[\u0000-\u001f\u007f]/.test(value)) {
    fail(`${field} must be a bounded string`);
  }
}

function identity(value, field) {
  bounded(value, field, 180);
  if (/\s/.test(value)) fail(`${field} must not contain whitespace`);
}

function digest(value, field) {
  if (typeof value !== 'string' || !/^[0-9a-f]{64}$/.test(value)) fail(`${field} must be a SHA-256`);
}

function timestamp(value, field) {
  const match = typeof value === 'string'
    ? /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/.exec(value) : null;
  if (!match) fail(`${field} must be a UTC timestamp`);
  const [year, month, day, hour, minute, second] = match.slice(1).map(Number);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month < 1 || month > 12 || day < 1 || day > daysInMonth[month - 1]
    || hour > 23 || minute > 59 || second > 59) fail(`${field} must be a UTC timestamp`);
  let adjustedYear = year;
  let adjustedMonth = month;
  if (adjustedMonth <= 2) {
    adjustedYear -= 1;
    adjustedMonth += 12;
  }
  const era = Math.floor(adjustedYear / 400);
  const yearOfEra = adjustedYear - era * 400;
  const dayOfYear = Math.floor((153 * (adjustedMonth - 3) + 2) / 5) + day - 1;
  const dayOfEra = yearOfEra * 365 + Math.floor(yearOfEra / 4)
    - Math.floor(yearOfEra / 100) + dayOfYear;
  const daysSinceEpoch = era * 146097 + dayOfEra - 719468;
  return (daysSinceEpoch * 86400 + hour * 3600 + minute * 60 + second) * 1000;
}

function repository(value, field) {
  exactKeys(value, ['url', 'commit_sha'], field);
  bounded(value.url, `${field}.url`, 2048);
  if (!/^https:\/\/[^\s@/?#]+\/[^\s?#]+$/.test(value.url) || value.url.endsWith('/') || value.url.includes('\\')) {
    fail(`${field}.url must be a canonical credential-free HTTPS URL`);
  }
  if (!/^[0-9a-f]{40}$/.test(value.commit_sha)) fail(`${field}.commit_sha must be immutable`);
}

function sourceRef(value, field, kind) {
  exactKeys(value, ['kind', 'ref'], field);
  identity(value.kind, `${field}.kind`);
  bounded(value.ref, `${field}.ref`, 4096);
  if (value.kind !== kind || !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(value.ref)
    || value.ref.includes('//') || value.ref.endsWith('/')
    || value.ref.split('/').some((segment) => segment === '.' || segment === '..')) {
    fail(`${field} must be a closed Host identity reference`);
  }
}

function artifactPointer(value, field) {
  bounded(value, field, 4096);
  if (!/^\.testing\/runs\/[A-Za-z0-9._-]+\/.+$/.test(value) || value.includes('\\')
    || value.includes('//') || /\s/.test(value) || value.includes('?') || value.includes('#')
    || value.split('/').some((segment) => segment === '.' || segment === '..')) {
    fail(`${field} must be a run-scoped artifact pointer`);
  }
}

function same(left, right) {
  return stable(left) === stable(right);
}

function runRoot(pointer) {
  const match = /^(\.testing\/runs\/[A-Za-z0-9._-]+)/.exec(pointer);
  return match && match[1];
}

function validateCommon(value, name, definition) {
  exactKeys(value, [...commonFields, ...definition.fields], `${name} receipt`);
  if (value.schema !== schemas[name] || value.status !== definition.status) fail(`${name} schema or status differs`);
  identity(value.receipt_id, `${name}.receipt_id`);
  identity(value.run_id, `${name}.run_id`);
  identity(value.trace_id, `${name}.trace_id`);
  identity(value.dedup_key, `${name}.dedup_key`);
  timestamp(value.recorded_at, `${name}.recorded_at`);
  repository(value.repository, `${name}.repository`);
  if (value.source_max_uses !== 1 || value.evidence_role !== 'audit-only'
    || value.human_approval_required !== false
    || value.authorization_capability !== false || value.execution_authorized !== false
    || value.promotion_authorized !== false || value.reusable !== false) {
    fail(`${name} must remain non-reusable audit evidence`);
  }
  for (const field of definition.pointers) {
    artifactPointer(value[field], `${name}.${field}`);
    if (runRoot(value[field]) !== `.testing/runs/${value.run_id}`) fail(`${name}.${field} belongs to another run`);
  }
  for (const field of definition.digests) digest(value[field], `${name}.${field}`);
  if (timestamp(value[definition.event], `${name}.${definition.event}`) > Date.parse(value.recorded_at)) {
    fail(`${name} was recorded before its source event`);
  }
}

function validateSpecific(value, name) {
  if (name === 'profile_claim') {
    sourceRef(value.profile_source_ref, 'profile_claim.profile_source_ref', 'host-profile-policy');
    sourceRef(value.approval_authority, 'profile_claim.approval_authority', 'host-policy');
    sourceRef(value.evidence_ref, 'profile_claim.evidence_ref', 'signed-attestation');
    identity(value.profile_revision, 'profile_claim.profile_revision');
    identity(value.approval_id, 'profile_claim.approval_id');
    identity(value.policy_revision, 'profile_claim.policy_revision');
  } else if (name === 'preauthorization_claim') {
    identity(value.authorization_id, 'preauthorization_claim.authorization_id');
    identity(value.policy_revision, 'preauthorization_claim.policy_revision');
    sourceRef(value.authority, 'preauthorization_claim.authority', 'host-policy');
    sourceRef(value.evidence_ref, 'preauthorization_claim.evidence_ref', 'signed-attestation');
  } else if (name === 'grant_verification') {
    identity(value.grant_id, 'grant_verification.grant_id');
    identity(value.policy_revision, 'grant_verification.policy_revision');
    identity(value.verification_id, 'grant_verification.verification_id');
    sourceRef(value.authority, 'grant_verification.authority', 'host-policy');
    sourceRef(value.evidence_ref, 'grant_verification.evidence_ref', 'signed-attestation');
    sourceRef(value.verifier_ref, 'grant_verification.verifier_ref', 'host-verifier');
  } else if (name === 'execution_claim') {
    identity(value.grant_id, 'execution_claim.grant_id');
    identity(value.operation_id, 'execution_claim.operation_id');
    if (value.artifact_root.endsWith('/')) fail('execution_claim.artifact_root is not exact');
  }
}

function validateReceipt(name, value, expected) {
  const definition = definitions[name];
  if (!definition) fail(`unsupported receipt ${name}`);
  validateCommon(value, name, definition);
  validateSpecific(value, name);
  exactKeys(expected, definition.sources, `${name} trusted source bindings`);
  for (const field of definition.sources) {
    if (!same(value[field], expected[field])) fail(`${name}.${field} differs from its trusted source`);
  }
  return value;
}

function canonicalDigest(value) {
  return crypto.createHash('sha256').update(stable(value)).digest('hex');
}

function validateLineageIndex(value, artifacts, expected) {
  exactKeys(value, [
    'schema', 'status', 'repository', 'run_id', 'trace_id', 'dedup_key', 'recorded_at',
    'receipts', 'lineage_complete', 'source_max_uses', 'evidence_role', 'human_approval_required',
    'authorization_capability', 'execution_authorized', 'promotion_authorized', 'reusable',
  ], 'lineage index');
  if (value.schema !== schemas.lineage_index || value.status !== 'complete'
    || value.lineage_complete !== true || value.source_max_uses !== 1
    || value.evidence_role !== 'audit-only' || value.human_approval_required !== false
    || value.authorization_capability !== false
    || value.execution_authorized !== false || value.promotion_authorized !== false
    || value.reusable !== false) fail('lineage index must remain complete non-reusable audit evidence');
  repository(value.repository, 'lineage index.repository');
  identity(value.run_id, 'lineage index.run_id');
  identity(value.trace_id, 'lineage index.trace_id');
  identity(value.dedup_key, 'lineage index.dedup_key');
  const indexTime = timestamp(value.recorded_at, 'lineage index.recorded_at');
  exactKeys(value.receipts, receiptNames, 'lineage index.receipts');
  object(artifacts, 'lineage artifacts');
  object(expected, 'lineage trusted source bindings');
  const root = `.testing/runs/${value.run_id}`;
  for (const name of receiptNames) {
    exactKeys(value.receipts[name], ['ref', 'sha256'], `lineage index.receipts.${name}`);
    const binding = value.receipts[name];
    artifactPointer(binding.ref, `lineage index.receipts.${name}.ref`);
    digest(binding.sha256, `lineage index.receipts.${name}.sha256`);
    if (binding.ref !== `${root}/${paths[name]}`) fail(`${name} receipt path is not canonical`);
    const artifact = artifacts[name];
    if (!artifact || artifact.ref !== binding.ref || artifact.sha256 !== binding.sha256
      || canonicalDigest(artifact.value) !== binding.sha256) fail(`${name} immutable binding differs`);
    validateReceipt(name, artifact.value, expected[name]);
    if (!same(artifact.value.repository, value.repository) || artifact.value.run_id !== value.run_id
      || artifact.value.trace_id !== value.trace_id || artifact.value.dedup_key !== value.dedup_key) {
      fail(`${name} receipt belongs to another run`);
    }
  }
  const profile = artifacts.profile_claim.value;
  const preauthorization = artifacts.preauthorization_claim.value;
  const grant = artifacts.grant_verification.value;
  const claim = artifacts.execution_claim.value;
  const completion = artifacts.execution_completion.value;
  if (preauthorization.profile_claim_receipt_ref !== value.receipts.profile_claim.ref
    || preauthorization.profile_claim_receipt_sha256 !== value.receipts.profile_claim.sha256
    || grant.preauthorization_claim_receipt_ref !== value.receipts.preauthorization_claim.ref
    || grant.preauthorization_claim_receipt_sha256 !== value.receipts.preauthorization_claim.sha256
    || claim.grant_verification_receipt_ref !== value.receipts.grant_verification.ref
    || claim.grant_verification_receipt_sha256 !== value.receipts.grant_verification.sha256
    || claim.preauthorization_claim_receipt_ref !== value.receipts.preauthorization_claim.ref
    || claim.preauthorization_claim_receipt_sha256 !== value.receipts.preauthorization_claim.sha256
    || completion.execution_claim_receipt_ref !== value.receipts.execution_claim.ref
    || completion.execution_claim_receipt_sha256 !== value.receipts.execution_claim.sha256
    || profile.profile_sha256 !== preauthorization.profile_sha256
    || preauthorization.preauthorization_ref !== grant.parent_authorization_ref
    || preauthorization.preauthorization_sha256 !== grant.parent_authorization_sha256
    || grant.grant_ref !== claim.grant_ref || grant.grant_sha256 !== claim.grant_sha256
    || grant.grant_id !== claim.grant_id || !same(preauthorization.authority, grant.authority)
    || preauthorization.policy_revision !== grant.policy_revision
    || preauthorization.plan_ref !== grant.plan_ref || preauthorization.plan_sha256 !== grant.plan_sha256
    || preauthorization.environment_receipt_ref !== grant.environment_receipt_ref
    || preauthorization.environment_receipt_sha256 !== grant.environment_receipt_sha256
    || grant.plan_ref !== claim.plan_ref || grant.plan_sha256 !== claim.plan_sha256
    || grant.environment_receipt_ref !== claim.environment_receipt_ref
    || grant.environment_receipt_sha256 !== claim.environment_receipt_sha256) {
    fail('receipt chain is incomplete or inconsistent');
  }
  if (completion.result_ref !== `${claim.artifact_root}/execution.json`
    || completion.case_result_set_ref !== `${claim.artifact_root}/case-result-set.json`
    || completion.evidence_manifest_ref !== `${claim.artifact_root}/evidence-manifest.json`) {
    fail('completion artifacts differ from the claimed execution root');
  }
  const chronology = [
    profile.claimed_at, preauthorization.claimed_at, grant.verified_at,
    claim.claimed_at, completion.completed_at, value.recorded_at,
  ].map((item, index) => timestamp(item, `lineage chronology ${index}`));
  if (chronology.some((item, index) => index > 0 && chronology[index - 1] > item)
    || chronology[chronology.length - 1] !== indexTime) fail('authorization events are out of order');
  return value;
}

module.exports = { definitions, paths, receiptNames, schemas, validateLineageIndex, validateReceipt };
