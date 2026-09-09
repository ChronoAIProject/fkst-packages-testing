local contract = require("contract.testing_design_generation")
local canonical_json = require("contract.canonical_json")
local error_facts = require("contract.error_facts")
local host_json = json
local t = fkst.test

local fixture_root = "packages/testing-design/tests/fixtures/generation/v1/"

local function load(name)
  local handle = assert(io.open(fixture_root .. name .. ".json", "rb"))
  local body = handle:read("*a")
  handle:close()
  return host_json.decode(body)
end

local function assert_classification(expected, callback)
  local ok, message = pcall(callback)
  t.eq(ok, false, "expected validation failure")
  t.eq(error_facts.error_class_from_message(message), expected, "expected " .. expected .. ", got " .. tostring(message))
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

  test_canonicalizes_host_containers_without_mutating_them = function()
    local value = host_json.decode('{"z":{},"a":[{},[],{"b":false,"a":0}],"empty":[]}')
    local array_tag, object_tag = getmetatable(value.a), getmetatable(value.z)
    t.eq(array_tag ~= object_tag, true, "host decoder must distinguish arrays from objects")
    local expected = '{"a":[{},[],{"a":0,"b":false}],"empty":[],"z":{}}\n'
    t.eq(contract.canonical_bytes(value), expected)
    t.eq(contract.canonical_bytes(value), expected)
    t.eq(getmetatable(value.a), array_tag)
    t.eq(getmetatable(value.z), object_tag)
    t.eq(getmetatable(value.a[2]), array_tag)
    t.eq(contract.canonical_bytes(host_json.decode("[]")), "[]\n")
    t.eq(contract.canonical_bytes(host_json.decode("{}")), "{}\n")
    t.eq(contract.canonical_bytes({ items = canonical_json.array(), object = canonical_json.object() }), '{"items":[],"object":{}}\n')
    t.eq(contract.canonical_bytes({ items = { 1, false, "value" } }), '{"items":[1,false,"value"]}\n')
  end,

  test_pinned_host_array_marker_is_protected_and_canonical_tags_are_not = function()
    local array = host_json.decode("[]")
    t.eq(getmetatable(array), false)
    t.eq(getmetatable(host_json.decode("{}")), nil)
    t.eq(pcall(setmetatable, array, nil), false)
    for _, value in ipairs({ host_json.decode("{}"), canonical_json.array(), canonical_json.object() }) do
      local tag = getmetatable(value)
      local ok, result = pcall(setmetatable, value, tag)
      t.eq(ok, true, "supported tags must permit same-tag assignment: " .. tostring(result))
      t.eq(rawequal(result, value), true)
      t.eq(rawequal(getmetatable(value), tag), true)
      t.eq(next(value), nil)
    end
  end,

  test_rejects_protected_host_array_tag_spoof_without_running_metamethods = function()
    local calls = 0
    local tag = getmetatable(host_json.decode("[]"))
    local value = setmetatable({ unknown = "preserve-me" }, {
      __metatable = tag,
      __pairs = function() calls = calls + 1; return next, {}, nil end,
    })
    t.eq(rawequal(getmetatable(value), tag), true, "spoof must expose the genuine host tag")
    t.eq(pcall(setmetatable, value, nil), false, "actual metatable must be protected")
    assert_classification("canonicalization-failed", function() contract.canonical_bytes({ nested = value }) end)
    t.eq(calls, 0)
    t.eq(rawget(value, "unknown"), "preserve-me")
    t.eq(pcall(setmetatable, value, nil), false, "rejection must not alter protection")
  end,

  test_canonical_tag_spoofs_cannot_erase_fields = function()
    for index, container in ipairs({ canonical_json.array(), canonical_json.object() }) do
      local calls = 0
      local tag = getmetatable(container)
      local value = setmetatable({ unknown = "preserve-me" }, {
        __metatable = tag,
        __pairs = function() calls = calls + 1; return next, {}, nil end,
      })
      if index == 1 then
        assert_classification("canonicalization-failed", function() contract.canonical_bytes(value) end)
      else
        t.eq(contract.canonical_bytes(value), '{"unknown":"preserve-me"}\n')
      end
      t.eq(calls, 0)
      t.eq(rawget(value, "unknown"), "preserve-me")
      t.eq(pcall(setmetatable, value, tag), false)
    end
  end,

  test_rejects_metatable_equality_spoof = function()
    local calls = 0
    local value = setmetatable({ unknown = "preserve-me" }, setmetatable({}, {
      __eq = function() calls = calls + 1; return true end,
    }))
    assert_classification("canonicalization-failed", function() contract.canonical_bytes(value) end)
    t.eq(calls, 0)
    t.eq(rawget(value, "unknown"), "preserve-me")
  end,

  test_raw_normalization_never_invokes_input_metamethods = function()
    local calls = 0
    local function hostile(value, tag)
      return setmetatable(value, {
        __metatable = tag,
        __pairs = function() calls = calls + 1; return next, {}, nil end,
        __index = function() calls = calls + 1; return "invented" end,
        __len = function() calls = calls + 1; return 999 end,
        __eq = function() calls = calls + 1; return true end,
      })
    end
    local host_tag = getmetatable(host_json.decode("[]"))
    local child = hostile({ field = "preserved" }, getmetatable(canonical_json.object()))
    local dense = hostile({ child, false }, host_tag)
    t.eq(contract.canonical_bytes(dense), '[{"field":"preserved"},false]\n')
    t.eq(contract.canonical_bytes(hostile({}, host_tag)), "[]\n")
    t.eq(rawequal(rawget(dense, 1), child), true)
    t.eq(rawget(child, "field"), "preserved")
    for _, value in ipairs({ hostile({ [2] = "hole" }, host_tag), hostile({ hidden = true }, host_tag), hostile({ 1, hidden = true }, host_tag) }) do
      assert_classification("canonicalization-failed", function() contract.canonical_bytes(value) end)
    end
    local cyclic = hostile({}, host_tag)
    rawset(cyclic, 1, cyclic)
    assert_classification("canonicalization-failed", function() contract.canonical_bytes(cyclic) end)
    for _, tag in ipairs({ true, "unsupported", 42, {} }) do
      assert_classification("canonicalization-failed", function() contract.canonical_bytes(hostile({}, tag)) end)
    end
    t.eq(calls, 0, "normalization must not invoke input metamethods")
  end,

  test_closed_and_dense_validation_reads_raw_fields = function()
    local calls = 0
    local function conceal(value)
      return setmetatable(value, {
        __pairs = function() calls = calls + 1; return next, {}, nil end,
        __index = function() calls = calls + 1; return "invented" end,
      })
    end
    local request = load("valid-request")
    request.repository = conceal({ unknown = "preserve-me" })
    assert_classification("malformed-request", function() contract.validate_request(request) end)
    request.repository = conceal({})
    assert_classification("malformed-request", function() contract.validate_request(request) end)
    local candidate_set = load("valid-candidate-set")
    candidate_set.candidates[1].preconditions = conceal({ [2] = {} })
    assert_classification("malformed-candidate", function() contract.validate_candidate_set(candidate_set, load("valid-request")) end)
    t.eq(calls, 0)
  end,

  test_keeps_canonicalization_fail_closed = function()
    for _, body in ipairs({ "null", '[null]', '{"field":null}', '{"nested":[{"field":null}]}' }) do
      assert_classification("canonicalization-failed", function() contract.canonical_bytes(host_json.decode(body)) end)
    end
    for _, value in ipairs({ canonical_json.null, { field = canonical_json.null }, { [1] = "a", [3] = "c" }, { [1] = "a", field = "b" } }) do
      assert_classification("canonicalization-failed", function() contract.canonical_bytes(value) end)
    end
    assert_classification("canonicalization-failed", function() contract.canonical_bytes(nil) end)
    local cyclic = host_json.decode("[]")
    cyclic[1] = cyclic
    assert_classification("canonicalization-failed", function() contract.canonical_bytes(cyclic) end)
    local unsupported = setmetatable({}, { __index = { hidden = true } })
    assert_classification("canonicalization-failed", function() contract.canonical_bytes({ nested = unsupported }) end)
    assert_classification("canonicalization-failed", function() canonical_json.encode(host_json.decode("[]")) end)
  end,

  test_empty_arrays_validate_but_objects_and_null_do_not = function()
    local request = load("valid-request")
    for _, key in ipairs({ "preconditions", "evidence_requirements" }) do
      local candidate_set = load("valid-candidate-set")
      candidate_set.candidates[1][key] = host_json.decode("[]")
      t.eq(contract.validate_candidate_set(candidate_set, request), candidate_set)
      for _, body in ipairs({ "{}", "null" }) do
        candidate_set.candidates[1][key] = host_json.decode(body)
        assert_classification("malformed-candidate", function() contract.validate_candidate_set(candidate_set, request) end)
      end
    end
    for _, key in ipairs({ "journey_refs", "risk_refs", "existing_test_refs" }) do
      for _, body in ipairs({ "{}", "null" }) do
        local candidate_set = load("valid-candidate-set")
        candidate_set.candidates[1].traceability[key] = host_json.decode(body)
        assert_classification("invalid-traceability", function() contract.validate_candidate_set(candidate_set, request) end)
      end
    end
    for _, body in ipairs({ "{}", "null" }) do
      local receipt = load("valid-receipt")
      receipt.rejected_candidates.reasons = host_json.decode(body)
      assert_classification("malformed-receipt", function() contract.validate_receipt(receipt, request, load("valid-candidate-set")) end)
    end
  end,

  test_retains_unknown_fields_for_closed_document_validation = function()
    local request = load("valid-request")
    request.repository.unknown = host_json.decode("[]")
    t.eq(contract.canonical_bytes(request):find('"unknown":[]', 1, true) ~= nil, true)
    assert_classification("malformed-request", function() contract.validate_request(request) end)
    local candidate_set = load("valid-candidate-set")
    candidate_set.candidates[1].steps[1].action.unknown = host_json.decode("{}")
    t.eq(contract.canonical_bytes(candidate_set):find('"unknown":{}', 1, true) ~= nil, true)
    assert_classification("malformed-action", function() contract.validate_candidate_set(candidate_set, load("valid-request")) end)
  end,

  test_classifies_request_action_and_candidate_status_failures = function()
    local request = load("valid-request")
    request.schema = "testing-design.unknown-request.v1"
    assert_classification("unknown-schema", function() contract.validate_request(request) end)

    request = load("valid-request")
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
