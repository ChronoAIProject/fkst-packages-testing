local canonical_json = require("contract.canonical_json")
local lineage = require("contract.execution_authorization_lineage")

local M = {}

local Projector = {}
Projector.__index = Projector

local validators = {
  profile_claim = lineage.validate_profile_claim_receipt,
  preauthorization_claim = lineage.validate_preauthorization_claim_receipt,
  grant_verification = lineage.validate_grant_verification_receipt,
  execution_claim = lineage.validate_execution_claim_receipt,
  execution_completion = lineage.validate_execution_completion_receipt,
}

local statuses = {
  profile_claim = "claimed",
  preauthorization_claim = "claimed",
  grant_verification = "authenticated",
  execution_claim = "claimed",
  execution_completion = "completed",
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[copy(key)] = copy(item) end
  return result
end

local function fail(message)
  error("testing-runtime: authorization-lineage-projection: " .. message, 0)
end

local function require_identity(value, label)
  if type(value) ~= "string" or value == "" or #value > 180
    or value:find("%s") ~= nil or value:find("[%z\1-\31\127]") ~= nil then
    fail(label .. " is invalid")
  end
  return value
end

function M.new(options)
  if type(options) ~= "table" or type(options.store) ~= "table"
    or type(options.store.load) ~= "function" or type(options.store.write_raw) ~= "function"
    or type(options.sha256) ~= "function" or type(options.fingerprint_secret) ~= "string"
    or #options.fingerprint_secret < 32 then
    fail("store, sha256, and a private fingerprint secret are required")
  end
  require_identity(options.run_id, "run_id")
  require_identity(options.trace_id, "trace_id")
  require_identity(options.dedup_key, "dedup_key")
  local root = ".testing/runs/" .. options.run_id
  if options.artifact_root ~= root then fail("artifact_root must be the canonical run root") end
  return setmetatable({
    store = options.store,
    sha256 = options.sha256,
    fingerprint_secret = options.fingerprint_secret,
    repository = copy(options.repository),
    run_id = options.run_id,
    trace_id = options.trace_id,
    dedup_key = options.dedup_key,
    artifact_root = root,
  }, Projector)
end

function Projector:path(name)
  local suffix = lineage.paths[name]
  if suffix == nil then fail("unsupported receipt name " .. tostring(name)) end
  return self.artifact_root .. "/" .. suffix
end

function Projector:fingerprint(domain, private_claim_id)
  require_identity(domain, "fingerprint domain")
  require_identity(private_claim_id, "private claim id")
  local inner = self.sha256(self.fingerprint_secret .. "\0" .. domain .. "\0" .. private_claim_id)
  return self.sha256("fkst-authorization-lineage.v1\0" .. domain .. "\0" .. inner)
end

function Projector:_persist(path, value)
  local body = canonical_json.encode(value)
  local digest = self.sha256(body)
  local existing = self.store:load(path)
  if existing == nil then
    if self.store:write_raw(path, body) ~= true then fail("immutable receipt write failed") end
    existing = self.store:load(path)
  end
  if type(existing) ~= "table" or existing.raw ~= body or existing.digest ~= digest then
    fail("immutable receipt differs at " .. path)
  end
  return { ref = path, sha256 = digest, value = copy(value) }
end

function Projector:write_receipt(name, receipt_id, recorded_at, fields, expected)
  local validator = validators[name]
  if validator == nil or type(fields) ~= "table" or type(expected) ~= "table" then
    fail("receipt fields and independent source bindings are required")
  end
  local value = {
    schema = lineage.schemas[name],
    status = statuses[name],
    receipt_id = require_identity(receipt_id, "receipt_id"),
    repository = copy(self.repository),
    run_id = self.run_id,
    trace_id = self.trace_id,
    dedup_key = self.dedup_key,
    recorded_at = recorded_at,
    source_max_uses = 1,
    evidence_role = "audit-only",
    authorization_capability = false,
    reusable = false,
  }
  for key, item in pairs(fields) do
    if value[key] ~= nil then fail("receipt field shadows envelope: " .. tostring(key)) end
    value[key] = copy(item)
  end
  validator(value, expected)
  return self:_persist(self:path(name), value), expected
end

function Projector:load_receipt(name, expected)
  if type(expected) ~= "table" then fail("independent source bindings are required") end
  local artifact = self.store:load(self:path(name))
  if artifact == nil or type(artifact.value) ~= "table" then
    fail("required predecessor receipt is unavailable: " .. tostring(name))
  end
  local canonical = canonical_json.encode(artifact.value)
  local digest = self.sha256(canonical)
  if artifact.raw ~= canonical or artifact.digest ~= digest then
    fail("predecessor receipt is not canonical: " .. tostring(name))
  end
  validators[name](artifact.value, expected)
  return { ref = self:path(name), sha256 = digest, value = copy(artifact.value) }
end

function Projector:write_index(recorded_at, artifacts, expected)
  if type(artifacts) ~= "table" or type(expected) ~= "table" then
    fail("complete trusted receipt artifacts and source bindings are required")
  end
  local receipts = {}
  for _, name in ipairs({
    "profile_claim", "preauthorization_claim", "grant_verification",
    "execution_claim", "execution_completion",
  }) do
    artifacts[name] = self:load_receipt(name, expected[name])
    receipts[name] = { ref = artifacts[name].ref, sha256 = artifacts[name].sha256 }
  end
  local value = {
    schema = lineage.schemas.lineage_index,
    status = "complete",
    repository = copy(self.repository),
    run_id = self.run_id,
    trace_id = self.trace_id,
    dedup_key = self.dedup_key,
    recorded_at = recorded_at,
    receipts = receipts,
    lineage_complete = true,
    source_max_uses = 1,
    evidence_role = "audit-only",
    authorization_capability = false,
    reusable = false,
  }
  lineage.validate_lineage_index(value, artifacts, expected)
  return self:_persist(self.artifact_root .. "/authorization-lineage/index.json", value)
end

return M
