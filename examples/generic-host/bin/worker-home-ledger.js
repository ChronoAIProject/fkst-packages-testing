'use strict';

const LEDGER_SCHEMA = 'environment-factory.worker-home-ledger.v1';
const RETENTION_SCHEMA = 'environment-factory.worker-home-retention.v1';
const RESOURCE_SCHEMA = 'generic-host.environment-resource.v1';
const MAX_ENTRIES = 256;
const MAX_LEDGER_BYTES = 1024 * 1024;

function create(deps) {
  const {
    artifactWrite, fail, minimalEnvironment, recordCas, recordImmutable, recordRead,
    releaseWorkerEnvironmentLease, releaseWorkerEnvironmentReservation,
    reservationMatchesLease, resourceKey, sha256, stable, verifyWorkerEnvironmentLease,
    workerEnvironmentLease, workerEnvironmentReleaseProven, workerEnvironmentReservation,
  } = deps;

  function exactRepository(value) {
    if (!value || typeof value.url !== 'string' || value.url === ''
      || !/^[0-9a-f]{40}$/.test(String(value.commit_sha || ''))) {
      fail('worker-home ledger requires an exact repository identity');
    }
    return { url: value.url, commit_sha: value.commit_sha };
  }

  function identity(operationId, repository) {
    if (typeof operationId !== 'string' || operationId === '') {
      fail('worker-home ledger requires operation_id');
    }
    const exact = exactRepository(repository);
    const binding = {
      schema: 'environment-factory.worker-home-ledger-binding.v1',
      operation_id: operationId,
      repository: exact,
    };
    const ledgerId = sha256(stable(binding));
    return {
      operationId,
      repository: exact,
      ledgerId,
      cleanupRef: {
        kind: 'resource-cleanup',
        ref: `environment-factory-worker-home-ledger-${ledgerId.slice(0, 32)}`,
      },
      key: 'environment-factory/worker-home-ledger',
    };
  }

  function verifyLedger(value, expected) {
    if (!value || value.schema !== LEDGER_SCHEMA || value.ledger_id !== expected.ledgerId
      || value.operation_id !== expected.operationId
      || stable(value.repository) !== stable(expected.repository)
      || value.max_entries !== MAX_ENTRIES || !Number.isInteger(value.version)
      || value.version < 1 || !Array.isArray(value.entries)
      || value.entries.length > MAX_ENTRIES
      || Buffer.byteLength(stable(value)) > MAX_LEDGER_BYTES) {
      fail('worker-home ledger binding differs');
    }
    return value;
  }

  function initialize(root, request) {
    const expected = identity(request.operation_id, request.repository);
    let ledger = recordRead(root, expected.key);
    if (!ledger) {
      const initial = {
        schema: LEDGER_SCHEMA,
        ledger_id: expected.ledgerId,
        operation_id: expected.operationId,
        repository: expected.repository,
        version: 1,
        max_entries: MAX_ENTRIES,
        entries: [],
      };
      const saved = recordCas(root, expected.key, initial, 0);
      ledger = saved.saved ? initial : saved.value;
    }
    verifyLedger(ledger, expected);
    const resource = {
      schema: RESOURCE_SCHEMA,
      kind: 'worker-home-ledger',
      operation_id: expected.operationId,
      cleanup_ref: expected.cleanupRef,
      ledger_id: expected.ledgerId,
      repository: expected.repository,
      ownership_token: sha256(stable({ ledger_id: expected.ledgerId, cleanup_ref: expected.cleanupRef })),
    };
    const stored = recordImmutable(root, resourceKey(expected.cleanupRef), resource);
    if (!stored.written && !stored.replayed) fail('worker-home ledger resource binding differs');
    return { status: 'passed', ledger_id: expected.ledgerId, cleanup_ref: expected.cleanupRef };
  }

  function requireContext(root, request) {
    const expected = identity(request.operation_id, request.repository);
    if (request.worker_home_ledger_ref
      && stable(request.worker_home_ledger_ref) !== stable(expected.cleanupRef)) {
      fail('worker-home ledger cleanup ref differs');
    }
    verifyLedger(recordRead(root, expected.key), expected);
    const resource = recordRead(root, resourceKey(expected.cleanupRef));
    if (!resource || resource.schema !== RESOURCE_SCHEMA || resource.kind !== 'worker-home-ledger'
      || resource.operation_id !== expected.operationId || resource.ledger_id !== expected.ledgerId
      || stable(resource.repository) !== stable(expected.repository)
      || stable(resource.cleanup_ref) !== stable(expected.cleanupRef)) {
      fail('worker-home ledger resource is unavailable');
    }
    return expected;
  }

  function updateLedger(root, expected, update) {
    for (let attempt = 0; attempt < 32; attempt += 1) {
      const current = verifyLedger(recordRead(root, expected.key), expected);
      const next = JSON.parse(stable(current));
      const result = update(next);
      next.version = current.version + 1;
      if (Buffer.byteLength(stable(next)) > MAX_LEDGER_BYTES) {
        fail('WORKER_HOME_LEDGER_CAPACITY_EXCEEDED');
      }
      const saved = recordCas(root, expected.key, next, current.version);
      if (saved.saved) return result;
    }
    fail('worker-home ledger update did not converge');
  }

  function slotBinding(request, purpose, extra) {
    if (typeof request.effect_id !== 'string' || request.effect_id === ''
      || typeof purpose !== 'string' || purpose === '' || purpose.length > 180) {
      fail('worker-home slot identity is invalid');
    }
    return {
      schema: 'environment-factory.worker-home-slot-binding.v1',
      operation_id: request.operation_id,
      effect_id: request.effect_id,
      purpose,
      repository: exactRepository(request.repository),
      environment_sha256: sha256(stable(extra || {})),
    };
  }

  function findSlot(ledger, slotId) {
    return ledger.entries.find((entry) => entry.slot_id === slotId) || null;
  }

  function generationReservationId(baseReservationId, generation) {
    if (generation === 1) return baseReservationId;
    return sha256(stable({
      schema: 'environment-factory.worker-home-generation-reservation.v1',
      base_reservation_id: baseReservationId,
      generation,
    })).slice(0, 32);
  }

  function allocate(root, request, purpose, extra = {}, reservationOverride = null, hooks = {}) {
    const expected = requireContext(root, request);
    const binding = slotBinding(request, purpose, extra);
    const slotId = sha256(stable(binding));
    const baseReservationId = reservationOverride === null
      ? slotId.slice(0, 32) : String(reservationOverride);
    if (!/^[0-9a-f]{32}$/.test(baseReservationId)) fail('worker-home slot reservation is invalid');
    const isolation = {
      schema: 'environment-factory.ledger-worker-isolation.v1',
      ledger_id: expected.ledgerId,
      slot_id: slotId,
      operation_id: request.operation_id,
      effect_id: request.effect_id,
      purpose,
      repository: expected.repository,
    };
    let reservation;
    let reservationId;
    let generation;
    updateLedger(root, expected, (ledger) => {
      let entry = findSlot(ledger, slotId);
      if (entry && stable(entry.binding) !== stable(binding)) {
        fail('worker-home slot binding differs');
      }
      if (entry && (!Number.isInteger(entry.generation) || entry.generation < 1
        || !['reserved', 'allocated', 'retained', 'released'].includes(entry.state))) {
        fail('worker-home slot lifecycle differs');
      }
      if (!entry) {
        if (ledger.entries.length >= ledger.max_entries) fail('WORKER_HOME_LEDGER_CAPACITY_EXCEEDED');
        generation = 1;
        reservationId = generationReservationId(baseReservationId, generation);
        reservation = workerEnvironmentReservation(extra, isolation, reservationId);
        entry = {
          slot_id: slotId,
          reservation_id: reservationId,
          generation,
          binding,
          state: 'reserved',
          release_reason: null,
          worker_environment_reservation: reservation,
          worker_environment_lease: null,
        };
        ledger.entries.push(entry);
      } else if (entry.state === 'released') {
        if (reservationOverride !== null) {
          fail('released worker-home slot cannot reuse a supervised reservation');
        }
        generation = entry.generation + 1;
        reservationId = generationReservationId(baseReservationId, generation);
        reservation = workerEnvironmentReservation(extra, isolation, reservationId);
        entry.generation = generation;
        entry.reservation_id = reservationId;
        entry.state = 'reserved';
        entry.release_reason = null;
        entry.worker_environment_reservation = reservation;
        entry.worker_environment_lease = null;
      } else {
        generation = entry.generation;
        reservationId = generationReservationId(baseReservationId, generation);
        reservation = workerEnvironmentReservation(extra, isolation, reservationId);
        if (entry.reservation_id !== reservationId
          || stable(entry.worker_environment_reservation) !== stable(reservation)) {
          fail('worker-home slot reservation binding differs');
        }
        if (entry.worker_environment_lease) {
          verifyWorkerEnvironmentLease(entry.worker_environment_lease);
        } else {
          fail('worker-home allocation has no durable lease or release proof');
        }
      }
    });

    const environment = minimalEnvironment(extra, isolation, reservationId, hooks);
    if (typeof hooks.afterEnvironmentCreated === 'function') hooks.afterEnvironmentCreated(environment);
    const lease = workerEnvironmentLease(environment);
    if (!reservationMatchesLease(reservation, lease)) {
      fail('worker-home slot lease differs from its durable reservation');
    }
    updateLedger(root, expected, (ledger) => {
      const entry = findSlot(ledger, slotId);
      if (!entry || stable(entry.binding) !== stable(binding)
        || entry.generation !== generation || entry.reservation_id !== reservationId
        || stable(entry.worker_environment_reservation) !== stable(reservation)) {
        fail('worker-home slot reservation is unavailable');
      }
      if (entry.worker_environment_lease
        && stable(entry.worker_environment_lease) !== stable(lease)) {
        fail('worker-home slot lease differs');
      }
      entry.worker_environment_lease = lease;
      entry.state = 'allocated';
      entry.release_reason = null;
    });
    verifyWorkerEnvironmentLease(lease);
    return { environment, identity: expected, lease, slot_id: slotId };
  }

  function recordRelease(root, allocation, reason = 'effect-complete') {
    if (!allocation || !allocation.identity || !allocation.lease
      || typeof allocation.slot_id !== 'string') fail('worker-home allocation is invalid');
    let released = false;
    let releaseReason = reason;
    try {
      released = releaseWorkerEnvironmentLease(allocation.lease);
      if (!released) releaseReason = 'OBJECT_BOUND_CLEANUP_UNAVAILABLE';
    } catch (_error) {
      releaseReason = 'release-verification-failed';
    }
    updateLedger(root, allocation.identity, (ledger) => {
      const entry = findSlot(ledger, allocation.slot_id);
      if (!entry || stable(entry.worker_environment_lease) !== stable(allocation.lease)) {
        fail('worker-home release binding differs');
      }
      entry.state = released ? 'released' : 'retained';
      entry.release_reason = released ? null : releaseReason;
    });
    return released;
  }

  function recordPersistedRelease(root, request, slotId, lease, reason) {
    return recordRelease(root, {
      identity: requireContext(root, request),
      lease,
      slot_id: slotId,
    }, reason);
  }

  function verifyPersisted(root, request, purpose, extra, slotId, lease) {
    const expected = requireContext(root, request);
    const binding = slotBinding(request, purpose, extra || {});
    const expectedSlotId = sha256(stable(binding));
    const ledger = verifyLedger(recordRead(root, expected.key), expected);
    const entry = findSlot(ledger, expectedSlotId);
    if (slotId !== expectedSlotId || !entry || stable(entry.binding) !== stable(binding)
      || stable(entry.worker_environment_lease) !== stable(lease)
      || (entry.state !== 'allocated' && entry.state !== 'retained')) {
      fail('worker-home persisted slot binding differs');
    }
    verifyWorkerEnvironmentLease(lease);
    return true;
  }

  function releaseProven(root, request, slotId, lease) {
    const expected = requireContext(root, request);
    const ledger = verifyLedger(recordRead(root, expected.key), expected);
    const entry = findSlot(ledger, slotId);
    return Boolean(entry && entry.state === 'released'
      && stable(entry.worker_environment_lease) === stable(lease)
      && workerEnvironmentReleaseProven(lease));
  }

  function withEnvironment(root, request, purpose, extra, callback) {
    const allocation = allocate(root, request, purpose, extra);
    try {
      return callback(allocation.environment, allocation);
    } finally {
      recordRelease(root, allocation);
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
      reason: entry.release_reason || 'allocation-not-complete',
    };
    if (lease || reservation) {
      value.identity_sha256 = (lease || reservation).identity_sha256;
      value.marker_sha256 = (lease || reservation).marker_sha256;
    }
    return value;
  }

  function cleanup(root, projectRoot, request, resource) {
    const expected = requireContext(root, {
      ...request,
      repository: resource.repository,
      worker_home_ledger_ref: request.cleanup_ref,
    });
    if (resource.ledger_id !== expected.ledgerId) fail('worker-home cleanup ledger differs');
    updateLedger(root, expected, (ledger) => {
      for (const entry of ledger.entries) {
        if (entry.state === 'released') continue;
        if (!entry.worker_environment_lease) {
          try {
            const released = releaseWorkerEnvironmentReservation(entry.worker_environment_reservation);
            entry.state = released ? 'released' : 'retained';
            entry.release_reason = released ? null : 'OBJECT_BOUND_CLEANUP_UNAVAILABLE';
          } catch (_error) {
            entry.state = 'retained';
            entry.release_reason = 'release-verification-failed';
          }
          continue;
        }
        try {
          const released = releaseWorkerEnvironmentLease(entry.worker_environment_lease);
          entry.state = released ? 'released' : 'retained';
          entry.release_reason = released ? null : 'OBJECT_BOUND_CLEANUP_UNAVAILABLE';
        } catch (_error) {
          entry.state = 'retained';
          entry.release_reason = 'release-verification-failed';
        }
      }
    });
    const ledger = verifyLedger(recordRead(root, expected.key), expected);
    const remaining = ledger.entries.filter((entry) => entry.state !== 'released').map(publicEntry);
    if (remaining.length === 0) return { cleaned: true };
    const ref = `${request.artifact_root}/worker-home-retention-${expected.ledgerId.slice(0, 24)}-v${ledger.version}.json`;
    const snapshot = {
      schema: RETENTION_SCHEMA,
      operation_id: request.operation_id,
      ledger_id: expected.ledgerId,
      repository: expected.repository,
      remaining_count: remaining.length,
      entries: remaining,
    };
    const written = artifactWrite(projectRoot, ref, snapshot);
    return {
      cleaned: false,
      resource_detail_ref: { kind: 'artifact', ref },
      resource_detail_sha256: written.digest,
      remaining_count: remaining.length,
    };
  }

  return {
    allocate, cleanup, initialize, recordPersistedRelease, recordRelease, releaseProven,
    verifyPersisted, withEnvironment,
  };
}

module.exports = { create };
