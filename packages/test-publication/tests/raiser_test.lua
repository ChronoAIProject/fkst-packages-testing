local t = fkst.test
local seam = require("departments.seam.main")
local testing = require("testkit.testing")

local function fire_raiser_child(body)
  return body
end

local _trace_fixture = fire_raiser_child([[
return {
  test_seam_keepalive_trace = function()
    local trace = t.fire_raiser("seam_keepalive")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "test-publication.seam_keepalive")
    t.eq(trace.routed_to[1], "test-publication.seam")
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
    t.eq(raiser.produces, "qa_publication_tick")
  end,

  test_seam_department_accepts_keepalive_without_effects = function()
    local trace = testing.run_fake(seam, { queue = "qa_publication_tick", payload = {} })
    t.eq(#trace.raises, 0)
  end,
}
