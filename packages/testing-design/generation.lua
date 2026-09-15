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
  if active[value] then error("testing-design: generation-outcome-cycle") end
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

function G.generate(request, supplied_ports, control)
  contract.validate_request(request)
  if control ~= nil then
    only_fields(control, { cancelled = true }, "control")
    if control.cancelled ~= nil and type(control.cancelled) ~= "boolean" then
      error("testing-design: malformed-generation-control: cancelled must be boolean")
    end
    if control.cancelled then return { ok = false, failure = { code = "cancellation" } } end
  end

  local outcome = ports_module.resolve_generation(supplied_ports).generate_candidates(copy(request), control)
  only_fields(outcome, { ok = true, candidate_set = true, failure = true }, "outcome")
  if outcome.ok == false and outcome.candidate_set == nil and outcome.failure ~= nil then
    return validate_failure(outcome.failure)
  end
  if outcome.ok ~= true or outcome.candidate_set == nil or outcome.failure ~= nil then
    error("testing-design: malformed-generation-outcome: invalid success/failure union")
  end
  local candidate_set = copy(outcome.candidate_set)
  if not pcall(contract.validate_candidate_set, candidate_set, request) then
    return { ok = false, failure = { code = "schema-mismatch" } }
  end
  return { ok = true, candidate_set = candidate_set }
end

return G
