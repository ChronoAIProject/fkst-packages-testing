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

function urlClass(value, baseUrl) {
  if (!value) return 'unknown';
  try {
    const parsed = new URL(value);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return 'non-http';
    const base = new URL(baseUrl);
    return parsed.origin === base.origin ? 'same-origin' : 'cross-origin';
  } catch (_error) {
    return 'invalid';
  }
}

function consoleMessage(params, fallback) {
  const parts = (params && params.args || []).map((argument) => {
    if (argument && argument.value !== undefined) return String(argument.value);
    return argument && (argument.description || argument.type) || '';
  });
  return cleanText(parts.join(' '), fallback);
}

function initiatorUrl(initiator) {
  if (!initiator || typeof initiator !== 'object') return '';
  if (initiator.url) return initiator.url;
  const frames = initiator.stack && initiator.stack.callFrames;
  return Array.isArray(frames) && frames[0] && frames[0].url || '';
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

function eventFacts(events, context = {}) {
  const consoleEvidence = [];
  const networkEvidence = [];
  const rawDiagnostics = [];
  const requests = context.requests instanceof Map ? context.requests : new Map();
  const addRawDiagnostic = (kind, event) => {
    rawDiagnostics.push({ kind, payload: event });
    return rawDiagnostics.length;
  };
  for (const event of events) {
    if (event.method === 'Log.entryAdded') {
      const entry = event.params && event.params.entry;
      if (entry && (entry.level === 'error' || entry.level === 'warning') && consoleEvidence.length < 16) {
        consoleEvidence.push({
          category: entry.level,
          source: 'log',
          message: cleanText(entry.text, entry.level),
          raw_diagnostic_index: addRawDiagnostic('console', event),
        });
      }
    }
    if (event.method === 'Runtime.consoleAPICalled') {
      const type = event.params && event.params.type;
      if ((type === 'error' || type === 'warning') && consoleEvidence.length < 16) {
        consoleEvidence.push({
          category: type,
          source: 'console-api',
          message: consoleMessage(event.params, type),
          raw_diagnostic_index: addRawDiagnostic('console', event),
        });
      }
    }
    if (event.method === 'Network.requestWillBeSent') {
      const params = event.params || {};
      if (params.requestId) {
        requests.set(params.requestId, {
          frameId: params.frameId,
          initiator: params.initiator,
          resourceType: params.type,
          url: params.request && params.request.url,
        });
        if (requests.size > 256) requests.delete(requests.keys().next().value);
      }
    }
    if (event.method === 'Network.loadingFailed' && networkEvidence.length < 16) {
      const params = event.params || {};
      const request = requests.get(params.requestId) || {};
      const resourceType = cleanText(params.type || request.resourceType, 'Other').slice(0, 80);
      const initiator = request.initiator || {};
      const initiatorClass = urlClass(initiatorUrl(initiator), context.baseUrl);
      const fact = {
        resource_type: resourceType,
        url_class: urlClass(request.url, context.baseUrl),
        failure_reason: cleanText(params.errorText || params.blockedReason, 'network failure'),
        canceled: params.canceled === true,
        initiator_type: cleanText(initiator.type, 'unknown').slice(0, 80),
        main_document: resourceType === 'Document'
          && Boolean(context.mainFrameId)
          && request.frameId === context.mainFrameId,
        raw_diagnostic_index: addRawDiagnostic('network-failure', event),
      };
      if (initiatorClass !== 'unknown') fact.initiator_url_class = initiatorClass;
      networkEvidence.push(fact);
      requests.delete(params.requestId);
    }
    if (event.method === 'Network.loadingFinished') requests.delete(event.params && event.params.requestId);
  }
  return {
    console: consoleEvidence.slice(0, 16),
    network: networkEvidence.slice(0, 16),
    raw_diagnostics: rawDiagnostics.slice(0, 32),
  };
}

function receiptBrowserEvidence(facts) {
  return {
    console: facts.console.map((fact) => ({ ...fact })),
    network: facts.network.map((fact) => ({ ...fact })),
  };
}

function normalizeBrowserEvents(events, context) {
  const evidence = eventFacts(events, context);
  return {
    evidence,
    receipt: receiptBrowserEvidence(evidence),
  };
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
    passed = facts.console.length === 0;
    observation = passed ? 'no severe console events' : `${facts.console.length} severe console events`;
  } else if (assertion.type === 'no-failed-document-request') {
    const documentFailures = facts.network.filter((fact) => fact.main_document);
    passed = documentFailures.length === 0;
    observation = passed ? 'no failed document requests' : `${documentFailures.length} failed document requests`;
  }
  return {
    type: assertion.type,
    status: passed ? 'passed' : 'failed',
    observation,
    evidence_pointer: evidencePointer,
  };
}

async function executeAction(cdp, request, action, mainFrameId, browserEventState) {
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
  const browserEvidence = normalizeBrowserEvents(events, {
    baseUrl: request.base_url,
    mainFrameId,
    requests: browserEventState.requests,
  });
  const facts = browserEvidence.evidence;
  const assertionResults = [];
  const actionContext = { ...action, request };
  for (const assertion of action.assertions) {
    assertionResults.push(await assertionResult(cdp, assertion, actionContext, facts, evidencePointer));
  }
  const failed = assertionResults.some((result) => result.status === 'failed');
  const evidence = {
    schema: 'testing-runtime.action-evidence.v1',
    case_id: action.case_id,
    action: action.action,
    sanitized_url: cleanUrl(await evaluate(cdp, 'location.href')),
    severe_console_count: facts.console.length,
    failed_request_count: facts.network.length,
    assertions: assertionResults,
    browser_evidence: facts,
  };
  writeJson(evidencePointer, evidence);
  const result = {
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
  if (facts.console.length > 0 || facts.network.length > 0) result.browser_evidence = browserEvidence.receipt;
  return result;
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
  try {
    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Log.enable');
    await cdp.send('Network.enable');
    const frameTree = await cdp.send('Page.getFrameTree');
    const mainFrameId = frameTree.frameTree && frameTree.frameTree.frame && frameTree.frameTree.frame.id;
    const browserEventState = { requests: new Map() };
    for (const action of request.actions) {
      actions.push(await executeAction(cdp, request, action, mainFrameId, browserEventState));
    }
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
    const normalized = normalizeBrowserEvents([
      {
        method: 'Runtime.consoleAPICalled',
        params: { type: 'warning', args: [{ type: 'string', value: 'image warning' }] },
      },
      {
        method: 'Network.requestWillBeSent',
        params: {
          requestId: 'image-1',
          frameId: 'main-frame',
          type: 'Image',
          request: { url: 'http://localhost:8080/app/missing.png' },
          initiator: { type: 'parser', url: 'http://localhost:8080/app' },
        },
      },
      {
        method: 'Network.loadingFailed',
        params: { requestId: 'image-1', type: 'Image', errorText: 'net::ERR_FAILED', canceled: false },
      },
    ], {
      baseUrl: 'http://localhost:8080/app',
      mainFrameId: 'main-frame',
    });
    if (normalized.evidence.console[0].category !== 'warning'
      || normalized.evidence.network[0].resource_type !== 'Image'
      || normalized.evidence.network[0].main_document !== false
      || normalized.receipt.network[0].raw_diagnostic_index !== 2) {
      throw new Error('browser event normalization failed');
    }
    const requestState = { requests: new Map() };
    normalizeBrowserEvents([{
      method: 'Network.requestWillBeSent',
      params: {
        requestId: 'deferred-image',
        frameId: 'main-frame',
        type: 'Image',
        request: { url: 'http://localhost:8080/app/deferred.png' },
        initiator: { type: 'parser', url: 'http://localhost:8080/app' },
      },
    }], { baseUrl: 'http://localhost:8080/app', requests: requestState.requests });
    const deferred = normalizeBrowserEvents([{
      method: 'Network.loadingFailed',
      params: { requestId: 'deferred-image', type: 'Image', errorText: 'net::ERR_FAILED' },
    }], { baseUrl: 'http://localhost:8080/app', requests: requestState.requests });
    if (deferred.evidence.network[0].url_class !== 'same-origin'
      || deferred.evidence.network[0].initiator_type !== 'parser') {
      throw new Error('browser request correlation failed');
    }
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
  cleanText,
  cleanUrl,
  executeRequest,
  eventFacts,
  normalizeBrowserEvents,
  receiptBrowserEvidence,
  sha256,
  stableStringify,
};
