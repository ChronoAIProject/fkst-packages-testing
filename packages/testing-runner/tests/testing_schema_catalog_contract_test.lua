local catalog = require("contract.testing_schema_catalog")
local canonical_json = require("contract.canonical_json")
local sha256 = require("tests.fixtures.sha256_helpers")
local t = fkst.test

local function digest(char) return string.rep(char, 64) end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[copy(key)] = copy(item) end
  return result
end

local function seal(value, field)
  local payload = {}
  for key, item in pairs(value) do
    if key ~= field then payload[key] = copy(item) end
  end
  value[field] = sha256(canonical_json.encode(payload))
  return value
end

local function valid_fixture_set()
  return seal({
    schema = "testing-schema-fixture-set.v1",
    schema_id = "testing-result-reason.v1",
    files = {
      { path = "schema-fixtures/testing-result-reason.v1/invalid.json", sha256 = digest("a"), size_bytes = 2 },
      { path = "schema-fixtures/testing-result-reason.v1/valid.json", sha256 = digest("b"), size_bytes = 2 },
    },
  }, "fixture_set_sha256")
end

local function valid_catalog()
  return seal({
    schema = "testing-schema-catalog.v1",
    canonicalization = "fkst-testing-schema-catalog-canonical-json.v1",
    schemas = { {
      schema_id = "testing-result-reason.v1",
      path = "schemas/testing-result-reason.v1.schema.json",
      draft = "https://json-schema.org/draft/2020-12/schema",
      canonicalization_profile = "json-schema-draft-2020-12-portable.v1",
      schema_sha256 = digest("c"),
      contract_major = 1,
      status = "stable",
      fixture_set_path = "schema-release/fixture-sets/testing-result-reason.v1.json",
      fixture_set_sha256 = digest("d"),
    } },
  }, "catalog_sha256")
end

local function valid_release()
  return seal({
    schema = "testing-package-schema-release.v1",
    canonicalization = "fkst-testing-package-schema-release-canonical-json.v1",
    package_manifest = { kind = "testing-package-manifest", ref = "immutable://package-manifest", sha256 = digest("e") },
    schema_catalog = { kind = "testing-schema-catalog", ref = "immutable://schema-catalog", sha256 = digest("f") },
    producer = { name = "fkst-packages-testing", version = "1.0.0" },
  }, "release_sha256")
end

return {
  test_validates_fixture_set_catalog_and_release_identities = function()
    local fixture_set = valid_fixture_set()
    local schema_catalog = valid_catalog()
    local release = valid_release()
    t.eq(catalog.validate_fixture_set(fixture_set, sha256), fixture_set)
    t.eq(catalog.validate_catalog(schema_catalog, sha256), schema_catalog)
    t.eq(catalog.validate_release(release, sha256), release)
  end,

  test_fixture_set_rejects_unknown_unsorted_and_invalid_identity = function()
    local value = valid_fixture_set(); value.extra = true
    t.raises(function() catalog.validate_fixture_set(value, sha256) end)
    value = valid_fixture_set(); value.files[2].path = value.files[1].path
    t.raises(function() catalog.validate_fixture_set(value, sha256) end)
    value = valid_fixture_set(); value.files[1].size_bytes = -1
    t.raises(function() catalog.validate_fixture_set(value, sha256) end)
    value = valid_fixture_set(); value.schema_id = string.char(0xff)
    t.raises(function() catalog.validate_fixture_set(value, sha256) end)
    value = valid_fixture_set(); value.fixture_set_sha256 = digest("0")
    t.raises(function() catalog.validate_fixture_set(value, sha256) end)
    t.raises(function() catalog.validate_fixture_set(valid_fixture_set()) end)
    t.raises(function() catalog.validate_fixture_set(valid_fixture_set(), function() return "bad" end) end)
  end,

  test_catalog_rejects_invalid_entries_duplicates_and_digest = function()
    local value = valid_catalog(); value.schema = "testing-schema-catalog.v2"
    t.raises(function() catalog.validate_catalog(value, sha256) end)
    value = valid_catalog(); value.schemas[1].schema_sha256 = "bad"
    t.raises(function() catalog.validate_catalog(value, sha256) end)
    value = valid_catalog(); value.schemas[1].status = "draft"
    t.raises(function() catalog.validate_catalog(value, sha256) end)
    value = valid_catalog(); table.insert(value.schemas, copy(value.schemas[1]))
    t.raises(function() catalog.validate_catalog(value, sha256) end)
    value = valid_catalog(); value.catalog_sha256 = digest("0")
    t.raises(function() catalog.validate_catalog(value, sha256) end)
  end,

  test_release_rejects_invalid_references_producer_and_digest = function()
    local value = valid_release(); value.canonicalization = "unknown"
    t.raises(function() catalog.validate_release(value, sha256) end)
    value = valid_release(); value.schema_catalog.extra = true
    t.raises(function() catalog.validate_release(value, sha256) end)
    value = valid_release(); value.package_manifest.ref = ""
    t.raises(function() catalog.validate_release(value, sha256) end)
    value = valid_release(); value.producer.version = "1.0"
    t.raises(function() catalog.validate_release(value, sha256) end)
    value = valid_release(); value.release_sha256 = digest("0")
    t.raises(function() catalog.validate_release(value, sha256) end)
  end,
}
