local core = require("core")
local acknowledge = require("departments.acknowledge.main")
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
  test_start_department_ready_and_blocked_paths = function()
    with_methods({
      start = function(payload) return { schema = "environment-factory.result.v1", status = payload.status } end,
      browser_readiness_check = function() return { schema = "browser-readiness.check.v1" } end,
    }, function()
      local trace = testing.run_fake(start, { queue = "environment_start", payload = { status = "ready", operation_state_ref = { kind = "artifact", ref = ".testing/runs/x/operation-state.json" } } })
      t.eq(#trace.raises, 2)
      t.eq(trace.raises[1].queue, "environment_result")
      t.eq(trace.raises[2].queue, "browser-readiness.browser_readiness_check")
      trace = testing.run_fake(start, { queue = "environment_start", payload = { status = "blocked" } })
      t.eq(#trace.raises, 1)
    end)
    t.is_true(includes(start.spec.produces, "environment_result"))
  end,

  test_handoff_department_ready_blocked_and_dedup_paths = function()
    with_methods({
      handle_browser_readiness = function(payload)
        if payload.mode == "ready" or payload.mode == "redelivery" then
          return { module_start = { schema = "testing-pipeline.module-start.v1", dedup_key = "stable" }, redelivery = payload.mode == "redelivery" }
        end
        if payload.mode == "blocked" then return { result = { schema = "environment-factory.result.v1", status = "blocked" } } end
        return { acknowledged = true }
      end,
    }, function()
      local function event(mode)
        return { queue = "browser-readiness.browser_readiness_result", payload = { mode = mode, source_ref = { kind = "artifact", ref = ".testing/runs/x/operation-state.json" } } }
      end
      local trace = testing.run_fake(handoff, event("ready"))
      t.eq(trace.raises[1].queue, "testing-pipeline.module_start")
      trace = testing.run_fake(handoff, event("redelivery"))
      t.eq(trace.raises[1].queue, "testing-pipeline.module_start")
      t.eq(trace.raises[1].payload.dedup_key, "stable")
      trace = testing.run_fake(handoff, event("blocked"))
      t.eq(trace.raises[1].queue, "environment_result")
      trace = testing.run_fake(handoff, event("dedup"))
      t.eq(#trace.raises, 0)
    end)
    t.is_true(includes(handoff.spec.consumes, "browser-readiness.browser_readiness_result"))
  end,

  test_terminal_acknowledgement_department_marks_pending_outbox = function()
    with_methods({ acknowledge_testing_terminal = function() return { acknowledged = true } end }, function()
      local trace = testing.run_fake(acknowledge, {
        queue = "test-publication.publication_request",
        payload = { source_ref = { kind = "artifact", ref = ".testing/runs/x/environment-receipt-ready.json" } },
      })
      t.eq(#trace.raises, 0)
    end)
    t.is_true(includes(acknowledge.spec.consumes, "test-publication.publication_request"))
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
