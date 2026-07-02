local core = require("core")
local t = fkst.test

return {
  test_builds_testing_runner_request = function()
    local request = core.runner_request({
      schema = "module-test-loop.start.v1",
      module = "module-a",
      e2e_driver = "browser_harness",
      dry_run_github = true,
      backend = "fkst-native",
      native_argv = { "lua", "check.lua" },
      preflight_result = { status = "ready" },
      trace_id = "trace-module-a",
      dedup_key = "dedup-module-a",
    })
    t.eq(request.schema, "testing-runner.module-test-loop.request.v1")
    t.eq(request.module, "module-a")
    t.eq(request.e2e_driver, "browser_harness")
    t.eq(request.dry_run_github, true)
    t.eq(request.backend, "fkst-native")
    t.eq(request.native_argv[1], "lua")
    t.eq(request.native_argv[2], "check.lua")
    t.eq(request.preflight_result.status, "ready")
    t.eq(request.trace_id, "trace-module-a")
    t.eq(request.dedup_key, "dedup-module-a")
  end,

  test_live_browser_driver_shape_preserves_native_backend = function()
    local preflight = { schema = "browser-readiness.result.v1", status = "ready" }
    local request = core.runner_request({
      schema = "module-test-loop.start.v1",
      module = "sample_module",
      backend = "fkst-native",
      dry_run = false,
      e2e_driver = "multi_session_browser_harness",
      preflight_result = preflight,
    })
    t.eq(request.backend, "fkst-native")
    t.eq(request.dry_run, false)
    t.eq(request.e2e_driver, "multi_session_browser_harness")
    t.eq(request.no_browser, nil)
    t.eq(request.native_argv, nil)
    t.eq(request.preflight_result, preflight)
  end,

  test_readiness_context_flows_to_runner_request = function()
    local readiness = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      request_context = {
        native_argv = { "lua", "checks/module-a.lua" },
        dry_run = false,
        no_browser = true,
      },
    }
    local runner_request = core.runner_request({
      schema = "module-test-loop.start.v1",
      module = "module-a",
      backend = "fkst-native",
      preflight_result = readiness,
      artifact_root = ".testing/runs/module-a",
      source_ref = { kind = "module", ref = "module-a" },
    })
    t.eq(runner_request.native_argv[1], "lua")
    t.eq(runner_request.native_argv[2], "checks/module-a.lua")
    t.eq(runner_request.dry_run, false)
    t.eq(runner_request.no_browser, true)
    t.eq(runner_request.preflight_result, readiness)
  end,

  test_module_ui_loop_contract_flows_to_runner_request = function()
    local module_ui_loop = {
      schema = "testing-runner.module-ui-loop.request.v1",
      base_url = "http://localhost:3000/",
      allowed_origins = { "http://localhost:3000" },
      readiness_ref = { schema = "browser-readiness.result.v1", status = "ready" },
      artifact_root = ".testing/runs/module-a-ui",
      dry_run = false,
      priority = { "P0" },
      mutation_policy = "read_only",
      artifact_pointers = { ".testing/runs/module-a-ui/evidence-index.json" },
      gap_pointers = { ".testing/runs/module-a-ui/gaps.json" },
    }
    local runner_request = core.runner_request({
      schema = "module-test-loop.start.v1",
      module = "module-a",
      backend = "fkst-native",
      module_ui_loop = module_ui_loop,
    })
    t.eq(runner_request.backend, "fkst-native")
    t.eq(runner_request.module_ui_loop, module_ui_loop)
    t.eq(runner_request.module_ui_loop.priority[1], "P0")
    t.eq(runner_request.module_ui_loop.mutation_policy, "read_only")
  end,

  test_explicit_execution_context_overrides_readiness_context = function()
    local request = core.runner_request({
      schema = "module-test-loop.start.v1",
      module = "module-a",
      backend = "fkst-native",
      dry_run = true,
      no_browser = false,
      native_argv = { "lua", "checks/explicit.lua" },
      preflight_result = {
        schema = "browser-readiness.result.v1",
        status = "ready",
        request_context = {
          native_argv = { "lua", "checks/from-readiness.lua" },
          dry_run = false,
          no_browser = true,
        },
      },
    })
    t.eq(request.native_argv[2], "checks/explicit.lua")
    t.eq(request.dry_run, true)
    t.eq(request.no_browser, false)
  end,

  test_requires_module = function()
    t.raises(function()
      core.runner_request({ schema = "module-test-loop.start.v1" })
    end)
  end,
}
