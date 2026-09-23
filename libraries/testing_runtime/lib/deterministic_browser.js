'use strict';

const crypto = require('node:crypto');

const CAPABILITY = ['testing.deterministic-browser-plan'];
const DENIED = { execution_authorized: false, promotion_authorized: false, gate_effect: false };
const PREFIX = 'testing.fixed-browser-';
const HEX = /^[0-9a-f]{64}$/;
const DIGEST = /^sha256:[0-9a-f]{64}$/;
const ID = /^[A-Za-z0-9_-]{1,96}$/;
const REF = /^[a-z][A-Za-z0-9._:/-]{2,200}$/;

function fail(code) { throw new Error(`fixed-browser: ${code}`); }
function check(value, code = 'unsupported-input') { if (!value) fail(code); }
function stable(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`;
  return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stable(value[key])}`).join(',')}}`;
}
function sha256(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function digest(value) { return `sha256:${sha256(stable(value))}`; }
function equal(a, b) { return stable(a) === stable(b); }
function keys(value, names) {
  check(value && typeof value === 'object' && !Array.isArray(value)
    && equal(Object.keys(value).sort(), names.split(' ').sort()), 'unexpected-fields');
}
function seal(value) {
  const body = { ...value }; delete body.content_digest;
  return { ...body, content_digest: digest(body) };
}
function sealed(value) {
  check(value && DIGEST.test(value.content_digest) && equal(value, seal(value)), 'content-digest-mismatch');
}
function bounded(value, max = 180) {
  return typeof value === 'string' && value.length > 0 && Buffer.byteLength(value) <= max && !/[\x00-\x1f\x7f]/.test(value);
}
function timeout(value, max) { check(Number.isInteger(value) && value >= 1 && value <= max, 'invalid-timeout'); }
function utc(value) {
  return typeof value === 'string' && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(value)
    && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().replace('.000Z', 'Z') === value;
}

function compile(candidate, policy) {
  keys(candidate, 'schema_version artifact_type artifact_id project_id source_binding case_design catalog bundle_digest staging_update_digest staged_project_pack_digest staging_approval_digest authority content_digest');
  sealed(candidate);
  check(candidate.schema_version === 'pql.browser-host-candidate.v1'
    && candidate.artifact_type === 'browser_host_candidate' && /^bhc_[0-9a-f]{24}$/.test(candidate.artifact_id)
    && equal(candidate.authority, DENIED), 'non-authorizing-candidate-required');
  keys(candidate.source_binding, 'exact_ref repo_state repository_identity');
  check(candidate.source_binding.repo_state === 'clean', 'source-binding-invalid');
  for (const field of ['bundle_digest', 'staging_update_digest', 'staged_project_pack_digest', 'staging_approval_digest']) {
    check(DIGEST.test(candidate[field]), 'staging-binding-invalid');
  }
  const c = candidate.case_design;
  keys(c, 'schema_version artifact_type artifact_id project_id created_at producer producer_version content_digest case_kind case_id suite_refs primary_asset_path source_lineage target_repository target_commit base_project_pack_ref base_project_pack_digest base_project_pack_version action_assertion_catalog capability_requirements evidence_requirements timeout_policy network_policy filesystem_policy secret_ref_requirements canonicalization lifecycle authorization browser');
  sealed(c);
  check(c.schema_version === 'pql.case-design.v2' && c.artifact_type === 'case_design'
    && c.case_kind === 'deterministic-browser' && c.project_id === candidate.project_id
    && /^[A-Z0-9][A-Z0-9._-]{2,127}$/.test(c.case_id)
    && equal(c.authorization, { execution_authorized: false, promotion_authorized: false })
    && equal(c.lifecycle, { activation_status: 'not-active', evidence_status: 'not-verifiable',
      gate_effect: false, lifecycle_state: 'design_only', required_review: true }), 'case-slice-invalid');
  keys(c.target_repository, 'identity exact_commit');
  check(/^repo:[A-Za-z0-9._/-]{3,175}$/.test(c.target_repository.identity)
    && /^[0-9a-f]{40}$/.test(c.target_commit)
    && c.target_commit === c.target_repository.exact_commit, 'target-sha-mismatch');
  check(candidate.source_binding && candidate.source_binding.exact_ref === c.target_commit
    && `repo:${String(candidate.source_binding.repository_identity).replace(/^github:/, '')}` === c.target_repository.identity,
  'source-binding-mismatch');
  check(equal(c.canonicalization, { algorithm: 'pql.canonical-json', version: '1', self_digest_excludes: ['content_digest'] })
    && equal(c.filesystem_policy, { path_policy: 'none', read_refs: [], write_refs: [] })
    && equal(c.secret_ref_requirements, []) && equal(c.capability_requirements, CAPABILITY), 'unsupported-case-policy');
  keys(c.network_policy, 'allowed_origin_refs query_fragment_policy');
  check(c.network_policy.query_fragment_policy === 'none', 'unsupported-network-policy');
  keys(c.timeout_policy, 'case_timeout_seconds per_action_timeout_seconds');
  timeout(c.timeout_policy.case_timeout_seconds, 900); timeout(c.timeout_policy.per_action_timeout_seconds, 300);
  check(Array.isArray(c.evidence_requirements) && c.evidence_requirements.length === 1, 'unsupported-evidence');
  keys(c.evidence_requirements[0], 'evidence_id digest_domain');
  check(c.evidence_requirements[0].digest_domain === 'case-result' && REF.test(c.evidence_requirements[0].evidence_id), 'unsupported-evidence');
  const b = c.browser;
  keys(b, 'browser_plan_ref action_catalog assertion_catalog origin_allowlist profile_requirement credential_refs actions assertions semantic_targets wait_policy evidence_policy forbidden_behavior capability_requirements');
  check(equal(b.credential_refs, []) && equal(b.capability_requirements, CAPABILITY)
    && equal(b.evidence_policy, { screenshot_allowed: false, sanitized_observation_required: true })
    && equal(b.forbidden_behavior, { extensions: 'forbidden', cookies_storage_access: 'forbidden',
      cross_origin_without_policy: 'forbidden', runtime_selector_synthesis: 'forbidden' }), 'unsupported-browser-policy');
  keys(b.profile_requirement, 'profile_ref credential_material_allowed');
  check(b.profile_requirement.credential_material_allowed === false && REF.test(b.profile_requirement.profile_ref), 'credentials-forbidden');
  keys(b.wait_policy, 'max_wait_seconds poll_interval_seconds');
  timeout(b.wait_policy.max_wait_seconds, 300); timeout(b.wait_policy.poll_interval_seconds, b.wait_policy.max_wait_seconds);
  check(Array.isArray(b.actions) && b.actions.length === 1 && Array.isArray(b.assertions)
    && b.assertions.length === 1 && Array.isArray(b.semantic_targets) && b.semantic_targets.length === 1, 'unsupported-browser-sequence');
  const action = b.actions[0]; const assertion = b.assertions[0]; const target = b.semantic_targets[0];
  keys(action, 'action_id kind origin_policy_ref timeout_seconds');
  keys(assertion, 'assertion_id kind target_ref expected_ref');
  check(action.kind === 'navigate' && assertion.kind === 'title' && REF.test(action.action_id)
    && REF.test(assertion.assertion_id) && REF.test(assertion.expected_ref), 'unsupported-browser-sequence');
  timeout(action.timeout_seconds, c.timeout_policy.per_action_timeout_seconds);
  keys(target, 'target_ref target_kind reviewed_origin_ref role accessible_name_ref state_predicates source_refs evidence_refs catalog_tuple target_digest');
  const targetBody = { ...target }; delete targetBody.target_digest;
  check(target.target_digest === digest(targetBody) && target.target_kind === 'page-region'
    && REF.test(target.target_ref) && assertion.target_ref === target.target_ref
    && target.reviewed_origin_ref === action.origin_policy_ref && target.role === 'region'
    && equal(target.state_predicates, ['state:visible']), 'target-binding-mismatch');
  const catalog = candidate.catalog;
  keys(catalog, 'schema_version catalog_id catalog_version content_digest actions assertions'); sealed(catalog);
  check(catalog.schema_version === 'pql.browser-design-catalog.v1', 'catalog-invalid');
  const tuple = { catalog_id: catalog.catalog_id, catalog_version: catalog.catalog_version, catalog_digest: catalog.content_digest };
  for (const actual of [c.action_assertion_catalog, b.action_catalog, b.assertion_catalog, target.catalog_tuple]) {
    check(equal(actual, tuple), 'catalog-binding-mismatch');
  }
  check(equal(catalog.actions, b.actions) && Array.isArray(catalog.assertions) && catalog.assertions.length === 1, 'catalog-sequence-mismatch');
  const fact = catalog.assertions[0]; keys(fact, 'kind value expected_value');
  check(fact.kind === 'assertion' && equal(fact.value, assertion)
    && typeof fact.expected_value === 'string' && /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,119}$/.test(fact.expected_value), 'catalog-assertion-mismatch');
  keys(policy, 'schema_version policy_id candidate_digest case_content_digest target_repository origin_ref origin path query_policy fragment_policy account_policy capabilities secret_ref_allowlist fixture_sha256 timeout_ms target_resolution');
  keys(policy.target_resolution, 'target_ref accessible_name_ref accessible_name');
  check(policy.target_resolution.target_ref === target.target_ref
    && policy.target_resolution.accessible_name_ref === target.accessible_name_ref
    && /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,119}$/.test(policy.target_resolution.accessible_name), 'target-resolution-invalid');
  check(policy.schema_version === `${PREFIX}host-policy.v1` && ID.test(policy.policy_id)
    && policy.candidate_digest === candidate.content_digest && policy.case_content_digest === c.content_digest
    && equal(policy.target_repository, c.target_repository), 'host-policy-binding-mismatch');
  check(policy.origin_ref === action.origin_policy_ref && equal(b.origin_allowlist, [policy.origin_ref])
    && equal(c.network_policy.allowed_origin_refs, [policy.origin_ref])
    && policy.query_policy === 'forbidden' && policy.fragment_policy === 'forbidden' && policy.account_policy === 'none'
    && equal(policy.capabilities, CAPABILITY) && equal(policy.secret_ref_allowlist, [])
    && HEX.test(policy.fixture_sha256), 'host-policy-scope-mismatch');
  let url; try { url = new URL(policy.origin + policy.path); } catch (_) { fail('invalid-fixture-url'); }
  check(/^http:\/\/(127\.0\.0\.1|\[::1\]):[1-9][0-9]{0,4}$/.test(policy.origin)
    && typeof policy.path === 'string' && /^\/[A-Za-z0-9/_-]*$/.test(policy.path)
    && url.origin === policy.origin && url.pathname === policy.path && !url.search && !url.hash
    && !url.username && !url.password, 'invalid-fixture-url');
  timeout(policy.timeout_ms, 30000);
  const timeoutMs = Math.min(policy.timeout_ms, action.timeout_seconds * 1000,
    c.timeout_policy.case_timeout_seconds * 1000, b.wait_policy.max_wait_seconds * 1000);
  return seal({ schema_version: `${PREFIX}plan.v1`, binding: {
    candidate_digest: candidate.content_digest, case_content_digest: c.content_digest,
    catalog_digest: catalog.content_digest, target_digests: [target.target_digest],
    target_repository: c.target_repository, host_policy_digest: digest(policy),
  }, action: { kind: 'navigate', action_id: action.action_id, url: url.href },
  assertion: { kind: 'title', assertion_id: assertion.assertion_id, target_ref: assertion.target_ref, expected: fact.expected_value },
  timeout_ms: timeoutMs });
}

function admit(request, host) {
  keys(request, 'candidate plan execution_id');
  check(ID.test(request.execution_id), 'invalid-execution-identity');
  check(equal(request.plan, compile(request.candidate, host.policy)), 'plan-mismatch');
  const grant = host.loadGrant(request.execution_id);
  keys(grant, 'schema_version execution_id binding plan_digest expires_at');
  check(grant.schema_version === `${PREFIX}grant.v1` && grant.execution_id === request.execution_id
    && grant.plan_digest === request.plan.content_digest && equal(grant.binding, request.plan.binding)
    && utc(grant.expires_at), 'grant-mismatch');
  return { ...request.plan.binding, plan_digest: request.plan.content_digest, grant_digest: digest(grant) };
}

function validateEffect(effect, binding) {
  keys(effect, 'schema_version binding outcome observed_title target_status cleanup_status started_at completed_at');
  check(effect.schema_version === `${PREFIX}effect.v1` && equal(effect.binding, binding)
    && ['observed', 'error', 'timeout', 'lost'].includes(effect.outcome)
    && (effect.outcome === 'observed' ? bounded(effect.observed_title, 120) : effect.observed_title === null)
    && ['unique-visible', 'unresolved'].includes(effect.target_status)
    && (effect.outcome !== 'observed' || effect.target_status === 'unique-visible')
    && ['complete', 'unknown'].includes(effect.cleanup_status) && utc(effect.started_at) && utc(effect.completed_at)
    && Date.parse(effect.completed_at) >= Date.parse(effect.started_at), 'effect-receipt-invalid');
}

function project(request, binding, effect) {
  validateEffect(effect, binding);
  const { plan, candidate, execution_id: id } = request;
  check(effect.observed_title === null || effect.observed_title === plan.assertion.expected
    || effect.observed_title === '[title differs]', 'unsafe-title-observation');
  const root = `.testing/runs/${id}`;
  const planRef = { kind: 'artifact', ref: `${root}/test-plan.json` };
  const planSha = sha256(stable(plan));
  const repository = { id: candidate.case_design.target_repository.identity,
    source_ref: { kind: 'git', ref: `${candidate.case_design.target_repository.identity}@${candidate.case_design.target_commit}` },
    source_sha256: sha256(stable(candidate.case_design.target_repository)) };
  const observed = effect.outcome === 'observed' && effect.cleanup_status === 'complete';
  const status = observed ? (effect.observed_title === plan.assertion.expected ? 'passed' : 'failed') : effect.outcome === 'lost' ? 'lost' : 'error';
  const classification = { passed: 'deterministic', failed: 'assertion_failure', lost: 'lost', error: 'execution_error' }[status];
  const evidence = { ...effect };
  const evidenceSha = sha256(stable(evidence));
  const evidenceRef = { kind: 'evidence', ref: 'fixed-browser-effect' };
  const manifest = { schema: 'testing-evidence-manifest.v1', manifest_id: id,
    canonicalization: 'fkst-testing-evidence-manifest-canonical-json.v1', repository,
    run_id: id, plan_ref: planRef, plan_sha256: planSha,
    entries: [{ evidence_id: evidenceRef.ref, case_id: candidate.case_design.case_id,
      assertion_id: plan.assertion.assertion_id, role: 'sanitized-json',
      artifact_ref: { kind: 'artifact', ref: `${root}/effect.json` }, sha256: evidenceSha,
      media_type: 'application/json', size_bytes: Buffer.byteLength(stable(evidence)),
      producer: 'testing.fixed-browser', producer_version: '1.0.0', created_at: effect.completed_at,
      sensitivity: 'internal', redaction_classification: 'raw-title-withheld',
      policy_version: 'fixed-browser.v1', policy_status: 'redacted',
      provenance: { source_kind: 'artifact', source_ref: `${root}/effect.json`, source_sha256: evidenceSha } }],
  };
  manifest.canonical_sha256 = sha256(stable(manifest));
  const manifestSha = sha256(stable(manifest));
  const item = { schema: 'testing-case-result.v2', case_id: candidate.case_design.case_id, repository,
    reviewed_case_id: candidate.case_design.case_id, plan_ref: planRef, plan_sha256: planSha,
    execution_mode: 'browser', execution_status: status, classification,
    observations: observed ? [{ schema: 'testing-observation.v1', observation_id: 'title-comparison',
      kind: 'browser-title', subject: plan.assertion.target_ref,
      value: effect.observed_title,
      source_ref: { kind: 'effect-receipt', ref: `${root}/effect.json` }, evidence_refs: [evidenceRef] }] : [],
    assertions: [{ schema: 'testing-assertion-result.v1', assertion_id: plan.assertion.assertion_id,
      type: 'title-equals', required: true, status: observed ? status : 'skipped',
      classification: observed ? classification : 'skipped', observation_ids: observed ? ['title-comparison'] : [], evidence_refs: [evidenceRef] }],
    evidence_refs: [evidenceRef], timing: { started_at: effect.started_at, completed_at: effect.completed_at,
      duration_ms: Math.min(86400000, Date.parse(effect.completed_at) - Date.parse(effect.started_at)) }, trace_id: id, dedup_key: id,
  };
  if (status === 'lost') item.non_execution_reason = 'execution-lost-between-action-and-assertion';
  if (status === 'error') item.error = { code: effect.outcome === 'timeout' ? 'provider-timeout' : 'browser-step-failed',
    message: 'Fixed Browser execution or cleanup did not complete.' };
  const resultSet = { schema: 'testing-case-result-set.v2', set_id: id, run_id: id,
    plan_ref: planRef, plan_sha256: planSha, cases: [item],
    evidence_manifest_ref: { kind: 'artifact', ref: `${root}/evidence-manifest.json`, sha256: manifestSha },
    evidence_manifest_sha256: manifest.canonical_sha256, evidence_manifest_artifact_sha256: manifestSha, trace_id: id, dedup_key: id };
  return { schema_version: `${PREFIX}result.v1`, completion: { schema_version: `${PREFIX}completion.v1`, execution_id: id,
    binding: plan.binding, plan_digest: plan.content_digest, grant_digest: binding.grant_digest,
    case_result_set_sha256: sha256(stable(resultSet)), evidence_manifest_sha256: manifestSha,
    evidence_sha256: evidenceSha, cleanup_status: effect.cleanup_status }, case_result_set: resultSet, evidence_manifest: manifest, evidence };
}

function validate_result(request, host) {
  const binding = admit(request, host); const id = request.execution_id;
  const claim = host.read(`fixed-browser/${id}/claim`);
  check(claim && equal(claim.binding, binding) && claim.status === 'completed', 'completion-unavailable');
  keys(claim, 'binding claim_id status completion result_ref result_sha256');
  check(claim.claim_id === id && claim.result_ref === null && claim.result_sha256 === null, 'claim-identity-invalid');
  const intent = host.read(`fixed-browser/${id}/intent`);
  keys(intent, 'binding started_at');
  check(equal(intent.binding, binding) && utc(intent.started_at), 'intent-invalid');
  const effect = host.read(`fixed-browser/${id}/effect`);
  check(effect && effect.started_at === intent.started_at, 'effect-intent-mismatch');
  const expected = project(request, binding, effect);
  check(equal(claim.completion, expected.completion), 'completion-tampered');
  for (const [file, value] of [['test-plan.json', request.plan], ['effect.json', expected.evidence],
    ['evidence-manifest.json', expected.evidence_manifest], ['case-result-set.json', expected.case_result_set]]) {
    check(host.readArtifact(`.testing/runs/${id}/${file}`) === stable(value), 'result-artifact-tampered');
  }
  return expected;
}

function run(request, host) {
  const binding = admit(request, host); const id = request.execution_id; const key = `fixed-browser/${id}`;
  return host.lock(id, () => {
    let claim = host.read(`${key}/claim`);
    if (claim) {
      check(equal(claim.binding, binding), 'execution-identity-reuse');
      if (claim.status === 'completed') return validate_result(request, host);
      keys(claim, 'binding claim_id status');
      check(claim.claim_id === id, 'claim-identity-invalid');
      check(claim.status === 'claimed', 'claim-invalid');
    } else {
      check(Date.parse(host.loadGrant(id).expires_at) > Date.now(), 'grant-expired');
      claim = { binding, claim_id: id, status: 'claimed' };
      host.immutable(`${key}/claim`, claim);
    }
    let effect = host.read(`${key}/effect`);
    const intent = host.read(`${key}/intent`);
    if (intent) { keys(intent, 'binding started_at'); check(equal(intent.binding, binding) && utc(intent.started_at), 'intent-invalid'); }
    if (effect) { check(intent && intent.started_at === effect.started_at, 'receipt-without-intent'); validateEffect(effect, binding); }
    else {
      const startedAt = intent ? intent.started_at : host.now();
      let result;
      if (intent) result = { outcome: 'lost', observed_title: null, target_status: 'unresolved', cleanup_status: host.recover(id) };
      else {
        check(Date.parse(host.loadGrant(id).expires_at) > Date.now(), 'grant-expired');
        host.immutable(`${key}/intent`, { binding, started_at: startedAt });
        result = host.browser(request.plan, id);
      }
      effect = { schema_version: `${PREFIX}effect.v1`, binding, ...result, started_at: startedAt, completed_at: host.now() };
      validateEffect(effect, binding);
      check(effect.observed_title === null || effect.observed_title === request.plan.assertion.expected
        || effect.observed_title === '[title differs]', 'unsafe-title-observation');
      host.immutable(`${key}/effect`, effect);
    }
    const result = project(request, binding, effect);
    for (const [file, value] of [['test-plan.json', request.plan], ['effect.json', result.evidence],
      ['evidence-manifest.json', result.evidence_manifest], ['case-result-set.json', result.case_result_set]]) {
      host.writeArtifact(`.testing/runs/${id}/${file}`, stable(value));
    }
    host.complete(`${key}/claim`, id, result.completion);
    return validate_result(request, host);
  });
}

module.exports = { compile, run, validate_result, stable, sha256, digest, seal, equal, check, keys };
