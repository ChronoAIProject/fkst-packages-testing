local M = {}

local strings = require("contract.strings")

M.version = "coverage-matrix/v1"

local max_string = 512
local max_id = 180
local max_cases = 32
local max_items = 16

local input_fields = { policy = true, cases = true }
local policy_fields = {
  policy_id = true,
  required_case_trace_kinds = true,
  required_assertion_trace_kinds = true,
  positive_risk_case_quota = true,
  positive_risk_reference = true,
}
local case_fields = {
  case_id = true,
  intent = true,
  target = true,
  preconditions = true,
  actions = true,
  assertions = true,
  trace_references = true,
  source = true,
}
local action_fields = { action = true, target = true, expected = true }
local assertion_fields = { expected = true, trace_references = true }
local reference_fields = { kind = true, ref = true }
local source_fields = {
  source_id = true,
  candidate_position = true,
  round = true,
  presentation_order = true,
}

local function bounded_string(value, limit)
  return type(value) == "string"
    and value ~= ""
    and #value <= (limit or max_string)
    and value:find("[%z\1-\31]") == nil
end

local function dense_list(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return false end
    count = count + 1
  end
  return count == #value
end

local function only_fields(value, allowed, context)
  if type(value) ~= "table" then error(context .. " must be a table") end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then error(context .. " contains unsupported field: " .. tostring(key)) end
  end
end

local function copy_string_list(value, context, allow_empty)
  if not dense_list(value) or #value > max_items or (not allow_empty and #value == 0) then error(context .. " must be a bounded dense list") end
  local copy = {}
  for _, item in ipairs(value) do
    if not bounded_string(item, max_string) then error(context .. " items must be bounded strings") end
    table.insert(copy, item)
  end
  return copy
end

local function copy_reference(value, context)
  only_fields(value, reference_fields, context)
  if not bounded_string(value.kind, 80) or not bounded_string(value.ref, max_string) then error(context .. " requires bounded kind and ref") end
  return { kind = value.kind, ref = value.ref }
end

local function copy_references(value, context)
  if not dense_list(value) or #value > max_items then error(context .. " must be a bounded dense list") end
  local copy = {}
  for index, reference in ipairs(value) do
    table.insert(copy, copy_reference(reference, context .. "[" .. tostring(index) .. "]"))
  end
  return copy
end

local function copy_source(value, context)
  only_fields(value, source_fields, context)
  if not bounded_string(value.source_id, max_id) then error(context .. ".source_id is required") end
  local copy = { source_id = value.source_id }
  for _, field in ipairs({ "candidate_position", "round", "presentation_order" }) do
    local item = value[field]
    if item ~= nil then
      if type(item) ~= "number" or item < 0 or math.floor(item) ~= item then error(context .. "." .. field .. " must be a non-negative integer") end
      copy[field] = item
    end
  end
  return copy
end

local function copy_case(value, context)
  only_fields(value, case_fields, context)
  if not bounded_string(value.case_id, max_id) then error(context .. ".case_id is required") end
  if not bounded_string(value.intent, max_string) then error(context .. ".intent is required") end
  if not bounded_string(value.target, max_string) then error(context .. ".target is required") end
  local actions = {}
  if not dense_list(value.actions) or #value.actions == 0 or #value.actions > max_items then error(context .. ".actions must be a non-empty bounded dense list") end
  for index, action in ipairs(value.actions) do
    local action_context = context .. ".actions[" .. tostring(index) .. "]"
    only_fields(action, action_fields, action_context)
    if not bounded_string(action.action, 80) or not bounded_string(action.target, max_string)
      or not bounded_string(action.expected, max_string) then error(action_context .. " requires bounded action, target, and expected") end
    table.insert(actions, { action = action.action, target = action.target, expected = action.expected })
  end
  local assertions = {}
  if not dense_list(value.assertions) or #value.assertions == 0 or #value.assertions > max_items then error(context .. ".assertions must be a non-empty bounded dense list") end
  for index, assertion in ipairs(value.assertions) do
    local assertion_context = context .. ".assertions[" .. tostring(index) .. "]"
    only_fields(assertion, assertion_fields, assertion_context)
    if not bounded_string(assertion.expected, max_string) then error(assertion_context .. ".expected is required") end
    table.insert(assertions, {
      expected = assertion.expected,
      trace_references = copy_references(assertion.trace_references, assertion_context .. ".trace_references"),
    })
  end
  return {
    case_id = value.case_id,
    intent = value.intent,
    target = value.target,
    preconditions = copy_string_list(value.preconditions, context .. ".preconditions", true),
    actions = actions,
    assertions = assertions,
    trace_references = copy_references(value.trace_references, context .. ".trace_references"),
    source = copy_source(value.source, context .. ".source"),
  }
end

local function parse_input(value)
  if value == nil then return nil end
  only_fields(value, input_fields, "testing-runner: malformed-coverage-input")
  only_fields(value.policy, policy_fields, "testing-runner: malformed-coverage-policy")
  local policy = value.policy
  if not bounded_string(policy.policy_id, max_id) then error("testing-runner: malformed-coverage-policy: policy_id is required") end
  local quota = policy.positive_risk_case_quota
  if type(quota) ~= "number" or quota < 0 or quota > max_cases or math.floor(quota) ~= quota then error("testing-runner: malformed-coverage-policy: positive_risk_case_quota must be an integer from 0 to 32") end
  local parsed_policy = {
    policy_id = policy.policy_id,
    required_case_trace_kinds = copy_string_list(policy.required_case_trace_kinds, "testing-runner: malformed-coverage-policy: required_case_trace_kinds", true),
    required_assertion_trace_kinds = copy_string_list(policy.required_assertion_trace_kinds, "testing-runner: malformed-coverage-policy: required_assertion_trace_kinds", true),
    positive_risk_case_quota = quota,
    positive_risk_reference = copy_reference(policy.positive_risk_reference, "testing-runner: malformed-coverage-policy: positive_risk_reference"),
  }
  table.sort(parsed_policy.required_case_trace_kinds)
  table.sort(parsed_policy.required_assertion_trace_kinds)
  if not dense_list(value.cases) or #value.cases == 0 or #value.cases > max_cases then error("testing-runner: malformed-coverage-input: cases must be a non-empty bounded dense list") end
  local cases, seen = {}, {}
  for index, item in ipairs(value.cases) do
    local parsed = copy_case(item, "testing-runner: malformed-coverage-input: cases[" .. tostring(index) .. "]")
    if seen[parsed.case_id] then error("testing-runner: malformed-coverage-input: duplicate case_id") end
    seen[parsed.case_id] = true
    table.insert(cases, parsed)
  end
  return { policy = parsed_policy, cases = cases }
end

local function normalize_text(value)
  return strings.trim(value):gsub("%s+", " "):lower()
end

local function canonical_meaning(value)
  local preconditions = {}
  for _, item in ipairs(value.preconditions) do table.insert(preconditions, normalize_text(item)) end
  table.sort(preconditions)
  local actions = {}
  for _, action in ipairs(value.actions) do
    table.insert(actions, {
      action = normalize_text(action.action),
      target = normalize_text(action.target),
      expected = normalize_text(action.expected),
    })
  end
  local assertions = {}
  for _, assertion in ipairs(value.assertions) do table.insert(assertions, normalize_text(assertion.expected)) end
  table.sort(assertions)
  return {
    intent = normalize_text(value.intent),
    target = normalize_text(value.target),
    preconditions = preconditions,
    actions = actions,
    assertions = assertions,
  }
end

local function semantic_seed(meaning)
  local parts = { meaning.intent, meaning.target }
  for _, item in ipairs(meaning.preconditions) do table.insert(parts, "precondition:" .. item) end
  for index, action in ipairs(meaning.actions) do
    table.insert(parts, table.concat({ "action", tostring(index), action.action, action.target, action.expected }, ":"))
  end
  for _, assertion in ipairs(meaning.assertions) do table.insert(parts, "assertion:" .. assertion) end
  local framed = {}
  for _, part in ipairs(parts) do table.insert(framed, tostring(#part) .. ":" .. part) end
  return table.concat(framed, "\31")
end

local function semantic_fingerprint(seed)
  return "semantic-v1-" .. strings.decimal_checksum(seed) .. "-" .. strings.decimal_checksum(seed:reverse())
end

local function reference_key(reference)
  return reference.kind .. "\31" .. reference.ref
end

local function merge_references(target, seen, references)
  for _, reference in ipairs(references) do
    local key = reference_key(reference)
    if not seen[key] then
      seen[key] = true
      table.insert(target, { kind = reference.kind, ref = reference.ref })
    end
  end
  table.sort(target, function(left, right)
    return left.kind == right.kind and left.ref < right.ref or left.kind < right.kind
  end)
end

local function copy_scalar_map(value)
  local copy = {}
  for key, item in pairs(value or {}) do
    if type(key) == "string" and (type(item) == "string" or type(item) == "number" or type(item) == "boolean") then
      copy[key] = item
    end
  end
  return next(copy) and copy or nil
end

local function source_provenance(plan_case, coverage_case)
  return {
    origin = plan_case.case_origin or "unknown",
    case_id = plan_case.id,
    source_id = coverage_case.source.source_id,
    candidate_position = coverage_case.source.candidate_position,
    round = coverage_case.source.round,
    presentation_order = coverage_case.source.presentation_order,
    generated = copy_scalar_map(plan_case.provenance),
  }
end

local function assertion_rows(value)
  local rows = {}
  for _, assertion in ipairs(value.assertions) do
    local expected = normalize_text(assertion.expected)
    local row = rows[expected]
    if row == nil then
      row = { expected = expected, trace_references = {}, _seen_references = {} }
      rows[expected] = row
    end
    merge_references(row.trace_references, row._seen_references, assertion.trace_references)
  end
  return rows
end

local function has_reference(references, kind, ref)
  for _, reference in ipairs(references or {}) do
    if reference.kind == kind and (ref == nil or reference.ref == ref) then return true end
  end
  return false
end

local function evaluate(cases, policy)
  local gaps, positive_risk_case_count = {}, 0
  for _, case in ipairs(cases) do
    for _, kind in ipairs(policy.required_case_trace_kinds) do
      if not has_reference(case.trace_references, kind) then
        table.insert(gaps, {
          code = "missing-case-trace-reference",
          scope = "case",
          semantic_fingerprint = case.semantic_fingerprint,
          reference_kind = kind,
        })
      end
    end
    for _, assertion in ipairs(case.assertions) do
      for _, kind in ipairs(policy.required_assertion_trace_kinds) do
        if not has_reference(assertion.trace_references, kind) then
          table.insert(gaps, {
            code = "missing-assertion-trace-reference",
            scope = "assertion",
            semantic_fingerprint = case.semantic_fingerprint,
            assertion = assertion.expected,
            reference_kind = kind,
          })
        end
      end
    end
    local positive = policy.positive_risk_reference
    if has_reference(case.trace_references, positive.kind, positive.ref) then
      positive_risk_case_count = positive_risk_case_count + 1
    end
  end
  if positive_risk_case_count < policy.positive_risk_case_quota then
    table.insert(gaps, {
      code = "positive-risk-case-quota-not-met",
      scope = "matrix",
      reference_kind = policy.positive_risk_reference.kind,
      reference_ref = policy.positive_risk_reference.ref,
      required = policy.positive_risk_case_quota,
      actual = positive_risk_case_count,
    })
  end
  return {
    complete = #gaps == 0,
    scope = "configured-policy",
    policy_id = policy.policy_id,
    evaluated_case_count = #cases,
    positive_risk_case_count = positive_risk_case_count,
    mandatory_gap_count = #gaps,
    gaps = gaps,
  }
end

function M.build(plan_modules, artifact_root, value)
  local parsed = parse_input(value)
  if parsed == nil then return nil end
  local case_index = {}
  for _, module in ipairs(plan_modules or {}) do
    for _, plan_case in ipairs(module.cases or {}) do
      if case_index[plan_case.id] ~= nil then error("testing-runner: malformed-coverage-input: case_id is ambiguous") end
      case_index[plan_case.id] = plan_case
    end
  end

  local entries = {}
  for _, coverage_case in ipairs(parsed.cases) do
    local plan_case = case_index[coverage_case.case_id]
    if plan_case == nil then error("testing-runner: malformed-coverage-input: case_id is not present in the test plan") end
    plan_case.coverage = coverage_case
    local meaning = canonical_meaning(coverage_case)
    local seed = semantic_seed(meaning)
    local fingerprint = semantic_fingerprint(seed)
    local entry = entries[fingerprint]
    if entry ~= nil and entry._semantic_seed ~= seed then error("testing-runner: coverage-fingerprint-collision: canonical meanings differ") end
    if entry == nil then
      entry = {
        semantic_fingerprint = fingerprint,
        intent = meaning.intent,
        target = meaning.target,
        preconditions = meaning.preconditions,
        actions = meaning.actions,
        assertions = {},
        trace_references = {},
        provenance = { sources = {}, source_count = 0 },
        _semantic_seed = seed,
        _seen_references = {},
        _assertions = {},
      }
      entries[fingerprint] = entry
    end
    merge_references(entry.trace_references, entry._seen_references, coverage_case.trace_references)
    local assertions = assertion_rows(coverage_case)
    for expected, assertion in pairs(assertions) do
      local target = entry._assertions[expected]
      if target == nil then
        target = { expected = expected, trace_references = {}, _seen_references = {} }
        entry._assertions[expected] = target
      end
      merge_references(target.trace_references, target._seen_references, assertion.trace_references)
    end
    table.insert(entry.provenance.sources, source_provenance(plan_case, coverage_case))
    entry.provenance.source_count = #entry.provenance.sources
  end

  local cases = {}
  for _, entry in pairs(entries) do
    for _, assertion in pairs(entry._assertions) do
      assertion._seen_references = nil
      table.insert(entry.assertions, assertion)
    end
    table.sort(entry.assertions, function(left, right) return left.expected < right.expected end)
    table.sort(entry.provenance.sources, function(left, right)
      local left_key = tostring(left.origin) .. "\31" .. tostring(left.source_id) .. "\31" .. tostring(left.case_id)
      local right_key = tostring(right.origin) .. "\31" .. tostring(right.source_id) .. "\31" .. tostring(right.case_id)
      return left_key < right_key
    end)
    entry._semantic_seed = nil
    entry._seen_references = nil
    entry._assertions = nil
    table.insert(cases, entry)
  end
  table.sort(cases, function(left, right) return left.semantic_fingerprint < right.semantic_fingerprint end)

  return {
    version = M.version,
    artifact_kind = "coverage-matrix",
    artifact_root = artifact_root,
    coverage_matrix_path = artifact_root .. "/coverage-matrix.json",
    policy = parsed.policy,
    input_case_count = #parsed.cases,
    unique_case_count = #cases,
    cases = cases,
    decision = evaluate(cases, parsed.policy),
  }
end

return M
