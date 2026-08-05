'use strict';

const assert = require('assert');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const {
  processStartIdentity,
  sha256,
  stableStringify,
} = require('../../../packages/environment-factory/bin/runtime/common');
const { dispatch: environmentDispatch } = require('../../../packages/environment-factory/bin/environment-factory-runtime');
const {
  listenerOwners,
  processGroupState,
} = require('../../../packages/environment-factory/bin/runtime/platform');
const { resourcePath } = require('../../../packages/environment-factory/bin/runtime/workspace');
const { dispatch, localOrigin } = require('../bin/fkst-structured-execution-runtime');

function run(argv, cwd) {
  const result = spawnSync(argv[0], argv.slice(1), { cwd, encoding: 'utf8', shell: false });
  if (result.status !== 0) throw new Error(result.stderr || `command failed: ${argv.join(' ')}`);
  return String(result.stdout || '').trim();
}

function listen() {
  return new Promise((resolve) => {
    const server = http.createServer((request, response) => {
      server.requestCount += 1;
      server.lastMethod = request.method;
      server.lastUrl = request.url;
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end('{"status":"healthy"}');
    });
    server.requestCount = 0;
    server.lastMethod = null;
    server.lastUrl = null;
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
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
    server = await listen();
    const address = server.address();
    const readyOrigin = `http://127.0.0.1:${address.port}`;
    const baseUrl = `${readyOrigin}/health`;
    const pgid = Number(run(['ps', '-o', 'pgid=', '-p', String(process.pid)]));
    const startIdentity = processStartIdentity(process.pid);
    assert.ok(Number.isInteger(pgid) && pgid > 0);
    assert.ok(typeof startIdentity === 'string' && startIdentity !== '');
    const processResourceRef = `${operationId}-application-process`;
    const processResource = {
      schema: 'environment-factory.resource.v1', kind: 'process', ref: processResourceRef,
      operation_id: operationId, runtime_ports: [{ name: 'application', port: address.port }],
      pid: process.pid, pgid, process_start_identity: startIdentity,
      ownership_token: `${operationId}-listener-owner`, cleaned: false,
    };
    fs.writeFileSync(resourcePath(processResourceRef), `${stableStringify(processResource)}\n`);
    const processState = processGroupState(processResource);
    assert.ok(processState.supported && processState.alive && !processState.foreign,
      JSON.stringify(processState));
    const listenerOwnership = listenerOwners(address.port);
    assert.ok(listenerOwnership.supported && listenerOwnership.pids.length === 1
      && listenerOwnership.pids[0] === process.pid, JSON.stringify(listenerOwnership));

    const traceId = `${runId}-trace`;
    const dedupKey = `${runId}-dedup`;
    const issuedAt = new Date(Date.now() - 60 * 1000).toISOString();
    const expiresAt = new Date(Date.now() + 60 * 60 * 1000).toISOString();
    const caseCatalogSha256 = 'e'.repeat(64);
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
      allowed_origins: [readyOrigin], timeouts: { receipt_ttl_seconds: 300 },
      resource_budgets: { network_requests: 1, output_bytes: 65536 },
    });
    const profileApprovalEvidence = { kind: 'attestation', ref: 'runtime-profile-approval' };
    const approval = writeAuthority('approval', {
      schema: 'testing-project-profile-approval.v1', approval_id: `${runId}-profile-approval`,
      canonicalization: 'fkst-project-profile-canonical-json.v1',
      profile_sha256: sha256(stableStringify(profile.value)), repository, authority,
      policy_revision: 'runtime-profile-policy-v1', evidence_ref: profileApprovalEvidence,
      issued_at: issuedAt, expires_at: expiresAt, max_uses: 1, trace_id: traceId, dedup_key: dedupKey,
    });
    const validation = writeAuthority('validation', {
      schema: 'testing-project-profile-validation-receipt.v1',
      profile_schema: 'testing-project-profile.v1', profile_revision: 'runtime-profile-v1',
      canonicalization: 'fkst-project-profile-canonical-json.v1',
      profile_sha256: approval.value.profile_sha256, repository,
      approval_ref: { kind: 'artifact', ref: approval.ref }, approval_id: approval.value.approval_id,
      approval_sha256: sha256(stableStringify(approval.value)), authority,
      policy_revision: approval.value.policy_revision, evidence_ref: profileApprovalEvidence,
      issued_at: issuedAt, trace_id: traceId, dedup_key: dedupKey,
    });
    const httpCapability = { origin: readyOrigin, methods: ['POST'], path_prefixes: ['/api/'] };
    const preauthorization = writeAuthority('preauthorization', {
      schema: 'testing-structured-execution-authorization.v1',
      authorization_id: `${runId}-authorization`, repository,
      profile_sha256: validation.value.profile_sha256, case_catalog_sha256: caseCatalogSha256,
      capabilities: { cli: [{ argv_prefix: [process.execPath] }], http: [httpCapability] },
      authority, policy_revision: 'runtime-test-policy-v1',
      evidence_ref: { kind: 'attestation', ref: 'runtime-test-preauthorization' },
      issued_at: issuedAt, expires_at: expiresAt, max_uses: 1,
      trace_id: traceId, dedup_key: dedupKey,
    });
    const environment = writeAuthority('environment', {
      schema: 'environment-factory.receipt.v2', status: 'ready', operation_id: operationId,
      profile_sha256: validation.value.profile_sha256, repository, workspace_ref: workspaceRef,
      base_url: baseUrl, runtime_ports: [{ name: 'application', port: address.port }],
      trace_id: traceId, dedup_key: dedupKey,
    });
    const cliCase = {
      case_id: 'cli-version', kind: 'cli',
      argv: [process.execPath, '-e', 'process.stdout.write(process.cwd())'], timeout_seconds: 10,
      assertions: [{ type: 'exit-code', expected: 0 }],
    };
    const httpCase = {
      case_id: 'api-probe', kind: 'http',
      request: { method: 'POST', url: `${readyOrigin}/api/probe`, headers: [] }, timeout_seconds: 10,
      assertions: [
        { type: 'status-code', expected: 200 },
        { type: 'body-contains', expected: 'healthy' },
      ],
    };
    const listenerLossCase = { ...httpCase, case_id: 'health-listener-loss' };
    const plan = writeAuthority('plan', {
      schema: 'testing-structured-plan.v2', repository,
      environment_receipt_sha256: environment.digest, case_catalog_sha256: caseCatalogSha256,
      cases: [cliCase, httpCase, listenerLossCase], trace_id: traceId, dedup_key: dedupKey,
    });
    const grant = writeAuthority('grant', {
      schema: 'testing-structured-execution-grant.v1', grant_id: `${runId}-effect-grant`,
      parent_authorization_sha256: preauthorization.digest, plan_sha256: plan.digest,
      environment_receipt_sha256: environment.digest, repository,
      cli_capabilities: [{ argv_prefix: [process.execPath] }], http_capabilities: [httpCapability], authority,
      policy_revision: 'runtime-test-policy-v1', evidence_ref: evidenceRef,
      issued_at: issuedAt, expires_at: expiresAt, max_uses: 1,
      trace_id: traceId, dedup_key: dedupKey,
    });
    const foreignReplayGrant = writeAuthority('foreign-replay-grant', {
      ...grant.value,
      grant_id: `${runId}-foreign-replay-grant`,
    });
    grantSha256 = grant.digest;
    const invalidAuthorizationChains = [
      {
        name: 'expired',
        value: { ...preauthorization.value,
          issued_at: '2020-01-01T00:00:00Z', expires_at: '2020-01-01T01:00:00Z' },
      },
      { name: 'multi-use', value: { ...preauthorization.value, max_uses: 2 } },
      {
        name: 'unknown-preauthorization-http-field',
        value: {
          ...preauthorization.value,
          capabilities: {
            ...preauthorization.value.capabilities,
            http: [{ ...httpCapability, unexpected: true }],
          },
        },
      },
      {
        name: 'unknown-grant-http-method',
        value: preauthorization.value,
        grantValue: {
          ...grant.value,
          http_capabilities: [{ ...httpCapability, methods: ['POST', 'TRACE'] }],
        },
      },
    ].map(({ name, value, grantValue }) => {
      const invalidPreauthorization = writeAuthority(`${name}-preauthorization`, value);
      const invalidGrant = writeAuthority(`${name}-grant`, {
        ...(grantValue || grant.value),
        parent_authorization_sha256: invalidPreauthorization.digest,
      });
      return { name, preauthorization: invalidPreauthorization, grant: invalidGrant };
    });

    fs.mkdirSync(path.dirname(configRef), { recursive: true });
    fs.writeFileSync(configRef, `${stableStringify({
      schema: 'testing-runtime.structured-execution-config.v1',
      state_auth_key: 'structured-runtime-test-state-key-00000000000000000000',
      state_mac_generation: 'runtime-test-v1', command_environment: {},
      output_bytes: 65536, http_response_bytes: 65536,
      profile_approval_attestations: [{
        approval_sha256: validation.value.approval_sha256, authority,
        policy_revision: approval.value.policy_revision, evidence_ref: profileApprovalEvidence,
      }],
      grant_attestations: [grant, foreignReplayGrant,
        ...invalidAuthorizationChains.map((chain) => chain.grant)].map((entry) => ({
        grant_sha256: entry.digest, authority,
        policy_revision: 'runtime-test-policy-v1', evidence_ref: evidenceRef,
      })),
    })}\n`);

    const common = {
      artifact_root: artifactRoot, operation_id: operationId, repository,
      environment_receipt_sha256: environment.digest,
      trace_id: traceId, dedup_key: dedupKey,
      runtime_config_ref: { kind: 'artifact', ref: configRef },
    };

    const currentTime = Date.parse((await dispatch('now', common)).now);
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

    const httpEnvelope = {
      schema: 'testing-action-envelope.v1', effect_kind: 'http', capability: 'direct-loopback-http',
      profile_ref: profile.ref, profile_artifact_sha256: profile.digest,
      profile_sha256: validation.value.profile_sha256,
      validation_receipt_ref: validation.ref, validation_receipt_sha256: validation.digest,
      preauthorization_ref: preauthorization.ref, preauthorization_sha256: preauthorization.digest,
      repository, run_id: operationId, operation_id: operationId,
      environment_receipt_ref: environment.ref, environment_receipt_sha256: environment.digest,
      workspace_ref: workspaceRef, ready_origin: readyOrigin,
      plan_ref: plan.ref, plan_sha256: plan.digest,
      grant_ref: grant.ref, grant_sha256: grant.digest,
      effect: {
        kind: 'http', case_id: httpCase.case_id, origin: readyOrigin,
        host: '127.0.0.1', port: address.port, method: 'POST', path: '/api/probe', headers: [],
        redirect_mode: 'error', proxy_mode: 'disabled', address_mode: 'numeric-loopback',
        timeout_seconds: httpCase.timeout_seconds, assertions: httpCase.assertions,
      },
      resource_bounds: { network_requests: 1, output_bytes: 65536 }, attempt: 1,
      trace_id: traceId, dedup_key: dedupKey, expires_at: expiresAt,
      fence_id: effectClaim.claim_id,
    };
    const foreignReplayClaim = await dispatch('replay-guard', {
      ...common,
      grant_id: foreignReplayGrant.value.grant_id,
      grant_sha256: foreignReplayGrant.digest,
      parent_authorization_sha256: preauthorization.digest,
      plan_sha256: plan.digest,
      environment_receipt_sha256: environment.digest,
      trace_id: `${traceId}-foreign-replay`,
    });
    const foreignReplayEnvelope = {
      ...httpEnvelope,
      grant_ref: foreignReplayGrant.ref,
      grant_sha256: foreignReplayGrant.digest,
      fence_id: foreignReplayClaim.claim_id,
    };
    const foreignReplayAuthorization = await dispatch('authorize-effect', {
      ...common, action_envelope: foreignReplayEnvelope,
    });
    assert.strictEqual(foreignReplayAuthorization.decision, 'deny');
    assert.strictEqual(foreignReplayAuthorization.reason_code, 'foreign-fence');
    await assert.rejects(() => dispatch('http-request', {
      ...common,
      action_envelope: foreignReplayEnvelope,
      authorization_receipt: foreignReplayAuthorization,
    }), /missing, denied, malformed, expired, or foreign/);
    assert.strictEqual(server.requestCount, 0);
    for (const chain of invalidAuthorizationChains) {
      const invalidEnvelope = {
        ...httpEnvelope,
        preauthorization_ref: chain.preauthorization.ref,
        preauthorization_sha256: chain.preauthorization.digest,
        grant_ref: chain.grant.ref,
        grant_sha256: chain.grant.digest,
      };
      const invalidAuthorization = await dispatch('authorize-effect', {
        ...common, action_envelope: invalidEnvelope,
      });
      assert.strictEqual(invalidAuthorization.decision, 'deny', chain.name);
    }
    const canonicalCliEnvelope = {
      ...httpEnvelope,
      effect_kind: 'cli', capability: 'direct-argv',
      effect: { kind: 'cli', case_id: cliCase.case_id, argv: cliCase.argv,
        timeout_seconds: cliCase.timeout_seconds, assertions: cliCase.assertions },
      resource_bounds: { output_bytes: 65536 },
    };
    await assert.rejects(() => dispatch('authorize-cli-effect', {
      ...common, action_envelope: canonicalCliEnvelope,
    }), /only legacy CLI envelopes/);
    const httpAuthorization = await dispatch('authorize-effect', {
      ...common, action_envelope: httpEnvelope,
    });
    assert.strictEqual(httpAuthorization.decision, 'allow', JSON.stringify(httpAuthorization));
    assert.strictEqual(server.requestCount, 0);
    await assert.rejects(() => dispatch('authorize-cli-effect', {
      ...common, action_envelope: httpEnvelope,
    }), /only legacy CLI envelopes/);
    await assert.rejects(() => dispatch('http-request', {
      ...common, action_envelope: httpEnvelope,
    }), /fields are invalid|missing, denied, malformed/);
    const malformedHttpReceipt = {
      ...httpAuthorization,
      evaluated_input_digests: { ...httpAuthorization.evaluated_input_digests },
    };
    delete malformedHttpReceipt.evaluated_input_digests.plan;
    await assert.rejects(() => dispatch('http-request', {
      ...common, action_envelope: httpEnvelope, authorization_receipt: malformedHttpReceipt,
    }), /fields are invalid|digests are malformed/);
    const foreignReceiptEnvelope = { ...httpEnvelope, trace_id: `${traceId}-foreign` };
    await assert.rejects(() => dispatch('http-request', {
      ...common, action_envelope: foreignReceiptEnvelope, authorization_receipt: httpAuthorization,
    }), /missing, denied, malformed, expired, or foreign/);
    const expiredEnvelope = {
      ...httpEnvelope,
      expires_at: new Date(Date.now() - 1000).toISOString(),
    };
    const expiredReceipt = { ...httpAuthorization, expires_at: expiredEnvelope.expires_at };
    await assert.rejects(() => dispatch('http-request', {
      ...common, action_envelope: expiredEnvelope, authorization_receipt: expiredReceipt,
    }), /missing, denied, malformed, expired, or foreign/);
    for (const effectPatch of [
      { redirect_mode: 'follow' },
      { proxy_mode: 'ambient' },
      { address_mode: 'dns' },
      { path: '/safe/../admin' },
      { path: '/safe%2fadmin' },
      { path: '/safe\\admin' },
    ]) {
      await assert.rejects(() => dispatch('http-request', {
        ...common,
        action_envelope: { ...httpEnvelope, effect: { ...httpEnvelope.effect, ...effectPatch } },
        authorization_receipt: httpAuthorization,
      }), /HTTP action effect is malformed/);
    }
    for (const malformedIdentity of [
      'x'.repeat(181),
      'invalid\nidentity',
    ]) {
      const malformedEnvelope = { ...httpEnvelope, trace_id: malformedIdentity };
      const malformedDenial = await dispatch('authorize-effect', {
        ...common, action_envelope: malformedEnvelope,
      });
      assert.strictEqual(malformedDenial.decision, 'deny');
      assert.strictEqual(malformedDenial.reason_code, 'malformed-envelope');
      assert.strictEqual(malformedDenial.trace_id, 'invalid-trace');
      assert.ok(malformedDenial.fence_id.length <= 180);
      assert.ok(malformedDenial.dedup_key.length <= 180);
    }
    for (const bindingPatch of [
      { plan_sha256: '0'.repeat(64) },
      { environment_receipt_sha256: '0'.repeat(64) },
    ]) {
      const foreignBindingEnvelope = { ...httpEnvelope, ...bindingPatch };
      const foreignBindingReceipt = await dispatch('authorize-effect', {
        ...common, action_envelope: foreignBindingEnvelope,
      });
      assert.strictEqual(foreignBindingReceipt.decision, 'deny');
      await assert.rejects(() => dispatch('http-request', {
        ...common,
        action_envelope: foreignBindingEnvelope,
        authorization_receipt: foreignBindingReceipt,
      }), /missing, denied, malformed, expired, or foreign/);
    }
    assert.strictEqual(server.requestCount, 0);
    const response = await dispatch('http-request', {
      ...common, action_envelope: httpEnvelope, authorization_receipt: httpAuthorization,
      base_url: 'http://127.0.0.1:1/other',
      request: { method: 'POST', url: 'http://example.invalid/redirect', headers: ['proxy'] },
      proxy: 'http://example.invalid:8080',
    });
    assert.strictEqual(response.status, 200);
    assert.match(response.body, /healthy/);
    assert.strictEqual(server.requestCount, 1);
    assert.strictEqual(server.lastMethod, 'POST');
    assert.strictEqual(server.lastUrl, '/api/probe');
    await assert.rejects(() => dispatch('http-request', {
      ...common, action_envelope: httpEnvelope, authorization_receipt: httpAuthorization,
    }), /replayed or is unavailable/);
    assert.strictEqual(server.requestCount, 1);
    const listenerLossEnvelope = {
      ...httpEnvelope,
      effect: { ...httpEnvelope.effect, case_id: listenerLossCase.case_id },
    };
    const listenerLossAuthorization = await dispatch('authorize-effect', {
      ...common, action_envelope: listenerLossEnvelope,
    });
    assert.strictEqual(listenerLossAuthorization.decision, 'allow');
    const ownedServer = server;
    const requestCountBeforeListenerLoss = ownedServer.requestCount;
    await new Promise((resolve) => ownedServer.close(resolve));
    server = null;
    await assert.rejects(() => dispatch('http-request', {
      ...common, action_envelope: listenerLossEnvelope,
      authorization_receipt: listenerLossAuthorization,
    }), /listener is not owned/);
    assert.strictEqual(ownedServer.requestCount, requestCountBeforeListenerLoss);
    const listenerLossDenial = await dispatch('authorize-effect', {
      ...common, action_envelope: listenerLossEnvelope,
    });
    assert.strictEqual(listenerLossDenial.decision, 'deny');
    const foreignHttpEnvelope = {
      ...httpEnvelope,
      effect: { ...httpEnvelope.effect, origin: 'http://127.0.0.1:1' },
    };
    const deniedHttp = await dispatch('authorize-effect', {
      ...common, action_envelope: foreignHttpEnvelope,
    });
    assert.strictEqual(deniedHttp.decision, 'deny');
    await assert.rejects(() => dispatch('http-request', {
      ...common, action_envelope: foreignHttpEnvelope, authorization_receipt: deniedHttp,
    }), /action effect is malformed|missing, denied, malformed, expired, or foreign/);

    fs.symlinkSync(temp, linkPath);
    await assert.rejects(() => dispatch('write-artifact', {
      ...common,
      artifact_ref: { kind: 'artifact', ref: `${linkPath}/escape.json` },
      value: { escaped: true },
    }), /symbolic link/);
    fs.rmSync(linkPath, { force: true });

    const resultRef = `${artifactRoot}/execution.json`;
    assert.strictEqual((await dispatch('write-artifact', {
      ...common,
      artifact_ref: { kind: 'artifact', ref: resultRef },
      value: {
        schema: 'testing-structured-execution.v1', operation_id: operationId,
        status: 'passed', classification: 'passed', repository,
        environment_receipt_sha256: common.environment_receipt_sha256,
        trace_id: common.trace_id, dedup_key: common.dedup_key,
        case_count: 1, passed_count: 1, failed_count: 0, skipped_count: 0, error_count: 0,
        test_plan_path: `${artifactRoot}/test-plan.json`,
        case_results_path: `${artifactRoot}/case-results.json`, execution_path: resultRef,
      },
    })).written, true);
    assert.strictEqual((await dispatch('load-artifact', {
      ...common, artifact_ref: { kind: 'artifact', ref: resultRef },
    })).value.status, 'passed');

    const claimRequest = {
      ...common,
      grant_id: `${runId}-grant`,
      grant_sha256: grantSha256,
      parent_authorization_sha256: 'c'.repeat(64),
      plan_sha256: 'd'.repeat(64),
    };
    const claim = await dispatch('replay-guard', claimRequest);
    assert.strictEqual(claim.status, 'claimed');
    assert.strictEqual((await dispatch('replay-guard', claimRequest)).status, 'in-progress');
    await assert.rejects(() => dispatch('replay-guard', {
      ...claimRequest, artifact_root: `.testing/runs/${runId}-foreign/execution`,
    }), /replay binding differs/);
    const completion = await dispatch('complete-replay', {
      ...common, claim, result_ref: resultRef,
    });
    assert.strictEqual(completion.completed, true);
    const replay = await dispatch('replay-guard', claimRequest);
    assert.strictEqual(replay.status, 'completed');
    assert.strictEqual(replay.result_ref, resultRef);
    assert.strictEqual(replay.result_sha256, completion.result_sha256);
    assert.strictEqual((await dispatch('load-result', {
      ...common, result_ref: resultRef, result_sha256: replay.result_sha256,
    })).passed_count, 1);
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
