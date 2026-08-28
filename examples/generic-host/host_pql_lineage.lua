local json = require("testing_runtime.json")
local testing_design = require("contract.testing_design")

local M = {}

local function fail(classification, message)
  error("generic-host-pql-lineage: " .. classification .. ": " .. message, 0)
end

local function bounded_string(value)
  return type(value) == "string" and value ~= "" and #value <= 512
    and value:find("[%z\1-\31\127]") == nil
end

local function single_item(value, name)
  if type(value) ~= "table" then fail("malformed-lineage", name .. " must be a table") end
  local count = 0
  for key, _ in pairs(value) do
    if key ~= 1 then fail("malformed-lineage", name .. " must contain exactly one item") end
    count = count + 1
  end
  if count ~= 1 then fail("malformed-lineage", name .. " must contain exactly one item") end
  return value[1]
end

local function required_ref(value, name)
  if type(value) ~= "table" or not bounded_string(value.ref) then
    fail("malformed-lineage", name .. ".ref must be a non-empty string")
  end
  return value.ref
end

function M.accept(context_reference, ports)
  testing_design.validate_context_reference(context_reference)
  ports = ports or {}
  if type(ports.read_artifact_bytes) ~= "function" or type(ports.sha256_bytes) ~= "function" then
    fail("unavailable-port", "artifact byte reader and SHA-256 ports are required")
  end
  local decode_json = ports.decode_json or json.decode
  if type(decode_json) ~= "function" then fail("unavailable-port", "JSON decoder is required") end

  local context = testing_design.copy_context_reference(context_reference)
  local traceability_ref = context.traceability_seed
  local bytes = ports.read_artifact_bytes(traceability_ref.artifact_pointer)
  if type(bytes) ~= "string" then fail("artifact-unavailable", "traceability seed bytes are unavailable") end
  if ports.sha256_bytes(bytes) ~= traceability_ref.artifact_digest then
    fail("digest-mismatch", "traceability seed bytes differ from the published digest")
  end

  local traceability = decode_json(bytes)
  if type(traceability) ~= "table" or type(traceability.pql_lineage) ~= "table" then
    fail("malformed-lineage", "pql_lineage must be a table")
  end
  local approved = single_item(traceability.pql_lineage.approved_assets, "pql_lineage.approved_assets")
  if type(approved) ~= "table" then fail("malformed-lineage", "approved asset must be a table") end
  if not bounded_string(approved.asset_id) then
    fail("malformed-lineage", "approved asset asset_id must be a non-empty string")
  end
  if not bounded_string(approved.asset_version) then
    fail("malformed-lineage", "approved asset asset_version must be a non-empty string")
  end
  local asset_ref = required_ref(approved.asset_ref, "approved asset asset_ref")
  local requirement = single_item(approved.requirement_refs, "approved asset requirement_refs")
  local requirement_ref = required_ref(requirement, "approved asset requirement_refs[1]")
  local design_case_id = approved.asset_id .. "@" .. approved.asset_version
  if design_case_id ~= asset_ref then
    fail("identity-mismatch", "derived design case identity differs from asset_ref.ref")
  end
  if design_case_id == requirement_ref then
    fail("identity-mismatch", "requirement identity cannot be used as the design case identity")
  end

  return {
    context = context,
    asset_id = approved.asset_id,
    asset_version = approved.asset_version,
    asset_ref = { ref = asset_ref },
    requirement_refs = { { ref = requirement_ref } },
    design_case_id = design_case_id,
  }
end

return M
