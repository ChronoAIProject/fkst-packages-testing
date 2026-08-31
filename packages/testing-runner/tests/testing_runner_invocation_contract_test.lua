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
    local canonical_json = require("contract.canonical_json")
    local function canonical_copy(value, omit_digest)
      if type(value) ~= "table" then return value end
      local numeric, count, highest = true, 0, 0
      for key in pairs(value) do if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then numeric = false; break end; count = count + 1; highest = math.max(highest, key) end
      if numeric and count == highest then local copy = {}; for index = 1, highest do copy[index] = canonical_copy(value[index], false) end; return canonical_json.array(copy) end
      local copy = {}; for key, item in pairs(value) do if not (omit_digest and key == "canonical_request_sha256") then copy[key] = canonical_copy(item, false) end end; return canonical_json.object(copy)
    end
    t.eq(sha256(canonical_json.encode(canonical_copy(fixture.request, true))), fixture.request.canonical_request_sha256)
  end,

  test_digest_mutation_is_rejected = function()
    local request = read_json(root .. "/valid-canonical-envelope.json").request
    request.canonical_request_sha256 = string.rep("0", 64)
    local ok, message = pcall(contract.validate, request, sha256)
    t.eq(ok, false)
    t.eq(error_facts.error_class_from_message(message), "digest-mismatch")
  end,
}
