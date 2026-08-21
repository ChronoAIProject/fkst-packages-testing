local contract = require("contract.testing_package_executor")
local package_manifest = require("contract.testing_package_manifest")
local results = require("contract.testing_results")
local time = require("contract.time")

local M = {}

local function fail(classification, message)
  error("testing-package-executor: " .. classification .. ": " .. message)
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

local function copy_identity(value)
  return {
    schema = value.schema,
    package_id = value.package_id,
    package_version = value.package_version,
    package_content_sha256 = value.package_content_sha256,
    manifest_digest = value.manifest_digest,
    entrypoint = value.entrypoint,
    contract_major = value.contract_major,
  }
end

local function copy_refs(value)
  local copied = {}
  for _, field in ipairs(contract.reference_order) do copied[field] = copy_reference(value[field]) end
  return copied
end

local function exact_capabilities(value)
  return type(value) == "table" and #value == 1 and value[1] == contract.capability
end

local function load_document(request, ports, field, validator)
  local reference = request.approved_input_refs[field]
  local bytes = call_port(ports, "load_immutable", reference)
  if type(bytes) ~= "string" or bytes == "" then fail("immutable-load-failed", field .. " did not return exact bytes") end
  local computed = call_port(ports, "sha256", bytes)
  if type(computed) ~= "string" or computed:match("^[0-9a-f]+$") == nil or #computed ~= 64 then
    fail("sha256-failed", field .. " SHA-256 result is malformed")
  end
  if computed ~= reference.sha256 then fail("digest-mismatch", field .. " stored bytes do not match the approved digest") end
  local decoded = call_port(ports, "decode_json", bytes)
  if type(decoded) ~= "table" then fail("decode-failed", field .. " did not decode to an object") end
  validator(decoded)
  return decoded
end

local function validate_mapping(request, manifest, policy, capability_set)
  if request.execution_profile ~= contract.profile
    or request.executor.package_id ~= contract.package_id
    or request.executor.package_version ~= "1.0.0"
    or request.executor.entrypoint ~= contract.entrypoint
    or request.executor.contract_major ~= contract.contract_major then
    fail("unsupported-mapping", "request does not match browser-deterministic.v1")
  end
  if manifest.package_id ~= request.executor.package_id
    or manifest.package_version ~= request.executor.package_version
    or manifest.package_content_sha256 ~= request.executor.package_content_sha256
    or manifest.manifest_digest ~= request.executor.manifest_digest then
    fail("identity-mismatch", "verified manifest does not match executor identity")
  end
  if not exact_capabilities(manifest.semantic_capabilities) then
    fail("capability-mismatch", "manifest semantic capabilities do not match the execution profile")
  end
  if policy.execution_profile ~= contract.profile
    or policy.authorized_entrypoint ~= contract.entrypoint
    or not exact_capabilities(policy.allowed_capabilities)
    or not exact_capabilities(capability_set.capabilities) then
    fail("policy-mismatch", "verified policy or capability set does not match the execution profile")
  end

  local selected, matches = nil, 0
  for _, entrypoint in ipairs(manifest.entrypoints) do
    if entrypoint.name == contract.entrypoint
      and entrypoint.contract_major == contract.contract_major
      and exact_capabilities(entrypoint.capabilities) then
      selected = entrypoint
      matches = matches + 1
    end
  end
  if matches ~= 1 then fail("entrypoint-mismatch", "manifest must contain exactly one authorized matching entrypoint") end
  return selected
end

function M.resolve(request, ports)
  contract.validate_request(request)
  callable_ports(ports, { "load_immutable", "sha256", "decode_json" }, "resolve")

  local documents = {}
  documents.package_manifest_ref = load_document(request, ports, "package_manifest_ref", function(value)
    package_manifest.validate(value, {
      package_id = request.executor.package_id,
      package_version = request.executor.package_version,
      package_content_sha256 = request.executor.package_content_sha256,
      entrypoint = request.executor.entrypoint,
      contract_major = request.executor.contract_major,
      capability = contract.capability,
    }, ports.sha256)
  end)
  documents.source_ref = load_document(request, ports, "source_ref", contract.validate_source)
  documents.plan_ref = load_document(request, ports, "plan_ref", contract.validate_plan)
  documents.pql_input_ref = load_document(request, ports, "pql_input_ref", contract.validate_pql_input)
  documents.policy_ref = load_document(request, ports, "policy_ref", contract.validate_policy)
  documents.capability_set_ref = load_document(request, ports, "capability_set_ref", contract.validate_capability_set)

  local selected = validate_mapping(
    request,
    documents.package_manifest_ref,
    documents.policy_ref,
    documents.capability_set_ref
  )
  local resolved = {
    schema = contract.schemas.resolved_invocation,
    executor = copy_identity(request.executor),
    execution_profile = request.execution_profile,
    approved_input_refs = copy_refs(request.approved_input_refs),
    source = {
      schema = documents.source_ref.schema,
      source_id = documents.source_ref.source_id,
      target_url = documents.source_ref.target_url,
    },
    plan = {
      schema = documents.plan_ref.schema,
      case_id = documents.plan_ref.case_id,
      assertion = {
        assertion_id = documents.plan_ref.assertion.assertion_id,
        expected = documents.plan_ref.assertion.expected,
        required = documents.plan_ref.assertion.required,
        type = documents.plan_ref.assertion.type,
      },
    },
    pql_input = {
      schema = documents.pql_input_ref.schema,
      requirement_id = documents.pql_input_ref.requirement_id,
    },
    selected_entrypoint = {
      name = selected.name,
      contract_major = selected.contract_major,
      capabilities = { selected.capabilities[1] },
    },
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  contract.validate_resolved_invocation(resolved)
  return resolved
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
    observations = {
      {
        schema = results.schemas.observation,
        observation_id = contract.observation_id,
        kind = "browser-title",
        subject = resolved.source.target_url,
        value = receipt.observed_title,
        source_ref = { kind = "effect-receipt", ref = receipt.effect_id },
        evidence_refs = {},
      },
    },
    assertions = {
      {
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
  contract.validate_resolved_invocation(resolved)
  callable_ports(ports, { "check_freshness", "browser_read_title", "write_canonical", "now", "sha256" }, "execute")

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
