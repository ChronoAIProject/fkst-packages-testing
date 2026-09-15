local contract = require("contract.testing_design_generation")
local ports_module = require("ports")

local G = {}

local function malformed(message)
  error("testing-design: malformed-generation-outcome: " .. message)
end

local function only_fields(value, allowed, label)
  if type(value) ~= "table" then malformed(label .. " must be a table") end
  for key in next, value do
    if type(key) ~= "string" or not allowed[key] then
      malformed("unsupported " .. label .. " field")
    end
  end
end

local function failure(code)
  return { ok = false, failure = { code = code } }
end

local function validate_failure(value)
  only_fields(value, { code = true }, "failure")
  if not contract.generation_failure_codes[value.code] then malformed("unsupported failure code") end
  return failure(value.code)
end

local function bounded(value, limit)
  return type(value) == "string" and #value >= 1 and #value <= limit
    and value:find("[%z\1-\31\127]") == nil
end

local function validate_provider(value)
  only_fields(value, { adapter_id = true, adapter_version = true, model_id = true }, "provider")
  if not bounded(value.adapter_id, 180) or not bounded(value.model_id, 180)
      or not bounded(value.adapter_version, 64)
      or not value.adapter_version:match("^%d+%.%d+%.%d+$") then
    malformed("invalid provider")
  end
  return contract.canonical_copy(value)
end

local function validate_prompt_template(value, request)
  only_fields(value, { template_id = true, template_version = true, template_digest = true }, "prompt_template")
  for _, key in ipairs({ "template_id", "template_version", "template_digest" }) do
    if value[key] ~= request.prompt_template[key] then malformed("foreign prompt_template") end
  end
  return contract.canonical_copy(value)
end

local function validate_control(value)
  if value == nil then return false end
  only_fields(value, { cancelled = true }, "control")
  if value.cancelled ~= nil and type(value.cancelled) ~= "boolean" then
    error("testing-design: malformed-generation-control: cancelled must be boolean")
  end
  return value.cancelled == true
end

function G.generate(request, supplied_port, control)
  contract.validate_request(request)
  if validate_control(control) then return failure("cancellation") end

  local port = ports_module.resolve_generation(supplied_port)
  local outcome = port.generate(contract.canonical_copy(request))
  only_fields(outcome, {
    ok = true,
    failure = true,
    status = true,
    candidate_set = true,
    provider = true,
    prompt_template = true,
  }, "outcome")

  if outcome.ok == false and outcome.failure ~= nil and outcome.status == nil
      and outcome.candidate_set == nil and outcome.provider == nil and outcome.prompt_template == nil then
    return validate_failure(outcome.failure)
  end
  if outcome.ok ~= nil or outcome.failure ~= nil or outcome.status ~= "complete"
      or outcome.candidate_set == nil or outcome.provider == nil or outcome.prompt_template == nil then
    malformed("invalid success/failure union")
  end

  local valid, candidate_set = pcall(function()
    local snapshot = contract.canonical_copy(outcome.candidate_set)
    contract.validate_candidate_set(snapshot, request)
    return snapshot
  end)
  if not valid then return failure("schema-mismatch") end

  return {
    status = "complete",
    candidate_set = candidate_set,
    provider = validate_provider(outcome.provider),
    prompt_template = validate_prompt_template(outcome.prompt_template, request),
  }
end

return G
