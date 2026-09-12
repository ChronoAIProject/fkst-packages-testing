'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const {
  pathIdentity,
  samePathIdentity,
  verifyWorkerEnvironment,
} = require('./common');
const {
  closeDirectoryAnchor,
  objectBoundExec,
  openDirectoryAnchor,
} = require('./object-bound-exec');
const {
  allocateDurableWorkerEnvironment,
  recordWorkerEnvironmentRelease,
} = require('./worker-home-resource');

function sha256(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

function durableRoot() {
  return path.resolve(process.env.FKST_DURABLE_ROOT || path.join('.testing', 'durable'));
}

function resourcePath(ref) {
  return path.join(durableRoot(), 'environment-factory', 'resources', `${sha256(ref)}.json`);
}

function readResource(workspaceRef) {
  if (!workspaceRef || workspaceRef.kind !== 'workspace' || typeof workspaceRef.ref !== 'string'
    || workspaceRef.ref === '') {
    throw new Error('workspace_ref is required');
  }
  let resource;
  try {
    resource = JSON.parse(fs.readFileSync(resourcePath(workspaceRef.ref), 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error('workspace resource is unavailable');
    throw error;
  }
  if (!resource || resource.schema !== 'environment-factory.resource.v1'
    || resource.kind !== 'workspace' || resource.ref !== workspaceRef.ref) {
    throw new Error('workspace resource is malformed');
  }
  return resource;
}

function sameRepository(left, right) {
  return left && right && left.url === right.url && left.commit_sha === right.commit_sha;
}

function gitOutput(workspaceRoot, workspaceIdentity, argv, label, request) {
  const allocation = allocateDurableWorkerEnvironment(request, `workspace-${label}`);
  let anchor;
  try {
    verifyWorkerEnvironment(allocation.environment);
    anchor = openDirectoryAnchor(workspaceRoot, workspaceIdentity);
    const launch = objectBoundExec(anchor, ['git', ...argv], 3);
    const result = spawnSync(launch.command, launch.argv, {
      cwd: '/',
      encoding: 'utf8',
      env: allocation.environment,
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe', anchor.descriptor],
      timeout: 5_000,
      windowsHide: true,
    });
    if (result.error || result.status !== 0) throw new Error(`workspace ${label} is unavailable`);
    return String(result.stdout || '').trim();
  } finally {
    closeDirectoryAnchor(anchor);
    recordWorkerEnvironmentRelease(allocation);
  }
}

function currentCommit(workspaceRoot, workspaceIdentity, request) {
  return gitOutput(workspaceRoot, workspaceIdentity, ['rev-parse', 'HEAD'], 'commit', request);
}

function trackedChanges(workspaceRoot, workspaceIdentity, request) {
  return gitOutput(workspaceRoot, workspaceIdentity,
    ['status', '--porcelain', '--untracked-files=no'], 'tracked status', request);
}

function resolveWorkspace(request) {
  if (!request || typeof request.operation_id !== 'string' || request.operation_id === '') {
    throw new Error('operation_id is required');
  }
  const resource = readResource(request.workspace_ref);
  if (resource.operation_id !== request.operation_id) throw new Error('workspace ownership binding is invalid');
  if (resource.cleaned === true || typeof resource.path !== 'string' || !fs.existsSync(resource.path)) {
    throw new Error('workspace resource is cleaned or unavailable');
  }
  if (!sameRepository(resource.repository, request.repository || resource.repository)) {
    throw new Error('workspace repository binding is invalid');
  }
  if (typeof resource.working_directory !== 'string' || resource.working_directory === ''
    || path.isAbsolute(resource.working_directory)) {
    throw new Error('workspace working_directory binding is invalid');
  }
  if (request.working_directory !== undefined && request.working_directory !== resource.working_directory) {
    throw new Error('working_directory differs from workspace binding');
  }
  const workspaceRoot = fs.realpathSync(resource.path);
  if (!samePathIdentity(pathIdentity(resource.path), resource.path_identity)) {
    throw new Error('workspace path identity changed');
  }
  if (typeof resource.containment_root !== 'string'
    || !samePathIdentity(pathIdentity(resource.containment_root), resource.containment_root_identity)
    || (workspaceRoot !== fs.realpathSync(resource.containment_root)
      && !workspaceRoot.startsWith(`${fs.realpathSync(resource.containment_root)}${path.sep}`))) {
    throw new Error('workspace containment binding changed');
  }
  const isolationRequest = { ...request, repository: resource.repository };
  if (currentCommit(workspaceRoot, resource.path_identity, isolationRequest)
    !== resource.repository.commit_sha) {
    throw new Error('workspace commit binding is invalid');
  }
  if (request.require_clean === true
    && trackedChanges(workspaceRoot, resource.path_identity, isolationRequest) !== '') {
    throw new Error('workspace tracked files differ from the approved commit');
  }
  const candidate = path.resolve(workspaceRoot, resource.working_directory);
  const cwd = fs.realpathSync(candidate);
  if (cwd !== workspaceRoot && !cwd.startsWith(`${workspaceRoot}${path.sep}`)) {
    throw new Error('working_directory escaped workspace through a symbolic link');
  }
  return { cwd, cwdIdentity: pathIdentity(cwd), resource, workspaceRoot };
}

module.exports = { readResource, resolveWorkspace, resourcePath };
