#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { execute: storeExecute, stable } = require('./durable-host-store');

function environmentRuntimeHelper(name) {
  const candidates = [
    path.resolve(__dirname, '../../../packages/environment-factory/bin/runtime', name),
    path.resolve(__dirname, '../../environment-factory/bin/runtime', name),
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(`${candidate}.js`)) return require(candidate);
  }
  fail(`environment-factory runtime helper is unavailable: ${name}`);
}

const {
  pathIdentity, processAlive, processStartIdentity, removeOwnedDirectory, samePathIdentity, sleep,
} = environmentRuntimeHelper('common');
const {
  listenerOwners, listenersOwnedByProcessGroup, listenersReleased, processGroupState, terminateProcessGroup,
} = environmentRuntimeHelper('platform');

function fail(message) {
  throw new Error(`generic-host runtime: ${message}`);
}

function sha256(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

function durableRoot() {
  const value = process.env.FKST_GENERIC_HOST_DURABLE_ROOT || process.env.FKST_DURABLE_ROOT;
  if (typeof value !== 'string' || !path.isAbsolute(value)) fail('generic Host durable root must be absolute');
  return path.resolve(value);
}

function safeArtifactPath(value) {
  return typeof value === 'string' && value.startsWith('.testing/runs/')
    && !value.includes('\0') && !value.includes('\\')
    && value.split('/').every((segment) => segment !== '' && segment !== '.' && segment !== '..');
}

function readRuntimeConfig(payload) {
  const ref = payload.runtime_config_ref;
  if (ref == null) return { project_root: process.cwd() };
  if (!ref || ref.kind !== 'artifact' || typeof ref.ref !== 'string'
    || !ref.ref.startsWith('.testing/') || ref.ref.includes('..') || path.isAbsolute(ref.ref)) {
    fail('runtime config ref is invalid');
  }
  const target = path.resolve(process.cwd(), ref.ref);
  const testingRoot = path.resolve(process.cwd(), '.testing');
  if (target !== testingRoot && !target.startsWith(`${testingRoot}${path.sep}`)) fail('runtime config escaped .testing');
  const config = JSON.parse(fs.readFileSync(target, 'utf8'));
  if (config.schema !== 'generic-host.runtime-config.v1' || typeof config.project_root !== 'string') {
    fail('runtime config schema is invalid');
  }
  return config;
}

function hostRoot() {
  return path.join(durableRoot(), 'generic-host');
}

function runRoot(runId) {
  if (typeof runId !== 'string' || !/^[A-Za-z0-9._-]+$/.test(runId)) fail('run_id is invalid');
  return path.join(hostRoot(), runId);
}

function recordRead(root, key) {
  const result = storeExecute({ root, operation: 'record-read', key });
  return result.found ? result.value : null;
}

function recordList(root, prefix) {
  return storeExecute({ root, operation: 'record-list', prefix }).entries;
}

function recordImmutable(root, key, value) {
  return storeExecute({ root, operation: 'record-immutable', key, value });
}

function recordCas(root, key, value, expectedVersion) {
  return storeExecute({ root, operation: 'record-cas', key, value, expected_version: expectedVersion });
}

function recordClaim(root, key, value) {
  return storeExecute({ root, operation: 'record-claim', key, value });
}

function runIdFromPath(value) {
  if (typeof value !== 'string') return null;
  const match = /^\.testing\/runs\/([^/]+)/.exec(value);
  return match && match[1];
}

function candidatePaths(payload) {
  const values = [payload.path, payload.artifact_root, payload.artifact_ref, payload.receipt_ref,
    payload.result_ref, payload.ledger_ref, payload.aggregate_report_ref, payload.cleanup_receipt_ref];
  for (const value of Object.values(payload)) {
    if (value && typeof value === 'object' && typeof value.ref === 'string') values.push(value.ref);
  }
  return values;
}

function runIdFor(payload) {
  if (typeof payload.run_id === 'string') return payload.run_id;
  if (payload.request && typeof payload.request.run_id === 'string') return payload.request.run_id;
  if (payload.source_ref && typeof payload.source_ref.ref === 'string'
    && /^[A-Za-z0-9._-]+$/.test(payload.source_ref.ref)) return payload.source_ref.ref;
  for (const value of candidatePaths(payload)) {
    const runId = runIdFromPath(value);
    if (runId) return runId;
  }
  if (typeof payload.dedup_key === 'string' && /^[A-Za-z0-9._-]+$/.test(payload.dedup_key)) {
    return payload.dedup_key;
  }
  fail('run_id cannot be derived from request');
}

function loadConfig(projectRoot, runId) {
  const config = recordRead(runRoot(runId), 'generic-host/config');
  if (!config || config.schema !== 'generic-host.durable-workflow-qa.v1'
    || config.run_id !== runId || path.resolve(config.project_root) !== path.resolve(projectRoot)) {
    fail('durable run config is unavailable or foreign');
  }
  return config;
}

function artifactFile(projectRoot, logicalPath) {
  if (!safeArtifactPath(logicalPath)) fail('artifact path is invalid');
  const target = path.resolve(projectRoot, logicalPath);
  const testingRoot = path.resolve(projectRoot, '.testing');
  if (!target.startsWith(`${testingRoot}${path.sep}`)) fail('artifact path escaped project root');
  return target;
}

function atomicWrite(filePath, body) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const temporary = `${filePath}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
  const fd = fs.openSync(temporary, 'wx', 0o600);
  try {
    fs.writeFileSync(fd, body, 'utf8');
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(temporary, filePath);
}

function artifactRead(projectRoot, logicalPath) {
  const runId = runIdFromPath(logicalPath);
  if (!runId) fail('artifact path has no run id');
  loadConfig(projectRoot, runId);
  let result = storeExecute({ root: runRoot(runId), operation: 'artifact-read', path: logicalPath });
  if (!result.found) {
    const target = artifactFile(projectRoot, logicalPath);
    if (!fs.existsSync(target)) return null;
    const body = fs.readFileSync(target, 'utf8');
    storeExecute({ root: runRoot(runId), operation: 'artifact-write', path: logicalPath, body });
    result = { found: true, body, digest: sha256(body) };
  }
  const target = artifactFile(projectRoot, logicalPath);
  if (!fs.existsSync(target)) atomicWrite(target, result.body);
  let value;
  try { value = JSON.parse(result.body); } catch (_error) { value = result.body; }
  return { value, raw: result.body, digest: result.digest };
}

function artifactWrite(projectRoot, logicalPath, value) {
  const runId = runIdFromPath(logicalPath);
  if (!runId) fail('artifact path has no run id');
  loadConfig(projectRoot, runId);
  const body = `${stable(value)}\n`;
  const result = storeExecute({ root: runRoot(runId), operation: 'artifact-write', path: logicalPath, body });
  if (!result.written) fail('immutable artifact differs');
  const target = artifactFile(projectRoot, logicalPath);
  if (fs.existsSync(target)) {
    if (fs.readFileSync(target, 'utf8') !== body) fail('materialized artifact differs');
  } else {
    atomicWrite(target, body);
  }
  return { written: true, replayed: result.replayed === true, digest: result.digest };
}

function listIndexedRuns(projectRoot) {
  const runs = [];
  for (const entry of recordList(hostRoot(), 'runs')) {
    const value = entry.value;
    if (value && value.schema === 'generic-host.durable-workflow-qa-index.v1'
      && path.resolve(value.project_root) === path.resolve(projectRoot)
      && typeof value.run_id === 'string') runs.push(value.run_id);
  }
  return runs.sort();
}

function requestFor(projectRoot, runId) {
  loadConfig(projectRoot, runId);
  return recordRead(runRoot(runId), `workflow-qa/requests/${runId}`);
}

function pendingRequests(projectRoot, limit) {
  if (!Number.isInteger(limit) || limit < 1 || limit > 64) fail('pending run limit must be from 1 to 64');
  const pending = [];
  for (const runId of listIndexedRuns(projectRoot)) {
    const request = requestFor(projectRoot, runId);
    const state = recordRead(runRoot(runId), `workflow-qa/state/${runId}`);
    const terminal = recordRead(runRoot(runId), `generic-host/terminal/${runId}`);
    if (request && state && (state.phase !== 'terminal' || !terminal)) pending.push(request);
    if (pending.length >= limit) break;
  }
  return pending;
}

function publicationResult(projectRoot, payload) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  loadConfig(projectRoot, runId);
  const key = `test-publication/effects/${sha256(stable(payload))}`;
  const existing = recordRead(root, key);
  if (existing) {
    if (stable(existing.binding) !== stable(payload)) fail('publication binding differs');
    return existing.result;
  }
  let result;
  if (payload.channel === 'filesystem-dry-run-v1') {
    const artifactRoot = `.testing/runs/${runId}`;
    const receiptRef = `${artifactRoot}/published/${payload.stage}-${payload.attempt}-materialization.json`;
    const receipt = {
      schema: 'test-publication.qa-materialization-receipt.v1',
      status: 'materialized',
      channel: 'filesystem-dry-run-v1',
      run_id: runId,
      stage: payload.stage,
      attempt: payload.attempt,
      artifact_ref: payload.artifact_ref,
      digest: payload.digest,
      source_commit: payload.repository.commit_sha,
      receipt_ref: receiptRef,
      trace_id: payload.trace_id,
      dedup_key: payload.dedup_key,
    };
    const written = artifactWrite(projectRoot, receiptRef, receipt);
    result = {
      status: 'materialized', artifact_ref: payload.artifact_ref, digest: payload.digest,
      source_commit: payload.repository.commit_sha, receipt_ref: receiptRef,
      receipt_sha256: written.digest,
    };
  } else {
    result = {
      status: 'published',
      remote_url: `https://github.com/${payload.repository.slug}/blob/${payload.repository.commit_sha}/qa/${payload.stage}-${payload.attempt}.json`,
      digest: payload.digest,
      source_commit: payload.repository.commit_sha,
      receipt_ref: `.testing/runs/${runId}/published/${payload.stage}-${payload.attempt}.json`,
    };
  }
  const stored = recordImmutable(root, key, { binding: payload, result });
  if (!stored.written && !stored.replayed) fail('publication commit conflict');
  return result;
}

function directExec(argv, cwd, timeoutSeconds) {
  if (!Array.isArray(argv) || argv.length === 0 || argv.some((item) => typeof item !== 'string')) {
    fail('argv must be a non-empty string list');
  }
  const result = spawnSync(argv[0], argv.slice(1), {
    cwd,
    encoding: 'utf8',
    timeout: Math.max(1, Number(timeoutSeconds) || 30) * 1000,
    env: process.env,
  });
  return {
    exit_code: result.status == null ? -1 : result.status,
    stdout: result.stdout || '',
    stderr: result.stderr || (result.error ? String(result.error.message || result.error) : ''),
  };
}

function environmentStateKey(ref) {
  if (!ref || typeof ref.ref !== 'string') fail('environment state ref is required');
  return `environment-factory/state/${sha256(stable(ref.ref))}`;
}

function environmentResourceKey(ref) {
  return `environment-factory/resources/${sha256(stable(ref))}`;
}

function exactRuntimePorts(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 32) fail('runtime_ports are invalid');
  const names = new Set();
  const ports = new Set();
  return value.map((item) => {
    const port = Number(item && item.port);
    if (!item || typeof item.name !== 'string' || item.name === '' || item.name.length > 180
      || !Number.isInteger(port) || port < 1 || port > 65535 || names.has(item.name) || ports.has(port)) {
      fail('runtime_ports are invalid');
    }
    names.add(item.name);
    ports.add(port);
    return { name: item.name, port };
  });
}

function samePorts(left, right) {
  return stable(exactRuntimePorts(left)) === stable(exactRuntimePorts(right));
}

function resourceRecord(root, ref) {
  const resource = recordRead(root, environmentResourceKey(ref));
  if (!resource || resource.schema !== 'generic-host.environment-resource.v1'
    || stable(resource.cleanup_ref) !== stable(ref)) fail('environment resource is unavailable or malformed');
  return resource;
}

function workspaceResource(root, ref) {
  const resource = recordRead(root, environmentResourceKey(ref));
  if (!resource || resource.schema !== 'generic-host.environment-resource.v1'
    || resource.kind !== 'workspace' || stable(resource.workspace_ref) !== stable(ref)) {
    fail('workspace resource is unavailable or malformed');
  }
  return resource;
}

function verifyWorkspace(config, resource) {
  if (resource.operation_id !== config.run_id || resource.path !== config.workspace_root
    || typeof resource.ownership_token !== 'string' || resource.ownership_token === '') {
    fail('workspace ownership binding differs');
  }
  if (!fs.existsSync(resource.path)) return { owned: false, reason: 'workspace-missing' };
  const identity = pathIdentity(resource.path);
  if (!samePathIdentity(identity, resource.path_identity)) return { owned: false, reason: 'workspace-identity-changed' };
  return { owned: true, identity };
}

function registerWorkspace(projectRoot, payload) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  const config = loadConfig(projectRoot, runId);
  if (payload.operation_id !== runId || !payload.workspace_ref || !payload.cleanup_ref
    || payload.workspace_ref.ref !== `${runId}-workspace` || payload.cleanup_ref.ref !== `${runId}-workspace`
    || payload.path !== config.workspace_root || payload.repository.commit_sha !== config.commit_sha) {
    fail('workspace registration binding differs');
  }
  const identity = pathIdentity(payload.path);
  const resource = {
    schema: 'generic-host.environment-resource.v1', kind: 'workspace', operation_id: runId,
    workspace_ref: payload.workspace_ref, cleanup_ref: payload.cleanup_ref, path: payload.path,
    path_identity: identity, repository: payload.repository,
    ownership_token: crypto.randomBytes(16).toString('hex'),
  };
  for (const ref of [payload.workspace_ref, payload.cleanup_ref]) {
    const stored = recordImmutable(root, environmentResourceKey(ref), resource);
    if (!stored.written && !stored.replayed) fail('workspace resource binding differs');
  }
  return { registered: true, path_identity: identity };
}

function startApplication(projectRoot, payload) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  const config = loadConfig(projectRoot, runId);
  const ports = exactRuntimePorts(payload.runtime_ports);
  if (payload.operation_id !== runId || payload.effect_id == null || !payload.workspace_ref
    || payload.workspace_ref.ref !== `${runId}-workspace` || !payload.cleanup_ref
    || payload.cleanup_ref.ref !== `${runId}-application` || !Array.isArray(payload.argv)
    || payload.argv.length === 0 || !samePorts(ports, [{ name: 'application', port: config.port }])) {
    fail('application start binding differs');
  }
  const existing = recordRead(root, environmentResourceKey(payload.cleanup_ref));
  if (existing) {
    const status = inspectResources(projectRoot, { run_id: runId });
    if (!status.owned) fail(`application replay ownership failed: ${status.reason}`);
    return { status: 'running', cleanup_ref: payload.cleanup_ref, early_exit: false, runtime_ports: ports };
  }
  const workspace = workspaceResource(root, payload.workspace_ref);
  const workspaceState = verifyWorkspace(config, workspace);
  if (!workspaceState.owned) fail(`workspace ownership failed: ${workspaceState.reason}`);
  const child = spawn(payload.argv[0], payload.argv.slice(1), {
    cwd: workspace.path,
    env: process.env,
    shell: false,
    detached: true,
    stdio: 'ignore',
  });
  child.once('error', () => {});
  child.unref();
  const deadline = Date.now() + 5_000;
  let processIdentity = null;
  let listenerState = null;
  while (Date.now() < deadline) {
    processIdentity = processStartIdentity(child.pid);
    if (processIdentity !== null) {
      listenerState = listenersOwnedByProcessGroup(ports, child.pid);
      if (listenerState.supported && listenerState.owned) break;
    }
    sleep(25);
  }
  if (processIdentity === null || !listenerState || !listenerState.supported || !listenerState.owned) {
    terminateProcessGroup({ pid: child.pid, pgid: child.pid, process_start_identity: processIdentity }, 500);
    fail(`application ownership could not be verified: ${listenerState && listenerState.reason || 'process-start-failed'}`);
  }
  const resource = {
    schema: 'generic-host.environment-resource.v1', kind: 'process', operation_id: runId,
    effect_id: payload.effect_id, cleanup_ref: payload.cleanup_ref, workspace_ref: payload.workspace_ref,
    workspace_path: workspace.path, workspace_identity: workspace.path_identity,
    argv_sha256: sha256(stable(payload.argv)), ownership_token: crypto.randomBytes(16).toString('hex'),
    runtime_ports: ports, pid: child.pid, pgid: child.pid, process_start_identity: processIdentity,
  };
  const stored = recordImmutable(root, environmentResourceKey(payload.cleanup_ref), resource);
  if (!stored.written) {
    terminateProcessGroup(resource, 500);
    fail('application resource binding differs');
  }
  return { status: 'running', cleanup_ref: payload.cleanup_ref, early_exit: false, runtime_ports: ports };
}

function inspectResources(projectRoot, payload) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  const config = loadConfig(projectRoot, runId);
  const workspaceRef = { kind: 'workspace', ref: `${runId}-workspace` };
  const processRef = { kind: 'process-cleanup', ref: `${runId}-application` };
  const workspace = workspaceResource(root, workspaceRef);
  const process = resourceRecord(root, processRef);
  const workspaceState = verifyWorkspace(config, workspace);
  if (!workspaceState.owned) return { owned: false, reason: workspaceState.reason };
  if (process.kind !== 'process' || process.operation_id !== runId
    || process.workspace_path !== workspace.path || !samePathIdentity(process.workspace_identity, workspace.path_identity)
    || typeof process.ownership_token !== 'string' || process.ownership_token === '') {
    return { owned: false, reason: 'process-binding-changed' };
  }
  const group = processGroupState(process);
  if (!group.supported || !group.alive || group.foreign) return { owned: false, reason: 'process-group-not-owned' };
  const listeners = listenersOwnedByProcessGroup(process.runtime_ports, process.pgid);
  if (!listeners.supported || !listeners.owned) return { owned: false, reason: listeners.reason || 'listeners-not-owned' };
  return {
    owned: true, pid: process.pid, pgid: process.pgid, process_start_identity: process.process_start_identity,
    ownership_token: process.ownership_token, runtime_ports: process.runtime_ports,
    workspace_path: workspace.path, workspace_identity: workspace.path_identity,
  };
}

function releasedResources(projectRoot, payload) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  const config = loadConfig(projectRoot, runId);
  const process = resourceRecord(root, { kind: 'process-cleanup', ref: `${runId}-application` });
  const group = processGroupState(process);
  const listeners = listenersReleased(process.runtime_ports);
  return {
    process_group_absent: group.supported === true && group.alive === false,
    listeners_closed: listeners.supported === true && listeners.released === true,
    workspace_absent: !fs.existsSync(config.workspace_root),
  };
}

function cleanupResource(projectRoot, payload) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  const config = loadConfig(projectRoot, runId);
  const cleanupRef = payload.cleanup_ref || {};
  const resource = resourceRecord(root, cleanupRef);
  if (payload.operation_id !== runId || resource.operation_id !== runId
    || typeof resource.ownership_token !== 'string' || resource.ownership_token === '') {
    fail('resource cleanup ownership binding differs');
  }
  if (resource.kind === 'process') {
    const workspace = workspaceResource(root, resource.workspace_ref);
    const workspaceState = verifyWorkspace(config, workspace);
    if (!workspaceState.owned || !samePathIdentity(resource.workspace_identity, workspace.path_identity)) {
      fail('process cleanup workspace ownership differs');
    }
    const group = processGroupState(resource);
    if (!group.supported || !group.alive || group.foreign) fail('process cleanup ownership cannot be verified');
    const owned = listenersOwnedByProcessGroup(resource.runtime_ports, resource.pgid);
    if (!owned.supported || !owned.owned) fail(`process listener ownership cannot be verified: ${owned.reason}`);
    const stopped = terminateProcessGroup(resource, Math.max(1, Number(payload.timeout_seconds) || 5) * 1000);
    if (!stopped.released) fail(`process cleanup failed: ${stopped.reason}`);
    const listeners = listenersReleased(resource.runtime_ports);
    if (!listeners.supported || !listeners.released) fail('process listeners remain after cleanup');
  } else if (resource.kind === 'workspace') {
    const process = resourceRecord(root, { kind: 'process-cleanup', ref: `${runId}-application` });
    const group = processGroupState(process);
    if (!group.supported || group.alive) fail('workspace cleanup requires a released process group');
    const listeners = listenersReleased(process.runtime_ports);
    if (!listeners.supported || !listeners.released) fail('workspace cleanup requires released listeners');
    const workspaceState = verifyWorkspace(config, resource);
    if (!workspaceState.owned) fail(`workspace cleanup ownership cannot be verified: ${workspaceState.reason}`);
    if (!removeOwnedDirectory(resource.path, resource.path_identity, config.temp_root)) {
      fail('workspace cleanup did not remove the owned workspace');
    }
  } else if (resource.kind === 'ports') {
    const listeners = listenersReleased(resource.runtime_ports);
    if (!listeners.supported || !listeners.released) fail('port cleanup requires released listeners');
  } else {
    fail('unsupported resource cleanup kind');
  }
  return { status: 'cleaned' };
}

function environmentEffect(projectRoot, payload, produce) {
  const runId = runIdFor(payload);
  const root = runRoot(runId);
  loadConfig(projectRoot, runId);
  if (typeof payload.effect_id !== 'string' || payload.effect_id === '') fail('environment effect_id is required');
  const key = `environment-factory/effects/${sha256(stable(payload.effect_id))}`;
  const binding = { ...payload };
  delete binding.runtime_config_ref;
  const existing = recordRead(root, key);
  if (existing) {
    if (stable(existing.binding) !== stable(binding)) fail('environment effect binding differs');
    return existing.result;
  }
  const result = produce(runId, root);
  const stored = recordImmutable(root, key, { binding, result });
  if (!stored.written && !stored.replayed) fail('environment effect commit conflict');
  return result;
}

function waitForHttp(url, timeoutSeconds) {
  const script = [
    "const http=require('http'),https=require('https'),url=process.argv[1],end=Date.now()+Number(process.argv[2])*1000;",
    "function poll(){const client=url.startsWith('https:')?https:http;const req=client.get(url,res=>{res.resume();process.exit(res.statusCode>=200&&res.statusCode<500?0:1)});",
    "req.on('error',()=>{if(Date.now()>=end)process.exit(1);setTimeout(poll,20)});req.setTimeout(500,()=>req.destroy())}poll();",
  ].join('');
  return directExec([process.execPath, '-e', script, url, String(timeoutSeconds || 30)], process.cwd(), timeoutSeconds).exit_code === 0;
}

function structuredReplayKey(grantId) {
  return `testing-runner/replay/${sha256(stable(grantId))}`;
}

function dispatch(name, payload, projectRoot) {
  switch (name) {
    case 'workflow-load-state': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      if (payload.path !== config.request.state_ref) return null;
      return recordRead(runRoot(runId), `workflow-qa/state/${runId}`);
    }
    case 'workflow-load-run': {
      for (const runId of listIndexedRuns(projectRoot)) {
        const request = requestFor(projectRoot, runId);
        if (request && request.trace_id === payload.trace_id && request.dedup_key === payload.dedup_key) return request;
      }
      return null;
    }
    case 'workflow-load-run-by-id':
      return requestFor(projectRoot, payload.run_id);
    case 'workflow-list-pending-runs':
      return pendingRequests(projectRoot, payload.limit);
    case 'workflow-save-state': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      if (payload.path !== config.request.state_ref) return { saved: false };
      return recordCas(runRoot(runId), `workflow-qa/state/${runId}`, payload.value, payload.expected_version);
    }
    case 'artifact-load':
      return artifactRead(projectRoot, payload.path);
    case 'artifact-write':
      return artifactWrite(projectRoot, payload.path, payload.value);
    case 'artifact-digest': {
      const artifact = artifactRead(projectRoot, payload.path);
      return { digest: artifact && artifact.digest || null };
    }
    case 'publication-load-ledger': {
      const runId = runIdFor(payload);
      return recordRead(runRoot(runId), `test-publication/ledgers/${sha256(stable(payload.path))}`);
    }
    case 'publication-save-ledger': {
      const runId = runIdFor(payload);
      return recordCas(runRoot(runId), `test-publication/ledgers/${sha256(stable(payload.path))}`,
        payload.value, payload.expected_version);
    }
    case 'publication-publish-artifact':
      return publicationResult(projectRoot, payload);
    case 'publication-write-report': {
      const written = artifactWrite(projectRoot, payload.path, payload.value);
      return { status: 'written', digest: written.digest };
    }
    case 'host-claim-preauthorization': {
      const runId = runIdFor(payload);
      loadConfig(projectRoot, runId);
      const claimed = recordClaim(runRoot(runId), `generic-host/preauthorization/${sha256(stable(payload.authorization_id))}`, {
        binding: payload, claim_id: `${runId}-preauthorization`,
      });
      if (!claimed.claimed) return { status: 'blocked' };
      return { status: 'claimed', claim_id: claimed.value.claim_id, replayed: claimed.replayed === true };
    }
    case 'host-grant-values': {
      const runId = runIdFor(payload.request || {});
      loadConfig(projectRoot, runId);
      return {
        grant_id: `${runId}-grant`,
        evidence_ref: { kind: 'signed-attestation', ref: `${runId}-execution-grant` },
        issued_at: '2026-07-22T00:15:00Z', expires_at: '2026-07-22T00:45:00Z',
        now: '2026-07-22T00:20:00Z',
      };
    }
    case 'host-record-terminal': {
      const runId = runIdFor(payload);
      loadConfig(projectRoot, runId);
      const stored = recordImmutable(runRoot(runId), `generic-host/terminal/${runId}`, payload);
      return { recorded: stored.written === true || stored.replayed === true };
    }
    case 'load-authorization-bundle': {
      const start = payload.start;
      const runId = runIdFor(start || {});
      const config = loadConfig(projectRoot, runId);
      const expected = config.request.environment_start;
      if (!start || start.operation_id !== runId
        || stable(start.profile_ref) !== stable(expected.profile_ref)
        || stable(start.approval_ref) !== stable(expected.approval_ref)
        || stable(start.validation_receipt_ref) !== stable(expected.validation_receipt_ref)) {
        fail('environment authorization request binding differs');
      }
      return {
        profile: config.profile,
        approval: config.approval,
        receipt: config.validation_receipt,
        context: {
          now: config.authorization_now,
          approval_ref: config.authorization_approval_ref,
          trusted_authorities: [{
            authenticated: true,
            approval_sha256: config.validation_receipt.approval_sha256,
            source_ref: config.approval.authority,
            policy_revision: config.approval.policy_revision,
            evidence_ref: config.approval.evidence_ref,
          }],
        },
      };
    }
    case 'sha256':
      loadConfig(projectRoot, runIdFor(payload));
      if (typeof payload.value !== 'string') fail('sha256 value must be a string');
      return { digest: sha256(payload.value) };
    case 'plan-listener-claim': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      const runtimePorts = exactRuntimePorts(payload.runtime_ports);
      if (!samePorts(runtimePorts, [{ name: 'application', port: config.port }])) {
        fail('listener claim plan binding differs');
      }
      return {
        status: 'planned',
        needs_claim: [],
        already_owned: runtimePorts,
        runtime_owned: true,
      };
    }
    case 'lookup-effect': {
      const runId = runIdFor(payload);
      const root = runRoot(runId);
      loadConfig(projectRoot, runId);
      const existing = recordRead(root, `environment-factory/effects/${sha256(stable(payload.effect_id))}`);
      if (!existing) return { found: false };
      const binding = payload.lookup_binding || {};
      if (!existing.binding || existing.binding.effect_id !== payload.effect_id
        || stable(existing.binding.request_binding) !== stable(binding.request_binding)
        || stable(existing.binding.runtime_ports) !== stable(binding.runtime_ports)) {
        fail('environment authorization effect binding differs');
      }
      return { found: true, outcome: existing.result };
    }
    case 'authorize-claim-ports': {
      const runId = runIdFor(payload);
      const root = runRoot(runId);
      loadConfig(projectRoot, runId);
      const key = `environment-factory/effects/${sha256(stable(payload.effect_id))}`;
      const existing = recordRead(root, key);
      const binding = payload.lookup_binding || {};
      if (existing) {
        if (!existing.binding || existing.binding.effect_id !== payload.effect_id
          || stable(existing.binding.request_binding) !== stable(binding.request_binding)
          || stable(existing.binding.runtime_ports) !== stable(payload.runtime_ports)
          || stable(existing.result.profile_snapshot) !== stable(payload.profile_snapshot)) {
          fail('environment authorization claim replay differs');
        }
        return existing.result;
      }
      if (!payload.replay_claim || stable(payload.profile_snapshot) !== stable(loadConfig(projectRoot, runId).profile)) {
        fail('environment authorization claim replay differs');
      }
      const approvalClaim = recordClaim(root, `generic-host/profile-approval/${runId}`, {
        binding: payload.replay_claim, claim_id: `${runId}-profile-claim`,
      });
      if (!approvalClaim.claimed || !approvalClaim.value || approvalClaim.value.claim_id !== `${runId}-profile-claim`) {
        fail('environment authorization approval claim was not acquired');
      }
      const runtimePorts = exactRuntimePorts(payload.runtime_ports);
      if (!Array.isArray(payload.listener_claimed_ports) || payload.listener_claimed_ports.length !== 0
        || !samePorts(exactRuntimePorts(payload.listener_already_owned_ports), runtimePorts)) {
        fail('environment authorization listener ownership differs');
      }
      const cleanupRef = { kind: 'port-lease', ref: `${runId}-ports` };
      const resource = recordImmutable(root, environmentResourceKey(cleanupRef), {
        schema: 'generic-host.environment-resource.v1', kind: 'ports', operation_id: runId,
        cleanup_ref: cleanupRef, runtime_ports: runtimePorts,
        ownership_token: sha256(`${runId}\0ports\0${payload.effect_id}`),
      });
      if (!resource.written && !resource.replayed) fail('port resource binding differs');
      const result = {
        status: 'passed', profile_snapshot: payload.profile_snapshot, cleanup_ref: cleanupRef,
        runtime_ports: runtimePorts, deadline_epoch_seconds: 1784685600,
        request_binding: binding.request_binding,
      };
      const stored = recordImmutable(root, key, { binding: {
        effect_id: payload.effect_id, request_binding: binding.request_binding, runtime_ports: runtimePorts,
      }, result });
      if (!stored.written && !stored.replayed) fail('environment authorization effect commit conflict');
      return { ...result, claim_id: approvalClaim.value.claim_id };
    }
    case 'remaining-budget':
      loadConfig(projectRoot, runIdFor(payload));
      return { remaining_seconds: 120 };
    case 'checkout': {
      const runId = runIdFor(payload);
      const root = runRoot(runId);
      const config = loadConfig(projectRoot, runId);
      return environmentEffect(projectRoot, payload, () => {
        if (payload.operation_id !== runId || stable(payload.repository) !== stable(config.profile.repository)
          || payload.working_directory !== config.profile.working_directory) {
          fail('environment checkout binding differs');
        }
        const workspaceRoot = path.resolve(config.workspace_root);
        const tempRoot = path.resolve(config.temp_root);
        if (workspaceRoot === tempRoot || !workspaceRoot.startsWith(`${tempRoot}${path.sep}`)) {
          fail('environment checkout workspace escaped the durable temp root');
        }
        fs.rmSync(config.workspace_root, { recursive: true, force: true });
        const cloned = directExec(['git', 'clone', '--quiet', config.source_root, config.workspace_root], config.temp_root,
          payload.timeout_seconds);
        if (cloned.exit_code !== 0) fail('environment checkout clone failed');
        const checkedOut = directExec(['git', 'checkout', '--quiet', config.commit_sha], config.workspace_root,
          payload.timeout_seconds);
        if (checkedOut.exit_code !== 0) fail('environment checkout revision failed');
        const resolved = directExec(['git', 'rev-parse', 'HEAD'], config.workspace_root, payload.timeout_seconds);
        const commit = String(resolved.stdout || '').trim();
        if (resolved.exit_code !== 0 || commit !== config.commit_sha) fail('environment checkout resolved commit differs');
        const workspaceRef = { kind: 'workspace', ref: `${runId}-workspace` };
        const cleanupRef = { kind: 'workspace-cleanup', ref: `${runId}-workspace` };
        registerWorkspace(projectRoot, {
          run_id: runId, operation_id: runId, workspace_ref: workspaceRef, cleanup_ref: cleanupRef,
          path: config.workspace_root, repository: config.repository,
        });
        return { status: 'passed', resolved_commit: commit, workspace_ref: workspaceRef, cleanup_ref: cleanupRef };
      });
    }
    case 'load-state': {
      const runId = runIdFor(payload);
      loadConfig(projectRoot, runId);
      const value = recordRead(runRoot(runId), environmentStateKey(payload.ref));
      if (!value) return null;
      return { authenticated: true, state: value.state, revision: value.version };
    }
    case 'save-state': {
      const runId = runIdFor(payload);
      loadConfig(projectRoot, runId);
      const saved = recordCas(runRoot(runId), environmentStateKey(payload.ref), {
        version: payload.expected_revision + 1,
        state: payload.state,
      }, payload.expected_revision);
      return { saved: saved.saved === true, stale: saved.stale === true, revision: saved.version };
    }
    case 'create-readiness-attempt':
      return environmentEffect(projectRoot, payload, (runId) => {
        const attemptRef = `${payload.artifact_root}/readiness-attempts/attempt-1.json`;
        const written = artifactWrite(projectRoot, attemptRef, {
          schema: 'canonical-qa.readiness-attempt.v1', operation_id: payload.operation_id,
          base_url: payload.base_url, sessions: payload.sessions,
          trace_id: payload.trace_id, dedup_key: payload.dedup_key,
        });
        return {
          status: 'passed', attempt_id: 'attempt-1', attempt_ref: { kind: 'artifact', ref: attemptRef },
          attempt_sha256: written.digest,
        };
      });
    case 'run-argv':
      return environmentEffect(projectRoot, payload, (runId, root) => {
        const workspace = workspaceResource(root, payload.workspace_ref);
        if (payload.mode === 'supervised') {
          return startApplication(projectRoot, {
            ...payload, run_id: runId,
            cleanup_ref: { kind: 'process-cleanup', ref: `${runId}-application` },
          });
        }
        const executed = directExec(payload.argv, workspace.path, payload.timeout_seconds);
        const result = { status: executed.exit_code === 0 ? 'passed' : 'blocked' };
        if (payload.requires_frozen_dependencies) result.frozen_dependencies_enforced = true;
        return result;
      });
    case 'wait-readiness':
      return environmentEffect(projectRoot, payload, (_runId, root) => {
        for (const check of payload.checks || []) {
          if (check.type === 'http') {
            if (!waitForHttp(check.url, payload.timeout_seconds)) return { status: 'blocked' };
          } else if (check.type === 'argv') {
            const workspace = workspaceResource(root, payload.workspace_ref);
            if (directExec(check.argv, workspace.path, payload.timeout_seconds).exit_code !== 0) {
              return { status: 'blocked' };
            }
          } else {
            return { status: 'blocked' };
          }
        }
        return { status: 'ready' };
      });
    case 'cleanup':
      return environmentEffect(projectRoot, payload, () => cleanupResource(projectRoot, payload));
    case 'write-receipt':
      return environmentEffect(projectRoot, payload, () => {
        const written = artifactWrite(projectRoot, payload.receipt_ref.ref, payload.receipt);
        return { status: written.written ? 'passed' : 'blocked' };
      });
    case 'load-artifact':
      return artifactRead(projectRoot, payload.artifact_ref.ref);
    case 'write-artifact':
      return artifactWrite(projectRoot, payload.artifact_ref.ref, payload.value);
    case 'now':
      loadConfig(projectRoot, runIdFor(payload));
      return { now: '2026-07-22T00:20:00Z' };
    case 'verify-grant':
      return {
        grant_sha256: payload.grant_sha256,
        authority: payload.grant.authority,
        policy_revision: payload.grant.policy_revision,
        evidence_ref: payload.grant.evidence_ref,
      };
    case 'replay-guard': {
      const runId = runIdFor(payload);
      loadConfig(projectRoot, runId);
      const claimId = `${runId}-execution-claim`;
      const claimed = recordClaim(runRoot(runId), structuredReplayKey(payload.grant_id), {
        status: 'claimed', claim_id: claimId, binding: payload,
      });
      if (!claimed.claimed) return null;
      if (claimed.value.status === 'completed') {
        return { status: 'completed', result_ref: claimed.value.result_ref,
          result_sha256: claimed.value.result_sha256 };
      }
      if (claimed.replayed) return { status: 'in-progress' };
      return { status: 'claimed', claim_id: claimId };
    }
    case 'exec-argv': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      if (payload.operation_id !== runId || !payload.workspace_ref
        || payload.workspace_ref.ref !== `${runId}-workspace`
        || payload.repository.commit_sha !== config.commit_sha) fail('structured CLI request binding differs');
      const workspace = recordRead(runRoot(runId), environmentResourceKey(payload.workspace_ref));
      if (!workspace || typeof workspace.path !== 'string') fail('structured workspace is unavailable');
      const result = directExec(payload.argv, workspace.path, payload.timeout_seconds);
      recordImmutable(runRoot(runId), `testing-runner/target-effects/${sha256(stable(payload))}`, {
        binding: payload, result,
      });
      return result;
    }
    case 'http-request': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      if (payload.operation_id !== runId || payload.base_url !== config.base_url
        || !payload.request || payload.request.url !== config.base_url) fail('structured HTTP request binding differs');
      const result = directExec(['curl', '-sS', '-o', '-', '-w', '\n%{http_code}', payload.request.url],
        projectRoot, payload.timeout_seconds);
      const match = /\n(\d{3})$/.exec(result.stdout);
      return { status: match ? Number(match[1]) : 0, body: match ? result.stdout.slice(0, match.index) : result.stdout };
    }
    case 'load-result': {
      const runId = runIdFor(payload);
      const config = loadConfig(projectRoot, runId);
      const artifact = artifactRead(projectRoot, payload.result_ref);
      if (!artifact || (payload.result_sha256 && artifact.digest !== payload.result_sha256)) return null;
      const value = artifact.value;
      if (value.operation_id !== payload.operation_id
        || value.environment_receipt_sha256 !== payload.environment_receipt_sha256
        || value.trace_id !== payload.trace_id || value.dedup_key !== payload.dedup_key) return null;
      const recovered = recordImmutable(runRoot(runId), 'generic-host/recovery/execution', {
        schema: 'generic-host.completed-execution-recovery.v1', run_id: runId,
        result_ref: payload.result_ref, result_sha256: artifact.digest, replayed: true,
      });
      if (!recovered.written && !recovered.replayed) fail('execution recovery witness differs');
      return {
        schema: 'testing-runner.structured-execution-summary.v1', status: value.status,
        classification: value.classification, mode: 'structured-api-cli',
        artifact_root: config.request.structured_execution.artifact_root,
        case_count: value.case_count, passed_count: value.passed_count, failed_count: value.failed_count,
        skipped_count: value.skipped_count, error_count: value.error_count,
        test_plan_path: value.test_plan_path, case_results_path: value.case_results_path,
        execution_path: value.execution_path, replayed: true,
      };
    }
    case 'complete-replay': {
      const runId = runIdFor(payload);
      const root = runRoot(runId);
      loadConfig(projectRoot, runId);
      let current = null;
      for (const entry of recordList(root, 'testing-runner/replay')) {
        if (entry.value && payload.claim && entry.value.claim_id === payload.claim.claim_id) {
          current = entry;
          break;
        }
      }
      if (!current || current.value.status !== 'claimed') return { completed: false };
      const binding = current.value.binding;
      if (binding.artifact_root !== payload.artifact_root || binding.operation_id !== payload.operation_id
        || binding.environment_receipt_sha256 !== payload.environment_receipt_sha256
        || stable(binding.repository) !== stable(payload.repository)
        || binding.trace_id !== payload.trace_id || binding.dedup_key !== payload.dedup_key) {
        return { completed: false };
      }
      const artifact = artifactRead(projectRoot, payload.result_ref);
      if (!artifact) return { completed: false };
      const completion = { ...payload, result_sha256: artifact.digest };
      delete completion.claim;
      const completed = storeExecute({ root, operation: 'replay-complete', key: current.key,
        claim_id: payload.claim.claim_id, completion });
      if (!completed.completed) return completed;
      const verified = artifactRead(projectRoot, payload.result_ref);
      if (!verified || verified.digest !== artifact.digest || completed.value.result_sha256 !== artifact.digest) {
        fail('completed replay result artifact is unavailable or changed');
      }
      const config = loadConfig(projectRoot, runId);
      const arm = config.completed_replay_failpoint;
      if (completed.replayed !== true && arm && arm.name === 'post-completed-replay'
        && typeof arm.token === 'string'
        && process.env.FKST_DURABLE_COMPLETED_REPLAY_FAILPOINT === arm.token) {
        const witness = recordImmutable(root, 'generic-host/barriers/post-replay-complete', {
          schema: 'generic-host.completed-replay-barrier.v1', run_id: runId,
          failpoint: arm.name, arm_token_sha256: sha256(arm.token),
          result_ref: payload.result_ref, result_sha256: artifact.digest,
          replay_status: completed.value.status,
        });
        if (!witness.written && !witness.replayed) fail('completed replay barrier witness differs');
        while (true) sleep(1000);
      }
      return completed;
    }
    case 'fixture-register-workspace':
      return registerWorkspace(projectRoot, payload);
    case 'fixture-start-application':
      return startApplication(projectRoot, payload);
    case 'fixture-resource-status':
      return inspectResources(projectRoot, payload);
    case 'fixture-release-status':
      return releasedResources(projectRoot, payload);
    default:
      fail(`unknown effect ${name}`);
  }
}

function parseArgs(argv) {
  if (argv[2] !== 'effect') fail('effect command is required');
  const values = {};
  for (let index = 3; index < argv.length; index += 2) {
    const key = argv[index];
    if (!['--name', '--request', '--response'].includes(key) || index + 1 >= argv.length) fail('invalid arguments');
    values[key.slice(2)] = argv[index + 1];
  }
  if (!values.name || !values.request || !values.response) fail('name, request, and response are required');
  return values;
}

function writeResponse(target, value) {
  atomicWrite(path.resolve(target), `${stable(value)}\n`);
}

function main() {
  const args = parseArgs(process.argv);
  let requestId = null;
  try {
    const transport = JSON.parse(fs.readFileSync(args.request, 'utf8'));
    requestId = transport && transport.request_id;
    if (typeof requestId !== 'string' || requestId === '' || requestId.length > 512) {
      fail('request_id is invalid');
    }
    const payload = { ...transport };
    delete payload.request_id;
    const config = readRuntimeConfig(payload);
    const projectRoot = path.resolve(config.project_root);
    const result = dispatch(args.name, payload, projectRoot);
    writeResponse(args.response, result === null
      ? { ok: true, request_id: requestId }
      : { ok: true, request_id: requestId, result });
  } catch (error) {
    writeResponse(args.response, {
      ok: false,
      request_id: requestId,
      error: String(error && error.message || error),
    });
    process.exitCode = 1;
  }
}

main();
