local dept = require("departments.check_readiness.main")
local testing = require("testkit.testing")
local t = fkst.test

local function ready_probe()
  return {
    env = function(name)
      t.eq(name, "FIXTURE_CDP_ENDPOINT")
      return "http://127.0.0.1:9222/json/version"
    end,
    command_exists = function(command)
      t.eq(command, "fixture-browser-harness")
      return true
    end,
    local_http_ready = function(url)
      t.eq(url, "http://localhost:4312/")
      return true
    end,
  }
end

return {
  test_check_readiness_department_declares_and_raises_readiness_contract = function()
    t.eq(#dept.spec.consumes, 1)
    t.eq(dept.spec.consumes[1], "browser_readiness_check")
    t.eq(#dept.spec.produces, 1)
    t.eq(dept.spec.produces[1], "browser_readiness_result")

    local request_context = {
      native_argv = { "fixture-check", "module-a" },
      dry_run = false,
      no_browser = true,
    }
    local trace = testing.run_fake(dept, {
      queue = "browser_readiness_check",
      payload = {
        schema = "browser-readiness.check.v1",
        base_url = "http://localhost:4312/",
        sessions = {
          { role = "operator", browser_harness_command = "fixture-browser-harness" },
          { role = "observer", cdp_endpoint_env = "FIXTURE_CDP_ENDPOINT" },
        },
        source_ref = { kind = "host-readiness", ref = "readiness-request" },
        request_context = request_context,
      },
      test_probe = ready_probe(),
    })

    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "browser_readiness_result")
    local result = trace.raises[1].payload
    t.eq(result.schema, "browser-readiness.result.v1")
    t.eq(result.status, "ready")
    t.eq(#result.sessions, 3)
    t.eq(result.sessions[1].role, "base_url")
    t.eq(result.sessions[2].role, "operator")
    t.eq(result.sessions[3].role, "observer")
    t.eq(result.source_ref.kind, "host-readiness")
    t.eq(result.source_ref.ref, "readiness-request")
    t.eq(result.request_context, request_context)
  end,

  test_check_readiness_department_rejects_malformed_input_without_raising_success = function()
    local trace = testing.run_fake_expecting_failure(dept, {
      queue = "browser_readiness_check",
      payload = { schema = "browser-readiness.check.v1", sessions = {} },
    })
    t.eq(#trace.raises, 0)
    t.is_true(tostring(trace.failure.error):find("sessions must be", 1, true) ~= nil)
  end,
}
