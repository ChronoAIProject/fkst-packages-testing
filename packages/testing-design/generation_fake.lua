local F = {}

local function copy(value, active)
  if type(value) ~= "table" then return value end
  active = active or {}
  if active[value] then error("testing-design: fake-generation-outcome-cycle") end
  active[value] = true
  local result = {}
  for key, item in next, value do result[copy(key, active)] = copy(item, active) end
  active[value] = nil
  return result
end

function F.new(outcome)
  local snapshot = copy(outcome)
  return {
    generate = function()
      return copy(snapshot)
    end,
  }
end

return F
