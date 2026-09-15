local contract = require("contract.testing_design_generation")

local F = {}

local function copy(value)
  return json.decode(contract.canonical_bytes(value))
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
