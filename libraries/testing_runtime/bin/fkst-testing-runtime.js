#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const {
  CdpSocket,
  acquireTarget,
  assertLocalHttpUrl,
  pageStateReady,
  waitForPage,
} = require('../lib/cdp_client');

const REDACTION_MASK_RGB = [217, 48, 37];
const redactionSelectorPattern = /^(?:#[A-Za-z][A-Za-z0-9_-]*|\.[A-Za-z][A-Za-z0-9_-]*|\[data-[A-Za-z][A-Za-z0-9_-]*\])$/;

function stableStringify(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(',')}}`;
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function parseArgs(argv) {
  const values = { paths: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const item = argv[index];
    if (item === '--path') values.paths.push(argv[++index]);
    else if (item.startsWith('--')) values[item.slice(2).replace(/-([a-z])/g, (_all, char) => char.toUpperCase())] = argv[++index];
  }
  return values;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${stableStringify(value)}\n`);
}

function writeBinary(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, value);
}

function safeArtifactPath(value) {
  const text = String(value || '');
  if (!text.startsWith('.testing/runs/') || text.startsWith('/') || text.includes('\\') || /\s/.test(text)) return false;
  if (!/^[A-Za-z0-9._\-/#]+$/.test(text)) return false;
  return text.split('/').every((segment) => segment !== '.' && segment !== '..');
}

function cleanText(value, fallback = '') {
  const text = String(value || '').replace(/[\x00-\x1f\x7f]/g, ' ').replace(/\s+/g, ' ').trim();
  return (text || fallback).slice(0, 512);
}

function cleanUrl(value) {
  try {
    const parsed = new URL(value);
    parsed.search = '';
    parsed.hash = '';
    parsed.username = '';
    parsed.password = '';
    return parsed.toString();
  } catch (_error) {
    return '';
  }
}

function allowedUrl(value, request) {
  const parsed = assertLocalHttpUrl(value, 'action URL');
  const base = assertLocalHttpUrl(request.base_url, 'base URL');
  const origins = new Set((request.allowed_origins || []).map((item) => new URL(item).origin.toLowerCase()));
  if (!origins.has(parsed.origin.toLowerCase()) || parsed.origin.toLowerCase() !== base.origin.toLowerCase()) return false;
  const prefix = base.pathname.endsWith('/') ? base.pathname : `${base.pathname}/`;
  return prefix === '/' || parsed.pathname === prefix.slice(0, -1) || parsed.pathname.startsWith(prefix);
}

async function evaluate(cdp, expression) {
  const response = await cdp.send('Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (response.exceptionDetails) throw new Error('runtime evaluation failed');
  return response.result && response.result.value;
}

function textProbeExpression(target, click) {
  const encoded = JSON.stringify(String(target || ''));
  return `(() => {
    const wanted = ${encoded}.trim().toLowerCase();
    const visible = (node) => !!node && !!(node.offsetWidth || node.offsetHeight || node.getClientRects().length);
    const nodes = Array.from(document.querySelectorAll('button,a,[role="button"],input,textarea,select,[data-testid]')).filter(visible);
    const node = nodes.find((item) => String(item.innerText || item.textContent || item.value || item.getAttribute('aria-label') || '').trim().toLowerCase().includes(wanted));
    if (!node) return { found: false, label: '' };
    ${click ? 'node.click();' : ''}
    return { found: true, label: String(node.innerText || node.textContent || node.value || node.getAttribute('aria-label') || '').trim().slice(0, 120) };
  })()`;
}

function redactionExpression(selectors) {
  const encoded = JSON.stringify(selectors);
  const color = `rgb(${REDACTION_MASK_RGB.join(', ')})`;
  return `(() => {
    const selectors = ${encoded};
    const marker = 'data-fkst-redaction-overlay';
    document.querySelectorAll('[' + marker + ']').forEach((node) => node.remove());
    let maskCount = 0;
    for (const selector of selectors) {
      let nodes;
      try {
        nodes = Array.from(document.querySelectorAll(selector));
      } catch (_error) {
        return { ok: false, selector_count: selectors.length, mask_count: maskCount };
      }
      let selectorMaskCount = 0;
      for (const node of nodes) {
        const style = getComputedStyle(node);
        const rect = node.getBoundingClientRect();
        const left = Math.max(0, Math.floor(rect.left));
        const top = Math.max(0, Math.floor(rect.top));
        const right = Math.min(window.innerWidth, Math.ceil(rect.right));
        const bottom = Math.min(window.innerHeight, Math.ceil(rect.bottom));
        if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0 || right <= left || bottom <= top) continue;
        const overlay = document.createElement('div');
        overlay.setAttribute(marker, '');
        Object.assign(overlay.style, {
          position: 'fixed',
          left: left + 'px',
          top: top + 'px',
          width: (right - left) + 'px',
          height: (bottom - top) + 'px',
          margin: '0',
          padding: '0',
          border: '0',
          borderRadius: '0',
          background: '${color}',
          boxShadow: 'none',
          opacity: '1',
          mixBlendMode: 'normal',
          pointerEvents: 'none',
          zIndex: '2147483647',
        });
        document.documentElement.appendChild(overlay);
        selectorMaskCount += 1;
        maskCount += 1;
      }
      if (selectorMaskCount === 0) {
        document.querySelectorAll('[' + marker + ']').forEach((node) => node.remove());
        return { ok: false, selector_count: selectors.length, mask_count: maskCount };
      }
    }
    return { ok: true, selector_count: selectors.length, mask_count: maskCount };
  })()`;
}

function validateRedactionSelectors(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 16) throw new Error('screenshot redaction configuration is invalid');
  for (const selector of value) {
    if (typeof selector !== 'string' || selector.length > 120 || !redactionSelectorPattern.test(selector)) {
      throw new Error('screenshot redaction configuration is invalid');
    }
  }
  return value;
}

async function captureFailureScreenshot(cdp, request) {
  const selectors = validateRedactionSelectors(request.redaction_selectors);
  const screenshotPath = `${request.artifact_root}/evidence/screenshots/failure.png`;
  let cleanupRequired = false;
  let screenshot;
  try {
    cleanupRequired = true;
    const redaction = await evaluate(cdp, redactionExpression(selectors));
    if (!redaction || redaction.ok !== true || redaction.mask_count < selectors.length) {
      throw new Error('screenshot redaction could not mask every configured element');
    }
    await evaluate(cdp, 'new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))');
    screenshot = await cdp.send('Page.captureScreenshot', {
      format: 'png',
      fromSurface: true,
      captureBeyondViewport: false,
    });
  } finally {
    if (cleanupRequired) {
      await evaluate(cdp, `(() => { document.querySelectorAll('[data-fkst-redaction-overlay]').forEach((node) => node.remove()); return true; })()`);
    }
  }
  const body = Buffer.from(String(screenshot && screenshot.data || ''), 'base64');
  const pngSignature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (body.length <= pngSignature.length || !body.subarray(0, pngSignature.length).equals(pngSignature)) {
    throw new Error('captured screenshot is not a valid PNG');
  }
  writeBinary(screenshotPath, body);
  return {
    path: screenshotPath,
    media_type: 'image/png',
    size_bytes: body.length,
    sha256: sha256(body),
  };
}

function eventFacts(events) {
  const severeConsole = [];
  const failedRequests = [];
  for (const event of events) {
    if (event.method === 'Log.entryAdded') {
      const entry = event.params && event.params.entry;
      if (entry && (entry.level === 'error' || entry.level === 'warning')) severeConsole.push(cleanText(entry.text, entry.level));
    }
    if (event.method === 'Runtime.consoleAPICalled') {
      const type = event.params && event.params.type;
      if (type === 'error' || type === 'warning') severeConsole.push(type);
    }
    if (event.method === 'Network.loadingFailed') {
      failedRequests.push(cleanText(event.params && event.params.errorText, 'network failure'));
    }
  }
  return { severeConsole: severeConsole.slice(0, 16), failedRequests: failedRequests.slice(0, 16) };
}

async function assertionResult(cdp, assertion, action, facts, evidencePointer) {
  let passed = false;
  let observation = '';
  if (assertion.type === 'url-within-scope') {
    const current = await evaluate(cdp, 'location.href');
    passed = allowedUrl(current, action.request);
    observation = cleanUrl(current);
  } else if (assertion.type === 'document-ready') {
    const state = await evaluate(cdp, 'document.readyState');
    passed = state === 'interactive' || state === 'complete';
    observation = `document.readyState=${cleanText(state)}`;
  } else if (assertion.type === 'visible-text-present' || assertion.type === 'visible-target-present') {
    const target = assertion.target || assertion.expected || action.target;
    const result = await evaluate(cdp, textProbeExpression(target, false));
    passed = Boolean(result && result.found);
    observation = passed ? `visible target: ${cleanText(result.label)}` : `visible target missing: ${cleanText(target)}`;
  } else if (assertion.type === 'no-severe-console') {
    passed = facts.severeConsole.length === 0;
    observation = passed ? 'no severe console events' : `${facts.severeConsole.length} severe console events`;
  } else if (assertion.type === 'no-failed-document-request') {
    passed = facts.failedRequests.length === 0;
    observation = passed ? 'no failed document requests' : `${facts.failedRequests.length} failed requests`;
  }
  return {
    type: assertion.type,
    status: passed ? 'passed' : 'failed',
    observation,
    evidence_pointer: evidencePointer,
  };
}

async function executeAction(cdp, request, action, evidenceState) {
  const evidencePointer = `${request.artifact_root}/evidence/execution/${String(action.case_id).replace(/[^A-Za-z0-9._-]/g, '-')}.json`;
  const actionUrl = action.url || request.base_url;
  if (!allowedUrl(actionUrl, request)) throw new Error(`action left allowed scope: ${action.case_id}`);

  if (action.action === 'navigate' || action.action === 'bounded-navigation') {
    const previousTimeOrigin = await evaluate(cdp, 'performance.timeOrigin');
    await cdp.send('Page.navigate', { url: actionUrl });
    await waitForPage(cdp, previousTimeOrigin);
  } else if (action.action === 'wait-for-load') {
    await waitForPage(cdp);
  } else if (action.action === 'open-visible-surface') {
    const result = await evaluate(cdp, textProbeExpression(action.target, true));
    if (!result || !result.found) throw new Error(`visible target not found: ${cleanText(action.target)}`);
    await new Promise((resolve) => setTimeout(resolve, 100));
  } else if (action.action === 'safe-mutation-fixture') {
    throw new Error('safe mutation fixture runtime is not implemented');
  } else if (action.action === 'inspect-visible-elements') {
    await evaluate(cdp, textProbeExpression(action.target, false));
  } else if (action.action !== 'collect-console-network-health') {
    throw new Error(`unsupported action: ${action.action}`);
  }

  const events = cdp.takeEvents();
  const facts = eventFacts(events);
  const assertionResults = [];
  const actionContext = { ...action, request };
  for (const assertion of action.assertions) {
    const result = await assertionResult(cdp, assertion, actionContext, facts, evidencePointer);
    if (result.status === 'failed' && evidenceState.failureScreenshot === null && request.redaction_selectors !== undefined) {
      evidenceState.failureScreenshot = await captureFailureScreenshot(cdp, request);
      result.screenshot_artifact = evidenceState.failureScreenshot;
    }
    assertionResults.push(result);
  }
  const failed = assertionResults.some((result) => result.status === 'failed');
  const evidence = {
    schema: 'testing-runtime.action-evidence.v1',
    case_id: action.case_id,
    action: action.action,
    sanitized_url: cleanUrl(await evaluate(cdp, 'location.href')),
    severe_console_count: facts.severeConsole.length,
    failed_request_count: facts.failedRequests.length,
    assertions: assertionResults,
  };
  writeJson(evidencePointer, evidence);
  return {
    step: action.step,
    case_id: action.case_id,
    action: action.action,
    execution_status: failed ? 'failed' : 'executed',
    assertion_status: failed ? 'failed' : 'passed',
    observation: failed ? 'one or more typed assertions failed' : 'typed browser action and assertions completed',
    evidence_pointer: evidencePointer,
    assertion_results: assertionResults,
    ...(action.fixture_receipt_path ? { fixture_receipt_path: action.fixture_receipt_path } : {}),
  };
}

async function executeRequest(request, receiptPath) {
  assertLocalHttpUrl(request.base_url, 'base URL');
  assertLocalHttpUrl(request.cdp_url, 'CDP URL');
  if (!safeArtifactPath(request.artifact_root)) throw new Error('artifact_root is unsafe');
  const basis = { ...request };
  delete basis.plan_sha256;
  const actualDigest = sha256(stableStringify(basis));
  if (actualDigest !== request.plan_sha256) throw new Error('request plan digest mismatch');

  const wsUrl = await acquireTarget(request.cdp_url, request.base_url);
  const cdp = new CdpSocket(wsUrl);
  await cdp.connect();
  const actions = [];
  const evidenceState = { failureScreenshot: null };
  try {
    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Log.enable');
    await cdp.send('Network.enable');
    for (const action of request.actions) actions.push(await executeAction(cdp, request, action, evidenceState));
  } finally {
    cdp.close();
  }
  const executed = actions.filter((action) => action.execution_status === 'executed').length;
  const failed = actions.filter((action) => action.execution_status === 'failed').length;
  const blocked = actions.filter((action) => action.execution_status === 'blocked').length;
  const status = failed > 0 ? 'failed' : blocked > 0 ? 'degraded' : executed > 0 ? 'passed' : 'blocked';
  const receipt = {
    schema: 'testing-runtime.execution-receipt.v1',
    module: request.module,
    request_sha256: request.plan_sha256,
    status,
    classification: status === 'passed' ? 'typed-browser-assertions-passed' : status === 'failed' ? 'typed-browser-assertion-failed' : 'browser-execution-incomplete',
    action_count: actions.length,
    executed_action_count: executed,
    failed_action_count: failed,
    blocked_action_count: blocked,
    actions,
  };
  writeJson(receiptPath, receipt);
  return receipt;
}

function mediaType(filePath) {
  if (filePath.endsWith('.json')) return 'application/json';
  if (filePath.endsWith('.md')) return 'text/markdown';
  if (filePath.endsWith('.png')) return 'image/png';
  return 'application/octet-stream';
}

function buildManifest(root, paths, out) {
  if (!safeArtifactPath(root) || !safeArtifactPath(out)) throw new Error('manifest path is unsafe');
  const unique = Array.from(new Set(paths)).sort();
  const entries = unique.map((filePath) => {
    if (!safeArtifactPath(filePath) || !filePath.startsWith(`${root}/`) || filePath === out) throw new Error(`manifest path is invalid: ${filePath}`);
    const body = fs.readFileSync(filePath);
    return {
      path: filePath,
      media_type: mediaType(filePath),
      size_bytes: body.length,
      sha256: sha256(body),
    };
  });
  const rootDigest = sha256(entries.map((entry) => `${entry.path}\0${entry.size_bytes}\0${entry.sha256}\n`).join(''));
  const manifest = {
    schema: 'test-artifacts.manifest.v1',
    artifact_root: root,
    algorithm: 'sha256',
    entries,
    entry_count: entries.length,
    root_digest: rootDigest,
  };
  writeJson(out, manifest);
  return manifest;
}

async function main(argv) {
  const command = argv[0];
  const options = parseArgs(argv.slice(1));
  if (command === 'hash-json') {
    const value = readJson(options.input);
    process.stdout.write(`${sha256(stableStringify(value))}\n`);
    return;
  }
  if (command === 'manifest') {
    buildManifest(options.root, options.paths, options.out);
    return;
  }
  if (command === 'execute') {
    await executeRequest(readJson(options.request), options.receipt);
    return;
  }
  if (command === 'self-test') {
    const digest = sha256(stableStringify({ b: 2, a: 1 }));
    if (digest !== sha256('{"a":1,"b":2}')) throw new Error('stable hashing failed');
    const previousTimeOrigin = 1000;
    if (pageStateReady({ readyState: 'complete', timeOrigin: previousTimeOrigin }, previousTimeOrigin)) {
      throw new Error('stale document readiness was accepted');
    }
    if (!pageStateReady({ readyState: 'interactive', timeOrigin: previousTimeOrigin + 1 }, previousTimeOrigin)) {
      throw new Error('new document readiness was rejected');
    }
    let credentialUrlRejected = false;
    try {
      assertLocalHttpUrl('http://user:secret@127.0.0.1:9222', 'self-test URL');
    } catch (_error) {
      credentialUrlRejected = true;
    }
    if (!credentialUrlRejected) throw new Error('credential-bearing loopback URL was accepted');
    process.stdout.write('fkst-testing-runtime: self-test passed\n');
    return;
  }
  throw new Error(`unknown command: ${command}`);
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`fkst-testing-runtime: ${error.message}\n`);
    process.exitCode = 1;
  });
}

module.exports = {
  allowedUrl,
  buildManifest,
  captureFailureScreenshot,
  cleanText,
  cleanUrl,
  executeRequest,
  sha256,
  stableStringify,
};
