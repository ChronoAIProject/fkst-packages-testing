local t = fkst.test

return {
  test_fire_raiser_keepalive_routes_to_seam = function()
    local trace = t.fire_raiser("keepalive")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "testing-pipeline.keepalive")
    t.eq(trace.routed_to[1], "testing-pipeline.seam")
    t.eq(trace.consumer_result.status, "accepted")
    t.eq(#trace.raised, 0)
  end,
}
