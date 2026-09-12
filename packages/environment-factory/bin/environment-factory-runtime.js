#!/usr/bin/env node
'use strict';
const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const https = require('https');
const net = require('net');
const path = require('path');
const { loadAuthorizationBundle } = require('./runtime/authorization');
const { createBudgetRuntime } = require('./runtime/budgets');
const {
  DEFAULT_OUTPUT_BYTES, OBJECT_BOUND_CLEANUP_UNAVAILABLE, acquireLock, artifactPath, boundedText, commandResult,
  isSafeArtifactPath, parseArgs, readJson,
  processStartIdentity, pathEntryExists, pathIdentity, removeOwnedDirectory,
  requireOwnedDirectory, runtimeConfig, sameArray, samePathIdentity, sha256, stableStringify, validateArgv,
  verifyWorkerEnvironment, verifyWorkerEnvironmentLease, writeJsonAtomic, writeJsonImmutable,
} = require('./runtime/common');
const { validateTargetExecutionBoundary } = require('./runtime/target-execution-boundary');
const { createListenerClaims } = require('./runtime/listener-claims');
const { runMeasuredCommand } = require('./runtime/measured-command');
const { listenersOwnedByProcessGroup, processGroupUsage } = require('./runtime/platform');
const { startOrRecoverSupervisedProcess } = require('./runtime/supervised-process');
const { loadState, saveState } = require('./runtime/state');
const { readResource: readWorkspaceResource, resolveWorkspace } = require('./runtime/workspace');
const { prepareReservedWorkspace } = require('./runtime/workspace-reservation');
const {
  allocateDurableWorkerEnvironment,
  cleanupWorkerHomeLedger,
  initializeWorkerHomeLedger,
  recordPersistedWorkerEnvironmentRelease,
  verifyPersistedWorkerEnvironment,
  withDurableWorkerEnvironment,
} = require('./runtime/worker-home-resource');
function durableRoot() {
  return path.resolve(process.env.FKST_DURABLE_ROOT || path.join('.testing', 'durable'));
}
function executionRoot() {
  return path.resolve(process.env.FKST_RUNTIME_ROOT || path.join('.testing', 'runtime'));
}
function targetExecutionConfig(payload, repository = payload && payload.repository) {
  const config = runtimeConfig(payload);
  validateTargetExecutionBoundary(config.target_execution_boundary, repository, {
    runtimeConfigRef: payload.runtime_config_ref,
    artifactRoot: payload.artifact_root,
  });
  return config;
}
function ledgerPath(kind, id) {
  return path.join(durableRoot(), 'environment-factory', kind, `${sha256(String(id))}.json`);
}

function effectPath(effectId) {
  return ledgerPath('effects', effectId);
}

function resourcePath(ref) {
  return ledgerPath('resources', ref);
}

function readIfExists(filePath) {
  try {
    return readJson(filePath);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

function effectRecord(effectId) {
  const record = readIfExists(effectPath(effectId));
  if (!record) return null;
  if (record.schema !== 'environment-factory.effect.v1' || record.effect_id !== effectId
    || typeof record.request_sha256 !== 'string' || !record.outcome) {
    throw new Error('effect ledger record is malformed');
  }
  return record;
}

function requestDigest(payload) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return sha256(stableStringify(payload));
  }
  const binding = { ...payload };
  delete binding.remaining_seconds;
  delete binding.timeout_seconds;
  delete binding.listener_claimed_ports;
  delete binding.listener_already_owned_ports;
  delete binding.replay_claim;
  return sha256(stableStringify(binding));
}

function lookupDigest(payload) {
  return requestDigest({
    ...(payload.lookup_binding || {}),
    runtime_config_ref: payload.runtime_config_ref,
  });
}

function boundEffectOutcome(effectId, digest) {
  const record = effectRecord(effectId);
  if (!record) return null;
  if (record.request_sha256 !== digest) throw new Error('effect request binding differs');
  return record.outcome;
}

async function withEffect(payload, produce) {
  const effectId = payload && payload.effect_id;
  if (typeof effectId !== 'string' || effectId === '') throw new Error('effect_id is required');
  const digest = requestDigest(payload);
  const existing = boundEffectOutcome(effectId, digest);
  if (existing) return existing;
  const release = acquireLock(`${effectPath(effectId)}.lock`);
  try {
    const replay = boundEffectOutcome(effectId, digest);
    if (replay) return replay;
    const outcome = await produce();
    writeJsonAtomic(effectPath(effectId), {
      schema: 'environment-factory.effect.v1', effect_id: effectId, request_sha256: digest, outcome,
    });
    return outcome;
  } finally {
    release();
  }
}

function diagnosticRef(request, label, extension = 'json') {
  const root = request.artifact_root;
  if (!isSafeArtifactPath(root)) throw new Error('artifact_root is unsafe');
  return {
    kind: 'artifact',
    ref: `${root}/diagnostics/${boundedText(label, 120).replace(/[^A-Za-z0-9._-]/g, '-')}.${extension}`,
  };
}

function writeDiagnostic(request, label, value) {
  const ref = diagnosticRef(request, label);
  writeJsonAtomic(artifactPath(ref), value);
  return ref;
}

function relativeWorkspacePath(cwd, value, field) {
  if (typeof value !== 'string' || value === '' || path.isAbsolute(value) || value.includes('\\')
    || value.split('/').some((segment) => segment === '' || segment === '.' || segment === '..')) {
    throw new Error(`${field} must be a safe relative path`);
  }
  const resolved = path.resolve(cwd, value);
  if (resolved !== cwd && !resolved.startsWith(`${cwd}${path.sep}`)) throw new Error(`${field} escaped workspace`);
  return resolved;
}

function frozenDependencyPolicy(config, argv, cwd) {
  const policy = config.frozen_dependency_policy;
  if (!policy || policy.kind !== 'npm-ci-offline-v1' || typeof policy.revision !== 'string'
    || policy.revision === '' || !sameArray(argv, policy.argv)
    || !sameArray(policy.argv, ['npm', 'ci', '--offline', '--ignore-scripts'])) {
    throw new Error('frozen dependency policy does not authorize the install argv');
  }
  const manifestPath = relativeWorkspacePath(cwd, policy.manifest_path, 'frozen manifest path');
  const lockfilePath = relativeWorkspacePath(cwd, policy.lockfile_path, 'frozen lockfile path');
  if (path.basename(manifestPath) !== 'package.json' || path.basename(lockfilePath) !== 'package-lock.json') {
    throw new Error('npm frozen dependency policy requires package.json and package-lock.json');
  }
  const manifest = fs.readFileSync(manifestPath);
  const lockfile = fs.readFileSync(lockfilePath);
  return {
    revision: policy.revision,
    manifestPath,
    lockfilePath,
    manifestSha256: sha256(manifest),
    lockfileSha256: sha256(lockfile),
  };
}

function makeResource(kind, operationId, details) {
  const ref = `environment-factory-resource-${sha256(`${kind}\0${operationId}\0${stableStringify(details)}`).slice(0, 32)}`;
  const record = { schema: 'environment-factory.resource.v1', kind, operation_id: operationId, ref, ...details };
  writeJsonAtomic(resourcePath(ref), record);
  return { kind: 'resource-cleanup', ref };
}

function readResource(cleanupRef) {
  if (!cleanupRef || cleanupRef.kind !== 'resource-cleanup' || typeof cleanupRef.ref !== 'string') {
    throw new Error('cleanup_ref is invalid');
  }
  return readIfExists(resourcePath(cleanupRef.ref));
}

const {
  consumeNetworkRequest,
  enforceCurrentBudgets,
  executeBudgetedCommand,
  resourceBudgets,
} = createBudgetRuntime({
  acquireLock,
  durableRoot,
  ledgerPath,
  readIfExists,
  verifyWorkerEnvironment,
  writeJsonAtomic,
});

function effectDeadline(payload) {
  return Date.now() + Math.max(1, Number(payload.timeout_seconds) || 1) * 1000;
}

function remainingTimeoutMs(deadline) {
  return Math.max(1, deadline - Date.now());
}

function workspaceReservation(payload, repository, workspacePath, workspaceContainer, resourceRef) {
  const workspaceRef = { kind: 'workspace', ref: resourceRef };
  const staticBinding = {
    schema: 'environment-factory.resource.v1',
    reservation_schema: 'environment-factory.workspace-reservation.v1',
    reservation_id: resourceRef,
    kind: 'workspace',
    operation_id: payload.operation_id,
    ref: resourceRef,
    path: workspacePath,
    containment_root: workspaceContainer,
    containment_root_identity: pathIdentity(workspaceContainer),
    workspace_ref: workspaceRef,
    repository: { url: repository.url, commit_sha: repository.commit_sha },
    working_directory: payload.working_directory,
    cleaned: false,
  };
  const current = readIfExists(resourcePath(resourceRef));
  if (current) {
    const observedBinding = { ...current };
    delete observedBinding.ownership_token;
    delete observedBinding.cleanup_capture_id;
    delete observedBinding.path_identity;
    delete observedBinding.reservation_state;
    if (stableStringify(observedBinding) !== stableStringify(staticBinding)
      || typeof current.ownership_token !== 'string'
      || !/^[0-9a-f]{64}$/.test(current.ownership_token)
      || typeof current.cleanup_capture_id !== 'string'
      || !/^[0-9a-f]{64}$/.test(current.cleanup_capture_id)) {
      throw new Error('workspace reservation binding differs');
    }
    if (!['reserved', 'allocated'].includes(current.reservation_state)
      || (current.reservation_state === 'allocated' && !current.path_identity)
      || (current.reservation_state === 'reserved' && current.path_identity !== null)) {
      throw new Error('workspace reservation state is malformed');
    }
    return { record: current, created: false };
  }
  if (pathEntryExists(workspacePath)) {
    throw new Error('workspace path already exists before durable reservation');
  }
  const record = {
    ...staticBinding,
    ownership_token: crypto.randomBytes(32).toString('hex'),
    cleanup_capture_id: crypto.randomBytes(32).toString('hex'),
    path_identity: null,
    reservation_state: 'reserved',
  };
  writeJsonAtomic(resourcePath(resourceRef), record);
  return { record, created: true };
}

async function checkout(payload, hooks = {}) {
  return withEffect(payload, async () => {
    const config = targetExecutionConfig(payload);
    const deadline = effectDeadline(payload);
    const repository = payload.repository || {};
    const source = config.repository_mirrors && config.repository_mirrors[repository.url];
    if (typeof source !== 'string' || source === '') throw new Error('repository mirror is unavailable');
    const sourcePath = path.resolve(source);
    if (!/^[0-9a-f]{40}$/.test(String(repository.commit_sha || ''))) throw new Error('exact commit is required');
    fs.mkdirSync(executionRoot(), { recursive: true, mode: 0o700 });
    const runtimeRoot = requireOwnedDirectory(executionRoot(), { privateDirectory: true });
    const factoryRoot = requireOwnedDirectory(
      path.join(runtimeRoot, 'environment-factory'), { privateDirectory: true },
    );
    const workspaceContainer = requireOwnedDirectory(
      path.join(factoryRoot, sha256(payload.operation_id).slice(0, 24)),
      { privateDirectory: true },
    );
    const workspacePath = path.join(workspaceContainer, 'checkout');
    const resourceRef = `environment-factory-resource-${sha256(`workspace\0${payload.operation_id}\0${workspacePath}`).slice(0, 32)}`;
    const workspaceRef = { kind: 'workspace', ref: resourceRef };
    const cleanupRef = { kind: 'resource-cleanup', ref: resourceRef };
    fs.mkdirSync(workspaceContainer, { recursive: true });
    const reservation = workspaceReservation(
      payload, repository, workspacePath, workspaceContainer, resourceRef,
    );
    const workspaceIdentity = prepareReservedWorkspace(
      reservation.record, reservation.record.path_identity, {
        reservationWasCreated: reservation.created,
        hooks,
        persistIdentity(identity) {
          reservation.record = {
            ...reservation.record,
            path_identity: identity,
            reservation_state: 'allocated',
          };
          writeJsonAtomic(resourcePath(resourceRef), reservation.record);
        },
      },
    );
    const result = await withDurableWorkerEnvironment(
      payload, 'checkout', config.command_environment || {}, async (commandEnvironment) => {
        const clone = await executeBudgetedCommand(payload,
          ['git', 'clone', '--quiet', '--no-checkout', sourcePath, '.'], {
            cwd: workspacePath,
            cwdIdentity: workspaceIdentity,
            env: commandEnvironment,
            timeoutMs: remainingTimeoutMs(deadline),
            workspacePath,
          });
        if (clone.reason !== null) {
          return {
            status: 'blocked',
            workspace_ref: workspaceRef,
            cleanup_ref: cleanupRef,
            diagnostic_ref: writeDiagnostic(payload, 'checkout', {
              status: 'blocked', reason: clone.reason, stderr: boundedText(clone.stderr, payload.output_bytes),
            }),
          };
        }
        const checkoutResult = await executeBudgetedCommand(payload,
          ['git', 'checkout', '--quiet', '--detach', repository.commit_sha], {
            cwd: workspacePath,
            cwdIdentity: workspaceIdentity,
            env: commandEnvironment,
            timeoutMs: remainingTimeoutMs(deadline),
            workspacePath,
          });
        const resolved = await executeBudgetedCommand(payload, ['git', 'rev-parse', 'HEAD'], {
          cwd: workspacePath,
          cwdIdentity: workspaceIdentity,
          env: commandEnvironment,
          timeoutMs: remainingTimeoutMs(deadline),
          workspacePath,
        });
        const resolvedCommit = String(resolved.stdout || '').trim();
        const passed = checkoutResult.reason === null && resolved.reason === null
          && resolvedCommit === repository.commit_sha;
        return {
          status: passed ? 'passed' : 'blocked',
          resolved_commit: resolvedCommit || null,
          workspace_ref: workspaceRef,
          cleanup_ref: cleanupRef,
          diagnostic_ref: writeDiagnostic(payload, 'checkout', {
            status: passed ? 'passed' : 'blocked',
            resolved_commit: resolvedCommit,
            stderr: boundedText(`${checkoutResult.stderr} ${resolved.stderr}`, 1024),
          }),
        };
      },
    );
    if (result.status === 'passed' && typeof hooks.afterSuccessfulCheckout === 'function') {
      hooks.afterSuccessfulCheckout({ reservation: { ...reservation.record }, result: { ...result } });
    }
    return result;
  });
}

function remainingBudget(payload) {
  const deadline = Number(payload.deadline_epoch_seconds);
  const total = Number(payload.total_seconds);
  if (!Number.isInteger(deadline) || !Number.isInteger(total)) throw new Error('deadline is invalid');
  return { remaining_seconds: Math.max(0, Math.min(total, deadline - Math.floor(Date.now() / 1000))) };
}

function localHttpOrigin(value) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch (_error) {
    return null;
  }
  if (parsed.protocol !== 'http:' || parsed.username !== '' || parsed.password !== '') return null;
  if (parsed.hostname !== '127.0.0.1' && parsed.hostname !== 'localhost' && parsed.hostname !== '::1') return null;
  return parsed.origin;
}

function fetchBoundedJson(url, maximumBytes = 256 * 1024) {
  return new Promise((resolve, reject) => {
    const request = http.get(url, { timeout: 3000 }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`CDP target list returned HTTP ${response.statusCode}`));
        return;
      }
      const chunks = [];
      let size = 0;
      response.on('data', (chunk) => {
        size += chunk.length;
        if (size > maximumBytes) {
          request.destroy(new Error('CDP target list exceeds the bounded response size'));
          return;
        }
        chunks.push(chunk);
      });
      response.on('end', () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch (error) {
          reject(error);
        }
      });
    });
    request.on('timeout', () => request.destroy(new Error('CDP target list timed out')));
    request.on('error', reject);
  });
}

async function exactReadinessTarget(payload) {
  const endpoints = new Set();
  for (const session of payload.sessions || []) {
    const origin = localHttpOrigin(session && session.cdp_url);
    if (origin) endpoints.add(origin);
  }
  const applicationOrigin = localHttpOrigin(payload.base_url);
  if (endpoints.size !== 1 || applicationOrigin === null) return null;
  try {
    const targets = await fetchBoundedJson(`${[...endpoints][0]}/json/list`);
    const eligible = Array.isArray(targets) ? targets.filter((target) => {
      if (!target || target.type !== 'page' || typeof target.id !== 'string'
        || target.id === '' || target.id.length > 256 || typeof target.webSocketDebuggerUrl !== 'string') return false;
      try {
        const targetUrl = new URL(target.url);
        return targetUrl.origin === applicationOrigin;
      } catch (_error) {
        return false;
      }
    }) : [];
    if (eligible.length !== 1) return null;
    return { target_id: eligible[0].id, target_sha256: sha256(eligible[0].id) };
  } catch (_error) {
    return null;
  }
}

async function createReadinessAttempt(payload) {
  return withEffect(payload, async () => {
    const attemptId = `environment-readiness-${sha256(payload.effect_id).slice(0, 24)}`;
    const ref = {
      kind: 'artifact',
      ref: `${payload.artifact_root}/readiness-attempts/${attemptId}.json`,
    };
    const target = await exactReadinessTarget(payload);
    const attempt = {
      schema: 'environment-factory.readiness-attempt.v1',
      attempt_id: attemptId,
      operation_id: payload.operation_id,
      operation_state_ref: payload.operation_state_ref,
      base_url: payload.base_url,
      sessions: payload.sessions,
      trace_id: payload.trace_id,
      dedup_key: payload.dedup_key,
      ...(target || {}),
    };
    const body = `${stableStringify(attempt)}\n`;
    writeJsonImmutable(artifactPath(ref), attempt);
    return {
      status: 'passed',
      attempt_id: attemptId,
      attempt_ref: ref,
      attempt_sha256: sha256(Buffer.from(body)),
      ...(target || {}),
      diagnostic_ref: ref,
    };
  });
}

function inheritedListenerNames(payload) {
  if (payload.listener_mode !== 'fkst-inherited-listeners-v1') {
    throw new Error('supervised argv requires fkst-inherited-listeners-v1');
  }
  const ports = exactPortList(payload.runtime_ports);
  const count = Number(process.env.FKST_LISTEN_FDS);
  const names = typeof process.env.FKST_LISTEN_FDNAMES === 'string'
    ? process.env.FKST_LISTEN_FDNAMES.split(':').filter((name) => name !== '') : [];
  if (!Number.isInteger(count) || count !== ports.length || names.length !== count
    || !sameArray(names, ports.map((item) => item.name))) {
    throw new Error('inherited listener descriptors differ from runtime_ports');
  }
  return names;
}

async function runArgvEffect(payload) {
  return withEffect(payload, async () => {
    const workspaceResource = readWorkspaceResource(payload.workspace_ref);
    const config = targetExecutionConfig(payload, workspaceResource.repository);
    const argv = validateArgv(payload.argv);
    const workspace = resolveWorkspace(payload);
    const cwd = workspace.cwd;
    const timeoutMs = Math.max(1, Number(payload.timeout_seconds) || 1) * 1000;
    const outputBytes = Number(payload.output_bytes) || DEFAULT_OUTPUT_BYTES;
    if (payload.mode !== 'oneshot' && payload.mode !== 'supervised') {
      throw new Error('unsupported argv mode');
    }
    if (payload.mode === 'oneshot') {
      const frozen = payload.requires_frozen_dependencies === true;
      let frozenProof = null;
      if (frozen) {
        try {
          frozenProof = frozenDependencyPolicy(config, argv, cwd);
        } catch (error) {
          return {
            status: 'blocked',
            frozen_dependencies_enforced: false,
            diagnostic_ref: writeDiagnostic(payload, sha256(payload.effect_id).slice(0, 16), {
              schema: 'environment-factory.command-diagnostic.v1',
              status: 'blocked', reason: boundedText(error.message, 256),
            }),
          };
        }
      }
      const workerRequest = { ...payload, repository: workspaceResource.repository };
      return withDurableWorkerEnvironment(
        workerRequest, `oneshot:${payload.effect_id}`, config.command_environment || {},
        async (environment) => {
          const result = await executeBudgetedCommand(payload, argv, {
            cwd,
            cwdIdentity: workspace.cwdIdentity,
            env: environment,
            timeoutMs,
            workspacePath: workspace.workspaceRoot,
          });
          let frozenEnforced = false;
          if (frozen && result.reason === null) {
            try {
              const afterLock = sha256(fs.readFileSync(frozenProof.lockfilePath));
              const afterManifest = sha256(fs.readFileSync(frozenProof.manifestPath));
              frozenProof.lockfileSha256After = afterLock;
              frozenProof.manifestSha256After = afterManifest;
              frozenEnforced = afterLock === frozenProof.lockfileSha256
                && afterManifest === frozenProof.manifestSha256;
            } catch (_error) {
              frozenEnforced = false;
            }
            if (!frozenEnforced) result.reason = 'frozen-lockfile-changed';
          }
          return {
            status: result.reason === null ? 'passed' : 'blocked',
            ...(frozen ? { frozen_dependencies_enforced: frozenEnforced } : {}),
            diagnostic_ref: writeDiagnostic(payload, sha256(payload.effect_id).slice(0, 16), {
              schema: 'environment-factory.command-diagnostic.v1',
              status: result.reason === null ? 'passed' : 'blocked',
              reason: result.reason,
              exit_code: result.exitCode,
              stderr: boundedText(result.stderr, outputBytes),
              cpu_millis: result.cpuMillis ?? null,
              max_rss_bytes: result.maxRssBytes ?? null,
              max_processes: result.maxProcesses ?? null,
              frozen_dependency_proof: frozenProof && {
                policy_revision: frozenProof.revision,
                manifest_sha256_before: frozenProof.manifestSha256,
                manifest_sha256_after: frozenProof.manifestSha256After ?? null,
                lockfile_sha256_before: frozenProof.lockfileSha256,
                lockfile_sha256_after: frozenProof.lockfileSha256After ?? null,
              },
            }),
          };
        },
      );
    }
    resourceBudgets(payload);
    const workspacePath = workspace.workspaceRoot;
    const before = enforceCurrentBudgets(payload, workspacePath);
    if (!before.passed) {
      return {
        status: 'blocked',
        early_exit: true,
        runtime_ports: exactPortList(payload.runtime_ports),
        diagnostic_ref: writeDiagnostic(payload, sha256(payload.effect_id).slice(0, 16), {
          status: 'blocked', reason: before.reason,
        }),
      };
    }
    const resourceRef = `environment-factory-resource-${sha256(`process\0${payload.operation_id}\0${payload.effect_id}`).slice(0, 32)}`;
    const cleanupRef = { kind: 'resource-cleanup', ref: resourceRef };
    const processResourcePath = resourcePath(resourceRef);
    const startupClaimPath = `${processResourcePath}.startup`;
    const workerRequest = { ...payload, repository: workspaceResource.repository };
    const workerPurpose = `supervised:${payload.effect_id}`;
    const commandEnvironment = config.command_environment || {};
    const starting = {
      schema: 'environment-factory.resource.v1',
      kind: 'process',
      operation_id: payload.operation_id,
      ref: resourceRef,
      effect_id: payload.effect_id,
      argv_sha256: sha256(stableStringify(argv)),
      ownership_token: sha256(stableStringify({
        schema: 'environment-factory.process-ownership.v1',
        operation_id: payload.operation_id,
        effect_id: payload.effect_id,
        ref: resourceRef,
      })),
      runtime_ports: exactPortList(payload.runtime_ports),
      repository: workspaceResource.repository,
      cleaned: false,
    };
    const existing = readIfExists(processResourcePath);
    if (existing) {
      const volatile = new Set([
        'startup_state', 'startup_token_sha256', 'pid', 'pgid',
        'process_start_identity', 'worker_environment_lease', 'worker_home_ledger_ref',
        'worker_home_slot_id',
      ]);
      const existingBinding = Object.fromEntries(
        Object.entries(existing).filter(([key]) => !volatile.has(key)),
      );
      if (stableStringify(existingBinding) !== stableStringify(starting)) {
        throw new Error('supervised process resource binding differs');
      }
      if (stableStringify(existing.worker_home_ledger_ref) !== stableStringify(payload.worker_home_ledger_ref)
        || typeof existing.worker_home_slot_id !== 'string') {
        throw new Error('supervised worker-home ledger binding differs');
      }
      verifyPersistedWorkerEnvironment(
        workerRequest, workerPurpose, commandEnvironment,
        existing.worker_home_slot_id, existing.worker_environment_lease,
      );
      const state = processGroupState(existing);
      const running = state.supported && state.alive && state.foreign !== true;
      return {
        status: running ? 'running' : 'blocked',
        early_exit: !running,
        runtime_ports: exactPortList(payload.runtime_ports),
        cleanup_ref: cleanupRef,
        diagnostic_ref: writeDiagnostic(payload, sha256(payload.effect_id).slice(0, 16), {
          status: running ? 'running' : 'blocked',
          reason: running ? null : 'supervised-process-exited',
          replayed_startup_resource: true,
          output_capture: 'discarded-by-bounded-runtime',
        }),
      };
    }
    const listenerNames = inheritedListenerNames(payload);
    const inheritedStdio = listenerNames.map((_name, index) => 3 + index);
    const createSupervisedEnvironment = (reservation) => {
      const allocation = allocateDurableWorkerEnvironment(
        workerRequest,
        workerPurpose,
        commandEnvironment,
        reservation && reservation.reservation_id,
      );
      const environment = allocation.environment;
      environment.FKST_LISTEN_FDS = String(listenerNames.length);
      environment.FKST_LISTEN_FDNAMES = listenerNames.join(':');
      return { environment, worker_home_slot_id: allocation.slot_id };
    };
    let launchResource = null;
    try {
      const launch = startOrRecoverSupervisedProcess({
        claimPath: startupClaimPath,
        argv,
        cwd,
        cwdIdentity: workspace.cwdIdentity,
        createEnvironment: createSupervisedEnvironment,
        inheritedStdio,
        binding: starting,
      });
      if (launch.interrupted || !launch.resource) {
        throw new Error('supervised process startup was interrupted before registration');
      }
      const resource = launch.resource;
      launchResource = resource;
      resource.worker_home_ledger_ref = payload.worker_home_ledger_ref;
      verifyPersistedWorkerEnvironment(
        workerRequest,
        workerPurpose,
        commandEnvironment,
        resource.worker_home_slot_id,
        resource.worker_environment_lease,
      );
      writeJsonAtomic(processResourcePath, resource);
      const live = processGroupState(resource);
      const running = launch.state === 'running' && live.supported && live.alive && live.foreign !== true;
      const measured = running
        ? enforceCurrentBudgets(payload, workspacePath)
        : { passed: false, reason: launch.state === 'failed'
          ? 'supervised-process-start-failed' : 'supervised-process-exited' };
      if (!measured.passed && running) {
        try { process.kill(-resource.pgid, 'SIGKILL'); } catch (_error) {
          try { process.kill(resource.pid, 'SIGKILL'); } catch (_ignored) {}
        }
      }
      const blocked = !measured.passed;
      return {
        status: blocked ? 'blocked' : 'running',
        early_exit: blocked,
        runtime_ports: exactPortList(payload.runtime_ports),
        cleanup_ref: cleanupRef,
        diagnostic_ref: writeDiagnostic(payload, sha256(payload.effect_id).slice(0, 16), {
          status: blocked ? 'blocked' : 'running',
          reason: blocked ? measured.reason : null,
          output_capture: 'discarded-by-bounded-runtime',
        }),
      };
    } catch (error) {
      if (launchResource) await stopProcess(launchResource, Date.now() + 500);
      return {
        status: 'blocked',
        early_exit: true,
        runtime_ports: exactPortList(payload.runtime_ports),
        cleanup_ref: cleanupRef,
        diagnostic_ref: writeDiagnostic(payload, sha256(payload.effect_id).slice(0, 16), {
          status: 'blocked', reason: boundedText(error.message, 256),
        }),
      };
    }
  });
}

function loopbackHost(value) {
  return value === '127.0.0.1' || value === 'localhost' || value === '::1' || value === '[::1]';
}

function checkTcp(check, timeoutMs) {
  return new Promise((resolve) => {
    if (!loopbackHost(check.host)) return resolve(false);
    const socket = net.connect({ host: check.host, port: check.port });
    const finish = (value) => { socket.destroy(); resolve(value); };
    socket.setTimeout(timeoutMs, () => finish(false));
    socket.once('connect', () => finish(true));
    socket.once('error', () => finish(false));
  });
}

function checkHttp(check, timeoutMs) {
  return new Promise((resolve) => {
    let parsed;
    try { parsed = new URL(check.url); } catch (_error) { return resolve(false); }
    if (!loopbackHost(parsed.hostname) || (parsed.protocol !== 'http:' && parsed.protocol !== 'https:')) return resolve(false);
    const client = parsed.protocol === 'https:' ? https : http;
    const request = client.get({ hostname: parsed.hostname, port: parsed.port, path: parsed.pathname, timeout: timeoutMs }, (response) => {
      response.resume();
      resolve(response.statusCode === Number(check.expected_status));
    });
    request.once('timeout', () => { request.destroy(); resolve(false); });
    request.once('error', () => resolve(false));
  });
}

async function readinessCheck(check, payload, deadline, environment) {
  const remaining = deadline - Date.now();
  if (remaining <= 0) return false;
  if (check.type === 'tcp') return checkTcp(check, Math.min(500, remaining));
  if (check.type === 'http') return checkHttp(check, Math.min(500, remaining));
  if (check.type === 'argv') {
    const workspace = resolveWorkspace(payload);
    const result = await executeBudgetedCommand(payload, validateArgv(check.argv), {
      cwd: workspace.cwd,
      cwdIdentity: workspace.cwdIdentity,
      env: environment,
      timeoutMs: Math.min(2_000, remaining),
      workspacePath: workspace.workspaceRoot,
    });
    return result.reason === null && Date.now() <= deadline;
  }
  return false;
}

function initialReadinessState(budgets, checks) {
  const hasNetworkCheck = checks.some((check) => check.type === 'tcp' || check.type === 'http');
  return {
    attempts: 0,
    probes: 0,
    reason: budgets.network_requests === 0 && hasNetworkCheck
      ? 'network-request-budget-exceeded' : null,
  };
}

async function waitReadiness(payload) {
  return withEffect(payload, async () => {
    const workspaceResource = readWorkspaceResource(payload.workspace_ref);
    const config = targetExecutionConfig(payload, workspaceResource.repository);
    const budgets = resourceBudgets(payload);
    const checks = Array.isArray(payload.checks) ? payload.checks : [];
    const ports = exactPortList(payload.runtime_ports);
    const processResource = readResource(payload.process_cleanup_ref);
    if (!processResource || processResource.kind !== 'process' || processResource.operation_id !== payload.operation_id
      || !sameArray(processResource.runtime_ports, ports)) {
      throw new Error('readiness process ownership binding is invalid');
    }
    const workspacePath = resolveWorkspace(payload).workspaceRoot;
    const usesArgv = checks.some((check) => check.type === 'argv');
    const executeChecks = async (environment) => {
      const deadline = Date.now() + Math.max(1, Number(payload.timeout_seconds) || 1) * 1000;
      let { attempts, probes, reason } = initialReadinessState(budgets, checks);
      let ready = false;
      while (reason === null && Date.now() < deadline) {
        attempts += 1;
        const budget = enforceCurrentBudgets(payload, workspacePath);
        if (!budget.passed) { reason = budget.reason; break; }
        const results = [];
        for (const check of checks) {
          if (check.type === 'tcp' || check.type === 'http') {
            const consumption = consumeNetworkRequest(payload);
            if (!consumption.accepted) {
              reason = 'network-request-budget-exceeded';
              break;
            }
            probes += 1;
          }
          results.push(await readinessCheck(check, payload, deadline, environment));
          if (Date.now() > deadline) { reason = 'readiness-timeout'; break; }
        }
        if (reason === 'network-request-budget-exceeded' || reason === 'readiness-timeout') break;
        if (results.length > 0 && results.every(Boolean)) {
          const ownership = listenersOwnedByProcessGroup(ports, processResource.pgid || processResource.pid);
          if (!ownership.supported) { reason = 'listener-ownership-unavailable'; break; }
          if (!ownership.owned) { reason = ownership.reason; break; }
          ready = true;
          reason = null;
          break;
        }
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
      if (!ready && reason === null) reason = 'readiness-timeout';
      return {
        status: ready ? 'ready' : 'blocked',
        diagnostic_ref: writeDiagnostic(payload, sha256(payload.effect_id).slice(0, 16), {
          status: ready ? 'ready' : 'blocked', attempts, network_requests: probes, reason,
        }),
      };
    };
    if (!usesArgv) return executeChecks(undefined);
    return withDurableWorkerEnvironment(
      { ...payload, repository: workspaceResource.repository },
      `readiness:${payload.effect_id}`,
      config.command_environment || {},
      executeChecks,
    );
  });
}

function processGroupState(resource) {
  const pgid = Number(resource.pgid || resource.pid);
  if (!Number.isInteger(pgid) || pgid < 1) return { supported: true, alive: false };
  const usage = processGroupUsage([pgid]);
  if (!usage.supported) return { supported: false, alive: true };
  if (usage.processes === 0) return { supported: true, alive: false };
  const leader = usage.members.find((item) => item.pid === resource.pid);
  if (leader && typeof resource.process_start_identity === 'string'
    && processStartIdentity(resource.pid) !== resource.process_start_identity) {
    return { supported: true, alive: false, foreign: true };
  }
  return { supported: true, alive: true };
}

const { claimPorts, exactPortList, listenerClaimPlan } = createListenerClaims({
  acquireLock,
  boundEffectOutcome,
  durableRoot,
  effectPath,
  ledgerPath,
  listenersOwnedByProcessGroup,
  lookupDigest,
  makeResource,
  processGroupState,
  readIfExists,
  requestDigest,
  runtimeConfig,
  sha256,
  writeDiagnostic,
  writeJsonAtomic,
});

async function stopProcess(resource, deadline) {
  const pgid = Number(resource.pgid || resource.pid);
  let state = processGroupState(resource);
  if (!state.supported || !state.alive || state.foreign) return;
  try { process.kill(-pgid, 'SIGTERM'); } catch (_error) {
    try { process.kill(resource.pid, 'SIGTERM'); } catch (_ignored) {}
  }
  while (Date.now() < deadline) {
    state = processGroupState(resource);
    if (!state.supported || !state.alive || state.foreign) break;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  state = processGroupState(resource);
  if (state.supported && state.alive && !state.foreign) {
    try { process.kill(-pgid, 'SIGKILL'); } catch (_error) {
      try { process.kill(resource.pid, 'SIGKILL'); } catch (_ignored) {}
    }
  }
}

function resourceIsReleased(resource, workerHomeReleased = false) {
  if (resource.kind === 'process') {
    const state = processGroupState(resource);
    const homeReleased = !resource.worker_environment_lease
      || workerHomeReleased === true || resource.cleaned === true;
    return state.supported && (!state.alive || state.foreign === true) && homeReleased;
  }
  if (resource.kind === 'workspace') return typeof resource.path === 'string' && !pathEntryExists(resource.path);
  if (resource.kind === 'ports') {
    return exactPortList(resource.ports).every((item) => {
      const owner = readIfExists(ledgerPath('ports', item.port));
      return !owner || owner.operation_id !== resource.operation_id || owner.effect_id !== resource.effect_id;
    });
  }
  return false;
}

async function cleanup(payload) {
  if (typeof payload.effect_id !== 'string' || payload.effect_id === '') throw new Error('effect_id is required');
  const digest = requestDigest(payload);
  const release = acquireLock(`${effectPath(payload.effect_id)}.lock`);
  try {
    let resource = readResource(payload.cleanup_ref);
    if (!resource) {
      return {
        status: 'blocked',
        diagnostic_ref: writeDiagnostic(payload, sha256(payload.effect_id).slice(0, 16), {
          status: 'blocked', reason: 'resource record is unavailable',
        }),
      };
    }
    if (resource.operation_id !== payload.operation_id) {
      throw new Error('resource ownership binding is invalid');
    }
    const cached = effectRecord(payload.effect_id);
    if (cached && cached.request_sha256 !== digest) throw new Error('effect request binding differs');
    if (cached && cached.outcome.status === 'cleaned' && resourceIsReleased(resource)) return cached.outcome;
    if (resource.cleaned === true && resourceIsReleased(resource)) {
      const outcome = {
        status: 'cleaned',
        diagnostic_ref: writeDiagnostic(payload, sha256(payload.effect_id).slice(0, 16), { status: 'cleaned', replay: true }),
      };
      writeJsonAtomic(effectPath(payload.effect_id), {
        schema: 'environment-factory.effect.v1', effect_id: payload.effect_id,
        request_sha256: digest, outcome,
      });
      return outcome;
    }

    const deadline = effectDeadline(payload);
    let cleaned = true;
    let blockedReason = null;
    if (resource.kind === 'process') {
      let workerHomeReleased = !resource.worker_environment_lease;
      const config = targetExecutionConfig(payload, resource.repository);
      if (Array.isArray(payload.argv) && payload.argv.length > 0) {
        const cleanupWorkspace = resolveWorkspace(payload);
        const result = await withDurableWorkerEnvironment(
          { ...payload, repository: resource.repository },
          `cleanup-argv:${resource.ref}`,
          config.command_environment || {},
          async (environment) => runMeasuredCommand(validateArgv(payload.argv), {
            cwd: cleanupWorkspace.cwd,
            cwdIdentity: cleanupWorkspace.cwdIdentity,
            env: environment,
            timeoutMs: remainingTimeoutMs(deadline),
            outputBytes: payload.output_bytes,
          }),
        );
        cleaned = result.exitCode === 0 && result.timedOut !== true && result.outputExceeded !== true;
      }
      await stopProcess(resource, deadline);
      const stopped = processGroupState(resource);
      if (stopped.supported && (!stopped.alive || stopped.foreign === true)
        && resource.worker_environment_lease) {
        workerHomeReleased = recordPersistedWorkerEnvironmentRelease({
          ...payload,
          repository: resource.repository,
          worker_home_ledger_ref: resource.worker_home_ledger_ref,
        }, resource.worker_home_slot_id, resource.worker_environment_lease, 'supervised-process-stopped');
        if (!workerHomeReleased) {
          blockedReason = OBJECT_BOUND_CLEANUP_UNAVAILABLE;
        }
      }
      cleaned = cleaned && resourceIsReleased(resource, workerHomeReleased);
      if (!cleaned && blockedReason === null && resource.worker_environment_lease
        && !workerHomeReleased) {
        blockedReason = OBJECT_BOUND_CLEANUP_UNAVAILABLE;
      }
    } else if (resource.kind === 'workspace') {
      if (typeof resource.containment_root !== 'string'
        || !samePathIdentity(pathIdentity(resource.containment_root), resource.containment_root_identity)) {
        throw new Error('workspace containment root identity changed');
      }
      cleaned = removeOwnedDirectory(
        resource.path, resource.path_identity, resource.containment_root,
        resource.cleanup_capture_id,
      );
      if (!cleaned) blockedReason = OBJECT_BOUND_CLEANUP_UNAVAILABLE;
    } else if (resource.kind === 'worker-home-ledger') {
      const result = cleanupWorkerHomeLedger(payload, resource);
      cleaned = result.cleaned;
      if (!cleaned) {
        blockedReason = OBJECT_BOUND_CLEANUP_UNAVAILABLE;
        resource.resource_detail_ref = result.resource_detail_ref;
        resource.resource_detail_sha256 = result.resource_detail_sha256;
        resource.remaining_count = result.remaining_count;
      }
    } else if (resource.kind === 'ports') {
      const lockPath = path.join(durableRoot(), 'environment-factory', 'claim.lock');
      fs.mkdirSync(path.dirname(lockPath), { recursive: true });
      const releaseClaim = acquireLock(lockPath);
      try {
        for (const item of exactPortList(resource.ports)) {
          const ownerPath = ledgerPath('ports', item.port);
          const owner = readIfExists(ownerPath);
          if (owner && owner.operation_id === resource.operation_id && owner.effect_id === resource.effect_id) fs.rmSync(ownerPath, { force: true });
        }
      } finally {
        releaseClaim();
      }
      cleaned = resourceIsReleased(resource);
    } else {
      cleaned = false;
    }
    resource = { ...resource, cleaned };
    writeJsonAtomic(resourcePath(resource.ref), resource);
    const outcome = {
      status: cleaned ? 'cleaned' : 'blocked',
      ...(resource.resource_detail_ref ? {
        resource_detail_ref: resource.resource_detail_ref,
        resource_detail_sha256: resource.resource_detail_sha256,
        remaining_count: resource.remaining_count,
      } : {}),
      diagnostic_ref: writeDiagnostic(payload, sha256(payload.effect_id).slice(0, 16), {
        status: cleaned ? 'cleaned' : 'blocked',
        resource_kind: resource.kind,
        reason: cleaned ? null : (blockedReason || 'resource-release-incomplete'),
      }),
    };
    if (cleaned) {
      writeJsonAtomic(effectPath(payload.effect_id), {
        schema: 'environment-factory.effect.v1', effect_id: payload.effect_id,
        request_sha256: digest, outcome,
      });
    } else {
      fs.rmSync(effectPath(payload.effect_id), { force: true });
    }
    return outcome;
  } finally {
    release();
  }
}

function verifyReceiptEffect(record, payload, receiptPath, body, bodyDigest, requestSha256) {
  if (!record || record.request_sha256 !== requestSha256
    || record.receipt_ref !== stableStringify(payload.receipt_ref) || record.receipt_sha256 !== bodyDigest) {
    throw new Error('receipt effect binding differs');
  }
  if (fs.readFileSync(receiptPath, 'utf8') !== body) throw new Error('immutable receipt is missing or differs');
  return record.outcome;
}

async function writeReceipt(payload) {
  const requestSha256 = requestDigest(payload);
  const receiptPath = artifactPath(payload.receipt_ref);
  const body = `${stableStringify(payload.receipt)}\n`;
  const bodyDigest = sha256(body);
  const existing = effectRecord(payload.effect_id);
  if (existing) return verifyReceiptEffect(existing, payload, receiptPath, body, bodyDigest, requestSha256);
  const release = acquireLock(`${effectPath(payload.effect_id)}.lock`);
  try {
    const replay = effectRecord(payload.effect_id);
    if (replay) return verifyReceiptEffect(replay, payload, receiptPath, body, bodyDigest, requestSha256);
    writeJsonImmutable(receiptPath, payload.receipt);
    const outcome = { status: 'passed' };
    writeJsonAtomic(effectPath(payload.effect_id), {
      schema: 'environment-factory.effect.v1',
      effect_id: payload.effect_id,
      request_sha256: requestSha256,
      receipt_ref: stableStringify(payload.receipt_ref),
      receipt_sha256: bodyDigest,
      outcome,
    });
    return outcome;
  } finally {
    release();
  }
}

async function dispatch(name, payload) {
  if (name === 'load-state') return loadState(payload);
  if (name === 'save-state') return saveState(payload);
  if (name === 'load-authorization-bundle') return loadAuthorizationBundle(payload);
  if (name === 'sha256') return { digest: sha256(String(payload.value || '')) };
  if (name === 'lookup-effect') {
    const record = effectRecord(payload.effect_id);
    if (!record) return { found: false };
    if (typeof record.lookup_request_sha256 !== 'string'
      || record.lookup_request_sha256 !== lookupDigest(payload)) {
      throw new Error('effect lookup binding differs');
    }
    return { found: true, outcome: record.outcome };
  }
  if (name === 'plan-listener-claim') return listenerClaimPlan(payload);
  if (name === 'authorize-claim-ports') return claimPorts(payload);
  if (name === 'initialize-worker-home-ledger') {
    return withEffect(payload, async () => initializeWorkerHomeLedger(payload));
  }
  if (name === 'checkout') return checkout(payload);
  if (name === 'remaining-budget') return remainingBudget(payload);
  if (name === 'create-readiness-attempt') return createReadinessAttempt(payload);
  if (name === 'run-argv') return runArgvEffect(payload);
  if (name === 'wait-readiness') return waitReadiness(payload);
  if (name === 'cleanup') return cleanup(payload);
  if (name === 'write-receipt') return writeReceipt(payload);
  throw new Error(`unknown effect: ${name}`);
}

function runtimeIoPath(value) {
  if (!isSafeArtifactPath(value)) throw new Error('runtime request and response paths must stay under .testing');
  return path.resolve(process.cwd(), value);
}

async function main(argv) {
  if (argv[0] !== 'effect') throw new Error('expected effect command');
  const options = parseArgs(argv.slice(1));
  if (Object.keys(options).sort().join(',') !== 'name,request,response') throw new Error('effect command requires name, request, and response');
  const payload = readJson(runtimeIoPath(options.request));
  const result = await dispatch(options.name, payload);
  writeJsonAtomic(runtimeIoPath(options.response), { ok: true, result: result === undefined ? null : result });
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`environment-factory-runtime: ${boundedText(error && error.stack ? error.stack : error, 4096)}\n`);
    process.exitCode = 1;
  });
}

module.exports = {
  checkout,
  commandResult,
  dispatch,
  initialReadinessState,
  isSafeArtifactPath,
  resourceIsReleased,
  sha256,
  stableStringify,
};
