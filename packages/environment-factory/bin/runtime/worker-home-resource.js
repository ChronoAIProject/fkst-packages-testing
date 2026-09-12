'use strict';

const path = require('path');
const {
  acquireLock,
  artifactPath,
  minimalEnvironment,
  readJson,
  releaseWorkerEnvironmentLease,
  releaseWorkerEnvironmentReservation,
  reservationMatchesLease,
  sha256,
  stableStringify,
  verifyWorkerEnvironmentLease,
  workerEnvironmentReservation,
  workerEnvironmentLease,
  writeJsonAtomic,
  writeJsonImmutable,
} = require('./common');

const LEDGER_SCHEMA = 'environment-factory.worker-home-ledger.v1';
const RETENTION_SCHEMA = 'environment-factory.worker-home-retention.v1';
const RESOURCE_SCHEMA = 'environment-factory.resource.v1';
const MAX_ENTRIES = 256;
const MAX_LEDGER_BYTES = 1024 * 1024;

function durableRoot() {
  return path.resolve(process.env.FKST_DURABLE_ROOT || path.join('.testing', 'durable'));
}

function privatePath(kind, value) {
  return path.join(durableRoot(), 'environment-factory', kind, `${sha256(String(value))}.json`);
}

function readIfExists(filePath) {
  try {
    return readJson(filePath);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

function exactRepository(value) {
  if (!value || typeof value.url !== 'string' || value.url === ''
    || !/^[0-9a-f]{40}$/.test(String(value.commit_sha || ''))) {
    throw new Error('worker-home ledger requires an exact repository identity');
  }
  return { url: value.url, commit_sha: value.commit_sha };
}

function ledgerIdentity(request) {
  if (!request || typeof request.operation_id !== 'string' || request.operation_id === '') {
    throw new Error('worker-home ledger requires operation_id');
  }
  const repository = exactRepository(request.repository);
  const binding = {
    schema: 'environment-factory.worker-home-ledger-binding.v1',
    operation_id: request.operation_id,
    repository,
  };
  const ledgerId = sha256(stableStringify(binding));
  const ref = `environment-factory-worker-home-ledger-${ledgerId.slice(0, 32)}`;
  return {
    binding,
    ledgerId,
    repository,
    cleanupRef: { kind: 'resource-cleanup', ref },
    ledgerPath: privatePath('worker-home-ledgers', ref),
    resourcePath: privatePath('resources', ref),
  };
}

function writeLedger(filePath, value) {
  const body = `${stableStringify(value)}\n`;
  if (Buffer.byteLength(body) > MAX_LEDGER_BYTES) {
    const error = new Error('WORKER_HOME_LEDGER_CAPACITY_EXCEEDED');
    error.code = 'WORKER_HOME_LEDGER_CAPACITY_EXCEEDED';
    throw error;
  }
  writeJsonAtomic(filePath, value);
}

function verifyLedger(value, identity) {
  if (!value || value.schema !== LEDGER_SCHEMA || value.ledger_id !== identity.ledgerId
    || value.operation_id !== identity.binding.operation_id
    || stableStringify(value.repository) !== stableStringify(identity.repository)
    || value.max_entries !== MAX_ENTRIES || !Number.isInteger(value.revision)
    || value.revision < 1 || !Array.isArray(value.entries) || value.entries.length > MAX_ENTRIES) {
    throw new Error('worker-home ledger binding differs');
  }
  return value;
}

function initializeWorkerHomeLedger(request) {
  const identity = ledgerIdentity(request);
  const release = acquireLock(`${identity.ledgerPath}.lock`);
  try {
    const existing = readIfExists(identity.ledgerPath);
    if (existing) {
      verifyLedger(existing, identity);
    } else {
      writeLedger(identity.ledgerPath, {
        schema: LEDGER_SCHEMA,
        ledger_id: identity.ledgerId,
        operation_id: request.operation_id,
        repository: identity.repository,
        revision: 1,
        max_entries: MAX_ENTRIES,
        entries: [],
      });
    }
    const resource = {
      schema: RESOURCE_SCHEMA,
      kind: 'worker-home-ledger',
      operation_id: request.operation_id,
      ref: identity.cleanupRef.ref,
      ledger_id: identity.ledgerId,
      repository: identity.repository,
      cleaned: false,
    };
    const stored = readIfExists(identity.resourcePath);
    if (stored && stableStringify(stored) !== stableStringify(resource)) {
      throw new Error('worker-home ledger resource binding differs');
    }
    if (!stored) writeJsonAtomic(identity.resourcePath, resource);
    return { status: 'passed', ledger_id: identity.ledgerId, cleanup_ref: identity.cleanupRef };
  } finally {
    release();
  }
}

function requireLedgerContext(request) {
  const identity = ledgerIdentity(request);
  if (request.worker_home_ledger_ref
    && stableStringify(request.worker_home_ledger_ref) !== stableStringify(identity.cleanupRef)) {
    throw new Error('worker-home ledger cleanup ref differs');
  }
  const resource = readIfExists(identity.resourcePath);
  if (!resource || resource.schema !== RESOURCE_SCHEMA || resource.kind !== 'worker-home-ledger'
    || resource.operation_id !== request.operation_id || resource.ledger_id !== identity.ledgerId
    || stableStringify(resource.repository) !== stableStringify(identity.repository)) {
    throw new Error('worker-home ledger resource is unavailable');
  }
  return identity;
}

function slotBinding(request, purpose, extra) {
  if (typeof request.effect_id !== 'string' || request.effect_id === ''
    || typeof purpose !== 'string' || purpose === '' || purpose.length > 180) {
    throw new Error('worker-home slot identity is invalid');
  }
  return {
    schema: 'environment-factory.worker-home-slot-binding.v1',
    operation_id: request.operation_id,
    effect_id: request.effect_id,
    purpose,
    repository: exactRepository(request.repository),
    environment_sha256: sha256(stableStringify(extra || {})),
  };
}

function findSlot(ledger, slotId) {
  return ledger.entries.find((entry) => entry.slot_id === slotId) || null;
}

function allocateDurableWorkerEnvironment(
  request, purpose, extra = {}, reservationOverride = null, hooks = {},
) {
  const identity = requireLedgerContext(request);
  const binding = slotBinding(request, purpose, extra);
  const slotId = sha256(stableStringify(binding));
  const reservationId = reservationOverride === null ? slotId.slice(0, 32) : String(reservationOverride);
  if (!/^[0-9a-f]{32}$/.test(reservationId)) {
    throw new Error('worker-home slot reservation is invalid');
  }
  const isolation = {
    schema: 'environment-factory.ledger-worker-isolation.v1',
    ledger_id: identity.ledgerId,
    slot_id: slotId,
    operation_id: request.operation_id,
    effect_id: request.effect_id,
    purpose,
    repository: identity.repository,
  };
  const reservation = workerEnvironmentReservation(extra, isolation, reservationId);
  let release = acquireLock(`${identity.ledgerPath}.lock`);
  try {
    const ledger = verifyLedger(readJson(identity.ledgerPath), identity);
    const existing = findSlot(ledger, slotId);
    if (existing && stableStringify(existing.binding) !== stableStringify(binding)) {
      throw new Error('worker-home slot binding differs');
    }
    if (existing && existing.reservation_id !== reservationId) {
      throw new Error('worker-home slot reservation differs');
    }
    if (existing && (!existing.worker_environment_reservation
      || stableStringify(existing.worker_environment_reservation) !== stableStringify(reservation))) {
      throw new Error('worker-home slot reservation binding differs');
    }
    if (!existing) {
      if (ledger.entries.length >= ledger.max_entries) {
        const error = new Error('WORKER_HOME_LEDGER_CAPACITY_EXCEEDED');
        error.code = 'WORKER_HOME_LEDGER_CAPACITY_EXCEEDED';
        throw error;
      }
      ledger.entries.push({
        slot_id: slotId,
        reservation_id: reservationId,
        generation: 1,
        binding,
        state: 'reserved',
        release_reason: null,
        worker_environment_reservation: reservation,
        worker_environment_lease: null,
      });
      ledger.revision += 1;
      writeLedger(identity.ledgerPath, ledger);
    } else if (existing.state === 'released') {
      existing.generation += 1;
      existing.state = 'reserved';
      existing.release_reason = null;
      existing.worker_environment_reservation = reservation;
      existing.worker_environment_lease = null;
      ledger.revision += 1;
      writeLedger(identity.ledgerPath, ledger);
    }
  } finally {
    release();
  }

  const environment = minimalEnvironment(extra, isolation, reservationId, hooks);
  if (typeof hooks.afterEnvironmentCreated === 'function') hooks.afterEnvironmentCreated(environment);
  const lease = workerEnvironmentLease(environment);
  if (!reservationMatchesLease(reservation, lease)) {
    throw new Error('worker-home slot lease differs from its durable reservation');
  }
  release = acquireLock(`${identity.ledgerPath}.lock`);
  try {
    const ledger = verifyLedger(readJson(identity.ledgerPath), identity);
    const entry = findSlot(ledger, slotId);
    if (!entry || stableStringify(entry.binding) !== stableStringify(binding)
      || stableStringify(entry.worker_environment_reservation) !== stableStringify(reservation)) {
      throw new Error('worker-home slot reservation is unavailable');
    }
    if (entry.worker_environment_lease
      && stableStringify(entry.worker_environment_lease) !== stableStringify(lease)) {
      throw new Error('worker-home slot lease differs');
    }
    entry.worker_environment_lease = lease;
    entry.state = 'allocated';
    entry.release_reason = null;
    ledger.revision += 1;
    writeLedger(identity.ledgerPath, ledger);
    verifyWorkerEnvironmentLease(lease);
  } finally {
    release();
  }
  return { environment, identity, lease, slot_id: slotId };
}

function recordWorkerEnvironmentRelease(allocation, reason = 'effect-complete') {
  if (!allocation || !allocation.identity || !allocation.lease || typeof allocation.slot_id !== 'string') {
    throw new Error('worker-home allocation is invalid');
  }
  let released = false;
  let releaseReason = reason;
  try {
    released = releaseWorkerEnvironmentLease(allocation.lease);
    if (!released) releaseReason = 'OBJECT_BOUND_CLEANUP_UNAVAILABLE';
  } catch (error) {
    releaseReason = `release-failed:${String(error && error.message || error).slice(0, 120)}`;
  }
  const release = acquireLock(`${allocation.identity.ledgerPath}.lock`);
  try {
    const ledger = verifyLedger(readJson(allocation.identity.ledgerPath), allocation.identity);
    const entry = findSlot(ledger, allocation.slot_id);
    if (!entry || stableStringify(entry.worker_environment_lease) !== stableStringify(allocation.lease)) {
      throw new Error('worker-home release binding differs');
    }
    entry.state = released ? 'released' : 'retained';
    entry.release_reason = released ? null : releaseReason;
    ledger.revision += 1;
    writeLedger(allocation.identity.ledgerPath, ledger);
  } finally {
    release();
  }
  return released;
}

function recordPersistedWorkerEnvironmentRelease(request, slotId, lease, reason) {
  return recordWorkerEnvironmentRelease({
    identity: requireLedgerContext(request),
    lease,
    slot_id: slotId,
  }, reason);
}

function verifyPersistedWorkerEnvironment(request, purpose, extra, slotId, lease) {
  const identity = requireLedgerContext(request);
  const binding = slotBinding(request, purpose, extra || {});
  const expectedSlotId = sha256(stableStringify(binding));
  const release = acquireLock(`${identity.ledgerPath}.lock`);
  try {
    const ledger = verifyLedger(readJson(identity.ledgerPath), identity);
    const entry = findSlot(ledger, expectedSlotId);
    if (slotId !== expectedSlotId || !entry
      || stableStringify(entry.binding) !== stableStringify(binding)
      || stableStringify(entry.worker_environment_lease) !== stableStringify(lease)
      || (entry.state !== 'allocated' && entry.state !== 'retained')) {
      throw new Error('worker-home persisted slot binding differs');
    }
    verifyWorkerEnvironmentLease(lease);
    return { identity, lease, slot_id: slotId };
  } finally {
    release();
  }
}

async function withDurableWorkerEnvironment(request, purpose, extra, callback) {
  const allocation = allocateDurableWorkerEnvironment(request, purpose, extra);
  try {
    return await callback(allocation.environment, allocation);
  } finally {
    recordWorkerEnvironmentRelease(allocation);
  }
}

function publicEntry(entry) {
  const lease = entry.worker_environment_lease;
  const reservation = entry.worker_environment_reservation;
  const value = {
    slot_id: entry.slot_id,
    lease_id: lease ? lease.lease_id : entry.reservation_id,
    effect_id: entry.binding.effect_id,
    purpose: entry.binding.purpose,
    generation: entry.generation,
    state: entry.state,
    reason: entry.release_reason && entry.release_reason.startsWith('release-failed:')
      ? 'release-verification-failed' : (entry.release_reason || 'allocation-not-complete'),
  };
  if (lease || reservation) {
    value.identity_sha256 = (lease || reservation).identity_sha256;
    value.marker_sha256 = (lease || reservation).marker_sha256;
  }
  return value;
}

function cleanupWorkerHomeLedger(request, resource) {
  const identity = requireLedgerContext({
    ...request,
    repository: resource.repository,
    worker_home_ledger_ref: request.cleanup_ref,
  });
  if (resource.ledger_id !== identity.ledgerId) throw new Error('worker-home cleanup ledger differs');
  const release = acquireLock(`${identity.ledgerPath}.lock`);
  let ledger;
  try {
    ledger = verifyLedger(readJson(identity.ledgerPath), identity);
    for (const entry of ledger.entries) {
      if (entry.state === 'released') continue;
      if (entry.worker_environment_lease) {
        try {
          const released = releaseWorkerEnvironmentLease(entry.worker_environment_lease);
          entry.state = released ? 'released' : 'retained';
          entry.release_reason = released ? null : 'OBJECT_BOUND_CLEANUP_UNAVAILABLE';
        } catch (error) {
          entry.state = 'retained';
          entry.release_reason = `release-failed:${String(error && error.message || error).slice(0, 120)}`;
        }
      } else {
        try {
          const released = releaseWorkerEnvironmentReservation(entry.worker_environment_reservation);
          entry.state = released ? 'released' : 'retained';
          entry.release_reason = released ? null : 'OBJECT_BOUND_CLEANUP_UNAVAILABLE';
        } catch (error) {
          entry.state = 'retained';
          entry.release_reason = `release-failed:${String(error && error.message || error).slice(0, 120)}`;
        }
      }
    }
    ledger.revision += 1;
    writeLedger(identity.ledgerPath, ledger);
  } finally {
    release();
  }
  const remaining = ledger.entries.filter((entry) => entry.state !== 'released').map(publicEntry);
  if (remaining.length === 0) return { cleaned: true };
  const ref = {
    kind: 'artifact',
    ref: `${request.artifact_root}/worker-home-retention-${identity.ledgerId.slice(0, 24)}-r${ledger.revision}.json`,
  };
  const snapshot = {
    schema: RETENTION_SCHEMA,
    operation_id: request.operation_id,
    ledger_id: identity.ledgerId,
    repository: identity.repository,
    remaining_count: remaining.length,
    entries: remaining,
  };
  writeJsonImmutable(artifactPath(ref), snapshot);
  return {
    cleaned: false,
    resource_detail_ref: ref,
    resource_detail_sha256: sha256(`${stableStringify(snapshot)}\n`),
    remaining_count: remaining.length,
  };
}

module.exports = {
  allocateDurableWorkerEnvironment,
  cleanupWorkerHomeLedger,
  initializeWorkerHomeLedger,
  recordPersistedWorkerEnvironmentRelease,
  recordWorkerEnvironmentRelease,
  verifyPersistedWorkerEnvironment,
  withDurableWorkerEnvironment,
};
