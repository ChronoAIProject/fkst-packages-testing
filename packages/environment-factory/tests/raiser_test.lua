local t = fkst.test

local function fire_raiser_child(body)
  return body
end

local _trace_fixture = fire_raiser_child([[
return {
  test_seam_keepalive_trace = function()
    local trace = t.fire_raiser("seam_keepalive")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "environment-factory.seam_keepalive")
    t.eq(trace.routed_to[1], "environment-factory.seam")
    t.eq(trace.consumer_result.status, "accepted")
    t.eq(#trace.raised, 0)
  end,
}
]])

return {
  test_seam_keepalive_cron_shape = function()
    local raiser = require("raisers.seam_keepalive")
    t.eq(raiser.type, "cron")
    t.eq(raiser.interval, "24h")
    t.eq(raiser.produces, "environment_control_tick")
  end,
}
