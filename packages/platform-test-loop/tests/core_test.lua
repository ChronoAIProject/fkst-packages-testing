local core = require("core")
local t = fkst.test

local function module_result(module, status)
  return {
    schema = "testing-runner.result.v1",
    job = "module-test-loop",
    module = module,
    status = status,
    artifact_root = ".testing/runs/" .. module,
    source_ref = { kind = "module", ref = module },
    dedup_key = module .. "-run",
    exit_code = status == "passed" and 0 or 1,
  }
end

local function generic_host_module_result(module)
  return {
    schema = "testing-runner.result.v1",
    job = "module-test-loop",
    module = module,
    status = "passed",
    artifact_root = ".testing/runs/generic-host-" .. module,
    source_ref = { kind = "host-module", ref = module },
    trace_id = "trace-generic-host-" .. module,
    dedup_key = "generic-host-" .. module,
    exit_code = 0,
    adapter = { name = "fkst-native", mode = "module-no-browser" },
    native_summary = {
      schema = "testing-runner.module-no-browser-summary.v1",
      module = module,
      status = "passed",
      mode = "argv",
    },
  }
end

return {
  test_builds_platform_runner_request = function()
    local request = core.runner_request({
      schema = "platform-test-loop.start.v1",
      modules = { "a", "b" },
      priority = { "P0", "P1" },
      e2e_driver = "browser_harness",
      backend = "fkst-native",
      preflight_result = { status = "ready" },
      trace_id = "trace-platform",
      dedup_key = "dedup-platform",
    })
    t.eq(request.schema, "testing-runner.platform-test-loop.request.v1")
    t.eq(request.modules[2], "b")
    t.eq(request.priority[1], "P0")
    t.eq(request.e2e_driver, "browser_harness")
    t.eq(request.backend, "fkst-native")
    t.eq(request.preflight_result.status, "ready")
    t.eq(request.trace_id, "trace-platform")
    t.eq(request.dedup_key, "dedup-platform")
  end,

  test_rejects_sparse_modules = function()
    t.raises(function()
      local modules = {}
      modules[1] = "a"
      modules[3] = "c"
      core.runner_request({ schema = "platform-test-loop.start.v1", modules = modules })
    end)
  end,

  test_aggregate_defaults_to_planned_modules = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      modules = { "module-a", "module-b" },
      platform = "generic-platform",
      artifact_root = ".testing/runs/platform",
      trace_id = "trace-platform",
      dedup_key = "platform-run",
    })
    t.eq(result.status, "planned")
    t.eq(result.counts.total, 2)
    t.eq(result.counts.planned, 2)
    t.eq(result.modules[1].module, "module-a")
    t.eq(result.modules[2].status, "planned")
    t.eq(result.artifact_root, ".testing/runs/platform")
    t.eq(result.metadata_path, ".testing/runs/platform/metadata.json")
    t.eq(result.trace_id, "trace-platform")
    t.eq(result.dedup_key, "platform-run")
  end,

  test_aggregate_all_passed = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        module_result("module-a", "passed"),
        module_result("module-b", "passed"),
      },
      artifact_root = ".testing/runs/platform",
    })
    t.eq(result.status, "passed")
    t.eq(result.counts.passed, 2)
    t.eq(result.modules[1].dedup_key, "module-a-run")
    t.eq(result.modules[2].exit_code, 0)
  end,

  test_generic_host_module_results_aggregate_to_platform_passed = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        generic_host_module_result("module-a"),
        generic_host_module_result("module-b"),
      },
      artifact_root = ".testing/runs/generic-host-platform",
      source_ref = { kind = "host-platform", ref = "generic-host" },
      trace_id = "trace-generic-host-platform",
      dedup_key = "generic-host-platform",
    })
    t.eq(result.schema, "platform-test-loop.aggregate.v1")
    t.eq(result.status, "passed")
    t.eq(result.counts.total, 2)
    t.eq(result.counts.passed, 2)
    t.eq(result.modules[1].module, "module-a")
    t.eq(result.modules[1].status, "passed")
    t.eq(result.modules[1].artifact_root, ".testing/runs/generic-host-module-a")
    t.eq(result.modules[1].dedup_key, "generic-host-module-a")
    t.eq(result.modules[1].exit_code, 0)
    t.eq(result.modules[2].module, "module-b")
    t.eq(result.modules[2].status, "passed")
    t.eq(result.modules[2].artifact_root, ".testing/runs/generic-host-module-b")
    t.eq(result.modules[2].dedup_key, "generic-host-module-b")
    t.eq(result.modules[2].exit_code, 0)
    t.eq(result.artifact_root, ".testing/runs/generic-host-platform")
    t.eq(result.metadata_path, ".testing/runs/generic-host-platform/metadata.json")
    t.eq(result.source_ref.kind, "host-platform")
    t.eq(result.source_ref.ref, "generic-host")
    t.eq(result.trace_id, "trace-generic-host-platform")
    t.eq(result.dedup_key, "generic-host-platform")
  end,

  test_aggregate_all_failed = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        module_result("module-a", "failed"),
        module_result("module-b", "failed"),
      },
      artifact_root = ".testing/runs/platform",
    })
    t.eq(result.status, "failed")
    t.eq(result.counts.failed, 2)
  end,

  test_aggregate_all_blocked = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        module_result("module-a", "blocked"),
        module_result("module-b", "blocked"),
      },
      artifact_root = ".testing/runs/platform",
    })
    t.eq(result.status, "blocked")
    t.eq(result.counts.blocked, 2)
  end,

  test_aggregate_all_degraded = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        module_result("module-a", "degraded"),
        module_result("module-b", "degraded"),
      },
      artifact_root = ".testing/runs/platform",
    })
    t.eq(result.status, "degraded")
    t.eq(result.counts.degraded, 2)
  end,

  test_aggregate_mixed_statuses = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        module_result("module-a", "passed"),
        module_result("module-b", "failed"),
        module_result("module-c", "blocked"),
      },
      artifact_root = ".testing/runs/platform",
    })
    t.eq(result.status, "mixed")
    t.eq(result.counts.passed, 1)
    t.eq(result.counts.failed, 1)
    t.eq(result.counts.blocked, 1)
  end,

  test_aggregate_rejects_sparse_module_results = function()
    t.raises(function()
      local module_results = {}
      module_results[1] = module_result("module-a", "passed")
      module_results[3] = module_result("module-c", "passed")
      core.aggregate_result({ schema = "platform-test-loop.aggregate.v1", module_results = module_results })
    end)
  end,

  test_aggregate_rejects_unsafe_module_artifact_root = function()
    t.raises(function()
      local result = module_result("module-a", "passed")
      result.artifact_root = "../outside"
      core.aggregate_result({
        schema = "platform-test-loop.aggregate.v1",
        module_results = { result },
      })
    end)
  end,

  test_saga_conformance_hook_passes = function()
    t.eq(#core.saga_conformance_errors(), 0)
  end,
}
