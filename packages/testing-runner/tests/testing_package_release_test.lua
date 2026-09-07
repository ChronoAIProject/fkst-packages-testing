local release = require("contract.testing_package_release")
local t = fkst.test

local function plain(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = plain(item) end
  return result
end

local function load(name)
  local path = "packages/testing-runner/tests/fixtures/testing-package-release.v1/" .. name .. ".json"
  local handle = assert(io.open(path, "rb"))
  local value = json.decode(handle:read("*a"))
  handle:close()
  return value
end

local function successor()
  local value = load("valid")
  value.authority = {
    issuer = "https://releases.chronoaiproject.org/fkst-packages-testing",
    keyid = "fkst-packages-testing-successor-test-v1",
    release_sequence = 2,
    revocation_authority = "https://releases.chronoaiproject.org/fkst-packages-testing/revocations/v1",
    signature_profile = "dsse-ed25519.v1",
    valid_from = "2026-09-04T00:00:00Z",
    valid_until = "2026-09-05T00:00:00Z",
  }
  value.tool_catalog = {
    path = "package-release/testing-package-tool-catalog.v1.json",
    sha256 = string.rep("a", 64),
    size_bytes = 1,
  }
  return value
end

local function rejects(value)
  return not pcall(function() release.validate(value) end)
end

return {
  test_valid_release_contract = function()
    local value = load("valid")
    t.eq(release.validate(value), value)
    t.eq(release.canonicalize(plain(value)):sub(-1), "\n")
  end,

  test_release_contract_rejects_unknown_fields = function()
    local ok = pcall(function() release.validate(load("invalid-unknown-field")) end)
    t.eq(ok, false)
  end,

  test_successor_accepts_bounded_publisher_metadata = function()
    local value = successor()
    value.executor = { module = "publisher.module", ["function"] = "publisher_function", executor_id = "publisher.executor" }
    value.mappings[1].module = "publisher.mapping"
    value.mappings[1]["function"] = "publisher_mapping"
    t.eq(release.validate(value), value)
  end,

  test_successor_rejects_incomplete_or_malformed_policy = function()
    local value = successor()
    value.tool_catalog = nil
    t.eq(rejects(value), true)

    value = successor()
    value.authority.keyid = "bad\194\133key"
    t.eq(rejects(value), true)

    value = successor()
    value.authority.release_sequence = 9007199254740992
    t.eq(rejects(value), true)

    value = successor()
    value.authority.valid_from = "2026-02-30T00:00:00Z"
    t.eq(rejects(value), true)

    value = successor()
    value.authority.valid_until = value.authority.valid_from
    t.eq(rejects(value), true)

    value = successor()
    value.tool_catalog.path = "publisher/tool-catalog.json"
    t.eq(rejects(value), true)
  end,

  test_legacy_rejects_publisher_coordinate_substitution = function()
    local value = load("valid")
    value.executor.module = "publisher.module"
    t.eq(rejects(value), true)

    value = load("valid")
    value.mappings[1]["function"] = "publisher_mapping"
    t.eq(rejects(value), true)
  end,
}
