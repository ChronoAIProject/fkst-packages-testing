local canonical_json = require("contract.canonical_json")
local contract = require("contract.testing_package_executor")
local error_facts = require("contract.error_facts")
local package_manifest = require("contract.testing_package_manifest")

local M = {}

local function fail(classification, message)
  error(error_facts.error_message("testing-runtime.package-resolver", classification, message))
end

local function callable_ports(ports, names)
  if type(ports) ~= "table" then fail("missing-ports", "resolver ports must be a table") end
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

local function equal_list(left, right)
  if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then return false end
  for index, item in ipairs(left) do if item ~= right[index] then return false end end
  return true
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

local function select_mapping(request, manifest, policy, capability_set)
  if manifest.package_id ~= request.executor.package_id
    or manifest.package_version ~= request.executor.package_version
    or manifest.package_content_sha256 ~= request.executor.package_content_sha256
    or manifest.manifest_digest ~= request.executor.manifest_digest then
    fail("identity-mismatch", "verified manifest does not match executor identity")
  end

  local supported = {}
  for _, mapping in ipairs(contract.semantic_mappings) do
    if mapping.execution_profile == request.execution_profile
      and mapping.package_id == request.executor.package_id
      and mapping.contract_major == request.executor.contract_major
      and mapping.entrypoint == request.executor.entrypoint
      and equal_list(mapping.capabilities, policy.allowed_capabilities)
      and equal_list(mapping.capabilities, capability_set.capabilities) then
      table.insert(supported, mapping)
    end
  end
  if #supported == 0 then fail("unsupported-mapping", "no supported semantic mapping matches the verified request and policy") end
  if #supported ~= 1 then fail("mapping-ambiguous", "more than one supported semantic mapping matches") end
  local mapping = supported[1]

  if policy.execution_profile ~= mapping.execution_profile or policy.authorized_entrypoint ~= mapping.entrypoint then
    fail("policy-mismatch", "verified policy does not authorize the selected semantic mapping")
  end
  local selected = {}
  for _, entrypoint in ipairs(manifest.entrypoints) do
    if entrypoint.name == mapping.entrypoint
      and entrypoint.contract_major == mapping.contract_major
      and equal_list(entrypoint.capabilities, mapping.capabilities) then
      table.insert(selected, entrypoint)
    end
  end
  if #selected == 0 then fail("entrypoint-mismatch", "manifest does not declare the selected semantic entrypoint") end
  if #selected ~= 1 then fail("mapping-ambiguous", "manifest declares the selected semantic entrypoint more than once") end
  return mapping, selected[1]
end

local function admission_digest(ports, request, mapping)
  local bytes = canonical_json.encode({
    schema = contract.schemas.admission_request,
    admission_key = request.dedup_key,
    executor = copy_identity(request.executor),
    execution_profile = request.execution_profile,
    approved_input_refs = copy_refs(request.approved_input_refs),
    selected_entrypoint = {
      executor_id = mapping.executor_id,
      name = mapping.entrypoint,
      contract_major = mapping.contract_major,
      capabilities = mapping.capabilities,
    },
  })
  local digest = call_port(ports, "sha256", bytes)
  if type(digest) ~= "string" or digest:match("^[0-9a-f]+$") == nil or #digest ~= 64 then
    fail("sha256-failed", "admission SHA-256 result is malformed")
  end
  return digest
end

function M.resolve(request, ports)
  contract.validate_request(request)
  callable_ports(ports, { "load_immutable", "sha256", "decode_json", "admit_resolution" })

  local documents = {}
  documents.package_manifest_ref = load_document(request, ports, "package_manifest_ref", function(value)
    package_manifest.validate(value, {
      package_id = request.executor.package_id,
      package_version = request.executor.package_version,
      package_content_sha256 = request.executor.package_content_sha256,
      entrypoint = request.executor.entrypoint,
      contract_major = request.executor.contract_major,
    }, ports.sha256)
  end)
  documents.source_ref = load_document(request, ports, "source_ref", contract.validate_source)
  documents.plan_ref = load_document(request, ports, "plan_ref", contract.validate_plan)
  documents.pql_input_ref = load_document(request, ports, "pql_input_ref", contract.validate_pql_input)
  documents.policy_ref = load_document(request, ports, "policy_ref", contract.validate_policy)
  documents.capability_set_ref = load_document(request, ports, "capability_set_ref", contract.validate_capability_set)

  local mapping, selected = select_mapping(request, documents.package_manifest_ref, documents.policy_ref, documents.capability_set_ref)
  local digest = admission_digest(ports, request, mapping)
  local admission = call_port(ports, "admit_resolution", {
    schema = contract.schemas.admission_request,
    admission_key = request.dedup_key,
    admission_digest = digest,
  })
  if type(admission) ~= "table" then fail("port-failed", "admit_resolution did not return a receipt") end
  if admission.status == "conflict" then
    contract.validate_admission_conflict(admission, request.dedup_key, digest)
    fail("admission-conflict", "admission key is already bound to a different verified digest")
  end
  contract.validate_admission_receipt(admission, request.dedup_key, digest)

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
      executor_id = mapping.executor_id,
      name = selected.name,
      contract_major = selected.contract_major,
      capabilities = { selected.capabilities[1] },
    },
    admission_digest = digest,
    admission_receipt = admission,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  contract.validate_resolved_invocation(resolved)
  return resolved
end

function M.failure_receipt(request, failure)
  local code = error_facts.error_class_from_message(failure)
  if not contract.resolver_failure_codes[code] then code = "caught-failure" end
  local receipt = {
    schema = contract.schemas.resolver_failure,
    status = "rejected",
    admission_key = type(request) == "table" and tostring(request.dedup_key or "unknown") or "unknown",
    code = code,
  }
  contract.validate_resolver_failure(receipt)
  return receipt
end

return M
