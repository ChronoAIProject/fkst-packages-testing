'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const test = require('node:test');
const { acquireTargetById } = require('../lib/cdp_client');
const {
  capabilityFor,
  parseLocation,
  projectObservation,
  sanitizeText,
  sha256,
  validateAction,
} = require('../lib/browser_control');

function grant() {
  return {
    target_id: 'target-1',
    target_sha256: sha256('target-1'),
    allowed_auth_origins: ['https://auth.example.test'],
    callback: { origin: 'http://127.0.0.1:43119', path: '/callback' },
    allowed_actions: ['click', 'type', 'submit', 'press_tab', 'finish'],
    approved_secret_refs: ['primary-identity', 'primary-secret'],
  };
}

function raw(overrides = {}) {
  return {
    url: 'https://auth.example.test/login?state=callback-secret#fragment',
    readyState: 'complete',
    timeOrigin: 100,
    title: 'Sign in',
    visibleText: 'Sign in user@example.test TOKEN=canary-secret-value-0123456789abcdef',
    controls: [
      { role: 'textbox', kind: 'textbox', label: 'user@example.test', focused: true },
      { role: 'button', kind: 'button', label: 'Continue', focused: false },
    ],
    consoleCount: 1,
    networkCount: 2,
    ...overrides,
  };
}

test('projection strips query fragment account identifiers and canary secrets', () => {
  const projected = projectObservation(raw(), grant(), 1);
  const serialized = JSON.stringify(projected);
  assert.equal(projected.observation.origin, 'https://auth.example.test');
  assert.equal(projected.observation.path, '/login');
  assert.equal(serialized.includes('callback-secret'), false);
  assert.equal(serialized.includes('user@example.test'), false);
  assert.equal(serialized.includes('canary-secret-value'), false);
  assert.equal(serialized.includes('TOKEN='), false);
  assert.match(projected.observation.controls[0].handle, /^[0-9a-f]{32}$/);
  assert.deepEqual(Object.keys(projected.capabilities.controls[0]).sort(),
    ['document_token', 'fingerprint', 'handle', 'index']);
});

test('document changes expire one-turn handles', () => {
  const first = projectObservation(raw(), grant(), 1);
  const second = projectObservation(raw({ timeOrigin: 101 }), grant(), 1);
  assert.notEqual(first.observation.document_token, second.observation.document_token);
  assert.notEqual(first.observation.controls[0].handle, second.observation.controls[0].handle);
  assert.throws(() => capabilityFor({ handle: first.observation.controls[0].handle }, second.capabilities),
    /stale or unknown/);
});

test('callback, MFA, CAPTCHA, popup, and target-change signals are deterministic', () => {
  const callback = projectObservation(raw({
    url: 'http://127.0.0.1:43119/callback?code=canary',
    visibleText: 'Verification code required prove you are human',
    targetChanged: true,
    popupDetected: true,
  }), grant(), 2).observation;
  assert.equal(callback.signals.callback_detected, true);
  assert.equal(callback.signals.mfa_detected, true);
  assert.equal(callback.signals.captcha_detected, true);
  assert.equal(callback.signals.target_changed, true);
  assert.equal(callback.signals.popup_detected, true);
  assert.equal(JSON.stringify(callback).includes('code=canary'), false);
});

test('unexpected origins and callback paths fail closed', () => {
  assert.throws(() => projectObservation(raw({ url: 'https://other.example.test/login' }), grant(), 1),
    /unexpected browser origin/);
  assert.throws(() => projectObservation(raw({ url: 'http://127.0.0.1:43119/other' }), grant(), 1),
    /unexpected browser origin/);
  assert.deepEqual(parseLocation('https://auth.example.test/a?secret=x#y'),
    { origin: 'https://auth.example.test', path: '/a' });
});

test('actions are selector-free and secret-ref-only', () => {
  validateAction({
    schema: 'testing-runner.ai-browser-control.action.v1',
    turn: 1,
    kind: 'type',
    handle: 'abcdef',
    secret_ref: 'primary-secret',
  }, grant(), 1);
  assert.throws(() => validateAction({
    schema: 'testing-runner.ai-browser-control.action.v1', turn: 1,
    kind: 'click', handle: 'abcdef', selector: '#submit',
  }, grant(), 1), /unsupported action field/);
  assert.throws(() => validateAction({
    schema: 'testing-runner.ai-browser-control.action.v1', turn: 1,
    kind: 'navigate', url: 'https://auth.example.test',
  }, grant(), 1), /unsupported action field|unauthorized/);
  assert.throws(() => validateAction({
    schema: 'testing-runner.ai-browser-control.action.v1', turn: 1,
    kind: 'type', handle: 'abcdef', secret_ref: 'literal-canary-secret',
  }, grant(), 1), /approved secret ref/);
});

test('sanitizer removes high-entropy canaries without leaking them to output', () => {
  const canary = 'CANARY_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  const sanitized = sanitizeText(`password=${canary} ${canary}`);
  assert.equal(sanitized.includes(canary), false);
  assert.equal(sanitized.includes('[redacted]'), true);
});

test('exact target acquisition never falls back to the first page', async () => {
  const server = http.createServer((request, response) => {
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify([
      { id: 'other', type: 'page', url: 'https://auth.example.test', webSocketDebuggerUrl: 'ws://127.0.0.1:9222/devtools/page/other' },
      { id: 'target-1', type: 'page', url: 'https://auth.example.test', webSocketDebuggerUrl: 'ws://127.0.0.1:9222/devtools/page/target-1' },
    ]));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  try {
    const target = await acquireTargetById(`http://127.0.0.1:${address.port}`, 'target-1');
    assert.equal(target.id, 'target-1');
    await assert.rejects(() => acquireTargetById(`http://127.0.0.1:${address.port}`, 'missing'),
      /exact approved CDP target/);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
