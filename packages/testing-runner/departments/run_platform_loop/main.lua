local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "platform_test_request" },
  published_seam = { "platform_test_request" },
  produces = { "testing_result", "final_report_rendered" },
  stall_window = "60m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  if payload.schema == "testing-runner.final-aggregate-report-request.v1" then
    local rendered = core.render_final_aggregate(payload)
    log.info("testing-runner dept=run_platform_loop tag=RENDERED status=" .. tostring(rendered.status))
    raise("final_report_rendered", rendered)
    return
  end
  local result = core.run("platform", payload)
  log.info("testing-runner dept=run_platform_loop tag=" .. string.upper(result.status))
  raise("testing_result", result)
end

local M = saga.department(spec, { done = done, act = act, name = "run_platform_loop" })
M.pipeline = _G.pipeline
return M
