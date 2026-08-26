local contract = require("contract.testing_package_executor")
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

local function copy_reference(value)
  return { kind = value.kind, ref = value.ref, sha256 = value.sha256 }
end

local function timestamp(ports)
  local value = call_port(ports, "now")
  if type(value) ~= "string" or time.iso_timestamp_epoch_seconds(value) == nil then
    fail("clock-failed", "now must return a UTC timestamp")
  end
  return value
end

local function case_result(resolved, receipt, started_at, completed_at)
  local passed = receipt.observed_title == resolved.plan.assertion.expected
  local source_ref = resolved.approved_input_refs.source_ref
  local plan_ref = resolved.approved_input_refs.plan_ref
  local result = {
    schema = results.schemas.case_result,
    case_id = resolved.plan.case_id,
    repository = {
      id = resolved.source.source_id,
      source_ref = copy_reference(source_ref),
      source_sha256 = source_ref.sha256,
    },
    reviewed_case_id = resolved.plan.case_id,
    asset_ref = copy_reference(source_ref),
    requirement_ref = { kind = "pql", ref = resolved.pql_input.requirement_id },
    plan_ref = copy_reference(plan_ref),
    plan_sha256 = plan_ref.sha256,
    execution_mode = "browser",
    execution_status = passed and "passed" or "failed",
    classification = passed and "deterministic" or "assertion_failure",
    observations = { {
        schema = results.schemas.observation,
        observation_id = contract.observation_id,
        kind = "browser-title",
        subject = resolved.source.target_url,
        value = receipt.observed_title,
        source_ref = { kind = "effect-receipt", ref = receipt.effect_id },
        evidence_refs = {},
      },
    },
    assertions = { {
        schema = results.schemas.assertion_result,
        assertion_id = resolved.plan.assertion.assertion_id,
        type = resolved.plan.assertion.type,
        required = resolved.plan.assertion.required,
        status = passed and "passed" or "failed",
        classification = passed and "deterministic" or "assertion_failure",
        observation_ids = { contract.observation_id },
        evidence_refs = {},
      },
    },
    evidence_refs = {},
    timing = {
      started_at = started_at,
      completed_at = completed_at,
      duration_ms = (time.iso_timestamp_epoch_seconds(completed_at) - time.iso_timestamp_epoch_seconds(started_at)) * 1000,
    },
    trace_id = resolved.trace_id,
    dedup_key = resolved.dedup_key,
  }
  local authority = {
    plan_ref = copy_reference(plan_ref),
    plan_sha256 = plan_ref.sha256,
    reviewed_case_id = resolved.plan.case_id,
    assertions = {
      { assertion_id = resolved.plan.assertion.assertion_id, required = resolved.plan.assertion.required },
    },
  }
  results.validate_case_result(result, authority)
  return result
end

function M.execute(resolved, ports)
  callable_ports(ports, { "check_freshness", "browser_read_title", "write_canonical", "now", "sha256" }, "execute")
  contract.validate_resolved_invocation(resolved, ports.sha256)

  local started_at = timestamp(ports)
  local freshness = {
    schema = contract.schemas.freshness_check,
    dedup_key = resolved.dedup_key,
    effect_id = contract.effect_id,
  }
  contract.validate_freshness_check(freshness)
  if call_port(ports, "check_freshness", freshness) ~= true then
    fail("freshness-denied", "freshness check did not authorize the Browser effect")
  end

  local effect_request = {
    schema = contract.schemas.browser_read_title,
    effect_id = contract.effect_id,
    url = resolved.source.target_url,
  }
  contract.validate_browser_read_title(effect_request)
  local effect_receipt = call_port(ports, "browser_read_title", effect_request)
  contract.validate_effect_receipt(effect_receipt)
  local completed_at = timestamp(ports)

  local result = case_result(resolved, effect_receipt, started_at, completed_at)
  local canonical_bytes = results.canonicalize(result)
  local canonical_sha256 = call_port(ports, "sha256", canonical_bytes)
  if type(canonical_sha256) ~= "string" or canonical_sha256:match("^[0-9a-f]+$") == nil or #canonical_sha256 ~= 64 then
    fail("sha256-failed", "canonical result SHA-256 is malformed")
  end
  local write_request = {
    schema = contract.schemas.canonical_write,
    kind = "case-result",
    dedup_key = resolved.dedup_key,
    canonical_sha256 = canonical_sha256,
    canonical_bytes = canonical_bytes,
  }
  contract.validate_canonical_write(write_request)
  local write_receipt = call_port(ports, "write_canonical", write_request)
  contract.validate_write_receipt(write_receipt)
  if write_receipt.ref.sha256 ~= canonical_sha256 then fail("digest-mismatch", "writer receipt does not bind canonical bytes") end

  local execution = {
    schema = contract.schemas.execution,
    case_result = result,
    effect_receipt = {
      schema = effect_receipt.schema,
      effect_id = effect_receipt.effect_id,
      status = effect_receipt.status,
      observed_title = effect_receipt.observed_title,
      evidence_refs = {},
    },
    case_result_ref = copy_reference(write_receipt.ref),
  }
  contract.validate_execution(execution)
  return execution
end

return M
