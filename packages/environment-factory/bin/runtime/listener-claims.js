'use strict';

const fs = require('fs');
const path = require('path');

function createListenerClaims(deps) {
  const {
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
    writeDiagnostic,
    writeJsonAtomic,
  } = deps;

  function exactPortList(value, allowEmpty = false) {
    if (!Array.isArray(value) || (!allowEmpty && value.length === 0) || value.length > 32) {
      throw new Error('runtime_ports are invalid');
    }
    const seenPorts = new Set();
    const seenNames = new Set();
    return value.map((item) => {
      const port = Number(item && item.port);
      if (!item || typeof item.name !== 'string' || item.name.length < 1 || item.name.length > 180
        || /[\x00-\x20\x7f]/.test(item.name) || !Number.isInteger(port) || port < 1 || port > 65535
        || seenPorts.has(port) || seenNames.has(item.name)) {
        throw new Error('runtime_ports are invalid');
      }
      seenPorts.add(port);
      seenNames.add(item.name);
      return { name: item.name, port };
    });
  }

  function samePortSet(left, right) {
    if (left.length !== right.length) return false;
    const expected = new Map(left.map((item) => [item.port, item.name]));
    return right.every((item) => expected.get(item.port) === item.name);
  }

  function processResources(operationId) {
    const root = path.join(durableRoot(), 'environment-factory', 'resources');
    let entries;
    try {
      entries = fs.readdirSync(root);
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
    return entries.flatMap((entry) => {
      const resource = readIfExists(path.join(root, entry));
      if (!resource || resource.schema !== 'environment-factory.resource.v1'
        || resource.kind !== 'process' || resource.operation_id !== operationId || resource.cleaned === true) {
        return [];
      }
      return [resource];
    });
  }

  function liveOwnerForPort(operationId, item) {
    const matches = [];
    for (const resource of processResources(operationId)) {
      const declared = exactPortList(resource.runtime_ports || [], true);
      if (!declared.some((candidate) => candidate.port === item.port && candidate.name === item.name)) continue;
      const state = processGroupState(resource);
      if (!state.supported) throw new Error('listener process ownership is unavailable');
      if (!state.alive) continue;
      const ownership = listenersOwnedByProcessGroup([item], resource.pgid || resource.pid);
      if (!ownership.supported) throw new Error('listener ownership inspection is unavailable');
      if (ownership.owned) matches.push(resource);
    }
    if (matches.length > 1) throw new Error(`runtime port ${item.port} has multiple operation owners`);
    return matches[0] || null;
  }

  function listenerClaimPlan(payload) {
    const ports = exactPortList(payload.runtime_ports);
    const needsClaim = [];
    const alreadyOwned = [];
    for (const item of ports) {
      if (liveOwnerForPort(payload.operation_id, item)) alreadyOwned.push(item);
      else needsClaim.push(item);
    }
    return {
      status: 'planned',
      needs_claim: needsClaim,
      already_owned: alreadyOwned,
    };
  }

  function validateClaimPartition(payload, ports) {
    const claimed = exactPortList(payload.listener_claimed_ports || [], true);
    const alreadyOwned = exactPortList(payload.listener_already_owned_ports || [], true);
    const combined = exactPortList([...claimed, ...alreadyOwned], true);
    if (!samePortSet(ports, combined)) throw new Error('listener claim partition differs from runtime_ports');
    for (const item of alreadyOwned) {
      if (!liveOwnerForPort(payload.operation_id, item)) {
        throw new Error(`listener ownership changed before claim commit for port ${item.port}`);
      }
    }
    return { claimed, alreadyOwned };
  }

  async function claimPorts(payload) {
    const digest = requestDigest(payload);
    const config = runtimeConfig(payload);
    const ports = exactPortList(payload.runtime_ports);
    const replay = payload.replay_claim || {};
    const profile = payload.profile_snapshot;
    if (!profile || !profile.timeouts || !Number.isInteger(profile.timeouts.total_seconds)) {
      throw new Error('profile snapshot is invalid');
    }
    validateClaimPartition(payload, ports);
    const existing = boundEffectOutcome(payload.effect_id, digest);
    if (existing) return existing;

    const lockPath = path.join(durableRoot(), 'environment-factory', 'claim.lock');
    fs.mkdirSync(path.dirname(lockPath), { recursive: true });
    const release = acquireLock(lockPath);
    try {
      validateClaimPartition(payload, ports);
      const replayed = boundEffectOutcome(payload.effect_id, digest);
      if (replayed) return replayed;
      const approvalKey = `${replay.approval_id}\0${replay.approval_sha256}`;
      const approvalPath = ledgerPath('approvals', approvalKey);
      const approval = readIfExists(approvalPath);
      if (approval && approval.effect_id !== payload.effect_id) return { status: 'blocked' };

      for (const item of ports) {
        const owner = readIfExists(ledgerPath('ports', item.port));
        if (owner && (owner.operation_id !== payload.operation_id || owner.effect_id !== payload.effect_id)) {
          return { status: 'blocked' };
        }
      }

      const claimId = `environment-factory-claim-${deps.sha256(payload.effect_id).slice(0, 24)}`;
      const cleanupRef = makeResource('ports', payload.operation_id, {
        effect_id: payload.effect_id,
        ports,
      });
      for (const item of ports) {
        writeJsonAtomic(ledgerPath('ports', item.port), {
          schema: 'environment-factory.port-owner.v1',
          operation_id: payload.operation_id,
          effect_id: payload.effect_id,
          cleanup_ref: cleanupRef,
        });
      }
      writeJsonAtomic(approvalPath, {
        schema: 'environment-factory.approval-claim.v1',
        effect_id: payload.effect_id,
        operation_id: payload.operation_id,
        claim_id: claimId,
      });
      const diagnostic = writeDiagnostic(payload, 'port-claim', {
        schema: 'environment-factory.port-claim-diagnostic.v1',
        operation_id: payload.operation_id,
        runtime_ports: ports,
        listener_claimed_ports: payload.listener_claimed_ports || [],
        listener_already_owned_ports: payload.listener_already_owned_ports || [],
        state_authentication: 'scrypt-hmac-sha256',
        runtime_config_revision: config.revision,
      });
      const outcome = {
        status: 'passed',
        profile_snapshot: profile,
        cleanup_ref: cleanupRef,
        runtime_ports: ports,
        deadline_epoch_seconds: Math.floor(Date.now() / 1000) + profile.timeouts.total_seconds,
        diagnostic_ref: diagnostic,
        request_binding: payload.request_binding,
      };
      writeJsonAtomic(effectPath(payload.effect_id), {
        schema: 'environment-factory.effect.v1',
        effect_id: payload.effect_id,
        request_sha256: digest,
        lookup_request_sha256: lookupDigest(payload),
        outcome,
      });
      return { ...outcome, claim_id: claimId };
    } finally {
      release();
    }
  }

  return {
    claimPorts,
    exactPortList,
    listenerClaimPlan,
  };
}

module.exports = { createListenerClaims };
