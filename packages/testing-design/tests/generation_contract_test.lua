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

local function load_path(path)
  local handle = assert(io.open(path, "rb"))
  local body = handle:read("*a")
  handle:close()
  return host_json.decode(body)
end

local function assert_classification(expected, callback)
  local ok, message = pcall(callback)
  t.eq(ok, false, "expected validation failure")
  t.eq(error_facts.error_class_from_message(message), expected, "expected " .. expected .. ", got " .. tostring(message))
end

local function apply_case(document, case)
  local current = document
  for index = 1, #case.path - 1 do
    local segment = case.path[index]
    if type(segment) == "number" then segment = segment + 1 end
    current = current[segment]
  end
  local leaf = case.path[#case.path]
  if type(leaf) == "number" then leaf = leaf + 1 end
  if case.operation == "remove" then current[leaf] = nil else current[leaf] = case.value end
  return document
end

local function at_path(document, path)
  local current = document
  for _, segment in ipairs(path) do current = current[segment] end
  return current
end

local function collect_object_locations(schema, instance, path, locations)
  if schema.type == "object" and type(instance) == "table" then
    locations[#locations + 1] = { path = path, schema = schema }
    for key, child_schema in pairs(schema.properties or {}) do
      if instance[key] ~= nil then
        local child_path = {}
        for index, segment in ipairs(path) do child_path[index] = segment end
        child_path[#child_path + 1] = key
        collect_object_locations(child_schema, instance[key], child_path, locations)
      end
    end
  elseif schema.type == "array" and type(instance) == "table" and instance[1] ~= nil then
    local child_path = {}
    for index, segment in ipairs(path) do child_path[index] = segment end
    child_path[#child_path + 1] = 1
    collect_object_locations(schema.items, instance[1], child_path, locations)
  end
end

local function expected_object_class(document_name, path)
  if document_name == "request" then return "malformed-request" end
  if document_name == "receipt" then return "malformed-receipt" end
  for _, segment in ipairs(path) do
    if segment == "action" or segment == "target" then return "malformed-action" end
    if segment == "assertion" then return "malformed-assertion" end
    if segment == "traceability" or segment == "requirement_refs" or segment == "journey_refs" or segment == "risk_refs" or segment == "source_refs" or segment == "existing_test_refs" then return "invalid-traceability" end
  end
  for _, segment in ipairs(path) do if segment == "candidates" then return "malformed-candidate" end end
  return "malformed-candidate-set"
end

local function validate_document(document_name, document, request, candidate_set)
  if document_name == "request" then return contract.validate_request(document) end
  if document_name == "candidate_set" then return contract.validate_candidate_set(document, request) end
  return contract.validate_receipt(document, request, candidate_set)
end

local function clone(value)
  return host_json.decode(contract.canonical_bytes(value))
end

local matrix_output_digest
local function matrix_context()
  local request, candidate_set, receipt = load("valid-request"), load("valid-candidate-set"), load("valid-receipt")
  local trace = candidate_set.candidates[1].traceability
  for _, key in ipairs({ "journey_refs", "risk_refs" }) do trace[key] = clone(trace.requirement_refs) end
  trace.existing_test_refs = { { kind = "artifact", ref = request.existing_test_inventory.artifact_pointer, sha256 = request.existing_test_inventory.artifact_digest } }
  matrix_output_digest = matrix_output_digest or contract.canonical_digest(candidate_set)
  receipt.validated_output_digest, receipt.candidate_set.artifact_digest = matrix_output_digest, matrix_output_digest
  receipt.rejected_candidates = { total = 1, reasons = { { code = "duplicate-candidate", count = 1 } } }
  return { request = request, candidate_set = candidate_set, receipt = receipt }
end

local function rebind_context(context)
  local request_digest = contract.canonical_digest(context.request)
  context.candidate_set.request_digest = request_digest
  context.receipt.request_digest, context.receipt.input_digest = request_digest, request_digest
  local output_digest = contract.canonical_digest(context.candidate_set)
  context.receipt.validated_output_digest, context.receipt.candidate_set.artifact_digest = output_digest, output_digest
end

local function string_samples(spec, controls)
  local prefix, maximum = spec.prefix or "", spec.max
  local samples = {
    { spec.minimum or prefix .. "x", true }, { prefix .. string.rep("x", maximum - #prefix), true },
    { "", false }, { prefix .. string.rep("x", maximum + 1 - #prefix), false },
    { prefix .. string.rep("界", math.floor((maximum - #prefix) / 3) + 1), false },
  }
  if not spec.ascii_only then samples[#samples + 1] = { prefix .. string.rep("界", math.floor((maximum - #prefix) / 3)) .. string.rep("x", (maximum - #prefix) % 3), true } end
  for _, code in ipairs(controls) do
    local control = string.char(code)
    for _, value in ipairs({ control .. prefix .. "x", prefix .. "x" .. control .. "x", prefix .. "x" .. control }) do samples[#samples + 1] = { value, false } end
  end
  return samples
end

local function check_matrix_value(spec, value, valid)
  local context = matrix_context()
  local document = context[spec.document]
  apply_case(document, { path = spec.path, operation = "set", value = value })
  if valid then
    for _, path in ipairs(spec.bindings or {}) do apply_case(context, { path = path, operation = "set", value = value }) end
    if spec.path[1] == "rejected_candidates" and spec.path[2] == "total" and value == 0 then context.receipt.rejected_candidates.reasons = canonical_json.array() end
    if spec.document ~= "request" then rebind_context(context) end
    t.eq(validate_document(spec.document, document, context.request, context.candidate_set), document)
  else
    assert_classification(spec.class, function() validate_document(spec.document, document, context.request, context.candidate_set) end)
  end
end

return {
  test_shared_string_boundaries_and_controls = function()
    local matrix = load("boundary-matrix")
    for _, spec in ipairs(matrix.strings) do
      for _, sample in ipairs(string_samples(spec, matrix.controls)) do check_matrix_value(spec, sample[1], sample[2]) end
    end
    for _, spec in ipairs(matrix.unsafe) do
      for _, value in ipairs(spec.values) do check_matrix_value(spec, value, false) end
    end
  end,

  test_shared_fixed_string_controls_and_hex_shapes = function()
    local matrix = load("boundary-matrix")
    for _, spec in ipairs(matrix.fixed_strings) do
      local samples = { "" }
      for _, code in ipairs(matrix.controls) do
        local control = string.char(code)
        samples[#samples + 1] = control .. spec.value
        samples[#samples + 1] = spec.value:sub(1, 1) .. control .. spec.value:sub(2)
        samples[#samples + 1] = spec.value .. control
      end
      if spec.hex then
        for _, value in ipairs({ string.rep("a", spec.hex - 1), string.rep("a", spec.hex + 1), string.rep("A", spec.hex), string.rep("g", spec.hex) }) do samples[#samples + 1] = value end
      end
      for _, value in ipairs(samples) do check_matrix_value(spec, value, false) end
    end
  end,

  test_rejects_invalid_utf8_and_preserves_scalar_boundaries = function()
    local invalid = { string.char(0x80), string.char(0xc0, 0xaf), string.char(0xe0, 0x80, 0xaf), string.char(0xed, 0xa0, 0x80), string.char(0xf4, 0x90, 0x80, 0x80), string.char(0xf0, 0x90) }
    for _, value in ipairs(invalid) do
      local request = load("valid-request")
      request.trace_id = value
      assert_classification("malformed-request", function() contract.validate_request(request) end)
      assert_classification("canonicalization-failed", function() contract.canonical_bytes({ value = value }) end)
    end
    for _, value in ipairs({ "é", "界", string.char(0xf0, 0x90, 0x80, 0x80), string.char(0xf4, 0x8f, 0xbf, 0xbf) }) do
      local request = load("valid-request")
      request.trace_id = value
      t.eq(contract.validate_request(request), request)
      t.eq(contract.canonical_bytes({ value = value }), '{"value":"' .. value .. '"}\n')
    end
  end,

  test_canonical_utf8_order_escaping_and_integer_rejections = function()
    local value = { ["界"] = true, ["é"] = false, a = { "second", "first" }, escape = "\"\\\n\1\127/" }
    local expected = '{"a":["second","first"],"escape":"\\"\\\\\\n\\u0001' .. string.char(127) .. '/","é":false,"界":true}\n'
    t.eq(contract.canonical_bytes(value), expected)
    t.eq(contract.canonical_bytes(value), expected)
    t.eq(value.a[1], "second")
    t.eq(value.escape, "\"\\\n\1\127/")
    for _, number in ipairs({ 1.5, 1.0, math.huge, -math.huge, 0 / 0 }) do
      assert_classification("canonicalization-failed", function() contract.canonical_bytes({ value = number }) end)
    end
    assert_classification("canonicalization-failed", function() contract.canonical_bytes({ [true] = "invalid" }) end)
  end,

  test_shared_unicode_scalar_representatives = function()
    local matrix = load("boundary-matrix")
    for _, spec in ipairs(matrix.strings) do
      for _, sample in ipairs(matrix.unicode_scalars) do
        local parts = { spec.prefix or "" }
        for _, code in ipairs(sample.codepoints) do parts[#parts + 1] = utf8.char(code) end
        check_matrix_value(spec, table.concat(parts), sample.valid and not spec.ascii_only)
      end
    end
  end,

  test_shared_timestamp_separator_and_worktree_grammar = function()
    for _, spec in ipairs(load("boundary-matrix").formats) do
      for _, sample in ipairs(spec.values) do check_matrix_value(spec, sample.value, sample.valid) end
    end
  end,

  test_shared_integer_boundaries = function()
    for _, spec in ipairs(load("boundary-matrix").integers) do
      for _, value in ipairs({ spec.min, spec.max }) do check_matrix_value(spec, value, true) end
      for _, value in ipairs({ spec.min - 1, spec.max + 1, 1.5, "1", true }) do check_matrix_value(spec, value, false) end
    end
  end,

  test_shared_candidate_and_step_length_boundaries = function()
    for _, spec in ipairs(load("boundary-matrix").arrays) do
      for _, size in ipairs({ 0, 1, spec.maximum, spec.maximum + 1 }) do
        local context = matrix_context()
        context.request.policy[spec.policy] = spec.maximum
        local values = canonical_json.array()
        for index = 1, size do
          local item = clone(spec.policy == "max_candidates" and context.candidate_set.candidates[1] or context.candidate_set.candidates[1].steps[1])
          if spec.policy == "max_candidates" then item.candidate_id = "candidate-" .. index
          else item.step_id = "step-" .. index end
          values[index] = item
        end
        apply_case(context.candidate_set, { path = spec.path, operation = "set", value = values })
        rebind_context(context)
        local validate = function() return contract.validate_candidate_set(context.candidate_set, context.request) end
        if size >= 1 and size <= spec.maximum then
          t.eq(validate(), context.candidate_set)
          if size > 1 then
            context.request.policy[spec.policy] = size - 1
            rebind_context(context)
            assert_classification(spec.class, validate)
          end
        else assert_classification(spec.class, validate) end
      end
      local context = matrix_context()
      context.request.policy[spec.policy] = 2
      local item = spec.policy == "max_candidates" and context.candidate_set.candidates[1] or context.candidate_set.candidates[1].steps[1]
      apply_case(context.candidate_set, { path = spec.path, operation = "set", value = { item, clone(item) } })
      rebind_context(context)
      assert_classification(spec.policy == "max_candidates" and "duplicate-candidate-id" or "duplicate-step-id", function()
        contract.validate_candidate_set(context.candidate_set, context.request)
      end)
    end
  end,

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

  test_classifies_request_and_action_failures = function()
    local request = load("valid-request")
    request.schema = "testing-design.unknown-request.v1"
    assert_classification("unknown-schema", function() contract.validate_request(request) end)

    request = load("valid-request")
    assert_classification("malformed-action", function() contract.validate_candidate_set(load("invalid-candidate-script"), request) end)
  end,

  test_accepts_supported_candidate_statuses_without_inventing_equality = function()
    local request = load("valid-request")
    local rejected_set = load("valid-candidate-set-status-rejected")
    local rejected_candidate = load("valid-candidate-status-rejected")
    t.eq(contract.validate_candidate_set(rejected_set, request), rejected_set)
    t.eq(contract.validate_candidate_set(rejected_candidate, request), rejected_candidate)

    local receipt = load("valid-receipt")
    local output_digest = contract.canonical_digest(rejected_candidate)
    receipt.validated_output_digest, receipt.candidate_set.artifact_digest = output_digest, output_digest
    t.eq(contract.validate_receipt(receipt, request, rejected_candidate), receipt)
  end,

  test_accepts_supported_receipt_outcomes_and_rejected_sets = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    local rejected_set = load("valid-candidate-set-status-rejected")
    for _, outcome in ipairs({ "partial", "rejected", "budget-exhausted", "provider-error" }) do
      local receipt = load("valid-receipt-outcome-" .. outcome)
      t.eq(contract.validate_receipt(receipt, request, candidate_set), receipt)

      receipt = load("valid-receipt-outcome-" .. outcome)
      local output_digest = contract.canonical_digest(rejected_set)
      receipt.validated_output_digest, receipt.candidate_set.artifact_digest = output_digest, output_digest
      t.eq(contract.validate_receipt(receipt, request, rejected_set), receipt)
    end

    local receipt = load("valid-receipt")
    local output_digest = contract.canonical_digest(rejected_set)
    receipt.validated_output_digest, receipt.candidate_set.artifact_digest = output_digest, output_digest
    assert_classification("unsupported-outcome", function() contract.validate_receipt(receipt, request, rejected_set) end)
  end,

  test_non_complete_outcomes_retain_common_invariants = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    for _, outcome in ipairs({ "partial", "rejected", "budget-exhausted", "provider-error" }) do
      local receipt = load("valid-receipt-outcome-" .. outcome)
      receipt.unknown = true
      assert_classification("malformed-receipt", function() contract.validate_receipt(receipt, request, candidate_set) end)

      receipt = load("valid-receipt-outcome-" .. outcome)
      receipt.validated_output_digest = string.rep("0", 64)
      assert_classification("foreign-candidate-digest", function() contract.validate_receipt(receipt, request, candidate_set) end)

      receipt = load("valid-receipt-outcome-" .. outcome)
      receipt.budget.prompt_bytes = request.policy.max_prompt_bytes + 1
      assert_classification("budget-exceeded", function() contract.validate_receipt(receipt, request, candidate_set) end)

      receipt = load("valid-receipt-outcome-" .. outcome)
      receipt.timing.duration_ms = receipt.budget.elapsed_ms + 1
      assert_classification("malformed-timing", function() contract.validate_receipt(receipt, request, candidate_set) end)

      local invalid_candidate_set = load("valid-candidate-set")
      invalid_candidate_set.candidates[1].traceability.source_refs[1].sha256 = string.rep("0", 64)
      receipt = load("valid-receipt-outcome-" .. outcome)
      assert_classification("foreign-traceability", function() contract.validate_receipt(receipt, request, invalid_candidate_set) end)
    end

    local receipt = load("valid-receipt-outcome-rejected")
    receipt.rejected_candidates = { total = 2, reasons = { { code = "duplicate-candidate", count = 1 } } }
    assert_classification("malformed-receipt", function() contract.validate_receipt(receipt, request, candidate_set) end)
  end,

  test_validates_rejected_candidate_reason_counts = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    local receipt = load("valid-receipt")
    local reason_codes = { "duplicate-candidate", "unsupported-action", "unsupported-assertion", "invalid-traceability", "oversized-value", "malformed-candidate" }
    receipt.rejected_candidates = { total = #reason_codes, reasons = {} }
    for _, code in ipairs(reason_codes) do receipt.rejected_candidates.reasons[#receipt.rejected_candidates.reasons + 1] = { code = code, count = 1 } end
    t.eq(contract.validate_receipt(receipt, request, candidate_set), receipt)
    receipt.rejected_candidates.total = #reason_codes - 1
    assert_classification("malformed-receipt", function() contract.validate_receipt(receipt, request, candidate_set) end)

    for _, reasons in ipairs({
      { { code = "unknown-reason", count = 1 } },
      { { code = "duplicate-candidate", count = 1 }, { code = "duplicate-candidate", count = 1 } },
      { { code = "duplicate-candidate", count = 0 } },
      { { code = "duplicate-candidate", count = 65 } },
      { { code = "duplicate-candidate", count = 1.5 } },
      { { code = "duplicate-candidate", count = "1" } },
      { { code = "duplicate-candidate" } },
      { { code = "duplicate-candidate", count = 1, unknown = true } },
    }) do
      receipt = load("valid-receipt")
      receipt.rejected_candidates = { total = 1, reasons = reasons }
      assert_classification("malformed-receipt", function() contract.validate_receipt(receipt, request, candidate_set) end)
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

  test_accepts_leap_day_and_equal_timestamps_with_subsecond_duration = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    local receipt = load("valid-receipt")
    receipt.timing.started_at = "2024-02-29T23:59:59Z"
    receipt.timing.finished_at = "2024-02-29T23:59:59Z"
    receipt.timing.duration_ms = 25
    receipt.budget.elapsed_ms = 25
    t.eq(contract.validate_receipt(receipt, request, candidate_set), receipt)
  end,

  test_rejects_shared_generation_contract_cases = function()
    local corpus = load("rejection-cases")
    for _, case in ipairs(corpus.cases) do
      local request = load("valid-request")
      local candidate_set = load("valid-candidate-set")
      local receipt = load("valid-receipt")
      local document = ({ request = request, candidate_set = candidate_set, receipt = receipt })[case.document]
      apply_case(document, case)
      assert_classification(case.lua_class, function()
        validate_document(case.document, document, request, candidate_set)
      end)
    end
  end,

  test_rejects_every_missing_and_unknown_object_field = function()
    local definitions = {
      request = "testing-design.generate-request.v1",
      candidate_set = "testing-design.candidate-test-case-set.v1",
      receipt = "testing-design.generation-receipt.v1",
    }
    for document_name, identity in pairs(definitions) do
      local schema = load_path("schemas-next-release/" .. identity .. ".schema.json")
      local base = matrix_context()[document_name]
      local locations = {}
      collect_object_locations(schema, base, {}, locations)
      for _, location in ipairs(locations) do
        local expected = expected_object_class(document_name, location.path)
        local context = matrix_context()
        local document = context[document_name]
        at_path(document, location.path).unknown = true
        assert_classification(expected, function()
          validate_document(document_name, document, context.request, context.candidate_set)
        end)
        for _, field in ipairs(location.schema.required or {}) do
          context = matrix_context()
          document = context[document_name]
          at_path(document, location.path)[field] = nil
          assert_classification(expected, function()
            validate_document(document_name, document, context.request, context.candidate_set)
          end)
        end
      end
    end
  end,
}
