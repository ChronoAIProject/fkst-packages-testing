-- contract.testing_package_manifest: immutable release identity for testing packages.
local canonical_json = require("contract.canonical_json")
local error_facts = require("contract.error_facts")
local M = {}

M.schema = "testing-package-manifest.v1"
M.canonicalization = "fkst-testing-package-manifest-canonical-json.v1"
M.contract_majors = { ["testing-runner.v1"] = true }
M.canonicalization_profiles = { [M.canonicalization] = true }
M.entrypoints = {
  ["testing-runner.run"] = true,
  ["testing-runner.supervise"] = true,
}
M.max_entries = 32
M.max_capabilities = 64
M.max_contracts = 32

local function fail(classification, message)
  error(error_facts.error_message("contract.testing-package-manifest", classification, message))
end

local function fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, "must be a table") end
  for key in pairs(value) do
    if allowed[key] ~= true then fail("malformed-" .. context, "unsupported field " .. tostring(key)) end
  end
end

local function required(value, field)
  if value == nil then fail("missing-field", field .. " is required") end
  return value
end

local function bounded(value, field, limit)
  if type(value) ~= "string" or value == "" or #value > (limit or 512) or value:find("[%z\1-\31]") ~= nil then
    fail("malformed-field", field .. " must be a bounded string")
  end
  return value
end

local function exact_sha256(value, field)
  bounded(value, field, 64)
  if not value:match("^[0-9a-f][0-9a-f]*$") or #value ~= 64 then
    fail("malformed-digest", field .. " must be lowercase SHA-256")
  end
end

local function exact_commit(value, field)
  bounded(value, field, 40)
  if not value:match("^[0-9a-f][0-9a-f]*$") or #value ~= 40 then
    fail("floating-reference", field .. " must be an exact 40-hex commit")
  end
end

local function semver(value, field)
  bounded(value, field, 64)
  if not value:match("^[0-9]+%.[0-9]+%.[0-9]+$") then
    fail("floating-version", field .. " must be an exact semantic version")
  end
end

local function package_id(value)
  bounded(value, "package_id", 180)
  if value:find("[/\\\\]") ~= nil or value:find("%.%.", 1, true) ~= nil then
    fail("unsafe-reference", "package_id must not contain a workspace path")
  end
end

local function dense_list(value, field, limit, nonempty)
  if type(value) ~= "table" then fail("malformed-list", field .. " must be a list") end
  local count, highest = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then fail("malformed-list", field .. " must be dense") end
    count, highest = count + 1, math.max(highest, key)
  end
  if count ~= highest or count > limit or (nonempty and count == 0) then fail("malformed-list", field .. " has an invalid size") end
  return value
end

local function unique_list(value, field, limit, nonempty)
  dense_list(value, field, limit, nonempty)
  local seen = {}
  for _, item in ipairs(value) do
    bounded(item, field .. " item", 180)
    if seen[item] then fail("duplicate-item", field .. " contains " .. item .. " more than once") end
    seen[item] = true
  end
  return seen
end

local function validate_dependency(value, field, expected_id)
  fields(value, { id = true, commit = true }, field)
  if value.id ~= expected_id then fail("dependency-mismatch", field .. ".id must be " .. expected_id) end
  exact_commit(required(value.commit, field .. ".commit"), field .. ".commit")
end

local function validate_entrypoint(value, contracts, capabilities)
  fields(value, { name = true, contract_major = true, capabilities = true }, "entrypoint")
  local name = bounded(required(value.name, "entrypoint.name"), "entrypoint.name", 180)
  if not M.entrypoints[name] then fail("unknown-entrypoint", name) end
  local major = bounded(required(value.contract_major, "entrypoint.contract_major"), "entrypoint.contract_major", 32)
  if not contracts[major] then fail("unsupported-major", "entrypoint contract major " .. major) end
  local required_capabilities = unique_list(required(value.capabilities, "entrypoint.capabilities"), "entrypoint.capabilities", M.max_capabilities, false)
  for capability in pairs(required_capabilities) do
    if not capabilities[capability] then fail("capability-mismatch", name .. " requires undeclared capability " .. capability) end
  end
end

local function validate_runtime(value)
  fields(value, { lua = true, platforms = true }, "runtime_requirements")
  local lua = bounded(required(value.lua, "runtime_requirements.lua"), "runtime_requirements.lua", 64)
  if lua:find("[%*~<>=|]", 1) then fail("floating-runtime", "runtime_requirements.lua must be exact") end
  unique_list(required(value.platforms, "runtime_requirements.platforms"), "runtime_requirements.platforms", 16, true)
end

local function validate_metadata(value)
  fields(value, { created_at = true, build_id = true }, "creation_metadata")
  local created_at = bounded(required(value.created_at, "creation_metadata.created_at"), "creation_metadata.created_at", 64)
  if not created_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then fail("malformed-field", "creation_metadata.created_at must be UTC RFC3339") end
  bounded(required(value.build_id, "creation_metadata.build_id"), "creation_metadata.build_id", 180)
end

function M.validate(value, expected, sha256_fn)
  fields(value, {
    schema = true, canonicalization = true, package_id = true, package_version = true,
    source_commit = true, package_content_sha256 = true, supported_contracts = true,
    entrypoints = true, semantic_capabilities = true, runtime_requirements = true,
    dependencies = true, producer = true, creation_metadata = true, manifest_digest = true,
  }, "manifest")
  if value.schema ~= M.schema then fail("unknown-schema", "manifest schema") end
  if value.canonicalization ~= M.canonicalization then fail("unknown-canonicalization", "manifest canonicalization") end
  package_id(required(value.package_id, "package_id"))
  semver(required(value.package_version, "package_version"), "package_version")
  exact_commit(required(value.source_commit, "source_commit"), "source_commit")
  exact_sha256(required(value.package_content_sha256, "package_content_sha256"), "package_content_sha256")

  fields(required(value.supported_contracts, "supported_contracts"), { majors = true, canonicalization_profiles = true }, "supported_contracts")
  local contracts = unique_list(required(value.supported_contracts.majors, "supported_contracts.majors"), "supported_contracts.majors", M.max_contracts, true)
  for major in pairs(contracts) do if not M.contract_majors[major] then fail("unsupported-major", major) end end
  local profiles = unique_list(required(value.supported_contracts.canonicalization_profiles, "supported_contracts.canonicalization_profiles"), "supported_contracts.canonicalization_profiles", M.max_contracts, true)
  for profile in pairs(profiles) do if not M.canonicalization_profiles[profile] then fail("unsupported-canonicalization", profile) end end

  local capabilities = unique_list(required(value.semantic_capabilities, "semantic_capabilities"), "semantic_capabilities", M.max_capabilities, false)
  local entrypoints = dense_list(required(value.entrypoints, "entrypoints"), "entrypoints", M.max_entries, true)
  for _, entrypoint in ipairs(entrypoints) do validate_entrypoint(entrypoint, contracts, capabilities) end

  validate_runtime(required(value.runtime_requirements, "runtime_requirements"))
  fields(required(value.dependencies, "dependencies"), { fkst_packages = true, fkst_substrate = true }, "dependencies")
  validate_dependency(required(value.dependencies.fkst_packages, "dependencies.fkst_packages"), "dependencies.fkst_packages", "fkst-packages")
  validate_dependency(required(value.dependencies.fkst_substrate, "dependencies.fkst_substrate"), "dependencies.fkst_substrate", "fkst-substrate")
  fields(required(value.producer, "producer"), { name = true, version = true, toolchain = true }, "producer")
  bounded(required(value.producer.name, "producer.name"), "producer.name", 180)
  semver(required(value.producer.version, "producer.version"), "producer.version")
  bounded(required(value.producer.toolchain, "producer.toolchain"), "producer.toolchain", 180)
  validate_metadata(required(value.creation_metadata, "creation_metadata"))
  exact_sha256(required(value.manifest_digest, "manifest_digest"), "manifest_digest")

  if expected ~= nil then
    fields(expected, { package_id = true, package_version = true, source_commit = true, package_content_sha256 = true, entrypoint = true, contract_major = true, capability = true }, "expected")
    for _, field in ipairs({ "package_id", "package_version", "source_commit", "package_content_sha256" }) do
      if expected[field] ~= nil and value[field] ~= expected[field] then fail("identity-mismatch", field .. " does not match expected identity") end
    end
    if expected.entrypoint ~= nil then
      local found = false
      for _, entrypoint in ipairs(entrypoints) do if entrypoint.name == expected.entrypoint then found = true end end
      if not found then fail("entrypoint-mismatch", "expected entrypoint is not declared") end
    end
    if expected.contract_major ~= nil and not contracts[expected.contract_major] then fail("unsupported-major", "expected contract major is not declared") end
    if expected.capability ~= nil and not capabilities[expected.capability] then fail("capability-mismatch", "expected capability is not declared") end
  end
  if sha256_fn ~= nil then
    if type(sha256_fn) ~= "function" then fail("missing-sha256", "SHA-256 function must be callable") end
    local copy = {}
    for key, item in pairs(value) do if key ~= "manifest_digest" then copy[key] = item end end
    local ok, computed = pcall(sha256_fn, M.canonicalize(copy))
    if not ok then fail("sha256-failed", "SHA-256 function failed") end
    if computed ~= value.manifest_digest then fail("digest-mismatch", "manifest digest does not match") end
  end
  return value
end

function M.canonicalize(value)
  return canonical_json.encode(value)
end

return M
