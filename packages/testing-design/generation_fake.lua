local contract = require("contract.testing_design_generation")

local F = {}

function F.new(outcome)
  local snapshot = contract.canonical_copy(outcome)
  return {
    generate = function()
      return contract.canonical_copy(snapshot)
    end,
  }
end

return F
