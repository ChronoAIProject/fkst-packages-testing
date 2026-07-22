'use strict';

const assert = require('assert');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const {
  acquireLock,
  authorizationArtifact,
  stableStringify,
} = require('../bin/runtime/common');
const { runMeasuredCommand } = require('../bin/runtime/measured-command');
const { listenersOwnedByProcessGroup } = require('../bin/runtime/platform');
const { dispatch, initialReadinessState, sha256 } = require('../bin/environment-factory-runtime');

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function stopGroup(child) {
  if (!child || !Number.isInteger(child.pid)) return;
  try { process.kill(-child.pid, 'SIGKILL'); } catch (_error) {
    try { process.kill(child.pid, 'SIGKILL'); } catch (_ignored) {}
  }
}

async function spawnListener(addresses, temp) {
  const readyPath = path.join(temp, `listener-${process.pid}-${Date.now()}-${Math.random()}.json`);
  const source = `
    const fs = require('fs');
    const net = require('net');
    const addresses = JSON.parse(process.argv[1]);
    const readyPath = process.argv[2];
    const ports = new Array(addresses.length);
    let remaining = addresses.length;
    const publish = (value) => {
      const pendingPath = readyPath + '.tmp';
      fs.writeFileSync(pendingPath, JSON.stringify(value));
      fs.renameSync(pendingPath, readyPath);
    };
    const fail = (error) => {
      publish({ error: error.message });
      process.exit(1);
    };
    addresses.forEach((address, index) => {
      const server = net.createServer();
      server.once('error', fail);
      server.listen(0, address, () => {
        ports[index] = server.address().port;
        remaining -= 1;
        if (remaining === 0) publish({ ports });
      });
    });
    setInterval(() => {}, 1000);
  `;
  const child = spawn(process.execPath, ['-e', source, JSON.stringify(addresses), readyPath], {
    detached: true,
    stdio: 'ignore',
  });
  child.unref();
  const deadline = Date.now() + 5_000;
  while (!fs.existsSync(readyPath)) {
    if (Date.now() >= deadline) {
      stopGroup(child);
      throw new Error(`listener readiness timed out: ${readyPath}`);
    }
    await delay(10);
  }
  const ready = JSON.parse(fs.readFileSync(readyPath, 'utf8'));
  fs.rmSync(readyPath, { force: true });
  if (ready.error) {
    stopGroup(child);
    throw new Error(`listener startup failed: ${ready.error}`);
  }
  return { child, ports: ready.ports };
}

async function main() {
  assert.throws(() => stableStringify({ value: undefined }), /rejects undefined/);
  assert.throws(() => stableStringify([undefined]), /rejects undefined/);
  assert.throws(() => stableStringify({ value: () => true }), /rejects function/);
  assert.strictEqual(stableStringify({ b: 2, a: 1 }), '{"a":1,"b":2}');

  const networkCheck = [{ type: 'http' }];
  assert.deepStrictEqual(initialReadinessState({ network_requests: 0 }, networkCheck), {
    attempts: 0, probes: 0, reason: 'network-request-budget-exceeded',
  });
  assert.deepStrictEqual(initialReadinessState({ network_requests: 1 }, networkCheck), {
    attempts: 0, probes: 0, reason: null,
  });
  assert.deepStrictEqual(initialReadinessState({ network_requests: 100000 }, networkCheck), {
    attempts: 0, probes: 0, reason: null,
  });
  assert.deepStrictEqual(initialReadinessState({ network_requests: 0 }, [{ type: 'argv' }]), {
    attempts: 0, probes: 0, reason: null,
  });

  const source = { kind: 'artifact', ref: '.testing/runs/op/profile.json' };
  assert.throws(() => authorizationArtifact({ authorization_sources: [] }, source), /not materialized/);
  assert.deepStrictEqual(authorizationArtifact({
    authorization_sources: [{ source_ref: source, artifact_ref: source }],
  }, source), source);

  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'environment-runtime-node-test-'));
  const artifactRoot = `.testing/runs/environment-node-runtime-${process.pid}`;
  const hostRoot = `.testing/host/environment-factory/environment-node-runtime-${process.pid}`;
  const previousDurable = process.env.FKST_DURABLE_ROOT;
  process.env.FKST_DURABLE_ROOT = path.join(temp, 'durable');
  fs.rmSync(artifactRoot, { recursive: true, force: true });
  fs.rmSync(hostRoot, { recursive: true, force: true });
  try {
    const lockPath = path.join(temp, 'stale.lock');
    fs.mkdirSync(lockPath);
    fs.writeFileSync(path.join(lockPath, 'owner.json'), `${JSON.stringify({
      schema: 'environment-factory.lock-owner.v1',
      pid: 2147483647,
      process_start_identity: 'dead process',
      token: 'stale-owner-token',
    })}\n`);
    const release = acquireLock(lockPath, 250);
    const recovered = JSON.parse(fs.readFileSync(path.join(lockPath, 'owner.json'), 'utf8'));
    assert.strictEqual(recovered.pid, process.pid);
    release();
    assert.strictEqual(fs.existsSync(lockPath), false);

    for (let index = 0; index < 10; index += 1) {
      const result = await runMeasuredCommand([process.execPath, '-e', 'process.exit(0)'], {
        timeoutMs: 2_000,
        outputBytes: 1024,
      });
      assert.strictEqual(result.exitCode, 0);
      assert.strictEqual(result.metricsSupported, true);
      assert.strictEqual(result.processMetricsSupported, true);
      assert.strictEqual(result.maxProcesses >= 1, true);
    }

    const bounded = await runMeasuredCommand([
      process.execPath,
      '-e',
      "process.stdout.write('a'.repeat(700));process.stderr.write('b'.repeat(700))",
    ], { timeoutMs: 2_000, outputBytes: 1024 });
    assert.strictEqual(bounded.outputExceeded, true);
    assert.strictEqual(Buffer.byteLength(bounded.stdout) + Buffer.byteLength(bounded.stderr) <= 1024, true);

    const extra = await spawnListener(['127.0.0.1', '127.0.0.1'], temp);
    const extraResult = listenersOwnedByProcessGroup(
      [{ name: 'expected', port: extra.ports[0] }],
      extra.child.pid,
    );
    stopGroup(extra.child);
    assert.strictEqual(extraResult.supported, true);
    assert.strictEqual(extraResult.owned, false);
    assert.match(extraResult.reason, /^extra-listener:/);

    const wildcard = await spawnListener(['0.0.0.0'], temp);
    const wildcardResult = listenersOwnedByProcessGroup(
      [{ name: 'expected', port: wildcard.ports[0] }],
      wildcard.child.pid,
    );
    stopGroup(wildcard.child);
    assert.strictEqual(wildcardResult.supported, true);
    assert.strictEqual(wildcardResult.owned, false);
    assert.match(wildcardResult.reason, /^non-loopback-listener:/);

    const effectPayload = {
      effect_id: `node-runtime-${process.pid}/readiness-attempt`,
      operation_id: `node-runtime-${process.pid}`,
      artifact_root: artifactRoot,
      operation_state_ref: { kind: 'artifact', ref: `${artifactRoot}/operation-state.json` },
      base_url: 'http://127.0.0.1:4312/health',
      sessions: [{ role: 'browser', cdp_url: 'http://127.0.0.1:9222' }],
      trace_id: 'trace-node-runtime',
      dedup_key: 'dedup-node-runtime',
    };
    const readinessAttempt = await dispatch('create-readiness-attempt', effectPayload);
    assert.strictEqual(readinessAttempt.status, 'passed');
    assert.match(readinessAttempt.attempt_ref.ref, /\/readiness-attempts\/environment-readiness-/);
    assert.match(readinessAttempt.attempt_sha256, /^[0-9a-f]{64}$/);
    assert.strictEqual(readinessAttempt.target_id, undefined);

    const cdpServer = http.createServer((request, response) => {
      if (request.url !== '/json/list') {
        response.writeHead(404).end();
        return;
      }
      const origin = `http://127.0.0.1:${cdpServer.address().port}`;
      response.setHeader('content-type', 'application/json');
      response.end(JSON.stringify([{
        id: 'exact-page-target', type: 'page', url: `${origin}/app`,
        webSocketDebuggerUrl: 'ws://127.0.0.1/devtools/page/exact-page-target',
      }]));
    });
    await new Promise((resolve) => cdpServer.listen(0, '127.0.0.1', resolve));
    const cdpOrigin = `http://127.0.0.1:${cdpServer.address().port}`;
    const exactAttempt = await dispatch('create-readiness-attempt', {
      ...effectPayload,
      effect_id: `node-runtime-${process.pid}/exact-readiness-attempt`,
      base_url: `${cdpOrigin}/health`,
      sessions: [{ role: 'browser', cdp_url: cdpOrigin }],
    });
    await new Promise((resolve) => cdpServer.close(resolve));
    assert.strictEqual(exactAttempt.target_id, 'exact-page-target');
    assert.strictEqual(exactAttempt.target_sha256, sha256('exact-page-target'));
    assert.match(exactAttempt.attempt_sha256, /^[0-9a-f]{64}$/);

    await assert.rejects(() => dispatch('create-readiness-attempt', {
      ...effectPayload,
      operation_state_ref: { kind: 'artifact', ref: `${artifactRoot}/foreign-state.json` },
    }), /effect request binding differs/);

    const ownedWorkspace = path.join(temp, 'owned-workspace');
    fs.mkdirSync(ownedWorkspace);
    const ownedResourceRef = `owned-workspace-${process.pid}`;
    const ownedResourcePath = path.join(
      process.env.FKST_DURABLE_ROOT,
      'environment-factory',
      'resources',
      `${sha256(ownedResourceRef)}.json`,
    );
    fs.mkdirSync(path.dirname(ownedResourcePath), { recursive: true });
    fs.writeFileSync(ownedResourcePath, `${JSON.stringify({
      schema: 'environment-factory.resource.v1',
      kind: 'workspace',
      operation_id: `owner-${process.pid}`,
      ref: ownedResourceRef,
      path: ownedWorkspace,
      cleaned: false,
    })}\n`);
    await assert.rejects(() => dispatch('cleanup', {
      effect_id: `foreign-${process.pid}/cleanup/workspace`,
      operation_id: `foreign-${process.pid}`,
      artifact_root: artifactRoot,
      cleanup_ref: { kind: 'resource-cleanup', ref: ownedResourceRef },
      timeout_seconds: 1,
    }), /resource ownership binding is invalid/);
    assert.strictEqual(fs.existsSync(ownedWorkspace), true);

    const runtimeConfigRef = { kind: 'artifact', ref: `${hostRoot}/runtime-config.json` };
    const stateRef = { kind: 'artifact', ref: `${artifactRoot}/operation-state.json` };
    fs.mkdirSync(hostRoot, { recursive: true });
    fs.writeFileSync(runtimeConfigRef.ref, `${JSON.stringify({
      schema: 'environment-factory.runtime-config.v1',
      revision: 'node-runtime-test-1',
      state_auth_key: 'node-runtime-state-auth-key-which-is-long-enough',
      state_mac_generation: 'node-runtime-key-1',
    })}\n`);
    const firstSave = await dispatch('save-state', {
      ref: stateRef,
      state: { schema: 'environment-factory.operation-state.v1', value: 1 },
      expected_revision: 0,
      runtime_config_ref: runtimeConfigRef,
    });
    assert.deepStrictEqual(firstSave, { saved: true, revision: 1 });
    const staleSave = await dispatch('save-state', {
      ref: stateRef,
      state: { schema: 'environment-factory.operation-state.v1', value: 2 },
      expected_revision: 0,
      runtime_config_ref: runtimeConfigRef,
    });
    assert.deepStrictEqual(staleSave, { saved: false, stale: true, revision: 1 });
    const loaded = await dispatch('load-state', { ref: stateRef, runtime_config_ref: runtimeConfigRef });
    assert.strictEqual(loaded.authenticated, true);
    assert.strictEqual(loaded.revision, 1);
    assert.strictEqual(loaded.state.value, 1);

    fs.writeFileSync(runtimeConfigRef.ref, `${JSON.stringify({
      schema: 'environment-factory.runtime-config.v1',
      revision: 'node-runtime-test-2',
      state_auth_key: 'node-runtime-state-auth-key-which-is-long-enough',
      state_mac_generation: 'node-runtime-key-2',
    })}\n`);
    const rotated = await dispatch('load-state', { ref: stateRef, runtime_config_ref: runtimeConfigRef });
    assert.strictEqual(rotated.authenticated, false);
  } finally {
    if (previousDurable === undefined) delete process.env.FKST_DURABLE_ROOT;
    else process.env.FKST_DURABLE_ROOT = previousDurable;
    fs.rmSync(temp, { recursive: true, force: true });
    fs.rmSync(artifactRoot, { recursive: true, force: true });
    fs.rmSync(hostRoot, { recursive: true, force: true });
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
