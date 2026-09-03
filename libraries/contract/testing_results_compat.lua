-- contract.testing_results_compat: bounded v1 projection for canonical testing results.
-- Context is closed: validate_v1 needs artifact_root/plan_sha256; canonicalize_v1
-- also needs repository, run_id, plan_ref, trace_id, dedup_key, sha256_bytes, and
-- ordered case_metadata entries containing timing plus one evidence descriptor.
local error_facts = require("contract.error_facts")
local strings = require("contract.strings")
local time = require("contract.time")
local structured = require("contract.structured_execution")
local results = require("contract.testing_results")
local manifests = require("contract.testing_evidence_manifest")

local C = {}
C.schema = "testing-structured-case-results.v1"

local status_pairs = {
  passed = { passed=true },
  failed = { ["product-defect"]=true },
  skipped = { ["data-fixture-gap"]=true, ["not-executed-risk"]=true },
  error = { ["environment-session-issue"]=true, ["harness-tooling-issue"]=true },
}
local canonical_outcomes = {
  passed = { status="passed", classification="deterministic" },
  failed = { status="failed", classification="assertion_failure" },
  skipped = { status="skipped", classification="not_applicable" },
  error = { status="error", classification="execution_error" },
}
local legacy_outcomes = {
  passed = { deterministic={status="passed",classification="passed"} },
  failed = { assertion_failure={status="failed",classification="product-defect"} },
  skipped = { skipped=true, not_applicable=true },
  error = { execution_error=true },
}

local function fail(classification, message)
  error(error_facts.error_message("contract.testing-results-compat", classification, message))
end
local function fields(value, allowed, label)
  if type(value) ~= "table" then fail("malformed-" .. label, label .. " must be a table") end
  for key in pairs(value) do if allowed[key] ~= true then fail("malformed-" .. label, "unsupported field " .. tostring(key)) end end
end
local function bounded(value, field, limit)
  if type(value) ~= "string" or value == "" or #value > (limit or 512) or value:find("[%z\1-\31\127]") ~= nil then fail("malformed-field", field .. " must be a bounded string") end
  return value
end
local function identifier(value, field)
  bounded(value, field, 180)
  if value:match("^[%w._%-]+$") == nil then fail("malformed-field", field .. " must be path-safe") end
  return value
end
local function digest(value, field)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then fail("malformed-digest", field .. " must be lowercase SHA-256") end
  return value
end
local function list(value, field, limit, required)
  if type(value) ~= "table" then fail("malformed-list", field .. " must be a list") end
  local count, highest = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then fail("malformed-list", field .. " must be dense") end
    count, highest = count + 1, math.max(highest, key)
  end
  if count ~= highest or count > limit or (required and count == 0) then fail("malformed-list", field .. " has an invalid size") end
  return value
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}; for key, item in pairs(value) do out[copy(key)] = copy(item) end; return out
end
local function reference(value, field)
  fields(value, {kind=true,ref=true}, field)
  bounded(value.kind, field .. ".kind", 96); bounded(value.ref, field .. ".ref", 4096)
  return value
end
local function same_reference(left, right)
  return left.kind == right.kind and left.ref == right.ref
end
local function repository(value)
  fields(value, {id=true,source_ref=true,source_sha256=true}, "context-repository")
  bounded(value.id, "context.repository.id", 180); reference(value.source_ref, "context.repository.source_ref"); digest(value.source_sha256, "context.repository.source_sha256")
  return value
end
local function timing(value)
  fields(value, {started_at=true,completed_at=true,duration_ms=true}, "context-timing")
  bounded(value.started_at, "context.timing.started_at", 40); bounded(value.completed_at, "context.timing.completed_at", 40)
  local started, completed = time.iso_timestamp_epoch_seconds(value.started_at), time.iso_timestamp_epoch_seconds(value.completed_at)
  if started == nil or completed == nil or completed < started then fail("malformed-time", "context timing must use ordered UTC timestamps") end
  if type(value.duration_ms) ~= "number" or value.duration_ms ~= math.floor(value.duration_ms) or value.duration_ms < 0 or value.duration_ms > 86400000 then fail("malformed-time", "context duration_ms is invalid") end
  return value
end
local function evidence_metadata(value, completed_at)
  fields(value, {evidence_id=true,role=true,sha256=true,media_type=true,size_bytes=true,producer=true,producer_version=true,created_at=true,sensitivity=true,redaction_classification=true,policy_version=true,policy_status=true,provenance=true}, "context-evidence")
  identifier(value.evidence_id, "context.evidence.evidence_id"); bounded(value.role, "context.evidence.role", 64); digest(value.sha256, "context.evidence.sha256"); bounded(value.media_type, "context.evidence.media_type", 120)
  if type(value.size_bytes) ~= "number" or value.size_bytes ~= math.floor(value.size_bytes) or value.size_bytes < 0 or value.size_bytes > 1000000000 then fail("malformed-field", "context evidence size_bytes is invalid") end
  bounded(value.producer, "context.evidence.producer", 180); bounded(value.producer_version, "context.evidence.producer_version", 96); bounded(value.created_at, "context.evidence.created_at", 40)
  if time.iso_timestamp_epoch_seconds(value.created_at) == nil or value.created_at ~= completed_at then fail("malformed-time", "context evidence created_at must equal case completion") end
  bounded(value.sensitivity, "context.evidence.sensitivity", 32); bounded(value.redaction_classification, "context.evidence.redaction_classification", 64); bounded(value.policy_version, "context.evidence.policy_version", 96); bounded(value.policy_status, "context.evidence.policy_status", 32)
  fields(value.provenance, {source_kind=true,source_ref=true,source_sha256=true}, "context-provenance")
  bounded(value.provenance.source_kind, "context.provenance.source_kind", 96); bounded(value.provenance.source_ref, "context.provenance.source_ref", 4096); digest(value.provenance.source_sha256, "context.provenance.source_sha256")
  return value
end
local context_fields = { artifact_root=true,plan_sha256=true,plan=true,repository=true,run_id=true,plan_ref=true,trace_id=true,dedup_key=true,case_metadata=true,sha256_bytes=true }
local function validate_context(context, mode, case_count)
  fields(context, context_fields, "context")
  if not strings.is_artifact_descendant(tostring(context.artifact_root or "") .. "/artifact", context.artifact_root) then fail("invalid-context", "artifact_root must be a safe .testing/runs/... root") end
  if mode ~= "project" or context.plan_sha256 ~= nil then digest(context.plan_sha256, "context.plan_sha256") end
  if context.plan ~= nil then structured.validate_plan(context.plan) end
  if mode == "validate" then
    if context.repository ~= nil then repository(context.repository) end
    if context.plan_ref ~= nil then reference(context.plan_ref, "context.plan_ref") end
    return context
  end
  if mode == "project" then
    if type(context.sha256_bytes) ~= "function" then fail("invalid-context", "sha256_bytes must be callable") end
    if context.plan == nil or context.plan_sha256 == nil or context.plan_ref == nil then fail("invalid-context", "immutable plan authority is required") end
    digest(context.plan_sha256, "context.plan_sha256"); reference(context.plan_ref, "context.plan_ref")
    if context.repository ~= nil then repository(context.repository) end
    if context.run_id ~= nil then
      bounded(context.run_id, "context.run_id", 180)
      if strings.artifact_run_id(context.artifact_root) ~= context.run_id then fail("foreign-run", "artifact root run differs from context run") end
    end
    if context.trace_id ~= nil then bounded(context.trace_id, "context.trace_id", 180) end
    if context.dedup_key ~= nil then bounded(context.dedup_key, "context.dedup_key", 180) end
    if context.case_metadata ~= nil then
      list(context.case_metadata, "context.case_metadata", 64, true)
      if case_count ~= nil and #context.case_metadata ~= case_count then fail("invalid-context", "case_metadata must align with canonical cases") end
      for _, metadata in ipairs(context.case_metadata) do
        fields(metadata, {case_id=true,timing=true,evidence=true,error_message=true}, "context-case-metadata")
        identifier(metadata.case_id, "context.case_metadata.case_id"); timing(metadata.timing); evidence_metadata(metadata.evidence, metadata.timing.completed_at)
        if metadata.error_message ~= nil then bounded(metadata.error_message, "context.case_metadata.error_message", 512) end
      end
    end
    return context
  end
  if context.plan == nil then fail("invalid-context", "immutable plan is required") end
  repository(context.repository); bounded(context.run_id, "context.run_id", 180); reference(context.plan_ref, "context.plan_ref")
  if strings.artifact_run_id(context.artifact_root) ~= context.run_id then fail("foreign-run", "artifact root run differs from context run") end
  if context.plan_ref.kind ~= "artifact" or context.plan_ref.ref ~= context.artifact_root .. "/test-plan.json" then fail("invalid-context", "plan_ref must identify the root test plan") end
  bounded(context.trace_id, "context.trace_id", 180); bounded(context.dedup_key, "context.dedup_key", 180)
  if type(context.sha256_bytes) ~= "function" then fail("invalid-context", "sha256_bytes must be callable") end
  list(context.case_metadata, "context.case_metadata", 64, true)
  if #context.case_metadata ~= case_count then fail("invalid-context", "case_metadata must align with v1 cases") end
  local evidence_ids = {}
  for _, metadata in ipairs(context.case_metadata) do
    fields(metadata, {case_id=true,timing=true,evidence=true,error_message=true}, "context-case-metadata")
    identifier(metadata.case_id, "context.case_metadata.case_id"); timing(metadata.timing); evidence_metadata(metadata.evidence, metadata.timing.completed_at)
    if metadata.error_message ~= nil then bounded(metadata.error_message, "context.case_metadata.error_message", 512) end
    if evidence_ids[metadata.evidence.evidence_id] then fail("duplicate-evidence-id", metadata.evidence.evidence_id) end
    evidence_ids[metadata.evidence.evidence_id] = true
  end
  return context
end

local function validate_plan_order(value, plan)
  if plan == nil then return end
  if #plan.cases ~= #value.cases then fail("foreign-plan", "v1 case count does not match the plan") end
  for index, case in ipairs(value.cases) do
    local planned = plan.cases[index]
    local planned_assertions = planned.kind == "browser" and planned.completion_assertions or planned.assertions
    if case.case_id ~= planned.case_id or case.kind ~= planned.kind then fail("foreign-plan", "v1 case order or kind does not match the plan") end
    if #case.assertions ~= 0 or (case.status ~= "skipped" and case.status ~= "error") then
      if #case.assertions ~= #planned_assertions then fail("foreign-plan", "v1 assertion count does not match the plan") end
      for assertion_index, assertion in ipairs(case.assertions) do
        if assertion.type ~= planned_assertions[assertion_index].type then fail("foreign-plan", "v1 assertion order or type does not match the plan") end
      end
    end
  end
end

function C.validate_v1(value, context)
  validate_context(context, "validate")
  fields(value, {schema=true,plan_sha256=true,cases=true}, "v1-results")
  if value.schema ~= C.schema then fail("unknown-schema", "v1 result schema is unsupported") end
  digest(value.plan_sha256, "plan_sha256"); if value.plan_sha256 ~= context.plan_sha256 then fail("foreign-plan", "v1 plan digest does not match context") end
  list(value.cases, "cases", 64, true); local seen = {}
  for _, case in ipairs(value.cases) do
    fields(case, {case_id=true,kind=true,status=true,classification=true,assertions=true,evidence_ref=true}, "v1-case")
    identifier(case.case_id, "case_id"); if seen[case.case_id] then fail("duplicate-case", case.case_id) end; seen[case.case_id] = true
    if case.kind ~= "cli" and case.kind ~= "http" and case.kind ~= "browser" then fail("unsupported-kind", tostring(case.kind)) end
    bounded(case.status, "status", 32); bounded(case.classification, "classification", 64)
    if not status_pairs[case.status] or not status_pairs[case.status][case.classification] then fail("contradictory-status", "v1 status and classification disagree") end
    list(case.assertions, "assertions", 32, false); local passed, failed = 0, 0
    for _, assertion in ipairs(case.assertions) do
      fields(assertion, {type=true,passed=true}, "v1-assertion"); bounded(assertion.type, "assertion.type", 96)
      if type(assertion.passed) ~= "boolean" then fail("malformed-field", "assertion.passed must be boolean") end
      if assertion.passed then passed = passed + 1 else failed = failed + 1 end
    end
    if case.status == "passed" and (passed == 0 or failed ~= 0) then fail("contradictory-status", "passed requires every present assertion to pass") end
    if case.status == "failed" and failed == 0 then fail("contradictory-status", "failed requires a false assertion") end
    if (case.status == "skipped" or case.status == "error") and #case.assertions ~= 0 then
      fail("contradictory-status", "historical non-executed cases require empty assertions")
    end
    if not strings.is_artifact_descendant(case.evidence_ref, context.artifact_root) then fail("cross-run-pointer", "evidence_ref is outside the artifact root") end
  end
  validate_plan_order(value, context.plan)
  return value
end

local function assertion_result(assertion, index, case_status)
  local status = assertion.passed and "passed" or "failed"
  if case_status == "skipped" or case_status == "error" then status = "skipped" end
  return {
    schema=results.schemas.assertion_result, assertion_id="assertion-" .. index, type=assertion.type, required=true,
    status=status, classification=status == "passed" and "deterministic" or status == "failed" and "assertion_failure" or "skipped",
    observation_ids={}, evidence_refs={},
  }
end

function C.canonicalize_v1(value, context)
  C.validate_v1(value, context); validate_context(context, "canonicalize", #value.cases)
  local cases, entries = {}, {}
  for index, legacy in ipairs(value.cases) do
    local metadata = context.case_metadata[index]
    local planned_case = context.plan.cases[index]
    if metadata.case_id ~= legacy.case_id then fail("invalid-context", "case_metadata order does not match v1 cases") end
    local assertions = {}
    for assertion_index, planned in ipairs(planned_case.assertions) do
      local assertion = legacy.assertions[assertion_index]
      if legacy.status == "skipped" or legacy.status == "error" then
        assertion = { type=planned.type, passed=false }
      end
      table.insert(assertions, assertion_result(assertion, assertion_index, legacy.status))
    end
    local outcome = canonical_outcomes[legacy.status]
    local case = {
      schema=results.schemas.case_result, case_id=legacy.case_id, repository=copy(context.repository), reviewed_case_id=legacy.case_id,
      plan_ref=copy(context.plan_ref), plan_sha256=context.plan_sha256, execution_mode=legacy.kind, execution_status=outcome.status,
      classification=outcome.classification, observations={}, assertions=assertions,
      evidence_refs={{kind="evidence",ref=metadata.evidence.evidence_id}}, timing=copy(metadata.timing), trace_id=context.trace_id, dedup_key=context.dedup_key,
    }
    if legacy.status == "skipped" then case.non_execution_reason = legacy.classification end
    if legacy.status == "error" then case.error = {code=legacy.classification,message=metadata.error_message or "structured case execution error"} end
    table.insert(cases, case)
    local evidence = metadata.evidence
    table.insert(entries, {
      evidence_id=evidence.evidence_id, case_id=legacy.case_id, role=evidence.role, artifact_ref={kind="artifact",ref=legacy.evidence_ref},
      sha256=evidence.sha256, media_type=evidence.media_type, size_bytes=evidence.size_bytes, producer=evidence.producer,
      producer_version=evidence.producer_version, created_at=evidence.created_at, sensitivity=evidence.sensitivity,
      redaction_classification=evidence.redaction_classification, policy_version=evidence.policy_version, policy_status=evidence.policy_status,
      provenance=copy(evidence.provenance),
    })
  end
  local manifest = {
    schema=manifests.schema, manifest_id=context.run_id, canonicalization=manifests.canonicalization, canonical_sha256=string.rep("0", 64),
    repository=copy(context.repository), run_id=context.run_id, plan_ref=copy(context.plan_ref), plan_sha256=context.plan_sha256, entries=entries,
  }
  local root_context = {artifact_root=context.artifact_root}
  manifest.canonical_sha256 = manifests.sha256(manifest, context.sha256_bytes, root_context)
  local result_set = {
    schema=results.schemas.case_result_set, set_id=context.run_id, run_id=context.run_id, plan_ref=copy(context.plan_ref), plan_sha256=context.plan_sha256,
    cases=cases, evidence_manifest_ref={kind="artifact",ref=context.artifact_root .. "/evidence-manifest.json"},
    evidence_manifest_sha256=manifest.canonical_sha256, trace_id=context.trace_id, dedup_key=context.dedup_key,
  }
  local authorities = results.plan_assertion_authorities(context.plan, context.plan_ref, context.plan_sha256)
  results.validate_case_result_set(result_set, authorities, manifest, context.sha256_bytes, root_context)
  return {result_set=result_set,evidence_manifest=manifest}
end

local function bind_optional_context(result_set, context)
  if context.plan_sha256 ~= nil and result_set.plan_sha256 ~= context.plan_sha256 then fail("foreign-plan", "canonical plan digest does not match context") end
  if context.run_id ~= nil and result_set.run_id ~= context.run_id then fail("foreign-run", "canonical run does not match context") end
  if context.plan_ref ~= nil and not same_reference(result_set.plan_ref, context.plan_ref) then fail("foreign-plan", "canonical plan reference does not match context") end
  if context.trace_id ~= nil and result_set.trace_id ~= context.trace_id then fail("foreign-correlation", "canonical trace does not match context") end
  if context.dedup_key ~= nil and result_set.dedup_key ~= context.dedup_key then fail("foreign-correlation", "canonical dedup key does not match context") end
  if context.repository ~= nil then
    repository(context.repository); local actual = result_set.cases[1].repository
    if actual.id ~= context.repository.id or actual.source_sha256 ~= context.repository.source_sha256 or not same_reference(actual.source_ref, context.repository.source_ref) then fail("foreign-repository", "canonical repository does not match context") end
  end
end

function C.projection_supported(result_set)
  if type(result_set) ~= "table" or type(result_set.cases) ~= "table" then return false end
  for _, case in ipairs(result_set.cases) do
    if type(case) ~= "table" or legacy_outcomes[case.execution_status] == nil then return false end
  end
  return true
end

function C.project_v1(result_set, manifest, context)
  validate_context(context, "project", type(result_set) == "table" and type(result_set.cases) == "table" and #result_set.cases or nil)
  local root_context = {artifact_root=context.artifact_root}
  local authorities = results.plan_assertion_authorities(context.plan, context.plan_ref, context.plan_sha256)
  results.validate_case_result_set(result_set, authorities, manifest, context.sha256_bytes, root_context); bind_optional_context(result_set, context)
  local entries = {}; for _, entry in ipairs(manifest.entries) do entries[entry.evidence_id] = entry end
  local cases = {}
  for _, case in ipairs(result_set.cases) do
    local mapping = legacy_outcomes[case.execution_status]
    if mapping == nil then fail("unsupported-status", "canonical status cannot project to v1") end
    local status, classification
    if case.execution_status == "skipped" then
      if mapping[case.classification] ~= true then fail("contradictory-status", "canonical skipped outcome cannot project to v1") end
      status = "skipped"
      classification = status_pairs.skipped[case.non_execution_reason]
        and case.non_execution_reason or "not-executed-risk"
    elseif case.execution_status == "error" then
      if mapping[case.classification] ~= true then fail("contradictory-status", "canonical error outcome cannot project to v1") end
      status = "error"
      classification = status_pairs.error[case.error.code]
        and case.error.code or "harness-tooling-issue"
    else
      local outcome = mapping[case.classification]
      if outcome == nil then fail("contradictory-status", "canonical outcome cannot project to v1") end
      status, classification = outcome.status, outcome.classification
    end
    if #case.evidence_refs ~= 1 or case.evidence_refs[1].kind ~= "evidence" then fail("ambiguous-evidence", "v1 projection requires one evidence reference per case") end
    local entry = entries[case.evidence_refs[1].ref]
    if entry == nil or entry.case_id ~= case.case_id then fail("foreign-evidence", "case evidence does not resolve to its manifest entry") end
    local assertions = {}
    if case.execution_status ~= "skipped" and case.execution_status ~= "error" then
      for _, assertion in ipairs(case.assertions) do
        table.insert(assertions, {type=assertion.type,passed=assertion.status == "passed"})
      end
    end
    table.insert(cases, {case_id=case.case_id,kind=case.execution_mode,status=status,classification=classification,assertions=assertions,evidence_ref=entry.artifact_ref.ref})
  end
  local value = {schema=C.schema,plan_sha256=result_set.plan_sha256,cases=cases}
  C.validate_v1(value, {artifact_root=context.artifact_root,plan_sha256=result_set.plan_sha256,plan=context.plan})
  return value
end

return C
