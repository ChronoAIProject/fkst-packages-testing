'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const fixed = require('../lib/deterministic_browser');
const { context } = require('../../../examples/generic-host/bin/deterministic-browser');
const store = require('../../../examples/generic-host/bin/durable-host-store');
const candidateFixture = require('./fixtures/browser-host-candidate.json');

const ROOT = path.resolve(__dirname, '../../..');
const CLI = path.join(ROOT, 'examples/generic-host/bin/deterministic-browser.js');
const CHROME = process.env.FKST_FIXED_BROWSER_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const HTML = '<!doctype html><title>Results</title><section role="region" aria-label="Results">Reviewed results</section>';

function inputs(t, origin = 'http://127.0.0.1:12345', html = HTML) {
  const temporary = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'fixed-browser-test-'));
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }));
  const candidate = structuredClone(candidateFixture);
  const policy = { schema_version: 'testing.fixed-browser-host-policy.v1', policy_id: 'fixture-policy',
    candidate_digest: candidate.content_digest, case_content_digest: candidate.case_design.content_digest,
    target_repository: candidate.case_design.target_repository, origin_ref: 'origin:example-web', origin,
    path: '/results', query_policy: 'forbidden', fragment_policy: 'forbidden', account_policy: 'none',
    capabilities: ['testing.deterministic-browser-plan'], secret_ref_allowlist: [],
    fixture_sha256: fixed.sha256(html), timeout_ms: 10000,
    target_resolution: { target_ref: 'target:results-region', accessible_name_ref: 'text-ref:results', accessible_name: 'Results' } };
  const plan = fixed.compile(candidate, policy);
  const request = { candidate, plan, execution_id: 'fixture-execution' };
  const config = { policy, grants: [{ schema_version: 'testing.fixed-browser-grant.v1', execution_id: request.execution_id,
    binding: plan.binding, plan_digest: plan.content_digest, expires_at: '2099-01-01T00:00:00Z' }],
  store_root: path.join(temporary, 'host-store'), chrome_path: CHROME };
  return { temporary, candidate, policy, plan, request, config };
}

function writeInputs(value) {
  const requestPath = path.join(value.temporary, 'request.json');
  const configPath = path.join(value.temporary, 'host-config.json');
  fs.writeFileSync(requestPath, fixed.stable(value.request));
  fs.writeFileSync(configPath, fixed.stable(value.config));
  return [requestPath, configPath];
}

function cli(command, value) {
  const [requestPath, configPath] = writeInputs(value);
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [CLI, command, '--request', requestPath, '--host-config', configPath], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = ''; let stderr = '';
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('CLI test timeout')); }, 25000);
    child.stdout.on('data', data => { stdout += data; }); child.stderr.on('data', data => { stderr += data; });
    child.on('error', reject); child.on('close', code => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
  });
}

function fakeHost(value) {
  const host = context(value.config);
  let effects = 0;
  host.browser = () => { effects += 1; return { outcome: 'observed', observed_title: 'Results', target_status: 'unique-visible', cleanup_status: 'complete' }; };
  return { host, effects: () => effects };
}

test('compile exact original PQL staged candidate; deterministic and nonauthorizing', t => {
  const { candidate, policy, plan } = inputs(t);
  assert.deepEqual(fixed.compile(candidate, policy), plan);
  assert.deepEqual(plan.binding.target_repository, candidate.case_design.target_repository);
  assert.equal(candidate.authority.execution_authorized, false);
  assert.equal(plan.action.url, 'http://127.0.0.1:12345/results');
});

test('reserved mismatch sentinel cannot be a reviewed expected title before Host store or effects', t => {
  const value = inputs(t);
  value.candidate.catalog.assertions[0].expected_value = '[title differs]';
  value.candidate.catalog = fixed.seal(value.candidate.catalog);
  const catalog = value.candidate.catalog;
  const tuple = { catalog_id: catalog.catalog_id, catalog_version: catalog.catalog_version, catalog_digest: catalog.content_digest };
  const design = value.candidate.case_design;
  design.action_assertion_catalog = tuple;
  design.browser.action_catalog = tuple;
  design.browser.assertion_catalog = tuple;
  const target = design.browser.semantic_targets[0];
  target.catalog_tuple = tuple;
  const targetBody = { ...target }; delete targetBody.target_digest;
  target.target_digest = fixed.digest(targetBody);
  value.candidate.case_design = fixed.seal(design);
  value.candidate = fixed.seal(value.candidate);
  value.policy.candidate_digest = value.candidate.content_digest;
  value.policy.case_content_digest = value.candidate.case_design.content_digest;
  value.request.candidate = value.candidate;
  const fake = fakeHost(value);
  assert.throws(() => fixed.compile(value.candidate, value.policy), /catalog-assertion-mismatch/);
  assert.throws(() => fixed.run(value.request, fake.host), /catalog-assertion-mismatch/);
  assert.equal(fake.effects(), 0);
  assert.equal(fs.existsSync(value.config.store_root), false);
});

for (const mutation of [
  c => { c.browser.actions.push({ kind: 'click_reviewed_target' }); },
  c => { c.browser.actions[0].kind = 'inspect'; },
  c => { c.browser.assertions[0].kind = 'visible'; },
  c => { c.browser.actions[0].selector = '#results'; },
  c => { c.browser.semantic_targets[0].xpath = '//section'; },
  c => { c.browser.actions[0].code = 'fetch("https://example.com")'; },
  c => { c.network_policy.account_context_ref = 'account-context:test'; },
  c => { c.network_policy.query_fragment_policy = 'explicit-reviewed-policy-ref'; },
  c => { c.secret_ref_requirements = [{ secret_ref: 'secret-ref:test', purpose: 'browser-credential' }]; },
  c => { c.browser.semantic_targets[0].state_predicates.push('state:enabled'); },
  c => { c.browser.profile_requirement.credential_material_allowed = true; },
  c => { c.evidence_requirements[0].digest_domain = 'screenshot'; },
]) {
  test(`unsupported candidate fails before store/effects: ${mutation.toString()}`, t => {
    const value = inputs(t);
    mutation(value.candidate.case_design);
    value.candidate.case_design = fixed.seal(value.candidate.case_design);
    value.candidate = fixed.seal(value.candidate);
    value.policy.case_content_digest = value.candidate.case_design.content_digest;
    value.policy.candidate_digest = value.candidate.content_digest;
    assert.throws(() => fixed.compile(value.candidate, value.policy));
    assert.equal(fs.existsSync(value.config.store_root), false);
  });
}

test('all independent authority bindings fail before effects', t => {
  for (const mutate of [
    v => { v.config.grants = []; },
    v => { v.config.grants[0].binding = { ...v.plan.binding, candidate_digest: 'sha256:' + '0'.repeat(64) }; },
    v => { v.config.grants[0].plan_digest = 'sha256:' + '0'.repeat(64); },
    v => { v.request.plan.action.url += '?secret=x'; },
    v => { v.config.policy.origin = 'http://example.com:1234'; },
    v => { v.config.policy.path = '/results?x=1'; },
    v => { v.config.policy.path = '/results#x'; },
    v => { v.config.policy.target_resolution.accessible_name_ref = 'text-ref:other'; },
    v => { v.config.grants[0].expires_at = '2000-01-01T00:00:00Z'; },
  ]) {
    const value = inputs(t); mutate(value); const fake = fakeHost(value);
    assert.throws(() => fixed.run(value.request, fake.host)); assert.equal(fake.effects(), 0);
  }
});

test('durable exact replay, single-use identity and independent read-only verification', async t => {
  const value = inputs(t); const fake = fakeHost(value);
  const result = fixed.run(value.request, fake.host);
  const { validateCanonical } = await import('../lib/fixed_browser_schema.mjs');
  await validateCanonical(result);
  assert.deepEqual(fixed.run(value.request, fake.host), result); assert.equal(fake.effects(), 1);
  assert.deepEqual(fixed.validate_result(value.request, context(value.config)), result);
  value.config.grants[0].expires_at = '2098-01-01T00:00:00Z';
  assert.throws(() => fixed.run(value.request, fake.host), /identity-reuse/);
  assert.equal(fake.effects(), 1);
});

test('interrupted intent terminalizes lost, persisted receipt resumes without effect', async t => {
  for (const persistReceipt of [false, true]) {
    const value = inputs(t); const fake = fakeHost(value);
    const write = fake.host.immutable;
    fake.host.immutable = (key, body) => {
      if (key.endsWith(persistReceipt ? '/effect' : '/intent')) {
        write(key, body); throw new Error('simulated process interruption');
      }
      return write(key, body);
    };
    assert.throws(() => fixed.run(value.request, fake.host), /interruption/);
    const recovery = fakeHost(value);
    const result = fixed.run(value.request, recovery.host);
    assert.equal(result.case_result_set.cases[0].execution_status, persistReceipt ? 'passed' : 'lost');
    assert.equal(recovery.effects(), 0);
    const { validateCanonical } = await import('../lib/fixed_browser_schema.mjs'); await validateCanonical(result);
  }
});

test('resealed result tamper and forged effect fail closed, missing verifier store stays missing', t => {
  const absent = inputs(t);
  assert.throws(() => fixed.validate_result(absent.request, context(absent.config)));
  assert.equal(fs.existsSync(absent.config.store_root), false);
  const value = inputs(t); const fake = fakeHost(value); fixed.run(value.request, fake.host);
  const logical = '.testing/runs/fixture-execution/case-result-set.json';
  const file = path.join(value.config.store_root, 'artifacts', fixed.sha256(logical) + '.json');
  const original = fs.readFileSync(file, 'utf8'); const stored = JSON.parse(original);
  const body = JSON.parse(stored.body); body.cases[0].observations[0].value = 'forged';
  stored.body = fixed.stable(body); stored.digest = fixed.sha256(stored.body); fs.writeFileSync(file, JSON.stringify(stored));
  assert.throws(() => fixed.validate_result(value.request, fake.host), /tampered/);
  assert.throws(() => fixed.run(value.request, fake.host), /tampered/); assert.equal(fake.effects(), 1);
  fs.writeFileSync(file, original);
  const effectFile = path.join(value.config.store_root, 'records/fixed-browser/fixture-execution/effect.json');
  const effect = JSON.parse(fs.readFileSync(effectFile)); effect.observed_title = 'forged'; fs.writeFileSync(effectFile, JSON.stringify(effect));
  assert.throws(() => fixed.validate_result(value.request, fake.host), /tampered|unsafe-title/);
});

test('completed replay requires exact claim, retained intent and effect start identity', t => {
  for (const mutation of ['delete-intent', 'edit-intent', 'edit-claim']) {
    const value = inputs(t); const fake = fakeHost(value); fixed.run(value.request, fake.host);
    const key = mutation === 'edit-claim' ? 'claim' : 'intent';
    const file = path.join(value.config.store_root, `records/fixed-browser/fixture-execution/${key}.json`);
    if (mutation === 'delete-intent') fs.unlinkSync(file);
    else {
      const record = JSON.parse(fs.readFileSync(file));
      if (mutation === 'edit-claim') record.claim_id = 'another-execution';
      else record.started_at = '2000-01-01T00:00:00Z';
      fs.writeFileSync(file, JSON.stringify(record));
    }
    assert.throws(() => fixed.validate_result(value.request, fake.host));
    assert.throws(() => fixed.run(value.request, fake.host)); assert.equal(fake.effects(), 1);
  }
});

test('preexisting profile and recycled process identity are preserved', async t => {
  const value = inputs(t); const host = context(value.config);
  const profile = path.join(os.tmpdir(), `fkst-fixed-browser-${fixed.sha256(value.config.store_root + '\0' + value.request.execution_id)}`);
  fs.mkdirSync(profile); fs.writeFileSync(path.join(profile, 'unowned.txt'), 'keep');
  t.after(() => fs.rmSync(profile, { recursive: true, force: true }));
  assert.throws(() => fixed.run(value.request, host), /profile-already-exists/);
  const lost = fixed.run(value.request, host);
  assert.equal(lost.case_result_set.cases[0].execution_status, 'lost');
  assert.equal(lost.completion.cleanup_status, 'unknown');
  assert.equal(fs.readFileSync(path.join(profile, 'unowned.txt'), 'utf8'), 'keep');
  const recycled = inputs(t);
  store.execute({ root: recycled.config.store_root, operation: 'record-immutable',
    key: 'fixed-browser/fixture-execution/resource', value: { pid: process.pid, process_start_identity: 'another-process' } });
  assert.equal(context(recycled.config).recover('fixture-execution'), 'unknown');
  assert.ok(store.processStartIdentity(process.pid));
});

test('cleanup preserves replaced directories and symlinks without matching inode ownership', t => {
  for (const symlink of [false, true]) {
    const value = inputs(t); const id = value.request.execution_id;
    const profile = path.join(os.tmpdir(), `fkst-fixed-browser-${fixed.sha256(value.config.store_root + '\0' + id)}`);
    const original = path.join(value.temporary, 'original-profile');
    fs.mkdirSync(original); fs.writeFileSync(path.join(original, 'keep'), 'unchanged');
    const stat = fs.lstatSync(original);
    store.execute({ root: value.config.store_root, operation: 'record-immutable', key: `fixed-browser/${id}/profile`,
      value: { device: String(stat.dev), inode: String(stat.ino) } });
    if (symlink) fs.symlinkSync(original, profile);
    else fs.mkdirSync(profile);
    t.after(() => fs.rmSync(profile, { recursive: true, force: true }));
    assert.equal(context(value.config).recover(id), 'unknown');
    assert.equal(fs.lstatSync(profile).isSymbolicLink(), symlink);
    assert.equal(fs.readFileSync(path.join(original, 'keep'), 'utf8'), 'unchanged');
  }
});

test('failed identity lookup cannot signal a live group or remove its profile', async t => {
  const value = inputs(t); const id = value.request.execution_id;
  const profile = path.join(os.tmpdir(), `fkst-fixed-browser-${fixed.sha256(value.config.store_root + '\0' + id)}`);
  fs.mkdirSync(profile); fs.writeFileSync(path.join(profile, 'keep'), 'unchanged');
  t.after(() => fs.rmSync(profile, { recursive: true, force: true }));
  const stat = fs.lstatSync(profile);
  store.execute({ root: value.config.store_root, operation: 'record-immutable', key: `fixed-browser/${id}/profile`,
    value: { device: String(stat.dev), inode: String(stat.ino) } });
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { detached: true, stdio: 'ignore' });
  t.after(() => child.kill('SIGKILL'));
  const identity = store.processStartIdentity(child.pid); assert.ok(identity);
  store.execute({ root: value.config.store_root, operation: 'record-immutable', key: `fixed-browser/${id}/resource`,
    value: { pid: child.pid, process_start_identity: identity } });
  const original = store.processStartIdentity;
  try {
    store.processStartIdentity = () => null;
    assert.equal(context(value.config).recover(id), 'unknown');
    assert.doesNotThrow(() => process.kill(child.pid, 0));
    assert.equal(fs.readFileSync(path.join(profile, 'keep'), 'utf8'), 'unchanged');
  } finally { store.processStartIdentity = original; }
  const stopped = new Promise(resolve => child.once('exit', resolve)); child.kill('SIGKILL'); await stopped;
});

test('real owned Chromium: exact navigate/title/AX target, replay and forbidden network', { timeout: 150000 }, async t => {
  if (!fs.existsSync(CHROME)) {
    assert.notEqual(process.env.FKST_REQUIRE_FIXED_BROWSER, '1', 'required Chromium executable missing');
    t.skip('Set FKST_FIXED_BROWSER_CHROME to Chromium executable; FKST_REQUIRE_FIXED_BROWSER=1 makes absence fatal'); return;
  }
  const requests = [];
  let currentHtml = HTML; let redirect = false; let hang = false;
  const server = http.createServer((req, res) => {
    requests.push(req.url);
    if (hang) return;
    res.writeHead(redirect ? 302 : 200, redirect ? { Location: '/forbidden' } : { 'Content-Type': 'text/html' });
    res.end(currentHtml);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const origin = `http://127.0.0.1:${server.address().port}`;
  for (const [name, html, status] of [
    ['pass', HTML, 'passed'],
    ['title mismatch', HTML.replace('<title>Results', '<title>Unexpected secret'), 'failed'],
    ['missing region', '<!doctype html><title>Results</title><main>Nothing</main>', 'error'],
    ['duplicate region', HTML + '<section role="region" aria-label="Results">Duplicate</section>', 'error'],
    ['hidden region', HTML.replace('role="region"', 'style="display:none" role="region"'), 'error'],
    ['scripts and subresources disabled', HTML + '<script>document.title="Secret";fetch("/forbidden")</script><img src="/forbidden">', 'passed'],
    ['redirect', HTML, 'error'],
    ['fixture digest mismatch', HTML, 'error'],
    ['timeout', HTML, 'error'],
  ]) {
    await t.test(name, async childTest => {
      currentHtml = html; redirect = name === 'redirect'; hang = name === 'timeout';
      const value = inputs(childTest, origin, html);
      if (name === 'fixture digest mismatch') value.policy.fixture_sha256 = '0'.repeat(64);
      if (hang) value.policy.timeout_ms = 1200;
      value.request.plan = fixed.compile(value.candidate, value.policy);
      value.config.grants[0].binding = value.request.plan.binding;
      value.config.grants[0].plan_digest = value.request.plan.content_digest;
      const before = requests.length;
      const first = await cli('run', value);
      assert.equal(first.code, 0, first.stderr);
      const result = JSON.parse(first.stdout);
      assert.equal(result.case_result_set.cases[0].execution_status, status);
      assert.equal(result.completion.cleanup_status, 'complete');
      const requestCount = requests.length - before;
      if (hang) { assert.ok(requestCount <= 1); assert.equal(result.evidence.outcome, 'timeout'); }
      else assert.equal(requestCount, 1);
      if (requestCount) assert.equal(requests.at(-1), '/results');
      assert.equal(first.stdout.includes('Unexpected secret'), false);
      const second = await cli('run', value); assert.equal(second.stdout, first.stdout);
      const verified = await cli('validate-result', value); assert.equal(verified.stdout, first.stdout);
      assert.equal(requests.length - before, requestCount);
      const browser = JSON.parse(fs.readFileSync(path.join(value.config.store_root, 'records/fixed-browser/fixture-execution/browser.json')));
      assert.equal(store.processStartIdentity(browser.pid), null);
    });
  }
  await t.test('simultaneous delivery claims one execution and one navigation', async childTest => {
    currentHtml = HTML; redirect = false; hang = false;
    const value = inputs(childTest, origin); const before = requests.length;
    const [first, second] = await Promise.all([cli('run', value), cli('run', value)]);
    const completed = [first, second].filter(item => item.code === 0);
    assert.ok(completed.length >= 1, first.stderr + second.stderr);
    if (completed.length === 2) assert.equal(first.stdout, second.stdout);
    assert.equal((await cli('run', value)).stdout, completed[0].stdout);
    assert.equal(requests.length - before, 1);
  });
  await t.test('killed Host after navigation recovers lost, kills owned resources, never retries', async childTest => {
    currentHtml = HTML; redirect = false; hang = true;
    const value = inputs(childTest, origin); const before = requests.length;
    const [requestPath, configPath] = writeInputs(value);
    const child = spawn(process.execPath, [CLI, 'run', '--request', requestPath, '--host-config', configPath], { stdio: 'ignore' });
    childTest.after(() => { try { child.kill('SIGKILL'); } catch (_) {} });
    const deadline = Date.now() + 15000;
    while (requests.length === before && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 25));
    assert.equal(requests.length - before, 1);
    const stopped = new Promise(resolve => child.once('exit', resolve)); child.kill('SIGKILL'); await stopped;
    const recovered = await cli('run', value);
    assert.equal(recovered.code, 0, recovered.stderr);
    const result = JSON.parse(recovered.stdout);
    assert.equal(result.case_result_set.cases[0].execution_status, 'lost');
    assert.equal(result.completion.cleanup_status, 'complete');
    assert.equal(requests.length - before, 1);
    const browser = JSON.parse(fs.readFileSync(path.join(value.config.store_root, 'records/fixed-browser/fixture-execution/browser.json')));
    assert.equal(store.processStartIdentity(browser.pid), null);
    assert.equal((await cli('run', value)).stdout, recovered.stdout);
    assert.equal(requests.length - before, 1);
  });
  await t.test('ownership journal failure leaves launch gate closed before Chrome navigation', async childTest => {
    hang = false; redirect = false; currentHtml = HTML;
    const value = inputs(childTest, origin); const before = requests.length;
    store.execute({ root: value.config.store_root, operation: 'record-immutable',
      key: 'fixed-browser/fixture-execution/browser', value: { pid: process.pid, process_start_identity: 'conflicting-owner' } });
    const attempted = await cli('run', value);
    assert.equal(attempted.code, 0, attempted.stderr);
    const result = JSON.parse(attempted.stdout);
    assert.equal(result.case_result_set.cases[0].execution_status, 'error');
    assert.equal(result.completion.cleanup_status, 'unknown');
    assert.equal(requests.length, before);
    assert.ok(store.processStartIdentity(process.pid));
  });
});
