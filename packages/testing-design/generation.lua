local contract = require("contract.testing_design_generation")
local ports_module = require("ports")

local G = {}

local failure_codes = {
  refusal = true,
  ["malformed-output"] = true,
  ["schema-mismatch"] = true,
  timeout = true,
  cancellation = true,
  ["nonzero-exit"] = true,
  ["unavailable-binary"] = true,
  truncation = true,
  ["budget-exhausted"] = true,
}

local function copy(value, active)
  if type(value) ~= "table" then return value end
  active = active or {}
  if active[value] then error("testing-design: generation-outcome-cycle: cycle detected") end
  active[value] = true
  local result = {}
  for key, item in next, value do result[copy(key, active)] = copy(item, active) end
  active[value] = nil
  return result
end

local function only_fields(value, allowed, label)
  if type(value) ~= "table" then error("testing-design: malformed-generation-outcome: " .. label .. " must be a table") end
  for key in next, value do
    if type(key) ~= "string" or not allowed[key] then
      error("testing-design: malformed-generation-outcome: unsupported " .. label .. " field")
    end
  end
end

local function validate_failure(value)
  only_fields(value, { code = true }, "failure")
  if not failure_codes[value.code] then
    error("testing-design: malformed-generation-outcome: unsupported failure code")
  end
  return { ok = false, failure = { code = value.code } }
end

local function bounded(value, limit)
  return type(value) == "string" and #value > 0 and #value <= limit and value:find("[%z\1-\31\127]") == nil
end

local function validate_provider(value)
  only_fields(value, { adapter_id = true, adapter_version = true, model_id = true }, "provider")
  if not bounded(value.adapter_id, 180) or not bounded(value.model_id, 180)
      or not bounded(value.adapter_version, 64)
      or not value.adapter_version:match("^%d+%.%d+%.%d+[%w%.%-]*$") then
    error("testing-design: malformed-generation-outcome: invalid provider")
  end
  return copy(value)
end

local function validate_prompt_template(value, request)
  only_fields(value, { template_id = true, template_version = true, template_digest = true }, "prompt_template")
  for _, key in ipairs({ "template_id", "template_version", "template_digest" }) do
    if value[key] ~= request.prompt_template[key] then
      error("testing-design: malformed-generation-outcome: foreign prompt_template")
    end
  end
  return copy(value)
end

function G.generate(request, supplied_ports, control)
  contract.validate_request(request)
  if control ~= nil then
    only_fields(control, { cancelled = true }, "control")
    if control.cancelled ~= nil and type(control.cancelled) ~= "boolean" then
      error("testing-design: malformed-generation-control: cancelled must be boolean")
    end
    if control.cancelled then return { ok = false, failure = { code = "cancellation" } } end
  end

  local outcome = ports_module.resolve_generation(supplied_ports).generate(copy(request), control)
  only_fields(outcome, {
    ok = true, failure = true, status = true, candidate_set = true,
    provider = true, prompt_template = true,
  }, "outcome")
  if outcome.ok == false and outcome.failure ~= nil and outcome.status == nil
      and outcome.candidate_set == nil and outcome.provider == nil and outcome.prompt_template == nil then
    return validate_failure(outcome.failure)
  end
  if outcome.ok ~= nil or outcome.failure ~= nil or outcome.status ~= "complete"
      or outcome.candidate_set == nil or outcome.provider == nil or outcome.prompt_template == nil then
    error("testing-design: malformed-generation-outcome: invalid success/failure union")
  end
  local candidate_set = copy(outcome.candidate_set)
  if not pcall(contract.validate_candidate_set, candidate_set, request) then
    return { ok = false, failure = { code = "schema-mismatch" } }
  end
  return {
    status = "complete",
    candidate_set = candidate_set,
    provider = validate_provider(outcome.provider),
    prompt_template = validate_prompt_template(outcome.prompt_template, request),
  }
end

return G
