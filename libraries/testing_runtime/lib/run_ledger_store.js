'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { validateArtifactAttemptCompletion } = require('./artifact_attempt_store');

const IDENTITY_SCHEMA = 'testing-runner.run-identity.v1';
const RECORD_SCHEMA = 'testing-runner.run-ledger-record.v1';
const RESULT_SCHEMA = 'testing-runner.result.v1';
const runnerStatuses = new Set(['planned', 'passed', 'failed', 'blocked', 'degraded']);

function stableStringify(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(',')}}`;
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function exactFields(value, expected, context) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${context} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((field, index) => field !== wanted[index])) {
    throw new Error(`${context} fields are invalid`);
  }
}

function boundedText(value, limit) {
  return typeof value === 'string'
    && value.length > 0
    && Buffer.byteLength(value, 'utf8') <= limit
    && !/[\x00-\x1f\x7f]/.test(value);
}

function identitySegment(value, limit) {
  return boundedText(value, limit) && /^[A-Za-z0-9._-]+$/.test(value);
}

function safeArtifactPath(value) {
  const text = String(value || '');
  if (!text.startsWith('.testing/runs/') || text.startsWith('/') || text.includes('\\') || /\s/.test(text)) return false;
  if (!/^[A-Za-z0-9._\-/#]+$/.test(text)) return false;
  return text.split('/').every((segment) => segment !== '.' && segment !== '..');
}

function validateIdentity(identity) {
  exactFields(identity, ['schema', 'job', 'trace_id', 'dedup_key'], 'run identity');
  if (identity.schema !== IDENTITY_SCHEMA) throw new Error('run identity schema is invalid');
  if (!identitySegment(identity.job, 120)) throw new Error('run identity job is invalid');
  if (!boundedText(identity.trace_id, 180)) throw new Error('run identity trace_id is invalid');
  if (!boundedText(identity.dedup_key, 180)) throw new Error('run identity dedup_key is invalid');
  return identity;
}

function identityFromRecord(record) {
  return {
    schema: IDENTITY_SCHEMA,
    job: record.job,
    trace_id: record.trace_id,
    dedup_key: record.dedup_key,
  };
}

function identityDigest(identity) {
  validateIdentity(identity);
  return sha256(stableStringify(identity));
}

function recordPath(identity, durableRoot) {
  const digest = identityDigest(identity);
  return path.join(durableRoot, 'testing-runner', 'run-ledger', digest.slice(0, 2), `${digest}.json`);
}

function sameIdentity(left, right) {
  return left.job === right.job
    && left.trace_id === right.trace_id
    && left.dedup_key === right.dedup_key;
}

function validateTerminalResult(result, identity, completion) {
  if (result === null || typeof result !== 'object' || Array.isArray(result)) {
    throw new Error('terminal result must be an object');
  }
  if (Buffer.byteLength(stableStringify(result), 'utf8') > 65536) {
    throw new Error('terminal result is too large');
  }
  if (result.schema !== RESULT_SCHEMA) throw new Error('terminal result schema is invalid');
  if (result.job !== identity.job) throw new Error('terminal result job mismatch');
  if (!runnerStatuses.has(result.status)) throw new Error('terminal result status is invalid');
  if (result.trace_id !== identity.trace_id) throw new Error('terminal result trace_id mismatch');
  if (result.dedup_key !== identity.dedup_key) throw new Error('terminal result dedup_key mismatch');
  if (!safeArtifactPath(result.artifact_root) || result.artifact_root !== completion.artifact_pointer) {
    throw new Error('terminal result artifact_root mismatch');
  }
  return result;
}

function validateRecord(record) {
  const baseFields = ['schema', 'state', 'job', 'trace_id', 'dedup_key', 'fence_version'];
  const expected = record && record.state === 'completed'
    ? [...baseFields, 'terminal_attempt', 'terminal_result']
    : baseFields;
  exactFields(record, expected, 'run ledger record');
  if (record.schema !== RECORD_SCHEMA) throw new Error('run ledger record schema is invalid');
  const identity = validateIdentity(identityFromRecord(record));
  if (!Number.isSafeInteger(record.fence_version) || record.fence_version < 1) {
    throw new Error('run ledger fence_version is invalid');
  }
  if (record.state !== 'acquired' && record.state !== 'completed') {
    throw new Error('run ledger state is invalid');
  }
  if (record.state === 'completed') {
    const completion = validateArtifactAttemptCompletion(record.terminal_attempt);
    if (completion.trace_id !== identity.trace_id || completion.dedup_key !== identity.dedup_key) {
      throw new Error('run ledger terminal attempt identity mismatch');
    }
    if (completion.fence_version !== record.fence_version) {
      throw new Error('run ledger terminal attempt fence mismatch');
    }
    validateTerminalResult(record.terminal_result, identity, completion);
  }
  return record;
}

function canonicalRecord(record) {
  return `${stableStringify(validateRecord(record))}\n`;
}

function readRecord(target) {
  if (!fs.existsSync(target)) return null;
  const body = fs.readFileSync(target, 'utf8');
  const record = validateRecord(JSON.parse(body));
  if (body !== canonicalRecord(record)) throw new Error('run ledger record is not canonical');
  return record;
}

function publishExclusive(target, body) {
  const parent = path.dirname(target);
  fs.mkdirSync(parent, { recursive: true });
  const temporary = path.join(parent, `.${path.basename(target)}.${process.pid}.${crypto.randomUUID()}.tmp`);
  try {
    fs.writeFileSync(temporary, body, { flag: 'wx', mode: 0o600 });
    fs.linkSync(temporary, target);
    return true;
  } catch (error) {
    if (error.code === 'EEXIST') return false;
    throw error;
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

function lookupRun(identity, durableRoot) {
  validateIdentity(identity);
  const record = readRecord(recordPath(identity, durableRoot));
  if (record !== null && !sameIdentity(identity, identityFromRecord(record))) {
    throw new Error('run ledger identity mismatch');
  }
  return record;
}

function acquireRun(identity, durableRoot) {
  validateIdentity(identity);
  const target = recordPath(identity, durableRoot);
  const existing = readRecord(target);
  if (existing !== null) return { created: false, record: existing };
  const record = {
    schema: RECORD_SCHEMA,
    state: 'acquired',
    job: identity.job,
    trace_id: identity.trace_id,
    dedup_key: identity.dedup_key,
    fence_version: 1,
  };
  if (publishExclusive(target, canonicalRecord(record))) return { created: true, record };
  return { created: false, record: readRecord(target) };
}

function completeRun(identity, fenceVersion, terminalAttempt, terminalResult, durableRoot) {
  validateIdentity(identity);
  const target = recordPath(identity, durableRoot);
  const before = fs.readFileSync(target, 'utf8');
  const current = validateRecord(JSON.parse(before));
  if (before !== canonicalRecord(current)) throw new Error('run ledger record is not canonical');
  if (!sameIdentity(identity, identityFromRecord(current))) throw new Error('run ledger identity mismatch');
  if (current.state !== 'acquired') throw new Error('run ledger is not acquired');
  if (current.fence_version !== fenceVersion) throw new Error('run ledger fence is stale');

  const completed = {
    schema: RECORD_SCHEMA,
    state: 'completed',
    job: identity.job,
    trace_id: identity.trace_id,
    dedup_key: identity.dedup_key,
    fence_version: fenceVersion,
    terminal_attempt: terminalAttempt,
    terminal_result: terminalResult,
  };
  const parent = path.dirname(target);
  const temporary = path.join(parent, `.${path.basename(target)}.${process.pid}.${crypto.randomUUID()}.tmp`);
  try {
    fs.writeFileSync(temporary, canonicalRecord(completed), { flag: 'wx', mode: 0o600 });
    if (fs.readFileSync(target, 'utf8') !== before) throw new Error('run ledger changed during completion');
    fs.renameSync(temporary, target);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
  return completed;
}

module.exports = {
  acquireRun,
  completeRun,
  lookupRun,
};
