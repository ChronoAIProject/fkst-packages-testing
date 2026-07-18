'use strict';

const assert = require('assert');
const fs = require('fs');
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
const { dispatch, initialReadinessState } = require('../bin/environment-factory-runtime');

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function stopGroup(child) {
  if (!child || !Number.isInteger(child.pid)) return;
  try { process.kill(-child.pid, 'SIGKILL'); } catch (_error) {
    try { process.kill(child.pid, 'SIGKILL'); } catch (_ignored) {}
  }
}

function spawnListener(source, ports) {
  const child = spawn(process.execPath, ['-e', source, ...ports.map(String)], {
    detached: true,
    stdio: 'ignore',
  });
  child.unref();
  return child;
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

    const expectedPort = 62000 + (process.pid % 1000);
    const extraPort = expectedPort + 1000;
    const extra = spawnListener(
      "const n=require('net');n.createServer().listen(Number(process.argv[1]),'127.0.0.1');n.createServer().listen(Number(process.argv[2]),'127.0.0.1');setInterval(()=>{},1000)",
      [expectedPort, extraPort],
    );
    await delay(250);
    const extraResult = listenersOwnedByProcessGroup([{ name: 'expected', port: expectedPort }], extra.pid);
    stopGroup(extra);
    assert.strictEqual(extraResult.supported, true);
    assert.strictEqual(extraResult.owned, false);
    assert.match(extraResult.reason, /^extra-listener:/);

    const wildcardPort = expectedPort + 2000;
    const wildcard = spawnListener(
      "require('net').createServer().listen(Number(process.argv[1]),'0.0.0.0');setInterval(()=>{},1000)",
      [wildcardPort],
    );
    await delay(250);
    const wildcardResult = listenersOwnedByProcessGroup([{ name: 'expected', port: wildcardPort }], wildcard.pid);
    stopGroup(wildcard);
    assert.strictEqual(wildcardResult.supported, true);
    assert.strictEqual(wildcardResult.owned, false);
    assert.match(wildcardResult.reason, /^non-loopback-listener:/);

    const effectPayload = {
      effect_id: `node-runtime-${process.pid}/readiness-attempt`,
      operation_id: `node-runtime-${process.pid}`,
      artifact_root: artifactRoot,
      environment_receipt_ref: { kind: 'artifact', ref: `${artifactRoot}/environment-receipt-ready.json` },
      operation_state_ref: { kind: 'artifact', ref: `${artifactRoot}/operation-state.json` },
    };
    await dispatch('create-readiness-attempt', effectPayload);
    await assert.rejects(() => dispatch('create-readiness-attempt', {
      ...effectPayload,
      operation_state_ref: { kind: 'artifact', ref: `${artifactRoot}/foreign-state.json` },
    }), /effect request binding differs/);

    const runtimeConfigRef = { kind: 'artifact', ref: `${hostRoot}/runtime-config.json` };
    const stateRef = { kind: 'artifact', ref: `${artifactRoot}/operation-state.json` };
    fs.mkdirSync(hostRoot, { recursive: true });
    fs.writeFileSync(runtimeConfigRef.ref, `${JSON.stringify({
      schema: 'environment-factory.runtime-config.v1',
      revision: 'node-runtime-test-1',
      state_auth_key: 'node-runtime-state-auth-key-which-is-long-enough',
      state_auth_key_revision: 'node-runtime-key-1',
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
      state_auth_key_revision: 'node-runtime-key-2',
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
