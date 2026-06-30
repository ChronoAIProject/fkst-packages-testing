local t = fkst.test

return {
  test_seam_keepalive_routes_to_noop_seam = function()
    local trace = t.fire_raiser("seam_keepalive")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "seam_keepalive")
    t.eq(trace.routed_to[1], "seam")
    t.eq(trace.consumer_result.status, "accepted")
    t.eq(#trace.raised, 0)
  end,
}
