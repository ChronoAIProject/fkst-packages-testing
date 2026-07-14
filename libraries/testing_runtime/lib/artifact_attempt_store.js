'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const INTENT_SCHEMA = 'test-artifacts.attempt-commit-intent.v1';
const COMPLETION_SCHEMA = 'test-artifacts.attempt-completed.v1';
const MANIFEST_SCHEMA = 'test-artifacts.manifest.v1';

const identityFields = [
  'run_id',
  'trace_id',
  'dedup_key',
  'artifact_kind',
  'attempt_id',
  'fence_version',
];

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

function sha256Digest(value) {
  return typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
}

function safeArtifactPath(value) {
  const text = String(value || '');
  if (!text.startsWith('.testing/runs/') || text.startsWith('/') || text.includes('\\') || /\s/.test(text)) return false;
  if (!/^[A-Za-z0-9._\-/#]+$/.test(text)) return false;
  return text.split('/').every((segment) => segment !== '.' && segment !== '..');
}

function validateIntent(intent) {
  exactFields(intent, ['schema', ...identityFields], 'artifact attempt intent');
  if (intent.schema !== INTENT_SCHEMA) throw new Error('artifact attempt intent schema is invalid');
  if (!identitySegment(intent.run_id, 180)) throw new Error('run_id is invalid');
  if (!boundedText(intent.trace_id, 180)) throw new Error('trace_id is invalid');
  if (!boundedText(intent.dedup_key, 180)) throw new Error('dedup_key is invalid');
  if (!identitySegment(intent.artifact_kind, 120)) throw new Error('artifact_kind is invalid');
  if (!identitySegment(intent.attempt_id, 180)) throw new Error('attempt_id is invalid');
  if (!Number.isSafeInteger(intent.fence_version) || intent.fence_version < 1) {
    throw new Error('fence_version is invalid');
  }
  return intent;
}

function identityBasis(intent) {
  validateIntent(intent);
  return {
    schema: intent.schema,
    run_id: intent.run_id,
    trace_id: intent.trace_id,
    dedup_key: intent.dedup_key,
    artifact_kind: intent.artifact_kind,
    attempt_id: intent.attempt_id,
    fence_version: intent.fence_version,
  };
}

function identityDigest(intent) {
  return sha256(stableStringify(identityBasis(intent)));
}

function deriveArtifactPointer(intent) {
  const digest = identityDigest(intent);
  return `.testing/runs/${intent.run_id}/artifact-attempts/${intent.artifact_kind}/${intent.attempt_id}/fence-${intent.fence_version}-${digest}`;
}

function completionPath(intent, durableRoot) {
  const digest = identityDigest(intent);
  return path.join(durableRoot, 'test-artifacts', 'attempt-completions', digest.slice(0, 2), `${digest}.json`);
}

function entryRelativePath(logicalRoot, entryPath) {
  const prefix = `${logicalRoot}/`;
  if (!entryPath.startsWith(prefix)) throw new Error(`manifest entry escapes artifact root: ${entryPath}`);
  const relative = entryPath.slice(prefix.length);
  if (!relative || relative === 'artifact-manifest.json') throw new Error(`manifest entry is invalid: ${entryPath}`);
  return relative;
}

function physicalEntryPath(physicalRoot, relative) {
  const root = path.resolve(physicalRoot);
  const candidate = path.resolve(physicalRoot, ...relative.split('/'));
  if (!candidate.startsWith(`${root}${path.sep}`)) throw new Error(`manifest entry escapes physical root: ${relative}`);
  return candidate;
}

function validateManifestShape(manifest, logicalRoot) {
  exactFields(
    manifest,
    ['schema', 'artifact_root', 'algorithm', 'entries', 'entry_count', 'root_digest'],
    'artifact manifest',
  );
  if (manifest.schema !== MANIFEST_SCHEMA) throw new Error('artifact manifest schema is invalid');
  if (manifest.artifact_root !== logicalRoot || !safeArtifactPath(manifest.artifact_root)) {
    throw new Error('artifact manifest root does not match the immutable attempt pointer');
  }
  if (manifest.algorithm !== 'sha256') throw new Error('artifact manifest algorithm must be sha256');
  if (!Array.isArray(manifest.entries) || manifest.entries.length > 256) throw new Error('artifact manifest entries are invalid');
  if (!Number.isInteger(manifest.entry_count) || manifest.entry_count !== manifest.entries.length) {
    throw new Error('artifact manifest entry count is invalid');
  }
  if (!sha256Digest(manifest.root_digest)) throw new Error('artifact manifest root digest is invalid');

  let previous = null;
  const seen = new Set();
  for (const entry of manifest.entries) {
    exactFields(entry, ['path', 'media_type', 'size_bytes', 'sha256'], 'artifact manifest entry');
    if (!safeArtifactPath(entry.path)) throw new Error(`artifact manifest entry path is invalid: ${entry.path}`);
    entryRelativePath(logicalRoot, entry.path);
    if (!boundedText(entry.media_type, 120)) throw new Error(`artifact manifest media type is invalid: ${entry.path}`);
    if (!Number.isInteger(entry.size_bytes) || entry.size_bytes < 0 || entry.size_bytes > 1000000000) {
      throw new Error(`artifact manifest size is invalid: ${entry.path}`);
    }
    if (!sha256Digest(entry.sha256)) throw new Error(`artifact manifest digest is invalid: ${entry.path}`);
    if (seen.has(entry.path) || (previous !== null && entry.path <= previous)) {
      throw new Error('artifact manifest entries must be unique and sorted');
    }
    seen.add(entry.path);
    previous = entry.path;
  }

  const rootDigest = sha256(manifest.entries
    .map((entry) => `${entry.path}\0${entry.size_bytes}\0${entry.sha256}\n`)
    .join(''));
  if (rootDigest !== manifest.root_digest) throw new Error('artifact manifest root digest mismatch');
  return manifest;
}

function verifyManifestBytes(manifest, physicalRoot) {
  for (const entry of manifest.entries) {
    const relative = entryRelativePath(manifest.artifact_root, entry.path);
    const body = fs.readFileSync(physicalEntryPath(physicalRoot, relative));
    if (body.length !== entry.size_bytes) throw new Error(`artifact size mismatch: ${entry.path}`);
    if (sha256(body) !== entry.sha256) throw new Error(`artifact digest mismatch: ${entry.path}`);
  }
}

function readStagedManifest(stagedRoot, artifactPointer) {
  const manifestPath = path.join(stagedRoot, 'artifact-manifest.json');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  validateManifestShape(manifest, artifactPointer);
  verifyManifestBytes(manifest, stagedRoot);
  return manifest;
}

function materializeVerifiedAttempt(manifest, stagedRoot, artifactPointer) {
  const parent = path.dirname(artifactPointer);
  fs.mkdirSync(parent, { recursive: true });
  if (fs.existsSync(artifactPointer)) throw new Error('immutable artifact attempt already exists');
  const temporary = path.join(parent, `.${path.basename(artifactPointer)}.${process.pid}.${crypto.randomUUID()}.tmp`);
  fs.mkdirSync(temporary);
  try {
    for (const entry of manifest.entries) {
      const relative = entryRelativePath(artifactPointer, entry.path);
      const source = physicalEntryPath(stagedRoot, relative);
      const target = physicalEntryPath(temporary, relative);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.copyFileSync(source, target, fs.constants.COPYFILE_EXCL);
    }
    const manifestBytes = `${stableStringify(manifest)}\n`;
    fs.writeFileSync(path.join(temporary, 'artifact-manifest.json'), manifestBytes, { flag: 'wx' });
    verifyManifestBytes(manifest, temporary);
    fs.renameSync(temporary, artifactPointer);
    return sha256(manifestBytes);
  } catch (error) {
    fs.rmSync(temporary, { recursive: true, force: true });
    throw error;
  }
}

function validateCompletion(completion, intent) {
  exactFields(
    completion,
    ['schema', ...identityFields, 'manifest_sha256', 'artifact_pointer'],
    'artifact attempt completion',
  );
  if (completion.schema !== COMPLETION_SCHEMA) throw new Error('artifact attempt completion schema is invalid');
  for (const field of identityFields) {
    if (completion[field] !== intent[field]) throw new Error(`artifact attempt completion ${field} mismatch`);
  }
  if (!sha256Digest(completion.manifest_sha256)) throw new Error('artifact attempt manifest digest is invalid');
  if (completion.artifact_pointer !== deriveArtifactPointer(intent)) {
    throw new Error('artifact attempt pointer does not match its stable identity');
  }
  return completion;
}

function validateArtifactAttemptCompletion(completion) {
  const intent = {
    schema: INTENT_SCHEMA,
    run_id: completion && completion.run_id,
    trace_id: completion && completion.trace_id,
    dedup_key: completion && completion.dedup_key,
    artifact_kind: completion && completion.artifact_kind,
    attempt_id: completion && completion.attempt_id,
    fence_version: completion && completion.fence_version,
  };
  validateIntent(intent);
  return validateCompletion(completion, intent);
}

function publishCompletion(completion, intent, durableRoot) {
  const target = completionPath(intent, durableRoot);
  const parent = path.dirname(target);
  fs.mkdirSync(parent, { recursive: true });
  if (fs.existsSync(target)) throw new Error('artifact attempt completion already exists');
  const temporary = path.join(parent, `.${path.basename(target)}.${process.pid}.${crypto.randomUUID()}.tmp`);
  try {
    fs.writeFileSync(temporary, `${stableStringify(completion)}\n`, { flag: 'wx', mode: 0o600 });
    fs.renameSync(temporary, target);
  } catch (error) {
    fs.rmSync(temporary, { force: true });
    throw error;
  }
}

function commitArtifactAttempt(intent, stagedRoot, durableRoot) {
  validateIntent(intent);
  if (!safeArtifactPath(stagedRoot)) throw new Error('staged artifact root is invalid');
  const artifactPointer = deriveArtifactPointer(intent);
  const manifest = readStagedManifest(stagedRoot, artifactPointer);
  const manifestSha256 = materializeVerifiedAttempt(manifest, stagedRoot, artifactPointer);
  const completion = {
    schema: COMPLETION_SCHEMA,
    run_id: intent.run_id,
    trace_id: intent.trace_id,
    dedup_key: intent.dedup_key,
    artifact_kind: intent.artifact_kind,
    attempt_id: intent.attempt_id,
    fence_version: intent.fence_version,
    manifest_sha256: manifestSha256,
    artifact_pointer: artifactPointer,
  };
  validateCompletion(completion, intent);
  publishCompletion(completion, intent, durableRoot);
  return completion;
}

function lookupArtifactAttempt(intent, durableRoot) {
  validateIntent(intent);
  const target = completionPath(intent, durableRoot);
  if (!fs.existsSync(target)) return null;
  const body = fs.readFileSync(target, 'utf8');
  const completion = validateCompletion(JSON.parse(body), intent);
  if (body !== `${stableStringify(completion)}\n`) throw new Error('artifact attempt completion is not canonical');
  const manifestPath = path.join(completion.artifact_pointer, 'artifact-manifest.json');
  const manifestBytes = fs.readFileSync(manifestPath);
  if (sha256(manifestBytes) !== completion.manifest_sha256) throw new Error('published artifact manifest digest mismatch');
  validateManifestShape(JSON.parse(manifestBytes.toString('utf8')), completion.artifact_pointer);
  return completion;
}

module.exports = {
  commitArtifactAttempt,
  deriveArtifactPointer,
  lookupArtifactAttempt,
  validateArtifactAttemptCompletion,
};
