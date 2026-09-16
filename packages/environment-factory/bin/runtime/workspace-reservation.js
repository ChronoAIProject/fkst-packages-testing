'use strict';

const path = require('path');
const {
  allocateOwnedDirectory,
  ownedDirectoryReleaseProven,
  pathEntryExists,
  pathIdentity,
  removeOwnedDirectory,
  retireOwnedDirectoryMarker,
  samePathIdentity,
  sha256,
  stableStringify,
} = require('./common');

const MARKER_NAME = '.fkst-workspace-reservation.json';

function reservationMarker(reservation) {
  return `${stableStringify({
    schema: 'environment-factory.workspace-reservation-marker.v1',
    reservation_id: reservation.reservation_id,
    operation_id: reservation.operation_id,
    path: reservation.path,
    repository: reservation.repository,
    ownership_token_sha256: sha256(reservation.ownership_token),
  })}\n`;
}

function verifyReservation(reservation) {
  if (!reservation || reservation.reservation_schema !== 'environment-factory.workspace-reservation.v1'
    || typeof reservation.reservation_id !== 'string' || reservation.reservation_id === ''
    || typeof reservation.operation_id !== 'string' || reservation.operation_id === ''
    || typeof reservation.path !== 'string' || !path.isAbsolute(reservation.path)
    || typeof reservation.containment_root !== 'string' || !path.isAbsolute(reservation.containment_root)
    || path.dirname(reservation.path) !== reservation.containment_root
    || typeof reservation.ownership_token !== 'string' || !/^[0-9a-f]{64}$/.test(reservation.ownership_token)
    || typeof reservation.cleanup_capture_id !== 'string'
    || !/^[0-9a-f]{64}$/.test(reservation.cleanup_capture_id)
    || !reservation.repository || typeof reservation.repository.url !== 'string'
    || !/^[0-9a-f]{40}$/.test(String(reservation.repository.commit_sha || ''))
    || !samePathIdentity(pathIdentity(reservation.containment_root), reservation.containment_root_identity)) {
    throw new Error('workspace reservation binding differs');
  }
  return reservation;
}

function allocationId(reservation) {
  return sha256(stableStringify({
    schema: 'environment-factory.workspace-directory-allocation.v1',
    reservation_id: reservation.reservation_id,
    ownership_token_sha256: sha256(reservation.ownership_token),
  }));
}

function prepareReservedWorkspace(reservation, persistedIdentity, options = {}) {
  verifyReservation(reservation);
  const hooks = options.hooks || {};
  if (persistedIdentity) {
    const recoveryCaptureId = sha256(stableStringify({
      schema: 'environment-factory.workspace-recovery-cleanup.v1',
      reservation_id: reservation.reservation_id,
      path_identity: persistedIdentity,
      cleanup_capture_id: reservation.cleanup_capture_id,
    }));
    if (!pathEntryExists(reservation.path)) {
      if (!ownedDirectoryReleaseProven(
        reservation.path, persistedIdentity, reservation.containment_root, recoveryCaptureId,
      )) throw new Error('workspace reserved object is missing without release proof');
    } else {
      if (!samePathIdentity(pathIdentity(reservation.path), persistedIdentity)) {
        throw new Error('workspace reserved object identity changed');
      }
      if (!removeOwnedDirectory(
        reservation.path, persistedIdentity, reservation.containment_root,
        recoveryCaptureId,
      )) throw new Error('workspace reserved object cleanup is unavailable');
    }
    if (typeof hooks.afterWorkspaceRecoveryReleased === 'function') {
      hooks.afterWorkspaceRecoveryReleased({
        reservation: { ...reservation }, recovery_capture_id: recoveryCaptureId,
      });
    }
  } else if (options.reservationWasCreated === true && pathEntryExists(reservation.path)) {
    throw new Error('workspace path already exists without recoverable reservation ownership');
  } else if (options.reservationWasCreated !== true && !pathEntryExists(reservation.path)) {
    throw new Error('workspace allocation identity is unavailable for recovery');
  }

  const existedBefore = pathEntryExists(reservation.path);
  const marker = reservationMarker(reservation);
  const identifier = allocationId(reservation);
  const identity = allocateOwnedDirectory(
    reservation.path,
    reservation.containment_root,
    reservation.containment_root_identity,
    identifier,
    MARKER_NAME,
    marker,
  );
  if (!existedBefore && typeof hooks.afterWorkspaceDirectoryCreated === 'function') {
    hooks.afterWorkspaceDirectoryCreated({ reservation: { ...reservation } });
  }
  if (!samePathIdentity(pathIdentity(reservation.path), identity)) {
    throw new Error('workspace identity changed after allocation');
  }
  if (typeof options.persistIdentity !== 'function') {
    throw new Error('workspace reservation identity persistence is unavailable');
  }
  options.persistIdentity(identity);
  if (typeof hooks.afterWorkspaceResourceRegistered === 'function') {
    hooks.afterWorkspaceResourceRegistered({ reservation: { ...reservation }, path_identity: identity });
  }
  if (!samePathIdentity(pathIdentity(reservation.path), identity)) {
    throw new Error('workspace identity changed before marker retirement');
  }
  retireOwnedDirectoryMarker(
    reservation.path,
    identity,
    reservation.containment_root,
    reservation.containment_root_identity,
    identifier,
    MARKER_NAME,
    marker,
  );
  return identity;
}

module.exports = {
  prepareReservedWorkspace,
  reservationMarker,
  verifyReservation,
};
