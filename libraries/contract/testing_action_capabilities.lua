-- contract.testing_action_capabilities: authoritative executable browser-action definitions.
local C = {}

local max_string = 512

local definitions = {
  click = {
    action_kind = "click",
    target_requirements = {
      type = "dom-target",
      locator = "css-selector",
      required = true,
    },
    preconditions = {
      "target-present",
      "target-visible",
      "target-enabled",
      "expected-observation-absent",
    },
    observation_requirements = {
      type = "visible-dom-target",
      target_required = true,
    },
    evidence_requirements = {
      "action",
      "resolved_target",
      "observed_post_action_state",
    },
    runtime_handler = "cdp.click",
  },
}

local function fail(classification, message)
  error("contract.testing-action-capabilities: " .. classification .. ": " .. message)
end

local function bounded(value)
  return type(value) == "string"
    and value ~= ""
    and #value <= max_string
    and value:find("[%z\1-\31]") == nil
end

local function only_fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, context .. " must be a table") end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then fail("malformed-" .. context, "unsupported field " .. tostring(key)) end
  end
end

local function copy_list(value)
  local out = {}
  for _, item in ipairs(value or {}) do table.insert(out, item) end
  return out
end

local function copy_definition(value)
  if value == nil then return nil end
  return {
    action_kind = value.action_kind,
    target_requirements = {
      type = value.target_requirements.type,
      locator = value.target_requirements.locator,
      required = value.target_requirements.required,
    },
    preconditions = copy_list(value.preconditions),
    observation_requirements = {
      type = value.observation_requirements.type,
      target_required = value.observation_requirements.target_required,
    },
    evidence_requirements = copy_list(value.evidence_requirements),
    runtime_handler = value.runtime_handler,
  }
end

function C.get(action_kind)
  return copy_definition(definitions[action_kind])
end

function C.require(action_kind)
  local definition = C.get(action_kind)
  if definition == nil then fail("unregistered-action", tostring(action_kind)) end
  return definition
end

function C.is_registered(action_kind)
  return definitions[action_kind] ~= nil
end

function C.registered_kinds()
  local kinds = {}
  for action_kind, _ in pairs(definitions) do table.insert(kinds, action_kind) end
  table.sort(kinds)
  return kinds
end

function C.validate_target(value, context, requirements)
  context = context or "dom-target"
  requirements = requirements or definitions.click.target_requirements
  if requirements.type ~= "dom-target" or requirements.locator ~= "css-selector" then
    fail("invalid-registry", context .. " requirements are unsupported")
  end
  if requirements.required == true and value == nil then fail("malformed-target", context .. " is required") end
  only_fields(value, { type = true, selector = true }, context)
  if value.type ~= requirements.locator then
    fail("unsupported-target", context .. ".type must be " .. requirements.locator)
  end
  if not bounded(value.selector) then fail("malformed-target", context .. ".selector must be a bounded string") end
  return {
    type = "css-selector",
    selector = value.selector,
  }
end

function C.validate_expected(value, context, definition)
  context = context or "expected-observation"
  definition = definition or definitions.click
  local requirements = definition.observation_requirements
  only_fields(value, { type = true, target = true }, context)
  if value.type ~= requirements.type then
    fail("unsupported-observation", context .. ".type must be " .. requirements.type)
  end
  if requirements.target_required == true and value.target == nil then
    fail("malformed-observation", context .. ".target is required")
  end
  return {
    type = requirements.type,
    target = C.validate_target(value.target, context .. ".target", definition.target_requirements),
  }
end

function C.validate_action(value)
  if type(value) ~= "table" then fail("malformed-action", "action must be a table") end
  local definition = definitions[value.action]
  if definition == nil then fail("unregistered-action", tostring(value.action)) end
  return {
    action = definition.action_kind,
    target = C.validate_target(value.target, "action.target", definition.target_requirements),
    expected = C.validate_expected(value.expected, "action.expected", definition),
  }
end

function C.validate_resolved_target(value, context)
  context = context or "resolved-target"
  only_fields(value, {
    type = true,
    selector = true,
    node_name = true,
    node_id = true,
  }, context)
  local target = C.validate_target({ type = value.type, selector = value.selector }, context)
  if not bounded(value.node_name) then fail("malformed-resolved-target", context .. ".node_name is required") end
  if value.node_id ~= nil and not bounded(value.node_id) then
    fail("malformed-resolved-target", context .. ".node_id must be bounded")
  end
  target.node_name = value.node_name
  if value.node_id ~= nil then target.node_id = value.node_id end
  return target
end

function C.validate_observed_post_action_state(value, context)
  context = context or "observed-post-action-state"
  local definition = definitions.click
  only_fields(value, {
    type = true,
    target = true,
    visible = true,
    text = true,
    was_visible_before = true,
  }, context)
  if value.type ~= definition.observation_requirements.type then
    fail("unsupported-observation", context .. ".type must be " .. definition.observation_requirements.type)
  end
  if value.visible ~= true then fail("postcondition-failed", context .. ".visible must be true") end
  if value.was_visible_before ~= false then
    fail("causality-unproven", context .. ".was_visible_before must be false")
  end
  if not bounded(value.text) then fail("malformed-observation", context .. ".text is required") end
  return {
    type = definition.observation_requirements.type,
    target = C.validate_target(value.target, context .. ".target", definition.target_requirements),
    visible = true,
    text = value.text,
    was_visible_before = false,
  }
end

function C.same_list(actual, expected)
  if type(actual) ~= "table" or #actual ~= #expected then return false end
  local count = 0
  for key, _ in pairs(actual) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
  end
  if count ~= #expected then return false end
  for index, value in ipairs(expected) do
    if actual[index] ~= value then return false end
  end
  return true
end

function C.classify_error(value)
  local text = tostring(value or "")
  if text:find("contract.testing-action-capabilities: unregistered-action:", 1, true) ~= nil then
    return "unregistered-action"
  end
  return nil
end

return C
