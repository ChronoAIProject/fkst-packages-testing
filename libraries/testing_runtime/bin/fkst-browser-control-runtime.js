#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const {
  CdpSocket,
  acquireTargetById,
  assertLocalHttpUrl,
} = require('../lib/cdp_client');
const {
  capabilityFor,
  projectObservation,
  sha256,
  validateAction,
} = require('../lib/browser_control');

function parseArgs(argv) {
  const command = argv[2];
  const args = {};
  for (let index = 3; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key || !key.startsWith('--') || value === undefined) throw new Error('arguments must be --key value pairs');
    args[key.slice(2)] = value;
  }
  return { command, args };
}

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'));
}

function writeJson(path, value) {
  fs.writeFileSync(path, `${JSON.stringify(value)}\n`, 'utf8');
}

function closedFields(value, allowed, context) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(context + " must be an object");
  for (const key of Object.keys(value)) if (!allowed.includes(key)) throw new Error(context + " contains unknown field " + key);
}

function validateTitle(value) {
  if (typeof value !== "string" || Buffer.byteLength(value, "utf8") < 1 || Buffer.byteLength(value, "utf8") > 4096
    || /[\u0000-\u001f\u007f]/u.test(value) || /[\ud800-\udfff]/u.test(value)) {
    throw new Error("browser title is missing, malformed, or unbounded");
  }
  return value;
}

function projectTitleResult(raw, request) {
  closedFields(raw, ["url", "title"], "browser title result");
  if (raw.url !== request.url) throw new Error("observed Browser URL does not match the approved target URL");
  return { observed_url: raw.url, observed_title: validateTitle(raw.title) };
}

async function readTitle(input) {
  closedFields(input, ["schema", "cdp_url", "target_id", "target_sha256", "request", "evidence_path"], "browser title input");
  if (input.schema !== "testing-runtime.browser-title-input.v1") throw new Error("browser title input schema is invalid");
  closedFields(input.request, ["schema", "effect_id", "url"], "browser title request");
  if (input.request.schema !== "testing-package-executor.browser-read-title.v1"
    || input.request.effect_id !== "effect-case-home-title-title"
    || input.request.url !== "http://127.0.0.1:4173/") throw new Error("browser title request is invalid");
  if (input.evidence_path !== ".testing/runs/dedup-walking-skeleton/evidence/title.json") throw new Error("browser title evidence path is invalid");
  assertLocalHttpUrl(input.cdp_url, "CDP URL");
  if (typeof input.target_id !== "string" || input.target_sha256 !== sha256(input.target_id)) throw new Error("browser target digest binding is invalid");
  const target = await acquireTargetById(input.cdp_url, input.target_id);
  if (target.url !== input.request.url) throw new Error("approved Browser target URL does not match the request");
  const cdp = new CdpSocket(target.webSocketDebuggerUrl);
  await cdp.connect();
  try {
    await cdp.send("Runtime.enable");
    const evaluated = await cdp.send("Runtime.evaluate", {
      expression: "({url: location.href, title: document.title})",
      returnByValue: true,
    });
    const projected = projectTitleResult(evaluated.result && evaluated.result.value, input.request);
    const evidenceBytes = JSON.stringify(projected);
    fs.mkdirSync(path.dirname(input.evidence_path), { recursive: true });
    fs.writeFileSync(input.evidence_path, evidenceBytes, "utf8");
    return {
      schema: "testing-package-executor.effect-receipt.v1",
      effect_id: input.request.effect_id,
      status: "succeeded",
      observed_url: projected.observed_url,
      observed_title: projected.observed_title,
      evidence_refs: [{ kind: "artifact", ref: input.evidence_path, sha256: sha256(evidenceBytes) }],
      evidence_size_bytes: Buffer.byteLength(evidenceBytes, "utf8"),
    };
  } finally {
    cdp.close();
  }
}

function rawObservationExpression() {
  return `(() => {
    const visible = (element) => {
      const style = window.getComputedStyle(element);
      return style && style.visibility !== 'hidden' && style.display !== 'none'
        && element.getAttribute('aria-hidden') !== 'true' && element.getClientRects().length > 0;
    };
    const kind = (element) => {
      const tag = element.tagName.toLowerCase();
      const type = String(element.getAttribute('type') || '').toLowerCase();
      const role = String(element.getAttribute('role') || '').toLowerCase();
      if (tag === 'button' || role === 'button' || type === 'submit' || type === 'button') return 'button';
      if (tag === 'a' || role === 'link') return 'link';
      if (type === 'password') return 'password';
      if (type === 'checkbox') return 'checkbox';
      if (type === 'radio') return 'radio';
      if (tag === 'select') return 'select';
      if (tag === 'input' || tag === 'textarea' || role === 'textbox') return 'textbox';
      return 'other';
    };
    const role = (element) => String(element.getAttribute('role') || kind(element) || 'control');
    const label = (element) => String(
      element.getAttribute('aria-label')
      || element.getAttribute('placeholder')
      || element.innerText
      || element.getAttribute('title')
      || element.getAttribute('type')
      || role(element)
    );
    const selector = 'button,a[href],input,textarea,select,[role="button"],[role="link"],[role="textbox"],[tabindex]';
    const controls = Array.from(document.querySelectorAll(selector)).filter(visible).slice(0, 32).map((element) => ({
      role: role(element), kind: kind(element), label: label(element), focused: document.activeElement === element,
    }));
    return {
      url: location.href,
      readyState: document.readyState,
      timeOrigin: performance.timeOrigin,
      title: document.title,
      visibleText: String(document.body && document.body.innerText || '').slice(0, 1000),
      controls,
    };
  })()`;
}

function controlExpression(index) {
  return `(() => {
    const visible = (element) => {
      const style = window.getComputedStyle(element);
      return style && style.visibility !== 'hidden' && style.display !== 'none'
        && element.getAttribute('aria-hidden') !== 'true' && element.getClientRects().length > 0;
    };
    const selector = 'button,a[href],input,textarea,select,[role="button"],[role="link"],[role="textbox"],[tabindex]';
    return Array.from(document.querySelectorAll(selector)).filter(visible).slice(0, 32)[${Number(index)}] || null;
  })()`;
}

async function connect(input) {
  assertLocalHttpUrl(input.cdp_url, 'CDP URL');
  if (!input.grant || input.grant.target_sha256 !== sha256(input.grant.target_id)) {
    throw new Error('browser target digest binding is invalid');
  }
  const target = await acquireTargetById(input.cdp_url, input.grant.target_id);
  const cdp = new CdpSocket(target.webSocketDebuggerUrl);
  await cdp.connect();
  await cdp.send('Runtime.enable');
  await cdp.send('Console.enable');
  await cdp.send('Network.enable');
  return { cdp, target };
}

async function observeConnected(cdp, target, input) {
  const targetInfo = await cdp.send('Target.getTargets').catch(() => ({ targetInfos: [] }));
  const pages = (targetInfo.targetInfos || []).filter((item) => item.type === 'page');
  const evaluated = await cdp.send('Runtime.evaluate', {
    expression: rawObservationExpression(),
    returnByValue: true,
  });
  const raw = evaluated.result && evaluated.result.value;
  if (!raw) throw new Error('browser observation is unavailable');
  raw.targetChanged = !pages.some((item) => item.targetId === target.id);
  raw.popupDetected = pages.some((item) => item.targetId !== target.id);
  const events = cdp.takeEvents();
  raw.consoleCount = events.filter((event) => event.method && event.method.startsWith('Console.')).length;
  raw.networkCount = events.filter((event) => event.method && event.method.startsWith('Network.')).length;
  return projectObservation(raw, input.grant, input.turn);
}

async function observe(input) {
  const { cdp, target } = await connect(input);
  try {
    return await observeConnected(cdp, target, input);
  } finally {
    cdp.close();
  }
}

async function applyElementAction(cdp, action, capability, secret) {
  const evaluated = await cdp.send('Runtime.evaluate', {
    expression: controlExpression(capability.index),
    returnByValue: false,
  });
  const objectId = evaluated.result && evaluated.result.objectId;
  if (!objectId) throw new Error('approved browser control is no longer available');
  if (action.kind === 'click') {
    await cdp.send('Runtime.callFunctionOn', { objectId, functionDeclaration: 'function(){ this.click(); }' });
  } else if (action.kind === 'submit') {
    await cdp.send('Runtime.callFunctionOn', {
      objectId,
      functionDeclaration: `function(){
        if (typeof this.requestSubmit === 'function') this.requestSubmit();
        else if (this.form && typeof this.form.requestSubmit === 'function') this.form.requestSubmit();
        else this.click();
      }`,
    });
  } else if (action.kind === 'type') {
    await cdp.send('Runtime.callFunctionOn', {
      objectId,
      functionDeclaration: `function(value){
        this.focus();
        const setter = Object.getOwnPropertyDescriptor(this.constructor.prototype, 'value');
        if (setter && typeof setter.set === 'function') setter.set.call(this, value); else this.value = value;
        this.dispatchEvent(new Event('input', { bubbles: true }));
        this.dispatchEvent(new Event('change', { bubbles: true }));
      }`,
      arguments: [{ value: secret }],
    });
  }
}

async function act(input, capabilities, secret) {
  const action = validateAction(input.action, input.grant, input.turn);
  const { cdp, target } = await connect(input);
  try {
    const before = await observeConnected(cdp, target, input);
    if (before.observation.document_token !== capabilities.document_token
      || before.observation.target_id !== capabilities.target_id) {
      throw new Error('stale browser document or target');
    }
    const capability = capabilityFor(action, capabilities);
    if (capability) {
      const current = before.capabilities.controls.find((entry) => entry.handle === action.handle);
      if (!current || current.fingerprint !== capability.fingerprint || current.index !== capability.index) {
        throw new Error('stale browser handle');
      }
    }
    if (action.kind === 'type') {
      if (typeof secret !== 'string' || secret.length < 1 || secret.length > 4096) {
        throw new Error('secret stdin is missing or unbounded');
      }
      await applyElementAction(cdp, action, capability, secret);
    } else if (action.kind === 'click' || action.kind === 'submit') {
      await applyElementAction(cdp, action, capability);
    } else if (action.kind === 'press_tab') {
      await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Tab', code: 'Tab' });
      await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Tab', code: 'Tab' });
    }
    if (action.kind !== 'finish') await new Promise((resolve) => setTimeout(resolve, 250));
    const after = action.kind === 'finish' ? before : await observeConnected(cdp, target, input);
    return {
      schema: 'testing-runner.ai-browser-control.step-receipt.v1',
      turn: input.turn,
      action,
      before: before.observation,
      after: after.observation,
      status: action.kind === 'finish' ? 'advisory' : 'executed',
      classification: action.kind === 'finish' ? 'ai-finish-advisory' : 'effect-applied',
    };
  } finally {
    cdp.close();
  }
}

async function main() {
  const { command, args } = parseArgs(process.argv);
  if (command === 'observe') {
    const input = readJson(args.input);
    const projected = await observe(input);
    writeJson(args.observation, projected.observation);
    writeJson(args.capabilities, projected.capabilities);
    return;
  }
  if (command === 'read-title') {
    const input = readJson(args.input);
    const receipt = await readTitle(input);
    writeJson(args.receipt, receipt);
    return;
  }
  if (command === 'act') {
    const input = readJson(args.input);
    const capabilities = readJson(args.capabilities);
    const secret = input.action && input.action.kind === 'type' ? fs.readFileSync(0, 'utf8') : undefined;
    const receipt = await act(input, capabilities, secret);
    writeJson(args.receipt, receipt);
    return;
  }
  throw new Error('expected observe or act command');
}

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`${String(error && error.message || error).slice(0, 600)}\n`);
    process.exitCode = 1;
  });
}

module.exports = { act, observe, projectTitleResult, rawObservationExpression, readTitle, validateTitle };
