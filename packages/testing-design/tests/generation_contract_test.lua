local contract = require("contract.testing_design_generation")
local json = require("testing_runtime.json")
local t = fkst.test

local fixture_root = "packages/testing-design/tests/fixtures/generation/v1/"

local function load(name)
  local handle = assert(io.open(fixture_root .. name .. ".json", "rb"))
  local body = handle:read("*a")
  handle:close()
  return json.decode(body)
end

local function assert_classification(expected, callback)
  local ok, message = pcall(callback)
  t.eq(ok, false, "expected validation failure")
  t.eq(tostring(message):find(":" .. expected .. ":", 1, true) ~= nil, true, "expected " .. expected .. ", got " .. tostring(message))
end

return {
  test_validates_traceable_browser_title_candidate_and_receipt = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    local receipt = load("valid-receipt")
    t.eq(contract.validate_request(request), request)
    t.eq(contract.validate_candidate_set(candidate_set, request), candidate_set)
    t.eq(contract.validate_receipt(receipt, request, candidate_set), receipt)
    t.eq(contract.canonical_digest(request), "cb410d00e97011ba14e43996037e4fac6ad4b9aee29ae83058697dd8ba48cf6e")
    t.eq(contract.canonical_digest(candidate_set), "684935a71f8e7f7ac25f8de2681e6910223c158ae9c73b8a172e188da9605930")
    t.eq(contract.canonical_bytes(request), contract.canonical_bytes(request))
    t.eq(contract.canonical_bytes(candidate_set), contract.canonical_bytes(candidate_set))
  end,

  test_rejects_forbidden_action_field_and_unsupported_candidate_statuses = function()
    local request = load("valid-request")
    assert_classification("malformed-action", function() contract.validate_candidate_set(load("invalid-candidate-script"), request) end)
    assert_classification("unsupported-candidate-set-status", function() contract.validate_candidate_set(load("invalid-candidate-set-status"), request) end)
    assert_classification("unsupported-candidate-status", function() contract.validate_candidate_set(load("invalid-candidate-status"), request) end)
  end,

  test_rejects_every_unsupported_receipt_outcome = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    for _, outcome in ipairs({ "partial", "rejected", "budget-exhausted", "provider-error" }) do
      assert_classification("unsupported-outcome", function()
        contract.validate_receipt(load("invalid-receipt-outcome-" .. outcome), request, candidate_set)
      end)
    end
  end,

  test_enforces_cross_document_bindings = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    candidate_set.request_digest = string.rep("0", 64)
    assert_classification("foreign-request-digest", function() contract.validate_candidate_set(candidate_set, request) end)

    candidate_set = load("valid-candidate-set")
    candidate_set.candidates[1].steps[1].action.catalog_version = "2.0.0"
    assert_classification("unsupported-action", function() contract.validate_candidate_set(candidate_set, request) end)

    candidate_set = load("valid-candidate-set")
    candidate_set.candidates[1].traceability.source_refs[1].sha256 = string.rep("0", 64)
    assert_classification("foreign-traceability", function() contract.validate_candidate_set(candidate_set, request) end)

    local receipt = load("valid-receipt")
    receipt.budget.prompt_bytes = request.policy.max_prompt_bytes + 1
    assert_classification("budget-exceeded", function() contract.validate_receipt(receipt, request, load("valid-candidate-set")) end)
  end,
}
