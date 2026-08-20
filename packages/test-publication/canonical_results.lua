local results = require("contract.testing_results")
local strings = require("contract.strings")

local C = {}

local function fail(message)
  error("test-publication: canonical-results: " .. message)
end

local function digest(value)
  if type(value) ~= "string" or #value ~= 64 then return false end
  return value:match("^[0-9a-f][0-9a-f]*$") ~= nil
end

local function same_reference(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.kind == right.kind and left.ref == right.ref
end

local function same_repository(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.id == right.id and left.source_sha256 == right.source_sha256
    and same_reference(left.source_ref, right.source_ref)
end

function C.validate(result_set, manifest, options)
  if type(options) ~= "table" or type(options.sha256_bytes) ~= "function"
    or type(options.plan) ~= "table" or type(options.repository) ~= "table" then
    fail("complete validation context is required")
  end
  if strings.artifact_run_id(options.artifact_root) ~= options.run_id then
    fail("artifact root run differs from the authoritative run")
  end
  if result_set.run_id ~= options.run_id or result_set.set_id ~= options.run_id then
    fail("result set run identity differs")
  end
  if not same_reference(result_set.plan_ref, options.plan_ref)
    or result_set.plan_sha256 ~= options.plan_sha256 then
    fail("result set plan identity differs")
  end
  if result_set.trace_id ~= options.trace_id or result_set.dedup_key ~= options.dedup_key then
    fail("result set correlation differs")
  end
  if result_set.evidence_manifest_artifact_sha256 ~= options.evidence_manifest_artifact_sha256
    or not digest(result_set.evidence_manifest_artifact_sha256) then
    fail("persisted manifest digest differs")
  end
  if not same_reference(result_set.evidence_manifest_ref, {
    kind = "artifact", ref = options.evidence_manifest_ref,
  }) then
    fail("manifest reference differs")
  end
  if result_set.evidence_manifest_ref.sha256 ~= nil
    and result_set.evidence_manifest_ref.sha256 ~= options.evidence_manifest_artifact_sha256 then
    fail("manifest reference digest differs")
  end

  local authorities = results.plan_assertion_authorities(
    options.plan, options.plan_ref, options.plan_sha256)
  results.validate_case_result_set(result_set, authorities, manifest,
    options.sha256_bytes, { artifact_root = options.artifact_root })

  if #result_set.cases ~= #options.plan.cases then fail("result set case count differs from plan") end
  if options.plan.execution_mode == "structured-api-cli" and #manifest.entries ~= #result_set.cases then
    fail("structured CLI/HTTP publication requires exactly one manifest entry per case")
  end
  local entries = {}
  for _, entry in ipairs(manifest.entries) do entries[entry.evidence_id] = entry end
  local view = { canonical = true, cases = {} }
  for index, case in ipairs(result_set.cases) do
    if not same_repository(case.repository, options.repository) then
      fail("result set repository differs")
    end
    if #case.evidence_refs ~= 1 or case.evidence_refs[1].kind ~= "evidence" then
      fail("each canonical case must reference exactly one evidence entry")
    end
    local entry = entries[case.evidence_refs[1].ref]
    view.cases[index] = {
      case_id = case.case_id,
      kind = case.execution_mode,
      status = case.execution_status,
      classification = case.classification,
      assertions = case.assertions,
      evidence_ref = entry.artifact_ref.ref,
    }
  end
  return view
end

function C.is_product_defect(view, case)
  if view.canonical then
    return case.status == "failed" and case.classification == "assertion_failure"
  end
  return case.classification == "product-defect"
end

function C.assertion_failed(view, assertion)
  if view.canonical then return assertion.status == "failed" end
  return assertion.passed == false
end

return C
