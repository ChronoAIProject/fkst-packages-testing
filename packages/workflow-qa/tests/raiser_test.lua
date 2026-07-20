local t = fkst.test

local function fire_raiser_child(body) return body end
local _trace_fixture = fire_raiser_child([[
return {
  test_qa_poll_routes_only_to_workflow_qa_seam = function()
    local trace = t.fire_raiser("qa_poll")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "workflow-qa.qa_poll")
    t.eq(trace.routed_to[1], "workflow-qa.seam")
    t.eq(trace.consumer_result.status, "accepted")
    t.eq(#trace.raised, 0)
  end,
}
]])

return {
  test_qa_poll_raiser_shape = function()
    local raiser = require("raisers.qa_poll")
    t.eq(raiser.type, "cron")
    t.eq(raiser.interval, "5m")
    t.eq(raiser.produces, "workflow_qa_tick")
  end,
}
