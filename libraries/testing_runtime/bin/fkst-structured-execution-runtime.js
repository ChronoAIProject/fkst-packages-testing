#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const path = require('path');
const {
  acquireLock,
  artifactPath,
  boundedText,
  isSafeArtifactPath,
  minimalEnvironment,
  parseArgs,
  readJson,
  sha256,
  stableStringify,
  validateArgv,
  writeJsonAtomic,
  writeJsonImmutable,
} = require('../../../packages/environment-factory/bin/runtime/common');
const { runMeasuredCommand } = require('../../../packages/environment-factory/bin/runtime/measured-command');
const { processGroupUsage } = require('../../../packages/environment-factory/bin/runtime/platform');
const { resolveWorkspace } = require('../../../packages/environment-factory/bin/runtime/workspace');

function durableRoot() {
  return path.resolve(process.env.FKST_DURABLE_ROOT || path.join('.testing', 'durable'));
}

function runtimeConfig(payload) {
  const config = readJson(artifactPath(payload.runtime_config_ref));
  if (config.schema !== 'testing-runtime.structured-execution-config.v1') {
    throw new Error('invalid structured execution runtime config schema');
  }
  if (typeof config.state_auth_key !== 'string' || config.state_auth_key.length < 32
    || config.state_auth_key.length > 512) {
    throw new Error('structured execution config requires a bounded state_auth_key');
  }
  if (typeof config.state_mac_generation !== 'string' || config.state_mac_generation === ''
    || config.state_mac_generation.length > 180) {
    throw new Error('structured execution config requires state_mac_generation');
  }
  return config;
}

function artifactRef(value) {
  if (!value || value.kind !== 'artifact' || !isSafeArtifactPath(value.ref)) {
    throw new Error('safe artifact pointer is required');
  }
  return value;
}

function readArtifact(ref) {
  const pointer = artifactRef(ref);
  const raw = fs.readFileSync(artifactPath(pointer), 'utf8');
  return { raw, digest: sha256(raw), value: JSON.parse(raw) };
}

function writeArtifact(ref, value) {
  const pointer = artifactRef(ref);
  const target = artifactPath(pointer);
  const body = `${stableStringify(value)}\n`;
  if (fs.existsSync(target)) {
    if (fs.readFileSync(target, 'utf8') !== body) throw new Error('immutable artifact differs');
    return { written: true, replayed: true, digest: sha256(body) };
  }
  writeJsonImmutable(target, value);
  return { written: true, replayed: false, digest: sha256(body) };
}

function samePointer(left, right) {
  return Boolean(left && right && left.kind === right.kind && left.ref === right.ref);
}

function sameAuthority(left, right) {
  return samePointer(left, right);
}

function verifyGrant(payload) {
  const config = runtimeConfig(payload);
  for (const entry of config.grant_attestations || []) {
    if (entry.grant_sha256 === payload.grant_sha256
      && sameAuthority(entry.authority, payload.grant.authority)
      && entry.policy_revision === payload.grant.policy_revision
      && samePointer(entry.evidence_ref, payload.grant.evidence_ref)) {
      return {
        grant_sha256: entry.grant_sha256,
        authority: entry.authority,
        policy_revision: entry.policy_revision,
        evidence_ref: entry.evidence_ref,
      };
    }
  }
  return { authenticated: false };
}

function replayPath(grantId) {
  return path.join(durableRoot(), 'testing-runner', 'structured-execution', `${sha256(grantId)}.json`);
}

function replayMac(config, value) {
  return crypto.createHmac('sha256', config.state_auth_key)
    .update(`${config.state_mac_generation}\0${stableStringify(value)}`).digest('hex');
}

function replayBinding(payload) {
  return {
    grant_id: payload.grant_id,
    grant_sha256: payload.grant_sha256,
    parent_authorization_sha256: payload.parent_authorization_sha256,
    plan_sha256: payload.plan_sha256,
    environment_receipt_sha256: payload.environment_receipt_sha256,
    repository: payload.repository,
    operation_id: payload.operation_id,
    artifact_root: payload.artifact_root,
    trace_id: payload.trace_id,
    dedup_key: payload.dedup_key,
  };
}

function readReplay(config, grantId) {
  const target = replayPath(grantId);
  if (!fs.existsSync(target)) return null;
  const envelope = readJson(target);
  if (envelope.schema !== 'testing-runtime.structured-execution-replay.v1'
    || envelope.mac !== replayMac(config, envelope.value)) {
    throw new Error('structured execution replay state authentication failed');
  }
  return envelope.value;
}

function writeReplay(config, grantId, value) {
  writeJsonAtomic(replayPath(grantId), {
    schema: 'testing-runtime.structured-execution-replay.v1',
    value,
    mac: replayMac(config, value),
  });
}

function sameRepository(left, right) {
  return Boolean(left && right && left.url === right.url && left.commit_sha === right.commit_sha);
}

function validateExecutionArtifact(payload, binding, expectedDigest) {
  if (!isSafeArtifactPath(payload.result_ref)
    || payload.result_ref !== `${binding.artifact_root}/execution.json`) {
    throw new Error('replay result_ref is outside the claimed structured execution root');
  }
  const artifact = readArtifact({ kind: 'artifact', ref: payload.result_ref });
  if (expectedDigest && artifact.digest !== expectedDigest) throw new Error('completed execution result digest differs');
  const value = artifact.value;
  const statuses = new Set(['passed', 'failed', 'blocked', 'degraded']);
  const counts = ['case_count', 'passed_count', 'failed_count', 'skipped_count', 'error_count'];
  if (!value || value.schema !== 'testing-structured-execution.v1'
    || value.operation_id !== binding.operation_id
    || !statuses.has(value.status) || typeof value.classification !== 'string'
    || !sameRepository(value.repository, binding.repository)
    || value.environment_receipt_sha256 !== binding.environment_receipt_sha256
    || value.trace_id !== binding.trace_id || value.dedup_key !== binding.dedup_key
    || value.test_plan_path !== `${binding.artifact_root}/test-plan.json`
    || value.case_results_path !== `${binding.artifact_root}/case-results.json`
    || value.execution_path !== payload.result_ref
    || counts.some((field) => !Number.isInteger(value[field]) || value[field] < 0)
    || value.case_count !== value.passed_count + value.failed_count + value.skipped_count + value.error_count) {
    throw new Error('completed execution result binding is invalid');
  }
  return artifact;
}

function replayGuard(payload) {
  const config = runtimeConfig(payload);
  const target = replayPath(payload.grant_id);
  const release = acquireLock(`${target}.lock`);
  try {
    const binding = replayBinding(payload);
    const existing = readReplay(config, payload.grant_id);
    if (existing) {
      if (stableStringify(existing.binding) !== stableStringify(binding)) {
        throw new Error('structured execution replay binding differs');
      }
      if (existing.status === 'completed') {
        if (!/^[0-9a-f]{64}$/.test(String(existing.result_sha256 || ''))) {
          throw new Error('completed replay result digest is unavailable');
        }
        return {
          status: 'completed',
          result_ref: existing.result_ref,
          result_sha256: existing.result_sha256,
        };
      }
      return { status: 'in-progress' };
    }
    const claimId = `structured-execution-claim-${replayMac(config, binding).slice(0, 32)}`;
    writeReplay(config, payload.grant_id, { status: 'claimed', claim_id: claimId, binding });
    return { status: 'claimed', claim_id: claimId, grant_id: payload.grant_id };
  } finally {
    release();
  }
}

function completeReplay(payload) {
  const config = runtimeConfig(payload);
  const claim = payload.claim || {};
  if (typeof claim.claim_id !== 'string' || claim.claim_id === ''
    || typeof claim.grant_id !== 'string' || claim.grant_id === '') {
    throw new Error('replay claim is required');
  }
  const target = replayPath(claim.grant_id);
  const release = acquireLock(`${target}.lock`);
  try {
    const current = readReplay(config, claim.grant_id);
    if (!current || current.status !== 'claimed' || current.claim_id !== claim.claim_id) {
      throw new Error('replay completion claim differs');
    }
    const suppliedBinding = replayBinding({ ...current.binding, ...payload, grant_id: claim.grant_id });
    if (stableStringify(current.binding) !== stableStringify(suppliedBinding)) {
      throw new Error('replay completion binding differs');
    }
    const artifact = validateExecutionArtifact(payload, current.binding);
    writeReplay(config, claim.grant_id, {
      ...current,
      status: 'completed',
      result_ref: payload.result_ref,
      result_sha256: artifact.digest,
    });
    return { completed: true, result_sha256: artifact.digest };
  } finally {
    release();
  }
}

function boundedOutput(config) {
  return Math.max(1024, Math.min(Number(config.output_bytes) || 64 * 1024, 1024 * 1024));
}

async function execArgv(payload) {
  const config = runtimeConfig(payload);
  const workspace = resolveWorkspace({ ...payload, require_clean: true });
  const result = await runMeasuredCommand(validateArgv(payload.argv), {
    cwd: workspace.cwd,
    env: minimalEnvironment(config.command_environment || {}),
    timeoutMs: Math.max(1, Number(payload.timeout_seconds) || 1) * 1000,
    outputBytes: boundedOutput(config),
  });
  if (result.timedOut) throw new Error('structured CLI effect timed out');
  if (result.outputExceeded) throw new Error('structured CLI effect exceeded output bound');
  if (result.error) throw result.error;
  const remaining = processGroupUsage([result.pgid]);
  if (!remaining.supported) throw new Error('structured CLI process cleanup verification is unavailable');
  if (remaining.processes > 0) {
    try { process.kill(-result.pgid, 'SIGKILL'); } catch (_error) {}
    throw new Error('structured CLI effect left a surviving process group');
  }
  return {
    exit_code: result.exitCode,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

function localOrigin(value) {
  const parsed = new URL(value);
  if (parsed.protocol !== 'http:' || parsed.username || parsed.password
    || !['127.0.0.1', 'localhost', '::1', '[::1]'].includes(parsed.hostname)) {
    throw new Error('HTTP effect must use loopback HTTP');
  }
  return parsed.origin.toLowerCase();
}

function httpRequest(payload) {
  const config = runtimeConfig(payload);
  const allowedMethods = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE']);
  if (!payload.request || !allowedMethods.has(payload.request.method)
    || !Array.isArray(payload.request.headers) || payload.request.headers.length !== 0) {
    throw new Error('HTTP effect request is invalid');
  }
  const target = new URL(payload.request.url);
  if (target.search || target.hash) throw new Error('HTTP effect URL must not contain query or fragment');
  if (localOrigin(target.toString()) !== localOrigin(payload.base_url)) {
    throw new Error('HTTP effect origin differs from ready environment');
  }
  const maximum = Math.max(1024, Math.min(Number(config.http_response_bytes) || 256 * 1024, 1024 * 1024));
  return new Promise((resolve, reject) => {
    const request = http.request({
      hostname: target.hostname,
      port: target.port,
      path: `${target.pathname}${target.search}`,
      method: payload.request.method,
      headers: {},
      timeout: Math.max(1, Number(payload.timeout_seconds) || 1) * 1000,
    }, (response) => {
      const chunks = [];
      let size = 0;
      response.on('data', (chunk) => {
        size += chunk.length;
        if (size > maximum) request.destroy(new Error('HTTP response exceeded bound'));
        else chunks.push(chunk);
      });
      response.on('end', () => resolve({
        status: response.statusCode,
        body: Buffer.concat(chunks).toString('utf8'),
        headers: {},
      }));
    });
    request.on('timeout', () => request.destroy(new Error('HTTP effect timed out')));
    request.on('error', reject);
    request.end();
  });
}

function loadResult(payload) {
  if (!/^[0-9a-f]{64}$/.test(String(payload.result_sha256 || ''))) {
    throw new Error('completed execution result digest is required');
  }
  const binding = {
    artifact_root: payload.artifact_root,
    operation_id: payload.operation_id,
    repository: payload.repository,
    environment_receipt_sha256: payload.environment_receipt_sha256,
    trace_id: payload.trace_id,
    dedup_key: payload.dedup_key,
  };
  const artifact = validateExecutionArtifact(payload, binding, payload.result_sha256);
  const execution = artifact.value;
  return {
    schema: 'testing-runner.structured-execution-summary.v1',
    status: execution.status,
    classification: execution.classification,
    mode: 'structured-api-cli',
    artifact_root: payload.artifact_root,
    case_count: execution.case_count,
    passed_count: execution.passed_count,
    failed_count: execution.failed_count,
    skipped_count: execution.skipped_count,
    error_count: execution.error_count,
    test_plan_path: execution.test_plan_path,
    case_results_path: execution.case_results_path,
    execution_path: execution.execution_path,
  };
}

async function dispatch(name, payload) {
  if (name === 'load-artifact') return readArtifact(payload.artifact_ref);
  if (name === 'write-artifact') return writeArtifact(payload.artifact_ref, payload.value);
  if (name === 'now') {
    runtimeConfig(payload);
    return { now: new Date().toISOString() };
  }
  if (name === 'verify-grant') return verifyGrant(payload);
  if (name === 'replay-guard') return replayGuard(payload);
  if (name === 'complete-replay') return completeReplay(payload);
  if (name === 'exec-argv') return execArgv(payload);
  if (name === 'http-request') return httpRequest(payload);
  if (name === 'load-result') return loadResult(payload);
  throw new Error(`unknown effect: ${name}`);
}

function runtimeIoPath(value) {
  if (!isSafeArtifactPath(value)) throw new Error('runtime IO path must stay under .testing');
  return artifactPath({ kind: 'artifact', ref: value });
}

async function main(argv) {
  if (argv[0] !== 'effect') throw new Error('expected effect command');
  const options = parseArgs(argv.slice(1));
  if (Object.keys(options).sort().join(',') !== 'name,request,response') {
    throw new Error('effect command requires name, request, and response');
  }
  const payload = readJson(runtimeIoPath(options.request));
  const result = await dispatch(options.name, payload);
  writeJsonAtomic(runtimeIoPath(options.response), { ok: true, result: result === undefined ? null : result });
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`fkst-structured-execution-runtime: ${boundedText(error && error.stack ? error.stack : error, 4096)}\n`);
    process.exitCode = 1;
  });
}

module.exports = { dispatch, localOrigin, runtimeConfig };
