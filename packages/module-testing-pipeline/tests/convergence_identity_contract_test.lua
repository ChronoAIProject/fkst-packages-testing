local identity = require("contract.convergence_identity")
local t = fkst.test

local function expect_error(fragment, fn)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find(fragment, 1, true) ~= nil)
end

return {
  test_from_parts_validates_required_fields_and_integer_counters = function()
    expect_error("missing role", function()
      identity.from_parts(nil, "proposal-1", "dedup-1", { angle_lane = "teleology" })
    end)
    expect_error("invalid generation", function()
      identity.from_parts("reviewer", "proposal-1", "dedup-1", {
        angle_lane = "teleology",
        generation = -1,
      })
    end)
  end,

  test_from_proposal_validates_shape_and_builds_convergence_dedup_key = function()
    expect_error("missing proposal", function()
      identity.from_proposal("reviewer", nil, { angle_lane = "teleology" })
    end)

    local value = identity.from_proposal("reviewer", {
      proposal_id = "proposal-1",
      generation = 2,
      round = 3,
    }, {
      angle_lane = "fidelity",
    })

    t.eq(value.role, "reviewer")
    t.eq(value.proposal_id, "proposal-1")
    t.eq(value.generation, 2)
    t.eq(value.round, 3)
    t.eq(value.angle_lane, "fidelity")
    t.eq(value.dedup_key, "convergence:reviewer:proposal-1:g2:r3:fidelity")
    t.eq(value.process.role, "reviewer")
    t.eq(value.process.proposal_id, "proposal-1")
  end,
}
