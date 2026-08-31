local contract = require("contract.testing_runner_invocation")
local error_facts = require("contract.error_facts")
local sha256 = require("tests.fixtures.sha256_helpers")
local conformance = require("tests.fixtures.conformance_runner_helpers")
local t = fkst.test
local root = "packages/testing-runner/tests/fixtures/testing-runner-invocation.v1"

local function read_json(path)
  if path:sub(-10) == "/index.json" then return conformance.index(root) end
  return conformance.fixture(root, path:match("([^/]+)%.json$"))
end

local function canonical_request_bytes(request)
  local canonical_json = require("contract.canonical_json")
  local function canonical_copy(value, omit_digest)
    if type(value) ~= "table" then return value end
    local numeric, count, highest = true, 0, 0
    for key in pairs(value) do if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then numeric = false; break end; count = count + 1; highest = math.max(highest, key) end
    if numeric and count == highest then local copy = {}; for index = 1, highest do copy[index] = canonical_copy(value[index], false) end; return canonical_json.array(copy) end
    local copy = {}; for key, item in pairs(value) do if not (omit_digest and key == "canonical_request_sha256") then copy[key] = canonical_copy(item, false) end end; return canonical_json.object(copy)
  end
  return canonical_json.encode(canonical_copy(request, true))
end

local function assert_malformed_capabilities(capabilities)
  local request = read_json(root .. "/valid-canonical-envelope.json").request
  request.requested_capabilities = capabilities
  local sha256_calls = 0
  local ok, message = pcall(contract.validate, request, function(bytes)
    sha256_calls = sha256_calls + 1
    return sha256(bytes)
  end)
  t.eq(ok, false)
  t.eq(error_facts.error_class_from_message(message), "malformed-list")
  t.eq(sha256_calls, 0)
end

return {
  test_shared_fixture_is_closed_and_valid = function()
    local index = read_json(root .. "/index.json")
    t.eq(index.schema, "testing-runner-invocation-fixture-index.v1")
    t.eq(#index.cases, 1)
    t.eq(index.cases[1].name, "valid-canonical-envelope")
    local fixture = read_json(root .. "/" .. index.cases[1].file)
    t.eq(fixture.case, "valid-canonical-envelope")
    t.eq(fixture.portable_valid, true)
    t.eq(fixture.lua_valid, true)
    t.eq(fixture.lua_error, "")
    t.eq(contract.validate(fixture.request, sha256), fixture.request)
    t.eq(sha256(canonical_request_bytes(fixture.request)), fixture.request.canonical_request_sha256)
  end,

  test_requested_capabilities_rejects_string_key_injection = function()
    assert_malformed_capabilities({ [1] = "browser.read-title.v1", injected = "unexpected" })
  end,

  test_requested_capabilities_rejects_sparse_numeric_keys = function()
    assert_malformed_capabilities({ [1] = "browser.read-title.v1", [3] = "browser.capture-screenshot.v1" })
  end,

  test_requested_capabilities_rejects_invalid_numeric_keys = function()
    for _, invalid_key in ipairs({ 0, -1, 1.5 }) do
      assert_malformed_capabilities({ [1] = "browser.read-title.v1", [invalid_key] = "browser.capture-screenshot.v1" })
    end

    local over_range = {}
    for index = 1, 65 do over_range[index] = "capability-" .. index .. ".v1" end
    assert_malformed_capabilities(over_range)
  end,

  test_requested_capability_order_is_digest_significant = function()
    local request = read_json(root .. "/valid-canonical-envelope.json").request
    request.requested_capabilities = { "browser.read-title.v1", "browser.capture-screenshot.v1" }
    request.canonical_request_sha256 = sha256(canonical_request_bytes(request))
    t.eq(contract.validate(request, sha256), request)

    request.requested_capabilities[1], request.requested_capabilities[2] = request.requested_capabilities[2], request.requested_capabilities[1]
    local ok, message = pcall(contract.validate, request, sha256)
    t.eq(ok, false)
    t.eq(error_facts.error_class_from_message(message), "digest-mismatch")
  end,

  test_digest_mutation_is_rejected = function()
    local request = read_json(root .. "/valid-canonical-envelope.json").request
    request.canonical_request_sha256 = string.rep("0", 64)
    local ok, message = pcall(contract.validate, request, sha256)
    t.eq(ok, false)
    t.eq(error_facts.error_class_from_message(message), "digest-mismatch")
  end,
}
