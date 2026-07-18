'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const {
  acquireLock,
  artifactPath,
  readJson,
  runtimeConfig,
  samePointer,
  stableStringify,
  writeJsonAtomic,
} = require('./common');

function authenticationBytes(pointer, state, keyRevision, revision) {
  return stableStringify({
    key_revision: keyRevision,
    revision,
    state_ref: pointer,
    state,
  });
}

function stateMacKey(config) {
  return crypto.scryptSync(
    config.state_auth_key,
    `environment-factory-state-v1\0${config.state_auth_key_revision}`,
    32,
  );
}

function stateMac(value, config) {
  return crypto.createHmac('sha256', stateMacKey(config)).update(value).digest('hex');
}

function loadState(payload) {
  const config = runtimeConfig(payload);
  const statePath = artifactPath(payload.ref);
  let envelope;
  try {
    envelope = readJson(statePath);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
  if (!envelope || envelope.schema !== 'environment-factory.authenticated-state.v1'
    || typeof envelope.mac !== 'string') {
    return { authenticated: false, state: envelope && envelope.state ? envelope.state : envelope };
  }
  const bindingMatches = envelope.key_revision === config.state_auth_key_revision
    && Number.isInteger(envelope.revision) && envelope.revision >= 1
    && samePointer(envelope.state_ref, payload.ref);
  const actual = stateMac(
    authenticationBytes(payload.ref, envelope.state, config.state_auth_key_revision, envelope.revision),
    config,
  );
  const left = Buffer.from(actual);
  const right = Buffer.from(envelope.mac);
  const authenticated = bindingMatches && left.length === right.length
    && crypto.timingSafeEqual(left, right);
  return { authenticated, state: envelope.state, revision: envelope.revision };
}

function saveState(payload) {
  const config = runtimeConfig(payload);
  const statePath = artifactPath(payload.ref);
  const expected = Number(payload.expected_revision);
  if (!Number.isInteger(expected) || expected < 0) throw new Error('expected state revision is required');
  fs.mkdirSync(path.dirname(statePath), { recursive: true });
  const release = acquireLock(`${statePath}.lock`);
  try {
    let current = null;
    try { current = readJson(statePath); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const currentRevision = current === null ? 0 : current.revision;
    if (!Number.isInteger(currentRevision) || currentRevision < 0) {
      throw new Error('current state revision is malformed');
    }
    if (currentRevision !== expected) return { saved: false, stale: true, revision: currentRevision };
    const revision = currentRevision + 1;
    const envelope = {
      schema: 'environment-factory.authenticated-state.v1',
      key_revision: config.state_auth_key_revision,
      revision,
      state_ref: payload.ref,
      state: payload.state,
      mac: stateMac(
        authenticationBytes(payload.ref, payload.state, config.state_auth_key_revision, revision),
        config,
      ),
    };
    writeJsonAtomic(statePath, envelope);
    return { saved: true, revision };
  } finally {
    release();
  }
}

module.exports = { loadState, saveState };
