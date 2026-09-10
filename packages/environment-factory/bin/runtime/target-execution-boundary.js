'use strict';

const path = require('path');

const BOUNDARY_SCHEMA = 'testing-host.target-execution-boundary.v1';
const SUPPORTED_MODE = 'trusted-fixture-exact';

function exactKeys(value, keys, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || Object.keys(value).sort().join(',') !== [...keys].sort().join(',')) {
    throw new Error(`${label} fields are invalid`);
  }
}

function validRepository(repository) {
  if (!repository || typeof repository !== 'object' || Array.isArray(repository)) return false;
  if (Object.keys(repository).sort().join(',') !== 'commit_sha,url') return false;
  if (typeof repository.url !== 'string' || repository.url.length > 2048
    || !/^https:\/\/[^/@]+\/[^?#]+$/.test(repository.url) || repository.url.includes('@')) return false;
  return /^[0-9a-f]{40}$/.test(String(repository.commit_sha || ''));
}

function sameRepository(left, right) {
  return validRepository(left) && validRepository(right)
    && left.url === right.url && left.commit_sha === right.commit_sha;
}

function safeHostPolicyAuthority(authority) {
  if (!authority || typeof authority !== 'object' || Array.isArray(authority)) return false;
  if (Object.keys(authority).sort().join(',') !== 'kind,ref') return false;
  return authority.kind === 'host-policy'
    && typeof authority.ref === 'string' && /^[A-Za-z0-9][A-Za-z0-9._/-]{2,255}$/.test(authority.ref)
    && !authority.ref.includes('..') && !authority.ref.includes('//');
}

function safeArtifactPath(value) {
  return typeof value === 'string' && value.startsWith('.testing/') && !path.isAbsolute(value)
    && !value.includes('\\') && !/[\x00-\x20\x7f]/.test(value)
    && value.split('/').every((segment) => segment !== '' && segment !== '.' && segment !== '..');
}

function assertConfigOutsideOperationArtifacts(runtimeConfigRef, artifactRoot) {
  if (!runtimeConfigRef || runtimeConfigRef.kind !== 'artifact'
    || !safeArtifactPath(runtimeConfigRef.ref) || !safeArtifactPath(artifactRoot)) {
    throw new Error('target execution boundary requires safe runtime config and artifact root paths');
  }
  const configPath = path.posix.normalize(runtimeConfigRef.ref);
  const operationRoot = path.posix.normalize(artifactRoot);
  if (!configPath.startsWith('.testing/host/')) {
    throw new Error('target execution runtime config must be in the Host control namespace');
  }
  if (!operationRoot.startsWith('.testing/runs/')) {
    throw new Error('target execution artifact root must be in the run namespace');
  }
  if (configPath === operationRoot || configPath.startsWith(`${operationRoot}/`)) {
    throw new Error('target execution runtime config must be Host-owned outside the operation artifact root');
  }
}

function validateTargetExecutionBoundary(boundary, repository, context = {}) {
  if (boundary && typeof boundary === 'object' && !Array.isArray(boundary)
    && (boundary.authorization_capability === true || boundary.execution_authorized === true)) {
    throw new Error('target execution boundary must remain a non-authorizing admission prerequisite');
  }
  if (!boundary || typeof boundary !== 'object' || Array.isArray(boundary)
    || Object.keys(boundary).sort().join(',') !== [
      'schema', 'mode', 'target_class', 'repository', 'authority', 'policy_revision',
      'authorization_capability', 'execution_authorized',
    ].sort().join(',')) {
    throw new Error('HOST_RUNTIME_ISOLATION_REQUIRED: target execution boundary is missing or malformed');
  }
  exactKeys(boundary, [
    'schema', 'mode', 'target_class', 'repository', 'authority', 'policy_revision',
    'authorization_capability', 'execution_authorized',
  ],
    'target execution boundary');
  if (boundary.schema !== BOUNDARY_SCHEMA) {
    throw new Error('HOST_RUNTIME_ISOLATION_REQUIRED: target execution boundary schema is unsupported');
  }
  if (boundary.mode !== SUPPORTED_MODE) {
    throw new Error('HOST_RUNTIME_ISOLATION_REQUIRED: unsupported target execution boundary mode');
  }
  if (boundary.target_class !== 'host-owned-exact-trusted-fixture') {
    throw new Error('HOST_RUNTIME_ISOLATION_REQUIRED: target is not a Host-owned exact trusted fixture');
  }
  if (boundary.authorization_capability !== false || boundary.execution_authorized !== false) {
    throw new Error('target execution boundary must remain a non-authorizing admission prerequisite');
  }
  if (!validRepository(boundary.repository)) {
    throw new Error('HOST_RUNTIME_ISOLATION_REQUIRED: target execution boundary repository is invalid');
  }
  if (!safeHostPolicyAuthority(boundary.authority)) {
    throw new Error('HOST_RUNTIME_ISOLATION_REQUIRED: target execution boundary authority is invalid');
  }
  if (typeof boundary.policy_revision !== 'string'
    || !/^[A-Za-z0-9][A-Za-z0-9._-]{2,179}$/.test(boundary.policy_revision)) {
    throw new Error('HOST_RUNTIME_ISOLATION_REQUIRED: target execution boundary policy revision is invalid');
  }
  if (repository !== undefined && !sameRepository(boundary.repository, repository)) {
    throw new Error('HOST_RUNTIME_ISOLATION_REQUIRED: target repository is not the exact trusted fixture');
  }
  if (context.runtimeConfigRef !== undefined || context.artifactRoot !== undefined) {
    assertConfigOutsideOperationArtifacts(context.runtimeConfigRef, context.artifactRoot);
  }
  return boundary;
}

module.exports = {
  BOUNDARY_SCHEMA,
  SUPPORTED_MODE,
  assertConfigOutsideOperationArtifacts,
  sameRepository,
  validateTargetExecutionBoundary,
};
