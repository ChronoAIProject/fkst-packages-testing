#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { CdpSocket } = require('../lib/cdp_client');
const { check, sha256 } = require('../lib/deterministic_browser');
const store = require('../../../examples/generic-host/bin/durable-host-store');

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function execute(input) {
  const { plan, policy, root, execution_id: id, profile } = input;
  let chrome; let cdp; let deadlineTimer; let closed = false; let profileIdentity;
  const result = { outcome: 'error', observed_title: null, target_status: 'unresolved', cleanup_status: 'unknown' };
  const deadline = Date.now() + plan.timeout_ms;
  const expired = () => Date.now() >= deadline;
  const recordOwner = (suffix, pid) => {
    const identity = store.processStartIdentity(pid);
    check(identity !== null, 'browser-owner-unavailable');
    const saved = store.execute({ root, operation: 'record-immutable', key: `fixed-browser/${id}/${suffix}`,
      value: { pid, process_start_identity: identity } });
    check(saved.written, 'browser-owner-conflict');
  };
  function closeCdp() {
    if (!cdp) return;
    for (const pending of cdp.pending.values()) clearTimeout(pending.timer);
    cdp.rejectAll(new Error('fixed-browser closed'));
    if (cdp.socket) cdp.socket.destroy();
  }
  try {
    recordOwner('resource', process.pid);
    check(!fs.existsSync(profile), 'ambient-profile-forbidden');
    fs.mkdirSync(profile, { mode: 0o700 });
    const stat = fs.lstatSync(profile);
    profileIdentity = { device: String(stat.dev), inode: String(stat.ino) };
    check(store.execute({ root, operation: 'record-immutable', key: `fixed-browser/${id}/profile`,
      value: profileIdentity }).written, 'profile-owner-conflict');
    // Keep the child inert until its PID/start identity is durable. EOF before
    // release exits the launcher without ever starting Chromium.
    chrome = spawn('/bin/sh', ['-c', 'IFS= read -r ready && [ "$ready" = start ] && exec "$@"', 'fixed-browser',
      input.chrome_path, '--headless=new', '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1',
      `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--disable-extensions',
      '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-default-apps',
      '--disable-domain-reliability', '--metrics-recording-only', '--disable-breakpad', '--disable-crash-reporter',
      '--password-store=basic', '--use-mock-keychain', '--no-proxy-server', '--no-startup-window'], { stdio: ['pipe', 'ignore', 'ignore'] });
    chrome.on('error', () => { closed = true; });
    chrome.on('exit', () => { closed = true; });
    check(Number.isInteger(chrome.pid), 'chrome-start-failed');
    recordOwner('browser', chrome.pid);
    chrome.stdin.end('start\n');
    deadlineTimer = setTimeout(() => { chrome.kill('SIGKILL'); }, plan.timeout_ms);
    const portFile = path.join(profile, 'DevToolsActivePort');
    while (!fs.existsSync(portFile)) {
      check(!closed && !expired(), 'chrome-start-failed'); await delay(25);
    }
    const port = fs.readFileSync(portFile, 'utf8').split('\n')[0];
    check(/^[1-9][0-9]{0,4}$/.test(port), 'debugger-port-invalid');
    const response = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, {
      method: 'PUT', signal: AbortSignal.timeout(Math.max(1, deadline - Date.now())),
    });
    check(response.ok, 'debugger-target-failed');
    const target = await response.json();
    cdp = new CdpSocket(target.webSocketDebuggerUrl);
    await cdp.connect();
    let navigationRequests = 0; let acceptedResponse = false; let networkViolation = false;
    const eventTasks = new Set();
    const original = cdp.handleMessage.bind(cdp);
    cdp.handleMessage = function handleMessage(text) {
      const message = JSON.parse(text);
      if (message.method !== 'Fetch.requestPaused') { original(text); return; }
      const task = handleRequest(message.params).catch(() => { networkViolation = true; });
      eventTasks.add(task); task.finally(() => eventTasks.delete(task));
    };
    async function handleRequest(event) {
      const req = event.request;
      const isResponse = event.responseStatusCode !== undefined || event.responseErrorReason !== undefined;
      const allowed = event.resourceType === 'Document' && req.method === 'GET' && req.url === plan.action.url;
      const credentials = Object.keys(req.headers || {}).some(key => /^(cookie|authorization|proxy-authorization)$/i.test(key));
      if (!allowed || credentials || (!isResponse && navigationRequests !== 0)) {
        networkViolation = true;
        await cdp.send('Fetch.failRequest', { requestId: event.requestId, errorReason: 'BlockedByClient' }); return;
      }
      if (!isResponse) {
        navigationRequests += 1;
        await cdp.send('Fetch.continueRequest', { requestId: event.requestId }); return;
      }
      const headers = event.responseHeaders || [];
      const contentType = headers.find(header => header.name.toLowerCase() === 'content-type');
      if (event.responseStatusCode !== 200 || !contentType || !/^text\/html(?:;|$)/i.test(contentType.value)
        || headers.some(header => /^(set-cookie|location|refresh)$/i.test(header.name))) {
        networkViolation = true;
        await cdp.send('Fetch.failRequest', { requestId: event.requestId, errorReason: 'BlockedByClient' }); return;
      }
      const body = await cdp.send('Fetch.getResponseBody', { requestId: event.requestId });
      const bytes = Buffer.from(body.body, body.base64Encoded ? 'base64' : 'utf8');
      if (bytes.length > 65536 || sha256(bytes) !== policy.fixture_sha256) {
        networkViolation = true;
        await cdp.send('Fetch.failRequest', { requestId: event.requestId, errorReason: 'BlockedByClient' }); return;
      }
      acceptedResponse = true;
      // The Host-pinned fixture bytes are served with a restrictive document CSP.
      // All original headers are discarded; no cookies, refresh or auth state.
      await cdp.send('Fetch.fulfillRequest', { requestId: event.requestId, responseCode: 200,
        responseHeaders: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' },
          { name: 'Content-Security-Policy', value: "default-src 'none'; style-src 'unsafe-inline'; script-src 'none'; frame-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'" }],
        body: bytes.toString('base64') });
    }
    await cdp.send('Page.enable');
    await cdp.send('Network.enable');
    await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });
    await cdp.send('Network.setBypassServiceWorker', { bypass: true });
    await cdp.send('Emulation.setScriptExecutionDisabled', { value: true });
    await cdp.send('Fetch.enable', { patterns: [{ urlPattern: '*', requestStage: 'Request' }, { urlPattern: '*', requestStage: 'Response' }] });
    const nav = await cdp.send('Page.navigate', { url: plan.action.url });
    check(!nav.errorText, 'navigation-failed');
    let state;
    while (!expired()) {
      const responseState = await cdp.send('Runtime.evaluate', {
        expression: '({ready:document.readyState,url:location.href,title:document.title})', returnByValue: true,
      });
      state = responseState.result && responseState.result.value;
      if (state && state.ready === 'complete' && state.url === plan.action.url && acceptedResponse) break;
      check(!networkViolation, 'network-policy-violation'); await delay(25);
    }
    check(!expired() && acceptedResponse && navigationRequests === 1 && !networkViolation, 'navigation-unverified');
    const tree = await cdp.send('Accessibility.getFullAXTree');
    const matches = tree.nodes.filter(node => !node.ignored && node.role && node.role.value === 'region'
      && node.name && node.name.value === policy.target_resolution.accessible_name);
    check(matches.length === 1 && matches[0].backendDOMNodeId, 'target-not-unique');
    const box = await cdp.send('DOM.getBoxModel', { backendNodeId: matches[0].backendDOMNodeId });
    check(box.model && box.model.width > 0 && box.model.height > 0, 'target-not-visible');
    await Promise.all(eventTasks);
    check(!networkViolation && !expired(), 'browser-policy-violation');
    result.outcome = 'observed'; result.target_status = 'unique-visible';
    result.observed_title = state.title === plan.assertion.expected ? plan.assertion.expected : '[title differs]';
  } catch (_) {
    result.outcome = expired() ? 'timeout' : 'error';
    result.observed_title = null; result.target_status = 'unresolved';
  } finally {
    clearTimeout(deadlineTimer);
    if (chrome && !closed) {
      chrome.kill('SIGKILL');
      let cleanupTimer;
      await Promise.race([once(chrome, 'exit').catch(() => {}), new Promise(resolve => { cleanupTimer = setTimeout(resolve, 2000); })]);
      clearTimeout(cleanupTimer);
    }
    closeCdp();
    // Only the Host may remove the profile after verifying the entire group and
    // the durable directory device/inode; parent exit alone is insufficient.
  }
  return result;
}

if (require.main === module) {
  let input = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => { input += chunk; if (input.length > 65536) process.exit(1); });
  process.stdin.on('end', () => execute(JSON.parse(input)).then(result => {
    process.stdout.write(JSON.stringify(result) + '\n');
  }).catch(() => { process.exitCode = 1; }));
}
