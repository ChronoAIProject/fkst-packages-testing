local module_dept = require("departments.run_module_loop.main")
local online_dept = require("departments.run_online_regression.main")
local platform_dept = require("departments.run_platform_loop.main")
local testing = require("testkit.testing")
local t = fkst.test

local function artifact_writer()
  return true
end

local function assert_department_contract(dept, input_queue)
  t.eq(#dept.spec.consumes, 1)
  t.eq(dept.spec.consumes[1], input_queue)
  t.eq(#dept.spec.produces, 1)
  t.eq(dept.spec.produces[1], "testing_result")
end

local function assert_identity(result, expected)
  t.eq(result.schema, "testing-runner.result.v1")
  t.eq(result.job, expected.job)
  t.eq(result.status, expected.status)
  t.eq(result.artifact_root, expected.artifact_root)
  t.eq(result.source_ref.kind, expected.source_kind)
  t.eq(result.source_ref.ref, expected.source_ref)
  t.eq(result.trace_id, expected.trace_id)
  t.eq(result.dedup_key, expected.dedup_key)
end

return {
  test_run_module_loop_department_raises_executed_module_result = function()
    assert_department_contract(module_dept, "module_test_request")
    local trace = testing.run_fake(module_dept, {
      queue = "module_test_request",
      payload = {
        schema = "testing-runner.module-test-loop.request.v1",
        module = "module-a",
        backend = "fkst-native",
        dry_run = false,
        no_browser = true,
        native_argv = { "fixture-check", "module-a" },
        artifact_root = ".testing/runs/module-department",
        source_ref = { kind = "module-source", ref = "module-a" },
        trace_id = "trace-module-department",
        dedup_key = "dedup-module-department",
        artifact_writer = artifact_writer,
        probe = {
          run_argv = function(argv)
            t.eq(argv[1], "fixture-check")
            t.eq(argv[2], "module-a")
            return { exit_code = 0, stderr = "" }
          end,
        },
      },
    })

    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "testing_result")
    local result = trace.raises[1].payload
    assert_identity(result, {
      job = "module-test-loop",
      status = "passed",
      artifact_root = ".testing/runs/module-department",
      source_kind = "module-source",
      source_ref = "module-a",
      trace_id = "trace-module-department",
      dedup_key = "dedup-module-department",
    })
    t.eq(result.exit_code, 0)
    t.eq(result.adapter.mode, "module-no-browser")
    t.eq(result.native_summary.schema, "testing-runner.module-no-browser-summary.v1")
    t.eq(result.native_summary.module, "module-a")
    t.eq(result.native_summary.status, "passed")
    t.eq(result.native_summary.mode, "argv")
  end,

  test_run_platform_loop_department_raises_planned_platform_result = function()
    assert_department_contract(platform_dept, "platform_test_request")
    local trace = testing.run_fake(platform_dept, {
      queue = "platform_test_request",
      payload = {
        schema = "testing-runner.platform-test-loop.request.v1",
        modules = { "module-a", "module-b" },
        backend = "fkst-native",
        artifact_root = ".testing/runs/platform-department",
        source_ref = { kind = "platform-source", ref = "platform-request" },
        trace_id = "trace-platform-department",
        dedup_key = "dedup-platform-department",
        artifact_writer = artifact_writer,
      },
    })

    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "testing_result")
    local result = trace.raises[1].payload
    assert_identity(result, {
      job = "platform-test-loop",
      status = "planned",
      artifact_root = ".testing/runs/platform-department",
      source_kind = "platform-source",
      source_ref = "platform-request",
      trace_id = "trace-platform-department",
      dedup_key = "dedup-platform-department",
    })
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "planning-envelope")
  end,

  test_run_online_regression_department_raises_executed_heartbeat_result = function()
    assert_department_contract(online_dept, "online_regression_request")
    local trace = testing.run_fake(online_dept, {
      queue = "online_regression_request",
      payload = {
        schema = "testing-runner.online-regression.request.v1",
        backend = "fkst-native",
        no_browser = true,
        dry_run = false,
        heartbeat_url = "http://localhost:4312/health?request=fixture",
        artifact_root = ".testing/runs/online-department",
        source_ref = { kind = "online-source", ref = "heartbeat-request" },
        trace_id = "trace-online-department",
        dedup_key = "dedup-online-department",
        artifact_writer = artifact_writer,
        probe = {
          http_ready = function(url)
            t.eq(url, "http://localhost:4312/health?request=fixture")
            return true
          end,
        },
      },
    })

    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "testing_result")
    local result = trace.raises[1].payload
    assert_identity(result, {
      job = "online-regression",
      status = "passed",
      artifact_root = ".testing/runs/online-department",
      source_kind = "online-source",
      source_ref = "heartbeat-request",
      trace_id = "trace-online-department",
      dedup_key = "dedup-online-department",
    })
    t.eq(result.exit_code, 0)
    t.eq(result.adapter.mode, "online-heartbeat")
    t.eq(result.native_summary.schema, "testing-runner.online-heartbeat-summary.v1")
    t.eq(result.native_summary.target, "http://localhost:4312/health")
    t.eq(result.native_summary.status, "passed")
    t.eq(result.native_summary.mode, "no-browser-http")
  end,

  test_execution_departments_reject_malformed_input_without_raising_success = function()
    for _, fixture in ipairs({
      { dept = module_dept, queue = "module_test_request" },
      { dept = platform_dept, queue = "platform_test_request" },
      { dept = online_dept, queue = "online_regression_request" },
    }) do
      local trace = testing.run_fake_expecting_failure(fixture.dept, {
        queue = fixture.queue,
        payload = {},
      })
      t.eq(#trace.raises, 0)
      t.is_true(tostring(trace.failure.error):find("unknown-schema", 1, true) ~= nil)
    end
  end,
}
