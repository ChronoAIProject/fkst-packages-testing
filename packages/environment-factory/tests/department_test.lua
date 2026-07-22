local core = require("core")
local dead_letter = require("departments.dead_letter.main")
local finalize = require("departments.finalize.main")
local handoff = require("departments.handoff.main")
local interrupt = require("departments.interrupt.main")
local seam = require("departments.seam.main")
local start = require("departments.start.main")
local testing = require("testkit.testing")
local t = fkst.test

local function includes(values, expected)
  for _, value in ipairs(values or {}) do if value == expected then return true end end
  return false
end

local function with_methods(methods, fn)
  local old = {}
  for name, value in pairs(methods) do old[name] = core[name]; core[name] = value end
  local ok, result = pcall(fn)
  for name, value in pairs(old) do core[name] = value end
  if not ok then error(result, 0) end
  return result
end

return {
  test_start_department_emits_pending_check_or_terminal_result = function()
    with_methods({
      start = function(payload)
        if payload.mode == "pending" then
          return { readiness_check = { schema = "browser-readiness.check.v1" } }
        end
        return { result = { schema = "environment-factory.result.v1", status = "blocked" } }
      end,
    }, function()
      local trace = testing.run_fake(start, {
        queue = "environment_start", payload = { mode = "pending" },
      })
      t.eq(#trace.raises, 1)
      t.eq(trace.raises[1].queue, "browser-readiness.browser_readiness_check")
      trace = testing.run_fake(start, {
        queue = "environment_start", payload = { mode = "blocked" },
      })
      t.eq(#trace.raises, 1)
      t.eq(trace.raises[1].queue, "environment_result")
    end)
    with_methods({ start = function() return {} end }, function()
      t.raises(function()
        testing.run_fake(start, { queue = "environment_start", payload = {} })
      end)
    end)
    t.is_true(includes(start.spec.produces, "environment_result"))
    t.is_true(includes(start.spec.produces, "browser-readiness.browser_readiness_check"))
  end,

  test_handoff_department_publishes_only_environment_results = function()
    with_methods({
      handle_browser_readiness = function(payload)
        return { result = {
          schema = "environment-factory.result.v1",
          status = payload.status,
        } }
      end,
    }, function()
      for _, status in ipairs({ "ready", "blocked" }) do
        local trace = testing.run_fake(handoff, {
          queue = "browser-readiness.browser_readiness_result",
          payload = {
            status = status,
            source_ref = { kind = "artifact", ref = ".testing/runs/x/operation-state.json" },
          },
        })
        t.eq(#trace.raises, 1)
        t.eq(trace.raises[1].queue, "environment_result")
        t.eq(trace.raises[1].payload.status, status)
      end
    end)
    with_methods({ handle_browser_readiness = function() return {} end }, function()
      t.raises(function()
        testing.run_fake(handoff, {
          queue = "browser-readiness.browser_readiness_result",
          payload = { source_ref = { kind = "artifact", ref = ".testing/runs/x/operation-state.json" } },
        })
      end)
    end)
    t.is_true(includes(handoff.spec.consumes, "browser-readiness.browser_readiness_result"))
    t.eq(#handoff.spec.produces, 1)
    t.eq(handoff.spec.produces[1], "environment_result")
  end,

  test_finalize_and_interrupt_departments_publish_results = function()
    with_methods({ finalize = function() return { schema = "environment-factory.result.v1", status = "finalized" } end }, function()
      local trace = testing.run_fake(finalize, { queue = "environment_finalize", payload = {} })
      t.eq(trace.raises[1].queue, "environment_result")
    end)
    with_methods({ interrupt = function() return { schema = "environment-factory.result.v1", status = "cancelled" } end }, function()
      local trace = testing.run_fake(interrupt, { queue = "environment_interrupt", payload = {} })
      t.eq(trace.raises[1].queue, "environment_result")
    end)
    t.is_true(includes(interrupt.spec.consumes, "environment_interrupt"))
  end,

  test_dead_letter_department_is_registered = function()
    t.is_true(includes(dead_letter.spec.consumes, "dead_letter"))
    t.eq(#dead_letter.spec.produces, 0)
  end,

  test_seam_accepts_control_tick_without_creating_lifecycle_events = function()
    local trace = testing.run_fake(seam, { queue = "environment_control_tick", payload = {} })
    t.eq(#trace.raises, 0)
    t.is_true(includes(seam.spec.produces, "environment_start"))
    t.is_true(includes(seam.spec.produces, "environment_finalize"))
    t.is_true(includes(seam.spec.produces, "environment_interrupt"))
  end,
}
