local contract = require("contract.testing_package_executor")
local evidence = require("contract.testing_evidence_manifest")
local error_facts = require("contract.error_facts")
local results = require("contract.testing_results")
local time = require("contract.time")

local M = {}

local function fail(classification, message)
  error(error_facts.error_message("testing-package-executor", classification, message))
end

local function callable_ports(ports, names, context)
  if type(ports) ~= "table" then fail("missing-ports", context .. " ports must be a table") end
  for _, name in ipairs(names) do
    if type(ports[name]) ~= "function" then fail("missing-port", name .. " must be callable") end
  end
end

local function call_port(ports, name, value)
  local ok, result = pcall(ports[name], value)
  if not ok then fail("port-failed", name .. " failed: " .. tostring(result)) end
  return result
end

local function equal(left, right, seen)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  seen = seen or {}
  if seen[left] == right then return true end
  seen[left] = right
  for key, value in pairs(left) do if not equal(value, right[key], seen) then return false end end
  for key in pairs(right) do if left[key] == nil then return false end end
  return true
end

local function copy_reference(value, digest)
  local result = { kind = value.kind, ref = value.ref }
  if digest ~= false and value.sha256 ~= nil then result.sha256 = value.sha256 end
  return result
end

local function sha256(ports, bytes, field)
  local value = call_port(ports, "sha256", bytes)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
    fail("sha256-failed", field .. " SHA-256 is malformed")
  end
  return value
end

local function timestamp(ports)
  local value = call_port(ports, "now")
  if type(value) ~= "string" or time.iso_timestamp_epoch_seconds(value) == nil then
    fail("clock-failed", "now must return a UTC timestamp")
  end
  return value
end

local function authority(resolved)
  local plan_ref = resolved.approved_input_refs.plan_ref
  return {
    plan_ref = copy_reference(plan_ref),
    plan_sha256 = plan_ref.sha256,
    reviewed_case_id = resolved.plan.case_id,
    assertions = { { assertion_id = resolved.plan.assertion.assertion_id, required = resolved.plan.assertion.required } },
  }
end

local function case_result(resolved, receipt, started_at, completed_at)
  if receipt.observed_title ~= resolved.plan.assertion.expected then fail("assertion-failed", "unequal title is outside this walking skeleton") end
  local source_ref = resolved.approved_input_refs.source_ref
  local plan_ref = resolved.approved_input_refs.plan_ref
  local evidence_ref = { kind = "evidence", ref = contract.evidence_id }
  local value = {
    schema = results.schemas.case_result,
    case_id = contract.case_id,
    repository = { id = resolved.source.source_id, source_ref = copy_reference(source_ref), source_sha256 = source_ref.sha256 },
    reviewed_case_id = contract.case_id,
    asset_ref = copy_reference(source_ref),
    requirement_ref = { kind = "pql", ref = resolved.pql_input.requirement_id },
    plan_ref = copy_reference(plan_ref), plan_sha256 = plan_ref.sha256,
    execution_mode = "browser", execution_status = "passed", classification = "deterministic",
    observations = { {
      schema = results.schemas.observation, observation_id = contract.observation_id, kind = "browser-title",
      subject = contract.target_url, value = receipt.observed_title,
      source_ref = { kind = "effect-receipt", ref = contract.effect_id }, evidence_refs = { evidence_ref },
    } },
    assertions = { {
      schema = results.schemas.assertion_result, assertion_id = contract.assertion_id, type = "title-equals",
      required = true, status = "passed", classification = "deterministic",
      observation_ids = { contract.observation_id }, evidence_refs = { evidence_ref },
    } },
    evidence_refs = { evidence_ref },
    timing = { started_at = started_at, completed_at = completed_at,
      duration_ms = (time.iso_timestamp_epoch_seconds(completed_at) - time.iso_timestamp_epoch_seconds(started_at)) * 1000 },
    trace_id = resolved.trace_id, dedup_key = resolved.dedup_key,
  }
  results.validate_case_result(value, authority(resolved))
  return value
end

local function evidence_manifest(resolved, receipt, completed_at, ports)
  local source_ref = resolved.approved_input_refs.source_ref
  local plan_ref = resolved.approved_input_refs.plan_ref
  local artifact = receipt.evidence_refs[1]
  local value = {
    schema = evidence.schema, manifest_id = resolved.dedup_key, canonicalization = evidence.canonicalization,
    canonical_sha256 = string.rep("0", 64),
    repository = { id = resolved.source.source_id, source_ref = copy_reference(source_ref, false), source_sha256 = source_ref.sha256 },
    run_id = resolved.dedup_key, plan_ref = copy_reference(plan_ref, false), plan_sha256 = plan_ref.sha256,
    entries = { {
      evidence_id = contract.evidence_id, case_id = contract.case_id, assertion_id = contract.assertion_id,
      role = "sanitized-json", artifact_ref = { kind = artifact.kind, ref = artifact.ref }, sha256 = artifact.sha256,
      media_type = "application/json", size_bytes = receipt.evidence_size_bytes,
      producer = contract.executor_id, producer_version = "1.0.0", created_at = completed_at,
      sensitivity = "internal", redaction_classification = "none", policy_version = "browser-title.v1", policy_status = "approved",
      provenance = { source_kind = "artifact", source_ref = artifact.ref, source_sha256 = artifact.sha256 },
    } },
  }
  value.canonical_sha256 = evidence.sha256(value, ports.sha256)
  evidence.validate(value, nil, ports.sha256)
  return value
end

local function write_artifact(resolved, ports, kind, value, manifest)
  local bytes = kind == "evidence-manifest" and evidence.canonicalize(value) or results.canonicalize(value, manifest, ports.sha256)
  local request = { schema = contract.schemas.canonical_write, kind = kind, dedup_key = resolved.dedup_key,
    canonical_sha256 = sha256(ports, bytes, kind), canonical_bytes = bytes }
  contract.validate_canonical_write(request)
  local receipt = call_port(ports, "write_canonical", request)
  contract.validate_write_receipt(receipt)
  local expected = ".testing/runs/" .. resolved.dedup_key .. "/" .. (kind == "evidence-manifest" and "evidence-manifest.json" or "case-result-set.json")
  if receipt.ref.ref ~= expected then fail("cross-run-pointer", "writer returned the wrong artifact path") end
  return request, receipt
end

local function validate_completed(value, resolved)
  contract.validate_completed_execution(value, resolved.dedup_key, resolved.admission_digest)
  local root = ".testing/runs/" .. resolved.dedup_key
  if value.evidence_manifest_ref.ref ~= root .. "/evidence-manifest.json"
    or value.case_result_set_ref.ref ~= root .. "/case-result-set.json" then
    fail("cross-run-pointer", "completed receipt artifacts are outside the execution root")
  end
  return value
end

function M.execute(resolved, ports)
  callable_ports(ports, { "load_completed_execution", "claim_execution", "check_freshness", "persist_effect_intent",
    "browser_read_title", "persist_effect_receipt", "write_canonical", "complete_execution", "now", "sha256" }, "execute")
  contract.validate_resolved_invocation(resolved, ports.sha256)

  local query = { schema = contract.schemas.completed_execution_query, dedup_key = resolved.dedup_key, admission_digest = resolved.admission_digest }
  contract.validate_completed_execution_query(query)
  local completed = call_port(ports, "load_completed_execution", query)
  if completed ~= nil then return validate_completed(completed, resolved) end

  local claim_request = { schema = contract.schemas.execution_claim_request, dedup_key = resolved.dedup_key, admission_digest = resolved.admission_digest }
  contract.validate_execution_claim_request(claim_request)
  local claim = call_port(ports, "claim_execution", claim_request)
  contract.validate_execution_claim_receipt(claim, claim_request)

  local freshness = { schema = contract.schemas.freshness_check, dedup_key = resolved.dedup_key, effect_id = contract.effect_id }
  contract.validate_freshness_check(freshness)
  if call_port(ports, "check_freshness", freshness) ~= true then fail("freshness-denied", "freshness check did not authorize the Browser effect") end

  local started_at = timestamp(ports)
  local intent = { schema = contract.schemas.effect_intent, dedup_key = resolved.dedup_key, admission_digest = resolved.admission_digest,
    claim_id = claim.claim_id, effect_id = contract.effect_id, url = contract.target_url }
  contract.validate_effect_intent(intent)
  if call_port(ports, "persist_effect_intent", intent) ~= true then fail("intent-persist-failed", "effect intent was not persisted") end

  local effect_request = { schema = contract.schemas.browser_read_title, effect_id = contract.effect_id, url = contract.target_url }
  contract.validate_browser_read_title(effect_request)
  local effect_receipt = call_port(ports, "browser_read_title", effect_request)
  contract.validate_effect_receipt(effect_receipt)
  if call_port(ports, "persist_effect_receipt", effect_receipt) ~= true then fail("receipt-persist-failed", "effect receipt was not persisted") end
  local completed_at = timestamp(ports)

  local case = case_result(resolved, effect_receipt, started_at, completed_at)
  local manifest = evidence_manifest(resolved, effect_receipt, completed_at, ports)
  local manifest_request, manifest_receipt = write_artifact(resolved, ports, "evidence-manifest", manifest)
  local result_set = {
    schema = results.schemas.case_result_set, set_id = resolved.dedup_key, run_id = resolved.dedup_key,
    plan_ref = copy_reference(resolved.approved_input_refs.plan_ref), plan_sha256 = resolved.approved_input_refs.plan_ref.sha256,
    cases = { case }, evidence_manifest_ref = copy_reference(manifest_receipt.ref),
    evidence_manifest_sha256 = manifest.canonical_sha256, evidence_manifest_artifact_sha256 = manifest_receipt.ref.sha256,
    trace_id = resolved.trace_id, dedup_key = resolved.dedup_key,
  }
  results.validate_case_result_set(result_set, { authority(resolved) }, manifest, ports.sha256)
  local result_request, result_receipt = write_artifact(resolved, ports, "case-result-set", result_set, manifest)

  local terminal = { schema = contract.schemas.completed_execution, status = "completed", dedup_key = resolved.dedup_key,
    admission_digest = resolved.admission_digest, claim_id = claim.claim_id, effect_id = contract.effect_id,
    case_result_set_ref = copy_reference(result_receipt.ref), case_result_set_sha256 = result_request.canonical_sha256,
    evidence_manifest_ref = copy_reference(manifest_receipt.ref), evidence_manifest_sha256 = manifest_request.canonical_sha256 }
  contract.validate_completed_execution(terminal, resolved.dedup_key, resolved.admission_digest)
  local stored = call_port(ports, "complete_execution", terminal)
  if type(stored) ~= "table" then fail("completion-failed", "completion did not return a receipt") end
  validate_completed(stored, resolved)
  if not equal(stored, terminal) then fail("completion-mismatch", "completion receipt changed") end
  return stored
end

return M
