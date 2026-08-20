'use strict';

function create(options) {
  const {
    artifactRead, boundedString, exactKeys, fail, path, safeArtifactPath, samePointer,
    sha256, stableStringify, validDigest, validRepository,
  } = options;
  const canonicalFields = [
    'case_result_set_path', 'case_result_set_artifact_sha256',
    'evidence_manifest_path', 'evidence_manifest_artifact_sha256',
  ];

  function artifactDescendant(value, root) {
    return safeArtifactPath(value) && value.startsWith(`${root}/`);
  }

  function validCanonicalRepository(value) {
    return exactKeys(value, ['id', 'source_ref', 'source_sha256'])
      && boundedString(value.id, 180)
      && exactKeys(value.source_ref, ['kind', 'ref'])
      && boundedString(value.source_ref.kind, 96)
      && boundedString(value.source_ref.ref, 4096)
      && validDigest(value.source_sha256);
  }

  function sameCanonicalRepository(left, right) {
    return validCanonicalRepository(left) && validCanonicalRepository(right)
      && left.id === right.id && samePointer(left.source_ref, right.source_ref)
      && left.source_sha256 === right.source_sha256;
  }

  function expectedCanonicalRepository(value) {
    if (!validRepository(value)) return null;
    return {
      id: value.commit_sha,
      source_ref: { kind: 'git', ref: `${value.url}@${value.commit_sha}` },
      source_sha256: sha256(`${value.url}\n${value.commit_sha}`),
    };
  }

  function canonicalManifestDigest(value) {
    const canonical = { ...value };
    delete canonical.canonical_sha256;
    return sha256(stableStringify(canonical));
  }

  function canonicalArtifactGroup(value, executionRoot) {
    const present = canonicalFields.filter((field) =>
      Object.prototype.hasOwnProperty.call(value, field));
    if (present.length === 0) return null;
    if (present.length !== canonicalFields.length
      || value.case_result_set_path !== `${executionRoot}/case-result-set.json`
      || value.evidence_manifest_path !== `${executionRoot}/evidence-manifest.json`
      || !validDigest(value.case_result_set_artifact_sha256)
      || !validDigest(value.evidence_manifest_artifact_sha256)
      || !validDigest(value.plan_sha256)) {
      fail('structured execution canonical artifact group is invalid');
    }
    return {
      caseResultSetPath: value.case_result_set_path,
      caseResultSetDigest: value.case_result_set_artifact_sha256,
      evidenceManifestPath: value.evidence_manifest_path,
      evidenceManifestDigest: value.evidence_manifest_artifact_sha256,
    };
  }

  function onlyKeys(value, keys) {
    return Boolean(value && typeof value === 'object' && !Array.isArray(value)
      && Object.keys(value).every((key) => keys.includes(key)));
  }

  function samePointerIdentity(left, right) {
    return Boolean(left && right && left.kind === right.kind && left.ref === right.ref);
  }

  function canonicalEvidenceRefs(owner, caseId, referenced, assertionId) {
    if (!Array.isArray(owner.evidence_refs)) {
      fail('structured execution canonical evidence references are invalid');
    }
    for (const reference of owner.evidence_refs) {
      if (!exactKeys(reference, ['kind', 'ref']) || reference.kind !== 'evidence'
        || !boundedString(reference.ref, 180)) {
        fail('structured execution canonical evidence reference is invalid');
      }
      referenced.push({ caseId, assertionId, evidenceId: reference.ref });
    }
  }

  function structuredExecutionArtifacts(projectRoot, resultRef) {
    const execution = artifactRead(projectRoot, resultRef);
    const value = execution && execution.value;
    const executionRoot = path.posix.dirname(resultRef);
    if (!value || value.schema !== 'testing-structured-execution.v1'
      || resultRef !== `${executionRoot}/execution.json`
      || value.execution_path !== resultRef
      || value.test_plan_path !== `${executionRoot}/test-plan.json`
      || value.case_results_path !== `${executionRoot}/case-results.json`) {
      fail('structured execution result binding is invalid');
    }
    const testPlan = artifactRead(projectRoot, value.test_plan_path);
    const caseResults = artifactRead(projectRoot, value.case_results_path);
    if (!testPlan || testPlan.digest !== value.plan_sha256
      || !caseResults || !caseResults.value
      || caseResults.value.plan_sha256 !== value.plan_sha256
      || !Array.isArray(caseResults.value.cases)) {
      fail('structured execution referenced artifacts are unavailable');
    }
    const group = canonicalArtifactGroup(value, executionRoot);
    if (!group) return { execution, testPlan, caseResults };

    const caseResultSet = artifactRead(projectRoot, group.caseResultSetPath);
    const evidenceManifest = artifactRead(projectRoot, group.evidenceManifestPath);
    if (!caseResultSet || caseResultSet.digest !== group.caseResultSetDigest) {
      fail('structured execution case result set artifact digest differs');
    }
    if (!evidenceManifest || evidenceManifest.digest !== group.evidenceManifestDigest) {
      fail('structured execution evidence manifest artifact digest differs');
    }

    const resultSet = caseResultSet.value;
    const planRef = { kind: 'artifact', ref: value.test_plan_path };
    const manifestRef = { kind: 'artifact', ref: group.evidenceManifestPath };
    if (!resultSet || resultSet.schema !== 'testing-case-result-set.v2'
      || resultSet.set_id !== value.operation_id || resultSet.run_id !== value.operation_id
      || !samePointer(resultSet.plan_ref, planRef) || resultSet.plan_sha256 !== value.plan_sha256
      || !onlyKeys(resultSet.evidence_manifest_ref, ['kind', 'ref', 'sha256'])
      || !samePointerIdentity(resultSet.evidence_manifest_ref, manifestRef)
      || !validDigest(resultSet.evidence_manifest_sha256)
      || resultSet.evidence_manifest_artifact_sha256 !== group.evidenceManifestDigest
      || (resultSet.evidence_manifest_ref.sha256 !== undefined
        && resultSet.evidence_manifest_ref.sha256 !== group.evidenceManifestDigest)
      || resultSet.trace_id !== value.trace_id || resultSet.dedup_key !== value.dedup_key
      || !Array.isArray(resultSet.cases) || resultSet.cases.length !== value.case_count) {
      fail('structured execution case result set binding is invalid');
    }

    const manifest = evidenceManifest.value;
    const expectedRepository = expectedCanonicalRepository(value.repository);
    if (!manifest || manifest.schema !== 'testing-evidence-manifest.v1'
      || manifest.canonicalization !== 'fkst-testing-evidence-manifest-canonical-json.v1'
      || manifest.canonical_sha256 !== resultSet.evidence_manifest_sha256
      || manifest.manifest_id !== resultSet.run_id || manifest.run_id !== resultSet.run_id
      || !samePointer(manifest.plan_ref, resultSet.plan_ref)
      || manifest.plan_sha256 !== resultSet.plan_sha256
      || !sameCanonicalRepository(manifest.repository, expectedRepository)
      || !Array.isArray(manifest.entries) || manifest.entries.length !== resultSet.cases.length) {
      fail('structured execution evidence manifest binding is invalid');
    }
    if (canonicalManifestDigest(manifest) !== manifest.canonical_sha256) {
      fail('structured execution evidence manifest canonical digest differs');
    }

    const cases = new Map();
    const caseAssertions = new Map();
    const referenced = [];
    for (const item of resultSet.cases) {
      if (!item || !boundedString(item.case_id, 180) || cases.has(item.case_id)
        || !sameCanonicalRepository(item.repository, manifest.repository)
        || !samePointer(item.plan_ref, resultSet.plan_ref)
        || item.plan_sha256 !== resultSet.plan_sha256
        || item.trace_id !== resultSet.trace_id || item.dedup_key !== resultSet.dedup_key
        || !Array.isArray(item.observations) || !Array.isArray(item.assertions)
        || !Array.isArray(item.evidence_refs) || item.evidence_refs.length !== 1) {
        fail('structured execution canonical case binding is invalid');
      }
      cases.set(item.case_id, item);
      canonicalEvidenceRefs(item, item.case_id, referenced);
      for (const observation of item.observations) {
        if (!observation || typeof observation !== 'object') {
          fail('structured execution canonical observation is invalid');
        }
        canonicalEvidenceRefs(observation, item.case_id, referenced);
      }
      const assertionIds = new Set();
      for (const assertion of item.assertions) {
        if (!assertion || typeof assertion !== 'object' || !boundedString(assertion.assertion_id, 180)
          || assertionIds.has(assertion.assertion_id)) {
          fail('structured execution canonical assertion is invalid');
        }
        assertionIds.add(assertion.assertion_id);
        canonicalEvidenceRefs(assertion, item.case_id, referenced, assertion.assertion_id);
      }
      caseAssertions.set(item.case_id, assertionIds);
    }

    const entryFields = ['evidence_id', 'case_id', 'assertion_id', 'role', 'artifact_ref', 'sha256',
      'media_type', 'size_bytes', 'producer', 'producer_version', 'created_at', 'sensitivity',
      'redaction_classification', 'policy_version', 'policy_status', 'provenance'];
    const roleMedia = { 'runner-log': 'text/plain', screenshot: 'image/png', 'sanitized-json': 'application/json' };
    const entries = new Map();
    for (const entry of manifest.entries) {
      const assertions = entry && caseAssertions.get(entry.case_id);
      if (!onlyKeys(entry, entryFields) || !boundedString(entry.evidence_id, 180)
        || entries.has(entry.evidence_id) || !boundedString(entry.case_id, 180) || !cases.has(entry.case_id)
        || (entry.assertion_id !== undefined
          && (!boundedString(entry.assertion_id, 180) || !assertions.has(entry.assertion_id)))
        || roleMedia[entry.role] !== entry.media_type
        || !exactKeys(entry.artifact_ref, ['kind', 'ref']) || entry.artifact_ref.kind !== 'artifact'
        || !artifactDescendant(entry.artifact_ref.ref, executionRoot) || !validDigest(entry.sha256)
        || !Number.isInteger(entry.size_bytes) || entry.size_bytes < 0 || entry.size_bytes > 1000000000
        || !boundedString(entry.producer, 180) || !boundedString(entry.producer_version, 96)
        || !boundedString(entry.created_at, 40) || Number.isNaN(Date.parse(entry.created_at))
        || !['public', 'internal', 'restricted'].includes(entry.sensitivity)
        || !boundedString(entry.redaction_classification, 64) || !boundedString(entry.policy_version, 96)
        || !['approved', 'redacted', 'withheld'].includes(entry.policy_status)
        || !exactKeys(entry.provenance, ['source_kind', 'source_ref', 'source_sha256'])
        || !boundedString(entry.provenance.source_kind, 96)
        || !boundedString(entry.provenance.source_ref, 4096) || !validDigest(entry.provenance.source_sha256)
        || (entry.provenance.source_kind === 'artifact'
          && (entry.provenance.source_ref !== entry.artifact_ref.ref
            || entry.provenance.source_sha256 !== entry.sha256))) {
        fail('structured execution evidence manifest entry binding is invalid');
      }
      entries.set(entry.evidence_id, entry);
    }
    for (const reference of referenced) {
      const entry = entries.get(reference.evidenceId);
      if (!entry || entry.case_id !== reference.caseId
        || (reference.assertionId && entry.assertion_id && entry.assertion_id !== reference.assertionId)) {
        fail('structured execution canonical evidence reference is unresolved');
      }
    }
    return { execution, testPlan, caseResults, caseResultSet, evidenceManifest };
  }

  return { structuredExecutionArtifacts };
}

module.exports = { create };
