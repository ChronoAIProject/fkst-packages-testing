local contract = require("contract.testing_runner_invocation")
local error_facts = require("contract.error_facts")
local sha256 = require("tests.fixtures.sha256_helpers")
local conformance = require("tests.fixtures.conformance_runner_helpers")
local t = fkst.test
local root = "packages/testing-runner/tests/fixtures/testing-runner-invocation.v1"

local function read_json(path)
  if path:sub(-10) == "/index.json" then return conformance.index(root) end
  return conformance._read(path)
end

local function key_count(value)
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  return count
end

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, item in pairs(value) do copy[deep_copy(key)] = deep_copy(item) end
  return copy
end

local function deep_equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  if key_count(left) ~= key_count(right) then return false end
  for key, value in pairs(left) do
    if not deep_equal(value, right[key]) then return false end
  end
  return true
end

local function canonical_value_bytes(value, omit_digest)
  local canonical_json = require("contract.canonical_json")
  local function canonical_copy(item, omit)
    if type(item) ~= "table" then return item end
    local numeric, count, highest = true, 0, 0
    for key in pairs(item) do
      if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then numeric = false; break end
      count = count + 1
      highest = math.max(highest, key)
    end
    if numeric and count == highest then
      local copy = {}
      for index = 1, highest do copy[index] = canonical_copy(item[index], false) end
      return canonical_json.array(copy)
    end
    local copy = {}
    for key, child in pairs(item) do
      if not (omit and key == "canonical_request_sha256") then copy[key] = canonical_copy(child, false) end
    end
    return canonical_json.object(copy)
  end
  return canonical_json.encode(canonical_copy(value, omit_digest == true))
end

local function canonical_request_bytes(request)
  return canonical_value_bytes(request, true)
end

local function assert_malformed_capabilities(capabilities)
  local request = conformance.fixture(root, "valid-canonical-envelope").request
  request.requested_capabilities = capabilities
  local entries = {}
  for key, value in pairs(capabilities) do entries[#entries + 1] = { key = key, value = value } end
  local sha256_calls = 0
  local ok, message = pcall(contract.validate, request, function(bytes)
    sha256_calls = sha256_calls + 1
    return sha256(bytes)
  end)
  t.eq(ok, false)
  t.eq(error_facts.error_class_from_message(message), "malformed-list")
  t.eq(sha256_calls, 0)
  t.eq(request.requested_capabilities == capabilities, true)
  t.eq(key_count(capabilities), #entries)
  for _, entry in ipairs(entries) do t.eq(capabilities[entry.key], entry.value) end
end

local runtime_reasons = {
  "mapping-ambiguous", "mapping-missing", "unsupported-execution-profile",
  "unsupported-mapping", "capability-mismatch", "policy-mismatch",
  "lineage-mismatch", "lineage-rebuilt", "lineage-substituted", "stale-plan",
  "deadline-expired", "cancelled", "current-claim-unavailable",
  "current-claim-superseded", "replay-conflict",
}

return {
  test_shared_fixture_matrix = function()
    local index = conformance.index(root)
    t.eq(key_count(index), 2)
    t.eq(index.schema, "testing-runner-invocation-fixture-index.v1")
    t.eq(#index.cases, 164)
    t.eq(index.cases[1].name, "valid-canonical-envelope")

    local fixtures_by_name = {}
    for _, entry in ipairs(index.cases) do
      t.eq(key_count(entry), 2)
      t.eq(entry.file, entry.name .. ".json")
      local fixture = conformance.fixture(root, entry.name)
      fixtures_by_name[entry.name] = fixture
      t.eq(key_count(fixture), 5)
      t.eq(fixture.case, entry.name)
      t.eq(type(fixture.portable_valid), "boolean")
      t.eq(type(fixture.lua_valid), "boolean")
      t.eq(type(fixture.lua_error), "string")
      t.eq(fixture.lua_valid, fixture.lua_error == "")

      local request = fixture.request
      local before = deep_copy(request)
      local sha256_calls = 0
      local ok, result = pcall(contract.validate, request, function(bytes)
        sha256_calls = sha256_calls + 1
        return sha256(bytes)
      end)
      t.eq(ok, fixture.lua_valid)
      if fixture.lua_valid then
        t.eq(result == request, true)
        t.eq(sha256_calls, 1)
      else
        local actual_error = error_facts.error_class_from_message(result)
        t.eq(actual_error .. "@" .. entry.name, fixture.lua_error .. "@" .. entry.name)
        t.eq(sha256_calls, fixture.lua_error == "digest-mismatch" and 1 or 0)
      end
      t.eq(fixture.request == request, true)
      t.eq(deep_equal(request, before), true)
    end

    for _, name in ipairs({ "forbidden-worker-authority", "forbidden-credential-material" }) do
      local fixture = fixtures_by_name[name]
      t.eq(fixture ~= nil, true)
      t.eq(fixture.portable_valid, false)
      t.eq(fixture.lua_valid, false)
      t.eq(fixture.lua_error, "malformed-invocation")
    end

    local canonical = conformance.fixture(root, "valid-canonical-envelope").request
    t.eq(canonical.canonical_request_sha256, "e307a583193b235addb17935725e3c52fa125860b4f3fa340431b6e6d43e9066")
    t.eq(sha256(canonical_request_bytes(canonical)), canonical.canonical_request_sha256)
  end,

  test_runtime_outcome_sidecar_is_closed_and_non_normative = function()
    local sidecar = read_json(root .. "/runtime-outcomes.json")
    t.eq(key_count(sidecar), 2)
    t.eq(sidecar.schema, "testing-runner-invocation-runtime-outcomes.v1")
    t.eq(#sidecar.cases, #runtime_reasons)
    for index, expected_reason in ipairs(runtime_reasons) do
      local case = sidecar.cases[index]
      t.eq(key_count(case), 2)
      t.eq(case.runtime_reason, expected_reason)
      t.eq(case.name, "runtime-" .. expected_reason)
      local fixture = conformance.fixture(root, case.name)
      t.eq(fixture.portable_valid, true)
      t.eq(fixture.lua_valid, true)
      t.eq(fixture.lua_error, "")
    end
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
    local ordered = conformance.fixture(root, "valid-capabilities-ordered").request
    local reordered = conformance.fixture(root, "valid-capabilities-reordered").request
    t.eq(contract.validate(ordered, sha256), ordered)
    t.eq(contract.validate(reordered, sha256), reordered)
    t.eq(ordered.canonical_request_sha256 == reordered.canonical_request_sha256, false)

    reordered.requested_capabilities[1], reordered.requested_capabilities[2] = reordered.requested_capabilities[2], reordered.requested_capabilities[1]
    local ok, message = pcall(contract.validate, reordered, sha256)
    t.eq(ok, false)
    t.eq(error_facts.error_class_from_message(message), "digest-mismatch")
  end,

  test_sha256_callback_failures_are_distinct_and_non_mutating = function()
    for _, scenario in ipairs({
      { callback = nil, error_class = "missing-sha256" },
      { callback = true, error_class = "missing-sha256" },
      { callback = function() error("boom") end, error_class = "sha256-failed" },
    }) do
      local request = conformance.fixture(root, "valid-canonical-envelope").request
      local before = deep_copy(request)
      local ok, message = pcall(contract.validate, request, scenario.callback)
      t.eq(ok, false)
      t.eq(error_facts.error_class_from_message(message), scenario.error_class)
      t.eq(deep_equal(request, before), true)
    end
  end,
}
