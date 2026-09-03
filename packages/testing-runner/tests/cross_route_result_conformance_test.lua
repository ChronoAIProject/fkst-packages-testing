local evidence = require("contract.testing_evidence_manifest")
local results = require("contract.testing_results")
local structured = require("contract.structured_execution")
local sha256 = require("tests.fixtures.sha256_helpers")
local t = fkst.test

local root = ".testing/runs/cross-route-conformance"
local run_id = "cross-route-conformance"
local plan_sha256 = string.rep("a", 64)
local repository = {
  id = "repository-identity",
  source_ref = { kind = "git", ref = "https://github.com/owner/repo.git@" .. string.rep("1", 40) },
  source_sha256 = string.rep("b", 64),
}
local plan_ref = { kind = "artifact", ref = root .. "/test-plan.json" }
local authority = {
  plan_ref = plan_ref,
  plan_sha256 = plan_sha256,
  reviewed_case_id = "case-equivalent",
  assertions = {
    { assertion_id = "assertion-required", required = true },
    { assertion_id = "assertion-optional", required = false },
  },
}
local outcomes = {
  passed = {
    classification = "deterministic",
    assertions = { { "passed", "deterministic" }, { "skipped", "not_applicable" } },
  },
  failed = {
    classification = "assertion_failure",
    assertions = { { "failed", "assertion_failure" }, { "skipped", "not_applicable" } },
  },
  skipped = {
    classification = "not_applicable",
    non_execution_reason = "platform-not-applicable",
    assertions = { { "skipped", "not_applicable" }, { "skipped", "not_applicable" } },
  },
  error = {
    classification = "execution_error",
    error = { code = "provider-timeout", message = "The execution provider timed out." },
    assertions = { { "skipped", "not_applicable" }, { "skipped", "not_applicable" } },
  },
  lost = {
    classification = "lost",
    non_execution_reason = "runner-disconnected",
    assertions = { { "skipped", "not_applicable" }, { "skipped", "not_applicable" } },
  },
}

local function copy(value) return structured.copy(value) end

local function bundle(route, status)
  local outcome = outcomes[status]
  local evidence_id = "evidence-equivalent"
  local artifact_ref = root .. "/evidence/" .. route .. "-observation.json"
  local artifact_sha256 = sha256(route .. " observation\n")
  local observation_id = "observation-equivalent"
  local assertions = {}
  for index, assertion_outcome in ipairs(outcome.assertions) do
    assertions[index] = {
      schema = results.schemas.assertion_result,
      assertion_id = authority.assertions[index].assertion_id,
      type = index == 1 and "expected-outcome" or "optional-diagnostic",
      required = authority.assertions[index].required,
      status = assertion_outcome[1],
      classification = assertion_outcome[2],
      observation_ids = { observation_id },
      evidence_refs = { { kind = "evidence", ref = evidence_id } },
    }
  end
  local case_result = {
    schema = results.schemas.case_result,
    case_id = "case-equivalent",
    repository = copy(repository),
    reviewed_case_id = authority.reviewed_case_id,
    plan_ref = copy(plan_ref),
    plan_sha256 = plan_sha256,
    execution_mode = route,
    execution_status = status,
    classification = outcome.classification,
    observations = { {
      schema = results.schemas.observation,
      observation_id = observation_id,
      kind = "route-observation",
      subject = "execution-route",
      value = route,
      source_ref = { kind = "runner", ref = route .. "/observation" },
      evidence_refs = { { kind = "evidence", ref = evidence_id } },
    } },
    assertions = assertions,
    evidence_refs = { { kind = "evidence", ref = evidence_id } },
    timing = {
      started_at = "2026-09-03T00:00:00Z",
      completed_at = "2026-09-03T00:00:01Z",
      duration_ms = 1000,
    },
    error = copy(outcome.error),
    non_execution_reason = outcome.non_execution_reason,
    trace_id = "trace-cross-route",
    dedup_key = "dedup-cross-route",
  }
  local manifest = {
    schema = evidence.schema,
    manifest_id = "cross-route-" .. route .. "-" .. status,
    canonicalization = evidence.canonicalization,
    canonical_sha256 = string.rep("0", 64),
    repository = copy(repository),
    run_id = run_id,
    plan_ref = copy(plan_ref),
    plan_sha256 = plan_sha256,
    entries = { {
      evidence_id = evidence_id,
      case_id = case_result.case_id,
      role = "sanitized-json",
      artifact_ref = { kind = "artifact", ref = artifact_ref },
      sha256 = artifact_sha256,
      media_type = "application/json",
      size_bytes = 64,
      producer = "cross-route-conformance." .. route,
      producer_version = "1",
      created_at = "2026-09-03T00:00:01Z",
      sensitivity = "internal",
      redaction_classification = "route-detail-only",
      policy_version = "cross-route-conformance.v1",
      policy_status = "redacted",
      provenance = { source_kind = "artifact", source_ref = artifact_ref, source_sha256 = artifact_sha256 },
    } },
  }
  manifest.canonical_sha256 = evidence.sha256(manifest, sha256, { artifact_root = root })
  local persisted_manifest_sha256 = sha256(evidence.serialize(manifest, { artifact_root = root }) .. "\n")
  local result_set = {
    schema = results.schemas.case_result_set,
    set_id = run_id,
    run_id = run_id,
    plan_ref = copy(plan_ref),
    plan_sha256 = plan_sha256,
    cases = { case_result },
    evidence_manifest_ref = {
      kind = "artifact", ref = root .. "/evidence-manifest.json", sha256 = persisted_manifest_sha256,
    },
    evidence_manifest_sha256 = manifest.canonical_sha256,
    evidence_manifest_artifact_sha256 = persisted_manifest_sha256,
    trace_id = case_result.trace_id,
    dedup_key = case_result.dedup_key,
  }
  results.validate_case_result_set(result_set, { authority }, manifest, sha256, { artifact_root = root })
  return result_set, manifest
end

local function semantic_view(result_set, manifest)
  local case_result = result_set.cases[1]
  local assertion_facts = {}
  for index, assertion in ipairs(case_result.assertions) do
    assertion_facts[index] = {
      assertion_id = assertion.assertion_id,
      type = assertion.type,
      required = assertion.required,
      status = assertion.status,
      classification = assertion.classification,
    }
  end
  return {
    run_id = result_set.run_id,
    plan_ref = copy(result_set.plan_ref),
    plan_sha256 = result_set.plan_sha256,
    repository = copy(case_result.repository),
    case_id = case_result.case_id,
    reviewed_case_id = case_result.reviewed_case_id,
    status = case_result.execution_status,
    classification = case_result.classification,
    assertions = assertion_facts,
    non_execution_reason = case_result.non_execution_reason,
    error = copy(case_result.error),
    evidence_ownership = {
      case_ref = copy(case_result.evidence_refs[1]),
      entry_id = manifest.entries[1].evidence_id,
      entry_case_id = manifest.entries[1].case_id,
      assertion_id = manifest.entries[1].assertion_id,
    },
  }
end

return {
  test_cli_http_and_browser_have_equal_canonical_semantics_for_all_terminal_classes = function()
    for status in pairs(outcomes) do
      local expected
      for _, route in ipairs({ "cli", "http", "browser" }) do
        local result_set, manifest = bundle(route, status)
        local actual = semantic_view(result_set, manifest)
        if expected == nil then expected = actual else t.is_true(structured.equal(expected, actual)) end
        t.eq(result_set.evidence_manifest_sha256, manifest.canonical_sha256)
        t.eq(result_set.evidence_manifest_ref.sha256, result_set.evidence_manifest_artifact_sha256)
        t.is_true(result_set.evidence_manifest_sha256 ~= result_set.evidence_manifest_artifact_sha256)
        t.eq(result_set.cases[1].observations[1].value, route)
        t.eq(manifest.entries[1].artifact_ref.ref,
          root .. "/evidence/" .. route .. "-observation.json")
      end
    end
  end,
}
