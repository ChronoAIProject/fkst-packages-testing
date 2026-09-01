local canonical_json = require("contract.canonical_json")
local M = {}

local function fail(message) error("contract.testing-schema-catalog: malformed-artifact: " .. message) end
local function fields(value, allowed, label)
  if type(value) ~= "table" then fail(label .. " must be an object") end
  for key in pairs(value) do if allowed[key] ~= true then fail(label .. " has unsupported field " .. tostring(key)) end end
end
local function bounded(value, label)
  if type(value) ~= "string" or value == "" or #value > 4096 or not canonical_json.is_valid_utf8(value) then fail(label .. " must be bounded UTF-8") end
end
local function digest(value, label) if type(value) ~= "string" or not value:match("^[0-9a-f]+$") or #value ~= 64 then fail(label .. " must be SHA-256") end end
local function dense(value, label)
  if type(value) ~= "table" then fail(label .. " must be an array") end
  local count, highest = 0, 0
  for key in pairs(value) do if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then fail(label .. " must be dense") end; count, highest = count + 1, math.max(highest, key) end
  if count ~= highest then fail(label .. " must be dense") end
end
local function identity(value, digest_field, sha256_fn)
  if type(sha256_fn) ~= "function" then fail("SHA-256 function is required") end
  local copy = {}; for key, item in pairs(value) do if key ~= digest_field then copy[key] = item end end
  local actual = sha256_fn(canonical_json.encode(copy)); digest(actual, "computed digest")
  if actual ~= value[digest_field] then fail(digest_field .. " differs") end
end

function M.validate_fixture_set(value, sha256_fn)
  fields(value, {schema=true,schema_id=true,files=true,fixture_set_sha256=true}, "fixture set")
  if value.schema ~= "testing-schema-fixture-set.v1" then fail("fixture set schema differs") end
  bounded(value.schema_id, "schema_id"); dense(value.files, "files"); local previous, seen = nil, {}
  for _, item in ipairs(value.files) do
    fields(item, {path=true,sha256=true,size_bytes=true}, "fixture file"); bounded(item.path, "path"); digest(item.sha256, "sha256")
    if type(item.size_bytes) ~= "number" or item.size_bytes < 0 or item.size_bytes ~= math.floor(item.size_bytes) then fail("size_bytes must be non-negative integer") end
    if seen[item.path] or (previous ~= nil and previous >= item.path) then fail("fixture files must be unique and sorted") end
    seen[item.path], previous = true, item.path
  end
  digest(value.fixture_set_sha256, "fixture_set_sha256"); identity(value, "fixture_set_sha256", sha256_fn); return value
end

function M.validate_catalog(value, sha256_fn)
  fields(value, {schema=true,canonicalization=true,schemas=true,catalog_sha256=true}, "catalog")
  if value.schema ~= "testing-schema-catalog.v1" or value.canonicalization ~= "fkst-testing-schema-catalog-canonical-json.v1" then fail("catalog identity differs") end
  dense(value.schemas, "schemas"); local previous, seen_ids, seen_paths = nil, {}, {}
  for _, item in ipairs(value.schemas) do
    fields(item, {schema_id=true,path=true,draft=true,canonicalization_profile=true,schema_sha256=true,contract_major=true,status=true,fixture_set_path=true,fixture_set_sha256=true}, "catalog entry")
    bounded(item.schema_id, "schema_id"); bounded(item.path, "path"); digest(item.schema_sha256, "schema_sha256"); digest(item.fixture_set_sha256, "fixture_set_sha256")
    if item.draft ~= "https://json-schema.org/draft/2020-12/schema" or item.status ~= "stable" or type(item.contract_major) ~= "number" then fail("catalog entry identity differs") end
    if seen_ids[item.schema_id] or seen_paths[item.path] or (previous ~= nil and previous >= item.schema_id) then fail("catalog entries must be unique and sorted") end
    seen_ids[item.schema_id], seen_paths[item.path], previous = true, true, item.schema_id
  end
  digest(value.catalog_sha256, "catalog_sha256"); identity(value, "catalog_sha256", sha256_fn); return value
end

function M.validate_release(value, sha256_fn)
  fields(value, {schema=true,canonicalization=true,package_manifest=true,schema_catalog=true,producer=true,release_sha256=true}, "release")
  if value.schema ~= "testing-package-schema-release.v1" or value.canonicalization ~= "fkst-testing-package-schema-release-canonical-json.v1" then fail("release identity differs") end
  for label, reference in pairs({package_manifest=value.package_manifest,schema_catalog=value.schema_catalog}) do
    fields(reference, {kind=true,ref=true,sha256=true}, label); bounded(reference.kind, label .. ".kind"); bounded(reference.ref, label .. ".ref"); digest(reference.sha256, label .. ".sha256")
  end
  fields(value.producer, {name=true,version=true}, "producer")
  if value.producer.name ~= "fkst-packages-testing" or type(value.producer.version) ~= "string" or not value.producer.version:match("^[0-9]+%.[0-9]+%.[0-9]+$") then fail("producer identity differs") end
  digest(value.release_sha256, "release_sha256"); identity(value, "release_sha256", sha256_fn); return value
end

return M
