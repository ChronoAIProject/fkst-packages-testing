local dept = require("departments.start.main")
local testing = require("testkit.testing")
local t = fkst.test

return {
  test_start_department_declares_and_raises_runner_request_contract = function()
    t.eq(#dept.spec.consumes, 1)
    t.eq(dept.spec.consumes[1], "module_loop_request")
    t.eq(#dept.spec.produces, 1)
    t.eq(dept.spec.produces[1], "testing-runner.module_test_request")

    local readiness = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      request_context = {
        native_argv = { "fixture-check", "module-a" },
        dry_run = false,
        no_browser = true,
      },
    }
    local source_ref = { kind = "host-module", ref = "module-a" }
    local trace = testing.run_fake(dept, {
      queue = "module_loop_request",
      payload = {
        schema = "module-test-loop.start.v1",
        module = "module-a",
        backend = "fkst-native",
        preflight_result = readiness,
        artifact_root = ".testing/runs/module-a",
        source_ref = source_ref,
        trace_id = "trace-module-a",
        dedup_key = "dedup-module-a",
      },
    })

    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "testing-runner.module_test_request")
    local request = trace.raises[1].payload
    t.eq(request.schema, "testing-runner.module-test-loop.request.v1")
    t.eq(request.module, "module-a")
    t.eq(request.backend, "fkst-native")
    t.eq(request.native_argv[1], "fixture-check")
    t.eq(request.native_argv[2], "module-a")
    t.eq(request.dry_run, false)
    t.eq(request.no_browser, true)
    t.eq(request.preflight_result, readiness)
    t.eq(request.artifact_root, ".testing/runs/module-a")
    t.eq(request.source_ref, source_ref)
    t.eq(request.trace_id, "trace-module-a")
    t.eq(request.dedup_key, "dedup-module-a")
  end,

  test_start_department_rejects_malformed_input_without_raising_success = function()
    local trace = testing.run_fake_expecting_failure(dept, {
      queue = "module_loop_request",
      payload = { schema = "module-test-loop.start.v1" },
    })
    t.eq(#trace.raises, 0)
    t.is_true(tostring(trace.failure.error):find("module is required", 1, true) ~= nil)
  end,
}
