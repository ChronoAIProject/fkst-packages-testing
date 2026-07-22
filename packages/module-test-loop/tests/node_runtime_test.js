'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const runtime = path.resolve(__dirname, '..', 'bin', 'module-test-loop-runtime.js');

function call(cwd, operation, request) {
  const result = spawnSync(process.execPath, [runtime, operation], {
    cwd,
    encoding: 'utf8',
    env: { ...process.env, FKST_MODULE_TEST_LOOP_REQUEST_JSON: JSON.stringify(request) },
  });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

test('persists CAS state, scans pending runs, and hashes artifacts', () => {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'fkst-module-loop-runtime-'));
  try {
    const stateRef = '.testing/runs/runtime-test/module-loop-state.json';
    assert.deepEqual(call(cwd, 'load-state', { state_ref: stateRef }), {
      ok: true,
      found: false,
    });

    const pending = {
      schema: 'module-test-loop.state.v1',
      version: 1,
      phase: 'runner-pending',
      state_ref: stateRef,
    };
    assert.deepEqual(call(cwd, 'save-state', {
      state_ref: stateRef,
      state: pending,
      expected_revision: 0,
    }), { ok: true, saved: true, revision: 1 });
    assert.equal(call(cwd, 'save-state', {
      state_ref: stateRef,
      state: pending,
      expected_revision: 0,
    }).stale, true);
    assert.deepEqual(call(cwd, 'load-state', { state_ref: stateRef }).result, pending);
    assert.deepEqual(call(cwd, 'list-pending-states', { limit: 8 }).result, [stateRef]);

    const artifact = '.testing/runs/runtime-test/test-plan.json';
    const artifactBody = '{"schema":"test-plan"}\n';
    fs.writeFileSync(path.resolve(cwd, artifact), artifactBody);
    assert.equal(
      call(cwd, 'artifact-digest', { pointer: artifact }).digest,
      crypto.createHash('sha256').update(artifactBody).digest('hex'),
    );

    const terminal = { ...pending, version: 2, phase: 'terminal' };
    assert.equal(call(cwd, 'save-state', {
      state_ref: stateRef,
      state: terminal,
      expected_revision: 1,
    }).saved, true);
    assert.deepEqual(call(cwd, 'list-pending-states', { limit: 8 }).result, []);
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
});

test('rejects paths outside the testing root', () => {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'fkst-module-loop-runtime-'));
  try {
    const result = spawnSync(process.execPath, [runtime, 'load-state'], {
      cwd,
      encoding: 'utf8',
      env: { ...process.env, FKST_MODULE_TEST_LOOP_REQUEST_JSON: JSON.stringify({ state_ref: '../state.json' }) },
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /must be under \.testing\/runs/);
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
});
