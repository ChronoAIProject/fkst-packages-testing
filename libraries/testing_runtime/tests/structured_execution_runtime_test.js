'use strict';

const assert = require('assert');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { sha256, stableStringify } = require('../../../packages/environment-factory/bin/runtime/common');
const { dispatch: environmentDispatch } = require('../../../packages/environment-factory/bin/environment-factory-runtime');
const { resourcePath } = require('../../../packages/environment-factory/bin/runtime/workspace');
const { dispatch, localOrigin } = require('../bin/fkst-structured-execution-runtime');

function run(argv, cwd) {
  const result = spawnSync(argv[0], argv.slice(1), { cwd, encoding: 'utf8', shell: false });
  if (result.status !== 0) throw new Error(result.stderr || `command failed: ${argv.join(' ')}`);
  return String(result.stdout || '').trim();
}

function listen() {
  return new Promise((resolve) => {
    const server = http.createServer((_request, response) => {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end('{"status":"healthy"}');
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

function copy(value) {
  return JSON.parse(JSON.stringify(value));
}

function persistJson(ref, value) {
  const raw = `${stableStringify(value)}\n`;
  fs.mkdirSync(path.dirname(ref), { recursive: true });
  fs.writeFileSync(ref, raw);
  return { raw, digest: sha256(Buffer.from(raw, 'utf8')), value };
}

function canonicalManifestDigest(value) {
  const canonical = copy(value);
  delete canonical.canonical_sha256;
  return sha256(stableStringify(canonical));
}

async function main() {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'structured-runtime-test-'));
  const previousDurable = process.env.FKST_DURABLE_ROOT;
  const previousRuntime = process.env.FKST_RUNTIME_ROOT;
  process.env.FKST_DURABLE_ROOT = path.join(temp, 'durable');
  process.env.FKST_RUNTIME_ROOT = path.join(temp, 'runtime');
  const runId = `structured-runtime-${process.pid}`;
  const artifactRoot = `.testing/runs/${runId}/execution`;
  const environmentArtifactRoot = `.testing/runs/${runId}/environment`;
  const configRef = `.testing/host/structured-execution/${runId}.json`;
  const environmentConfigRef = `.testing/host/environment-factory/${runId}.json`;
  const linkPath = `.testing/${runId}-link`;
  const source = path.join(temp, 'source');
  let workspace;
  let checkout;
  const operationId = `${runId}-operation`;
  let workspaceRef;
  const repository = { url: 'https://example.invalid/testing/runtime.git', commit_sha: '' };
  let grantSha256;
  const authority = { kind: 'policy', ref: 'runtime-test-authority' };
  const evidenceRef = { kind: 'attestation', ref: 'runtime-test-grant' };
  let server;

  fs.rmSync(`.testing/runs/${runId}`, { recursive: true, force: true });
  fs.rmSync(configRef, { force: true });
  try {
    fs.mkdirSync(source, { recursive: true });
    run(['git', 'init', '--quiet'], source);
    run(['git', 'config', 'user.email', 'runtime-test@example.invalid'], source);
    run(['git', 'config', 'user.name', 'Runtime Test'], source);
    fs.writeFileSync(path.join(source, 'marker.txt'), 'committed\n');
    run(['git', 'add', 'marker.txt'], source);
    run(['git', 'commit', '--quiet', '-m', 'fixture'], source);
    repository.commit_sha = run(['git', 'rev-parse', 'HEAD'], source);

    fs.mkdirSync(path.dirname(environmentConfigRef), { recursive: true });
    fs.writeFileSync(environmentConfigRef, `${stableStringify({
      schema: 'environment-factory.runtime-config.v1',
      state_auth_key: 'environment-runtime-test-state-key-00000000000000000000',
      state_mac_generation: 'environment-runtime-test-v1',
      repository_mirrors: { [repository.url]: source },
      command_environment: {},
    })}\n`);
    checkout = await environmentDispatch('checkout', {
      effect_id: `${operationId}/checkout`,
      operation_id: operationId,
      repository,
      working_directory: '.',
      artifact_root: environmentArtifactRoot,
      runtime_config_ref: { kind: 'artifact', ref: environmentConfigRef },
      timeout_seconds: 20,
      output_bytes: 65536,
      resource_budgets: {
        cpu_millis: 60000, memory_mb: 256, disk_mb: 128,
        processes: 8, network_requests: 0, output_bytes: 65536,
      },
    });
    assert.strictEqual(checkout.status, 'passed');
    workspaceRef = checkout.workspace_ref;
    workspace = JSON.parse(fs.readFileSync(resourcePath(workspaceRef.ref), 'utf8')).path;

    const traceId = `${runId}-trace`;
    const dedupKey = `${runId}-dedup`;
    const expiresAt = new Date(Date.now() + 60 * 60 * 1000).toISOString();
    const authorityRoot = `.testing/runs/${runId}/authorization`;
    const writeAuthority = (name, value) => {
      const ref = `${authorityRoot}/${name}.json`;
      const body = `${stableStringify(value)}\n`;
      fs.mkdirSync(path.dirname(ref), { recursive: true });
      fs.writeFileSync(ref, body);
      return { ref, digest: sha256(body), value };
    };
    const profile = writeAuthority('profile', {
      schema: 'testing-project-profile.v1', revision: 'runtime-profile-v1', repository,
      working_directory: '.', mutation_policy: { mode: 'read-only' },
      resource_budgets: { output_bytes: 65536 },
    });
    const validation = writeAuthority('validation', {
      schema: 'testing-project-profile-validation-receipt.v1', profile_revision: 'runtime-profile-v1',
      profile_sha256: sha256(stableStringify(profile.value)), repository, trace_id: traceId, dedup_key: dedupKey,
    });
    const preauthorization = writeAuthority('preauthorization', {
      schema: 'testing-structured-execution-authorization.v1', profile_sha256: validation.value.profile_sha256,
      repository, capabilities: { cli: [{ argv_prefix: [process.execPath] }], http: [] },
      trace_id: traceId, dedup_key: dedupKey,
    });
    const environment = writeAuthority('environment', {
      schema: 'environment-factory.receipt.v2', status: 'ready', operation_id: operationId,
      profile_sha256: validation.value.profile_sha256, repository, workspace_ref: workspaceRef,
      trace_id: traceId, dedup_key: dedupKey,
    });
    const cliCase = {
      case_id: 'cli-version', kind: 'cli',
      argv: [process.execPath, '-e', 'process.stdout.write(process.cwd())'], timeout_seconds: 10,
      assertions: [{ type: 'exit-code', expected: 0 }],
    };
    const plan = writeAuthority('plan', {
      schema: 'testing-structured-plan.v2', execution_mode: 'structured-api-cli', repository,
      environment_receipt_sha256: environment.digest, cases: [cliCase],
      trace_id: traceId, dedup_key: dedupKey,
    });
    const grant = writeAuthority('grant', {
      schema: 'testing-structured-execution-grant.v1', grant_id: `${runId}-effect-grant`,
      parent_authorization_sha256: preauthorization.digest, plan_sha256: plan.digest,
      environment_receipt_sha256: environment.digest, repository,
      cli_capabilities: [{ argv_prefix: [process.execPath] }], authority,
      policy_revision: 'runtime-test-policy-v1', evidence_ref: evidenceRef,
      expires_at: expiresAt, max_uses: 1, trace_id: traceId, dedup_key: dedupKey,
    });
    grantSha256 = grant.digest;

    fs.mkdirSync(path.dirname(configRef), { recursive: true });
    fs.writeFileSync(configRef, `${stableStringify({
      schema: 'testing-runtime.structured-execution-config.v1',
      state_auth_key: 'structured-runtime-test-state-key-00000000000000000000',
      state_mac_generation: 'runtime-test-v1', command_environment: {},
      output_bytes: 65536, http_response_bytes: 65536,
      grant_attestations: [{ grant_sha256: grantSha256, authority,
        policy_revision: 'runtime-test-policy-v1', evidence_ref: evidenceRef }],
    })}\n`);

    const common = {
      artifact_root: artifactRoot, operation_id: operationId, repository,
      environment_receipt_sha256: environment.digest,
      trace_id: traceId, dedup_key: dedupKey,
      runtime_config_ref: { kind: 'artifact', ref: configRef },
    };

    assert.strictEqual((await dispatch('sha256-bytes', { bytes: 'abc' })).sha256, sha256('abc'));
    await assert.rejects(() => dispatch('sha256-bytes', { bytes: 'abc', extra: true }),
      /payload fields are invalid/);
    await assert.rejects(() => dispatch('sha256-bytes', {
      bytes: String.fromCharCode(0xe9).repeat(524289),
    }),
      /no larger than 1 MiB/);
    await assert.rejects(() => dispatch('sha256-bytes', { bytes: Buffer.from('abc') }),
      /requires a string/);

    const nowValue = (await dispatch('now', common)).now;
    assert.match(nowValue, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    const currentTime = Date.parse(nowValue);
    assert.ok(Math.abs(currentTime - Date.now()) < 10_000);
    assert.strictEqual(localOrigin('http://[::1]:4173/health'), 'http://[::1]:4173');
    const attestation = await dispatch('verify-grant', {
      ...common,
      grant_sha256: grantSha256,
      grant: { authority, policy_revision: 'runtime-test-policy-v1', evidence_ref: evidenceRef },
    });
    assert.strictEqual(attestation.grant_sha256, grantSha256);

    const effectClaim = await dispatch('replay-guard', {
      ...common, grant_id: grant.value.grant_id, grant_sha256: grant.digest,
      parent_authorization_sha256: preauthorization.digest, plan_sha256: plan.digest,
      environment_receipt_sha256: environment.digest,
    });
    const actionEnvelope = {
      schema: 'testing-cli-action-envelope.v1', effect_kind: 'cli', capability: 'direct-argv',
      profile_ref: profile.ref, profile_artifact_sha256: profile.digest,
      profile_sha256: validation.value.profile_sha256,
      validation_receipt_ref: validation.ref, validation_receipt_sha256: validation.digest,
      preauthorization_ref: preauthorization.ref, preauthorization_sha256: preauthorization.digest,
      repository, run_id: operationId, operation_id: operationId,
      environment_receipt_ref: environment.ref, environment_receipt_sha256: environment.digest,
      workspace_ref: workspaceRef, plan_ref: plan.ref, plan_sha256: plan.digest,
      grant_ref: grant.ref, grant_sha256: grant.digest, case: cliCase,
      resource_bounds: { output_bytes: 65536 }, attempt: 1,
      trace_id: traceId, dedup_key: dedupKey, expires_at: expiresAt,
      fence_id: effectClaim.claim_id,
    };
    const authorization = await dispatch('authorize-cli-effect', {
      ...common, action_envelope: actionEnvelope,
    });
    assert.strictEqual(authorization.decision, 'allow');
    assert.match(authorization.issued_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    const cli = await dispatch('exec-argv', {
      ...common, action_envelope: actionEnvelope, authorization_receipt: authorization,
    });
    assert.strictEqual(cli.exit_code, 0);
    assert.strictEqual(cli.stdout, fs.realpathSync(workspace));
    await assert.rejects(() => dispatch('exec-argv', {
      ...common, action_envelope: actionEnvelope, authorization_receipt: authorization,
    }), /replayed or is unavailable/);
    const foreignEnvelope = { ...actionEnvelope, plan_sha256: '0'.repeat(64) };
    const denied = await dispatch('authorize-cli-effect', {
      ...common, action_envelope: foreignEnvelope,
    });
    assert.strictEqual(denied.decision, 'deny');
    await assert.rejects(() => dispatch('exec-argv', {
      ...common, action_envelope: foreignEnvelope, authorization_receipt: denied,
    }), /missing, denied, malformed, expired, or foreign/);

    server = await listen();
    const address = server.address();
    const baseUrl = `http://127.0.0.1:${address.port}/health`;
    const response = await dispatch('http-request', {
      ...common,
      base_url: baseUrl,
      request: { method: 'GET', url: baseUrl, headers: [] },
      timeout_seconds: 10,
    });
    assert.strictEqual(response.status, 200);
    assert.match(response.body, /healthy/);
    await assert.rejects(() => dispatch('http-request', {
      ...common,
      base_url: baseUrl,
      request: { method: 'GET', url: 'http://example.invalid/health', headers: [] },
      timeout_seconds: 10,
    }), /loopback HTTP/);

    fs.symlinkSync(temp, linkPath);
    await assert.rejects(() => dispatch('write-artifact', {
      ...common,
      artifact_ref: { kind: 'artifact', ref: `${linkPath}/escape.json` },
      value: { escaped: true },
    }), /symbolic link/);
    fs.rmSync(linkPath, { force: true });

    const resultRef = `${artifactRoot}/execution.json`;
    const historicalExecution = {
      schema: 'testing-structured-execution.v1', operation_id: operationId,
      status: 'passed', classification: 'passed', repository,
      environment_receipt_sha256: common.environment_receipt_sha256,
      trace_id: common.trace_id, dedup_key: common.dedup_key,
      case_count: 1, passed_count: 1, failed_count: 0, skipped_count: 0, error_count: 0,
      test_plan_path: `${artifactRoot}/test-plan.json`,
      case_results_path: `${artifactRoot}/case-results.json`, execution_path: resultRef,
    };
    assert.strictEqual((await dispatch('write-artifact', {
      ...common,
      artifact_ref: { kind: 'artifact', ref: resultRef },
      value: historicalExecution,
    })).written, true);
    assert.strictEqual((await dispatch('load-artifact', {
      ...common, artifact_ref: { kind: 'artifact', ref: resultRef },
    })).value.status, 'passed');

    const historicalClaimRequest = {
      ...common,
      grant_id: `${runId}-historical-grant`,
      grant_sha256: grantSha256,
      parent_authorization_sha256: 'c'.repeat(64),
      plan_sha256: 'd'.repeat(64),
    };
    const historicalClaim = await dispatch('replay-guard', historicalClaimRequest);
    assert.strictEqual(historicalClaim.status, 'claimed');
    assert.strictEqual((await dispatch('replay-guard', historicalClaimRequest)).status, 'in-progress');
    await assert.rejects(() => dispatch('replay-guard', {
      ...historicalClaimRequest, artifact_root: `.testing/runs/${runId}-foreign/execution`,
    }), /replay binding differs/);
    const historicalCompletion = await dispatch('complete-replay', {
      ...common, claim: historicalClaim, result_ref: resultRef,
    });
    assert.strictEqual(historicalCompletion.completed, true);
    const historicalReplay = await dispatch('replay-guard', historicalClaimRequest);
    assert.strictEqual(historicalReplay.status, 'completed');
    const historicalSummary = await dispatch('load-result', {
      ...common, result_ref: resultRef, result_sha256: historicalReplay.result_sha256,
    });
    assert.strictEqual(historicalSummary.passed_count, 1);
    assert.strictEqual(Object.prototype.hasOwnProperty.call(
      historicalSummary, 'case_result_set_path'), false);
    assert.strictEqual(Object.prototype.hasOwnProperty.call(
      historicalSummary, 'evidence_manifest_path'), false);

    const caseResultSetPath = `${artifactRoot}/case-result-set.json`;
    const evidenceManifestPath = `${artifactRoot}/evidence-manifest.json`;
    const evidencePath = `${artifactRoot}/evidence/not-written.json`;
    const canonicalPlanSha256 = plan.digest;
    const canonicalPlanArtifact = persistJson(historicalExecution.test_plan_path, plan.value);
    assert.strictEqual(canonicalPlanArtifact.digest, canonicalPlanSha256);
    const canonicalRepository = {
      id: repository.commit_sha,
      source_ref: { kind: 'git', ref: `${repository.url}@${repository.commit_sha}` },
      source_sha256: sha256(`${repository.url}\n${repository.commit_sha}`),
    };
    const planRef = { kind: 'artifact', ref: historicalExecution.test_plan_path };
    const evidencePointer = { kind: 'evidence', ref: 'evidence-cli-version' };
    const manifest = {
      schema: 'testing-evidence-manifest.v1', manifest_id: operationId,
      canonicalization: 'fkst-testing-evidence-manifest-canonical-json.v1',
      canonical_sha256: '0'.repeat(64), repository: copy(canonicalRepository),
      run_id: operationId, plan_ref: copy(planRef), plan_sha256: canonicalPlanSha256,
      entries: [{
        evidence_id: evidencePointer.ref, case_id: cliCase.case_id, assertion_id: 'assertion-1',
        role: 'runner-log', artifact_ref: { kind: 'artifact', ref: evidencePath },
        sha256: sha256('not persisted'), media_type: 'text/plain', size_bytes: 13,
        producer: 'testing-runner', producer_version: 'v1', created_at: '2026-07-24T00:00:00Z',
        sensitivity: 'internal', redaction_classification: 'none', policy_version: 'v1',
        policy_status: 'approved', provenance: {
          source_kind: 'artifact', source_ref: evidencePath, source_sha256: sha256('not persisted'),
        },
      }],
    };
    manifest.canonical_sha256 = canonicalManifestDigest(manifest);
    const resultSet = {
      schema: 'testing-case-result-set.v2', set_id: operationId, run_id: operationId,
      plan_ref: copy(planRef), plan_sha256: canonicalPlanSha256,
      cases: [{
        schema: 'testing-case-result.v2', case_id: cliCase.case_id,
        repository: copy(canonicalRepository), reviewed_case_id: cliCase.case_id,
        plan_ref: copy(planRef), plan_sha256: canonicalPlanSha256, execution_mode: 'cli',
        execution_status: 'passed', classification: 'deterministic', observations: [],
        assertions: [{
          schema: 'testing-assertion-result.v1', assertion_id: 'assertion-1',
          type: 'exit-code', required: true, status: 'passed', classification: 'deterministic',
          observation_ids: [], evidence_refs: [copy(evidencePointer)],
        }],
        evidence_refs: [copy(evidencePointer)], timing: {
          started_at: '2026-07-24T00:00:00Z', completed_at: '2026-07-24T00:00:00Z', duration_ms: 0,
        },
        trace_id: common.trace_id, dedup_key: common.dedup_key,
      }],
      evidence_manifest_ref: { kind: 'artifact', ref: evidenceManifestPath },
      evidence_manifest_sha256: manifest.canonical_sha256,
      trace_id: common.trace_id, dedup_key: common.dedup_key,
    };
    const validManifestArtifact = persistJson(evidenceManifestPath, manifest);
    resultSet.evidence_manifest_ref.sha256 = validManifestArtifact.digest;
    resultSet.evidence_manifest_artifact_sha256 = validManifestArtifact.digest;
    const validResultSetArtifact = persistJson(caseResultSetPath, resultSet);
    const canonicalExecution = {
      ...historicalExecution,
      plan_sha256: canonicalPlanSha256,
      case_result_set_path: caseResultSetPath,
      case_result_set_artifact_sha256: validResultSetArtifact.digest,
      evidence_manifest_path: evidenceManifestPath,
      evidence_manifest_artifact_sha256: validManifestArtifact.digest,
    };
    const canonicalClaimRequest = {
      ...common,
      grant_sha256: grantSha256,
      parent_authorization_sha256: 'c'.repeat(64),
      plan_sha256: canonicalPlanSha256,
    };
    const claimCanonical = async (name) => dispatch('replay-guard', {
      ...canonicalClaimRequest, grant_id: `${runId}-${name}`,
    });
    const rejectCompletion = async (name, pattern) => {
      const candidateClaim = await claimCanonical(name);
      await assert.rejects(() => dispatch('complete-replay', {
        ...common, claim: candidateClaim, result_ref: resultRef,
      }), pattern);
    };

    for (const field of [
      'case_result_set_path', 'case_result_set_artifact_sha256',
      'evidence_manifest_path', 'evidence_manifest_artifact_sha256',
    ]) {
      const partial = { ...canonicalExecution };
      delete partial[field];
      persistJson(resultRef, partial);
      await rejectCompletion(`partial-${field}`, /canonical artifact group is invalid/);
    }

    persistJson(caseResultSetPath, { ...resultSet, set_id: 'tampered-before-completion' });
    persistJson(resultRef, canonicalExecution);
    await rejectCompletion('tampered-set-digest', /case result set artifact digest differs/);
    persistJson(caseResultSetPath, resultSet);

    persistJson(evidenceManifestPath, { ...manifest, manifest_id: 'tampered-before-completion' });
    persistJson(resultRef, canonicalExecution);
    await rejectCompletion('tampered-manifest-digest', /evidence manifest artifact digest differs/);
    persistJson(evidenceManifestPath, manifest);

    const foreignSetArtifact = persistJson(caseResultSetPath, {
      ...resultSet, run_id: 'foreign-operation',
    });
    persistJson(resultRef, {
      ...canonicalExecution, case_result_set_artifact_sha256: foreignSetArtifact.digest,
    });
    await rejectCompletion('foreign-set', /case result set binding is invalid/);
    persistJson(caseResultSetPath, resultSet);

    const foreignManifestArtifact = persistJson(evidenceManifestPath, {
      ...manifest, run_id: 'foreign-operation',
    });
    const foreignManifestSetArtifact = persistJson(caseResultSetPath, {
      ...resultSet,
      evidence_manifest_ref: { ...resultSet.evidence_manifest_ref, sha256: foreignManifestArtifact.digest },
      evidence_manifest_artifact_sha256: foreignManifestArtifact.digest,
    });
    persistJson(resultRef, {
      ...canonicalExecution,
      case_result_set_artifact_sha256: foreignManifestSetArtifact.digest,
      evidence_manifest_artifact_sha256: foreignManifestArtifact.digest,
    });
    await rejectCompletion('foreign-manifest', /evidence manifest binding is invalid/);

    const invalidCanonicalManifestArtifact = persistJson(evidenceManifestPath, {
      ...manifest, canonical_sha256: 'f'.repeat(64),
    });
    const invalidCanonicalSetArtifact = persistJson(caseResultSetPath, {
      ...resultSet,
      evidence_manifest_ref: {
        ...resultSet.evidence_manifest_ref, sha256: invalidCanonicalManifestArtifact.digest,
      },
      evidence_manifest_sha256: 'f'.repeat(64),
      evidence_manifest_artifact_sha256: invalidCanonicalManifestArtifact.digest,
    });
    persistJson(resultRef, {
      ...canonicalExecution,
      case_result_set_artifact_sha256: invalidCanonicalSetArtifact.digest,
      evidence_manifest_artifact_sha256: invalidCanonicalManifestArtifact.digest,
    });
    await rejectCompletion('invalid-canonical-manifest', /canonical digest differs/);

    const foreignCanonicalRepository = {
      id: 'f'.repeat(40), source_ref: { kind: 'git', ref: 'https://foreign.invalid/repo.git@foreign' },
      source_sha256: 'e'.repeat(64),
    };
    const foreignRepositoryManifest = {
      ...manifest, repository: foreignCanonicalRepository,
      entries: manifest.entries.map((entry) => ({ ...entry })),
    };
    foreignRepositoryManifest.canonical_sha256 = canonicalManifestDigest(foreignRepositoryManifest);
    const foreignRepositoryManifestArtifact = persistJson(evidenceManifestPath, foreignRepositoryManifest);
    const foreignRepositorySetArtifact = persistJson(caseResultSetPath, {
      ...resultSet,
      cases: resultSet.cases.map((item) => ({ ...item, repository: foreignCanonicalRepository })),
      evidence_manifest_ref: {
        ...resultSet.evidence_manifest_ref, sha256: foreignRepositoryManifestArtifact.digest,
      },
      evidence_manifest_sha256: foreignRepositoryManifest.canonical_sha256,
      evidence_manifest_artifact_sha256: foreignRepositoryManifestArtifact.digest,
    });
    persistJson(resultRef, {
      ...canonicalExecution,
      case_result_set_artifact_sha256: foreignRepositorySetArtifact.digest,
      evidence_manifest_artifact_sha256: foreignRepositoryManifestArtifact.digest,
    });
    await rejectCompletion('foreign-canonical-repository', /evidence manifest binding is invalid/);

    persistJson(evidenceManifestPath, manifest);
    const malformedReferenceSetArtifact = persistJson(caseResultSetPath, {
      ...resultSet,
      cases: resultSet.cases.map((item) => ({ ...item, evidence_refs: [{ kind: 'evidence' }] })),
    });
    persistJson(resultRef, {
      ...canonicalExecution, case_result_set_artifact_sha256: malformedReferenceSetArtifact.digest,
    });
    await rejectCompletion('malformed-case-evidence', /canonical case binding is invalid/);

    const contradictoryCaseSetArtifact = persistJson(caseResultSetPath, {
      ...resultSet,
      cases: resultSet.cases.map((item) => ({ ...item, classification: 'assertion_failure' })),
    });
    persistJson(resultRef, {
      ...canonicalExecution, case_result_set_artifact_sha256: contradictoryCaseSetArtifact.digest,
    });
    await rejectCompletion('contradictory-case-outcome', /canonical case outcome is invalid/);

    const malformedManifestArtifact = persistJson(evidenceManifestPath, {
      ...manifest, entries: {},
    });
    const malformedManifestSetArtifact = persistJson(caseResultSetPath, {
      ...resultSet,
      evidence_manifest_ref: { ...resultSet.evidence_manifest_ref, sha256: malformedManifestArtifact.digest },
      evidence_manifest_artifact_sha256: malformedManifestArtifact.digest,
    });
    persistJson(resultRef, {
      ...canonicalExecution,
      case_result_set_artifact_sha256: malformedManifestSetArtifact.digest,
      evidence_manifest_artifact_sha256: malformedManifestArtifact.digest,
    });
    await rejectCompletion('malformed-manifest', /evidence manifest binding is invalid/);

    persistJson(evidenceManifestPath, manifest);
    persistJson(caseResultSetPath, resultSet);
    const canonicalExecutionArtifact = persistJson(resultRef, canonicalExecution);
    assert.strictEqual(fs.existsSync(evidencePath), false);
    const canonicalClaim = await claimCanonical('canonical-grant');
    const completion = await dispatch('complete-replay', {
      ...common, claim: canonicalClaim, result_ref: resultRef,
    });
    assert.strictEqual(completion.completed, true);
    assert.strictEqual(completion.result_sha256, canonicalExecutionArtifact.digest);
    const replay = await dispatch('replay-guard', {
      ...canonicalClaimRequest, grant_id: `${runId}-canonical-grant`,
    });
    assert.strictEqual(replay.status, 'completed');
    assert.strictEqual(replay.result_ref, resultRef);
    assert.strictEqual(replay.result_sha256, completion.result_sha256);
    const summary = await dispatch('load-result', {
      ...common, result_ref: resultRef, result_sha256: replay.result_sha256,
    });
    assert.strictEqual(summary.passed_count, 1);
    assert.strictEqual(summary.case_result_set_path, caseResultSetPath);
    assert.strictEqual(summary.case_result_set_artifact_sha256, validResultSetArtifact.digest);
    assert.strictEqual(summary.evidence_manifest_path, evidenceManifestPath);
    assert.strictEqual(summary.evidence_manifest_artifact_sha256, validManifestArtifact.digest);
    assert.strictEqual(fs.existsSync(evidencePath), false);
    assert.strictEqual(fs.readFileSync(resultRef, 'utf8'), canonicalExecutionArtifact.raw);
    assert.strictEqual(fs.readFileSync(caseResultSetPath, 'utf8'), validResultSetArtifact.raw);
    assert.strictEqual(fs.readFileSync(evidenceManifestPath, 'utf8'), validManifestArtifact.raw);

    persistJson(caseResultSetPath, { ...resultSet, set_id: 'tampered-after-completion' });
    await assert.rejects(() => dispatch('load-result', {
      ...common, result_ref: resultRef, result_sha256: replay.result_sha256,
    }), /case result set artifact digest differs/);
    persistJson(caseResultSetPath, resultSet);
    persistJson(evidenceManifestPath, { ...manifest, manifest_id: 'tampered-after-completion' });
    await assert.rejects(() => dispatch('load-result', {
      ...common, result_ref: resultRef, result_sha256: replay.result_sha256,
    }), /evidence manifest artifact digest differs/);
    persistJson(evidenceManifestPath, manifest);
    fs.writeFileSync(resultRef, '{}\n');
    await assert.rejects(() => dispatch('load-result', {
      ...common, result_ref: resultRef, result_sha256: replay.result_sha256,
    }), /digest differs/);

    const cleaned = await environmentDispatch('cleanup', {
      effect_id: `${operationId}/cleanup/workspace`,
      operation_id: operationId,
      artifact_root: environmentArtifactRoot,
      cleanup_ref: checkout.cleanup_ref,
      workspace_ref: workspaceRef,
      working_directory: '.',
      runtime_config_ref: { kind: 'artifact', ref: environmentConfigRef },
      timeout_seconds: 10,
    });
    assert.strictEqual(cleaned.status, 'cleaned');
    assert.strictEqual(fs.existsSync(workspace), false);
    await assert.rejects(() => dispatch('exec-argv', {
      ...common,
    }), /fields are invalid|malformed/);
  } finally {
    if (server) await new Promise((resolve) => server.close(resolve));
    if (previousDurable === undefined) delete process.env.FKST_DURABLE_ROOT;
    else process.env.FKST_DURABLE_ROOT = previousDurable;
    if (previousRuntime === undefined) delete process.env.FKST_RUNTIME_ROOT;
    else process.env.FKST_RUNTIME_ROOT = previousRuntime;
    fs.rmSync(`.testing/runs/${runId}`, { recursive: true, force: true });
    fs.rmSync(linkPath, { force: true });
    fs.rmSync(configRef, { force: true });
    fs.rmSync(environmentConfigRef, { force: true });
    fs.rmSync(temp, { recursive: true, force: true });
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
