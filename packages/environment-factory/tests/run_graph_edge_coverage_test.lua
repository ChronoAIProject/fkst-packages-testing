local graph = require("testkit.graph")
local runtime_ports = require("ports")
local t = fkst.test

local suffix = tostring(os.tmpname()):match("([^/]+)$"):gsub("[^%w%-]", "-")
local state_root = ".testing/runs/environment-graph-" .. suffix
local state_path = state_root .. "/operation-state.json"

local function cleanup_state()
  os.remove(state_path)
  os.remove(state_root)
end

return {
  test_browser_readiness_result_routes_but_plain_state_fails_closed = function()
    local ok = os.execute("mkdir -p '" .. state_root .. "'")
    t.is_true(ok == true or ok == 0)
    local handle = assert(io.open(state_path, "w"))
    handle:write(runtime_ports.encode_json({ schema = "environment-factory.operation-state.v1" }))
    handle:write("\n")
    handle:close()

    local trace = graph.run({
      queue = "browser-readiness.browser_readiness_result",
      source_ref = { kind = "external", reference = "environment-graph-readiness" },
      payload = {
        schema = "browser-readiness.result.v1",
        status = "ready",
        sessions = { {
          role = "browser", status = "ready",
          checks = { { name = "cdp_url", status = "ready" } },
          cdp_url = "http://127.0.0.1:9222",
        } },
        source_ref = { kind = "artifact", ref = state_path },
        request_context = { dry_run = false },
        correlation = {
          schema = "environment-factory.browser-readiness-correlation.v1",
          attempt_id = "graph-attempt",
          operation_id = "environment-graph",
          operation_state_ref = { kind = "artifact", ref = state_path },
          readiness_attempt_ref = {
            kind = "artifact",
            ref = state_root .. "/readiness-attempts/graph-attempt.json",
          },
          readiness_attempt_sha256 = string.rep("a", 64),
          base_url = "http://127.0.0.1:4312/health",
          sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
          trace_id = "trace-environment-graph",
          dedup_key = "dedup-environment-graph",
        },
      },
    }, { max_steps = 4 })

    graph.assert_covers(trace, {
      "browser-readiness.browser_readiness_result -> environment-factory.handoff",
    })
    local step = graph.require_delivery(trace, {
      queue = "browser-readiness.browser_readiness_result",
      consumer = "environment-factory.handoff",
    })
    t.eq(step.status, "error")
    t.is_true(tostring(step.error):find("runtime-config-unavailable", 1, true) ~= nil)
    cleanup_state()
  end,
}
