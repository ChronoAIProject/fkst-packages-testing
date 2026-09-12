'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { stable } = require(path.resolve(__dirname, '../bin/durable-host-store'));
const lineage = require(path.resolve(__dirname, '../bin/authorization-lineage'));
const runtime = require(path.resolve(__dirname, '../bin/generic-host-runtime'));

const runId = 'node-lineage-validator';
const repository = { url: 'https://example.invalid/testing/fixture.git', commit_sha: '1'.repeat(40) };
const ref = (suffix) => `.testing/runs/${runId}/${suffix}`;
const digest = (value) => crypto.createHash('sha256').update(stable(value)).digest('hex');
const fakeDigest = (value) => String(value).repeat(64).slice(0, 64);
const copy = (value) => JSON.parse(JSON.stringify(value));
const common = (value) => ({
  repository: copy(repository), run_id: runId, trace_id: 'trace-node-lineage', dedup_key: runId,
  recorded_at: '2026-09-10T00:10:00Z', source_max_uses: 1, evidence_role: 'audit-only',
  human_approval_required: false,
  authorization_capability: false, execution_authorized: false,
  promotion_authorized: false, reusable: false, ...value,
});

const envelopeFields = new Set([
  'schema', 'status', 'receipt_id', 'recorded_at', 'source_max_uses',
  'evidence_role', 'human_approval_required', 'authorization_capability', 'execution_authorized',
  'promotion_authorized', 'reusable',
]);
const expected = (value) => Object.fromEntries(
  Object.entries(copy(value)).filter(([key]) => !envelopeFields.has(key)),
);

function fixture() {
  const values = {
    profile_claim: common({
      schema: lineage.schemas.profile_claim, status: 'claimed', receipt_id: 'profile-claim-1',
      profile_source_ref: { kind: 'host-profile-policy', ref: 'policies/profile-v1' },
      profile_artifact_ref: ref('authorization/project-profile.json'),
      profile_artifact_sha256: fakeDigest('1'), profile_sha256: fakeDigest('2'),
      profile_revision: 'profile-v1', approval_artifact_ref: ref('authorization/profile-approval.json'),
      approval_artifact_sha256: fakeDigest('3'), approval_id: 'profile-approval-1',
      approval_sha256: fakeDigest('4'),
      approval_authority: { kind: 'host-policy', ref: 'policies/profile-approval-v1' },
      policy_revision: 'profile-policy-v1',
      evidence_ref: { kind: 'signed-attestation', ref: 'attestations/profile-approval-1' },
      validation_receipt_ref: ref('authorization/profile-validation.json'),
      validation_receipt_sha256: fakeDigest('5'), claim_fingerprint_sha256: fakeDigest('6'),
      claimed_at: '2026-09-10T00:01:00Z',
    }),
    preauthorization_claim: common({
      schema: lineage.schemas.preauthorization_claim, status: 'claimed',
      receipt_id: 'preauthorization-claim-1',
      profile_claim_receipt_ref: ref(lineage.paths.profile_claim),
      profile_claim_receipt_sha256: fakeDigest('7'),
      preauthorization_ref: ref('execution/preauthorization.json'),
      preauthorization_sha256: fakeDigest('8'), authorization_id: 'preauthorization-1',
      profile_sha256: fakeDigest('2'), case_catalog_ref: ref('execution/case-catalog.json'),
      case_catalog_sha256: fakeDigest('9'), plan_ref: ref('execution/structured-plan.json'),
      plan_sha256: fakeDigest('a'), environment_receipt_ref: ref('environment/ready.json'),
      environment_receipt_sha256: fakeDigest('b'),
      authority: { kind: 'host-policy', ref: 'policies/execution-v1' },
      policy_revision: 'execution-v1',
      evidence_ref: { kind: 'signed-attestation', ref: 'attestations/preauthorization-1' },
      claim_fingerprint_sha256: fakeDigest('c'), claimed_at: '2026-09-10T00:02:00Z',
    }),
    grant_verification: common({
      schema: lineage.schemas.grant_verification, status: 'authenticated',
      receipt_id: 'grant-verification-1',
      preauthorization_claim_receipt_ref: ref(lineage.paths.preauthorization_claim),
      preauthorization_claim_receipt_sha256: fakeDigest('d'),
      grant_ref: ref('execution/execution-grant.json'), grant_sha256: fakeDigest('e'),
      grant_id: 'grant-1', parent_authorization_ref: ref('execution/preauthorization.json'),
      parent_authorization_sha256: fakeDigest('8'), plan_ref: ref('execution/structured-plan.json'),
      plan_sha256: fakeDigest('a'), environment_receipt_ref: ref('environment/ready.json'),
      environment_receipt_sha256: fakeDigest('b'),
      authority: { kind: 'host-policy', ref: 'policies/execution-v1' },
      policy_revision: 'execution-v1',
      evidence_ref: { kind: 'signed-attestation', ref: 'attestations/grant-1' },
      verifier_ref: { kind: 'host-verifier', ref: 'verifiers/execution-v1' },
      verification_id: 'verification-1', verified_at: '2026-09-10T00:03:00Z',
    }),
    execution_claim: common({
      schema: lineage.schemas.execution_claim, status: 'claimed', receipt_id: 'execution-claim-1',
      grant_verification_receipt_ref: ref(lineage.paths.grant_verification),
      grant_verification_receipt_sha256: fakeDigest('f'),
      preauthorization_claim_receipt_ref: ref(lineage.paths.preauthorization_claim),
      preauthorization_claim_receipt_sha256: fakeDigest('d'),
      grant_ref: ref('execution/execution-grant.json'), grant_sha256: fakeDigest('e'),
      grant_id: 'grant-1', plan_ref: ref('execution/structured-plan.json'), plan_sha256: fakeDigest('a'),
      environment_receipt_ref: ref('environment/ready.json'), environment_receipt_sha256: fakeDigest('b'),
      artifact_root: ref('execution'), operation_id: runId,
      claim_fingerprint_sha256: fakeDigest('0'), claimed_at: '2026-09-10T00:04:00Z',
    }),
    execution_completion: common({
      schema: lineage.schemas.execution_completion, status: 'completed',
      receipt_id: 'execution-completion-1',
      execution_claim_receipt_ref: ref(lineage.paths.execution_claim),
      execution_claim_receipt_sha256: fakeDigest('1'), result_ref: ref('execution/execution.json'),
      result_sha256: fakeDigest('2'), case_result_set_ref: ref('execution/case-result-set.json'),
      case_result_set_artifact_sha256: fakeDigest('3'),
      evidence_manifest_ref: ref('execution/evidence-manifest.json'),
      evidence_manifest_artifact_sha256: fakeDigest('4'), completed_at: '2026-09-10T00:05:00Z',
    }),
  };
  const state = { values };
  reseal(state);
  return state;
}

function reseal(state) {
  const { values } = state;
  const artifacts = {};
  const bind = (name) => {
    const sha256 = digest(values[name]);
    artifacts[name] = { ref: ref(lineage.paths[name]), sha256, value: values[name] };
    return sha256;
  };
  values.preauthorization_claim.profile_claim_receipt_sha256 = bind('profile_claim');
  const preauthorizationDigest = bind('preauthorization_claim');
  values.grant_verification.preauthorization_claim_receipt_sha256 = preauthorizationDigest;
  values.execution_claim.preauthorization_claim_receipt_sha256 = preauthorizationDigest;
  values.execution_claim.grant_verification_receipt_sha256 = bind('grant_verification');
  values.execution_completion.execution_claim_receipt_sha256 = bind('execution_claim');
  bind('execution_completion');
  state.artifacts = artifacts;
  state.expected = Object.fromEntries(Object.entries(values).map(([name, value]) => [name, expected(value)]));
  state.index = {
    schema: lineage.schemas.lineage_index, status: 'complete', repository: copy(repository),
    run_id: runId, trace_id: 'trace-node-lineage', dedup_key: runId,
    recorded_at: '2026-09-10T00:10:00Z',
    receipts: Object.fromEntries(Object.entries(artifacts).map(([name, artifact]) => [
      name, { ref: artifact.ref, sha256: artifact.sha256 },
    ])),
    lineage_complete: true, source_max_uses: 1, evidence_role: 'audit-only',
    human_approval_required: false,
    authorization_capability: false, execution_authorized: false,
    promotion_authorized: false, reusable: false,
  };
}

function rejects(mutator) {
  const value = fixture();
  mutator(value.values);
  reseal(value);
  assert.throws(() => lineage.validateLineageIndex(value.index, value.artifacts, value.expected));
}

const valid = fixture();
assert.equal(lineage.validateLineageIndex(valid.index, valid.artifacts, valid.expected), valid.index);

rejects((values) => { values.grant_verification.authority.ref = 'policies/foreign-execution'; });
rejects((values) => { values.grant_verification.policy_revision = 'execution-v2'; });
rejects((values) => {
  values.grant_verification.plan_ref = ref('execution/foreign-plan.json');
  values.grant_verification.plan_sha256 = fakeDigest('5');
  values.execution_claim.plan_ref = values.grant_verification.plan_ref;
  values.execution_claim.plan_sha256 = values.grant_verification.plan_sha256;
});
rejects((values) => {
  values.grant_verification.environment_receipt_ref = ref('environment/foreign-ready.json');
  values.grant_verification.environment_receipt_sha256 = fakeDigest('6');
  values.execution_claim.environment_receipt_ref = values.grant_verification.environment_receipt_ref;
  values.execution_claim.environment_receipt_sha256 = values.grant_verification.environment_receipt_sha256;
});
rejects((values) => { values.execution_claim.grant_id = 'foreign-grant'; });
rejects((values) => { values.preauthorization_claim.claimed_at = '2026-09-09T23:59:59Z'; });
rejects((values) => { values.execution_claim.human_approval_required = true; });
rejects((values) => { values.execution_claim.authorization_capability = true; });
rejects((values) => { values.execution_claim.execution_authorized = true; });
rejects((values) => { values.execution_claim.promotion_authorized = true; });
for (const invalidTimestamp of [
  '2026-02-30T00:00:00Z',
  '2026-09-10T24:00:00Z',
  '2026-09-10T00:00:00.123Z',
]) {
  rejects((values) => { values.execution_claim.claimed_at = invalidTimestamp; });
}
rejects((values) => { values.execution_claim.receipt_id = '\u00e9'.repeat(91); });

const substituted = fixture();
const trusted = copy(substituted.expected);
substituted.values.profile_claim.profile_sha256 = fakeDigest('f');
reseal(substituted);
substituted.expected = trusted;
assert.throws(() => lineage.validateLineageIndex(
  substituted.index, substituted.artifacts, substituted.expected,
));

const preauthorizationRequest = {
  authorization_id: 'preauthorization-1',
  preauthorization_ref: ref('execution/preauthorization.json'),
  preauthorization_sha256: fakeDigest('8'),
  repository: copy(repository),
  plan_ref: ref('execution/structured-plan.json'),
  plan_sha256: fakeDigest('a'),
  environment_receipt_ref: ref('environment/ready.json'),
  environment_receipt_sha256: fakeDigest('b'),
  trace_id: 'trace-node-lineage',
  dedup_key: runId,
};
const legacyPreauthorizationBinding = {
  authorization_id: preauthorizationRequest.authorization_id,
  preauthorization_sha256: preauthorizationRequest.preauthorization_sha256,
  repository: copy(repository),
  plan_sha256: preauthorizationRequest.plan_sha256,
  environment_receipt_sha256: preauthorizationRequest.environment_receipt_sha256,
  trace_id: preauthorizationRequest.trace_id,
  dedup_key: preauthorizationRequest.dedup_key,
};
const runtimeConfigRef = {
  kind: 'artifact', ref: '.testing/generic-host-runtime.json',
};
const trustedPreauthorizationRefs = {
  preauthorization_ref: preauthorizationRequest.preauthorization_ref,
  plan_ref: preauthorizationRequest.plan_ref,
  environment_receipt_ref: preauthorizationRequest.environment_receipt_ref,
};

assert.equal(runtime.preauthorizationBindingMatches(
  copy(preauthorizationRequest), preauthorizationRequest, trustedPreauthorizationRefs), true);
assert.equal(runtime.preauthorizationBindingMatches(
  copy(legacyPreauthorizationBinding), preauthorizationRequest, trustedPreauthorizationRefs), true);
assert.equal(runtime.preauthorizationBindingMatches({
  ...copy(preauthorizationRequest), runtime_config_ref: copy(runtimeConfigRef),
}, preauthorizationRequest, trustedPreauthorizationRefs), true);
assert.equal(runtime.preauthorizationBindingMatches({
  ...copy(legacyPreauthorizationBinding), runtime_config_ref: copy(runtimeConfigRef),
}, preauthorizationRequest, trustedPreauthorizationRefs), true);
assert.equal(runtime.preauthorizationBindingMatches({
  ...copy(preauthorizationRequest),
  runtime_config_ref: { kind: 'artifact', ref: '.testing/foreign-runtime.json' },
}, preauthorizationRequest, trustedPreauthorizationRefs), false);
assert.equal(runtime.preauthorizationBindingMatches({
  ...copy(preauthorizationRequest), unexpected: true,
}, preauthorizationRequest, trustedPreauthorizationRefs), false);
assert.equal(runtime.preauthorizationBindingMatches(
  copy(legacyPreauthorizationBinding), {
    ...copy(preauthorizationRequest), plan_ref: ref('execution/foreign-plan.json'),
  }, trustedPreauthorizationRefs), false);

const structuredConfig = { run_id: runId };
const structuredRequest = {
  repository: copy(repository), preauthorization_ref: ref('execution/preauthorization.json'),
  preauthorization_sha256: fakeDigest('8'), plan_ref: ref('execution/structured-plan.json'),
  plan_sha256: fakeDigest('a'), environment_receipt_ref: ref('environment/ready.json'),
  environment_receipt_sha256: fakeDigest('b'), grant_ref: ref('execution/execution-grant.json'),
  grant_sha256: fakeDigest('e'), now: '2026-07-22T00:20:00Z',
  trace_id: 'trace-node-lineage', dedup_key: runId,
};
const structuredPreauthorization = { digest: structuredRequest.preauthorization_sha256, value: {
  schema: 'testing-structured-execution-authorization.v1', authorization_id: 'preauthorization-1',
  repository: copy(repository), profile_sha256: fakeDigest('2'), case_catalog_sha256: fakeDigest('9'),
  capabilities: {
    cli: [],
    http: [{ origin: 'http://127.0.0.1:4173', methods: ['GET'], path_prefixes: ['/health'] }],
  },
  authority: { kind: 'host-policy', ref: 'policies/execution-v1' }, policy_revision: 'execution-v1',
  evidence_ref: { kind: 'signed-attestation', ref: 'attestations/preauthorization-1' },
  issued_at: '2026-07-22T00:00:00Z', expires_at: '2026-07-22T01:00:00Z', max_uses: 1,
  trace_id: structuredRequest.trace_id, dedup_key: structuredRequest.dedup_key,
} };
const structuredPlan = { digest: structuredRequest.plan_sha256, value: {
  schema: 'testing-structured-plan.v2', execution_mode: 'structured-api-cli', repository: copy(repository),
  environment_receipt_sha256: structuredRequest.environment_receipt_sha256,
  case_catalog_sha256: structuredPreauthorization.value.case_catalog_sha256,
  cases: [{
    case_id: 'health', kind: 'http', timeout_seconds: 10,
    request: { method: 'GET', url: 'http://127.0.0.1:4173/health', headers: [] },
    assertions: [{ type: 'status-code', expected: 200 }],
  }],
  residual_risk_case_ids: [], browser_readiness_sha256: fakeDigest('c'),
  module_plan_sha256: fakeDigest('d'), trace_id: structuredRequest.trace_id,
  dedup_key: structuredRequest.dedup_key,
} };
const structuredEnvironment = { digest: structuredRequest.environment_receipt_sha256, value: {
  schema: 'environment-factory.receipt.v2', status: 'ready', repository: copy(repository),
  trace_id: structuredRequest.trace_id, dedup_key: structuredRequest.dedup_key,
} };
const structuredGrant = { digest: structuredRequest.grant_sha256, value: {
  schema: 'testing-structured-execution-grant.v1', grant_id: `${runId}-grant`,
  parent_authorization_sha256: structuredRequest.preauthorization_sha256,
  plan_sha256: structuredRequest.plan_sha256,
  environment_receipt_sha256: structuredRequest.environment_receipt_sha256,
  repository: copy(repository), cli_capabilities: [],
  http_capabilities: copy(structuredPreauthorization.value.capabilities.http),
  authority: copy(structuredPreauthorization.value.authority), policy_revision: 'execution-v1',
  evidence_ref: { kind: 'signed-attestation', ref: `${runId}-execution-grant` },
  issued_at: '2026-07-22T00:15:00Z', expires_at: '2026-07-22T00:45:00Z', max_uses: 1,
  trace_id: structuredRequest.trace_id, dedup_key: structuredRequest.dedup_key,
} };
assert.deepEqual(runtime.assertStructuredGrantDerivation(structuredConfig, structuredRequest,
  structuredPreauthorization, structuredPlan, structuredEnvironment, structuredGrant), structuredGrant.value);
assert.equal(runtime.assertExecutionMatchesClaim(
  { plan_sha256: structuredRequest.plan_sha256 },
  { plan_sha256: structuredRequest.plan_sha256 },
), true);
assert.throws(() => runtime.assertExecutionMatchesClaim(
  { plan_sha256: fakeDigest('f') },
  { plan_sha256: structuredRequest.plan_sha256 },
), /Plan binding differs/);

for (const mutate of [
  (state) => { state.grant.value.authority.ref = 'policies/foreign'; },
  (state) => { state.grant.value.policy_revision = 'execution-v2'; },
  (state) => { state.grant.value.evidence_ref.ref = 'foreign-evidence'; },
  (state) => { state.grant.value.http_capabilities[0].methods.push('POST'); },
  (state) => { state.grant.value.http_capabilities[0].path_prefixes.push('/admin'); },
  (state) => { state.plan.value.cases[0].request.url = 'http://127.0.0.1:4173/admin'; },
]) {
  const state = {
    preauthorization: copy(structuredPreauthorization), plan: copy(structuredPlan),
    environment: copy(structuredEnvironment), grant: copy(structuredGrant),
  };
  mutate(state);
  assert.throws(() => runtime.assertStructuredGrantDerivation(structuredConfig, structuredRequest,
    state.preauthorization, state.plan, state.environment, state.grant));
}

const cliState = {
  preauthorization: copy(structuredPreauthorization), plan: copy(structuredPlan),
  environment: copy(structuredEnvironment), grant: copy(structuredGrant),
};
cliState.preauthorization.value.capabilities = {
  cli: [{ argv_prefix: ['fixture-cli', 'health'] }], http: [],
};
cliState.plan.value.cases = [{
  case_id: 'health-cli', kind: 'cli', argv: ['fixture-cli', 'health'],
  timeout_seconds: 10, assertions: [{ type: 'exit-code', expected: 0 }],
}];
cliState.grant.value.cli_capabilities = copy(cliState.preauthorization.value.capabilities.cli);
cliState.grant.value.http_capabilities = [];
assert.doesNotThrow(() => runtime.assertStructuredGrantDerivation(structuredConfig, structuredRequest,
  cliState.preauthorization, cliState.plan, cliState.environment, cliState.grant));
cliState.grant.value.cli_capabilities[0].argv_prefix = ['fixture-cli'];
assert.throws(() => runtime.assertStructuredGrantDerivation(structuredConfig, structuredRequest,
  cliState.preauthorization, cliState.plan, cliState.environment, cliState.grant));
